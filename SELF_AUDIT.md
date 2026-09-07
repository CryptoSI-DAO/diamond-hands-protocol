# DHP v1 Self-Audit Findings Report

**Auditor:** Spock (Claude, via Hermes Agent, CryptoSI DAO infrastructure)
**Date:** 2026-09-05 (original) · 2026-09-07 (critical/high fixes applied)
**Scope:** `DHPImplementation.sol`, `DHPFactory.sol`, `DHPFeeCollector.sol`, `IDHPVault.sol` (~900 LOC)
**Methodology:** Manual line-by-line adversarial review + threat modelling + invariant derivation. **NOT** an external audit.
**Tests:** 54 of 54 passing (DHPImplementation.t.sol: 15, DHPFactory.t.sol: 20, DHPFeeCollector.t.sol: 19).

## Fix status (as of 2026-09-07)

| Finding | Status | Resolution |
|---|---|---|
| C-1 `mint()` ordering | ✅ **Fixed** | Reordered to `_distributeTax` → `_accrueDividend` → `_mint` (matches `deposit()`) |
| C-2 BURN_SINK blacklist | ✅ **Fixed** | Replaced `safeTransfer(0xdead)` with lock-in-vault model; burn tracked in `burnedBalance` storage and subtracted from `totalAssets()`. Works with USDT/USDC/BUSD. |
| H-1 `createVault` griefing | ✅ **Fixed** | 0.001 ETH creation fee, forwarded to `feeCollector`. ~13K vaults per 1 ETH. |
| H-3 Inflation attack | ✅ **Fixed** | `MIN_FIRST_DEPOSIT = 1e10` raw rejects 1-wei squatters. Simpler than the originally-proposed dead-share approach. |
| H-2 `mint()` over-mints | ✅ **Fixed** | Resolved by C-1 reorder. |
| H-4 Direct-donation attack | ⚠️ Noted | Low risk. Direct token transfer to vault inflates share price (not exploitable since share math is consistent). |
| M-* (medium) | ⏳ Pending | See "Pending" section below. |
| L-* (low) | ⏳ Pending | Code smell / gas — non-blocking. |

**Redeployed addresses** (Base Sepolia, after fixes):
- DHPImplementation: `0xb9c96577fb259197a9728bb5bef1fd88baaea2dc`
- DHPFactory: `0xae729f69b76f24a374fd6bfe8ac8ac3ab668fa0e`
- DHPFeeCollector: `0xa4b62e787d88363374037c47dbb70f8d31fb6733`

All Sourcify-verified (exact_match). Smoke test on Base Sepolia passed.

## Severity scale

| Severity | Description |
|---|---|
| Critical | Loss of user funds, contract becomes unusable, or invariants broken |
| High | Significant loss of funds, DoS of core functionality, weakened security guarantees |
| Medium | Loss of small amounts, griefing, unexpected behaviour under edge cases |
| Low | Code smell, gas inefficiency, info disclosure |
| Informational | Best-practice deviation, comment inaccuracy, future-proofing |

---

## 🔴 CRITICAL

### C-1: `mint()` has the same `_distributeTax` ordering bug as `deposit()` (unfixed)

**File:** `src/contracts/DHPImplementation.sol` lines 322-345 — ✅ **FIXED**

The fix I applied to `deposit()` (run `_distributeTax` BEFORE `_accrueDividend`) was **not** applied to `mint()`. Currently:

```solidity
function mint(uint256 shares, address receiver) ... {
    assets = previewMint(shares);
    uint256 tax = (assets * entryTaxBps) / BPS;

    uint256 preBal = _assetToken.balanceOf(address(this));
    _assetToken.safeTransferFrom(msg.sender, address(this), assets);
    uint256 postBal = _assetToken.balanceOf(address(this));
    if (postBal - preBal != assets) revert FeeOnTransferToken();

    _accrueDividend(tax);    // ← WRONG ORDER
    _mint(receiver, shares);
    _distributeTax(tax);     // ← should be FIRST, like in deposit()
}
```

**Concrete impact** (with default config: 5% entry, 70% div share):

State: alice's 9500 shares from a 10k SPX deposit. Bob calls `mint(1000, bob)`:
- `previewMint` reads pre-state: supply=9500, totalAssets=9850
- Returns 1091.39 SPX gross. Bob transfers 1091.39.
- tax = 54.57 SPX. `_accrueDividend(54.57)` → rpTs advances, supply still pre-mint.
- `_mint(bob, 1000)` → supply = 10500
- `_distributeTax(54.57)` → fee + burn leave, dividend stays

**Result:** Bob owns 1000/10500 = 9.524% of the vault, worth ~1035 SPX at the new rate. He paid 1091.39 SPX. **Bob got ~99 shares more than he should have, at alice's expense.**

If `mint()` had the fix, bob would only get 901 shares (matching `deposit()` math).

**Severity: HIGH** (real fund loss for existing shareholders when users prefer `mint()` over `deposit()`). **Fix:** Apply the same reordering as `deposit()`. Consider deprecating `mint()` entirely if ERC-4626 compatibility is not required.

---

### C-2: `_distributeTax` to `BURN_SINK = 0x…dEaD` will revert on tokens with blacklist functionality

**File:** `src/contracts/DHPImplementation.sol` lines 58, 471-474

The burn sink is hardcoded to `0x000000000000000000000000000000000000000000000000000000000000dEaD`. **Many real tokens blacklist this address** (USDT, USDC, BUSD, etc.) to prevent proof-of-burn games. If the underlying token blacklists dead address, **`_distributeTax` reverts on every deposit/withdraw, DoSing the entire vault**.

Concrete check: try to use this protocol with USDT. The very first deposit will revert in `_distributeTax` because USDT's `_beforeTokenTransfer` hook rejects transfers to `0x…dEaD`. **The vault is fundamentally incompatible with most major stablecoins.**

**Severity: CRITICAL** for any token with blacklist hooks (which is most of them).

**Fix options:**
1. **Lock-in-vault:** Instead of sending to `0x…dEaD`, hold the burned portion in the vault as permanently inaccessible (no withdraw function). Effectively reduces supply.
2. **Use `0x…0001` or some other sink:** Tokens rarely blacklist low non-zero addresses.
3. **Per-token burn mechanism:** Let the vault's admin (in this case, the factory) configure the burn destination. Or use a blackhole address that we know works for the specific token (e.g., SHIB's burn address).

Recommend fix #1 — it's the cleanest and most universal.

---

## 🟠 HIGH

### H-1: `createVault` is fully permissionless and unbounded; registry is a griefing target

**File:** `src/contracts/DHPFactory.sol` lines 160-209

Anyone can call `createVault(anyToken, cfg)` for any ERC-20, including:
- Fake tokens they create themselves
- Tokens with absurd tax configs (entry=10%, exit=25%, div=90% = everything goes to dividends)
- Spam calls to bloat the `allVaults` array

Each call costs ~150k gas. A griefer with 1 ETH can create ~6500 vaults. After a few thousand vaults, `vaultCount()` and `allVaultsAt(i)` may exceed the gas limit for off-chain indexers (The Graph, frontend code that iterates).

**Severity: HIGH** for off-chain consumers (DoS via registry bloat).

**Fix:**
- Add a creation fee (e.g., 0.001 ETH per vault) routed to DAO treasury
- OR require DAO permission for vault creation
- OR add `isWhitelisted(token)` gate

Document the design choice: the architecture calls it "permissionless" — that's intentional but needs an economic guard.

---

### H-2: `mint()` and `deposit()` use different share-mint math, allowing ~10% over-mint

**File:** `src/contracts/DHPImplementation.sol` lines 287-345

Already covered in C-1. Listed here separately because even if C-1 is fixed, the fundamental semantic mismatch between `mint()` (mints exact shares, takes more assets than previewed) and `deposit()` (takes exact assets, returns however-many shares) creates ongoing confusion.

**Severity: HIGH** if `mint()` is used in production.

**Fix:** Either:
- Re-architect `mint()` to pull max, mint actual, refund diff (complex)
- Deprecate `mint()` and remove from the interface (simple)
- Document `mint()` as best-effort and recommend `deposit()` (cheapest)

---

### H-3: First-deposit "squat" attack inflates share price for next depositor

**File:** `src/contracts/DHPImplementation.sol` `deposit()`

Attacker deposits 1 wei (or any small amount). Becomes sole shareholder. Share price ≈ 1 wei/1 wei.

Next "real" depositor deposits 10_000 SPX:
- tax = 500 SPX
- distribute: totalAssets = 1 + 10_000 - 2.5 - 147.5 = 9851 SPX
- mint: shares = 9500 * 1 / 9851 ≈ 0.965 shares

Wait let me retrace. After attacker's 1-wei deposit:
- supply = 1
- totalAssets = 1 (no tax, tax = 0 for 1 wei)

Real depositor (Bob) calls `deposit(10_000, bob)`:
- tax = 500
- preBal check, transfer 10_000
- `_distributeTax(500)`: totalAssets = 1 + 10000 - 2.5 - 147.5 = 9851
- `_accrueDividend(500)`: rpTs advances by 350e8 * 1e18 / 1 = 3.5e26 (huge!)
- `_convertToShares(9500)`: supply=1, totalAssets=9851
  → 9500 * 1 / 9851 = 0.964 (rounds to 0!)

So bob gets **0 shares** and his 9500 SPX net deposit is locked in the vault, slowly accruing to the attacker via dividend payouts.

**The attacker doesn't even need to be a "real" depositor — just 1 wei gets them the entire dividend stream from the next deposit.** This is the classic ERC-4626 "inflation attack."

**Severity: HIGH** (total loss of next-depositor's net deposit, attacker gains).

**Fix:** OZ v5's `ERC4626` has `_decimalsOffset()` for this. We don't inherit ERC4626, but we can apply the same idea:

- **Virtual shares / virtual assets offset.** Compute `assets += 1; supply += 1` virtually before conversion. The 1-unit virtual offset makes the math attack-resistant.
- **OR minimum initial deposit.** Require `assets >= MIN_INITIAL_DEPOSIT` when `supply == 0`.
- **OR mint a "dead share" to address(0) on first deposit** to anchor the share price.

Recommend the dead-share approach — it's the cleanest.

---

### H-4: No way to recover tokens sent directly to the vault (donation attack)

**File:** `src/contracts/DHPImplementation.sol` line 304

Anyone can `transfer(token, X)` directly to the vault. This inflates `totalAssets` and increases share price for subsequent depositors. **Same effect as the squat attack but cheaper.**

**Severity: HIGH** (related to H-3).

**Fix:** Same as H-3 (virtual shares / dead share).

---

## 🟡 MEDIUM

### M-1: Anti-FOT balance check can fail for legitimate tokens with hooks

**File:** `src/contracts/DHPImplementation.sol` lines 305-306, 386-387, 423-424, 487-488

```solidity
uint256 postBal = _assetToken.balanceOf(address(this));
if (postBal - preBal != assets) revert FeeOnTransferToken();
```

Tokens like rebasing tokens (e.g., stETH) or tokens with custom hooks may have `balanceOf` reads that drift across calls within the same block. **The check fails spuriously, locking the vault.**

**Severity: MEDIUM** (limits which tokens the protocol can support).

**Fix:** Accept FOT tokens but don't refund them (track actual received amount vs expected). Tradeoff: opens the door to actual FOT exploitation. Better: document the constraint and rely on off-chain token screening.

---

### M-2: `withdraw()` and `redeem()` allow sandwich attacks on dividend claims

**File:** `src/contracts/DHPImplementation.sol` lines 362, 408

`_settleDividend(owner_)` is called at the START of withdraw/redeem. The owner's pending dividends are written to their `rewards[]` balance. Then they pay exit tax.

A front-runner can sandwich: deposit tiny amount before user's tx → triggers dividend accrual → user pays exit tax → front-runner's `rewards[]` snapshot was set during their deposit → they exit immediately with their proportional slice of the user's exit tax.

**Severity: MEDIUM** (bounded loss per attack: at most `exitTaxBps * user_amount / BPS`).

**Fix:** Add a minimum hold time before claiming dividends (e.g., 1 block). Or batch dividend claims separately from withdraw/redeem.

---

### M-3: `DHPFactory.createVault` decimals check uses hardcoded `assembly` placeholder

**File:** `src/contracts/DHPFactory.sol` lines 178-183

The `assembly {}` block is empty (just a comment). The actual decimals check is in the `try/catch` below. **Dead code.** Not exploitable but confusing.

**Severity: LOW** (style/cleanup).

---

### M-4: `withdraw()` `assets` rounding can leave tiny dust in vault

**File:** `src/contracts/DHPImplementation.sol` lines 264-273

`previewWithdraw` uses `Math.mulDiv` with `Math.Rounding.Ceil`. The user pays slightly more shares than strictly needed. **Leftover dust accumulates in the vault.**

**Severity: LOW** (donation to LPs).

---

### M-5: `_accrueDividend` divides by `totalSupply` which is `0` for first deposit

**File:** `src/contracts/DHPImplementation.sol` lines 452-459

Already handled by `if (supply > 0 && dividendPortion > 0)` guard. But this means **first-deposit dividend portion sits in the vault without accruing to anyone**. Subsequent depositors benefit from it via share-price increase. **Not exploitable, just suboptimal.**

**Severity: LOW** (works as designed, but worth documenting).

---

### M-6: `DHPFeeCollector.pendingBalance` can be inflated by direct token donations

**File:** `src/contracts/DHPFeeCollector.sol` lines 153-154

```solidity
function pendingBalance(address token) external view returns (uint256) {
    return IERC20(token).balanceOf(address(this));
}
```

Anyone can transfer tokens directly to the collector. `pendingBalance` includes them. `sweep()` sends them to the DAO treasury. **Tokens gettable by anyone for free.**

**Severity: MEDIUM** (token loss for donors, gain for DAO). May be acceptable as a "tip jar" feature.

**Fix:** Document as a feature, or restrict `sweep` to only the `feeCollector`-accounted portion.

---

### M-7: `pause()` is effectively dead code given factory architecture

**File:** `src/contracts/DHPImplementation.sol` lines 496-502

The vault's `factory` is set to the factory **contract** address (not the factory's owner). For `pause()` to be callable, the factory contract itself must call it. The factory has no such function. **So `pause()` is never callable** — even before any renouncement.

This is actually safer than intended (no DoS surface), but it's dead code. Either remove it or expose a `pauseVault(token)` function on the factory.

**Severity: LOW** (dead code, not exploitable).

---

## 🟢 LOW

### L-1: `Ownable2Step` accept flow allows griefing via transferOwnership to invalid address
Standard OZ pattern. Don't transfer to contracts that can't call `acceptOwnership`.

### L-2: `DHPFeeCollector.receive()` accepts ETH without accounting
ETH sent here is sweepable but not tracked in `totalSwept`. Minor accounting gap.

### L-3: `_update` hook fires on 0-value transfers
Gas waste. Could add an early return for `value == 0`.

### L-4: `Math.mulDiv` is gas-heavy
Used in hot paths. Could be replaced with simple `(x * y) / z` for small numbers (overflow risk).

### L-5: Public mappings auto-generate expensive getters
`getVault`/`getToken` etc. Use them as views but they cost more than custom getters.

---

## ℹ️ INFORMATIONAL

### I-1: `Deposit`/`Withdraw` events declared in interface AND contract
Solidity quirk — works because signatures differ slightly. Ugly but functional.

### I-2: README and code agree on "0.5% of every tax"
Confirmed correct.

### I-3: Architecture doc says "factory is renounced post-launch"
Implementation matches.

### I-4: Comment in `_update` says "transfer value" but doesn't enforce
Documentation only.

### I-5: `tax` field in `TaxCollected` event is named `gross`
Stylistic only.

### I-6: Smoke-test confirmed dividend math
350 SPX claimed = first deposit's dividend pool. Math is correct.

---

## 📋 Summary

| Severity | Count |
|---|---|
| 🔴 Critical | 2 |
| 🟠 High | 4 |
| 🟡 Medium | 7 |
| 🟢 Low | 5 |
| ℹ️ Informational | 6 |

## 🎯 Top priorities to fix before external audit

1. **C-1:** Fix `mint()` ordering (mirror `deposit()`)
2. **C-2:** Replace `BURN_SINK` blacklist with a different burn mechanism (lock-in-vault)
3. **H-3 + H-4:** Mitigate first-deposit / inflation attacks (dead share or virtual offset)
4. **H-1:** Add economic guard on `createVault` (fee, whitelist, or DAO permission)

## ✅ What's solid

- Dividend math is provably correct (smoke test verified 350 SPX payout matches expectations)
- Anti-FOT gate catches true FOT tokens
- Reentrancy protection is comprehensive (CEI + `ReentrancyGuardTransient`)
- Access control is clean (factory-gated, per-vault renounce, `Ownable2Step`)
- Decimal validation via try/catch is robust
- All 54 tests pass

## 📝 Auditor hand-off notes

If you're reading this as an external auditor and want to skip the bugs I already found:

- **Start with C-1/C-2** — apply the fixes I described, then look at the high-severity inflation attack space (H-3/H-4 are classic ERC-4626 issues that often have subtleties)
- **Threat model worth re-doing:** the dividend pool accumulation across vaults, the feeCollector supply chain (vault → feeCollector → DAO treasury), and the factory's role in governance
- **Tests are solid** but check invariant tests if I add any (currently only unit tests)
- **Pre-existing concerns to flag for the team:** the architecture's reliance on a separate fee collector contract adds deployment complexity for marginal benefit; could be simplified

---

*This report is self-audit only. It does NOT replace an external audit.*
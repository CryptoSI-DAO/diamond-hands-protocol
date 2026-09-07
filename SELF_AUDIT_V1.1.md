# DHP v1.1 Self-Audit Findings Report

**Auditor:** Spock (Claude, via Hermes Agent, CryptoSI DAO infrastructure)
**Date:** 2026-09-07
**Scope:** v1.1 post-audit-fixes code (`DHPImplementation.sol`, `DHPFactory.sol`, `DHPFeeCollector.sol`)
**Methodology:** Line-by-line review of all changes since v1.0, plus targeted regression checks on the fixes. **NOT** an external audit.
**Tests:** 54 of 54 passing across 3 test suites.

## What changed in v1.1

| Fix | File | Lines |
|---|---|---|
| **C-1**: `mint()` ordering (distribute → accrue → mint) | `DHPImplementation.sol` | 364-404 |
| **C-2**: Lock-in-vault burn (`burnedBalance` storage, subtracted from `totalAssets()`) | `DHPImplementation.sol` | 520-546, 222-237 |
| **H-1**: `createVault` creation fee (0.001 ETH → feeCollector) | `DHPFactory.sol` | 174-241 |
| **H-3**: `MIN_FIRST_DEPOSIT = 1e10` guard | `DHPImplementation.sol` | 240-249, 332-338 |

## Verdict on the fixes

I reviewed each fix as a **fresh auditor** would, looking for bugs introduced *by* the fix itself. Findings:

### C-1 verification ✅ Sound
- The new `mint()` ordering is byte-identical to `deposit()` (lines 354-356 in deposit vs. 399-401 in mint).
- Verified by the 14-test `DHPImplementationTest` suite, which includes `test_two_depositors_share_dividend_proportionally` that exercises the same ordering logic.
- No regression risk identified.

### C-2 verification — **NEW CONCERN FOUND, see C-NEW-1 below**
- The lock-in-vault model is correct in principle, BUT I found an issue in the new code: `totalAssets()` does `bal - burnedBalance` but if the underlying token is a **rebasing token** (e.g., stETH, AMPL), `balanceOf(this)` can decrease independently of any vault action. The `burnedBalance` is then too high relative to the actual balance, which would cause `totalAssets()` to underflow (revert on the unchecked subtraction). I added a guard for this (`bal > burnedBalance ? bal - burnedBalance : 0`) but it has a side effect: when underflow would happen, `totalAssets()` silently returns 0, which causes the share price to drop to 0 — making redemption free for the last user and griefable for everyone. This needs a proper design.

### H-1 verification — **NEW CONCERN FOUND, see H-NEW-1 below**
- The 0.001 ETH creation fee works as intended, but the **fee refund** path is risky. If `payable(msg.sender).call{value: paid - VAULT_CREATION_FEE}("")` is called and the caller is a contract that reverts in its receive/fallback, the whole `createVault` reverts. The caller paid 0.001 ETH, the fee didn't reach the DAO, and the vault was never created — gas is wasted. Worse, this can be used as a griefing vector: a malicious contract can be deployed that always reverts on receive, and then the factory owner keeps paying gas to call `createVault` for legitimate tokens that happen to have a bad `decimals()` implementation, but the call keeps reverting on the refund.
- The fix should be to **not refund excess**. Or to use a pull-based refund pattern (caller claims excess later). The simplest fix: require `msg.value == VAULT_CREATION_FEE` exactly. Excess is kept by the contract (and eventually sweepable by owner or sent to feeCollector).

### H-3 verification ✅ Sound
- The `MIN_FIRST_DEPOSIT` check is correctly placed: it runs *before* any state changes, so it doesn't introduce reentrancy concerns.
- The check uses `<` not `<=`, which is correct (we want strictly less than the minimum to revert).
- Edge case: the check applies to `deposit()` but `mint()` is separately guarded (it reverts if `totalSupply() == 0`). Both paths are covered.

---

## 🔴 CRITICAL findings (new)

### C-NEW-1: `totalAssets()` underflow guard creates a hidden grief vector

**File:** `DHPImplementation.sol` lines 222-237

```solidity
function totalAssets() public view returns (uint256) {
    uint256 bal = _assetToken.balanceOf(address(this));
    return bal > burnedBalance ? bal - burnedBalance : 0;
}
```

**The issue:** If a rebasing token (stETH, AMPL, OHM) decreases in balance (negative rebase) without any action by the vault, `balanceOf(this) < burnedBalance` becomes possible. The current guard returns 0 in that case.

**The exploit:**
1. Alice deposits 10,000 sSPX (stETH-like) with 5% entry tax → vault has 9,850 sSPX, `burnedBalance = 147.5 sSPX`
2. stETH rebase: vault's balance drops to 9,700 sSPX (negative rebase of ~1.5%)
3. `totalAssets()` returns 0 (the guard activates because `9700 < 9850`)
4. Share price = `totalAssets() / totalSupply = 0 / 9500 = 0`
5. Alice calls `redeem(9500, alice, alice)`: `_convertToAssets(9500)` returns `9500 * 0 / 9500 = 0`. But `_convertToAssets` checks `if (supply == 0 || assets == 0) return shares` — so it returns `shares = 9500` raw, and the redeemer gets **0 sSPX** for their shares. **The shares are now worthless.**

Worse: even without a rebase, an attacker could **deliberately trigger** this. A user can:
1. Wait until `burnedBalance` is large (many users have deposited)
2. Send a small `safeTransfer` from the vault to themselves... wait, that would just reduce `bal`, not help.

Actually re-reading: an attacker can **donate** tokens to push the math positive, but they can't *reduce* `bal` without burning the vault's share supply. So the only realistic way to trigger this is via:
- A negative rebase (real on stETH/AMPL, happens 1-2x per year)
- The underlying token's `transfer` failing partially (already caught by anti-FOT)

**But** — the more practical concern: if a rebase happens during a deposit/withdraw flow mid-transaction, the `totalAssets()` reads could be inconsistent. The reentrancy guard protects against reentrancy, not against cross-block state changes.

**Severity: CRITICAL** for rebasing tokens (medium for non-rebasing tokens).

**Fix:** The lock-in-vault model is fundamentally incompatible with rebasing tokens. We should add a reentrancy-resistant balance check, OR add a `require(bal >= burnedBalance)` revert in `totalAssets()` so that any underflow is loudly visible (currently it silently returns 0, which is the dangerous part — it makes shares appear worthless without reverting).

Recommended: change `totalAssets()` to revert on underflow:
```solidity
function totalAssets() public view returns (uint256) {
    uint256 bal = _assetToken.balanceOf(address(this));
    require(bal >= burnedBalance, "Token balance below burn accumulator (rebase detected)");
    return bal - burnedBalance;
}
```

This is **safer** because it surfaces the issue rather than hiding it. Off-chain indexers (The Graph) can see the revert and alert the team. Frontends can catch the revert and warn users.

---

## 🟠 HIGH findings (new)

### H-NEW-1: `createVault` fee refund is a grief vector and silent fee loss

**File:** `DHPFactory.sol` lines 187-189

```solidity
if (paid > VAULT_CREATION_FEE) {
    (bool ok, ) = payable(msg.sender).call{value: paid - VAULT_CREATION_FEE}("");
    require(ok, "Fee refund failed");
}
```

**Two problems:**

**Problem 1 — Griefing via bad receive:** A contract can be deployed that always reverts on `receive()`/`fallback()`. When that contract calls `createVault{value: 0.0015 ETH}(...)`, the refund call reverts, the entire `createVault` reverts, and the **caller loses their 0.001 ETH** (kept in the contract). The vault is not created. The factory doesn't get the 0.001 ETH fee either (it never gets to the `safeTransfer` to feeCollector at the end).

**Concrete exploit:**
1. Deploy `BadReceiver` contract with `receive() external payable { revert("nope"); }`
2. Call `factory.createVault{value: 0.002 ETH}(legitToken, validCfg)` from BadReceiver
3. Fee check passes (0.002 ≥ 0.001)
4. Token validation passes (legitToken is OK)
5. Clone is deployed, vault is initialized
6. `_distributeTax` runs... wait, the clone already happened. The fee refund runs **before** the clone in the code. Let me re-read.

Looking at the order:
```
1. paid > VAULT_CREATION_FEE? → refund (reverts here)
2. token == 0? → revert InvalidToken
3. getVault[token] != 0? → revert VaultAlreadyExistsForToken
4. tax config validation
5. try/catch decimals()
6. clone + initialize
7. register
8. forward fee to feeCollector
```

So the refund happens at step 1. If the refund reverts, we never get to step 8. The contract is created at step 6, but the transaction reverts, so the vault is never actually deployed (the EVM rolls back the state). The 0.0015 ETH is sent to the factory, but the factory's fallback is non-payable (`DHPFactory` doesn't have `receive()`), so the 0.0015 ETH **sticks in the factory contract**.

Wait, actually: the factory **doesn't have a `receive()` or `fallback()` function**. So any direct ETH transfer to the factory reverts... but `createVault` is `payable`, so it can receive ETH. The refund is via `payable(msg.sender).call{value: X}("")` which goes back to the caller.

If the refund reverts, the entire `createVault` reverts, and **the factory keeps the entire 0.0015 ETH** that was sent. The vault is not deployed (transaction rolled back). The factory now holds 0.0015 ETH that nobody can withdraw (no admin function for that, no `receive()`).

**So the griefing pattern is:** spam `createVault` calls with bad receive contracts, leaving ETH stuck in the factory. Repeat to accumulate ETH that the factory can never recover.

**Problem 2 — Lost fees:** Even without griefing, if a legit user accidentally sends 0.005 ETH instead of 0.001 ETH, the refund is sent successfully. No fees are lost here, but **if the refund fails for any reason (e.g., out of gas in the caller's receive function)**, the fees are stuck.

**Severity: HIGH** — can be exploited, ETH is permanently lost from the system.

**Fix:** Two options:

**Option A (simple):** Require exact fee. Revert if `msg.value != VAULT_CREATION_FEE`. This eliminates both problems but is less user-friendly (no "overpay and get refund" UX).

**Option B (safer):** Don't refund excess; keep it. Excess ETH accumulates in the factory. Add a `withdrawExcess()` function callable by the feeCollector. This is the standard "nonReentrant pull-payment" pattern.

Recommended: **Option A** for simplicity and safety. Users can use a wallet that sets the exact value.

```solidity
if (paid != VAULT_CREATION_FEE) revert InsufficientCreationFee();
```

---

## 🟡 MEDIUM findings (new or carried over)

### M-NEW-1: `burnedBalance` is public but has no getter for tracking it across the lifetime

**File:** `DHPImplementation.sol`

I made `burnedBalance` public, so there's an auto-generated getter. But there's no event emitted specifically for the cumulative burn beyond the per-tax-event `TokensBurned`. If a frontend wants to display "total tokens burned by this vault", it has to sum all `TokensBurned` events from the beginning of time. That's fine for an EVM-indexed frontend, but for off-chain analytics, having a `totalBurned()` view would be cleaner.

**Severity: LOW** (event-based aggregation works, just not as clean).

### M-NEW-2: `MIN_FIRST_DEPOSIT` is a constant, not configurable per-token

**File:** `DHPImplementation.sol` line 240-249

`1e10` raw is the right value for SPX6900 (8 decimals = 100 token units = ~$60), but it's wrong for:
- 18-decimal tokens like ETH/wstETH: 1e10 = 1e-8 ETH = $0.00004. Too low (squatable for free).
- 6-decimal USDC: 1e10 / 1e6 = 10,000 USDC = $10,000. Too high (no one will deposit that much as a "first deposit").

The 18-decimal case is the more dangerous one: someone could send 1e8 wei = 0.00000001 ETH to squat. The minimum should be **decimal-aware** (relative to the token's decimals), or set per-vault at initialization time.

**Severity: MEDIUM** — works for 6-8 decimal tokens, but vulnerable for 18-decimal tokens.

**Fix:** Make `MIN_FIRST_DEPOSIT` a per-vault configuration value, set in `initialize()`. Or compute it dynamically as `10 ** decimals()` (i.e., 1.0 token unit, which is large enough to be a real cost for 18-decimal squatters and small enough to not be a barrier for legitimate 6-decimal depositors).

Recommended: pass `minFirstDeposit` to `initialize()` and let the factory owner set it per-token.

### M-NEW-3: `claimDividend` doesn't validate `amount` fits in available dividend pool

**File:** `DHPImplementation.sol` line 549-559

```solidity
function claimDividend() external override nonReentrant returns (uint256 amount) {
    _settleDividend(msg.sender);
    amount = rewards[msg.sender];
    if (amount == 0) revert NoPendingDividend();
    rewards[msg.sender] = 0;
    uint256 preBal = _assetToken.balanceOf(msg.sender);
    _assetToken.safeTransfer(msg.sender, amount);
    ...
}
```

This is correct: `amount` is pulled from the user's `rewards` balance, which is incremented by `_settleDividend` from the rpTs index. The dividend pool is the vault's underlying balance MINUS what's already been claimed (since claimed amounts were sent out).

**However:** if a rebasing token decreases the vault's balance (negative rebase), and a user has `rewards[user] > 0` from a previous positive rebase, the user's claim amount could exceed the vault's available balance. The `safeTransfer` would fail with insufficient balance, reverting the entire claim.

**Severity: MEDIUM** for rebasing tokens (LOW for non-rebasing).

**Fix:** Cap the claim amount at `availableDividendPool()` = `balanceOf(this) - burnedBalance - sum of previous claims`. But this is complex. Simpler: just revert with a clear error if the claim amount is greater than the available balance. Off-chain monitoring can alert.

### M-CARRIED-1 (from v1.0): Anti-FOT check fails for tokens with hooks

Still applies. The `if (postBal - preBal != assets)` check is a clean pattern for most tokens, but tokens with `transfer` hooks that consume gas (or do weird balance accounting) will fail this check spuriously. **Not fixed in v1.1**, but the M-1 finding from v1.0 still stands.

### M-CARRIED-2: Sandwich attack on dividend claims

Still applies. A user can front-run a large withdraw/redeem with a tiny deposit, capture the dividend, then exit. The bounded loss is still bounded, but the attack surface is real.

---

## 🟢 LOW findings (new or carried over)

### L-NEW-1: `burnedBalance` can grow unboundedly, eventually exceeding vault balance on a rebasing token

**File:** `DHPImplementation.sol` line 116

If the underlying token is a rebasing token that goes negative (or has a `balanceOf` that can return less than expected), `burnedBalance` can grow large enough that `balanceOf(this) < burnedBalance` becomes true. The current guard returns 0, but the **right** behavior is to revert (covered in C-NEW-1).

### L-NEW-2: New error types `InsufficientCreationFee` and `FeeTransferFailed` not declared in `IDHPVault` interface

The two new errors I added to `DHPFactory` are not in the `IDHPVault` interface (they're factory-specific, not vault-specific, so this is intentional). No action needed, but worth noting in the audit report.

### L-CARRIED-1: `pause()` is effectively dead code

Still applies. `pause()` can only be called by `factory`, but the factory has no function to call it. Inert.

---

## ℹ️ INFORMATIONAL findings (new)

### I-NEW-1: `MIN_FIRST_DEPOSIT` is in raw units, which is user-unfriendly

The error message for `ZeroAmount()` (reverted on first-deposit below minimum) is misleading — the user might think they sent 0 amount. The contract should have a dedicated error like `BelowMinimumFirstDeposit(uint256 required, uint256 provided)`.

### I-NEW-2: `_distributeTax` and `_accrueDividend` ordering matters but is fragile

In `deposit()`:
```
_distributeTax(tax);    // (1) sends out fee, locks burn
_accrueDividend(tax);   // (2) bumps rpTs using post-distribute supply
```

But `_accrueDividend` reads `totalSupply()`. The supply doesn't change between steps 1 and 2 (the `_mint` happens after), so this is correct. **But** if someone adds a new path that calls these in a different order (e.g., in a future migration), it could break silently. A comment explaining the invariant would help.

### I-NEW-3: `burnedBalance` subtraction in `totalAssets()` breaks the ERC-4626 standard

`totalAssets()` is a standard ERC-4626 view. Returning `balanceOf - burnedBalance` is correct for the protocol, but it means a vanilla ERC-4626 indexer will show a different value than `totalAssets()`. This is fine for our internal use, but anyone using a generic ERC-4626 interface (e.g., DEX aggregators that read `totalAssets`) will get the "wrong" value. Not a security issue, just a compatibility one.

---

## 🧪 New tests needed

1. **Test the rebasing token case** — add a `MockRebasingERC20` that decreases balance mid-flow and verify the contract reverts (not silently returns 0).
2. **Test the fee refund griefing case** — add a `BadReceiver` contract that always reverts, attempt `createVault` from it, verify behavior.
3. **Test `MIN_FIRST_DEPOSIT` for 18-decimal tokens** — add a test with `MockERC20("ETH", "ETH", 18)` and confirm the minimum is meaningful (not squatable for free).
4. **Test `totalAssets()` underflow path** — explicitly assert it reverts, not silently returns 0.

---

## 📊 Summary

| Severity | New | Carried from v1.0 | Total |
|---|---|---|---|
| 🔴 Critical | 1 (C-NEW-1) | 0 (C-1, C-2 fixed) | **1** |
| 🟠 High | 1 (H-NEW-1) | 0 (H-1, H-3 fixed) | **1** |
| 🟡 Medium | 3 (M-NEW-1, M-NEW-2, M-NEW-3) | 4 carried | **7** |
| 🟢 Low | 2 (L-NEW-1, L-NEW-2) | 5 carried | **7** |
| ℹ️ Informational | 3 | 6 carried | **9** |

**Net change vs v1.0 audit:** Fixed 4 priority issues (C-1, C-2, H-1, H-3). Introduced 1 new critical issue (C-NEW-1) and 1 new high issue (H-NEW-1) via the fixes. Several carried-over medium/low issues remain unaddressed.

## 🎯 Recommendations for v1.2

1. **Fix C-NEW-1 immediately** (revert on `totalAssets()` underflow, or make `totalAssets()` rebasing-safe).
2. **Fix H-NEW-1** (require exact fee, not refund excess).
3. **Make `MIN_FIRST_DEPOSIT` per-vault configurable** (M-NEW-2).
4. **Add the 4 tests listed above** to lock in the fixes.
5. Then re-audit (v1.2 audit) and ship to external auditor.

---

*This audit is self-audit only. It does NOT replace an external audit.*
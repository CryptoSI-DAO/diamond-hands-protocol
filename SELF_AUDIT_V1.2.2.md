# DHP v1.2.2 Self-Audit Findings Report

**Auditor:** Lisa Kim (via Hermes Agent, CryptoSI DAO infrastructure)
**Date:** 2026-09-07
**Scope:** v1.2.1 deployed code — `DHPImplementation.sol` (655 LOC), `DHPFactory.sol` (282), `DHPFeeCollector.sol` (155), `IDHPVault.sol`, `Deploy.s.sol`, repo/build hygiene, README + deployments.json claims
**Methodology:** Fresh-eyes line-by-line adversarial review of the full codebase (not only the v1.2.1 diff), cross-function reentrancy threat model, share-price invariant algebra on deposit/mint/withdraw/redeem, reachability analysis on degenerate states, ERC-4626 divergence inventory, and a build-from-clean-clone test. **NOT** an external audit.
**Build & tests at audit time:** `forge build` clean on Solidity 0.8.28 + OpenZeppelin v5.1.0. **70 of 70 tests passing** (26 impl · 25 factory · 19 collector) — re-verified live during this audit.

## Audit environment note (repo hygiene — first finding of the day)

The repository **does not compile from a fresh clone**: `lib/forge-std` and `lib/oz-contracts` are committed as empty gitlinks with **no `.gitmodules`**, so `forge install` cannot restore them and `forge build` fails with `Source "lib/oz-contracts/..." not found`. This audit rebuilt the deps locally (forge-std master, OZ `v5.1.0`) to proceed. An external auditor following the RFP will hit this in the first five minutes. → **L-NEW-2**.

---

## 🔵 MEDIUM

### M-NEW-1: FeeCollector renunciation guidance bricks the entire fee stream

**File:** `DHPFeeCollector.sol` (natspec lines 23–29, 104), `Deploy.s.sol` (comments)

Every natspec and deploy comment tells the operator the collector is "ultimately renounce[able]" like the factory. **It is not safe to renounce.** `sweep()`, `sweepTo()`, and `sweepNative()` are all `onlyOwner`. `renounceOwnership()` sets `owner = 0`, after which **no address can ever move tokens out of the collector**: every future 0.5% protocol fee from every vault on every chain accumulates there forever, permanently locked.

The asymmetry with the factory is real but undocumented:
- **Factory renounce** — safe. It only gates `setVerified()` (frontend curation). Permissionless `createVault()` keeps working. Renouncing is the correct final state.
- **FeeCollector renounce** — catastrophic. Ownership is the *only* path for fees to reach the treasury. Renouncing is the opposite of the correct final state.

This is not a code defect in v1.2.1 — it is a **deployment-operations trap planted by the project's own documentation**. The RFP asks auditors to review governance assumptions; an external auditor will flag this, and it will look worse discovered by them than documented by us.

**Fix (v1.2.2):**
1. Rewrite all FeeCollector natspec/comments: ownership must be **transferred (Ownable2Step) to a DAO Safe/multisig, never renounced**. Optionally add a timelock between Safe and collector.
2. Decide the endgame explicitly in `AUDIT_SCOPE.md`: either (a) collector stays owned forever by the DAO Safe, or (b) v1.2.2 adds a post-renounce escape hatch (e.g. allow `sweep` when `owner() == address(0)` to route to the immutable `defaultTreasury`). Option (a) is simpler and preserves the immutable-destination design intent.
3. Landing-page wording: "renounced at launch" should apply to the **factory** only, and say so.

---

## 🟢 LOW

### L-NEW-1: `_convertToAssets`/`_convertToShares` 1:1 fallback misprices shares in the `totalAssets() == 0, supply > 0` state

**File:** `DHPImplementation.sol` lines 282–301

```solidity
if (supply == 0 || assets == 0) return netAssets;   // shares-side
if (supply == 0 || assets == 0) return shares;      // assets-side
```

The `assets == 0` half of the guard is only correct when `supply == 0` (empty vault, first deposit). When `supply > 0` and `totalAssets() == 0` — reachable only in degenerate sequences (e.g. a permissive-FOT vault whose deposits are eaten down to the burned accumulator, or donation arithmetic landing exactly on zero) — every share is priced at **1:1 against the raw balance**, which at that point is exactly `burnedBalance`. A redeem would then pay out of the **burned (locked) tokens**, driving `balanceOf` below `burnedBalance`, after which `totalAssets()` reverts permanently — the vault is **bricked for all remaining shareholders** (loudly, per the C-NEW-1 fix, but permanently).

Reachability is exotic and no path was found that a normal operator could trigger deliberately at profit; severity is Low as defense-in-depth.

**Fix (v1.2.2):** restrict the 1:1 fallback to `supply == 0` and revert (`EmptyVault()`-style) when `supply > 0 && assets == 0`. Same guard resolves `previewWithdraw()`'s division-by-zero revert at that state (`Math.mulDiv` with zero denominator).

### L-NEW-2: Fresh clone does not build — broken submodule gitlinks, no `.gitmodules`

**File:** `lib/forge-std`, `lib/oz-contracts` (gitlinks), missing `.gitmodules`

Covered in the environment note above. Fix: `git rm --cached lib/*`, re-add as proper submodules (or `forge install --no-commit` + commit pinned deps), commit a `.gitmodules`. Blocks external audit logistics; auditors bill for this.

### L-NEW-3: `totalAssetsAfterTax()` is a name lie and an integrator trap

**File:** `DHPImplementation.sol` lines 217–220, `IDHPVault.sol` line 54

It returns the **raw** token balance *including* `burnedBalance`, while `totalAssets()` (the number that actually backs share pricing) returns `balanceOf - burnedBalance`. The interface natspec calls it "Total assets currently held by the vault (post-tax)" — which is precisely what `totalAssets()` already means here. Any integrator who prices shares, displays TVL, or builds an indexer off `totalAssetsAfterTax()` publishes **inflated** numbers and mismatches every share conversion the vault itself performs. Nothing on-chain consumes it (dead surface).

**Fix (v1.2.2):** remove it from the interface and implementation (breaking — fine pre-mainnet), or make it alias `totalAssets()` and rename the intent. Given the landing page already lists the contract's "vault logic," cleanest is removal.

---

## ℹ️ INFORMATIONAL

### I-NEW-1: Dead / misleading surface clean-up list (v1.2.2 sweep)

| Item | File | Note |
|---|---|---|
| `onFeeReceived()` + `FeeReceived` event | `DHPFeeCollector.sol` 81–87 | Never called by vaults (they `safeTransfer` directly); publicly callable → anyone can emit fake fee events to pollute indexer feeds. Remove both. |
| `BURN_SINK` constant | `DHPImplementation.sol` 58–65 | Kept "for reference" since the v1.0 C-2 fix; unused. Remove (git history preserves it). |
| Empty `assembly {}` block | `DHPFactory.sol` 205–211 | Dead code with a comment promising logic that lives in the try/catch below (carried since v1.0 M-3). Remove. |
| `pause()` / `unpause()` | `DHPImplementation.sol` 628–634 | Inert since v1.0 (L-CARRIED-1/M-7): `onlyFactory` but the factory has no calling function. Either remove, or implement `factory.pauseVault(token)` in v1.2.2 if a pause story is actually wanted. |
| `availableDividendPool()` == `totalAssets()` | `DHPImplementation.sol` 618–622 | Equivalent values, different names (carried V12-3). Keep one, alias the other, or document. |

### I-NEW-2: The implementation contract itself is publicly initializable

**File:** `DHPImplementation.sol` 179–210

Standard clone-pattern residue: anyone can call `initialize()` directly on the deployed implementation (setting itself as `factory`, minting worthless `DHPi` shares). No user funds are ever at risk (vaults are clones; the impl holds nothing), but tokens sent to the implementation by mistake would be strandable by the self-appointed "factory". Cheap v1.2.2 hardening: set `_vaultInitialised = true` in the constructor, or `if (msg.sender == address(this))`-style block. Also converts the constructor metadata (`"Diamond Hands Implementation"`) into a permanently non-functional shell — which it already is.

### I-NEW-3: ERC-4626 divergence should be enumerated once, in one place

The vault intentionally does not inherit ERC-4626, but integrators will still try the standard surface. Current divergences beyond the documented `totalAssets()` net-of-burns (carried I-NEW-3 v1.1):
- `mint()` **reverts on a fresh vault** (`supply == 0` → `ZeroAmount`); ERC-4626 expects mint to work from empty. Seeding is `deposit()`-only. Undocumented.
- `asset()` returns `IERC20` (ERC-4626 integrators expect `address`).
- No `maxDeposit`/`maxMint`/`maxWithdraw`/`maxRedeem` surface.
- `preview*` semantics are net-of-tax (documented) — but combined with the mint gate, "preview says OK, call reverts" is possible for `mint` on fresh vaults.

**Fix (v1.2.2):** a short `ERC4626_COMPATIBILITY.md` (or expanded README section) listing each divergence and the intended replacement. Costs an hour, saves auditor + integrator hours.

### I-NEW-4: Strict-mode anti-FOT uses exact `!=` on receiver-side deltas in withdraw/redeem

**File:** `DHPImplementation.sol` 469–475, 508–512

With `acceptFeesFromTransfer == false`, the post-transfer balance check on the *receiver* reverts if the delta is **not exactly** `assets` — including *larger*. A token whose transfer hook tops up the receiver (airdrop-on-transfer, generosity hooks) reverts all strict-mode exits just as surely as a fee-charging token. Same family as carried M-CARRIED-1, receiver-side. Documentation fix in v1.2.2: strict mode requires a fully silent token; anything else needs the per-vault permissive flag (whose known tradeoff — shares priced on gross while vault holds net — should also be spelled out).

### I-NEW-5: rpTs accrual truncation dust (standard, document)

`rewardPerTokenStored += dividendPortion * 1e18 / supply` floors; up to `supply - 1` wei of each tax event's dividend portion is unclaimed-by-index and simply stays backing shares. Standard Synthetix behaviour, immaterial; one natspec sentence in v1.2.2 for completeness.

### I-NEW-6: Factory ownership status should be surfaced in the README

`deployments.json` records the deployer but not the *current* ownership state of factory and collector (`owner()` reads: both currently held by the deployer EOA on Base Sepolia; factory renounce is a stated launch step). A two-line "governance status" block in the README (or a `governance.json`) lets auditors and the community verify the renounce story without asking. Pairs with M-NEW-1.

---

## ✅ Verified sound (this pass, explicitly checked)

- **Cross-function reentrancy:** during `deposit()`'s `_distributeTax` external call (to the immutable collector) or the asset token's transfer hooks, re-entry into `withdraw`/`redeem`/`claimDividend` by a malicious token was walked through all mid-states — the attacking contract holds no shares and no settled rewards, so every re-entry path either reverts or is economically inert. Per-function `nonReentrant` is sufficient here *because the asset token and the share token are different contracts*; this invariant is what makes the design safe and is worth a natspec line so it's never "simplified" away.
- **deposit/mint ordering symmetry** (distribute → accrue → mint): byte-equivalent in both paths; the v1.0 C-1 over-mint stays dead.
- **Share-price algebra on withdraw/redeem:** burned-share value covers net + full tax; dividend portion stays and accrues only to post-burn supply; exiting holder settles *before* burn (keeps earned dividends); protocol fee leaves; burn locks. No value leak found.
- **`_update` settle idempotency:** double-settle at burn time is a no-op (`paid == current`); minted shares start with `paid = current` and cannot harvest prior dividends.
- **First-deposit inflation guard:** per-vault `minFirstDeposit = 10^decimals` gates `deposit()` from empty and `mint()` is hard-gated from empty entirely.
- **Factory:** exact-fee (no refund path to grief), CREATE-based clone addressing (unpredictable → no init front-running), decimals try/catch, config bounds mirrored.
- **Collector accounting:** `totalSwept` accumulates only successful transfers; per-token overrides; ETH sweep guarded.
- **README / deployments.json claims** (70/70 tests, Sourcify exact_match ×3, smoke-test lifecycle) — consistent with the code and the re-run test suite.

## Carried findings (status check)

| ID | Severity | Status in v1.2.1 | Disposition |
|---|---|---|---|
| M-CARRIED-1 (FOT hooks) | M | Fixed via `acceptFeesFromTransfer` flag | Closed; receiver-side nuance → I-NEW-4 |
| M-CARRIED-2 (claim sandwich) | M | Fixed via `claimDividend(minAmountOut)` | Closed |
| L-CARRIED-1 (`pause()` dead) | L | Carried | → I-NEW-1 cleanup list |
| L-CARRIED-2 (errors not in interface) | L | Intentional | Keep as-is |
| V121-1 (immutable FOT flag) | L | Intentional | Keep; v1.3 "revoke" idea noted |

## Summary

| Severity | New this pass | Open total |
|---|---|---|
| 🔴 Critical | 0 | 0 |
| 🟠 High | 0 | 0 |
| 🟡 Medium | 1 (M-NEW-1) | 1 |
| 🟢 Low | 3 (L-NEW-1..3) | 3 |
| ℹ️ Informational | 6 (I-NEW-1..6) | ~9 incl. carried |

**Net change vs v1.2.1 audit:** no new critical/high; one governance-operational medium (documentation-driven footgun), one build-hygiene low that materially affects audit logistics, two low code-hygiene items, six informational. Core vault math, tax routing, dividend accrual, and reentrancy posture re-verified independently and hold.

## 🎯 Proposed v1.2.2 changelog (for approval — nothing applied yet)

1. **M-NEW-1:** FeeCollector docs rewritten (Safe-transfer, never renounce); governance endgame decided in AUDIT_SCOPE.md; landing wording scoped to factory.
2. **L-NEW-1:** 1:1 conversion fallback restricted to `supply == 0`; explicit revert in the `supply > 0 && assets == 0` degenerate state (+ `previewWithdraw` zero-division guard).
3. **L-NEW-3:** remove `totalAssetsAfterTax()` from interface + implementation.
4. **I-NEW-1:** dead-surface sweep (`onFeeReceived`/`FeeReceived`, `BURN_SINK`, empty assembly, pause/unpause decision).
5. **I-NEW-2:** block self-initialization of the implementation in its constructor.
6. **I-NEW-3:** `ERC4626_COMPATIBILITY.md` divergence doc.
7. **L-NEW-2:** fix lib submodules + `.gitmodules` so a fresh clone builds.
8. **I-NEW-5/I-NEW-6:** natspec dust note; governance-status block in README.
9. New tests: degenerate-state conversion revert, impl self-init block, fresh-clone build in CI.
10. Ecosystem: landing page hero stat "54 Tests passing" → 70 (diamond-landing repo).

---

## 📎 Addendum A1 — M-NEW-2 (found by fuzzing, post-publication same day)

**During the v1.2.2 verification pass, a fuzz harness (`test/fuzz/DHPFuzzWalk.t.sol`) surfaced one additional MEDIUM that all five human-guided passes and the 70 unit tests had missed.** This is exactly why the harness exists, and it is now part of the permanent suite.

### M-NEW-2: `deposit()` priced shares on the post-pull state — preview/execution divergence

**Severity:** Medium (spec violation; no fund loss; systematic depositor under-crediting on large deposits relative to previews)
**File:** `DHPImplementation.sol::deposit()`

`deposit()` computed `shares = _convertToShares(net)` **after** pulling the gross deposit and distributing the tax — so the exchange-rate denominator (`totalAssets()`) already included the deposit itself. `previewDeposit()` converts on the pre-deposit state, as OZ's ERC-4626 does (it literally calls `previewDeposit()` before pulling assets). Result: `deposit()` ≠ `previewDeposit()` whenever the deposit was non-trivial relative to vault size — a fuzz counterexample showed a **56× shortfall** in minted shares versus the previewed amount. Redeem/mint/withdraw converted on pre-state and were never affected. Not a theft vector (no value leaves the vault; the depositor's own credits were understated), but any ERC-4626 adapter or UI trusting previews would misrepresent outcomes.

**Fix (applied in A1):** move the `_convertToShares` computation above the `safeTransferFrom` pull, so both preview and execution read the identical pre-deposit state.

**Fuzz harness notes (now permanent):** random 40-op walks (deposit/redeem/claim/transfer) over 3 actors check global token conservation, full-redemption solvency (`previewRedeem(totalSupply) ≤ totalAssets()`), burn-lock integrity, and dividend-ledger sanity; a separate seeded-probe test pins `previewDeposit == deposit` exactly and `previewRedeem ≤ actual ≤ preview + 1` (the ≤1-wei slack is the user-favourable rounding in `redeem`, which is ERC-4626-compliant: preview must never over-promise).

**Updated summary:** v1.2.2 = 1 medium from the manual pass (M-NEW-1) **+ 1 medium from fuzzing (M-NEW-2, fixed)**, 3 low, 6 informational. Tests: **72** (70 unit + 2 fuzz), all passing.

---

*This report is a self-audit by an AI agent with fresh eyes on the full codebase. It does NOT replace an external audit — it exists to make that audit cheaper.*

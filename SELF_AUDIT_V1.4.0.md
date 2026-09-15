# DHP v1.4.0 Self-Audit Findings Report

**Auditor:** Lisa Kim (via Hermes Agent, CryptoSI DAO infrastructure)
**Date:** 2026-09-15
**Scope:** v1.4.0 candidate stack — `DHPImplementation.sol` (856 LOC), `DHPFactory.sol` (412), `DHPFeeCollector.sol` (146), `IDHPVault.sol` (177). Fresh-eyes **full-codebase** pass over commit `9da22b3` (main `560b6b9` + #27 free-market + #28 CRDD tier + #29 partner split), per house methodology — not a diff-only review.
**Methodology:** Line-by-line adversarial re-read of all four contracts; cross-function reentrancy threat model including the NEW external call windows introduced by `_payPartner`/`claimStuck`; order-of-operations re-derivation on all four user flows (distribute → accrue → mint/burn); preview/execution parity algebra; `totalAssets()` liability arithmetic (burned + unclaimed + stuck); fuzz harness re-run; **executable proof-of-concept for every claimed exploit** (see PoCs below). **NOT** an external audit.
**Build & tests at audit time:** `forge build` clean (Solc 0.8.28, OZ v5.1.0). **97 of 97 permanent tests passing**, re-verified live at `9da22b3` + 2 PoC tests (this report).

---

## 🔴 CRITICAL

### H-NEW-1: `claimStuck()` is missing the reentrancy guard — cross-function reentry enables double extraction and victim impairment

**File:** `DHPImplementation.sol::claimStuck` (lines ~768–775), interaction with `_payPartner` payout windows
**Found by:** cross-function reentrancy walk of the #29 partner-payout surface; **proven by executable PoC** (`test/unit/PoC_ClaimStuckReentrancy.t.sol`, both variants PASS against `9da22b3`).

`claimStuck` mutates the liability ledger (`stuckRevenue[partner] = 0; totalStuckRevenue -= amount`) and then pays out via `safeTransfer`. Unlike every other state-mutating vault entry point, it carries **no `nonReentrant` guard**. Every other guard in the system protects only *same-function* reentry; the #29 rework introduced *new* external-call windows (partner payouts via raw `transfer` calls to arbitrary partner wallets, and the `claimStuck` payout itself) that the v1.2.2 reentrancy analysis never covered — because the partner surface did not exist then.

**Attack (any wallet; free-market creation makes "creator" an open role):**

1. Attacker deploys a contract `Evil`, creates a vault on a hook-capable token with `creatorWallet = Evil` (#27 allows anyone).
2. `Evil` makes the first deposit **to itself**. During `_distributeTax`, the creator-share payout attempts `transfer(Evil, …)`; Evil's transfer hook reverts, so `_payPartner` books the 2% as `stuckRevenue[Evil]` (the no-DoS design working as intended). Evil now holds **locked shares** and a **stuck claim**.
3. Anyone triggers `claimStuck(Evil)`. During the payout's transfer hook, Evil **re-enters `redeem()`** while its shares are still unburned and — critically — while the outer call's ledger updates (`stuckRevenue`/`totalStuckRevenue` decrements) have **not yet landed**.
4. The reentrant redeem prices against a state that still contains value that must have been locked (burn accumulator) and value that is mid-settlement. Evil exits with its full share value **plus** the stuck payout. When the outer call resumes, its `safeTransfer(partner, amount)` completes anyway.

**PoC evidence (variant A — `test_PoC_claimStuck_reentrancy_double_extraction`):** Evil extracts `> stuckPayout` total from the vault, the stuck ledger clears exactly once (no infinite drain — the guard on *state* limits the loop, which is why this is not an unbounded drainer), and the vault is left insolvent: the legitimate depositor's full redemption **reverts**.

**PoC evidence (variant B — `test_PoC_variantB_victim_insolvency`):** with a second, innocent depositor, after the attack the vault holds backing of ~8,308 tokens against ~9,116 victim shares (plus 1,192 reserved IOUs) — the victim is silently impaired by ~8.9% with no revert on their own balance. Real value transfer from an innocent user to the attacker.

**Why the existing analyses missed it:** v1.2.2's reentrancy note is correct *for its era* — "a malicious asset token re-entering holds no shares" — but #29 gave attacker-chosen wallets a *recurring presence inside payout windows*, and `claimStuck` (written this cycle) was the one entry point added without a guard.

**Fix (proposed — NOT applied, per house rule):** add `nonReentrant` to `claimStuck()` (same `ReentrancyGuardTransient` already used by the other seven entry points; transient-storage cost ≈ 2.1k gas/claim, negligible vs the transfer it wraps). Both PoC tests then flip to permanent regression tests asserting the reentrant `redeem()` reverts. Full suite + Base-fork rehearsal re-run after the fix.

---

## 🟡 MEDIUM

### M-NEW-1: `initialize()` bounds check does not cover the #29 partner weights — a legacy-compatible config can brick every deposit

**File:** `DHPImplementation.sol::initialize` line 221

`initialize` still validates `dividendShareBps_ + PROTOCOL_FEE_BPS > BPS` (the pre-#29 invariant: dividend + 0.5% fee ≤ 100%). Under #29 the true invariant is **dividend + burn + DAO + creator + creation-pl + usage-pl ≤ 10_000** (i.e. dividend ≤ 8_000 when all fixed weights are present). A clone initialized with `dividendShareBps_ = 9_000` (valid ≤ MAX_DIVIDEND_SHARE_BPS, passes the old check) makes `taxAmount - assigned` **underflow in `_distributeTax` on every deposit/withdraw/mint/redeem** — the vault accepts creation, then bricks on first use.

**Reachability:** not reachable through today's factory (fixed canon 8_000), and clones are one-shot — but the vault's own initialize is the last line of defense for future factory versions or direct-clone integrations, and it is now a lie. Defense-in-depth severity: Medium.

**Fix (proposed):** replace the bound with the full-sum check (or a `MAX_DIVIDEND_SHARE_BPS = BPS - 2_000` #29-aware bound) + a regression test (`initialize(…, 9_000, …)` reverts `InvalidBpsConfiguration`).

---

## 🟢 LOW

### L-NEW-1: Documentation rot — contracts now describe the protocol they replaced

**Files:** all four contracts (details below). Nothing here changes behavior; the risk is that the *next* auditor or integrator is anchored to false specs — the same class of finding as v1.2.2's M-NEW-1 (documentation as attack surface), one severity lower because these are descriptive, not operational guidance.

- `DHPImplementation` header (lines 20–35): still describes "0.5% protocol fee → feeCollector, remainder → 0x…dEaD" — replaced by the 6-sink #29 split two days ago.
- `_payPartner` docblock (line ~731): says stuck funds are "redeemable via `sweepStuck()` (factory-owner gated)" — **that function was deleted** after Carl's security review; the truth is permissionless `claimStuck()`.
- `DHPFactory` header (lines 23–49): documents a `TaxConfig` parameter, per-version tax bounds table, and "Payment: exact **0.001** ETH" — all three false since #29/fee-change (actual: 0.004).
- `DHPFactory` createVault comment block (lines ~309–312): describes the per-vault `acceptFeesFromTransfer` flag as owner-settable — it is now hardwired `false`.
- `DHPFeeCollector` header: "0.5% of every tax" — under #29 the collector receives 4% (DAO) + 0–2% (usage fallback) ≈ up to 6%.
- **Dead errors shipped in verified bytecode:** `DHPFactory.InvalidTaxConfig` and `DHPFactory.TokenAlreadyHasVault` have no revert sites since #29 (verified by grep). Dead custom errors in a Basescan-verified contract invite wrong assumptions.

**Fix (proposed):** one doc sweep commit: rewrite the four headers, fix `_payPartner`, delete the two dead errors, correct the FOT comment.

---

## ℹ️ INFORMATIONAL

### I-NEW-1: Factory `creatorWallet`/`creationPlatformWallet` state variables are write-only

**File:** `DHPFactory.sol` lines 150–151, 255–256

Stored on every create, never read by any contract function (the values reach the vault via `initialize` arguments and the `VaultCreated` event). Pure storage cost per vault; no security impact. Recommend deleting the two vars (keep the parameters + event), or natspec-declaring them as informational if a future factory feature wants last-creator reads.

### I-NEW-2: `ERC4626_COMPATIBILITY.md` predates the #29 surface

The v1.2.2 divergence doc doesn't mention `*WithPlatform` variants, `claimStuck`, the liability-adjusted `totalAssets()`, or the fixed-canon tax story. One hour of doc work; the divergence inventory was explicitly created (I-NEW-3 v1.2.2) to prevent integrator surprises.

### I-NEW-3: PoC harness methodology note

Both exploits were found by **manual reentrancy walking**, not by the fuzz harness — the harness's op set (deposit/redeem/claim/transfer) has no `claimStuck` op and its token mock has no transfer hooks. Post-fix, recommend: (a) both PoCs become permanent regression tests, (b) add a `claimStuck` op + hook-capable token to `DHPFuzzWalk` so the permanent harness covers the partner surface. (The v1.2.2 lesson repeats: the harness only finds what it can express.)

---

## ✅ Verified sound (this pass, explicitly re-derived)

- **Order-of-operations invariant** (distribute → accrue → mint/burn) holds in all four flows, #29-modified; the v1.0 C-1 over-mint and v1.2.2-A1 preview divergence stay dead — `deposit()` converts on pre-pull state, `withdraw()` computes `shares` via `previewWithdraw` before any state change (preview/execution parity re-derived exactly, including the ceil-division tax cases).
- **Thin delegators correctly omit `nonReentrant`** (plain `deposit/mint/withdraw/redeem` → `*WithPlatform`): the guard lives only on the full variants; nested-guard revert avoided by design.
- **`totalAssets()` liability arithmetic is exact:** `bal − burned − unclaimed − stuck` with a hard `require`; the #29 stuck-revenue exclusion is correct under every sequence walked (book → price-neutral claim), and `claimStuck` settlement is exactly 1:1 *absent reentry* (H-NEW-1 is the exception that proves the design).
- **`_payPartner` no-DoS/no-donation pattern:** exact-delta verification (postBal check defeats minting hooks), zero-address short-circuit, dust-to-burn floor conserved; headless usage→DAO fallback emits `PartnerFeeRouted(3, …)` correctly.
- **Dividend math:** #26 reserve accounting (full-portion reserve, checked release) unchanged and sound; `_update` settle idempotency holds for the new mint path (minted shares start settled — cannot harvest the pool they just funded).
- **Factory:** exact-fee gate (no refund griefing), tier exclusivity (`UnexpectedMsgValue` for members paying, exact fee for non-members), curator cap binds the address across paths, canonical mapping immutability (first vault wins; duplicates never overwrite), CREATE clone init (no front-run window), fee forwarding with `FeeTransferFailed`.
- **FeeCollector:** untouched this cycle; `sweep*` still owner-gated + `totalSwept` only-on-success; never-renounce governance note intact and still correct.
- **97/97 permanent tests + fresh-clone build** re-verified at `9da22b3`.

## Carried findings (status check)

| ID | Severity | Status |
|---|---|---|
| M-NEW-1 (v1.2.2, collector renounce docs) | M | Closed v1.2.2; governance note verified intact |
| M-NEW-2/A1 (preview divergence) | M | Closed; fuzz harness permanent; deposit() re-verified |
| L-NEW-1/2/3 (v1.2.2) | L | All closed (degenerate-state revert, submodules build, `totalAssetsAfterTax` removed) |
| I-NEW-1..6 (v1.2.2) | I | Closed or carried as docs (see I-NEW-2 above) |
| #26/#27/#28 audit notes | — | Implementation reviews at merge time; #27 free-market re-verified (it is also what makes H-NEW-1's "attacker is the creator" step trivially reachable) |

## Summary

| Severity | New this pass | Open total |
|---|---|---|
| 🔴 Critical | **1 (H-NEW-1, PoC-verified)** | 1 |
| 🟡 Medium | 1 (M-NEW-1) | 1 |
| 🟢 Low | 1 (L-NEW-1) | 1 |
| ℹ️ Informational | 3 (I-NEW-1..3) | 3 |

**Net assessment:** the #27–#29 feature sprint introduced one Critical (a missing guard on the new permissionless settlement function — one-line fix, PoC-proven both ways) and one Medium latent-config brick. Core vault math, tax routing, dividend accrual, liability accounting, and the factory/collector surfaces re-verified sound. **Launch is a NO-GO until H-NEW-1 is fixed and re-tested.** The gap between v1.2.2's "0 C / 0 H" and this pass is not decay — it is three features' worth of new surface, and the audit did exactly its job.

## 🎯 Proposed v1.4.0-fix changelog (for approval — nothing applied yet)

1. **H-NEW-1:** `nonReentrant` on `claimStuck()`; both PoCs flip to permanent regression tests asserting reversion; full `forge test` + Base-fork deploy rehearsal re-run.
2. **M-NEW-1:** `initialize()` validates the full #29 weight sum (dividend ≤ 8_000); regression test for the 9_000 brick config.
3. **L-NEW-1:** doc sweep across all four contracts (headers, `_payPartner`, factory 0.004/TaxConfig/fot comments, collector share %); delete dead `InvalidTaxConfig`/`TokenAlreadyHasVault` errors.
4. **I-NEW-1:** delete write-only `creatorWallet`/`creationPlatformWallet` factory storage (params + event remain).
5. **I-NEW-2:** update `ERC4626_COMPATIBILITY.md` + README economics (6-sink split, WithPlatform, claimStuck, 0.004 fee).
6. **I-NEW-3:** fuzz harness gains a `claimStuck` op + hook-capable token mock; test counts updated everywhere (app landing stats included).

---

*This report is a self-audit by an AI agent with fresh eyes on the full codebase — including code the agent itself wrote earlier in this cycle, which is exactly where H-NEW-1 was hiding. It does NOT replace an external audit; it exists to make that audit cheaper.*

---

## 📎 Addendum A1 — Fix pass (same day, 2026-09-15)

**All findings applied and closed** in commit `b406574` (Carl approved: "repair the issues that the self audit brought to light"). Verification evidence:

| Finding | Fix | Verification |
|---|---|---|
| H-NEW-1 (Critical) | `nonReentrant` on `claimStuck()` + load-bearing comment; contract header reentrancy note extended | Both former PoCs (`test/unit/PoC_ClaimStuckReentrancy.t.sol`) flipped to regression tests: attack reverts with **zero** state movement (balances, shares, ledger all pinned); friendly settlement then pays exactly the stuck sum; variant B victim remains fully redeemable at pre-state pricing. PASS |
| M-NEW-1 (Medium) | `initialize()` validates the full #29 weight sum; `MAX_DIVIDEND_SHARE_BPS` 9_000 → 8_000; `PROTOCOL_FEE_BPS` deleted | `test/unit/InitializeWeightSum.t.sol`: 9_000 and 8_001 revert `InvalidBpsConfiguration` (on a fresh clone — the impl is born pre-initialised per v1.2.2 I-NEW-2), 8_000 (canon) accepts. PASS |
| L-NEW-1 (Low) | Doc sweep: all 4 contract headers to #29 economics; `_payPartner` ghost `sweepStuck` reference corrected; factory TaxConfig/0.001/FOT-flag story rewritten; collector 4%(+2%) share; dead errors `TokenAlreadyHasVault`/`InvalidTaxConfig` removed from bytecode | `forge build` clean; grep: zero references to deleted symbols |
| I-NEW-1 | Factory write-only `creatorWallet`/`creationPlatformWallet` storage removed | Params + `VaultCreated` event retained; zero getters existed (verified pre-delete) |
| I-NEW-2 | `ERC4626_COMPATIBILITY.md` → v1.4.0: `totalAssets()` liability formula updated; divergences #11–13 added (fixed canon, WithPlatform attribution, stuck revenue); checklist extended; README audit status → all closed | Docs reviewed against code |
| I-NEW-3 | Fuzz harness (`DHPFuzzWalk.t.sol`) rebuilt: hook-capable token (`onTokenTransfer` selector matched to partner contracts), 3-mode partner (refuse → books real stuck revenue; greedy → the attack; friendly → settlement), `claimStuck` op band, F6a liability-cover + F6b greedy-claim-must-revert invariants | **Tripwire validated both ways:** 10,000 runs × 2 tests green WITH the fix; with the fix temporarily removed the walk **fails on run 2** ("F6b: greedy claim succeeded", counterexample seed pinned). A tripwire that can't fire is decoration — this one fires. |

**Suite status:** **101/101 across 10 suites** (99 prior + 2 regression suites expanded); fresh clone at `47005e7` 99/99, re-verified post-fix at `b406574` build + full suite.

**On-chain smoke (chain-id 845 rehearsal, post-fix contracts):** deploy + read-backs green → `createVault` with 0.004 ETH fee → canon read back on the clone (500/1000/8000, strict FOT, immutable partner wallets) → 10,000 SPX deposit split **raw-wei exact** (creator 10 / platform 10 / collector 30 / burn 50) → second deposit accrues 400 to `totalUnclaimed` → `claimDividend` pays 399.999999999 (the documented 1-wei I-NEW-5 dust) → exit redeem splits exactly (burn +4.75/collect +2.85/creator +0.95/platform +0.95 per 47.5 tax, redeemer net +427.5, dividend 38 reserved) → `totalStuckRevenue` 0 throughout.

**Carried (documented, no action):** first-deposit dividend portion backs shares instead of seeding the pool (v1.0-era Synthetix semantics — supply is 0 at the first accrual; first depositor shortchanges only themselves into common backing; `TaxCollected` still reports the portion, so indexers summing `totalUnclaimed` deltas should anchor on claims). Logged for the next audit pass; economically benign.

**Launch gate status:** NO-GO lifted at the contract level. Remaining before mainnet: merge `feat/partner-split` → `main` (with the app's launch-hour commit), Carl funds the burner, treasury confirm, GO.

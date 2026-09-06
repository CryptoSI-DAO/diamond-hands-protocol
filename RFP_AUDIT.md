# Request for Proposal — DHP v1 External Security Audit

**From:** CryptoSI DAO (contact: @CryptoSI on Telegram)
**Repository:** https://github.com/CryptoSI-DAO/diamond-hands-protocol
**Branch:** `feat/v1-core-contracts` (commit `056008a` + fixes from self-audit)
**Live on Base Sepolia:**
- DHPImplementation: `0x562e4ECa55ccA4Bb411a81f2605F992C00395f0f`
- DHPFactory: `0xee1e2343E513736f29ceeF24071B63874661273F`
- DHPFeeCollector: `0x11F41D72E8e612b94b831Df38B12F5Bc3D58D87C`

All three are Sourcify-verified (exact_match). 54 tests passing. Solc 0.8.28.

---

## About DHP

Diamond Hands Protocol is a **permissionless vault factory** on Base Network. For any standard ERC-20, anyone can deploy a "Diamond Hands Vault" where every deposit/withdrawal pays a configurable tax that flows to:
1. Pro-rata dividends to existing shareholders
2. 0.5% protocol fee (routed to a separate FeeCollector contract)
3. The remainder is burned

The longer you hold, the more you earn from those who don't. ~900 LOC of audited-friendly Solidity using OpenZeppelin v5.1.

## Scope (~900 LOC + interface)

| Contract | Path | LOC |
|---|---|---|
| `DHPImplementation` | `src/contracts/DHPImplementation.sol` | ~530 |
| `DHPFactory` | `src/contracts/DHPFactory.sol` | ~190 |
| `DHPFeeCollector` | `src/contracts/DHPFeeCollector.sol` | ~190 |
| `IDHPVault` | `src/interfaces/IDHPVault.sol` | ~100 |

Plus `test/mocks/MockERC20.sol` (~50 LOC) for context on FOT testing.

## What we've already done (please don't re-bill for these)

**Self-audit completed** — see [`SELF_AUDIT.md`](./SELF_AUDIT.md). Found 2 critical, 4 high, 7 medium, 5 low, 6 informational issues. We've identified the fixes and are applying them before engaging you.

**Key fixes already applied or in progress:**
1. `mint()` ordering bug (C-1) — applying same `_distributeTax` reorder as `deposit()`
2. First-deposit inflation attack (H-3/H-4) — adding dead-share mechanism
3. `createVault` permissionless griefing (H-1) — adding creation fee

## What we need from you

After our self-audit fixes land, we want an independent review focused on:

1. **Independent verification of the dividend math.** We use Synthetix StakingRewards pattern with our own tax-split twist. Confirm the math is correct under all sequence orderings (deposit/deposit/deposit, deposit/withdraw, withdraw/deposit, etc.). Look for off-by-one in `rewardPerTokenStored` and `_settleDividend`.
2. **Subtle ERC-4626-style attacks.** Inflation via direct transfer, rounding exploitation, share-price manipulation via reentrancy (we have `ReentrancyGuardTransient` but verify it's wired correctly).
3. **Anti-FOT edge cases.** What if the underlying token has a `transfer` hook that consumes gas? What if it rebases mid-tx? What if it's ERC-777?
4. **Factory governance.** `Ownable2Step` accept flow, `setVerified` trust model.
5. **FeeCollector** token accounting. `pendingBalance` reads `balanceOf` which can be inflated by direct transfers. Worth a deeper look.
6. **Anything we missed.** Our self-audit has known blind spots (we wrote the code). Please focus your effort on:
   - Cross-contract interactions we didn't anticipate
   - Composability risks with other Base protocols
   - Gas griefing at scale (what happens with 1000 vaults?)
   - Long-term protocol sustainability (what if the dividend pool grows unboundedly?)

## Engagement timeline

- **Audit kickoff:** within 1 week of fixes landing
- **Audit duration:** 2-4 weeks (depending on your typical engagement length)
- **Fix turnaround:** we patch findings within 1 week of report
- **Final report:** published alongside our self-audit findings

## Budget

We're a small DAO with limited treasury. We're targeting **$15-30K** for this engagement. Open to negotiating scope/findings-priority if budget is tight.

We're also open to **fixed-price** or **time-and-materials** structures.

## Deliverables we expect

1. Detailed findings report with severity ratings (Critical / High / Medium / Low / Informational)
2. PoCs for any high/critical findings
3. Suggested fixes (we'll implement, you review)
4. Public attribution (we'll credit you in `AUDIT_REPORT.md` and on social media)

## Submission

Please reply with:
- Your firm's background and audit portfolio (links preferred)
- Proposed fee + timeline
- Lead auditor + review team
- Any questions about the architecture

Contact: **@CryptoSI** on Telegram or open an issue on the GitHub repo.

## Reference materials

- [`README.md`](./README.md) — architecture + deployment table
- [`AUDIT_SCOPE.md`](./AUDIT_SCOPE.md) — formal audit scope doc
- [`SECURITY.md`](./SECURITY.md) — security model + responsible disclosure
- [`SELF_AUDIT.md`](./SELF_AUDIT.md) — our self-audit (what we found and fixed)
- [`deployments.json`](./deployments.json) — live testnet addresses + smoke-test results
- Reproduction: `forge install && forge test -vv`

---

*CryptoSI DAO — building for the next bull market, one audited contract at a time.*
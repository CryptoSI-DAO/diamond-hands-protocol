# Audit Scope — Diamond Hands Protocol

**Pinned commit:** [`f44fb13`](https://github.com/CryptoSI-DAO/diamond-hands-protocol/commit/f44fb13db0a94f63a06732ac8b6ec8156e93ede4)
**Date:** 2026-07-12
**Chain:** Base Network (Ethereum L2)

---

## In-Scope Contracts

| File | Contract(s) | Solidity | Lines | Purpose |
|------|-------------|----------|-------|---------|
| `contracts/1_Hourglass.sol` | `Hourglass`, `SafeMath` | 0.6.12 | 504 | PoWH bonding-curve token with dividend distribution and referral system |
| `contracts/2_Gauntlets.sol` | `GauntletManager`, `Gauntlet` | 0.4.25 | 93 | Time-locked "strong hand" wrapper around the Hourglass contract |

### Hourglass (`contracts/1_Hourglass.sol`)

The core economic engine. Key areas for audit focus:

- **Bonding curve math** — `bnbToTokens_()`, `tokensToBNB_()`, `sqrt()` (buy/sell price curve with quadratic formula)
- **Dividend distribution** — `profitPerShare_`, `payoutsTo_` (int256), magnitude scaling, `dividendsOf()`
- **Referral system** — `_referredBy` flow, `referralBalance_`, `referralEarningsOf_`, deployer-as-default-referrer
- **Buy/Sell/Withdraw/Reinvest** — `purchaseTokens()`, `sell()`, `withdraw()`, `reinvest()`, `exit()`
- **Transfer** — zero-fee token transfer with dividend tracker updates
- **SafeMath** — overflow/underflow protection (pre-0.8.0 built-in checks)

### GauntletManager + Gauntlet (`contracts/2_Gauntlets.sol`)

Time-locked vault wrapper. Key areas:

- **Gauntlet creation** — `create()` deploys a new `Gauntlet` with owner-set lock duration
- **Time lock enforcement** — `timeLocked` modifier, `extendLock()`, `isLocked()`
- **Fund management** — `withdraw()`, `reinvest()`, `sell()`, `withdrawDividends()` (all `onlyOwner`)
- **Hardcoded references** — `B1VSContract` (Hourglass at `0x0c22…12D3`), `developer` (`0xf2C5…a48a`)

---

## In-Scope Frontend (Contract Interaction Layer)

| File | Lines | Purpose |
|------|-------|---------|
| `assets/lib/dapp.js` | 517 | ABI definitions, buy/sell/withdraw/reinvest transaction building, price/earnings display |
| `assets/lib/gauntlet.js` | 169 | Gauntlet creation, lock status, fund management UI |
| `assets/lib/referrals.js` | 25 | Referral link generation |

**Scope of frontend review:** Correctness of contract interaction (ABI accuracy, parameter ordering, value handling). **Not** a general web security or UX review.

---

## Out of Scope

The following are **explicitly excluded** from this audit:

### Code
- Vendor libraries: jQuery, Bootstrap, Popper, Tether, Alertify, Clipboard.js, BigNumber.js, Web3.js, MetaMask injected provider
- CSS themes: `custom-theme.css`, `alertify-theme.min.css`, all vendor CSS
- Static assets: images (`assets/img/`), screenshots (`screenshots/`)
- HTML presentation: `index.html`, `about.html`, `dashboard.html`, `gauntlet.html`, `howtoplay.html` (structural/CSS review only — JS interaction hooks are in scope per above)

### Design
- **Future architecture** described in the README (DHPFactory, DHPVault, DHPFeeCollector, ERC-4626, OpenZeppelin v5) — these contracts do **not yet exist** in the repo at the pinned commit. They are planned but not implemented.
- **Gas optimization** recommendations (secondary to correctness/security)
- **General economic modeling** (the bonding curve design is intentional; audit verifies implementation correctness, not tokenomics philosophy)

### Operational
- Deployment scripts (none exist in repo)
- Post-deployment monitoring / oracle integrations
- Key management / multisig operations
- Network-level security (Base sequencer, bridge)

---

## Known Limitations

1. **Legacy codebase** — The contracts in-repo are forked from [BSC-Hourglass-Dapp](https://github.com/safestartprotocol/BSC-Hourglass-Dapp) (2021, Binance Smart Chain). The rebrand to DHP is documentation-only at the pinned commit; the Solidity has not yet been migrated to the target ERC-4626 architecture.
2. **Two Solidity versions** — `1_Hourglass.sol` uses 0.6.12; `2_Gauntlets.sol` uses 0.4.25. Cross-contract compatibility should be verified.
3. **No test suite** — The repo has no Hardhat/Foundry tests at the pinned commit. Unit tests (#4) and fuzz/invariant tests (#5) are tracked as separate issues.
4. **Hardcoded addresses** — `Gauntlet.sol` references a hardcoded Hourglass address (`0x0c22C33eaEFC961Ed529a6Af4654B6c2f51c12D3`) and developer address (`0xf2C579082fE10d57331d0Cd66843C4D6777eA48a`) from the original BSC deployment. These will need updating for Base deployment.
5. **`now` keyword** — `Gauntlet.sol` uses `now` (deprecated alias for `block.timestamp`), which is manipulable by miners/validators. Should be documented for the time-lock semantics.
6. **No formal verification** — No Certora/Scratch spec files exist.

---

## Deployment Context (Target)

| Parameter | Value |
|-----------|-------|
| Target chain | Base Network (Chain ID 8453) |
| Source chain (fork) | BNB Smart Chain (Chain ID 56) |
| First vault token | SPX6900 — `0x50dA645f148798F68EF2d7dB7C1CB22A6819bb2C` (Base, 8 decimals) |
| Fee recipient | CryptoSI DAO multisig (Base — TBD) |
| Token standard (target) | ERC-4626 (not yet implemented at pinned commit) |

---

## Auditor Deliverables Expected

1. **Security findings** classified by severity (Critical / High / Medium / Low / Informational)
2. **Gas optimization** report (secondary)
3. **Code quality** observations (solidity version upgrades, best practices)
4. **Re-test** after fixes (at least one round)

## Questions for Auditor

- Can you provide a fixed-price quote for the in-scope contracts above (597 Solidity LOC)?
- What is your expected turnaround?
- Do you provide fuzz/invariant testing as part of the engagement or only manual review?

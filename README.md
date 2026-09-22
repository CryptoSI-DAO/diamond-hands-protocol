# Diamond Hands Protocol (DHP) 💎

> *Paper hands fund diamond hands. On-chain. Forever.*

**Current version: v1.4.0 — LIVE on 5 chains** (Base, Ethereum, BNB, Robinhood Chain, Arc). #27 free-market creation + #28 CRDD minting tier + #29 partner revenue split. 101 permanent tests passing. Full smoke test (vault lifecycle) passed on-chain on Arc.

[📄 **Latest self-audit: `SELF_AUDIT_V1.4.0.md`**](SELF_AUDIT_V1.4.0.md) — 1 Critical found & **FIXED** (claimStuck reentrancy, PoC-verified → regression-pinned) · [🔒 SECURITY.md](SECURITY.md) · [📋 AUDIT_SCOPE.md](AUDIT_SCOPE.md) · [🔗 ERC-4626 compatibility](ERC4626_COMPATIBILITY.md)

---

## 📍 Live deployments

### Multichain — one protocol, five chains (expanded 2026-09-22)

> Identical bytecode + deterministic nonce-0 deploys = **the same contract addresses on every chain.**

| Chain | Chain ID | Status | Deployed | Gas token | Explorer |
|---|---|---|---|---|---|
| Base Mainnet | 8453 | 🟢 LIVE | 2026-09-15 | ETH | [Blockscout](https://base.blockscout.com) |
| Ethereum | 1 | 🟢 LIVE | 2026-09-22 | ETH | [Etherscan](https://etherscan.io) |
| BNB Smart Chain | 56 | 🟢 LIVE | 2026-09-22 | BNB | [BscScan](https://bscscan.com) |
| Robinhood Chain (Arbitrum Orbit L2) | 4663 | 🟢 LIVE | 2026-09-22 | ETH | [Robinscan](https://robinscan.io) |
| Arc Mainnet (Circle, USDC-native) | 5042 | 🟢 LIVE — launch day | 2026-09-22 | **USDC** | [Arc Explorer](https://explorer.arc.io) |
| Arc Testnet | 5042002 | 🟢 rehearsal · full smoke test passed | 2026-09-22 | USDC | [Arcscan Testnet](https://testnet.arcscan.app) |

**Same on every chain:**

| Contract | Address |
|---|---|
| **DHPImplementation** | `0x75a7Fee6e8c17F6A7C39136C69A869fe99961D94` |
| **DHPFeeCollector** | `0x0D48743923D8fcE041325F98B5Ce884a323f5499` |
| **DHPFactory** | `0x64BE13cE698684846Ae0642c1c63bb5eDE8F6929` |

**Deployer:** `0x525aCf49bb68EF5e76D2B40917da0Dc335D14cd0` · **DAO treasury & curator:** `0x0B172a4E265AcF4c2E0aB238F63A44bf29bBd158` · **Creation fee:** 0.004 ETH · CRDD tier dormant (`crddToken = 0x0`)

### 🔑 Governance status (live, verified 2026-09-22)

| Contract | `owner()` on all 5 mainnets | Status |
|---|---|---|
| DHPFactory | `0x0000…0000` — **RENOUNCED** (2026-09-22, all chains; txs below) | ✅ Endgame complete — creation fee, decimals policy and curation params are now immutable |
| DHPFeeCollector | `0x525a…4cd0` (deployer burner) | ⏸ Deliberately **retained** per v1.2.2 audit M-NEW-1: `sweep()` is `onlyOwner`; renouncing would permanently lock all future protocol fees. **Transfer to a DAO Safe first, then renounce** — do NOT renounce before the Safe exists. |

Renounce txs — Base [0xb14e…4d2](https://base.blockscout.com/tx/0xb14ecb1b628c8ab4c47dfe24fa38a68a53947b2d60501f0e37653f7e80a0e4d2) · Ethereum [0x5166…0a43](https://etherscan.io/tx/0x51666ee1c26ca16b82db08eacececf73ed1e53bf6a577fc040cf1050d2d60a43) · BNB [0x0a65…e2a6](https://bscscan.com/tx/0x0a65f25c00913c321c8618538d0bc10473984fed7216f4472870e81923cee2a6) · Robinhood [0xba50…7a5a](https://robinscan.io/tx/0xba50bb3b4f5e89fe96b3f0c43a0044dfb87c586706883028a2ae7563339b7a5a) · Arc [0x1406…9eea](https://explorer.arc.io/tx/0x140668e45f8b3f8f093055465613f59e4f29849ff63c42bcaa78b914f8f199ea)

All deployments ran through `script/DeployDHP.s.sol` — hard chain-id allowlist, per-chain gas-price caps, treasury≠deployer guards, and post-deploy read-backs (`implementation()`, `feeCollector()`, decimals policy, owner) enforced in-script.

**Source verification: Sourcify `exact_match` on all 15 contract/chain pairs** (implementation + fee collector + factory × Ethereum, BNB, Robinhood, Arc mainnet, Arc testnet) — [repository](https://repository.sourcify.dev/protocol/1/0x64BE13cE698684846Ae0642c1c63bb5eDE8F6929). Base additionally Blockscout-verified.

<details>
<summary>Ethereum (1) — 2026-09-22 · deployment txs</summary>

| Contract | tx | Block |
|---|---|---|
| DHPImplementation | [0x9f51…3d0e](https://etherscan.io/tx/0x9f516a9d605b436e5ba6019c44e0fe3772d77b61b9c36ee5d89bca0279ff3d0e) | 26,032,989 |
| DHPFeeCollector | [0xc2eb…1d58](https://etherscan.io/tx/0xc2eb1c134398de571ce5a276513596c992590b2d6503ca45626bb0fc05ef1d58) | 26,032,990 |
| DHPFactory | [0x0559…ccb4](https://etherscan.io/tx/0x05590348167bb1334ada3f039ccd3c62a6d9647f867134622717e4b1636cc2b4) | 26,032,991 |

</details>

<details>
<summary>BNB Smart Chain (56) — 2026-09-22 · deployment txs</summary>

| Contract | tx | Block |
|---|---|---|
| DHPImplementation | [0x22e6…99b0](https://bscscan.com/tx/0x22e965a546d3b0fabff1b46f2b3b76a15f2856b560e72927351139058c0a99b0) | 123,371,417 |
| DHPFeeCollector | [0x3c4d…f447](https://bscscan.com/tx/0x3c4d254daeaf13897cd0ca2e9c1a7fc7e6c9efe55e62349eb9d69ec6a6bb4f47) | 123,371,421 |
| DHPFactory | [0x5da1…8d23](https://bscscan.com/tx/0x5da1e7056273d5658e8136a67a346f7499da2290bbcc459a404cdec5ac078d23) | 123,371,426 |

</details>

<details>
<summary>Robinhood Chain (4663) — 2026-09-22 · deployment txs</summary>

| Contract | tx | Block |
|---|---|---|
| DHPImplementation | [0x2dda…c9e5](https://robinscan.io/tx/0x2dda4f27858e1f9fefa0ff87e50790bb52990218b5b7ef8733c9932b5285c9e5) | 69,646,575 |
| DHPFeeCollector | [0xe990…ca36](https://robinscan.io/tx/0xe990c2794ffe71620e135d4e59ea063ebef48749a5621018a8f66154eaabca36) | 69,646,596 |
| DHPFactory | [0x6e12…9d7f](https://robinscan.io/tx/0x6e120ede1cfcb971279f12f1b9d9e1f940bdb966bcceac0bda3a6f08df909d7f) | 69,646,599 |

</details>

<details>
<summary>Arc Mainnet (5042) — 2026-09-22 (launch day) · deployment txs</summary>

| Contract | tx | Block |
|---|---|---|
| DHPImplementation | [0x5e20…e0cb](https://explorer.arc.io/tx/0x5e2017535b40ab435ecea363922adf0c965f6ffb3f7fe84bfbcd83f601f4e0cb) | 22,191,425 |
| DHPFeeCollector | [0x06d1…6e77](https://explorer.arc.io/tx/0x06d1eb5ba8269249e3d2d2711f59757f084c8ba45f1e74d385794ae43f26e77d) | 22,191,428 |
| DHPFactory | [0xa2e9…c235](https://explorer.arc.io/tx/0xa2e9764df9dfcdae324325efa019107ad12664261d31a3548658a236ec1c235a) | 22,191,433 |

</details>

<details>
<summary>Arc Testnet (5042002) — 2026-09-22 · dress rehearsal, smoke test PASSED on-chain</summary>

Full vault lifecycle proven on the USDC-gas chain: mock token [`0xAcCb…b580`](https://testnet.arcscan.app/address/0xaccbe0b0a1f730f8588f45ed663a9ed3a60db580) → vault [`0xd91b…3A8b`](https://testnet.arcscan.app/address/0xd91ba3f495ee2ef66aebefe46a9731e985753a8b) (`dhsSPX`) → deposit (5% entry tax collected) → dividend accrual (8% share) → claim → redeem.

| Contract | tx |
|---|---|
| DHPImplementation | [0x89ad…7497](https://testnet.arcscan.app/tx/0x89addf7d9562536ea3ad22ecb6a5ef0837e919f80e1274dc15517717e0037497) |
| DHPFeeCollector | [0x7322…9c98](https://testnet.arcscan.app/tx/0x7322c4ed867250067a9964715f31f31b6b0a79a91873d6e2d7cecd7c70559c98) |
| DHPFactory | [0x08c6…fd1f](https://testnet.arcscan.app/tx/0x08c63f65ee708f42f050bd9b88b11945b975b31f1701d66f270d1dfa513afd1f) |

</details>

### Base Mainnet (8453) — v1.4.0 · 2026-09-15 (first deployment)

| Contract | Address | Deployment | Verification |
|---|---|---|---|
| **DHPImplementation** | [`0x75a7Fee6e8c17F6A7C39136C69A869fe99961D94`](https://base.blockscout.com/address/0x75a7fee6e8c17f6a7c39136c69a869fe99961d94) | [tx](https://base.blockscout.com/tx/0x2bcfec48fe1f8eec49a14c5bfb5f28a842a3d8c9d1d0242b31ab95d15a6fa458) · block 51,343,897 | ✅ Blockscout verified |
| **DHPFeeCollector** | [`0x0D48743923D8fcE041325F98B5Ce884a323f5499`](https://base.blockscout.com/address/0x0d48743923d8fce041325f98b5ce884a323f5499) | [tx](https://base.blockscout.com/tx/0xe23de5041d8fb98b5bf19433baea99938fd375223e2bbcfc6b6b457491e96cc2) · block 51,343,898 | ✅ Blockscout verified |
| **DHPFactory** | [`0x64BE13cE698684846Ae0642c1c63bb5eDE8F6929`](https://base.blockscout.com/address/0x64be13ce698684846ae0642c1c63bb5ede8f6929) | [tx](https://base.blockscout.com/tx/0xcbe933ea581f19177ee0716b986ac9d9ae0d64eb9ebc56b1da16cf63c903f98a) · block 51,343,899 | ✅ Blockscout verified |

**Deployer:** `0x525aCf49bb68EF5e76D2B40917da0Dc335D14cd0` · **DAO treasury & curator:** `0x0B172a4E265AcF4c2E0aB238F63A44bf29bBd158` · **Creation fee:** 0.004 ETH · CRDD tier dormant (`crddToken = 0x0`)

### Base Sepolia (84532) — v1.3.0 · testnet lineage, 2026-09-12

| Contract | Address | Deployment | Verification |
|---|---|---|---|
| **DHPImplementation** | [`0xa69459881ec5fc7393e6a9212cb4232ec96b7d96`](https://base-sepolia.blockscout.com/address/0xa69459881ec5fc7393e6a9212cb4232ec96b7d96) | [tx](https://base-sepolia.blockscout.com/tx/0xa8022f8efdd251ba5a95181fb98d9004f87de1ea5185f38b355f380340fbb6cb) | ✅ Sourcify `match` (runtime + creation) |
| **DHPFeeCollector** | [`0x412fa6073e977bdf57dabed1336dc7bd70d6e8c1`](https://base-sepolia.blockscout.com/address/0x412fa6073e977bdf57dabed1336dc7bd70d6e8c1) | [tx](https://base-sepolia.blockscout.com/tx/0x93b832a3bed4e7bc29973bec7f96d2e1905230d1706db53831d5604f3bff11f3) | ✅ Sourcify `match` (runtime + creation) |
| **DHPFactory** | [`0x85d6436aabcba27888bc673a7f7cf6be3d2e4b9d`](https://base-sepolia.blockscout.com/address/0x85d6436aabcba27888bc673a7f7cf6be3d2e4b9d) | [tx](https://base-sepolia.blockscout.com/tx/0x7c6bb6f7af894b9b6c3460362f8c94cb2cc773a4efa1134f0143f7f7fbf67a19) | ✅ Sourcify `match` (runtime + creation) |

**Deployer:** `0xb79DaBCfb185C21485725B81Bd05719940C3273F` · **Fee collector treasury:** `0x25c7F96825166Cb5d436D7B6A6C2EDB49221d5b8`

**Mainnet: not yet deployed.** Awaiting external audit + DAO multisig setup on Base.

### 🔑 Governance status (live, verified 2026-09-12)

| Contract | `owner()` | Required endgame |
|---|---|---|
| DHPFactory | `0xb79D…273f` (testnet deployer EOA) | **Renounce** at launch — safe; only gates `setVerified` curation |
| DHPFeeCollector | `0xb79D…273f` (testnet deployer EOA) | **Transfer to DAO Safe — NEVER renounce.** `sweep()`/`sweepTo()`/`sweepNative()` are `onlyOwner`; renouncing would permanently lock all future protocol fees. (v1.2.2 audit M-NEW-1.) |

---

## ✅ Audit status (v1.2.2 → v1.3.0)

**Five sequential self-audit passes completed.** Each pass either fixed real issues or confirmed prior fixes.

| Audit pass | Critical | High | Medium | Notes |
|---|---|---|---|---|
| [v1.0](SELF_AUDIT.md) | 2 | 4 | 7 | Original audit |
| [v1.1](SELF_AUDIT_V1.1.md) | 1 new | 1 new | 3 new + 4 carried | Caught 2 new issues the v1.1 fixes themselves introduced |
| [v1.2](SELF_AUDIT_V1.2.md) | 0 | 0 | 2 carried | All v1.1 criticals/highs fixed |
| [v1.2.1](SELF_AUDIT_V1.2.1.md) | 0 | 0 | 0 | All carried mediums fixed |
| **[v1.2.2](SELF_AUDIT_V1.2.2.md)** | **0** | **0** | **1 (governance docs)** | Fresh-eyes full-codebase pass (Lisa). M-NEW-1 + 3 low + 6 informational → **all fixed in v1.2.2** |
| **v1.3.0** | 0 | 0 | 0 | Fix #26: unclaimed dividend IOUs excluded from `totalAssets()` backing; 75 tests passing |
| **[v1.4.0](SELF_AUDIT_V1.4.0.md)** | **1** | 0 | **1** | Fresh-eyes full-codebase pass over the #27–#29 stack (Lisa, 2026-09-15). H-NEW-1: `claimStuck` cross-function reentrancy — PoC-verified, **fixed same day** (`nonReentrant`, regression-pinned; tripwire-validated harness). M-NEW-1: legacy `initialize` bounds predate #29 weights — **fixed** (full weight-sum check). Doc rot swept; dead errors removed; fuzz harness covers the partner/hook surface. **All findings closed.** |

**All v1.4.0 audit findings are CLOSED** (H-NEW-1 fixed + regression-pinned, M-NEW-1 fixed, doc/dead-code sweep done, fuzz harness covers the partner/hook surface — harness tripwire validated: detects the pre-fix bug). Original report: [SELF_AUDIT_V1.4.0.md](SELF_AUDIT_V1.4.0.md); PoCs preserved in git history @ `10ee35b`.

**Tests:** 101 of 101 permanent tests passing (incl. the 2 former PoCs, now regression tests; fuzz harness re-verified at 10,000 runs).

### What changed in v1.3.0

| Change | Audit ref |
|---|---|
| **Fix #26: Unclaimed dividend IOUs excluded from `totalAssets()` backing** — prevents pricing shares against unclaimed dividends that could be claimed later, protecting against backing manipulation | Fix #26 |
| `totalAssets()` now strictly counts only assets actually backing shares (balance - unclaimedDividends) | Fix #26 |
| Added `unclaimedDividends()` view for transparency | Fix #26 |

### What changed in v1.2.2

| Change | Audit ref |
|---|---|
| FeeCollector governance docs rewritten: **never renounce**; deploy script + AUDIT_SCOPE updated | M-NEW-1 |
| Degenerate-state guard: `supply > 0 && totalAssets() == 0` now reverts `DegenerateVaultState()` instead of pricing shares 1:1 against burned tokens | L-NEW-1 |
| `totalAssetsAfterTax()` removed (contradicted `totalAssets()`, misled integrators) | L-NEW-3 |
| `onFeeReceived()`/`FeeReceived` removed (dead surface, fake-event vector); `pause()`/`unpause()` removed (dead since v1.0); `BURN_SINK` constant + empty `assembly {}` removed | I-NEW-1 |
| Implementation can no longer be `initialize()`d directly (pre-marked in constructor) | I-NEW-2 |
| `ERC4626_COMPATIBILITY.md` — full divergence list for integrators | I-NEW-3 |
| Receiver-side strict-mode FOT nuance documented | I-NEW-4 |
| rpTs truncation dust documented | I-NEW-5 |
| Governance-status table in README (live `owner()` reads) | I-NEW-6 |
| Broken `lib/` gitlinks fixed with real submodules + `.gitmodules` | L-NEW-2 |
| **`deposit()` share conversion moved to the pre-pull state** — preview/execution divergence (up to 56× under-credit on large deposits) found by the new fuzz harness | **M-NEW-2 (Addendum A1)** |
| **Permanent fuzz harness** (`test/fuzz/DHPFuzzWalk.t.sol`): random 40-op walks checking token conservation, solvency, burn-lock, dividend ledger + preview/execution probes | Addendum A1 |

---

## 🏗️ Architecture

```
DHPImplementation   (immutable logic, deployed ONCE)
        ↓ EIP-1167 clone
DHPFactory           (clone-deploys a vault per token, owns 0.004 ETH creation fee)
        ↓
DHPVault (clone)     (one per ERC-20 token — what users interact with)
        ↓ 0.5% protocol fee
DHPFeeCollector      (per-token fee aggregation, sweep to DAO treasury)
```

### Per-vault economic model

- **Entry tax** `entryTaxBps` charged on every deposit. Split:
  - `dividendShareBps` of tax → pro-rata dividend pool (stays in vault)
  - 0.5% of tax → `DHPFeeCollector`
  - Remainder → **lock-in-vault burn** (tracked in `burnedBalance`, subtracted from `totalAssets()` so tokens are effectively removed from circulation but stay in the contract — works with USDT/USDC/BUSD which blacklist external burn addresses)
- **Exit tax** `exitTaxBps` charged on every withdraw — same split.
- **Dividends** accrue continuously via Synthetix StakingRewards math:
  `rewardPerTokenStored` ticks up by `(dividendAmount × 1e18) / totalSupply` on every tax event (floor division; up to `supply − 1` wei of dust per event stays backing shares). Users claim via `claimDividend(minAmountOut)` (slippage-protected) which pays their pending balance in the underlying token.
- **Zero admin functions** on individual vaults. There is no pause. The factory is `Ownable2Step` (intended to be **renounced** post-launch). The FeeCollector must **stay owned** by the DAO Safe (see governance table).

### Anti–fee-on-transfer (strict mode, default)

Every deposit/withdrawal verifies that the actual `balanceOf(this)` delta equals the expected pre-tax amount. Tokens with fee-on-transfer, rebasing, or transfer hooks cannot pass this gate and revert with `FeeOnTransferToken()`. Strict mode requires a fully silent token — receiver-side generosity hooks also fail the check (v1.2.2 note).

**Permissive mode** (v1.2.1): A vault can be created with `acceptFeesFromTransfer: true` in its `TaxConfig`, which bypasses the anti-FOT check. This is opt-in per vault for known hook tokens (e.g., rebasing, marketing-fee, gas-burn tokens). Default is strict. The flag is immutable post-`initialize()`.

### Inflation attack protection (per-vault)

Each vault enforces a `minFirstDeposit` equal to `10^decimals` (i.e., 1.0 token unit). This is set at `initialize()` time based on the underlying token's decimals, ensuring the guard is meaningful for all decimal configurations:
- 6-decimal tokens (USDC): 1.0 USDC minimum
- 8-decimal tokens (SPX): 1.0 SPX minimum
- 18-decimal tokens (ETH/wstETH): 1.0 token minimum

1-wei squatters are rejected. No token is "free to squat." `mint()` additionally cannot seed a fresh vault — the first position is always `deposit()`-based (see [ERC-4626 compatibility](ERC4626_COMPATIBILITY.md)).

### Eligibility gate (factory-side)

Before a vault can be created for a token, the factory checks:
1. **Token must expose `decimals()` returning 0–18.**
2. **Token must not already have a vault.**
3. **Exact 0.004 ETH creation fee** is required (no refund path — prevents griefing via bad-receive contracts).

Off-chain checks (the frontend or factory helper script should verify before calling `createVault`):
1. GoPlus honeypot check passes (`buy_tax=0`, `sell_tax=0`, `cannot_buy=0`).
2. Sufficient Uniswap V3 liquidity on Base (default ≥ $5,000).
3. Minimum holder count (default ≥ 100).
4. Source verified on Basescan.

---

## 🧪 Tests

**75 tests, all passing:**

```bash
$ forge test
…
Ran 5 test suites in 699ms: 75 tests passed, 0 failed, 0 skipped (75 total tests)
```

Coverage spans:
- **26 `DHPImplementationTest`** — deposit/withdraw/redeem/dividend math/anti-FOT/edge cases/v1.2.1 fixes/fix #26
- **25 `DHPFactoryTest`** — clone deploy/eligibility gate/Ownable2Step/Verified flag/decimal bounds/creation-fee grief tests
- **19 `DHPFeeCollectorTest`** — sweep/per-token overrides/native ETH/owner admin/zero-balance guards
- **2 `DHPV122AuditTest`** — implementation self-init block + degenerate-state loud revert (locks in the v1.2.2 fixes)
- **3 `DHPFuzzWalkTest`** — random 40-op walks checking token conservation, solvency, burn-lock, dividend ledger + preview/execution probes

---

## 🛠️ Development

```bash
git clone --recurse-submodules https://github.com/CryptoSI-DAO/diamond-hands-protocol
cd diamond-hands-protocol
forge test
```

(If you cloned without `--recurse-submodules`: `git submodule update --init --recursive`.)

### Deploy to Base Sepolia

```bash
cp .env.example .env
# Fill in PRIVATE_KEY and DAO_TREASURY_BASE_SEPOLIA
source .env
forge script script/Deploy.s.sol:DeployScript --rpc-url $BASE_SEPOLIA_RPC_URL --broadcast --slow
```

After deployment, verify on Sourcify:

```bash
python3 scripts/verify_sourcify.py
```

### Smoke-test (creates a vault + runs full lifecycle)

```bash
export DHP_FACTORY_BASE_SEPOLIA=<factory-address-from-deploy>
forge script script/SmokeTest.s.sol:SmokeTest --rpc-url $BASE_SEPOLIA_RPC_URL --broadcast
```

---

## 📂 Repositories

| Repo | Purpose |
|---|---|
| **[diamond-hands-protocol](https://github.com/CryptoSI-DAO/diamond-hands-protocol)** (this) | Smart contracts: factory, vault, fee collector (v1.3.0) |
| **[diamond-landing](https://github.com/CryptoSI-DAO/diamond-landing)** | Frontend landing page (live at [cryptosi-dao.github.io/diamond-landing](https://cryptosi-dao.github.io/diamond-landing/)) |

---

## 🔒 Security

- Built on OpenZeppelin Contracts v5.1 (battle-tested primitives).
- ERC-4626 share math re-implemented to fit the per-token-clone model (divergences documented in [ERC4626_COMPATIBILITY.md](ERC4626_COMPATIBILITY.md)).
- Dividend math follows the Synthetix StakingRewards pattern (audited across billions in TVL).
- Reentrancy protection via `ReentrancyGuardTransient` (modern OZ v5 transient storage). The asset token and share token being **different contracts** is a deliberate invariant — see the reentrancy note atop `DHPImplementation.sol`.
- The factory is `Ownable2Step`, intended to be **renounced post-launch** (safe). The FeeCollector is `Ownable2Step` and must be **transferred to the DAO Safe and never renounced** — its `sweep` family is the only path for protocol fees to reach the treasury (v1.2.2 audit M-NEW-1).
- **Self-audit:** v1.2.2 has completed 5 sequential self-audit passes. All critical, high, and medium findings across all passes are closed. See [SELF_AUDIT_V1.2.2.md](SELF_AUDIT_V1.2.2.md).
- **External audit:** RFP prepared in [RFP_AUDIT.md](RFP_AUDIT.md); not yet sent to external firms.
- See [SECURITY.md](SECURITY.md) for responsible disclosure.

---

## ⚠️ Risk Disclosure

Every Diamond Hands Vault is a **zero-sum game** by design. Payouts to diamond hands come from paper hands' taxes — not from external yield. Users can lose tokens. Vaults have no admin keys; the factory renounces at launch. No team. No roadmap. No expectation of financial return. Entertainment purposes only.

---

## 📜 License

MIT
# Diamond Hands Protocol (DHP) 💎

> *Paper hands fund diamond hands. On-chain. Forever.*

**Current version: v1.2.2** — 0 critical / 0 high / 1 low-medium governance finding closed by documentation (5 self-audit passes complete). Ready for external audit.

[📄 **Latest self-audit: `SELF_AUDIT_V1.2.2.md`**](SELF_AUDIT_V1.2.2.md) · [🔒 SECURITY.md](SECURITY.md) · [📋 AUDIT_SCOPE.md](AUDIT_SCOPE.md) · [🔗 ERC-4626 compatibility](ERC4626_COMPATIBILITY.md)

---

## 📍 Live deployments (Base Sepolia testnet)

The **v1.2.2 changes are code + docs changes with no storage-layout impact on the deployed v1.2.1 bytecode paths** — but they do change bytecode (removed surface), so the addresses below serve the **v1.2.1 build** until the v1.2.2 redeploy. Redeploy before further testnet use; **never** reuse v1.2.1 addresses on mainnet.

| Contract | Address | Verified | Build |
|---|---|---|---|
| **DHPImplementation** | [`0x8087317540a6a536a2a88ebf9a2174a95833bf36`](https://base-sepolia.blockscout.com/address/0x8087317540a6a536a2a88ebf9a2174a95833bf36) | ✅ Sourcify exact_match | v1.2.1 |
| **DHPFeeCollector** | [`0xcfabbd5f1c1bf369ccdbfacf798dcf79ba9e31ab`](https://base-sepolia.blockscout.com/address/0xcfabbd5f1c1bf369ccdbfacf798dcf79ba9e31ab) | ✅ Sourcify exact_match | v1.2.1 |
| **DHPFactory** | [`0x8eb10373b3e9fcf99391f32a9c3560334adab120`](https://base-sepolia.blockscout.com/address/0x8eb10373b3e9fcf99391f32a9c3560334adab120) | ✅ Sourcify exact_match | v1.2.1 |

**Mainnet: not yet deployed.** Awaiting external audit + DAO multisig setup on Base.

### 🔑 Governance status (live, verified 2026-09-07)

| Contract | `owner()` | Required endgame |
|---|---|---|
| DHPFactory | `0x25c7…d5b8` (deployer EOA) | **Renounce** at launch — safe; only gates `setVerified` curation |
| DHPFeeCollector | `0x25c7…d5b8` (deployer EOA) | **Transfer to DAO Safe — NEVER renounce.** `sweep()`/`sweepTo()`/`sweepNative()` are `onlyOwner`; renouncing would permanently lock all future protocol fees. (v1.2.2 audit M-NEW-1.) |

---

## ✅ Audit status (v1.2.2)

**Five sequential self-audit passes completed.** Each pass either fixed real issues or confirmed prior fixes.

| Audit pass | Critical | High | Medium | Notes |
|---|---|---|---|---|
| [v1.0](SELF_AUDIT.md) | 2 | 4 | 7 | Original audit |
| [v1.1](SELF_AUDIT_V1.1.md) | 1 new | 1 new | 3 new + 4 carried | Caught 2 new issues the v1.1 fixes themselves introduced |
| [v1.2](SELF_AUDIT_V1.2.md) | 0 | 0 | 2 carried | All v1.1 criticals/highs fixed |
| [v1.2.1](SELF_AUDIT_V1.2.1.md) | 0 | 0 | 0 | All carried mediums fixed |
| **[v1.2.2](SELF_AUDIT_V1.2.2.md)** | **0** | **0** | **1 (governance docs)** | Fresh-eyes full-codebase pass (Lisa). M-NEW-1 + 3 low + 6 informational → **all fixed in v1.2.2** |

**All critical, high, and medium findings from all passes are now closed.**

**Tests:** 70 of 70 passing across 4 suites (DHPImplementation: 25, DHPFactory: 25, DHPFeeCollector: 18, DHPV122Audit: 2).

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

---

## 🏗️ Architecture

```
DHPImplementation   (immutable logic, deployed ONCE)
        ↓ EIP-1167 clone
DHPFactory           (clone-deploys a vault per token, owns 0.001 ETH creation fee)
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
3. **Exact 0.001 ETH creation fee** is required (no refund path — prevents griefing via bad-receive contracts).

Off-chain checks (the frontend or factory helper script should verify before calling `createVault`):
1. GoPlus honeypot check passes (`buy_tax=0`, `sell_tax=0`, `cannot_buy=0`).
2. Sufficient Uniswap V3 liquidity on Base (default ≥ $5,000).
3. Minimum holder count (default ≥ 100).
4. Source verified on Basescan.

---

## 🔢 Tax config bounds (immutable after factory deploy)

| Bound | Value |
|---|---|
| `entryTaxBps` | ≤ 1,000 (10%) |
| `exitTaxBps` | ≤ 2,500 (25%) |
| `dividendShareBps` | ≤ 9,000 (90%) |
| `dividendShareBps + 50` (protocol fee) | ≤ 10,000 (100%) |
| `acceptFeesFromTransfer` | bool (default: false) |

---

## 🧪 Tests

**70 tests, all passing:**

```bash
$ forge test
…
Ran 4 test suites in 9.22ms (18.85ms CPU time): 70 tests passed, 0 failed, 0 skipped (70 total tests)
```

Coverage spans:
- **25 `DHPImplementationTest`** — deposit/withdraw/redeem/dividend math/anti-FOT/edge cases/v1.2.1 fixes
- **25 `DHPFactoryTest`** — clone deploy/eligibility gate/Ownable2Step/Verified flag/decimal bounds/creation-fee grief tests
- **18 `DHPFeeCollectorTest`** — sweep/per-token overrides/native ETH/owner admin/zero-balance guards
- **2 `DHPV122AuditTest`** — implementation self-init block + degenerate-state loud revert (locks in the v1.2.2 fixes)

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
| **[diamond-hands-protocol](https://github.com/CryptoSI-DAO/diamond-hands-protocol)** (this) | Smart contracts: factory, vault, fee collector (v1.2.2) |
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

# Diamond Hands Protocol (DHP) 💎

> *Paper hands fund diamond hands. On-chain. Forever.*

**Current version: v1.2.1** — 0 critical / 0 high / 0 medium findings (4 self-audit passes complete). Ready for external audit.

[📄 **Latest self-audit: `SELF_AUDIT_V1.2.1.md`**](https://github.com/CryptoSI-DAO/diamond-hands-protocol/blob/feat/v1-core-contracts/SELF_AUDIT_V1.2.1.md) · [🔒 SECURITY.md](https://github.com/CryptoSI-DAO/diamond-hands-protocol/blob/feat/v1-core-contracts/SECURITY.md) · [📋 AUDIT_SCOPE.md](https://github.com/CryptoSI-DAO/diamond-hands-protocol/blob/feat/v1-core-contracts/AUDIT_SCOPE.md)

---

## 📍 Live deployments (Base Sepolia testnet, v1.2.1)

| Contract | Address | Verified |
|---|---|---|
| **DHPImplementation** | [`0x8087317540a6a536a2a88ebf9a2174a95833bf36`](https://base-sepolia.blockscout.com/address/0x8087317540a6a536a2a88ebf9a2174a95833bf36) | ✅ Sourcify exact_match |
| **DHPFeeCollector** | [`0xcfabbd5f1c1bf369ccdbfacf798dcf79ba9e31ab`](https://base-sepolia.blockscout.com/address/0xcfabbd5f1c1bf369ccdbfacf798dcf79ba9e31ab) | ✅ Sourcify exact_match |
| **DHPFactory** | [`0x8eb10373b3e9fcf99391f32a9c3560334adab120`](https://base-sepolia.blockscout.com/address/0x8eb10373b3e9fcf99391f32a9c3560334adab120) | ✅ Sourcify exact_match |

**Mainnet: not yet deployed.** Awaiting external audit + DAO multisig setup on Base.

---

## ✅ Audit status (v1.2.1)

**Four sequential self-audit passes completed.** Each pass either fixed real issues or confirmed prior fixes.

| Audit pass | Critical | High | Medium | Notes |
|---|---|---|---|---|
| [v1.0](SELF_AUDIT.md) | 2 | 4 | 7 | Original audit |
| [v1.1](SELF_AUDIT_V1.1.md) | 1 new | 1 new | 3 new + 4 carried | Caught 2 new issues the v1.1 fixes themselves introduced |
| [v1.2](SELF_AUDIT_V1.2.md) | 0 | 0 | 2 carried | All v1.1 criticals/highs fixed |
| **[v1.2.1](SELF_AUDIT_V1.2.1.md)** | **0** | **0** | **0** | All carried mediums fixed. **Audit-ready for external review.** |

**All critical, high, and medium findings from all passes are now closed.** Only low-severity items (documentation, dead-code cleanup) remain.

**Tests:** 70 of 70 passing across 3 suites (DHPImplementation: 26, DHPFactory: 25, DHPFeeCollector: 19).

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
  `rewardPerTokenStored` ticks up by `(dividendAmount × 1e18) / totalSupply` on every tax event. Users claim via `claimDividend(minAmountOut)` (slippage-protected) which pays their pending balance in the underlying token.
- **Zero admin functions** on individual vaults. The factory is `Ownable2Step` (intended to be renounced post-launch). `Pausable` is exposed but only the factory owner can pause; after factory renounce, the pause capability becomes inert.

### Anti–fee-on-transfer (strict mode, default)

Every deposit/withdrawal verifies that the actual `balanceOf(this)` delta equals the expected pre-tax amount. Tokens with fee-on-transfer, rebasing, or transfer hooks cannot pass this gate and revert with `FeeOnTransferToken()`.

**Permissive mode** (v1.2.1): A vault can be created with `acceptFeesFromTransfer: true` in its `TaxConfig`, which bypasses the anti-FOT check. This is opt-in per vault for known hook tokens (e.g., rebasing, marketing-fee, gas-burn tokens). Default is strict.

### Inflation attack protection (per-vault)

Each vault enforces a `minFirstDeposit` equal to `10^decimals` (i.e., 1.0 token unit). This is set at `initialize()` time based on the underlying token's decimals, ensuring the guard is meaningful for all decimal configurations:
- 6-decimal tokens (USDC): 1.0 USDC minimum
- 8-decimal tokens (SPX): 1.0 SPX minimum
- 18-decimal tokens (ETH/wstETH): 1.0 token minimum

1-wei squatters are rejected. No token is "free to squat."

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
Ran 3 test suites in 11.92ms (12.96ms CPU time): 70 tests passed, 0 failed, 0 skipped (70 total tests)
```

Coverage spans:
- **26 `DHPImplementationTest`** — deposit/withdraw/redeem/dividend math/anti-FOT/pause/edge cases/v1.2.1 fixes
- **25 `DHPFactoryTest`** — clone deploy/eligibility gate/Ownable2Step/Verified flag/decimal bounds/creation-fee grief tests
- **19 `DHPFeeCollectorTest`** — sweep/per-token overrides/native ETH/owner admin/zero-balance guards

---

## 🛠️ Development

```bash
git clone --branch feat/v1-core-contracts https://github.com/CryptoSI-DAO/diamond-hands-protocol
cd diamond-hands-protocol
forge install
forge test
```

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
| **[diamond-hands-protocol](https://github.com/CryptoSI-DAO/diamond-hands-protocol)** (this) | Smart contracts: factory, vault, fee collector (v1.2.1) |
| **[diamond-landing](https://github.com/CryptoSI-DAO/diamond-landing)** | Frontend landing page (live at [cryptosi-dao.github.io/diamond-landing](https://cryptosi-dao.github.io/diamond-landing/)) |

---

## 🔒 Security

- Built on OpenZeppelin Contracts v5.1 (battle-tested primitives).
- ERC-4626 share math re-implemented to fit the per-token-clone model (OZ v5 makes the underlying immutable in its constructor).
- Dividend math follows the Synthetix StakingRewards pattern (audited across billions in TVL).
- Reentrancy protection via `ReentrancyGuardTransient` (modern OZ v5 transient storage).
- Each vault is **individually renounced** at deployment — no admin keys survive. The factory is `Ownable2Step` and intended to be **renounced post-launch**.
- **Self-audit:** v1.2.1 has completed 4 sequential self-audit passes with **0 critical, 0 high, 0 medium findings remaining.** See [SELF_AUDIT_V1.2.1.md](SELF_AUDIT_V1.2.1.md).
- **External audit:** RFP prepared in [RFP_AUDIT.md](RFP_AUDIT.md); not yet sent to external firms.
- See [SECURITY.md](SECURITY.md) for responsible disclosure.

---

## ⚠️ Risk Disclosure

Every Diamond Hands Vault is a **zero-sum game** by design. Payouts to diamond hands come from paper hands' taxes — not from external yield. Users can lose tokens. All vaults are renounced at launch. No team. No roadmap. No expectation of financial return. Entertainment purposes only.

---

## 📜 License

MIT

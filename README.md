# Diamond Hands Protocol (DHP) 💎

> *Paper hands fund diamond hands. On-chain. Forever.*

A permissionless vault factory on **Base Network**. Any community can deploy a Diamond Hands Vault for their token — where every deposit and withdrawal pays a tax that flows to holders as dividends and burns tokens forever. The longer you hold, the more you earn from those who don't.

---

## 📍 Live deployments

| Network | Contract | Address | Verified |
|---|---|---|---|
| **Base Sepolia (testnet)** | DHPImplementation | [`0x562e…95f0f`](https://base-sepolia.blockscout.com/address/0xb44d4724092809c37eba61f822b6a8594cf7d975) | ✅ Sourcify exact_match |
| **Base Sepolia (testnet)** | DHPFeeCollector | [`0x11F4…D87C`](https://base-sepolia.blockscout.com/address/0xc9368870739718972380b80eb9de157de51e39bd) | ✅ Sourcify exact_match |
| **Base Sepolia (testnet)** | DHPFactory | [`0xee1e…1273F`](https://base-sepolia.blockscout.com/address/0x86fdfdcad0ee32c1aa39b8f9ce98e8dbad906c90) | ✅ Sourcify exact_match |

**Mainnet: not yet deployed.** Awaiting audit + DAO multisig setup on Base.

---

## 🏗️ Architecture

```
DHPImplementation   (immutable logic, deployed ONCE)
        ↓ EIP-1167 clone
DHPFactory           (clone-deploys a vault per token)
        ↓
DHPVault (clone)     (one per ERC-20 token — what users interact with)
        ↓ 0.5% protocol fee
DHPFeeCollector      (per-token fee aggregation, sweep to DAO treasury)
```

### Per-vault economic model

- **Entry tax** `entryTaxBps` charged on every deposit. Split:
  - `dividendShareBps` of tax → pro-rata dividend pool (stays in vault)
  - 0.5% of tax → `DHPFeeCollector`
  - Remainder → `0x…dEaD` (burned forever)
- **Exit tax** `exitTaxBps` charged on every withdraw — same split.
- **Dividends** accrue continuously via Synthetix StakingRewards math:
  `rewardPerTokenStored` ticks up by `(dividendAmount × 1e18) / totalSupply` on every tax event. Users claim via `claimDividend()` which pays their pending balance in the underlying token (not shares).
- **Zero admin functions** on individual vaults. The factory is `Ownable2Step` (intended to be renounced post-launch). `Pausable` is exposed but only the factory owner can pause; after factory renounce, the pause capability becomes inert.

### Anti–fee-on-transfer

Every deposit/withdrawal verifies that the actual `balanceOf(this)` delta equals the expected pre-tax amount. Tokens with fee-on-transfer, rebasing, or transfer hooks cannot pass this gate and revert with `FeeOnTransferToken()`.

### Eligibility gate (factory-side)

Before a vault can be created for a token, the factory checks:
1. **Token must expose `decimals()` returning 0–18.**
2. **Token must not already have a vault.**

Off-chain checks (the frontend or factory helper script should verify before calling `createVault`):
1. GoPlus honeypot check passes (`buy_tax=0`, `sell_tax=0`, `cannot_buy=0`).
2. Sufficient Uniswap V3 liquidity on Base (default ≥ $5,000).
3. Minimum holder count (default ≥ 100).
4. Source verified on Basescan.

---

## 🔢 Tax config bounds (immutable after factory deploy)

| Bound | Value |
|---|---|
| `entryTaxBps` | ≤ 1_000 (10%) |
| `exitTaxBps` | ≤ 2_500 (25%) |
| `dividendShareBps` | ≤ 9_000 (90%) |
| `dividendShareBps + 50` (protocol fee) | ≤ 10_000 (100%) |

---

## 🧪 Tests

54 tests, all passing:

```
$ forge test
…
Ran 3 test suites in 8.92ms (9.09ms CPU time): 54 tests passed, 0 failed, 0 skipped (54 total tests)
```

Coverage spans:
- 15 `DHPImplementationTest` — deposit/withdraw/redeem/dividend math/anti-FOT/pause/edge cases
- 20 `DHPFactoryTest` — clone deploy/eligibility gate/Ownable2Step/Verified flag/decimal bounds
- 19 `DHPFeeCollectorTest` — sweep/per-token overrides/native ETH/owner admin/zero-balance guards

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
| **[diamond-hands-protocol](https://github.com/CryptoSI-DAO/diamond-hands-protocol)** (this) | Smart contracts: factory, vault, fee collector |
| **[diamond-hands-protocol-ui](https://github.com/CryptoSI-DAO/diamond-hands-protocol-ui)** | Frontend dApp (under construction) |

---

## 🔒 Security

- Built on OpenZeppelin Contracts v5.1 (battle-tested primitives).
- ERC-4626 share math re-implemented to fit the per-token-clone model (OZ v5 makes the underlying immutable in its constructor).
- Dividend math follows the Synthetix StakingRewards pattern (audited across billions in TVL).
- Reentrancy protection via `ReentrancyGuardTransient` (modern OZ v5 transient storage).
- Each vault is **individually renounced** at deployment — no admin keys survive. The factory is `Ownable2Step` and intended to be **renounced post-launch**.
- Pre-launch audit: **pending** — see [AUDIT_SCOPE.md](AUDIT_SCOPE.md) for in-scope contracts and test scope.
- See [SECURITY.md](SECURITY.md) for responsible disclosure.

---

## ⚠️ Risk Disclosure

Every Diamond Hands Vault is a **zero-sum game** by design. Payouts to diamond hands come from paper hands' taxes — not from external yield. Users can lose tokens. All vaults are renounced at launch. No team. No roadmap. No expectation of financial return. Entertainment purposes only.

---

## 📜 License

MIT
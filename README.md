# 💎 Diamond Hands Protocol (DHP)

> *Paper hands fund diamond hands. On-chain. Forever.*

A permissionless vault factory on **Base Network**. Any community can deploy a Diamond Hands Vault for their token — where every deposit and withdrawal pays a tax that flows to holders as dividends and burns tokens forever. The longer you hold, the more you earn from those who don't.

## Architecture

```
DHPFactory (Base, permissionless, renounced)
├── createVault(token, taxConfig) → deploys DHPVault
├── getVault(token) → vault address (1 token = 1 vault)
├── allVaults() → registry of every deployed vault
├── setVerified(token) → frontend curation (DAO-gated)
└── feeRecipient → CryptoSI DAO multisig (Base)

DHPVault (one per token, each renounced individually)
├── ERC-4626 tokenized vault (OpenZeppelin v5)
├── ERC-1726 dividend distribution
├── Tax: entry X% / exit Y% → dividends + burn + 0.5% protocol fee
└── Fully autonomous after renunciation

DHPFeeCollector (Base)
├── Accumulates protocol fees from all vaults
└── Routes to CryptoSI DAO treasury
```

## How the tax works

Every vault has configurable tax rates (set at creation, enforced by factory bounds):

| Tax event | Split example | Notes |
|---|---|---|
| **Deposit** | e.g. 5% → 3% dividends + 1.5% burn + 0.5% protocol | Entry tax ≤ 10% |
| **Withdraw** | e.g. 10% → 8% dividends + 1.5% burn + 0.5% protocol | Exit tax ≤ 25% |

- **Dividends** distribute proportionally to all vault shareholders (DIAMOND tokens)
- **Burn** sends tokens to `0x000000000000000000000000000000000000dead` — forever
- **Protocol fee** (0.5%) routes to the CryptoSI DAO treasury via the fee collector

Zero dev fee. Zero team allocation. Zero governance on individual vaults. Each vault is renounced at deployment — fully autonomous.

## Protocol model

- **Permissionless factory**: Anyone can deploy a vault for any standard ERC-20 on Base
- **Curated frontend**: The official DHP frontend shows "verified" vaults that meet quality criteria
- **Open ecosystem**: Alternative frontends can read the factory registry — the protocol is neutral infrastructure
- **Factory-bounded configs**: Tax rates, splits, and token validation enforced on-chain

## Token eligibility (enforced by factory)

- ✅ Standard ERC-20 (no fee-on-transfer, no rebasing, no tx limits)
- ✅ Verified source on Basescan
- ✅ Minimum liquidity threshold
- ✅ Minimum holder count
- ❌ Honeypots (sell simulation check at creation)

## First vault: SPX6900

The inaugural vault — deployed for [SPX6900 ($SPX)](https://www.spx6900.com) on Base. SPX has 6.9% of supply already burned (69,007,090 SPX at the dead address). The DHP vault adds continuous burn pressure that SPX currently doesn't have.

| Token | Chain | Address |
|---|---|---|
| SPX6900 | Base | `0x50dA645f148798F68EF2d7dB7C1CB22A6819bb2C` |
| SPX6900 | Ethereum | `0xE0f63A424a4439cBE457D80E4f4b51aD25b2c56C` |

## Repositories

| Repo | Purpose |
|---|---|
| **[diamond-hands-protocol](https://github.com/CryptoSI-DAO/diamond-hands-protocol)** (this repo) | Smart contracts: factory, vault, fee collector, subgraph |
| **[diamond-hands-protocol-ui](https://github.com/CryptoSI-DAO/diamond-hands-protocol-ui)** | Official frontend dApp |

## Security

- Built on OpenZeppelin Contracts v5 (battle-tested primitives)
- ERC-1726 dividend math (proven across billions in TVL)
- Each vault is individually renounced — no admin keys survive deployment
- Factory is renounced after protocol launch
- Pre-launch audit (see [security issue](https://github.com/CryptoSI-DAO/diamond-hands-protocol/issues/8))

## Origin

Forked from [BSC-Hourglass-Dapp](https://github.com/safestartprotocol/BSC-Hourglass-Dapp) (the "Proof of Weak Hands" / Hourglass pattern). The original native-coin bonding curve has been rewritten as an ERC-4626 tokenized vault with modern OpenZeppelin security primitives, dividend distribution, and a permissionless factory.

## ⚠️ Known Technical Debt

The contracts in this repo are legacy code from the original fork. These items must be addressed before any production deployment. Tracked as part of the pre-launch audit ([#8](https://github.com/CryptoSI-DAO/diamond-hands-protocol/issues/8)).

1. **Two Solidity versions** — `1_Hourglass.sol` is 0.6.12, `2_Gauntlets.sol` is 0.4.25. Both should be unified (target: 0.8.24+).
2. **Hardcoded BSC addresses** — `Gauntlet` references a hardcoded Hourglass address (`0x0c22…12D3`) and developer address (`0xf2C5…a48a`) from the original BSC deployment. These must be parameterized for Base.
3. **No overflow protection in Gauntlet** — `extendLock()` does `unlockAfterNDays + _howManyDays` with no SafeMath. Fixed automatically by upgrading to 0.8+ (built-in overflow reverts).
4. **Deprecated `now` keyword** — `Gauntlet` uses `now` (alias for `block.timestamp`), deprecated since 0.7. Fixed automatically by upgrading to 0.8+.
5. **`.transfer()` gas stipend** — Both contracts use `.transfer()` (2300 gas). Will revert if the recipient is a contract with expensive receive logic. Replace with `.call()` + explicit reentrancy guard.
6. **No test suite** — Zero tests, no build framework. Unit tests ([#4](https://github.com/CryptoSI-DAO/diamond-hands-protocol/issues/4)) and fuzz/invariant tests ([#5](https://github.com/CryptoSI-DAO/diamond-hands-protocol/issues/5)) are tracked separately.

## ⚠️ Risk Disclosure

Every Diamond Hands Vault is a **zero-sum game** by design. Payouts to diamond hands come from paper hands' taxes — not from external yield. Users can lose tokens. All vaults are renounced at launch. No team. No roadmap. No expectation of financial return. Entertainment purposes only.

## License

MIT

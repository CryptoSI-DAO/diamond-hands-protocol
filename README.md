# 💎 SPX6900 Diamond Hands Vault

> *Stop trading. Believe in something. Get paid when others don't.*

An ERC-4626 tokenized vault for **SPX6900 ($SPX)** on **Base Network** where paper hands fund diamond hands. Every deposit and withdrawal pays a tax — the bulk flows to holders as dividends, a portion is burned to `0x...dead` forever.

## The Mechanic

| Action | Tax | → Dividends | → Burn |
|---|---|---|---|
| **Deposit** | 5% | 3% to all holders | 2% burned |
| **Withdraw** | 10% | 8% to all holders | 2% burned |

The longer you hold, the more dividends you accrue from every paper-hand exit. Every burn adds to the eternal 6.9% already at the dead address. Zero dev fee. Zero team allocation. Zero governance.

## Architecture

- **ERC-4626** (OpenZeppelin v5) — battle-tested tokenized vault standard
- **ERC-1726** dividend math — proven across billions in TVL
- **SafeERC20** — safe SPX token handling
- **ReentrancyGuard + Pausable** — security primitives
- **Ownable2Step** — deploy, verify, renounce

```
SPXDiamondHandsVault
├── ERC4626              (vault deposit/redeem/share math)
├── DividendPayingToken  (ERC-1726 per-share dividend accrual)
├── ReentrancyGuard      (reentrancy protection)
├── Pausable             (emergency stop)
└── Ownable2Step         (safe renunciation at launch)
```

## Contracts

| Token | Chain | Address |
|---|---|---|
| SPX6900 | Ethereum | `0xE0f63A424a4439cBE457D80E4f4b51aD25b2c56C` |
| SPX6900 | **Base** | `0x50dA645f148798F68EF2d7dB7C1CB22A6819bb2C` |
| Vault | Base | *(deploy pending v0.6.9)* |

## Origin

Forked from [BSC-Hourglass-Dapp](https://github.com/safestartprotocol/BSC-Hourglass-Dapp) (the "Proof of Weak Hands" / Hourglass pattern). The original contract logic is being rewritten from a native-coin bonding curve into an ERC-20 tokenized vault with modern OpenZeppelin security primitives.

## Frontend

The dApp frontend lives in a separate repo: [`CryptoSI-DAO/spx-diamond-hands-ui`](https://github.com/CryptoSI-DAO/spx-diamond-hands-ui)

This repo stays compact and audit-friendly — contracts, tests, deploy scripts, and the subgraph. The frontend imports the ABI and deployed addresses from here.

## ⚠️ Risk Disclosure

This is a **zero-sum game** by design. Payouts to diamond hands come from paper hands' exit taxes — not from external yield. You can lose SPX. The contract will be renounced at launch. No team. No roadmap. No expectation of financial return. Entertainment purposes only.

## License

MIT

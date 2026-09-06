# Audit Scope — Diamond Hands Protocol (DHP)

**Repository:** https://github.com/CryptoSI-DAO/diamond-hands-protocol
**Branch:** `feat/v1-core-contracts`
**Commit:** (filled at audit kickoff)
**Solidity version:** 0.8.28 (`+commit.7893614a`)
**OpenZeppelin Contracts:** v5.1.0 (`release-v5.1`)

## In Scope (3 contracts, all on Base Sepolia)

| Contract | Path | LOC | Address (Base Sepolia) |
|---|---|---|---|
| **DHPImplementation** | `src/contracts/DHPImplementation.sol` | ~530 | `0x562e4ECa55ccA4Bb411a81f2605F992C00395f0f` |
| **DHPFactory** | `src/contracts/DHPFactory.sol` | ~190 | `0xee1e2343E513736f29ceeF24071B63874661273F` |
| **DHPFeeCollector** | `src/contracts/DHPFeeCollector.sol` | ~190 | `0x11F41D72E8e612b94b831Df38B12F5Bc3D58D87C` |

Plus the external interface `src/interfaces/IDHPVault.sol` (~100 LOC).

## Out of Scope

- `test/` directory (mocks, fixtures — Foundry tests)
- `script/` directory (deployment / verification scripts)
- `lib/` directory (OpenZeppelin Contracts v5.1, forge-std — third-party)
- Off-chain components (frontend dApp at `diamond-hands-protocol-ui`, GoPlus/Basescan eligibility scripts)
- Integration with third-party tokens (e.g. SPX6900) — only the protocol's interaction with standard ERC-20s is in scope

## High-Risk Areas (focus here first)

| Area | Concern |
|---|---|
| **`DHPImplementation.deposit()` / `mint()`** | CEI pattern, anti-FOT balance check, tax split accounting. Order matters — see "Order-of-operations" section below. |
| **`DHPImplementation._accrueDividend()` / `_settleDividend()`** | Synthetix StakingRewards math. Off-by-one in `rewardPerTokenStored` would silently drain dividends. |
| **`DHPImplementation._distributeTax()`** | Three-way split (dividends/protocol fee/burn). Rounding losses accumulate. |
| **`DHPImplementation._update()` (ERC-20 hook)** | Called on every transfer. Reverts here break ERC-20 compliance — must call `_settleDividend` cheaply. |
| **`DHPFactory.createVault()`** | EIP-1167 clone deploy + `decimals()` try/catch. Re-initialisation guard. Tax config validation. |
| **`DHPFeeCollector.sweep()`** | Reentrancy via malicious token's `transfer` hook. Fee-on-transfer tokens that report `balanceOf` differently. |

## Order-of-operations — **critical invariant**

In **all four** user-facing methods (`deposit`, `mint`, `withdraw`, `redeem`), the flow is:

1. Pull underlying from user (or burn shares)
2. `safeTransfer` net to receiver (where applicable)
3. `_distributeTax(tax)` — sends fee + burn OUT, keeps dividend portion in vault
4. `_accrueDividend(tax)` — bumps `rewardPerTokenStored` using post-burn, post-distribute supply
5. `_mint` shares (deposits only)

The original v1 implementation had `_accrueDividend` and `_convertToShares` reading `totalSupply` and `totalAssets` BEFORE `_distributeTax` sent out the fee + burn, which caused new depositors to receive fewer shares than they should have (diluted by soon-to-leave tokens). The v1.1 fix is in commit history and verified by tests + on-chain smoke test.

## Test Coverage (54 tests, all passing)

- **15** `DHPImplementation.t.sol` — first-deposit, tax split correctness, dividend accrual, pro-rata distribution, claim flow, withdraw/redeem, transfer accounting, fee-on-transfer rejection, pause, zero-amount, zero-address, share-price non-inflation
- **20** `DHPFactory.t.sol` — clone deploy, registration, dual vaults, event emission, duplicate-token rejection, zero-token rejection, tax-config validation (entry/exit/dividend bounds), zero-tax config, max-valid-tax config, decimals boundaries, reverting decimals, Ownable2Step, EIP-1167 45-byte proxy size, verified-flag admin
- **19** `DHPFeeCollector.t.sol` — initial state, zero-treasury rejection, sweep full/zero/owner-only, sweepTo, per-token overrides, default treasury update, native ETH sweep, hooks, view helpers, total-swept accumulation

Run: `forge test` (no flags needed).

## Reproduction

```bash
git clone --branch feat/v1-core-contracts https://github.com/CryptoSI-DAO/diamond-hands-protocol
cd diamond-hands-protocol
forge install
forge test -vv
```

## Live on Base Sepolia

| Contract | Address | Sourcify |
|---|---|---|
| DHPImplementation | `0x562e4ECa55ccA4Bb411a81f2605F992C00395f0f` | ✅ exact_match |
| DHPFactory | `0xee1e2343E513736f29ceeF24071B63874661273F` | ✅ exact_match |
| DHPFeeCollector | `0x11F41D72E8e612b94b831Df38B12F5Bc3D58D87C` | ✅ exact_match |

Smoke-test tx hashes and on-chain evidence are in `deployments.json`.

## Contact

- Telegram: `@CryptoSI`
- Email: TBD (responsible disclosure channel — see `SECURITY.md`)

## Pre-audit TODO (CISO checklist)

- [ ] Final testnet rehearsal after audit findings integrated
- [ ] Deploy to Base mainnet at known deterministic addresses (CREATE deterministic — same deployer + nonce ⇒ same address on every chain)
- [ ] Verify all 3 contracts on Base mainnet Sourcify (same script, swap chainId 8453 for 84532)
- [ ] Renounce factory + feeCollector ownership to DAO multisig (or per launch plan)
- [ ] Publish audit report and findings response

---
*This document is the source of truth for the audit scope. Any change to in-scope contracts requires audit re-scope.*
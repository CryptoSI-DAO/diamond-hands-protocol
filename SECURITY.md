# Security Policy — Diamond Hands Protocol (DHP)

## Reporting a Vulnerability

Please report security vulnerabilities to **security@cryptosi.org** (PGP key TBD). Do **not** file public GitHub issues for security-sensitive findings.

We aim to:
- **Acknowledge** within 48 hours
- **Provide a triage assessment** within 5 business days
- **Disclose a fix timeline** within 10 business days for high/critical issues

## Scope

Smart contracts in this repository:

| Contract | Path |
|---|---|
| DHPImplementation | `src/contracts/DHPImplementation.sol` |
| DHPFactory | `src/contracts/DHPFactory.sol` |
| DHPFeeCollector | `src/contracts/DHPFeeCollector.sol` |
| IDHPVault (interface) | `src/interfaces/IDHPVault.sol` |

For each audit round, see `AUDIT_SCOPE.md` for the live deployment addresses being audited.

Out of scope: `test/`, `script/`, `lib/`, frontend dApp.

## Trust Model

- **No admin keys survive deployment.** Each vault is **individually renounced** at construction — no owner, no pause, no setters. The factory and fee collector are `Ownable2Step` and intended to be **renounced post-launch**.
- **Users do not need to trust CryptoSI DAO** for their funds to be safe. Renounced factories + fee-on-transfer rejection + immutable tax splits are the main protections.
- **Honesty disclaimer:** DHP is a zero-sum game. Taxes from paper hands fund diamond hands — there is no external yield. Users can lose tokens. This is not an investment product.

## Known Considerations (Pre-Audit Acknowledgements)

1. **Share price inflation after first deposit.** The first deposit's dividend portion (e.g., 350 of 500 SPX tax for a 5% entry / 70% dividend-share config) sits in the vault as the initial dividend pool. This causes subsequent depositors to receive **fewer shares than 1:1 with their net assets** (the exchange rate has already risen). This is **intended behaviour** — it correctly reflects that existing shareholders own the dividend pool — but it's a sharp edge that deserves audit attention.

2. **Rounding losses** in `_distributeTax` accumulate as dust in the vault. Total never exceeds `(numTaxEvents × 3) × 1 wei` of the underlying token.

3. **`Pausable` becomes inert after factory renounce** — anyone could still call `pause()` on a vault, but with no admin key to call `unpause()`, the vault is permanently disabled. This is a DoS vector for individual vaults. Mitigation: not pause per-vault via the factory-owner once we know the contract is sound. **Open audit question: should `pause` be removed entirely?**

4. **The factory is `Ownable2Step`** (not `Ownable`). After `transferOwnership`, the new owner must explicitly call `acceptOwnership()`. This is a safety net against address typos but means the existing owner has full power until renounce.

## Disclosure Process

1. Researcher submits report to `security@cryptosi.org`
2. CryptoSI acknowledges + triages within 5 business days
3. Joint development of fix + test
4. Deploy to Base Sepolia + smoke-test
5. Deploy to mainnet + verify on Sourcify
6. Coordinated public disclosure (researcher credited, fix announcement)

## Bug Bounty

**Coming soon** after mainnet launch + audit completion. Scope and reward tiers will be published in this file.

---
*Last updated: 2026-09-05 — pre-mainnet, pre-audit*
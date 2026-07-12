# Security Policy

## Reporting a Vulnerability

The Diamond Hands Protocol team takes security bugs seriously. We appreciate your efforts to responsibly disclose your findings and will make every effort to acknowledge your contributions.

### How to Report

**Do NOT open a public GitHub issue for security vulnerabilities.**

Instead, please report vulnerabilities privately:

1. **Preferred:** Use GitHub's [Private Vulnerability Reporting](https://github.com/CryptoSI-DAO/diamond-hands-protocol/security/advisories/new) feature on this repository.
2. **Email:** Send details to **security@cryptosidao.org** with the subject line `[DHP SECURITY] — <brief summary>`.
3. **PGP:** If you have sensitive exploit details, request our public key by emailing the above address first.

### What to Include

To help us triage quickly, please include:

- **Contract name and file** (e.g., `Hourglass` in `contracts/1_Hourglass.sol`)
- **Commit hash** you reviewed against
- **Description** of the vulnerability and its potential impact
- **Steps to reproduce** (code snippet, transaction calldata, or Foundry/Hardhat test case)
- **Suggested fix** (optional, but appreciated)
- **Your contact info / handle** for acknowledgment

---

## Scope

### In Scope

- Smart contracts in this repository (`contracts/` directory)
- Contract interaction logic in `assets/lib/dapp.js`, `assets/lib/gauntlet.js`
- Deployed instances of the above contracts on Base Network

### Out of Scope

- Vulnerabilities in third-party dependencies (jQuery, Bootstrap, Web3.js, OpenZeppelin — report these upstream)
- Frontend XSS, CSRF, or other web vulnerabilities not directly impacting contract state
- Social engineering, phishing, or physical attacks
- Denial of service attacks against the RPC provider or Base Network infrastructure
- Issues already reported in a previous advisory (check [existing advisories](https://github.com/CryptoSI-DAO/diamond-hands-protocol/security/advisories))
- Theoretical vulnerabilities without a concrete exploitation path

---

## Response Timeline

| Milestone | Target |
|-----------|--------|
| **Acknowledgment** | Within 48 hours of report |
| **Initial triage** | Within 5 business days |
| **Status update** | Every 7 days until resolved |
| **Fix deployed** | Depends on severity (see below) |

### Severity-Based SLA

| Severity | Target Fix Window |
|----------|-------------------|
| **Critical** (fund loss, permanent lock) | 48 hours — emergency response |
| **High** (exploitable fund loss under specific conditions) | 7 days |
| **Medium** (state corruption, griefing) | 30 days |
| **Low / Informational** (best practice, gas) | Next release |

---

## Safe Harbor

We will not pursue legal action against security researchers who:

- Make a good-faith effort to avoid privacy violations, destruction of data, and interruption or degradation of services
- Do not access or modify data that does not belong to them
- Give us reasonable time to remediate before any public disclosure
- Do not exploit the vulnerability for financial gain, beyond any agreed bounty

---

## Reward / Acknowledgment

- DHP is a community project and does not currently run a formal bug bounty program.
- Researchers who report valid, in-scope vulnerabilities will be **publicly acknowledged** in the security advisory (unless they prefer to remain anonymous).
- We may offer discretionary rewards in $LISA or stablecoins for **Critical** or **High** severity findings at our discretion.

---

## Public Disclosure

We believe in transparency. Once a vulnerability is fixed, we will:

1. Publish a [GitHub Security Advisory](https://github.com/CryptoSI-DAO/diamond-hands-protocol/security/advisories) with full technical details
2. Credit the reporter (with permission)
3. Request a CVE if applicable

We kindly request that reporters **do not publicly disclose** vulnerabilities until a fix has been deployed and we have agreed on a disclosure timeline.

---

## Contact

| Role | Contact |
|------|---------|
| Security reports | security@cryptosidao.org |
| General questions | [GitHub Issues](https://github.com/CryptoSI-DAO/diamond-hands-protocol/issues) |
| Team | [CryptoSI DAO](https://github.com/CryptoSI-DAO) |

---

*This policy is adapted from responsible disclosure best practices. Last updated: 2026-07-12.*

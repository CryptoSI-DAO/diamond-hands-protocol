# Build & Test Evidence Pack

**Pinned commit:** [`f44fb13`](https://github.com/CryptoSI-DAO/diamond-hands-protocol/commit/f44fb13db0a94f63a06732ac8b6ec8156e93ede4)
**Date:** 2026-07-12
**Compiler:** Official `ethereum/solc` Docker images (exact versions below)

---

## Toolchain

| Component | Version |
|-----------|---------|
| `solc` (1_Hourglass.sol) | `0.6.12+commit.27d51765.Linux.g++` |
| `solc` (2_Gauntlets.sol) | `0.4.25+commit.0db513f2.Linux.g++` |
| Docker | Standard `ethereum/solc` images from Docker Hub |
| Build framework | **None** — raw `solc` compilation (no Hardhat/Foundry) |
| Package manager | **N/A** — no `package.json` or `requirements.txt` for contracts |

> ⚠️ The repo has **no build framework** (no Hardhat, Foundry, or Truffle configuration). Contracts are compiled individually with standalone `solc` matching each file's pragma. The legacy frontend uses plain `<script>` tags (no bundler, no `package-lock.json`).

---

## Source File Integrity

| File | SHA-256 | Lines |
|------|---------|-------|
| `contracts/1_Hourglass.sol` | `d740ba176f63a2d70a25e4d2f319ca4e6b558de00ffe68e8a07e1c7c486c1266` | 504 |
| `contracts/2_Gauntlets.sol` | `9bd74bf236dabe925cac09bf469907448d79776d6419a0ea22b7b47450b2e548` | 93 |

---

## Compilation Results

### `1_Hourglass.sol` — solc 0.6.12

```
Compiler run successful. No warnings, no errors.
```

| Contract | Deployed Bytecode Size | Notes |
|----------|----------------------|-------|
| `Hourglass` | 7,982 bytes | Within EIP-170 limit (24,576 bytes) |
| `SafeMath` | ~60 bytes (library) | Inlined into Hourglass; not independently deployable |

**Output:** `audit/compile_hourglass.json` (ABI + bytecode + AST + source maps)

### `2_Gauntlets.sol` — solc 0.4.25

```
Compiler run successful. No warnings, no errors.
```

| Contract | Deployed Bytecode Size | Notes |
|----------|----------------------|-------|
| `GauntletManager` | 5,856 bytes | Factory that deploys Gauntlet instances |
| `Gauntlet` | 4,292 bytes | Time-locked vault (deployed via `GauntletManager.create()`) |
| `HourglassInterface` | 0 bytes (interface) | Not deployable — used by `Gauntlet` for external calls |

**Output:** `audit/compile_gauntlets.json` (ABI + bytecode + source maps)

---

## Test Results

### ⚠️ No Test Suite Exists

The repository contains **zero tests** at the pinned commit. There is:

- No `test/` directory
- No Hardhat test files (`*.test.js`, `*.spec.ts`)
- No Foundry test files (`*.t.sol`)
- No deployment scripts
- No test configuration

**Related issues tracking test creation:**
- [#4 — Write comprehensive unit tests](https://github.com/CryptoSI-DAO/diamond-hands-protocol/issues/4)
- [#5 — Write fuzz / invariant tests](https://github.com/CryptoSI-DAO/diamond-hands-protocol/issues/5)

---

## Gas Report

**Not available.** No gas reporting tooling (`hardhat-gas-reporter`, `forge test --gas-report`) is configured because no test framework exists.

---

## Coverage Report

**Not available.** No coverage tooling (`solidity-coverage`, `forge coverage`) is configured.

---

## Key Findings for Auditor

These items surfaced during evidence pack preparation and should be on the auditor's radar:

1. **Two Solidity versions (0.6.12 + 0.4.25)** — Cross-contract interaction between `Hourglass` (0.6.12) and `Gauntlet` (0.4.25) should be validated. The `Gauntlet` calls into `Hourglass` via `HourglassInterface` using `.value()` syntax (deprecated in 0.6+).

2. **No constructor arguments** — `Hourglass` has a parameterless constructor that sets `deployer = msg.sender`. No way to transfer deployer role or renounce ownership.

3. **Hardcoded addresses in Gauntlet** — `B1VSContract` (`0x0c22C33eaEFC961Ed529a6Af4654B6c2f51c12D3`) and `developer` (`0xf2C579082fE10d57331d0Cd66843C4D6777eA48a`) are hardcoded constants from the original BSC deployment. These **must** be parameterized before Base deployment.

4. **`now` keyword in Gauntlet** — Uses deprecated `now` (alias for `block.timestamp`), which is miner/validator manipulable. Relevant for time-lock semantics.

5. **No SafeMath in Gauntlet** — `Gauntlet.sol` (0.4.25) has no overflow protection on `extendLock()` arithmetic (`unlockAfterNDays + _howManyDays`).

6. **Fallback function in Gauntlet** — `function() public payable {}` accepts arbitrary ETH with no restrictions.

7. **Direct `.transfer()` calls** — Both contracts use `.transfer()` (2300 gas stipend), which can fail if the recipient is a contract with expensive receive logic.

8. **Deprecated `.value()` syntax** — `Gauntlet.sol` uses `B1VSContract.buy.value(msg.value)(developer)` — pre-0.6 syntax that emits a compiler note.

---

## Reproducibility

To reproduce this evidence pack:

```bash
# Clone and checkout the pinned commit
git clone https://github.com/CryptoSI-DAO/diamond-hands-protocol.git
cd diamond-hands-protocol
git checkout f44fb13

# Compile Hourglass (solc 0.6.12)
docker run --rm -v "$(pwd):/src" ethereum/solc:0.6.12 \
  --combined-json abi,bin,bin-runtime,srcmap,srcmap-runtime,ast \
  --overwrite /src/contracts/1_Hourglass.sol > audit/compile_hourglass.json

# Compile Gauntlets (solc 0.4.25)
docker run --rm -v "$(pwd):/src" ethereum/solc:0.4.25 \
  --combined-json abi,bin,bin-runtime,srcmap,srcmap-runtime \
  --overwrite /src/contracts/2_Gauntlets.sol > audit/compile_gauntlets.json

# Verify file integrity
sha256sum contracts/1_Hourglass.sol contracts/2_Gauntlets.sol
# Expected: d740ba...486c1266 and 9bd74b...50b2e548
```

---

*Generated 2026-07-12 against commit `f44fb13`. This evidence pack is commit-bound and should be regenerated if the code changes.*

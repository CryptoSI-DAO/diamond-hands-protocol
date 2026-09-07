// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {DHPImplementation} from "./DHPImplementation.sol";
import {IDHPVault} from "../interfaces/IDHPVault.sol";

/// @title  DHPFactory
/// @notice Permissionless deployment of Diamond Hands Vaults. One per ERC-20
///         on Base (or whichever chain this factory is deployed to).
/// @dev    Each `createVault()` call:
///           1. Validates the underlying token against the eligibility gate.
///           2. Clones the canonical `DHPImplementation` via EIP-1167.
///           3. Calls `initialize()` on the clone with the chosen tax config.
///           4. Records the (token → vault) mapping for frontend indexing.
///
///         Eligibility gate (configured at deploy time):
///           • Token must expose `decimals()` returning 0–18
///           • Caller must pass a valid `TaxConfig` (see bounds below)
///           • A vault for this token must not already exist
///
///         Off-chain checks (BEFORE the on-chain tx) — done by the frontend
///         or factory helper script — should verify:
///           • GoPlus honeypot check passes (buy_tax=0, sell_tax=0)
///           • Sufficient Uniswap V3 liquidity on Base
///           • Minimum holder count
///           • Source verified on Basescan
///
///         Tax config bounds (immutable after factory deploy):
///           • entryTaxBps     ∈ [0, MAX_ENTRY_TAX_BPS=1000]   (0–10%)
///           • exitTaxBps      ∈ [0, MAX_EXIT_TAX_BPS=2500]    (0–25%)
///           • dividendShareBps ∈ [0, MAX_DIVIDEND_SHARE_BPS=9000] (0–90%)
///           • dividendShareBps + 50 (protocol fee) ≤ 10000
///
///         The factory itself is `Ownable2Step` and is intended to be
///         RENOUNCED post-launch (`renounceOwnership()` to 0x0). The only
///         owner-gated function is `setVerified(token, bool)` for frontend
///         curation; renouncing freezes it at the last set of verified tokens.
contract DHPFactory is Ownable2Step, ReentrancyGuardTransient {
    using Clones for address;

    // ──────────────────────────────────────────────────────────────────────────
    // Immutable configuration (set at deploy, never mutable)
    // ──────────────────────────────────────────────────────────────────────────

    /// @notice Canonical implementation every clone proxies to.
    address public immutable implementation;

    /// @notice Protocol fee recipient (0.5% of every tax).
    address public immutable feeCollector;

    // ──────────────────────────────────────────────────────────────────────────
    // Tax config bounds (immutable; mirrors the vault's own checks)
    // ──────────────────────────────────────────────────────────────────────────

    uint16 public constant MAX_ENTRY_TAX_BPS = 1_000;   // 10%
    uint16 public constant MAX_EXIT_TAX_BPS = 2_500;    // 25%
    uint16 public constant MAX_DIVIDEND_SHARE_BPS = 9_000; // 90%
    uint16 public constant PROTOCOL_FEE_BPS = 50;      // 0.5%

    /// @dev Creation fee to prevent griefing the registry. ~$3 at current ETH
    ///      prices — high enough to make mass-griefing expensive (~13K vaults
    ///      per 1 ETH), low enough that legitimate deploys aren't priced out.
    ///      All proceeds go to the DAO treasury (the feeCollector).
    uint256 public constant VAULT_CREATION_FEE = 0.001 ether;

    // ──────────────────────────────────────────────────────────────────────────
    // Mutable configuration (DAO-gated, intended to freeze post-launch)
    // ──────────────────────────────────────────────────────────────────────────

    /// @dev Minimum acceptable `decimals()` return value.
    uint8 public minAcceptedDecimals;

    /// @dev Maximum acceptable `decimals()` return value.
    uint8 public maxAcceptedDecimals;

    // ──────────────────────────────────────────────────────────────────────────
    // Registry state
    // ──────────────────────────────────────────────────────────────────────────

    /// @dev Mapping: underlying token → its vault address (zero if none).
    mapping(address token => address vault) public getVault;

    /// @dev Mapping: underlying token → DAO curation flag (frontend-side only).
    mapping(address token => bool verified) public isVerified;

    /// @dev Enumerable list of every vault address ever deployed.
    address[] public allVaults;

    /// @dev Mapping: vault address → its underlying token.
    mapping(address vault => address token) public getToken;

    // ──────────────────────────────────────────────────────────────────────────
    // Structs
    // ──────────────────────────────────────────────────────────────────────────

    struct TaxConfig {
        uint16 entryTaxBps;
        uint16 exitTaxBps;
        uint16 dividendShareBps;
        /// @dev v1.2.1: If true, the vault accepts tokens with FOT/hook behaviour
        ///      (rebasing, gas-burn, marketing-fee). Default: false.
        bool acceptFeesFromTransfer;
    }

    // ──────────────────────────────────────────────────────────────────────────
    // Events
    // ──────────────────────────────────────────────────────────────────────────

    event VaultCreated(
        address indexed token,
        address indexed vault,
        uint16 entryTaxBps,
        uint16 exitTaxBps,
        uint16 dividendShareBps
    );
    event VerifiedSet(address indexed token, bool verified);

    // ──────────────────────────────────────────────────────────────────────────
    // Errors
    // ──────────────────────────────────────────────────────────────────────────

    error TokenAlreadyHasVault(address existing);
    error VaultAlreadyExistsForToken(address token);
    error InvalidTaxConfig();
    error InvalidToken();
    error InvalidDecimals(uint8 returned);
    error InsufficientCreationFee();
    error FeeTransferFailed();

    // ──────────────────────────────────────────────────────────────────────────
    // Constructor
    // ──────────────────────────────────────────────────────────────────────────

    /// @param implementation_ Canonical DHPImplementation deployed separately.
    /// @param feeCollector_  Protocol fee recipient (immutable).
    /// @param minDecimals     Lower bound for token `decimals()` return.
    /// @param maxDecimals     Upper bound for token `decimals()` return.
    constructor(
        address implementation_,
        address feeCollector_,
        uint8 minDecimals,
        uint8 maxDecimals
    ) Ownable(msg.sender) {
        if (implementation_ == address(0) || feeCollector_ == address(0)) {
            revert InvalidToken();
        }
        if (minDecimals > maxDecimals || maxDecimals > 18) {
            revert InvalidToken();
        }
        implementation = implementation_;
        feeCollector = feeCollector_;
        minAcceptedDecimals = minDecimals;
        maxAcceptedDecimals = maxDecimals;
    }

    // ──────────────────────────────────────────────────────────────────────────
    // Vault creation
    // ──────────────────────────────────────────────────────────────────────────

    /// @notice Deploy a new Diamond Hands Vault for `token`.
    /// @param  token   The underlying ERC-20 the vault will wrap.
    /// @param  cfg     Tax configuration.
    /// @return vault   The address of the newly created clone.
    /// @dev    Requires `msg.value >= VAULT_CREATION_FEE` (0.001 ETH).
    ///         Excess ETH is refunded. The fee goes to the DAO treasury
    ///         (feeCollector) to prevent griefing the registry — without
    ///         a fee, anyone can call createVault() for any token (including
    ///         spam tokens they create themselves) and bloat `allVaults` until
    ///         off-chain indexers (The Graph, frontend loops) hit gas limits.
    function createVault(address token, TaxConfig calldata cfg)
        external
        payable
        nonReentrant
        returns (address vault)
    {
        // Anti-grief: require EXACTLY the creation fee (no refund). Refunding
        // excess was removed in v1.2 because contracts with a reverting
        // receive() function could grief by sending excess and trapping the
        // refund inside the factory forever. Requiring the exact fee also
        // avoids the silent-fee-loss risk if the refund call reverts for any
        // reason (out-of-gas in caller, etc.). Excess ETH is no longer accepted.
        if (msg.value != VAULT_CREATION_FEE) {
            revert InsufficientCreationFee();
        }

        if (token == address(0)) revert InvalidToken();
        if (getVault[token] != address(0)) revert VaultAlreadyExistsForToken(token);

        // Validate tax config against immutable bounds.
        if (cfg.entryTaxBps > MAX_ENTRY_TAX_BPS) revert InvalidTaxConfig();
        if (cfg.exitTaxBps > MAX_EXIT_TAX_BPS) revert InvalidTaxConfig();
        if (cfg.dividendShareBps > MAX_DIVIDEND_SHARE_BPS) revert InvalidTaxConfig();
        if (cfg.dividendShareBps + PROTOCOL_FEE_BPS > 10_000) revert InvalidTaxConfig();

        // Validate the token's `decimals()` return. We require a sane answer
        // between minDecimals and maxDecimals (default [0, 18]). Tokens that
        // revert or return something out-of-range are rejected here.
        // (v1.2.2: the dead empty `assembly {}` block that used to sit here —
        // v1.0 audit M-3 — has been removed; the try/catch below is the
        // actual implementation.)
        uint8 dec;
        try IERC20Metadata(token).decimals() returns (uint8 d) {
            dec = d;
        } catch {
            revert InvalidToken();
        }
        if (dec < minAcceptedDecimals || dec > maxAcceptedDecimals) {
            revert InvalidDecimals(dec);
        }

        // Clone + initialise. The minimum first deposit is set per-vault based
        // on the token's decimals (10^decimals, so 1.0 token unit). This
        // ensures the inflation-attack guard is meaningful for all decimal
        // configurations (1.0 SPX for 6-decimal tokens, 1.0 wstETH for
        // 18-decimal tokens). See audit finding M-NEW-2.
        //
        // v1.2.1: `acceptFeesFromTransfer` is exposed as a per-vault flag
        // (audit M-CARRIED-1: previously, tokens with legitimate hooks were
        // rejected). Default: false (strict mode, rejects FOT tokens).
        // Factory owner can set true for known-hook tokens.
        uint256 minFirstDeposit = 10 ** IERC20Metadata(token).decimals();
        bool acceptFeesFromTransfer = cfg.acceptFeesFromTransfer;
        vault = implementation.clone();
        DHPImplementation(payable(vault)).initialize(
            IERC20(token),
            feeCollector,
            cfg.entryTaxBps,
            cfg.exitTaxBps,
            cfg.dividendShareBps,
            minFirstDeposit,
            acceptFeesFromTransfer
        );

        // Register.
        getVault[token] = vault;
        getToken[vault] = token;
        allVaults.push(vault);

        // Forward the creation fee to the DAO treasury.
        if (VAULT_CREATION_FEE > 0) {
            (bool ok, ) = payable(feeCollector).call{value: VAULT_CREATION_FEE}("");
            if (!ok) revert FeeTransferFailed();
        }

        emit VaultCreated(token, vault, cfg.entryTaxBps, cfg.exitTaxBps, cfg.dividendShareBps);
    }

    // ──────────────────────────────────────────────────────────────────────────
    // Frontend curation (DAO-gated; inert post-renounce)
    // ──────────────────────────────────────────────────────────────────────────

    /// @notice Mark a token as DAO-verified for frontend curation.
    ///         The frontend shows verified vaults by default; unverified
    ///         vaults still work but are flagged.
    function setVerified(address token, bool verified_) external onlyOwner {
        isVerified[token] = verified_;
        emit VerifiedSet(token, verified_);
    }

    // ──────────────────────────────────────────────────────────────────────────
    // View helpers
    // ──────────────────────────────────────────────────────────────────────────

    /// @notice Total number of vaults ever deployed (monotonic).
    function vaultCount() external view returns (uint256) {
        return allVaults.length;
    }

    /// @notice Returns the vault address at index `i` in the registry.
    function allVaultsAt(uint256 i) external view returns (address) {
        return allVaults[i];
    }
}
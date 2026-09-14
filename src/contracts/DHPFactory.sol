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
/// @notice Permissionless deployment of Diamond Hands Vaults. Vault creation
///         is FREE-MARKET: any wallet may create vaults for any token,
///         including multiple vaults for the same token (#27 revision).
///         The curator is the single exception — capped at ONE vault per
///         token, keeping the curated layer squat-proof.
/// @dev    Each `createVault()` call:
///           1. Validates the underlying token against the eligibility gate.
///           2. Clones the canonical `DHPImplementation` via EIP-1167.
///           3. Calls `initialize()` on the clone with the chosen tax config.
///           4. Records the (token → vault) mapping for frontend indexing.
///
///         Eligibility gate (configured at deploy time):
///           • Token must expose `decimals()` returning 0–18
///           • Caller must pass a valid `TaxConfig` (see bounds below)
///           • Curator only: max one vault per token — there are no other
///             per-token creation limits (#27 free-market policy)
///           • Payment: exact 0.001 ETH — waived for CRDD tier members (#28)
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
///         The factory itself is `Ownable2Step`. Owner-gated functions:
///         `setVerified(token, bool)` for frontend curation and
///         `setCurator(address)` for the #27 exemption holder; renouncing
///         freezes both at their last values.
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

    /// @dev Creation fee to prevent griefing the registry. ~$12-16 at current
    ///      ETH prices — high enough to make mass-griefing expensive (250
    ///      vaults per 1 ETH), low enough that legitimate deploys aren't
    ///      priced out. CRDD tier members (#28) pay nothing instead.
    ///      All proceeds go to the DAO treasury (the feeCollector).
    uint256 public constant VAULT_CREATION_FEE = 0.004 ether;

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
    ///      The FIRST vault created for the token — duplicates (allowed for
    ///      anyone since #27) never overwrite it; the curator's vault
    ///      registers in `getCuratedVault` when it is not the first.
    mapping(address token => address vault) public getVault;

    /// @dev Mapping: underlying token → the curator's vault (#27) when it is
    ///      NOT the token's first vault. Zero when the curator created the
    ///      canonical one or has not created for the token.
    mapping(address token => address vault) public getCuratedVault;

    /// @dev Mapping: token → curator cap consumed flag (#27). Set on the
    ///      curator's FIRST create for the token via ANY path — the cap
    ///      binds the curator's address, not the create path.
    mapping(address token => bool created) public curatorVaultCreated;

    /// @notice The curator address (#27): the ONLY wallet capped at one vault
    ///         per token. Owner-settable (D1); renouncing factory ownership
    ///         freezes it at its last value.
    address public curator;

    // ──────────────────────────────────────────────────────────────────────────
    // CRDD minting tier (#28)
    // ──────────────────────────────────────────────────────────────────────────

    /// @notice CRDD token gating the free-minting tier. ZERO = tier disabled
    ///         (deploy default; everyone pays the per-vault fee). Owner-wired
    ///         once CRDD's address is final; renouncing freezes it.
    address public crddToken;

    /// @notice Balance of `crddToken` (in its own decimals) that unlocks
    ///         unlimited fee-free vault creation. Set together with
    ///         `crddToken`; immutable between owner calls.
    uint256 public crddTierThreshold;

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

    /// @notice #27: emitted ONLY when the curator used the one-per-token
    ///         exemption (i.e. a vault for this token already existed).
    event CuratedVaultCreated(address indexed token, address indexed vault);
    event CuratorSet(address indexed previousCurator, address indexed newCurator);

    /// @notice #28: tier config wired or disabled (token=0, threshold=0).
    event CrddTierConfigured(address indexed token, uint256 threshold);

    /// @notice #28: a tier member minted a vault fee-free.
    event TierVaultCreated(address indexed creator, address indexed token, address indexed vault);

    // ──────────────────────────────────────────────────────────────────────────
    // Errors
    // ──────────────────────────────────────────────────────────────────────────

    error TokenAlreadyHasVault(address existing);
    error InvalidTaxConfig();
    error InvalidToken();
    error InvalidCurator();
    error InvalidDecimals(uint8 returned);
    error InsufficientCreationFee();
    error FeeTransferFailed();
    /// @notice #27: the curator already created their one allowed vault for
    ///         this token (the only per-token creation limit on the factory).
    error CuratorVaultAlreadyExists(address token);
    /// @notice #28: tier members must send 0 ETH; non-tier send exactly the fee.
    error UnexpectedMsgValue();
    /// @notice #28: setCrddToken called with a token but zero threshold.
    error InvalidCrddConfig();

    // ──────────────────────────────────────────────────────────────────────────
    // Constructor
    // ──────────────────────────────────────────────────────────────────────────

    /// @param implementation_ Canonical DHPImplementation deployed separately.
    /// @param feeCollector_  Protocol fee recipient (immutable).
    /// @param curator_       Curator for the #27 exemption (mandatory; non-zero).
    /// @param minDecimals     Lower bound for token `decimals()` return.
    /// @param maxDecimals     Upper bound for token `decimals()` return.
    constructor(
        address implementation_,
        address feeCollector_,
        address curator_,
        uint8 minDecimals,
        uint8 maxDecimals
    ) Ownable(msg.sender) {
        if (implementation_ == address(0) || feeCollector_ == address(0)) {
            revert InvalidToken();
        }
        if (curator_ == address(0)) {
            revert InvalidCurator();
        }
        if (minDecimals > maxDecimals || maxDecimals > 18) {
            revert InvalidToken();
        }
        implementation = implementation_;
        feeCollector = feeCollector_;
        curator = curator_;
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
    /// @dev    Payment (v1.4 #28): wallets holding `crddTierThreshold` CRDD
    ///         send exactly 0 ETH; everyone else sends exactly
    ///         `VAULT_CREATION_FEE` (0.004 ETH). No refunds in either path
    ///         (v1.2 griefing fix — reverting-receive callers could trap
    ///         refunds). Tier disabled while `crddToken` is zero.
    function createVault(address token, TaxConfig calldata cfg)
        external
        payable
        nonReentrant
        returns (address vault)
    {
        // ── #28 CRDD minting tier ────────────────────────────────────────────
        // Holders of `crddTierThreshold` CRDD (in the token's own decimals)
        // mint fee-free and must send exactly 0 ETH. Everyone else pays
        // exactly VAULT_CREATION_FEE. No refunds in either case — the v1.2
        // griefing rationale (reverting-receive callers trapping refunds)
        // applies to both paths.
        bool tierMember = crddToken != address(0) &&
            IERC20(crddToken).balanceOf(msg.sender) >= crddTierThreshold;
        if (tierMember) {
            if (msg.value != 0) revert UnexpectedMsgValue();
        } else if (msg.value != VAULT_CREATION_FEE) {
            revert InsufficientCreationFee();
        }

        if (token == address(0)) revert InvalidToken();

        // ── #27 free-market policy ───────────────────────────────────────────
        // ANY wallet may create vaults for any token, including duplicates of
        // an existing token vault. The curator is the ONLY capped wallet:
        // ONE vault per token, enforced by consuming the flag on their FIRST
        // create via ANY path (the cap binds the address, not the path).
        bool isCurator = msg.sender == curator;
        if (isCurator) {
            if (curatorVaultCreated[token]) revert CuratorVaultAlreadyExists(token);
            curatorVaultCreated[token] = true;
        }

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

        // Register. The FIRST vault for a token is canonical (`getVault`) and
        // is never overwritten — not by duplicates, not by the curator. The
        // curator's vault lands in `getCuratedVault` when it is not the first.
        if (getVault[token] == address(0)) {
            getVault[token] = vault;
        } else if (isCurator) {
            getCuratedVault[token] = vault;
        }
        getToken[vault] = token;
        allVaults.push(vault);

        // Forward the creation fee to the DAO treasury (#28: tier pays 0).
        if (msg.value > 0) {
            (bool ok, ) = payable(feeCollector).call{value: msg.value}("");
            if (!ok) revert FeeTransferFailed();
        }

        emit VaultCreated(token, vault, cfg.entryTaxBps, cfg.exitTaxBps, cfg.dividendShareBps);
        if (tierMember) {
            emit TierVaultCreated(msg.sender, token, vault);
        }
        if (isCurator && getCuratedVault[token] == vault) {
            emit CuratedVaultCreated(token, vault);
        }
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

    /// @notice #27: reassign the curator (e.g. to a DAO Safe at migration).
    ///         The new curator does NOT inherit consumed exemptions —
    ///         `curatorVaultCreated` is per-token and per-factory, so a
    ///         migrated curator cannot mint a second vault for a token where
    ///         the exemption was already used. Renouncing ownership freezes
    ///         the curator at its last value.
    function setCurator(address newCurator) external onlyOwner {
        if (newCurator == address(0)) revert InvalidCurator();
        emit CuratorSet(curator, newCurator);
        curator = newCurator;
    }

    /// @notice #28: wire or disable the CRDD minting tier. `token = 0`
    ///         disables the tier (threshold must then be 0); a non-zero
    ///         token requires a non-zero threshold. `threshold` is in the
    ///         CRDD token's own decimals (e.g. 10_000e18 for an 18-decimal
    ///         CRDD). Owner-gated; renouncing ownership freezes the config.
    function setCrddToken(address token, uint256 threshold) external onlyOwner {
        if (token == address(0)) {
            if (threshold != 0) revert InvalidCrddConfig();
        } else if (threshold == 0) {
            revert InvalidCrddConfig();
        }
        crddToken = token;
        crddTierThreshold = threshold;
        emit CrddTierConfigured(token, threshold);
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

    /// @notice #28: whether `who` qualifies for fee-free vault creation
    ///         right now (false while the tier is disabled).
    function isTierMember(address who) external view returns (bool) {
        return crddToken != address(0) &&
            IERC20(crddToken).balanceOf(who) >= crddTierThreshold;
    }
}
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

/// @title  DHPFeeCollector
/// @notice Accumulates the 0.5% protocol fee from every Diamond Hands Vault,
///         token-by-token, and lets the DAO treasury sweep each balance on
///         demand.
/// @dev    Per the vault design, every vault sends its 0.5% protocol share
///         directly to this contract on every deposit/withdraw. This contract
///         does not own those tokens; vaults just `safeTransfer` here.
///
/// @dev    Why a separate collector?
///         - The vault's `feeCollector` reference is set at clone init and
///           immutable forever. If we pointed it at the DAO multisig
///           directly, a single misconfigured multisig on one chain would
///           lock the protocol fee. By routing through this collector, we
///           can swap the destination per token without redeploying vaults.
///
///         ⚠️ GOVERNANCE — DO NOT RENOUNCE THIS CONTRACT (v1.2.2, audit
///         M-NEW-1). Unlike the factory, the FeeCollector's `sweep()`,
///         `sweepTo()` and `sweepNative()` are `onlyOwner`. Renouncing
///         ownership here would PERMANENTLY LOCK every future protocol fee
///         inside this contract. The required endgame is: transfer ownership
///         (Ownable2Step) to the DAO's Safe/multisig — and keep it owned
///         forever. Only the FACTORY is meant to be renounced (that is safe:
///         renouncing merely freezes `setVerified` curation; permissionless
///         `createVault` keeps working).
contract DHPFeeCollector is Ownable2Step, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    // ──────────────────────────────────────────────────────────────────────────
    // Storage
    // ──────────────────────────────────────────────────────────────────────────

    /// @dev Default destination for `sweep(token)` when no override is set.
    address public defaultTreasury;

    /// @dev Per-token sweep overrides (token → override destination).
    mapping(address token => address destination) public sweepOverride;

    /// @dev Per-token accounting (token → total ever swept).
    mapping(address token => uint256 total) public totalSwept;

    // ──────────────────────────────────────────────────────────────────────────
    // Events
    // ──────────────────────────────────────────────────────────────────────────

    event Swept(address indexed token, address indexed to, uint256 amount);
    event DefaultTreasuryUpdated(address indexed previous, address indexed current);
    event SweepOverrideUpdated(address indexed token, address indexed previous, address indexed current);

    // ──────────────────────────────────────────────────────────────────────────
    // Errors
    // ──────────────────────────────────────────────────────────────────────────

    error ZeroAddress();
    error NothingToSweep(address token);

    // ──────────────────────────────────────────────────────────────────────────
    // Constructor
    // ──────────────────────────────────────────────────────────────────────────

    /// @param treasury_ The initial sweep destination (CryptoSI DAO multisig).
    constructor(address treasury_) Ownable(msg.sender) {
        if (treasury_ == address(0)) revert ZeroAddress();
        defaultTreasury = treasury_;
    }

    // ──────────────────────────────────────────────────────────────────────────
    // Vault-side: receive fees
    // ──────────────────────────────────────────────────────────────────────────

    /// @notice Vaults route their 0.5% protocol share here via plain
    ///         `safeTransfer` — no hook call is needed or used, and the
    ///         balance is implicit in `IERC20(token).balanceOf(address(this))`.
    ///         Indexers should track fee inflows via each vault's
    ///         `TaxCollected` event (the old `onFeeReceived()`/`FeeReceived`
    ///         surface was removed in v1.2.2 — audit I-NEW-1: it was never
    ///         called by vaults and allowed anyone to emit fake fee events).
    // solhint-disable-next-line no-empty-blocks
    receive() external payable {}

    // ──────────────────────────────────────────────────────────────────────────
    // DAO-side: sweep + admin
    // ──────────────────────────────────────────────────────────────────────────

    /// @notice Sweep the entire balance of `token` to its configured
    ///         destination (per-token override or default treasury).
    function sweep(address token) external nonReentrant onlyOwner {
        address dest = sweepOverride[token] == address(0) ? defaultTreasury : sweepOverride[token];
        if (dest == address(0)) revert ZeroAddress();
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (bal == 0) revert NothingToSweep(token);
        IERC20(token).safeTransfer(dest, bal);
        totalSwept[token] += bal;
        emit Swept(token, dest, bal);
    }

    /// @notice Sweep a specific amount of `token` to `to`.
    function sweepTo(address token, address to, uint256 amount) external nonReentrant onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        IERC20(token).safeTransfer(to, amount);
        totalSwept[token] += amount;
        emit Swept(token, to, amount);
    }

    /// @notice Sweep the native ETH/Base balance to `to` (if anyone sent ETH
    ///         here by accident or future cross-chain bridges).
    function sweepNative(address to) external nonReentrant onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        uint256 bal = address(this).balance;
        if (bal == 0) revert NothingToSweep(address(0));
        (bool ok, ) = to.call{value: bal}("");
        require(ok, "ETH transfer failed");
        emit Swept(address(0), to, bal);
    }

    /// @notice Update the default treasury destination.
    function setDefaultTreasury(address treasury_) external onlyOwner {
        if (treasury_ == address(0)) revert ZeroAddress();
        emit DefaultTreasuryUpdated(defaultTreasury, treasury_);
        defaultTreasury = treasury_;
    }

    /// @notice Set or clear a per-token sweep override.
    /// @param token     The underlying token.
    /// @param override_ Destination, or zero to clear the override.
    function setSweepOverride(address token, address override_) external onlyOwner {
        emit SweepOverrideUpdated(token, sweepOverride[token], override_);
        sweepOverride[token] = override_;
    }

    // ──────────────────────────────────────────────────────────────────────────
    // Views
    // ──────────────────────────────────────────────────────────────────────────

    /// @notice Current pending balance of `token` in this collector.
    function pendingBalance(address token) external view returns (uint256) {
        return IERC20(token).balanceOf(address(this));
    }
}
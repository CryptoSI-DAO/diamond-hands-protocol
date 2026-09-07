// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title  IDHPVault
/// @notice External interface for a single Diamond Hands Vault clone.
/// @dev    Each vault is an EIP-1167 minimal proxy over DHPImplementation,
///         initialised with one specific underlying ERC-20 token. The factory
///         exposes a `getVault(token) → vault` mapping; the vault address
///         itself is what users call `deposit`/`withdraw`/`claimDividend` on.
interface IDHPVault {
    // ──────────────────────────────────────────────────────────────────────────
    // Views
    // ──────────────────────────────────────────────────────────────────────────

    /// @notice Returns the underlying ERC-20 this vault wraps.
    function asset() external view returns (IERC20 assetTokenAddress);

    /// @notice Total underlying assets currently held by the vault.
    function totalAssets() external view returns (uint256 totalManagedAssets);

    /// @notice The factory that deployed this vault.
    function factory() external view returns (address);

    /// @notice Fee collector receiving the 0.5% protocol share.
    function feeCollector() external view returns (address);

    /// @notice Cumulative dividends per share, scaled 1e18.
    function rewardPerTokenStored() external view returns (uint256);

    /// @notice Total dividends ever distributed (tax inflows minus protocol share).
    function totalDividendsDistributed() external view returns (uint256);

    /// @notice Snapshot of `rewardPerTokenStored` at the user's last interaction.
    function rewardPerTokenPaid(address account) external view returns (uint256);

    /// @notice Unclaimed dividends accrued to `account`.
    function rewards(address account) external view returns (uint256);

    /// @notice Configured entry tax in basis points (1 bp = 0.01%).
    function entryTaxBps() external view returns (uint16);

    /// @notice Configured exit tax in basis points.
    function exitTaxBps() external view returns (uint16);

    /// @notice Configured dividend share of every tax (out of the tax, after the
    ///         protocol fee is taken). The remainder is sent to the burn sink.
    function dividendShareBps() external view returns (uint16);

    // (v1.2.2) `totalAssetsAfterTax()` removed from the interface — it
    // returned the raw balance including burned tokens, contradicting
    // `totalAssets()` and misleading integrators. (Audit L-NEW-3.)

    // (Note: ERC-20 share surface — balanceOf, totalSupply, transfer, approve —
//  is inherited from the underlying ERC20 base; not redeclared here to
//  avoid OZ's public/external visibility mismatch.)

    // ──────────────────────────────────────────────────────────────────────────
    // User actions
    // ──────────────────────────────────────────────────────────────────────────

    /// @notice Deposit `assets` underlying tokens and receive vault shares.
    /// @param  assets  The amount of underlying tokens to deposit.
    /// @param  receiver The recipient of the minted vault shares.
    /// @return shares   The amount of vault shares minted (post-entry-tax).
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);

    /// @notice Mint exactly `shares` vault shares by depositing the required
    ///         amount of underlying (which is greater due to the entry tax).
    function mint(uint256 shares, address receiver) external returns (uint256 assets);

    /// @notice Burn `shares` and withdraw the corresponding amount of underlying,
    ///         minus the exit tax. The withdrawn amount is split between the
    ///         receiver, the dividend pool, the burn sink, and the fee collector.
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares);

    /// @notice Burn `shares` and withdraw `assets` underlying.
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);

    /// @notice Claim pending dividends for `msg.sender`. Pays out in the
    ///         underlying token (not shares).
    /// @param  minAmountOut  Slippage protection: reverts if the actual
    ///         amount is less than this. Pass 0 to skip the check.
    /// @return amount The amount of underlying transferred to the caller.
    function claimDividend(uint256 minAmountOut) external returns (uint256 amount);

    /// @notice Backwards-compatible overload (no slippage protection).
    /// @return amount The amount of underlying transferred to the caller.
    function claimDividend() external returns (uint256 amount);

    /// @notice If true, the vault accepts tokens with FOT/hook behaviour
    ///         (rebasing, gas-burn, marketing-fee). When false (default),
    ///         the vault reverts on any transfer that doesn't deliver the
    ///         full requested amount. (v1.2.1, M-CARRIED-1.)
    function acceptFeesFromTransfer() external view returns (bool);

    // ──────────────────────────────────────────────────────────────────────────
    // ERC-4626 preview helpers (mirror ERC4626 semantics; previews already net
    // out entry/exit tax — i.e. previewDeposit returns shares-after-tax).
    // ──────────────────────────────────────────────────────────────────────────

    function previewDeposit(uint256 assets) external view returns (uint256);
    function previewMint(uint256 shares) external view returns (uint256);
    function previewWithdraw(uint256 assets) external view returns (uint256);
    function previewRedeem(uint256 shares) external view returns (uint256);

    // ──────────────────────────────────────────────────────────────────────────
    // Events
    // ──────────────────────────────────────────────────────────────────────────

    event VaultInitialised(address indexed token, uint16 entryTaxBps, uint16 exitTaxBps, uint16 dividendShareBps);
    event DividendAccrued(address indexed account, uint256 amount);
    event DividendClaimed(address indexed account, uint256 amount);
    event TaxCollected(uint8 kind, uint256 gross, uint256 dividends, uint256 burned, uint256 protocolFee);
    event TokensBurned(uint256 amount);
}
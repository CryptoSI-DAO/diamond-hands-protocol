// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DHPImplementation} from "../../src/contracts/DHPImplementation.sol";
import {DHPFactory} from "../../src/contracts/DHPFactory.sol";
import {DHPFeeCollector} from "../../src/contracts/DHPFeeCollector.sol";
import {IDHPVault} from "../../src/interfaces/IDHPVault.sol";

import {MockERC20} from "../mocks/MockERC20.sol";

/// @title  DHP v1.2.2 audit-fix tests
/// @notice Locks in the v1.2.2 changes (self-audit SELF_AUDIT_V1.2.2.md):
///          - I-NEW-2: the implementation contract can no longer be initialized
///          - L-NEW-1: degenerate state (supply > 0, totalAssets == 0) reverts
///            loudly instead of pricing shares 1:1 against burned tokens
contract DHPV122AuditTest is Test {
    DHPImplementation internal implementation;
    DHPFactory internal factory;
    DHPFeeCollector internal feeCollector;
    MockERC20 internal token;
    DHPImplementation internal vault;

    address internal alice = makeAddr("alice");

    function setUp() public {
        implementation = new DHPImplementation();
        feeCollector = new DHPFeeCollector(makeAddr("treasury"));
        factory = new DHPFactory(address(implementation), address(feeCollector), 0, 18);
        vm.deal(address(this), 10 ether);

        token = new MockERC20("SPX6900", "SPX", 8);
        DHPFactory.TaxConfig memory cfg = DHPFactory.TaxConfig({
            entryTaxBps: 500,
            exitTaxBps: 1_000,
            dividendShareBps: 7_000,
            acceptFeesFromTransfer: false
        });
        vault = DHPImplementation(payable(factory.createVault{value: 0.001 ether}(address(token), cfg)));

        token.mint(alice, 1_000_000e8);
        vm.prank(alice);
        token.approve(address(vault), type(uint256).max);
    }

    // ── I-NEW-2: implementation self-initialization is dead ──────────────────

    function test_implementation_initialize_reverts() public {
        vm.expectRevert(DHPImplementation.AlreadyInitialised.selector);
        implementation.initialize(
            IERC20(address(token)),
            makeAddr("collector"),
            500,
            1_000,
            7_000,
            1e8,
            false
        );
    }

    // ── L-NEW-1: degenerate state reverts loudly ─────────────────────────────
    //
    // Drive a live vault into supply > 0 && totalAssets() == 0 by burning
    // underlying tokens straight out of its balance (mock rebase simulation)
    // until balanceOf(vault) == burnedBalance. The old code priced every
    // share 1:1 against the raw balance there, letting a redeemer eat the
    // LOCKED burn tokens and subsequently brick totalAssets() for everyone.

    function test_degenerate_state_reverts_on_pricing() public {
        vm.prank(alice);
        vault.deposit(200e8, alice);
        // deposit(): net 190e8 shares; tax 10e8 -> div 7e8, fee 0.05e8, burn 2.95e8
        assertEq(vault.totalBurned(), 2.95e8);
        uint256 vaultBal = token.balanceOf(address(vault));
        assertEq(vaultBal, 199.95e8); // 200 in, 0.05 fee out
        assertEq(vault.totalAssets(), 197e8); // 199.95 - 2.95

        // Simulate a negative rebase: burn net assets out of the vault until
        // balanceOf == burnedBalance, i.e. totalAssets() == 0.
        token.burn(address(vault), vaultBal - 2.95e8);
        assertEq(token.balanceOf(address(vault)), vault.totalBurned());

        // totalAssets() itself still returns 0 legitimately (require passes).
        assertEq(vault.totalAssets(), 0);

        // Pricing must now revert LOUDLY instead of 1:1-mispricing shares.
        vm.expectRevert(DHPImplementation.DegenerateVaultState.selector);
        vault.previewRedeem(1e8);

        vm.expectRevert(DHPImplementation.DegenerateVaultState.selector);
        vault.previewDeposit(1e8);

        // And a real redemption cannot eat the locked burn tokens.
        vm.prank(alice);
        vm.expectRevert();
        vault.redeem(1e8, alice, alice);

        // The locked tokens are untouched.
        assertEq(token.balanceOf(address(vault)), 2.95e8);
    }
}

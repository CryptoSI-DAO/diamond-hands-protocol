// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import {DHPFeeCollector} from "../../src/contracts/DHPFeeCollector.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @title  DHPFeeCollector unit tests
/// @notice Exercises sweep, admin, and the receive hook.
contract DHPFeeCollectorTest is Test {
    DHPFeeCollector internal collector;
    MockERC20 internal token;
    address internal daoTreasury = makeAddr("dao-treasury");
    address internal newTreasury = makeAddr("new-treasury");
    address internal owner = makeAddr("collector-owner");
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        vm.prank(owner);
        collector = new DHPFeeCollector(daoTreasury);
        token = new MockERC20("Test", "TST", 18);
    }

    function _fund(uint256 amount) internal {
        token.mint(address(collector), amount);
    }

    // ──────────────────────────────────────────────────────────────────────────
    // Constructor / metadata
    // ──────────────────────────────────────────────────────────────────────────

    function test_initial_state() public view {
        assertEq(collector.owner(), owner);
        assertEq(collector.defaultTreasury(), daoTreasury);
    }

    function test_zero_treasury_in_constructor_reverts() public {
        vm.expectRevert(DHPFeeCollector.ZeroAddress.selector);
        new DHPFeeCollector(address(0));
    }

    // ──────────────────────────────────────────────────────────────────────────
    // Sweep
    // ──────────────────────────────────────────────────────────────────────────

    function test_sweep_transfers_full_balance() public {
        _fund(1_000e18);
        assertEq(token.balanceOf(address(collector)), 1_000e18);

        vm.prank(owner);
        collector.sweep(address(token));

        assertEq(token.balanceOf(address(collector)), 0);
        assertEq(token.balanceOf(daoTreasury), 1_000e18);
        assertEq(collector.totalSwept(address(token)), 1_000e18);
    }

    function test_sweep_zero_balance_reverts() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(DHPFeeCollector.NothingToSweep.selector, address(token)));
        collector.sweep(address(token));
    }

    function test_sweep_only_owner() public {
        _fund(100e18);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", stranger));
        collector.sweep(address(token));
    }

    function test_sweep_to_specific_address() public {
        _fund(500e18);
        vm.prank(owner);
        collector.sweepTo(address(token), newTreasury, 200e18);

        assertEq(token.balanceOf(newTreasury), 200e18);
        assertEq(token.balanceOf(address(collector)), 300e18);
        assertEq(collector.totalSwept(address(token)), 200e18);
    }

    function test_sweep_to_zero_address_reverts() public {
        _fund(100e18);
        vm.prank(owner);
        vm.expectRevert(DHPFeeCollector.ZeroAddress.selector);
        collector.sweepTo(address(token), address(0), 50e18);
    }

    // ──────────────────────────────────────────────────────────────────────────
    // Per-token override
    // ──────────────────────────────────────────────────────────────────────────

    function test_per_token_override_routes_sweep() public {
        _fund(100e18);

        // Set override to newTreasury for this token.
        vm.prank(owner);
        collector.setSweepOverride(address(token), newTreasury);

        vm.prank(owner);
        collector.sweep(address(token));

        // Override should have been honoured.
        assertEq(token.balanceOf(newTreasury), 100e18);
        assertEq(token.balanceOf(daoTreasury), 0);
    }

    function test_per_token_override_clear() public {
        _fund(100e18);

        // Set then clear override.
        vm.prank(owner);
        collector.setSweepOverride(address(token), newTreasury);
        vm.prank(owner);
        collector.setSweepOverride(address(token), address(0));

        vm.prank(owner);
        collector.sweep(address(token));

        // Should fall back to default treasury.
        assertEq(token.balanceOf(daoTreasury), 100e18);
    }

    function test_set_sweep_override_only_owner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", stranger));
        collector.setSweepOverride(address(token), newTreasury);
    }

    // ──────────────────────────────────────────────────────────────────────────
    // Default treasury update
    // ──────────────────────────────────────────────────────────────────────────

    function test_set_default_treasury() public {
        vm.prank(owner);
        collector.setDefaultTreasury(newTreasury);

        assertEq(collector.defaultTreasury(), newTreasury);

        // Subsequent sweeps go to the new treasury.
        _fund(50e18);
        vm.prank(owner);
        collector.sweep(address(token));
        assertEq(token.balanceOf(newTreasury), 50e18);
    }

    function test_set_default_treasury_zero_reverts() public {
        vm.prank(owner);
        vm.expectRevert(DHPFeeCollector.ZeroAddress.selector);
        collector.setDefaultTreasury(address(0));
    }

    function test_set_default_treasury_only_owner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", stranger));
        collector.setDefaultTreasury(newTreasury);
    }

    // ──────────────────────────────────────────────────────────────────────────
    // Native ETH sweep
    // ──────────────────────────────────────────────────────────────────────────

    function test_sweep_native_eth() public {
        // Send some ETH to the collector.
        vm.deal(address(collector), 1 ether);
        assertEq(address(collector).balance, 1 ether);

        vm.prank(owner);
        collector.sweepNative(newTreasury);
        assertEq(address(collector).balance, 0);
        assertEq(newTreasury.balance, 1 ether);
    }

    function test_sweep_native_zero_balance_reverts() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(DHPFeeCollector.NothingToSweep.selector, address(0)));
        collector.sweepNative(newTreasury);
    }

    function test_sweep_native_only_owner() public {
        vm.deal(address(collector), 1 ether);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", stranger));
        collector.sweepNative(newTreasury);
    }

    // ──────────────────────────────────────────────────────────────────────────
    // Hook (informational event)
    // ──────────────────────────────────────────────────────────────────────────

    // (v1.2.2) test_on_fee_received_emits_event removed with the function
    // itself — audit I-NEW-1: onFeeReceived()/FeeReceived were dead surface;
    // vaults transfer directly and anyone could emit fake fee events.

    function test_pending_balance_view() public {
        _fund(123e18);
        assertEq(collector.pendingBalance(address(token)), 123e18);
    }

    function test_total_swept_accumulates() public {
        _fund(1_000e18);

        vm.prank(owner);
        collector.sweepTo(address(token), newTreasury, 400e18);
        vm.prank(owner);
        collector.sweep(address(token)); // sweeps remaining 600

        assertEq(collector.totalSwept(address(token)), 1_000e18);
    }
}
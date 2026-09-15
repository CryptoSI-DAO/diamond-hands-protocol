// SPDX-License-Identifier: MIT
// SPDX-Date: 2026-09-15 — audit M-NEW-1 regression (SELF_AUDIT_V1.4.0.md)
pragma solidity ^0.8.28;

/// @dev Regression tests for the #29 weight-sum validation in
///      `DHPImplementation.initialize()` (audit M-NEW-1). Pre-fix, the vault
///      validated the pre-#29 "dividend + 0.5% fee" invariant, so a legacy
///      9_000-dividend config passed validation yet underflowed
///      `_distributeTax` on first use — a created-but-bricked vault.
import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {DHPImplementation} from "../../src/contracts/DHPImplementation.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

contract InitializeWeightSumRegression is Test {
    DHPImplementation impl;
    MockERC20 token;

    function setUp() public {
        token = new MockERC20("Mock", "MK", 18);
        // (v1.2.2, I-NEW-2) The implementation is born pre-initialised —
        // tests must exercise a FRESH CLONE, same as the factory does.
        impl = DHPImplementation(Clones.clone(address(new DHPImplementation())));
    }

    /// @dev Helper: initialize with an explicit dividend share, everything
    ///      else canonical.
    function _init(uint16 dividendShareBps_) internal {
        impl.initialize(
            token, makeAddr("collector"), makeAddr("creator"), makeAddr("platform"),
            500, 1000, dividendShareBps_, 1e18, false
        );
    }

    /// @notice The exact legacy brick config from the audit: dividend = 9_000
    ///         passes the OLD bound but exceeds the true #29 weight-sum
    ///         budget (8_000). Must revert at initialize, before any funds
    ///         can ever be deposited.
    function test_initialize_rejects_legacy_9000_dividend_config() public {
        vm.expectRevert(DHPImplementation.InvalidBpsConfiguration.selector);
        _init(9_000);
    }

    /// @notice Boundary: 8_001 is one over budget — reject. 8_000 (the
    ///         canon) is exactly at budget — accept.
    function test_initialize_boundary_8001_vs_8000() public {
        vm.expectRevert(DHPImplementation.InvalidBpsConfiguration.selector);
        _init(8_001);
        _init(8_000); // canon config — must succeed
        assertEq(impl.dividendShareBps(), 8_000);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {DHPImplementation} from "../../src/contracts/DHPImplementation.sol";
import {DHPFactory} from "../../src/contracts/DHPFactory.sol";
import {DHPFeeCollector} from "../../src/contracts/DHPFeeCollector.sol";

import {MockERC20} from "../mocks/MockERC20.sol";

/// @title  Curator cap tests (#27)
/// @notice Vault creation is FREE-MARKET: any wallet may create vaults for
///         any token, including duplicates. The curator is the ONLY wallet
///         capped at ONE vault per token (flag consumed on their first
///         create, any path). The canonical `getVault[token]` is always the
///         token's FIRST vault and is never overwritten.
contract DHPCuratorExemptionTest is Test {
    DHPImplementation internal implementation;
    DHPFactory internal factory;
    DHPFeeCollector internal feeCollector;

    address internal curator = makeAddr("curator");
    address internal squatter = makeAddr("squatter");
    address internal dao = makeAddr("dao-treasury");
    address internal factoryOwner = makeAddr("factory-owner");

    MockERC20 internal tokenA;
    MockERC20 internal tokenB;

    function setUp() public {
        implementation = new DHPImplementation();
        feeCollector = new DHPFeeCollector(dao);
        vm.prank(factoryOwner);
        factory = new DHPFactory(address(implementation), address(feeCollector), curator, 0, 18);

        // 8-dec mocks (house convention, SPX-like).
        tokenA = new MockERC20("Squat Target A", "SQTA", 8);
        tokenB = new MockERC20("Squat Target B", "SQTB", 8);

        vm.deal(address(this), 100 ether);
        vm.deal(curator, 10 ether);
        vm.deal(squatter, 10 ether);
    }

    function _canon() internal pure returns (DHPFactory.TaxConfig memory) {
        return DHPFactory.TaxConfig({
            entryTaxBps: 500,
            exitTaxBps: 1_000,
            dividendShareBps: 8_000,
            acceptFeesFromTransfer: false
        });
    }

    /// @dev Read the fee BEFORE pranking — the constant-getter staticcall
    ///      would otherwise consume the prank (house gotcha).
    function _createAs(address caller, address token) internal returns (address) {
        uint256 fee = factory.VAULT_CREATION_FEE();
        vm.prank(caller);
        return factory.createVault{value: fee}(token, _canon());
    }

    function test_CuratorOverride_HappyPath() public {
        // A squatter takes the token's slot first.
        address first = _createAs(squatter, address(tokenA));
        assertEq(factory.getVault(address(tokenA)), first);
        assertEq(factory.curatorVaultCreated(address(tokenA)), false);

        uint256 collectorBefore = address(feeCollector).balance;

        // Override create: emits CuratedVaultCreated with the NEW vault.
        vm.recordLogs();
        address second = _createAs(curator, address(tokenA));

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool emitted = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == DHPFactory.CuratedVaultCreated.selector) {
                emitted = true;
                assertEq(logs[i].topics[1], bytes32(uint256(uint160(address(tokenA)))));
                assertEq(address(uint160(uint256(logs[i].topics[2]))), second);
            }
        }
        assertTrue(emitted, "CuratedVaultCreated not emitted");

        // D2: canonical mapping untouched; override lives in getCuratedVault.
        assertEq(factory.getVault(address(tokenA)), first);
        assertEq(factory.getCuratedVault(address(tokenA)), second);
        assertEq(factory.getToken(second), address(tokenA));
        assertTrue(factory.curatorVaultCreated(address(tokenA)));

        // Enumeration: both vaults registered.
        assertEq(factory.vaultCount(), 2);
        assertEq(factory.allVaultsAt(0), first);
        assertEq(factory.allVaultsAt(1), second);

        // D3: fee still charged exactly on the override path.
        assertEq(address(feeCollector).balance - collectorBefore, 0.004 ether);
    }

    function test_CuratorOverride_SecondCreateReverts() public {
        _createAs(squatter, address(tokenA));
        _createAs(curator, address(tokenA));

        uint256 fee = factory.VAULT_CREATION_FEE();
        vm.prank(curator);
        vm.expectRevert(
            abi.encodeWithSelector(DHPFactory.CuratorVaultAlreadyExists.selector, address(tokenA))
        );
        factory.createVault{value: fee}(address(tokenA), _canon());
    }

    function test_CuratorFirstCreate_ConsumesExemption() public {
        // Curator arrives FIRST: canonical path, no override record.
        address vault = _createAs(curator, address(tokenA));
        assertEq(factory.getVault(address(tokenA)), vault);
        assertEq(factory.getCuratedVault(address(tokenA)), address(0));
        assertTrue(factory.curatorVaultCreated(address(tokenA)));

        // No CuratedVaultCreated on the canonical path.
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(
                logs[i].topics[0] != DHPFactory.CuratedVaultCreated.selector,
                "override event must not fire on canonical create"
            );
        }

        // D4: cap binds ANY path — the curator cannot create a second vault
        // for this token even though duplicates are free for everyone else.
        uint256 fee = factory.VAULT_CREATION_FEE();
        vm.prank(curator);
        vm.expectRevert(
            abi.encodeWithSelector(DHPFactory.CuratorVaultAlreadyExists.selector, address(tokenA))
        );
        factory.createVault{value: fee}(address(tokenA), _canon());
    }

    function test_NonCurator_DuplicateAllowed_SameActor() public {
        // Free market: the same wallet duplicates a token's vault freely.
        address first = _createAs(squatter, address(tokenA));
        address second = _createAs(squatter, address(tokenA));

        assertTrue(first != second);
        assertEq(factory.getVault(address(tokenA)), first);
        assertEq(factory.vaultCount(), 2);
        assertTrue(factory.curatorVaultCreated(address(tokenA)) == false);
    }

    function test_NonCurator_Duplicate_AfterCuratorCanonicalCreate() public {
        // Curator takes the canonical slot; anyone can still duplicate.
        address curatorVault = _createAs(curator, address(tokenA));

        address dup = _createAs(squatter, address(tokenA));
        assertTrue(dup != address(0));

        // Canonical stays the curator's first create; curated mapping zero.
        assertEq(factory.getVault(address(tokenA)), curatorVault);
        assertEq(factory.getCuratedVault(address(tokenA)), address(0));
        assertEq(factory.vaultCount(), 2);
    }

    function test_SetCurator_ReassignAndGuards() public {
        // Old curator consumes tokenA's exemption before the reassignment.
        _createAs(curator, address(tokenA));
        assertTrue(factory.curatorVaultCreated(address(tokenA)));

        address newCurator = makeAddr("new-curator");

        // Non-owner cannot reassign.
        vm.prank(squatter);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, squatter)
        );
        factory.setCurator(newCurator);

        // Zero curator rejected.
        vm.prank(factoryOwner);
        vm.expectRevert(DHPFactory.InvalidCurator.selector);
        factory.setCurator(address(0));

        // Owner reassigns, event fires.
        vm.prank(factoryOwner);
        vm.expectEmit(true, true, false, true, address(factory));
        emit DHPFactory.CuratorSet(curator, newCurator);
        factory.setCurator(newCurator);
        assertEq(factory.curator(), newCurator);

        // Consumed exemptions do NOT transfer: old curator used tokenA's slot.
        vm.deal(newCurator, 1 ether);
        uint256 fee = factory.VAULT_CREATION_FEE();
        vm.prank(newCurator);
        vm.expectRevert(
            abi.encodeWithSelector(DHPFactory.CuratorVaultAlreadyExists.selector, address(tokenA))
        );
        factory.createVault{value: fee}(address(tokenA), _canon());

        // New curator CAN use a fresh token's exemption.
        address v = _createAs(newCurator, address(tokenB));
        assertEq(factory.getVault(address(tokenB)), v);
        assertTrue(factory.curatorVaultCreated(address(tokenB)));
    }

    function test_Constructor_RejectsZeroCurator() public {
        vm.expectRevert(DHPFactory.InvalidCurator.selector);
        new DHPFactory(address(implementation), address(feeCollector), address(0), 0, 18);
    }

    /// @notice Random walk over the (actor x token) state machine under the
    ///         free-market policy: the curator must NEVER end up with more
    ///         than one vault per token, and the canonical `getVault` for a
    ///         token must be set exactly once (first create) and never move.
    function testFuzz_AtMostOneCuratorVaultPerToken(uint256 seed) public {
        uint256 curatorVaultsA;
        uint256 curatorVaultsB;
        address canonicalA;
        address canonicalB;

        for (uint256 i = 0; i < 8; i++) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            bool asCurator = r % 2 == 0;
            MockERC20 tok = r % 4 < 2 ? tokenA : tokenB;
            bool onA = address(tok) == address(tokenA);

            // Only the curator can hit a revert; skip consumed states.
            if (asCurator && factory.curatorVaultCreated(address(tok))) continue;

            address actor = asCurator ? curator : squatter;

            // Canonical set-once invariant: capture the zero-state before the
            // create, then assert the mapping never moves afterwards.
            address before = factory.getVault(address(tok));
            _createAs(actor, address(tok));
            address afterV = factory.getVault(address(tok));
            if (before == address(0)) {
                if (onA) {
                    canonicalA = afterV;
                } else {
                    canonicalB = afterV;
                }
            } else {
                assertEq(afterV, before, "canonical mapping moved");
            }

            if (asCurator) {
                if (onA) {
                    curatorVaultsA++;
                } else {
                    curatorVaultsB++;
                }
                assertTrue(factory.curatorVaultCreated(address(tok)));
            }
        }

        assertLe(curatorVaultsA, 1, "curator created multiple vaults for tokenA");
        assertLe(curatorVaultsB, 1, "curator created multiple vaults for tokenB");
        // Canonical mapping is always set (something created each token).
        assertTrue(canonicalA != address(0) || canonicalB != address(0));
    }
}

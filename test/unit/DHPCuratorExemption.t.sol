// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {DHPImplementation} from "../../src/contracts/DHPImplementation.sol";
import {DHPFactory} from "../../src/contracts/DHPFactory.sol";
import {DHPFeeCollector} from "../../src/contracts/DHPFeeCollector.sol";

import {MockERC20} from "../mocks/MockERC20.sol";

/// @title  Curator exemption tests (#27)
/// @notice The curator may create ONE vault per token even when a vault
///         already exists (anti-squat escape hatch). Everyone else keeps the
///         strict one-vault-per-token rule. The override vault registers in
///         `getCuratedVault` and NEVER overwrites the canonical `getVault`.
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
        assertEq(address(feeCollector).balance - collectorBefore, 0.001 ether);
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

        // D4: curator already owns the ONLY vault — still blocked from a second.
        uint256 fee = factory.VAULT_CREATION_FEE();
        vm.prank(curator);
        vm.expectRevert(
            abi.encodeWithSelector(DHPFactory.CuratorVaultAlreadyExists.selector, address(tokenA))
        );
        factory.createVault{value: fee}(address(tokenA), _canon());
    }

    function test_NonCurator_StillBlockedByOnePerToken() public {
        _createAs(squatter, address(tokenA));

        address other = makeAddr("other");
        vm.deal(other, 1 ether);
        uint256 fee = factory.VAULT_CREATION_FEE();
        vm.prank(other);
        vm.expectRevert(
            abi.encodeWithSelector(DHPFactory.VaultAlreadyExistsForToken.selector, address(tokenA))
        );
        factory.createVault{value: fee}(address(tokenA), _canon());
    }

    function test_NonCurator_Blocked_EvenAfterCuratorCanonicalCreate() public {
        // Curator takes the canonical slot; squatter gets the NORMAL
        // one-per-token error (the curator flag must not gate other actors).
        _createAs(curator, address(tokenA));
        assertTrue(factory.getVault(address(tokenA)) != address(0));

        uint256 fee = factory.VAULT_CREATION_FEE();
        vm.prank(squatter);
        vm.expectRevert(
            abi.encodeWithSelector(DHPFactory.VaultAlreadyExistsForToken.selector, address(tokenA))
        );
        factory.createVault{value: fee}(address(tokenA), _canon());
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

    /// @notice Random walk over the (actor x token) state machine: the curator
    ///         must NEVER end up with more than one vault per token.
    function testFuzz_AtMostOneCuratorVaultPerToken(uint256 seed) public {
        uint256 curatorVaultsA;
        uint256 curatorVaultsB;

        for (uint256 i = 0; i < 8; i++) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            bool asCurator = r % 2 == 0;
            MockERC20 tok = r % 4 < 2 ? tokenA : tokenB;
            bool onA = address(tok) == address(tokenA);

            // Skip states that would revert (they are unit-tested above).
            if (asCurator && factory.curatorVaultCreated(address(tok))) continue;
            if (!asCurator && factory.getVault(address(tok)) != address(0)) continue;

            address actor = asCurator ? curator : squatter;
            _createAs(actor, address(tok));

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
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {DHPImplementation} from "../../src/contracts/DHPImplementation.sol";
import {DHPFactory} from "../../src/contracts/DHPFactory.sol";
import {DHPFeeCollector} from "../../src/contracts/DHPFeeCollector.sol";

import {MockERC20} from "../mocks/MockERC20.sol";

/// @title  CRDD minting tier tests (#28)
/// @notice Wallets holding `crddTierThreshold` CRDD create vaults fee-free
///         (and must send exactly 0 ETH); everyone else pays the exact
///         0.001 ETH fee. The tier ships DISABLED (crddToken = 0) and is
///         owner-wired once CRDD's address is final.
contract DHPCrddTierTest is Test {
    DHPImplementation internal implementation;
    DHPFactory internal factory;
    DHPFeeCollector internal feeCollector;

    address internal curator = makeAddr("curator");
    address internal dao = makeAddr("dao-treasury");
    address internal factoryOwner = makeAddr("factory-owner");
    address internal holder = makeAddr("crdd-holder");
    address internal pleb = makeAddr("pleb");

    MockERC20 internal crdd;
    MockERC20 internal tokenA;

    uint256 internal constant THRESHOLD = 10_000e18; // 10,000 CRDD @ 18 dec

    function setUp() public {
        implementation = new DHPImplementation();
        feeCollector = new DHPFeeCollector(dao);
        vm.prank(factoryOwner);
        factory = new DHPFactory(address(implementation), address(feeCollector), curator, 0, 18);

        crdd = new MockERC20("CryptoRisk DAO", "CRDD", 18);
        tokenA = new MockERC20("Squat Target A", "SQTA", 8);

        vm.deal(address(this), 100 ether);
        vm.deal(holder, 10 ether);
        vm.deal(pleb, 10 ether);
        crdd.mint(holder, THRESHOLD);
    }

    function _canon() internal pure returns (DHPFactory.TaxConfig memory) {
        return DHPFactory.TaxConfig({
            entryTaxBps: 500,
            exitTaxBps: 1_000,
            dividendShareBps: 8_000,
            acceptFeesFromTransfer: false
        });
    }

    function _createAs(address caller, uint256 value, address token)
        internal
        returns (address)
    {
        vm.prank(caller);
        return factory.createVault{value: value}(token, _canon());
    }

    function _wireTier() internal {
        vm.prank(factoryOwner);
        factory.setCrddToken(address(crdd), THRESHOLD);
    }

    // ── Dormant by default ───────────────────────────────────────────────

    function test_TierDisabled_ByDefault() public {
        // crddToken is zero → nobody is a tier member, even a CRDD whale.
        assertTrue(factory.crddToken() == address(0));
        assertTrue(!factory.isTierMember(holder));

        // Exact-fee path still works, zero-value path still reverts.
        address v = _createAs(pleb, 0.001 ether, address(tokenA));
        assertTrue(v != address(0));

        vm.prank(pleb);
        vm.expectRevert(DHPFactory.InsufficientCreationFee.selector);
        factory.createVault{value: 0}(address(tokenA), _canon());
    }

    // ── Admin guards ─────────────────────────────────────────────────────

    function test_SetCrddToken_Guards() public {
        // Non-owner cannot wire.
        vm.prank(pleb);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, pleb)
        );
        factory.setCrddToken(address(crdd), THRESHOLD);

        // Disable call with a non-zero threshold is contradictory.
        vm.prank(factoryOwner);
        vm.expectRevert(DHPFactory.InvalidCrddConfig.selector);
        factory.setCrddToken(address(0), THRESHOLD);

        // Wire with a zero threshold is contradictory.
        vm.prank(factoryOwner);
        vm.expectRevert(DHPFactory.InvalidCrddConfig.selector);
        factory.setCrddToken(address(crdd), 0);

        // Happy wire: event + state.
        vm.prank(factoryOwner);
        vm.expectEmit(true, false, false, true, address(factory));
        emit DHPFactory.CrddTierConfigured(address(crdd), THRESHOLD);
        factory.setCrddToken(address(crdd), THRESHOLD);
        assertEq(factory.crddToken(), address(crdd));
        assertEq(factory.crddTierThreshold(), THRESHOLD);
    }

    // ── Free minting ─────────────────────────────────────────────────────

    function test_TierMember_FreeCreate_Unlimited() public {
        _wireTier();
        assertTrue(factory.isTierMember(holder));

        uint256 collectorBefore = address(feeCollector).balance;

        // Multiple free creates — unlimited means unlimited.
        vm.recordLogs();
        address v1 = _createAs(holder, 0, address(tokenA));
        address v2 = _createAs(holder, 0, address(tokenA));

        // TierVaultCreated fires per free create.
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 tierEvents;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == DHPFactory.TierVaultCreated.selector) {
                tierEvents++;
                assertEq(address(uint160(uint256(logs[i].topics[1]))), holder);
            }
        }
        assertEq(tierEvents, 2, "expected one TierVaultCreated per free create");

        // Collector earned nothing from tier creates; vaults still registered.
        assertEq(address(feeCollector).balance, collectorBefore, "tier member must not pay");
        assertEq(factory.getVault(address(tokenA)), v1);
        assertEq(factory.vaultCount(), 2);
        assertEq(factory.getToken(v2), address(tokenA));

        // Curator cap untouched by tier membership (holder is not curator).
        assertTrue(!factory.curatorVaultCreated(address(tokenA)));
    }

    function test_TierMember_PayingFee_Reverts() public {
        _wireTier();
        vm.prank(holder);
        vm.expectRevert(DHPFactory.UnexpectedMsgValue.selector);
        factory.createVault{value: 0.001 ether}(address(tokenA), _canon());
    }

    // ── Non-members unchanged ────────────────────────────────────────────

    function test_NonMember_ExactFeeStillRequired() public {
        _wireTier();

        // Below threshold: zero value reverts, exact fee works.
        assertTrue(!factory.isTierMember(pleb));
        vm.prank(pleb);
        vm.expectRevert(DHPFactory.InsufficientCreationFee.selector);
        factory.createVault{value: 0}(address(tokenA), _canon());

        address v = _createAs(pleb, 0.001 ether, address(tokenA));
        assertTrue(v != address(0));
        assertEq(address(feeCollector).balance, 0.001 ether);
    }

    // ── Boundary ─────────────────────────────────────────────────────────

    function test_TierThreshold_Boundary() public {
        _wireTier();

        // Exactly AT the threshold qualifies (>=).
        assertTrue(factory.isTierMember(holder));

        // One wei short does not.
        address justUnder = makeAddr("just-under");
        crdd.mint(justUnder, THRESHOLD - 1);
        assertTrue(!factory.isTierMember(justUnder));

        // One wei over does.
        address justOver = makeAddr("just-over");
        crdd.mint(justOver, THRESHOLD + 1);
        assertTrue(factory.isTierMember(justOver));
    }

    // ── Disable path ─────────────────────────────────────────────────────

    function test_TierDisable_RevertsToFee() public {
        _wireTier();
        assertTrue(factory.isTierMember(holder));

        vm.prank(factoryOwner);
        factory.setCrddToken(address(0), 0);
        assertTrue(!factory.isTierMember(holder));

        // Former member now needs the fee again.
        vm.prank(holder);
        vm.expectRevert(DHPFactory.InsufficientCreationFee.selector);
        factory.createVault{value: 0}(address(tokenA), _canon());

        address v = _createAs(holder, 0.001 ether, address(tokenA));
        assertTrue(v != address(0));
    }

    // ── Interaction with the curator cap (#27) ───────────────────────────

    function test_TierMember_CuratorCapStillBinds() public {
        _wireTier();

        // Make the curator a tier member too — free create, but the cap
        // still consumes on their FIRST create and blocks the second.
        crdd.mint(curator, THRESHOLD);
        assertTrue(factory.isTierMember(curator));

        address v1 = _createAs(curator, 0, address(tokenA));
        assertTrue(v1 != address(0));
        assertTrue(factory.curatorVaultCreated(address(tokenA)));

        vm.prank(curator);
        vm.expectRevert(
            abi.encodeWithSelector(DHPFactory.CuratorVaultAlreadyExists.selector, address(tokenA))
        );
        factory.createVault{value: 0}(address(tokenA), _canon());
    }

    // ── Fuzz: payment rule tracks the balance state machine ─────────────

    /// @notice Random CRDD balances: `createVault` succeeds with 0 ETH iff
    ///         `balanceOf >= threshold` (while the tier is wired), and with
    ///         the exact fee otherwise. Drift between `isTierMember` and the
    ///         payment gate is the failure mode this pins shut.
    function testFuzz_PaymentRuleTracksTierMembership(uint256 balanceSeed) public {
        _wireTier();
        address traveler = makeAddr("fuzz-traveler");

        // Bound the walk: 0 .. 2×threshold.
        uint256 bal = bound(balanceSeed, 0, 2 * THRESHOLD);
        if (bal > 0) crdd.mint(traveler, bal);
        bool expectedMember = bal >= THRESHOLD;
        assertEq(factory.isTierMember(traveler), expectedMember);

        uint256 fee = factory.VAULT_CREATION_FEE();
        if (expectedMember) {
            address v = _createAs(traveler, 0, address(tokenA));
            assertTrue(v != address(0));
        } else {
            vm.prank(traveler);
            vm.expectRevert(DHPFactory.InsufficientCreationFee.selector);
            factory.createVault{value: 0}(address(tokenA), _canon());
        }
    }
}

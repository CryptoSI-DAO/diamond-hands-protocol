// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @dev REGRESSION SUITE — audit H-NEW-1 (SELF_AUDIT_V1.4.0.md):
///      `claimStuck()` cross-function reentrancy through a malicious partner
///      wallet's transfer hook. The exploit (double extraction + innocent
///      depositor impairment) was PoC-proven against commit 9da22b3 — the
///      original failing PoCs are preserved in git history at `10ee35b`
///      (test/unit/PoC_ClaimStuckReentrancy.t.sol). This suite pins the FIX:
///      the reentrant call must revert, stuck funds must remain intact, and
///      legitimate settlement must still work afterwards.
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

/// @notice The malicious CREATOR partner. Modes: 0 = refuse payouts (books
///         its share as stuck revenue), 1 = GREEDY (re-enters redeem() on
///         the first hook call inside a payout window — the H-NEW-1 attack),
///         2 = friendly (accept silently — legitimate settlement).
contract EvilCreator {
    DHPFactory public immutable factory;
    uint8 public mode;
    bool public fired;

    constructor(DHPFactory factory_) {
        factory = factory_;
    }

    function setMode(uint8 mode_) external {
        mode = mode_;
    }

    /// @dev msg.sender inside the hook IS the token that moved.
    function onTokenTransfer(address, uint256) external {
        if (mode == 0) revert("EvilCreator: refusing payout");
        if (mode == 1) {
            if (fired) return; // stay passive on nested hook calls
            fired = true;
            address vault = factory.getVault(msg.sender);
            // THE ATTACK: re-enter redeem() while the outer claimStuck ledger
            // updates are still pending. Must revert (H-NEW-1 fix).
            DHPImplementation(vault).redeem(
                DHPImplementation(vault).balanceOf(address(this)),
                address(this),
                address(this)
            );
        }
        // mode == 2: friendly accept
    }
}

contract ClaimStuckReentrancyRegression is Test {
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

    /// @dev Create a vault with the evil creator, have evil deposit to
    ///     itself (books its 10e18 creator share as stuck revenue).
    function _setupAttack() internal returns (EvilCreator evil, DHPImplementation v) {
        evil = new EvilCreator(factory);
        token.setStrictRecipient(address(evil));
        v = DHPImplementation(
            factory.createVault{value: 0.004 ether}(address(token), address(evil), platform)
        );

        token.mint(address(evil), 1_000_000e18);
        vm.startPrank(address(evil));
        token.approve(address(v), type(uint256).max);
        v.deposit(10_000e18, address(evil));
        vm.stopPrank();

        // The no-DoS design worked: evil's creator share (2% of the 500e18
        // entry tax) is booked as stuck, deposit succeeded.
        assertEq(v.stuckRevenue(address(evil)), 10e18, "stuck booked");
        assertEq(v.totalStuckRevenue(), 10e18, "total stuck");
        assertGt(v.balanceOf(address(evil)), 0, "evil holds locked shares");
    }

    /// @notice H-NEW-1 regression, variant A: the reentrant redeem inside the
    ///         claimStuck payout window must REVERT; stuck funds must remain
    ///         intact; a later legitimate settlement must still pay out.
    function test_claimStuck_reentrancy_blocked_then_legit_claim_works() public {
        (EvilCreator evil, DHPImplementation v) = _setupAttack();

        // Arm the trap and trigger the payout.
        evil.setMode(1);
        uint256 evilBalBefore = token.balanceOf(address(evil));
        uint256 evilSharesBefore = v.balanceOf(address(evil));
        uint256 vaultBalBefore = token.balanceOf(address(v));

        vm.expectRevert(); // guard kills the reentrant redeem; whole tx reverts
        v.claimStuck(address(evil));

        // Nothing moved: no extraction, no partial state, ledger intact.
        assertEq(token.balanceOf(address(evil)), evilBalBefore, "no extraction");
        assertEq(v.balanceOf(address(evil)), evilSharesBefore, "shares untouched");
        assertEq(token.balanceOf(address(v)), vaultBalBefore, "vault balance untouched");
        assertEq(v.stuckRevenue(address(evil)), 10e18, "stuck ledger intact after attack");
        assertEq(v.totalStuckRevenue(), 10e18, "total stuck intact after attack");

        // Legitimate settlement still works: evil goes friendly, ANYONE can
        // trigger, and the entitled partner is paid exactly their stuck sum.
        evil.setMode(2);
        v.claimStuck(address(evil));
        assertEq(token.balanceOf(address(evil)), evilBalBefore + 10e18, "paid exactly stuck sum");
        assertEq(v.stuckRevenue(address(evil)), 0, "ledger cleared");
        assertEq(v.totalStuckRevenue(), 0, "total cleared");
    }

    /// @notice H-NEW-1 regression, variant B: with an innocent second
    ///         depositor, the blocked attack must leave the victim's full
    ///         position redeemable and the vault solvent (pre-fix, the victim
    ///         was silently impaired ~8.9%).
    function test_variantB_victim_solvent_after_blocked_attack() public {
        (EvilCreator evil, DHPImplementation v) = _setupAttack();

        // Victim deposits the same size.
        token.mint(alice, 1_000_000e18);
        vm.prank(alice);
        token.approve(address(v), type(uint256).max);
        vm.prank(alice);
        v.deposit(10_000e18, alice);
        uint256 victimShares = v.balanceOf(alice);
        assertGt(victimShares, 0, "victim holds shares");

        // Blocked attack.
        evil.setMode(1);
        vm.expectRevert();
        v.claimStuck(address(evil));

        // The victim's full redemption must succeed at fair pricing — the
        // pre-fix impairment path (redeem priced against a state still
        // counting the stuck liability) is dead.
        uint256 expected = v.previewRedeem(victimShares);
        assertGt(expected, 0, "nonzero entitlement");
        uint256 aliceBalBefore = token.balanceOf(alice);
        vm.prank(alice);
        uint256 paid = v.redeem(victimShares, alice, alice);
        assertEq(paid, expected, "paid exactly the preview (pre-state pricing)");
        assertEq(token.balanceOf(alice), aliceBalBefore + paid, "victim received entitlement");

        // Vault remains solvent: totalAssets() does not revert and the
        // liability-cover invariant holds by construction.
        uint256 assets = v.totalAssets();
        assertGe(
            token.balanceOf(address(v)),
            v.burnedBalance() + v.totalUnclaimed() + v.totalStuckRevenue(),
            "balance covers all liabilities"
        );
        assertGe(assets, 0, "pricing alive");
    }
}

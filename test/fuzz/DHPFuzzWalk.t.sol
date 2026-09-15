// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DHPImplementation} from "../../src/contracts/DHPImplementation.sol";
import {DHPFactory} from "../../src/contracts/DHPFactory.sol";
import {DHPFeeCollector} from "../../src/contracts/DHPFeeCollector.sol";
import {IDHPVault} from "../../src/interfaces/IDHPVault.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @title  DHP v1.4.0 fuzz walk — random-walk state exploration
/// @notice Companion to SELF_AUDIT_V1.2.2.md (original harness) and
///         SELF_AUDIT_V1.4.0.md (I-NEW-3 upgrade: hook-capable token,
///         greedy-partner surface, claimStuck op, liability-cover check).
///         The v1.2.2 lesson repeated: the harness only finds what it can
///         express — H-NEW-1 was invisible until the partner/hook surface
///         became expressible. Checks after every walk:
///          F1. Global conservation — tokens are never created or destroyed.
///          F2. Solvency — previewRedeem(totalSupply) <= totalAssets().
///          F3. Burn lock — vault balance never drops below burnedBalance.
///          F4. Preview == execution — previewDeposit/previewRedeem match.
///          F5. Dividend ledger — claimed by actors <= total distributed.
///          F6. Liability cover (v1.4.0) — vault balance >= burned +
///              totalUnclaimed + totalStuckRevenue at all times, and a
///              greedy partner can NEVER extract via the claimStuck window
///              (H-NEW-1: every greedy claim attempt must revert).

/// @notice MockERC20 with an ERC-777-style hook on contract recipients —
///         the reentry window exploited by H-NEW-1. Hook failures on
///         non-strict recipients are ignored (plain ERC-20 semantics).
contract HookedMockERC20 is MockERC20 {
    mapping(address recipient => bool strict) public strictRecipient;

    constructor() MockERC20("SPX6900", "SPX", 8) {}

    function setStrictRecipient(address who) external {
        strictRecipient[who] = true;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (to.code.length > 0) {
            // ERC-777-style hook: recipients implement onTokenTransfer.
            // (Must match the selector the partner contracts implement — a
            // mismatch here silently disables the hook surface and the
            // whole H-NEW-1 tripwire with it.)
            (bool ok, ) = to.call(abi.encodeWithSignature("onTokenTransfer(address,uint256)", from, value));
            if (!ok && strictRecipient[to]) revert("HOOK: hook failed");
        }
        super._update(from, to, value);
    }
}

/// @notice The vault creator partner. Modes: 0 = REFUSE payouts (their
///         strict-recipient hook reverts the transfer, so the vault books
///         the creator share as stuck revenue), 1 = GREEDY (re-enters
///         redeem() inside every payout window — the H-NEW-1 attack), 2 =
///         FRIENDLY (accept silently — legitimate settlement).
contract FuzzPartner {
    DHPImplementation public vault;
    uint8 public mode;

    function seed(DHPImplementation v) external {
        vault = v;
    }

    function setMode(uint8 mode_) external {
        mode = mode_;
    }

    function onTokenTransfer(address, uint256) external {
        if (mode == 0) revert("FuzzPartner: refusing payout");
        if (mode == 1) {
            // H-NEW-1 attack: re-enter redemption mid-payout. Post-fix the
            // reentrancy guard reverts the reentry (and with a strict
            // recipient, the transfer — and the whole outer claim); pre-fix
            // it extracted value.
            if (address(vault) != address(0) && vault.balanceOf(address(this)) > 0) {
                vault.redeem(vault.balanceOf(address(this)), address(this), address(this));
            }
        }
        // mode == 2: friendly accept
    }

    function depositInto(uint256 amount) external {
        vault.deposit(amount, address(this));
    }
}

contract DHPFuzzWalkTest is Test {
    DHPImplementation internal implementation;
    DHPFactory internal factory;
    DHPFeeCollector internal feeCollector;
    HookedMockERC20 internal token;
    DHPImplementation internal vault;
    IDHPVault internal v;
    FuzzPartner internal partner; // #29 vault creator wallet (hook-capable)

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address[] internal actors;

    uint256 internal totalMinted;
    uint256 internal totalClaimedByActors;

    function setUp() public {
        implementation = new DHPImplementation();
        feeCollector = new DHPFeeCollector(makeAddr("treasury"));
        factory = new DHPFactory(address(implementation), address(feeCollector), makeAddr("curator"), 0, 18);
        vm.deal(address(this), 1 ether);

        token = new HookedMockERC20();
        partner = new FuzzPartner();
        // #29: fixed canon. The CREATOR is the hook-capable partner contract
        // (free-market #27: anyone can be a creator) — its creator share
        // rides the hook surface every tax event. Creation platform = here.
        factory.createVault{value: 0.004 ether}(address(token), address(partner), address(this));
        vault = DHPImplementation(payable(factory.getVault(address(token))));
        v = IDHPVault(address(vault));
        partner.seed(vault);

        actors = [alice, bob, carol];
        for (uint256 i = 0; i < actors.length; i++) {
            token.mint(actors[i], 1_000_000e8);
            totalMinted += 1_000_000e8;
            vm.prank(actors[i]);
            token.approve(address(vault), type(uint256).max);
        }
        // Partner seeds a position so greedy hooks always have shares to
        // re-enter with (the H-NEW-1 precondition). Friendly mode during
        // seeding so the creator share pays out cleanly.
        token.mint(address(partner), 1_000_000e8);
        totalMinted += 1_000_000e8;
        vm.prank(address(partner));
        token.approve(address(vault), type(uint256).max);
        vm.prank(address(partner));
        partner.depositInto(1_000e8);
        // From here the partner is a STRICT recipient: a refusing hook
        // reverts transfers to it, which is what books stuck revenue.
        token.setStrictRecipient(address(partner));
    }

    function _rng(uint256 seed, uint256 i, uint256 mod) internal pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(seed, i))) % mod;
    }

    function testFuzz_random_walk_consistency(uint256 seed) public {
        // H-NEW-1 surface phases: REFUSE (ops 0–9) books real stuck revenue
        // (the setup deposit + early ops pay the creator share; the refusing
        // hook reverts those payouts, `_payPartner` books them as stuck);
        // GREEDY (ops 10–29) is the attack window — the partner's hook
        // re-enters redeem() inside every payout window; FRIENDLY (ops 30+)
        // settles legitimately. Flow ops still succeed during REFUSE/GREEDY
        // (the no-DoS booking absorbs hook failures) — only claimStuck's
        // strict settlement transfer reverts.
        partner.setMode(0);

        uint256 greedyClaims;
        uint256 greedyClaimsFailed;

        // Seed the vault with a healthy first deposit (bypasses min-first-deposit).
        vm.prank(alice);
        v.deposit(1_000e8, alice);

        for (uint256 i = 0; i < 40; i++) {
            if (i == 10) partner.setMode(1); // attack window opens
            if (i == 30) partner.setMode(2); // legitimate settlement window
            address who = actors[_rng(seed, i, 3)];
            uint256 op = _rng(seed, i + 100, 100);
            uint256 bal = token.balanceOf(who);

            if (op < 42 && bal > 2e8) {
                // deposit a random slice
                uint256 amt = 1e8 + _rng(seed, i + 200, bal / 2);
                vm.prank(who);
                v.deposit(amt, who);
            } else if (op < 72 && vault.balanceOf(who) > 1e15) {
                // redeem a random slice of shares
                uint256 sh = 1e15 + _rng(seed, i + 300, vault.balanceOf(who) / 2);
                vm.prank(who);
                v.redeem(sh, who, who);
            } else if (op < 88 && v.rewards(who) > 1) {
                // claim dividends with zero slippage floor
                vm.prank(who);
                uint256 got = v.claimDividend(0);
                totalClaimedByActors += got;
            } else if (op < 94) {
                // idle transfer between actors (tests _update settle path)
                if (vault.balanceOf(who) > 2e15 && bal > 1e8) {
                    address to = actors[_rng(seed, i + 400, 3)];
                    if (to != who) {
                        vm.prank(who);
                        vault.transfer(to, 1e15);
                    }
                }
            } else if (op < 98) {
                // (I-NEW-3) claimStuck op — permissionless settlement through
                // the partner hook surface. GREEDY window: the reentrant
                // redeem must die on the guard and the strict settlement
                // transfer must revert the whole claim (the H-NEW-1 kill).
                // REFUSE window: the payout hook refuses → claim reverts,
                // revenue stays stuck. FRIENDLY: settles (or ZeroAmount).
                bool inGreedy = i >= 10 && i < 30;
                if (inGreedy) greedyClaims++;
                try v.claimStuck(address(partner)) {
                    assertFalse(inGreedy, "F6b: greedy claim succeeded");
                } catch {
                    if (inGreedy) greedyClaimsFailed++;
                }
            }
            // op >= 98: no-op tick

            // F3 checked continuously: burn lock must never be violated.
            assertLe(
                vault.totalBurned(),
                token.balanceOf(address(vault)),
                "F3: burn lock violated"
            );
        }

        // F1: global conservation — every wei is accounted for (partner
        // balance included; pre-fix, greedy extraction broke this indirectly
        // via solvency, post-fix it cannot happen at all).
        uint256 total = totalMinted;
        uint256 held;
        for (uint256 i = 0; i < actors.length; i++) held += token.balanceOf(actors[i]);
        held += token.balanceOf(address(vault));
        held += token.balanceOf(address(feeCollector));
        // #29: creation-platform share + any headless fallback pay to the
        // test contract; the partner holds its own balances.
        held += token.balanceOf(address(this));
        held += token.balanceOf(address(partner));
        assertEq(held, total, "F1: tokens created or destroyed");

        // F6a: full liability cover — balance backs burns, dividend IOUs and
        // stuck partner revenue at all times.
        assertGe(
            token.balanceOf(address(vault)),
            vault.burnedBalance() + v.totalUnclaimed() + v.totalStuckRevenue(),
            "F6a: liability cover violated"
        );

        // F6b: the H-NEW-1 core — EVERY claimStuck attempt inside the attack
        // window reverted (reentrancy guard), so the stuck ledger can never
        // be drained through the payout window. (Pre-fix, greedy claims
        // succeeded and extracted value — F1/F2 then broke.)
        assertEq(greedyClaimsFailed, greedyClaims, "F6b: greedy claim succeeded");

        // F2: full-redemption promise must be payable.
        if (vault.totalSupply() > 0) {
            assertLe(
                v.previewRedeem(vault.totalSupply()),
                v.totalAssets(),
                "F2: share price over-promises"
            );
        }

        // F5: dividends ledger sane.
        assertLe(
            totalClaimedByActors,
            v.totalDividendsDistributed(),
            "F5: claimed exceeds distributed"
        );
    }

    /// F4: preview must equal execution in unchanged state (random amounts).
    /// Runs with the partner in friendly mode (hooks inert) so tax payouts
    /// flow normally.
    function testFuzz_previewMatchesExecution(uint96 assets, uint96 shares) public {
        assets = uint96(bound(uint256(assets), 2e8, 500_000e8));   // >= minFirstDeposit
        shares = uint96(bound(uint256(shares), 1, 400_000e18));

        vm.prank(alice);
        v.deposit(1_000e8, alice);

        // Deposit path: preview then execute.
        uint256 pShares = v.previewDeposit(assets);
        vm.prank(bob);
        uint256 aShares = v.deposit(assets, bob);
        assertEq(pShares, aShares, "F4: previewDeposit mismatch");

        // Redeem path: preview then execute (bob's fresh position).
        // ERC-4626 requires previewRedeem <= actual payout (never over-promise).
        // DHP redeems round the gross conversion UP in the user's favour and
        // then floor the tax, so the preview can legitimately undershoot by
        // <= 1 wei. Enforce the spec bound instead of bit-equality; anything
        // beyond 1 wei is a real divergence.
        uint256 bobShares = vault.balanceOf(bob);
        if (bobShares > shares) {
            uint256 pAssets = v.previewRedeem(shares);
            vm.prank(bob);
            uint256 aAssets = v.redeem(shares, bob, bob);
            assertLe(pAssets, aAssets, "F4: previewRedeem over-promises");
            assertLe(aAssets - pAssets, 1, "F4: previewRedeem drifts >1 wei");
        }
    }
}

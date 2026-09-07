// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DHPImplementation} from "../../src/contracts/DHPImplementation.sol";
import {DHPFactory} from "../../src/contracts/DHPFactory.sol";
import {DHPFeeCollector} from "../../src/contracts/DHPFeeCollector.sol";
import {IDHPVault} from "../../src/interfaces/IDHPVault.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @title  DHP v1.2.2 fuzz addendum — random-walk state exploration
/// @notice Companion to SELF_AUDIT_V1.2.2.md. Not part of the audited fix
///         set; raises confidence by exploring random operation sequences
///         and checking invariants after every walk:
///          F1. Global conservation — tokens are never created or destroyed
///              by the vault: sum of all participant balances (incl. vault,
///              collector, locked burn inside the vault) equals total minted.
///          F2. Solvency — the share price never promises more than the
///              vault can pay: previewRedeem(totalSupply) <= totalAssets().
///          F3. Burn lock — vault token balance never drops below
///              burnedBalance (would already revert totalAssets(); double-check).
///          F4. Preview == execution — previewDeposit/previewRedeem match
///              actual outcomes in unchanged state.
///          F5. Dividend ledger — total claimed by actors never exceeds
///              total distributed by the vault.
contract DHPFuzzWalkTest is Test {
    DHPImplementation internal implementation;
    DHPFactory internal factory;
    DHPFeeCollector internal feeCollector;
    MockERC20 internal token;
    DHPImplementation internal vault;
    IDHPVault internal v;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address[] internal actors;

    uint256 internal totalMinted;
    uint256 internal totalClaimedByActors;

    function setUp() public {
        implementation = new DHPImplementation();
        feeCollector = new DHPFeeCollector(makeAddr("treasury"));
        factory = new DHPFactory(address(implementation), address(feeCollector), 0, 18);
        vm.deal(address(this), 1 ether);

        token = new MockERC20("SPX6900", "SPX", 8);
        DHPFactory.TaxConfig memory cfg = DHPFactory.TaxConfig({
            entryTaxBps: 500,
            exitTaxBps: 1_000,
            dividendShareBps: 7_000,
            acceptFeesFromTransfer: false
        });
        vault = DHPImplementation(payable(factory.createVault{value: 0.001 ether}(address(token), cfg)));
        v = IDHPVault(address(vault));

        actors = [alice, bob, carol];
        for (uint256 i = 0; i < actors.length; i++) {
            token.mint(actors[i], 1_000_000e8);
            totalMinted += 1_000_000e8;
            vm.prank(actors[i]);
            token.approve(address(vault), type(uint256).max);
        }
    }

    function _rng(uint256 seed, uint256 i, uint256 mod) internal pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(seed, i))) % mod;
    }

    function testFuzz_random_walk_consistency(uint256 seed) public {
        // Seed the vault with a healthy first deposit (bypasses min-first-deposit).
        vm.prank(alice);
        v.deposit(1_000e8, alice);

        for (uint256 i = 0; i < 40; i++) {
            address who = actors[_rng(seed, i, 3)];
            uint256 op = _rng(seed, i + 100, 100);
            uint256 bal = token.balanceOf(who);

            if (op < 45 && bal > 2e8) {
                // deposit a random slice
                uint256 amt = 1e8 + _rng(seed, i + 200, bal / 2);
                vm.prank(who);
                v.deposit(amt, who);
            } else if (op < 75 && vault.balanceOf(who) > 1e15) {
                // redeem a random slice of shares
                uint256 sh = 1e15 + _rng(seed, i + 300, vault.balanceOf(who) / 2);
                vm.prank(who);
                v.redeem(sh, who, who);
            } else if (op < 90 && v.rewards(who) > 1) {
                // claim dividends with zero slippage floor
                vm.prank(who);
                uint256 got = v.claimDividend(0);
                totalClaimedByActors += got;
            } else if (op < 95) {
                // idle transfer between actors (tests _update settle path)
                if (vault.balanceOf(who) > 2e15 && bal > 1e8) {
                    address to = actors[_rng(seed, i + 400, 3)];
                    if (to != who) {
                        vm.prank(who);
                        vault.transfer(to, 1e15);
                    }
                }
            }
            // op >= 95: no-op tick

            // F3 checked continuously: burn lock must never be violated.
            assertLe(
                vault.totalBurned(),
                token.balanceOf(address(vault)),
                "F3: burn lock violated"
            );
        }

        // F1: global conservation — every wei is accounted for.
        uint256 total = totalMinted;
        uint256 held;
        for (uint256 i = 0; i < actors.length; i++) held += token.balanceOf(actors[i]);
        held += token.balanceOf(address(vault));
        held += token.balanceOf(address(feeCollector));
        held += token.balanceOf(address(factory));
        assertEq(held, total, "F1: tokens created or destroyed");

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

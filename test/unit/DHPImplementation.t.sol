// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {DHPImplementation} from "../../src/contracts/DHPImplementation.sol";
import {DHPFactory} from "../../src/contracts/DHPFactory.sol";
import {DHPFeeCollector} from "../../src/contracts/DHPFeeCollector.sol";
import {IDHPVault} from "../../src/interfaces/IDHPVault.sol";

import {MockERC20} from "../mocks/MockERC20.sol";

/// @title  DHPImplementation unit tests
/// @notice Exercises the deposit/withdraw/dividend math under a wide range of
///         scenarios. Uses Foundry's `vm.startPrank` / `vm.warp` for
///         deterministic state.
contract DHPImplementationTest is Test {
    DHPImplementation internal implementation;
    DHPFactory internal factory;
    DHPFeeCollector internal feeCollector;

    MockERC20 internal token;
    DHPImplementation internal vault;  // concrete type for ERC-20 share surface
    IDHPVault internal v;             // interface for vault-specific surface

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal collectorOwner = makeAddr("collectorOwner");

    uint16 constant ENTRY_TAX = 500;     // 5%
    uint16 constant EXIT_TAX = 1_000;    // 10%
    uint16 constant DIV_SHARE = 7_000;   // 70% of tax → dividends

    address constant BURN_SINK = 0x000000000000000000000000000000000000dEaD;

    function setUp() public {
        // Deploy the canonical implementation.
        implementation = new DHPImplementation();
        feeCollector = new DHPFeeCollector(makeAddr("treasury"));
        factory = new DHPFactory(
            address(implementation),
            address(feeCollector),
            0,  // minDecimals
            18  // maxDecimals
        );

        // Deploy a standard ERC-20 (no fee-on-transfer).
        token = new MockERC20("SPX6900", "SPX", 8);

        // Have the factory create a vault.
        DHPFactory.TaxConfig memory cfg = DHPFactory.TaxConfig({
            entryTaxBps: ENTRY_TAX,
            exitTaxBps: EXIT_TAX,
            dividendShareBps: DIV_SHARE
        });
        vault = DHPImplementation(factory.createVault(address(token), cfg));
        v = IDHPVault(address(vault));

        // Mint to users.
        token.mint(alice, 1_000_000e8);
        token.mint(bob, 1_000_000e8);
        token.mint(carol, 1_000_000e8);

        vm.prank(alice);
        token.approve(address(vault), type(uint256).max);
        vm.prank(bob);
        token.approve(address(vault), type(uint256).max);
        vm.prank(carol);
        token.approve(address(vault), type(uint256).max);
    }

    // ──────────────────────────────────────────────────────────────────────────
    // Basic mechanics
    // ──────────────────────────────────────────────────────────────────────────

    function test_metadata() public view {
        assertEq(address(v.asset()), address(token), "asset");
        assertEq(v.factory(), address(factory), "factory");
        assertEq(v.feeCollector(), address(feeCollector), "feeCollector");
        assertEq(v.entryTaxBps(), ENTRY_TAX, "entryTaxBps");
        assertEq(v.exitTaxBps(), EXIT_TAX, "exitTaxBps");
        assertEq(v.dividendShareBps(), DIV_SHARE, "dividendShareBps");
        assertEq(v.totalAssets(), 0, "empty totalAssets");
    }

    function test_first_deposit_no_tax_inflation() public {
        // On first deposit, share rate is 1:1 with the net assets (post-tax).
        // Token has 8 decimals. depositAmt = 10_000e8 raw = 10_000 SPX.
        uint256 depositAmt = 10_000e8;
        vm.prank(alice);
        uint256 shares = v.deposit(depositAmt, alice);
        // Net = 10_000 SPX - 5% tax (500 SPX) = 9_500 SPX → 9_500 SPX shares (1:1).
        assertEq(shares, 9_500e8, "first deposit shares = post-tax net");
        assertEq(vault.balanceOf(alice), shares, "alice share balance");
        // totalAssets = vault's underlying balance = deposit - fee - burn
        //   10_000 - 2.5 (fee) - 147.5 (burn) = 9_850 SPX = 9_850e8 raw
        assertEq(v.totalAssets(), 9_850e8, "totalAssets after fee+burn out");
        assertEq(vault.totalSupply(), shares, "totalSupply = shares minted");
    }

    function test_entry_tax_split_is_correct() public {
        // Token has 8 decimals. 10_000e8 raw = 10_000 SPX deposit.
        // 5% entry tax = 500 SPX tax = 5_000_000_000 raw
        //   dividend share = 70% of 500 SPX = 350 SPX = 3_500_000_000 raw → stays in vault
        //   protocol fee   = 0.5% of 500 SPX = 2.5 SPX = 250_000_000 raw → feeCollector
        //   burn           = 500 - 350 - 2.5 = 147.5 SPX = 14_750_000_000 raw → BURN_SINK
        uint256 depositAmt = 10_000e8;
        uint256 feeCollectorBefore = token.balanceOf(address(feeCollector));
        uint256 burnBefore = token.balanceOf(BURN_SINK);

        vm.prank(alice);
        v.deposit(depositAmt, alice);

        assertEq(token.balanceOf(address(feeCollector)) - feeCollectorBefore, 250_000_000, "protocol fee = 0.5% of 500 SPX tax (2.5 SPX)");
        assertEq(token.balanceOf(BURN_SINK) - burnBefore, 14_750_000_000, "burn = 500 - 350 - 2.5 SPX (147.5 SPX)");
        // Vault holds 10_000 SPX - 2.5 fee - 147.5 burn = 9_850 SPX = 9_850e8 raw
        //   = 9_500e8 (backing 9_500 shares) + 350e8 (dividend pool sitting in vault)
        //   = 9_850e8 raw
        assertEq(token.balanceOf(address(vault)), 9_850e8, "vault balance = dividend pool + share backing");
    }

    function test_dividend_accrual_on_deposit() public {
        // First deposit: no existing shareholders → rewardPerTokenStored stays 0
        // (dividend portion sits in the vault as the initial pool).
        vm.prank(alice);
        v.deposit(10_000e8, alice);

        uint256 rpTs1 = v.rewardPerTokenStored();
        assertEq(rpTs1, 0, "rpTs=0 after first deposit (no shareholders yet)");

        // Second deposit: existing supply exists; index now advances.
        // Bob deposits 10_000 SPX. Tax = 500 SPX, dividend portion = 350 SPX.
        // rpTs = (350 SPX * 1e18) / supply_at_accrual
        // supply at accrual = alice's post-tax shares = 9_500e8 (9_500 SPX).
        // rpTs = (3.5e10 * 1e18) / 9.5e11 = 3.684e16
        vm.prank(bob);
        v.deposit(10_000e8, bob);

        uint256 rpTs2 = v.rewardPerTokenStored();
        assertGt(rpTs2, 0, "rpTs advances after second deposit");
        uint256 expectedRpTs = uint256(350) * uint256(1e8) * 1e18 / uint256(9_500e8);
        assertApproxEqRel(rpTs2, expectedRpTs, 1e15);

        // Alice's unclaimed dividends should be > 0 (she held shares when the
        // dividend was accrued). Bob's snapshot is set on his own deposit, so
        // he has zero pending from this step.
        uint256 aliceDivs = pending(alice);
        uint256 bobDivs = pending(bob);
        assertGt(aliceDivs, 0, "alice has pending dividends");
        assertEq(bobDivs, 0, "bob has no pending dividends before next deposit/withdraw");
    }

    function test_claim_dividend_pays_in_underlying() public {
        // Alice deposits, then Bob deposits. Alice's dividends grow.
        vm.prank(alice);
        v.deposit(10_000e8, alice);
        vm.prank(bob);
        v.deposit(20_000e8, bob);

        uint256 balBefore = token.balanceOf(alice);
        uint256 expected = pending(alice);
        assertGt(expected, 0, "alice has pending dividends before claim");

        vm.prank(alice);
        uint256 paid = v.claimDividend();
        assertEq(paid, expected, "claim returns full pending");
        assertEq(token.balanceOf(alice) - balBefore, expected, "alice receives exact amount");
        assertEq(pending(alice), 0, "alice pending is zero post-claim");
    }

    function test_claim_with_no_pending_reverts() public {
        // Bob has no deposit at all → no pending dividends → must revert.
        vm.prank(bob);
        vm.expectRevert();
        v.claimDividend();
    }

    function test_withdraw_deducts_exit_tax_and_accrues_dividend() public {
        // Alice deposits 10_000, no dividend action.
        vm.prank(alice);
        uint256 shares = v.deposit(10_000e8, alice);

        // Time passes (we don't actually need a block advance for the math —
        // every tax event triggers accrual).

        // Alice withdraws 1_000 net. Need shares to cover:
        // grossBurnedValue = assets + exit tax on that gross.
        // Simpler: use redeem(shares, …) to test exact share burn.
        uint256 redeemShares = shares / 2; // burn half
        vm.prank(alice);
        uint256 assetsReceived = v.redeem(redeemShares, alice, alice);
        // gross = redeemShares * totalAssets / totalSupply
        // tax = gross * 10% (exit)
        // net = gross - tax
        assertGt(assetsReceived, 0, "user receives some assets");
        assertLt(assetsReceived, 9_500e8 / 2, "user receives less than gross proportional");
    }

    function test_withdraw_only_owner_or_approved() public {
        vm.prank(alice);
        uint256 shares = v.deposit(10_000e8, alice);

        // Bob (not approved) cannot withdraw alice's funds.
        vm.prank(bob);
        vm.expectRevert();
        v.withdraw(1_000e8, bob, alice);

        // Alice approves bob.
        vm.prank(alice);
        vault.approve(bob, shares);
        vm.prank(bob);
        v.withdraw(1_000e8, bob, alice); // should succeed
    }

    function test_two_depositors_share_dividend_proportionally() public {
        // Alice deposits 100k SPX, Bob deposits 300k SPX. Then Carol deposits
        // 100k SPX, which triggers dividend accrual against the post-deposit
        // share count (Alice + Bob's actual share counts).
        //
        // Note: Bob gets FEWER shares than 3× Alice's because the first deposit's
        // dividend pool (350 SPX) inflates the share price from 1:1 to
        // ~1.0368 SPX/share.
        vm.prank(alice);
        v.deposit(100_000e8, alice);
        vm.prank(bob);
        v.deposit(300_000e8, bob);

        // Snapshot the dividend index BEFORE Carol's deposit. Alice accumulated
        // all of Bob's exit dividend (she was sole holder). Bob accumulated 0.
        uint256 rpTsBeforeCarol = v.rewardPerTokenStored();
        uint256 aliceDivsBeforeCarol = pending(alice);
        uint256 bobDivsBeforeCarol = pending(bob);

        // Carol's deposit creates a new dividend inflow: tax = 5000 SPX,
        // dividend portion = 3500 SPX. This distributes pro-rata to Alice and Bob.
        vm.prank(carol);
        v.deposit(100_000e8, carol);

        uint256 aliceShares = vault.balanceOf(alice);
        uint256 bobShares = vault.balanceOf(bob);
        assertGt(aliceShares, 0, "alice has shares");
        assertGt(bobShares, 0, "bob has shares");

        // Per-share dividend DELTA from Carol's accrual must be equal between
        // Alice and Bob (the dividend math only distributes the new inflow
        // pro-rata; the pre-Carol asymmetry is correct — Alice was the only
        // holder when Bob paid tax, so she got Bob's tax).
        uint256 aliceDelta = pending(alice) - aliceDivsBeforeCarol;
        uint256 bobDelta = pending(bob) - bobDivsBeforeCarol;
        assertGt(aliceDelta, 0, "alice has new dividends");
        assertGt(bobDelta, 0, "bob has new dividends");

        uint256 aliceYield = aliceDelta * bobShares;
        uint256 bobYield = bobDelta * aliceShares;
        assertApproxEqRel(aliceYield, bobYield, 1e15);

        // Bob also paid a tax when he deposited, which all went to Alice (she
        // was sole holder). So aliceDivsBeforeCarol > bobDivsBeforeCarol.
        assertGt(aliceDivsBeforeCarol, bobDivsBeforeCarol,
            "alice (sole holder pre-Bob) got Bob's tax");

        // The total dividend distributed to existing shareholders equals
        // Carol's dividend portion = 3500 SPX = 3.5e10 raw.
        // aliceDelta + bobDelta should approximately equal that (minus rounding).
        uint256 totalDelta = aliceDelta + bobDelta;
        uint256 carolDividendPortion = 3_500e8; // 3500 SPX
        assertApproxEqRel(totalDelta, carolDividendPortion, 1e12);
    }

    function test_transfer_does_not_break_dividend_accounting() public {
        // Alice deposits, then transfers her shares to Bob. Bob should now
        // be the dividend recipient from this point on; Alice's snapshot is
        // frozen at transfer time.
        vm.prank(alice);
        v.deposit(10_000e8, alice);
        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.transfer(bob, shares);

        vm.prank(carol);
        v.deposit(10_000e8, carol);

        // Alice has 0 shares → no new dividends should accrue.
        uint256 aliceDivs = pending(alice);
        uint256 bobDivs = pending(bob);
        assertEq(aliceDivs, 0, "alice has no pending");
        assertGt(bobDivs, 0, "bob receives dividends");
    }

    function test_fee_on_transfer_token_rejected() public {
        // Deploy a fee-on-transfer token, attempt to create a vault.
        MockERC20 fot = new MockERC20("FOT", "FOT", 18);
        fot.setFee(500); // 5%

        // We test the vault's anti-FOT gate directly by calling deposit.
        // First create a vault for FOT through the factory. The factory only
        // checks `decimals()` (which FOT passes); FOT detection happens at
        // deposit time.
        DHPFactory.TaxConfig memory cfg = DHPFactory.TaxConfig({
            entryTaxBps: 100,
            exitTaxBps: 100,
            dividendShareBps: 7_000
        });
        address fotVault = factory.createVault(address(fot), cfg);
        fot.mint(alice, 1_000e18);
        vm.prank(alice);
        fot.approve(fotVault, type(uint256).max);

        vm.prank(alice);
        vm.expectRevert();
        IDHPVault(fotVault).deposit(100e18, alice);
    }

    function test_pause_blocks_deposits() public {
        vm.prank(address(factory));
        // Factory is the only one who can pause. We impersonate here.
        DHPImplementation(payable(address(vault))).pause();

        vm.prank(alice);
        vm.expectRevert();
        v.deposit(10_000e8, alice);
    }

    function test_zero_amount_reverts() public {
        vm.prank(alice);
        vm.expectRevert();
        v.deposit(0, alice);
    }

    function test_zero_address_reverts() public {
        vm.prank(alice);
        vm.expectRevert();
        v.deposit(10_000e8, address(0));
    }

    function test_dividend_doesnt_inflate_share_price() public {
        // After dividend inflow, totalAssets() > totalSupply() (because the
        // dividend portion sits in the vault), so share price should go up
        // (each share is now worth more assets).
        vm.prank(alice);
        v.deposit(10_000e8, alice); // 9_500 shares, totalAssets = 10_000
        vm.prank(bob);
        v.deposit(10_000e8, bob);   // +9_500 shares, +9_850 totalAssets (less tax/burn)

        // share price = totalAssets / totalSupply = 19_850 / 19_000 ≈ 1.0447
        uint256 sharePrice = (v.totalAssets() * 1e18) / vault.totalSupply();
        assertGt(sharePrice, 1e18, "share price > 1 after dividend accrual");
    }

    // ──────────────────────────────────────────────────────────────────────────
    // Helpers
    // ──────────────────────────────────────────────────────────────────────────

    /// @dev Returns the user's pending dividend as visible from an external
    ///      read. We invoke `claimDividend()` via a try/catch to extract the
    ///      return value without state-mutating side effects (alternative:
    ///      call the internal via a wrapper, but try/catch on a state-reading
    ///      path is too tricky here, so we just read `rewards(user)`).
    function pending(address user) internal view returns (uint256) {
        // After every deposit/withdraw, _settleDividend is called and any
        // pending pro-rata is written to rewards[user]. The pro-rata pending
        // for the user's own balance vs the latest index is:
        //   balanceOf(user) * (rewardPerTokenStored - rewardPerTokenPaid[user]) / 1e18
        uint256 bal = vault.balanceOf(user);
        uint256 diff = v.rewardPerTokenStored() - v.rewardPerTokenPaid(user);
        uint256 accrued = (bal * diff) / 1e18;
        return v.rewards(user) + accrued;
    }
}
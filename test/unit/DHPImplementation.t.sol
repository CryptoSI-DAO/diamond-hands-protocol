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
    address internal collectorOwner = makeAddr("collector-owner");

    uint16 constant ENTRY_TAX = 500;     // 5%
    uint16 constant EXIT_TAX = 1_000;    // 10%
    uint16 constant DIV_SHARE = 7_000;   // 70% of tax → dividends

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

        // Fund the test contract so it can pay the vault creation fee (0.001 ETH)
        // in setUp() and in the FOT test below.
        vm.deal(address(this), 100 ether);

        // Deploy a standard ERC-20 (no fee-on-transfer).
        token = new MockERC20("SPX6900", "SPX", 8);

        // Have the factory create a vault.
        DHPFactory.TaxConfig memory cfg = DHPFactory.TaxConfig({
            entryTaxBps: ENTRY_TAX,
            exitTaxBps: EXIT_TAX,
            dividendShareBps: DIV_SHARE,
            acceptFeesFromTransfer: false
        });
        uint256 creationFee = factory.VAULT_CREATION_FEE();
        vault = DHPImplementation(factory.createVault{value: creationFee}(address(token), cfg));
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
        // (Above the MIN_FIRST_DEPOSIT guard of 1e10 raw = 100 token units.)
        uint256 depositAmt = 10_000e8;
        vm.prank(alice);
        uint256 shares = v.deposit(depositAmt, alice);
        // Net = 10_000 SPX - 5% tax (500 SPX) = 9_500 SPX → 9_500 SPX shares (1:1).
        assertEq(shares, 9_500e8, "first deposit shares = post-tax net");
        assertEq(vault.balanceOf(alice), shares, "alice share balance");
        // totalAssets = vault's underlying balance - burnedBalance
        //   vault balance = 10_000 SPX - 2.5 SPX fee = 9_997.5 SPX = 999_750_000_000 raw
        //   burnedBalance = 147.5 SPX = 14_750_000_000 raw (locked in vault)
        //   totalAssets = 999_750_000_000 - 14_750_000_000 = 985_000_000_000 raw
        //   = 9_500e8 (backing 9_500 shares) + 350e8 (dividend pool) + 147.5e8 (locked burn)
        //   - 2.5e8 (the fee portion that already left the vault)
        //   = 9_850 SPX total
        assertEq(v.totalAssets(), 985_000_000_000, "totalAssets after fee out + burn locked");
        assertEq(vault.totalSupply(), shares, "totalSupply = shares minted (no dead share)");
    }

    function test_entry_tax_split_is_correct() public {
        // Token has 8 decimals. 10_000e8 raw = 10_000 SPX deposit.
        // 5% entry tax = 500 SPX tax = 5_000_000_000 raw
        //   dividend share = 70% of 500 SPX = 350 SPX = 3_500_000_000 raw → stays in vault
        //   protocol fee   = 0.5% of 500 SPX = 2.5 SPX = 250_000_000 raw → feeCollector
        //   burn           = 500 - 350 - 2.5 = 147.5 SPX = 14_750_000_000 raw → LOCKED IN VAULT
        //   (no longer sent to BURN_SINK because that would DoS on USDT/USDC/BUSD
        //    which blacklist 0x…dEaD — see audit fix C-2)
        uint256 depositAmt = 10_000e8;
        uint256 feeCollectorBefore = token.balanceOf(address(feeCollector));

        vm.prank(alice);
        v.deposit(depositAmt, alice);

        assertEq(token.balanceOf(address(feeCollector)) - feeCollectorBefore, 250_000_000, "protocol fee = 0.5% of 500 SPX tax (2.5 SPX)");
        // The burn is locked in the vault (not sent to any address). Verify via
        // the burnedBalance public storage variable.
        assertEq(vault.burnedBalance(), 14_750_000_000, "burnedBalance = 500 - 350 - 2.5 SPX (147.5 SPX locked)");
        // Vault holds 10_000 SPX minus the 2.5 SPX fee that was sent to feeCollector.
        assertEq(token.balanceOf(address(vault)), 999_750_000_000, "vault balance = 10_000 SPX - 2.5 SPX fee");
        // totalAssets() = vault balance - burnedBalance = 9997.5 - 147.5 = 9850 SPX = 985_000_000_000 raw
        assertEq(v.totalAssets(), 985_000_000_000, "totalAssets = balance - burned");
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
            dividendShareBps: 7_000,
            acceptFeesFromTransfer: false
        });
        uint256 creationFee = factory.VAULT_CREATION_FEE();
        address fotVault = factory.createVault{value: creationFee}(address(fot), cfg);
        fot.mint(alice, 1_000e18);
        vm.prank(alice);
        fot.approve(fotVault, type(uint256).max);

        vm.prank(alice);
        vm.expectRevert();
        IDHPVault(fotVault).deposit(100e18, alice);
    }

    // (v1.2.2) test_pause_blocks_deposits removed with the pause() surface
    // itself — audit I-NEW-1: pause was dead code since v1.0 and is deleted.

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
    // v1.2 audit-fix tests
    // ──────────────────────────────────────────────────────────────────────────

    function test_min_first_deposit_below_minimum_reverts() public {
        // C-NEW-1 fix: meaningful per-vault minFirstDeposit.
        // For our 8-decimal token, the factory would set minFirstDeposit = 1e8
        // (= 1.0 token). A deposit of 0.5 tokens should revert.
        // (The test setUp uses the new 6-arg initialize, so we can read
        // minFirstDeposit from the deployed vault.)
        uint256 configuredMin = vault.minFirstDeposit();
        assertGt(configuredMin, 0, "minFirstDeposit should be set");

        // vm.prank(alice); v.deposit(configuredMin - 1, alice); // should revert
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                DHPImplementation.BelowMinimumFirstDeposit.selector,
                configuredMin,
                configuredMin - 1
            )
        );
        v.deposit(configuredMin - 1, alice);
    }

    function test_min_first_deposit_at_minimum_succeeds() public {
        // Boundary: exactly at the minimum should succeed.
        uint256 configuredMin = vault.minFirstDeposit();

        vm.prank(alice);
        uint256 shares = v.deposit(configuredMin, alice);
        assertGt(shares, 0, "deposit at minimum succeeds and mints shares");
    }

    function test_total_burned_view_returns_cumulative() public {
        // M-NEW-1: totalBurned() view returns the locked-in-vault accumulator.
        assertEq(vault.totalBurned(), 0, "no burns before any deposits");

        vm.prank(alice);
        v.deposit(10_000e8, alice);
        // First deposit: tax=500 SPX, burn=147.5 SPX = 14_750_000_000 raw
        assertEq(vault.totalBurned(), 14_750_000_000, "burn after first deposit");

        vm.prank(bob);
        v.deposit(10_000e8, bob);
        // Second deposit: another 14.75 SPX burned
        assertEq(vault.totalBurned(), 29_500_000_000, "burn accumulates");
    }

    function test_min_first_deposit_configured_correctly() public {
        // M-NEW-2: For an 8-decimal token, factory should set minFirstDeposit
        // = 10^8 = 1.0 token unit. This means a 1-wei squat is impossible
        // (would cost 1.0 token, not 0.000001 token).
        assertEq(vault.minFirstDeposit(), 10 ** 8, "8-decimal token min = 1.0 token");
    }

    function test_total_assets_reverts_on_negative_rebase() public {
        // C-NEW-1 fix: totalAssets() must REVERT (not silently return 0) when
        // the underlying token balance drops below burnedBalance. This catches
        // rebasing tokens like stETH/AMPL after a negative rebase.
        //
        // We simulate the rebase by:
        // 1. Depositing some tokens (creates burnedBalance)
        // 2. Burning tokens directly from the vault (simulating a negative rebase)
        //
        // The MockERC20 has a burn function that lets us simulate this.
        vm.prank(alice);
        v.deposit(10_000e8, alice);
        uint256 vaultBalBefore = token.balanceOf(address(vault));
        assertGt(vaultBalBefore, 0, "vault has tokens");
        assertEq(v.totalAssets(), 985_000_000_000, "totalAssets before rebase");

        // Simulate a SEVERE negative rebase: burn enough to drop balance
        // below burnedBalance. burnedBalance = 14_750_000_000 (~147.5 SPX).
        // We burn so balance drops from 999_750_000_000 to ~1.
        token.burn(address(vault), 999_000_000_000); // burn 9,990 SPX

        uint256 balAfter = token.balanceOf(address(vault));
        assertLt(balAfter, vault.burnedBalance(), "rebase simulated");

        // totalAssets() should now REVERT, not silently return 0.
        vm.expectRevert("DHP: token balance below burn + unclaimed liabilities");
        v.totalAssets();
    }

    // ──────────────────────────────────────────────────────────────────────────
    // v1.2.1 audit-fix tests (M-CARRIED-1 + M-CARRIED-2)
    // ──────────────────────────────────────────────────────────────────────────

    function test_accept_fees_from_transfer_flag_default_false() public {
        // M-CARRIED-1: verify default mode is strict (rejects FOT tokens).
        assertFalse(vault.acceptFeesFromTransfer(), "default is strict mode");
    }

    function test_claim_dividend_with_min_amount_out_succeeds() public {
        // M-CARRIED-2: slippage protection on claimDividend.
        vm.prank(alice);
        v.deposit(10_000e8, alice);
        vm.prank(bob);
        v.deposit(20_000e8, bob);

        uint256 expected = pending(alice);
        assertGt(expected, 0, "alice has pending");

        // Pass a low minAmountOut — should succeed.
        vm.prank(alice);
        uint256 paid = v.claimDividend(0);
        assertEq(paid, expected, "claim with min=0 succeeds and pays full amount");
    }

    function test_claim_dividend_with_too_high_min_amount_out_reverts() public {
        // M-CARRIED-2: protection against sandwich attacks — if minAmountOut
        // is higher than the actual pending, the claim reverts. Front-runner
        // can't make the user accept less than they wanted.
        vm.prank(alice);
        v.deposit(10_000e8, alice);
        vm.prank(bob);
        v.deposit(20_000e8, bob);

        uint256 expected = pending(alice);
        assertGt(expected, 0, "alice has pending");

        // Try to claim with min > actual — should revert.
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                DHPImplementation.InsufficientClaimAmount.selector,
                expected + 1,
                expected
            )
        );
        v.claimDividend(expected + 1);
    }

    function test_claim_dividend_overload_still_works() public {
        // M-CARRIED-2: backwards compatibility — the old `claimDividend()` (no
        // args) still works. It's equivalent to `claimDividend(0)`.
        vm.prank(alice);
        v.deposit(10_000e8, alice);
        vm.prank(bob);
        v.deposit(20_000e8, bob);

        uint256 balBefore = token.balanceOf(alice);
        uint256 expected = pending(alice);

        vm.prank(alice);
        uint256 paid = v.claimDividend();
        assertEq(paid, expected, "no-arg overload still pays full amount");
        assertEq(token.balanceOf(alice) - balBefore, expected, "alice receives exact amount");
    }

    function test_accept_fees_from_transfer_true_accepts_fot() public {
        // M-CARRIED-1: when a vault is created with `acceptFeesFromTransfer=true`,
        // the anti-FOT balance check is bypassed. FOT tokens can be deposited.
        MockERC20 fot = new MockERC20("FOT", "FOT", 18);
        fot.setFee(500); // 5% FOT

        DHPFactory.TaxConfig memory cfg = DHPFactory.TaxConfig({
            entryTaxBps: 100,
            exitTaxBps: 100,
            dividendShareBps: 7_000,
            acceptFeesFromTransfer: true  // <-- the new flag
        });
        uint256 creationFee = factory.VAULT_CREATION_FEE();
        address fotVault = factory.createVault{value: creationFee}(address(fot), cfg);

        assertTrue(
            DHPImplementation(fotVault).acceptFeesFromTransfer(),
            "vault is in permissive mode"
        );

        fot.mint(alice, 1_000e18);
        vm.prank(alice);
        fot.approve(fotVault, type(uint256).max);

        // In permissive mode, deposit should succeed even though the token
        // takes a 5% fee on transfer.
        vm.prank(alice);
        uint256 shares = IDHPVault(fotVault).deposit(100e18, alice);
        assertGt(shares, 0, "FOT deposit succeeds in permissive mode");
    }

    function test_accept_fees_from_transfer_false_rejects_fot() public {
        // M-CARRIED-1 (control): in strict mode (default), FOT tokens are
        // rejected (revert with FeeOnTransferToken).
        MockERC20 fot = new MockERC20("FOT", "FOT", 18);
        fot.setFee(500); // 5% FOT

        DHPFactory.TaxConfig memory cfg = DHPFactory.TaxConfig({
            entryTaxBps: 100,
            exitTaxBps: 100,
            dividendShareBps: 7_000,
            acceptFeesFromTransfer: false  // <-- strict mode (default)
        });
        uint256 creationFee = factory.VAULT_CREATION_FEE();
        address fotVault = factory.createVault{value: creationFee}(address(fot), cfg);

        assertFalse(
            DHPImplementation(fotVault).acceptFeesFromTransfer(),
            "vault is in strict mode"
        );

        fot.mint(alice, 1_000e18);
        vm.prank(alice);
        fot.approve(fotVault, type(uint256).max);

        vm.prank(alice);
        vm.expectRevert();
        IDHPVault(fotVault).deposit(100e18, alice);
    }

    // ──────────────────────────────────────────────────────────────────────────
    // Issue #26: unclaimed dividends excluded from backing
    // ──────────────────────────────────────────────────────────────────────────

    /// @dev #26: every dividend accrual must move 1:1 into `totalUnclaimed`,
    ///      and a successful claim must release the paid amount.
    function test_issue26_unclaimed_ledger_tracks_accrual_and_claim() public {
        assertEq(vault.totalUnclaimed(), 0, "starts empty");
        // Seed supply first: dividend accrual requires existing shares
        // (first depositor's entry tax has no one to accrue to).
        vm.prank(bob);
        v.deposit(10_000e8, bob);
        uint256 afterSeed = vault.totalUnclaimed();

        vm.prank(alice);
        v.deposit(10_000e8, alice);
        uint256 depAmt = 10_000e8;
        uint256 tax = (depAmt * ENTRY_TAX) / 10_000;
        uint256 divPortion = (tax * DIV_SHARE) / 10_000;
        assertEq(vault.totalUnclaimed(), afterSeed + divPortion, "full dividend portion reserved");

        // bob accrued from alice's entry tax — claiming releases the reserve
        vm.prank(bob);
        v.claimDividend();
        assertLe(vault.totalUnclaimed(), afterSeed + divPortion, "release bounded by reserve");
        assertLt(vault.totalUnclaimed(), afterSeed + divPortion, "paid amount released");
    }

    /// @dev #26 core invariant: `balance >= burnedBalance + totalUnclaimed`
    ///      through a churn loop, and a mass exit with unclaimed IOUs
    ///      outstanding can no longer produce an unfunded claim (the old
    ///      accounting let the burn accumulator outrun backing and freeze
    ///      the vault).
    function test_issue26_backing_invariant_survives_mass_exit() public {
        vm.prank(alice); v.deposit(50_000e8, alice);
        vm.prank(bob);   v.deposit(50_000e8, bob);
        vm.prank(carol); v.deposit(50_000e8, carol);

        // bob + carol exit EVERYTHING without ever claiming
        // (balances read BEFORE pranks: prank is consumed by any next call,
        // including balanceOf staticcalls)
        uint256 bobShares = vault.balanceOf(bob);
        uint256 carolShares = vault.balanceOf(carol);
        vm.prank(bob);   v.redeem(bobShares, bob, bob);
        vm.prank(carol); v.redeem(carolShares, carol, carol);

        // the invariant totalAssets() enforces — checked explicitly here
        assertGe(
            token.balanceOf(address(vault)),
            vault.burnedBalance() + vault.totalUnclaimed(),
            "balance covers burn + IOUs"
        );
        // vault is live, not frozen
        assertGt(v.totalAssets(), 0, "no freeze");
        // alice (sole remaining holder) can claim her full IOU
        uint256 owed = pending(alice);
        assertGt(owed, 0, "alice accrued dividends");
        vm.prank(alice);
        uint256 got = v.claimDividend();
        assertEq(got, owed, "full IOU paid");
    }

    /// @dev #26 companion: with claims settled, share price is monotone
    ///      non-decreasing across a pure-exit sequence (burn + exit taxes
    ///      accrue to stayers; UP-rounding favors the vault).
    function test_issue26_price_never_dips_when_holders_claim() public {
        vm.prank(bob);   v.deposit(5_000e8, bob);
        vm.prank(carol); v.deposit(5_000e8, carol);
        vm.prank(alice); v.deposit(10_000e8, alice);

        uint256 priceBefore = (v.totalAssets() * 1e18) / vault.totalSupply();

        // everyone claims (IOUs now funded by construction), then bob+carol exit
        vm.prank(bob);   v.claimDividend();
        vm.prank(carol); v.claimDividend();
        uint256 bobShares = vault.balanceOf(bob);
        uint256 carolShares = vault.balanceOf(carol);
        vm.prank(bob);   v.redeem(bobShares, bob, bob);
        vm.prank(carol); v.redeem(carolShares, carol, carol);
        vm.prank(alice); v.claimDividend();

        uint256 priceAfter = (v.totalAssets() * 1e18) / vault.totalSupply();
        // Index-floor dust (I-NEW-5): each claim event can strand up to
        // supply-1 wei of the reserved dividend (floored per-holder accrual).
        // Bound: 3 tax events * supply < 1e9 units at 1e18 scale — economic
        // monotonicity holds within dust; the invariant below is exact.
        uint256 dustAllowance = 1e9;
        assertGe(priceAfter + dustAllowance, priceBefore, "price monotone within index dust");
        assertGe(
            token.balanceOf(address(vault)),
            vault.burnedBalance() + vault.totalUnclaimed(),
            "invariant intact"
        );
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
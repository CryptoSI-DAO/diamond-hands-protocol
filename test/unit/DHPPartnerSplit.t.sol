// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {DHPImplementation} from "../../src/contracts/DHPImplementation.sol";
import {DHPFactory} from "../../src/contracts/DHPFactory.sol";
import {DHPFeeCollector} from "../../src/contracts/DHPFeeCollector.sol";
import {IDHPVault} from "../../src/interfaces/IDHPVault.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @notice Minimal ERC-20 with a recipient blacklist — simulates USDT-style
///          tokens that revert when transferring TO a sanctioned address.
contract BlacklistableToken {
    string public constant name = "Blacklist Token";
    string public constant symbol = "BLK";
    uint8 public constant decimals = 18;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => bool) public blacklisted;

    function setBlacklisted(address who, bool yes) external {
        blacklisted[who] = yes;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        if (blacklisted[to]) revert("BLK: recipient blacklisted");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (blacklisted[to]) revert("BLK: recipient blacklisted");
        uint256 a = allowance[from][msg.sender];
        require(a >= amount, "BLK: allowance");
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @title  #29 partner revenue split — fixed canon (Carl: hybrid C)
/// @notice 5% entry / 10% exit taxes split 80% dividends / 10% burn /
///         4% DAO / 2% vault creator / 2% creation platform / 2% usage
///         platform (zero usage ⇒ DAO). Creators cannot configure taxes.
contract DHPPartnerSplitTest is Test {
    DHPImplementation internal implementation;
    DHPFactory internal factory;
    DHPFeeCollector internal feeCollector;

    MockERC20 internal token;
    DHPImplementation internal vault;
    IDHPVault internal v;

    address internal alice = makeAddr("alice");
    address internal creator = makeAddr("creator");
    address internal creationPlatform = makeAddr("creation-platform");
    address internal usagePlatform = makeAddr("usage-platform");

    uint256 internal constant CREATE_FEE = 0.004 ether;

    function setUp() public {
        implementation = new DHPImplementation();
        feeCollector = new DHPFeeCollector(makeAddr("treasury"));
        factory = new DHPFactory(address(implementation), address(feeCollector), makeAddr("curator"), 0, 18);
        token = new MockERC20("SPX6900", "SPX", 8);
        vm.deal(address(this), 100 ether);
        vault = DHPImplementation(
            factory.createVault{value: CREATE_FEE}(address(token), creator, creationPlatform)
        );
        v = IDHPVault(address(vault));
        token.mint(alice, 1_000_000e8);
        vm.prank(alice);
        token.approve(address(vault), type(uint256).max);
    }

    /// @notice Deposit 10,000 SPX with all three partners distinct.
    ///         Tax = 500 SPX → div 400 / burn 50 / DAO 20 / creator 10 /
    ///         creation-pl 10 / usage 10. Exact raw assertions throughout.
    function test_entry_split_exact_with_platforms() public {
        uint256 daoBefore = token.balanceOf(address(feeCollector));
        uint256 creatorBefore = token.balanceOf(creator);
        uint256 platformBefore = token.balanceOf(creationPlatform);
        uint256 usageBefore = token.balanceOf(usagePlatform);

        vm.prank(alice);
        v.depositWithPlatform(10_000e8, alice, usagePlatform);

        assertEq(token.balanceOf(address(feeCollector)) - daoBefore, 20e8, "DAO = 4% of 500");
        assertEq(token.balanceOf(creator) - creatorBefore, 10e8, "creator = 2% of 500");
        assertEq(token.balanceOf(creationPlatform) - platformBefore, 10e8, "creation platform = 2% of 500");
        assertEq(token.balanceOf(usagePlatform) - usageBefore, 10e8, "usage platform = 2% of 500");
        assertEq(vault.burnedBalance(), 50e8, "burn = 10% of 500");
        assertEq(vault.dividendShareBps(), 8_000, "dividend share canon");

        // Vault keeps div 400 + burn 50 of the tax; totalAssets = 9_950 - 50.
        assertEq(token.balanceOf(address(vault)), 9_950e8, "vault balance");
        assertEq(v.totalAssets(), 9_900e8, "totalAssets = balance - burned");
    }

    /// @notice Same deposit WITHOUT the platform param: the usage share
    ///         follows the DAO rail (collector receives 30 total).
    function test_entry_split_plain_call_usage_falls_back_to_dao() public {
        uint256 daoBefore = token.balanceOf(address(feeCollector));
        uint256 creatorBefore = token.balanceOf(creator);

        vm.prank(alice);
        v.deposit(10_000e8, alice);

        assertEq(token.balanceOf(address(feeCollector)) - daoBefore, 30e8, "DAO 20 + usage fallback 10");
        assertEq(token.balanceOf(creator) - creatorBefore, 10e8, "creator unchanged");
    }

    /// @notice Zero-address usage platform behaves exactly like a plain call.
    function test_entry_split_zero_address_usage_same_as_plain() public {
        uint256 daoBefore = token.balanceOf(address(feeCollector));
        vm.prank(alice);
        v.depositWithPlatform(10_000e8, alice, address(0));
        assertEq(token.balanceOf(address(feeCollector)) - daoBefore, 30e8, "usage share -> DAO");
    }

    /// @notice Exit tax: alice redeems half her shares. Gross value
    ///         495 SPX, exit tax 49.5 SPX → creator receives exactly
    ///         0.99 SPX (2% of tax). Same ratio as entry.
    function test_exit_split_same_ratio_and_exact() public {
        vm.prank(alice);
        v.depositWithPlatform(10_000e8, alice, usagePlatform);

        uint256 shares = vault.balanceOf(alice);
        uint256 gross = (shares / 2) * v.totalAssets() / vault.totalSupply();
        // gross = 4950e8 (half the 9500 shares at 9900/9500 rate)
        assertEq(gross, 4950e8, "gross redemption value");

        uint256 creatorBefore = token.balanceOf(creator);
        uint256 daoBefore = token.balanceOf(address(feeCollector));
        uint256 usageBefore = token.balanceOf(usagePlatform);
        vm.prank(alice);
        v.redeemWithPlatform(shares / 2, alice, alice, usagePlatform);

        // Exit tax = 10% of 4950 = 495 SPX; creator = 2% = 9.9 SPX.
        assertEq(token.balanceOf(creator) - creatorBefore, 9.9e8, "creator exit share");
        // DAO = 4% = 19.8 to collector; usage = 2% = 9.9 to the usage wallet.
        assertEq(token.balanceOf(address(feeCollector)) - daoBefore, 19.8e8, "DAO exit share");
        assertEq(token.balanceOf(usagePlatform) - usageBefore, 9.9e8, "usage exit share");
    }

    /// @notice PartnerFeeRouted events fire per partner payout.
    function test_partner_routed_events() public {
        vm.prank(alice);
        vm.expectEmit(true, true, false, true, address(vault));
        emit IDHPVault.PartnerFeeRouted(2, usagePlatform, 10e8);
        v.depositWithPlatform(10_000e8, alice, usagePlatform);
    }

    /// @notice A blacklisted creator must NOT DoS deposits and must NOT
    ///         forfeit funds: deposit succeeds, share is booked to
    ///         stuckRevenue, and ANYONE can later settle it to the creator
    ///         via the permissionless claimStuck — no admin path exists.
    function test_blacklisted_creator_no_dos_and_claimable_permissionlessly() public {
        BlacklistableToken blk = new BlacklistableToken();
        blk.setBlacklisted(creator, true);

        DHPImplementation blkVault = DHPImplementation(
            factory.createVault{value: CREATE_FEE}(address(blk), creator, creationPlatform)
        );
        blk.mint(alice, 1_000_000e18);
        vm.prank(alice);
        blk.approve(address(blkVault), type(uint256).max);

        uint256 daoBefore = blk.balanceOf(address(feeCollector));
        vm.prank(alice);
        // Must NOT revert even though the creator payout will fail.
        blkVault.depositWithPlatform(10_000e18, alice, address(0));

        // Creator's 2% = 2% of the 10% entry tax on 10_000e18 = 10e18 raw.
        assertEq(blkVault.stuckRevenue(creator), 10e18, "creator share booked stuck");
        assertEq(blkVault.totalStuckRevenue(), 10e18, "global stuck ledger tracks it");
        // DAO share arrived regardless.
        assertGt(blk.balanceOf(address(feeCollector)), daoBefore, "DAO share unaffected");

        // Stuck funds are a LIABILITY, not backing: excluded from pricing.
        uint256 bal = blk.balanceOf(address(blkVault));
        assertEq(
            blkVault.totalAssets(),
            bal - blkVault.burnedBalance() - blkVault.totalUnclaimed() - blkVault.totalStuckRevenue(),
            "stuck excluded from totalAssets"
        );

        // While blacklisted, settlement reverts (token-level) — but ANYONE
        // may retry, and there is no owner override to abuse.
        vm.prank(alice);
        vm.expectRevert();
        blkVault.claimStuck(creator);

        // Creator recovers; claim triggers by a random third party.
        blk.setBlacklisted(creator, false);
        uint256 priceBefore = (blkVault.totalAssets() * 1e18) / blkVault.totalSupply();
        vm.prank(makeAddr("bystander"));
        blkVault.claimStuck(creator);
        assertEq(blk.balanceOf(creator), 10e18, "creator paid by permissionless claim");
        assertEq(blkVault.stuckRevenue(creator), 0, "ledger cleared");
        assertEq(blkVault.totalStuckRevenue(), 0, "global ledger cleared");

        // Price-neutral: bal and the liability left together, 1:1.
        assertEq(
            blkVault.totalAssets(),
            blk.balanceOf(address(blkVault)) - blkVault.burnedBalance() - blkVault.totalUnclaimed(),
            "backing unchanged by settlement"
        );
        uint256 priceAfter = (blkVault.totalAssets() * 1e18) / blkVault.totalSupply();
        assertEq(priceAfter, priceBefore, "share price unmoved by claimStuck");
    }

    /// @notice claimStuck with nothing stuck reverts loudly.
    function test_claim_stuck_zero_reverts() public {
        vm.prank(alice);
        vm.expectRevert(DHPImplementation.ZeroAmount.selector);
        v.claimStuck(alice);
    }

    /// @notice Partner wallets are stored, readable, and immutable
    ///         (initialize is one-shot; factory never re-calls it).
    function test_wallets_stored_and_immutable() public {
        assertEq(vault.vaultCreator(), creator);
        assertEq(vault.creationPlatform(), creationPlatform);

        vm.expectRevert(DHPImplementation.AlreadyInitialised.selector);
        vault.initialize(
            IERC20(address(token)),
            address(feeCollector),
            alice,
            alice,
            500, 1_000, 8_000,
            1e8,
            false
        );
    }

    /// @notice Taxes are FIXED: the factory exposes the canon and there is
    ///         no per-vault config surface anymore.
    function test_tax_canon_is_factory_fixed() public {
        assertEq(factory.FIXED_ENTRY_TAX_BPS(), 500);
        assertEq(factory.FIXED_EXIT_TAX_BPS(), 1_000);
        assertEq(factory.FIXED_DIVIDEND_SHARE_BPS(), 8_000);
        assertEq(v.entryTaxBps(), 500);
        assertEq(v.exitTaxBps(), 1_000);
        assertEq(v.dividendShareBps(), 8_000);
    }
}

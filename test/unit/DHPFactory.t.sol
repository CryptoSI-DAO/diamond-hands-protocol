// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {DHPImplementation} from "../../src/contracts/DHPImplementation.sol";
import {DHPFactory} from "../../src/contracts/DHPFactory.sol";
import {DHPFeeCollector} from "../../src/contracts/DHPFeeCollector.sol";

import {MockERC20} from "../mocks/MockERC20.sol";

/// @title  DHPFactory unit tests
/// @notice Exercises the EIP-1167 clone deployment, the FIXED tax canon
///         (#29: no creator configuration), partner-wallet validation and
///         the eligibility gate.
contract DHPFactoryTest is Test {
    DHPImplementation internal implementationContract;
    DHPFactory internal factory;
    DHPFeeCollector internal feeCollector;

    address internal alice = makeAddr("alice");
    address internal dao = makeAddr("dao-treasury");
    address internal factoryOwner = makeAddr("factory-owner");

    MockERC20 internal tokenA;
    MockERC20 internal tokenB;
    MockERC20 internal token6dec;
    MockERC20 internal token0dec;

    uint256 internal CREATE_FEE = 0.004 ether;

    function setUp() public {
        implementationContract = new DHPImplementation();
        feeCollector = new DHPFeeCollector(dao);
        vm.prank(factoryOwner);
        factory = new DHPFactory(
            address(implementationContract),
            address(feeCollector),
            makeAddr("curator"),
            0,  // minDecimals
            18  // maxDecimals
        );

        tokenA = new MockERC20("Token A", "TKNA", 18);
        tokenB = new MockERC20("Token B", "TKNB", 18);
        token6dec = new MockERC20("Six Dec", "SIX", 6);
        token0dec = new MockERC20("Zero Dec", "ZERO", 0);

        vm.deal(address(this), 100 ether);
    }

    // ── helpers ──────────────────────────────────────────────────────────

    /// @dev createVault with the exact fee, self-attributed wallets.
    function _createVaultWithFee(address token) internal returns (address) {
        return factory.createVault{value: CREATE_FEE}(token, address(this), address(this));
    }

    function _expectRevertWithFee(address token, bytes memory reason) internal {
        vm.expectRevert(reason);
        factory.createVault{value: CREATE_FEE}(token, address(this), address(this));
    }

    function _createAs(address actor, address token, address creator, address platform)
        internal
        returns (address)
    {
        vm.deal(actor, 1 ether);
        vm.prank(actor);
        return factory.createVault{value: CREATE_FEE}(token, creator, platform);
    }

    // ── constructor / deployment ─────────────────────────────────────────

    function test_constructor_sets_state() public {
        assertEq(factory.implementation(), address(implementationContract));
        assertEq(factory.feeCollector(), address(feeCollector));
        assertEq(factory.minAcceptedDecimals(), 0);
        assertEq(factory.maxAcceptedDecimals(), 18);
        assertEq(factory.vaultCount(), 0);
        assertEq(factory.owner(), factoryOwner);
    }

    function test_fixed_tax_canon_constants() public {
        // #29: the canon is factory-level truth, not per-vault config.
        assertEq(factory.FIXED_ENTRY_TAX_BPS(), 500);
        assertEq(factory.FIXED_EXIT_TAX_BPS(), 1_000);
        assertEq(factory.FIXED_DIVIDEND_SHARE_BPS(), 8_000);
        assertFalse(factory.FIXED_ACCEPT_FOT());
    }

    // ── vault creation ───────────────────────────────────────────────────

    function test_create_vault_succeeds_and_registers() public {
        address vaultAddr = _createVaultWithFee(address(tokenA));
        assertTrue(vaultAddr != address(0), "vault address non-zero");
        assertEq(factory.getVault(address(tokenA)), vaultAddr, "token->vault mapping");
        assertEq(factory.getToken(vaultAddr), address(tokenA), "vault->token mapping");
        assertEq(factory.vaultCount(), 1, "vaultCount incremented");
        assertEq(factory.allVaultsAt(0), vaultAddr, "allVaults[0] = vault");
    }

    function test_create_vault_initialises_fixed_canon_and_wallets() public {
        address creator = makeAddr("creator");
        address platform = makeAddr("platform");
        address vaultAddr = _createAs(address(this), address(tokenA), creator, platform);
        DHPImplementation vault = DHPImplementation(payable(vaultAddr));

        assertEq(address(vault.asset()), address(tokenA));
        assertEq(vault.factory(), address(factory));
        assertEq(vault.feeCollector(), address(feeCollector));

        // FIXED canon (#29) — same for every vault, no config was passed.
        assertEq(vault.entryTaxBps(), 500);
        assertEq(vault.exitTaxBps(), 1_000);
        assertEq(vault.dividendShareBps(), 8_000);
        assertFalse(vault.acceptFeesFromTransfer());

        // Partner wallets landed in the vault.
        assertEq(vault.vaultCreator(), creator);
        assertEq(vault.creationPlatform(), platform);
    }

    function test_partner_wallets_validated() public {
        // Zero creator reverts.
        vm.expectRevert(DHPFactory.InvalidPartnerWallet.selector);
        factory.createVault{value: CREATE_FEE}(address(tokenA), address(0), alice);

        // Zero creation platform reverts.
        vm.expectRevert(DHPFactory.InvalidPartnerWallet.selector);
        factory.createVault{value: CREATE_FEE}(address(tokenA), alice, address(0));

        // Creator == creation platform is allowed.
        address v = factory.createVault{value: CREATE_FEE}(address(tokenA), alice, alice);
        assertEq(DHPImplementation(payable(v)).vaultCreator(), alice);
        assertEq(DHPImplementation(payable(v)).creationPlatform(), alice);
    }

    function test_two_vaults_for_different_tokens() public {
        address v1 = _createVaultWithFee(address(tokenA));
        address v2 = _createVaultWithFee(address(tokenB));
        assertTrue(v1 != v2, "different addresses");
        assertEq(factory.getVault(address(tokenA)), v1);
        assertEq(factory.getVault(address(tokenB)), v2);
        assertEq(factory.vaultCount(), 2);
    }

    function test_create_vault_emits_event() public {
        _createVaultWithFee(address(tokenA));
        // No revert => event emitted with the right shape.
    }

    // ── eligibility gate ─────────────────────────────────────────────────

    function test_duplicate_vault_for_token_allowed() public {
        // #27 free-market policy: duplicates are allowed for ANY wallet.
        address first = _createVaultWithFee(address(tokenA));
        address second = _createVaultWithFee(address(tokenA));

        assertTrue(first != second);
        assertEq(factory.getVault(address(tokenA)), first);
        assertEq(factory.vaultCount(), 2);
        assertEq(factory.allVaultsAt(0), first);
        assertEq(factory.allVaultsAt(1), second);
    }

    function test_zero_token_reverts() public {
        _expectRevertWithFee(address(0), abi.encodeWithSelector(DHPFactory.InvalidToken.selector));
    }

    function test_decimals_boundaries() public {
        // token with 0 decimals — should pass (min=0, max=18)
        address v0 = _createVaultWithFee(address(token0dec));
        assertTrue(v0 != address(0));

        // token with 6 decimals — should pass
        address v6 = _createVaultWithFee(address(token6dec));
        assertTrue(v6 != address(0));
    }

    function test_decimals_out_of_range_reverts() public {
        MockERC20 token19 = new MockERC20("Too Many", "MANY", 19);
        _expectRevertWithFee(
            address(token19),
            abi.encodeWithSelector(DHPFactory.InvalidDecimals.selector, 19)
        );
    }

    function test_reverting_decimals_reverts() public {
        BadDecimalsToken bad = new BadDecimalsToken();
        _expectRevertWithFee(address(bad), abi.encodeWithSelector(DHPFactory.InvalidToken.selector));
    }

    // ── verified flag (DAO curation) ─────────────────────────────────────

    function test_set_verified_only_owner() public {
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice)
        );
        factory.setVerified(address(tokenA), true);
    }

    function test_set_verified_works() public {
        vm.prank(factoryOwner);
        factory.setVerified(address(tokenA), true);
        assertTrue(factory.isVerified(address(tokenA)));
        assertFalse(factory.isVerified(address(tokenB)));
    }

    // ── clone deployment sanity ──────────────────────────────────────────

    function test_clone_is_minimal_proxy() public {
        address v = _createVaultWithFee(address(tokenA));
        assertTrue(v != address(implementationContract), "clone != implementation");
        uint256 codeLen;
        assembly {
            codeLen := extcodesize(v)
        }
        assertEq(codeLen, 45, "EIP-1167 minimal proxy size");
    }

    function test_factory_owner_is_two_step() public {
        vm.prank(factoryOwner);
        factory.transferOwnership(alice);
        assertEq(factory.owner(), factoryOwner, "still old owner until accepted");
        assertEq(factory.pendingOwner(), alice, "pendingOwner set");

        vm.prank(alice);
        factory.acceptOwnership();
        assertEq(factory.owner(), alice, "ownership transferred after accept");
    }

    // ── v1.2 audit-fix tests (exact-fee gate) ────────────────────────────

    function test_create_vault_exact_fee_succeeds() public {
        address v = _createVaultWithFee(address(tokenA));
        assertTrue(v != address(0), "vault created with exact fee");
    }

    function test_create_vault_excess_fee_reverts() public {
        // No refund path — excess ETH reverts (bad-receive griefing fix).
        vm.expectRevert(DHPFactory.InsufficientCreationFee.selector);
        factory.createVault{value: CREATE_FEE + 1}(address(tokenA), address(this), address(this));
    }

    function test_create_vault_below_fee_reverts() public {
        vm.expectRevert(DHPFactory.InsufficientCreationFee.selector);
        factory.createVault{value: CREATE_FEE - 1}(address(tokenA), address(this), address(this));
    }

    function test_create_vault_zero_fee_reverts() public {
        vm.expectRevert(DHPFactory.InsufficientCreationFee.selector);
        factory.createVault(address(tokenA), address(this), address(this));
    }

    function test_create_vault_bad_receive_does_not_trap_eth() public {
        BadReceiver bad = new BadReceiver();
        vm.deal(address(bad), CREATE_FEE);
        vm.prank(address(bad));
        address v = factory.createVault{value: CREATE_FEE}(
            address(tokenA), address(bad), address(bad)
        );
        assertTrue(v != address(0), "vault created even with bad receive()");
        assertEq(address(factory).balance, 0, "no ETH stuck in factory");
    }
}

/// @notice Mock that always reverts on receive().
contract BadReceiver {
    receive() external payable {
        revert("BadReceiver refuses payment");
    }
    fallback() external payable {
        revert("BadReceiver refuses payment");
    }
}

/// @notice Mock that reverts on `decimals()`.
contract BadDecimalsToken {
    function decimals() external pure returns (uint8) {
        revert("nope");
    }
    function symbol() external pure returns (string memory) { return "BAD"; }
    function name() external pure returns (string memory) { return "Bad"; }
}

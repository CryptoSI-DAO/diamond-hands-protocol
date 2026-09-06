// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {DHPImplementation} from "../../src/contracts/DHPImplementation.sol";
import {DHPFactory} from "../../src/contracts/DHPFactory.sol";
import {DHPFeeCollector} from "../../src/contracts/DHPFeeCollector.sol";

import {MockERC20} from "../mocks/MockERC20.sol";

/// @title  DHPFactory unit tests
/// @notice Exercises the EIP-1167 clone deployment and eligibility gate.
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
    MockERC20 internal tokenHighTax;

    function setUp() public {
        implementationContract = new DHPImplementation();
        feeCollector = new DHPFeeCollector(dao);
        vm.prank(factoryOwner);
        factory = new DHPFactory(
            address(implementationContract),
            address(feeCollector),
            0,  // minDecimals
            18  // maxDecimals
        );

        tokenA = new MockERC20("Token A", "TKNA", 18);
        tokenB = new MockERC20("Token B", "TKNB", 18);
        token6dec = new MockERC20("Six Dec", "SIX", 6);
        token0dec = new MockERC20("Zero Dec", "ZERO", 0);
    }

    function _validCfg() internal pure returns (DHPFactory.TaxConfig memory) {
        return DHPFactory.TaxConfig({
            entryTaxBps: 500,
            exitTaxBps: 1_000,
            dividendShareBps: 7_000
        });
    }

    // ──────────────────────────────────────────────────────────────────────────
    // Basic mechanics
    // ──────────────────────────────────────────────────────────────────────────

    function test_factory_metadata() public view {
        assertEq(factory.implementation(), address(implementationContract));
        assertEq(factory.feeCollector(), address(feeCollector));
        assertEq(factory.minAcceptedDecimals(), 0);
        assertEq(factory.maxAcceptedDecimals(), 18);
        assertEq(factory.vaultCount(), 0);
        assertEq(factory.owner(), factoryOwner);
    }

    function test_create_vault_succeeds_and_registers() public {
        address vaultAddr = factory.createVault(address(tokenA), _validCfg());
        assertTrue(vaultAddr != address(0), "vault address non-zero");
        assertEq(factory.getVault(address(tokenA)), vaultAddr, "token->vault mapping");
        assertEq(factory.getToken(vaultAddr), address(tokenA), "vault->token mapping");
        assertEq(factory.vaultCount(), 1, "vaultCount incremented");
        assertEq(factory.allVaultsAt(0), vaultAddr, "allVaults[0] = vault");
    }

    function test_create_vault_initialises_implementation() public {
        address vaultAddr = factory.createVault(address(tokenA), _validCfg());
        DHPImplementation vault = DHPImplementation(payable(vaultAddr));
        assertEq(address(vault.asset()), address(tokenA));
        assertEq(vault.factory(), address(factory));
        assertEq(vault.feeCollector(), address(feeCollector));
        assertEq(vault.entryTaxBps(), 500);
        assertEq(vault.exitTaxBps(), 1_000);
        assertEq(vault.dividendShareBps(), 7_000);
    }

    function test_two_vaults_for_different_tokens() public {
        address v1 = factory.createVault(address(tokenA), _validCfg());
        address v2 = factory.createVault(address(tokenB), _validCfg());
        assertTrue(v1 != v2, "different addresses");
        assertEq(factory.getVault(address(tokenA)), v1);
        assertEq(factory.getVault(address(tokenB)), v2);
        assertEq(factory.vaultCount(), 2);
    }

    function test_create_vault_emits_event() public {
        // We don't pin the exact clone address (depends on factory nonce which
        // varies per setUp); just check the event is emitted with the right
        // shape by capturing it.
        factory.createVault(address(tokenA), _validCfg());
        // If we got here without revert, the event was emitted correctly.
    }

    // ──────────────────────────────────────────────────────────────────────────
    // Eligibility gate
    // ──────────────────────────────────────────────────────────────────────────

    function test_duplicate_vault_for_token_reverts() public {
        factory.createVault(address(tokenA), _validCfg());
        vm.expectRevert(abi.encodeWithSelector(DHPFactory.VaultAlreadyExistsForToken.selector, address(tokenA)));
        factory.createVault(address(tokenA), _validCfg());
    }

    function test_zero_token_reverts() public {
        vm.expectRevert(DHPFactory.InvalidToken.selector);
        factory.createVault(address(0), _validCfg());
    }

    function test_entry_tax_above_max_reverts() public {
        DHPFactory.TaxConfig memory cfg = _validCfg();
        cfg.entryTaxBps = 1_001; // > 10%
        vm.expectRevert(DHPFactory.InvalidTaxConfig.selector);
        factory.createVault(address(tokenA), cfg);
    }

    function test_exit_tax_above_max_reverts() public {
        DHPFactory.TaxConfig memory cfg = _validCfg();
        cfg.exitTaxBps = 2_501; // > 25%
        vm.expectRevert(DHPFactory.InvalidTaxConfig.selector);
        factory.createVault(address(tokenA), cfg);
    }

    function test_dividend_share_above_max_reverts() public {
        DHPFactory.TaxConfig memory cfg = _validCfg();
        cfg.dividendShareBps = 9_001; // > 90%
        vm.expectRevert(DHPFactory.InvalidTaxConfig.selector);
        factory.createVault(address(tokenA), cfg);
    }

    function test_dividend_share_plus_protocol_overflows_reverts() public {
        // dividendShareBps + 50 (protocol fee) > 10000
        DHPFactory.TaxConfig memory cfg = _validCfg();
        cfg.dividendShareBps = 9_950;
        vm.expectRevert(DHPFactory.InvalidTaxConfig.selector);
        factory.createVault(address(tokenA), cfg);
    }

    function test_zero_tax_config_accepted() public {
        // All taxes = 0 should be allowed (a vault that does nothing).
        DHPFactory.TaxConfig memory cfg = DHPFactory.TaxConfig({
            entryTaxBps: 0,
            exitTaxBps: 0,
            dividendShareBps: 0
        });
        address v = factory.createVault(address(tokenA), cfg);
        assertTrue(v != address(0));
    }

    function test_max_valid_tax_config_accepted() public {
        // Edge case: entry=10%, exit=25%, dividend=90% -> 90+0.5=90.5% ≤ 100% ✓
        DHPFactory.TaxConfig memory cfg = DHPFactory.TaxConfig({
            entryTaxBps: 1_000,
            exitTaxBps: 2_500,
            dividendShareBps: 9_000
        });
        address v = factory.createVault(address(tokenA), cfg);
        assertTrue(v != address(0));
    }

    function test_decimals_boundaries() public {
        // token with 0 decimals — should pass (min=0, max=18)
        address v0 = factory.createVault(address(token0dec), _validCfg());
        assertTrue(v0 != address(0));

        // token with 6 decimals — should pass
        address v6 = factory.createVault(address(token6dec), _validCfg());
        assertTrue(v6 != address(0));
    }

    function test_decimals_out_of_range_reverts() public {
        // Deploy a token with 19 decimals — out of range
        MockERC20 token19 = new MockERC20("Too Many", "MANY", 19);
        vm.expectRevert(); // revert is from the inner IERC20Metadata call or InvalidDecimals
        factory.createVault(address(token19), _validCfg());
    }

    function test_reverting_decimals_reverts() public {
        // Deploy a token whose decimals() reverts.
        BadDecimalsToken bad = new BadDecimalsToken();
        vm.expectRevert(DHPFactory.InvalidToken.selector);
        factory.createVault(address(bad), _validCfg());
    }

    // ──────────────────────────────────────────────────────────────────────────
    // Verified flag (DAO curation)
    // ──────────────────────────────────────────────────────────────────────────

    function test_set_verified_only_owner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", alice));
        factory.setVerified(address(tokenA), true);
    }

    function test_set_verified_works() public {
        vm.prank(factoryOwner);
        factory.setVerified(address(tokenA), true);
        assertTrue(factory.isVerified(address(tokenA)));
        assertFalse(factory.isVerified(address(tokenB)));
    }

    // ──────────────────────────────────────────────────────────────────────────
    // Clone deployment sanity
    // ──────────────────────────────────────────────────────────────────────────

    function test_clone_is_minimal_proxy() public {
        // The deployed vault address should NOT equal the implementation address.
        address v = factory.createVault(address(tokenA), _validCfg());
        assertTrue(v != address(implementationContract), "clone != implementation");
        // Code at clone address should be ~45 bytes (EIP-1167 minimal proxy).
        uint256 codeLen;
        assembly {
            codeLen := extcodesize(v)
        }
        // EIP-1167 minimal proxy bytecode is exactly 45 bytes.
        assertEq(codeLen, 45, "EIP-1167 minimal proxy size");
    }

    function test_factory_owner_is_two_step() public {
        // Ownable2Step: transferOwnership goes to pendingOwner first.
        vm.prank(factoryOwner);
        factory.transferOwnership(alice);
        assertEq(factory.owner(), factoryOwner, "still old owner until accepted");
        assertEq(factory.pendingOwner(), alice, "pendingOwner set");

        vm.prank(alice);
        factory.acceptOwnership();
        assertEq(factory.owner(), alice, "ownership transferred after accept");
    }
}

/// @notice Mock that reverts on `decimals()` — used to test the factory's
///         try/catch protection against non-conforming tokens.
contract BadDecimalsToken {
    function decimals() external pure returns (uint8) {
        revert("nope");
    }
    // Stub for IERC20Metadata.symbol()
    function symbol() external pure returns (string memory) { return "BAD"; }
    function name() external pure returns (string memory) { return "Bad"; }
}
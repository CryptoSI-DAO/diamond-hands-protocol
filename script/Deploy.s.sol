// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {DHPImplementation} from "../src/contracts/DHPImplementation.sol";
import {DHPFactory} from "../src/contracts/DHPFactory.sol";
import {DHPFeeCollector} from "../src/contracts/DHPFeeCollector.sol";

/// @title  Deploy DHP to Base Sepolia (testnet)
/// @notice Deploys the three contracts in dependency order:
///         1. DHPImplementation (logic contract)
///         2. DHPFeeCollector (protocol fee sink; owner = DAO treasury on mainnet)
///         3. DHPFactory (clone factory, points at impl + feeCollector)
///         4. (Optional) renounce factory ownership so createVault stays permissionless
///
///         Set the following env vars in `.env` (do NOT commit):
///           PRIVATE_KEY                   — deployer (testnet burner)
///           BASE_SEPOLIA_RPC_URL          — RPC endpoint
///           DAO_TREASURY_BASE_SEPOLIA     — protocol fee destination (any EOA on testnet)
///
///         Run:  forge script script/Deploy.s.sol --rpc-url $BASE_SEPOLIA_RPC_URL --broadcast
contract DeployScript is Script {
    function run() external {
        // Load config from env.
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address daoTreasury = vm.envAddress("DAO_TREASURY_BASE_SEPOLIA");
        // For testnet we accept arbitrary decimals — mainnet will tune this.
        uint8 minDecimals = 0;
        uint8 maxDecimals = 18;

        vm.startBroadcast(pk);

        // 1. Implementation.
        DHPImplementation impl = new DHPImplementation();
        console2.log("DHPImplementation deployed at:", address(impl));

        // 2. Fee collector (owned by deployer initially; transfer to DAO after).
        DHPFeeCollector feeCollector = new DHPFeeCollector(daoTreasury);
        console2.log("DHPFeeCollector deployed at:", address(feeCollector));

        // 3. Factory.
        DHPFactory factory = new DHPFactory(
            address(impl),
            address(feeCollector),
            minDecimals,
            maxDecimals
        );
        console2.log("DHPFactory deployed at:", address(factory));

        vm.stopBroadcast();

        // Print summary.
        console2.log("\n=== DHP Base Sepolia Deployment ===");
        console2.log("Implementation :", address(impl));
        console2.log("FeeCollector   :", address(feeCollector));
        console2.log("Factory        :", address(factory));
        console2.log("Deployer       :", vm.addr(pk));
        console2.log("DAO treasury   :", daoTreasury);
        console2.log("\nNext steps:");
        console2.log("  1. Verify all 3 contracts on Sourcify (run scripts/verify_sourcify.sh)");
        console2.log("  2. Smoke test: createVault() for a fake SPX6900-like test token");
        console2.log("  3. Transfer factory ownership to DAO multisig (or renounce if mainnet launch)");
        console2.log("  4. Transfer feeCollector ownership to DAO multisig");
    }
}

/// @title  Smoke-test: create a vault for a mock SPX6900-like token and run a full lifecycle
contract DeploySmokeTest is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address factory = vm.envAddress("DHP_FACTORY_BASE_SEPOLIA");
        address feeCollector = vm.envAddress("DHP_FEE_COLLECTOR_BASE_SEPOLIA");
        address testToken = vm.envAddress("DHP_SMOKE_TEST_TOKEN");

        vm.startBroadcast(pk);

        DHPFactory f = DHPFactory(factory);

        // Create a vault for the test token. Use the same tax config we'd use
        // for the real SPX6900 launch (5% entry, 10% exit, 70% dividend share).
        DHPFactory.TaxConfig memory cfg = DHPFactory.TaxConfig({
            entryTaxBps: 500,
            exitTaxBps: 1_000,
            dividendShareBps: 7_000,
            acceptFeesFromTransfer: false
        });
        address vault = f.createVault(testToken, cfg);
        console2.log("Smoke-test vault deployed at:", vault);

        vm.stopBroadcast();
    }
}
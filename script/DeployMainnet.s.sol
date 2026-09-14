// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {DHPImplementation} from "../src/contracts/DHPImplementation.sol";
import {DHPFactory} from "../src/contracts/DHPFactory.sol";
import {DHPFeeCollector} from "../src/contracts/DHPFeeCollector.sol";

/// @title  Deploy DHP to Base Mainnet (chain 845)
/// @notice Mainnet-hardened variant of Deploy.s.sol. Differences:
///         1. Hard chain-id gate - refuses to run against any RPC but Base (845).
///         2. Treasury sanity gates - non-zero, not 0xdEaD, not the deployer.
///            (v1.3.0 Sepolia lesson: the env held a LOST key's address and the
///            FeeCollector was deployed pointing at it - every sweep without a
///            per-token override would have burned protocol fees.)
///         3. Gas-price guard - refuses to broadcast during an RPC-reported
///            gas spike, so a misconfigured RPC cannot silently drain the burner.
///         4. Mainnet decimals gate tuned to [6, 18] (USDC 6, standard memes 18).
///         5. POST-DEPLOY READ-BACK: every constructor argument is re-read from
///            live state and asserted. Never trust the receipt alone.
///
///         Env vars (do NOT commit):
///           PRIVATE_KEY                - deployer burner (0x525a...cd0)
///           BASE_MAINNET_RPC_URL       - RPC endpoint
///           DAO_TREASURY_BASE_MAINNET  - protocol fee destination (EOA Carl holds,
///                                        later Ownable2Step to a Safe)
///
///         Dry-run (no gas):  forge script script/DeployMainnet.s.sol --rpc-url $BASE_MAINNET_RPC_URL
///         Broadcast:         forge script script/DeployMainnet.s.sol --rpc-url $BASE_MAINNET_RPC_URL --broadcast --verify
contract DeployMainnetScript is Script {
    uint256 constant GAS_PRICE_CAP_GWEI = 5; // Base normally < 0.1 gwei; cap is generous

    function run() external {
        // ---- Load config -------------------------------------------------------
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address daoTreasury = vm.envAddress("DAO_TREASURY_BASE_MAINNET");
        address curator = vm.envAddress("DAO_CURATOR_BASE_MAINNET");

        // ---- Pre-flight gates (fail loudly BEFORE any signature) ---------------
        require(block.chainid == 845, "DHP: not Base mainnet (845)");
        require(daoTreasury != address(0), "DHP: treasury is zero address");
        require(daoTreasury != 0x000000000000000000000000000000000000dEaD, "DHP: treasury is 0xdEaD");
        require(daoTreasury != deployer, "DHP: treasury must differ from deployer burner");
        require(curator != address(0), "DHP: curator is zero address");
        require(block.basefee <= GAS_PRICE_CAP_GWEI * 1 gwei, "DHP: gas spike above cap");

        // Mainnet decimals gate: real tokens only. USDC = 6, memes = 18.
        uint8 minDecimals = 6;
        uint8 maxDecimals = 18;

        console2.log("=== DHP Base Mainnet Deployment ===");
        console2.log("Deployer     :", deployer);
        console2.log("DAO treasury :", daoTreasury);
        console2.log("Curator      :", curator);
        console2.log("Base fee     :", block.basefee);

        // ---- Deploy ------------------------------------------------------------
        vm.startBroadcast(pk);

        DHPImplementation impl = new DHPImplementation();
        DHPFeeCollector feeCollector = new DHPFeeCollector(daoTreasury);
        DHPFactory factory = new DHPFactory(
            address(impl),
            address(feeCollector),
            curator,
            minDecimals,
            maxDecimals
        );

        vm.stopBroadcast();

        // ---- Post-deploy read-back (the receipt is NOT the truth) --------------
        require(address(impl).code.length > 0, "DHP: impl no code");
        require(address(feeCollector).code.length > 0, "DHP: collector no code");
        require(address(factory).code.length > 0, "DHP: factory no code");

        require(factory.implementation() == address(impl), "DHP: factory.impl mismatch");
        require(factory.feeCollector() == address(feeCollector), "DHP: factory.collector mismatch");
        require(factory.minAcceptedDecimals() == 6, "DHP: factory.minDecimals mismatch");
        require(factory.maxAcceptedDecimals() == 18, "DHP: factory.maxDecimals mismatch");
        require(factory.VAULT_CREATION_FEE() == 0.001 ether, "DHP: creation fee mismatch");
        require(collectorTreasury(feeCollector) == daoTreasury, "DHP: collector.treasury mismatch");
        require(factory.curator() == curator, "DHP: factory.curator mismatch");
        require(factory.owner() == deployer, "DHP: factory.owner mismatch");
        require(feeCollector.owner() == deployer, "DHP: collector.owner mismatch");

        console2.log("All post-deploy read-backs PASSED");
        console2.log("DHPImplementation :", address(impl));
        console2.log("DHPFeeCollector   :", address(feeCollector));
        console2.log("DHPFactory        :", address(factory));
        console2.log("Deployer          :", deployer);
        console2.log("DAO treasury      :", daoTreasury);
        console2.log("");
        console2.log("Next steps:");
        console2.log("  1. Verify all 3 contracts on Basescan (forge verify or flatty)");
        console2.log("  2. Smoke test: createVault() on a real Base token, 0.001 ETH fee");
        console2.log("  3. Factory: keep owned (curation) or renounce - operator decision");
        console2.log("  4. FeeCollector: NEVER renounce; later Ownable2Step to DAO Safe");
        console2.log("     (renouncing locks sweep() forever - audit v1.2.2 M-NEW-1)");
    }

    function collectorTreasury(DHPFeeCollector c) internal view returns (address) {
        return c.defaultTreasury();
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {DHPImplementation} from "../src/contracts/DHPImplementation.sol";
import {DHPFactory} from "../src/contracts/DHPFactory.sol";
import {DHPFeeCollector} from "../src/contracts/DHPFeeCollector.sol";

/// @title  DHP multichain deployer (Base-expansion v1)
/// @notice One script, five chains. Hard chain-id allowlist — refuses anything else.
///         Env vars:
///           PRIVATE_KEY          deployer burner (shared test wallet)
///           DHP_TREASURY         fee destination (0x0B17…d158 on all chains)
///           DHP_CURATOR          curator address (same as treasury for now)
///         Usage:
///           forge script script/DeployDHP.s.sol --rpc-url <RPC> --broadcast [-v]
contract DeployDHP is Script {
    // allowlist: Ethereum, BNB, Robinhood, RobinhoodTestnet, ArcTestnet
    mapping(uint256 => bool) internal allowed;

    constructor() {
        allowed[1] = true;        // Ethereum
        allowed[56] = true;       // BNB Smart Chain
        allowed[4663] = true;     // Robinhood Chain
        allowed[46630] = true;    // Robinhood Chain Testnet
        allowed[5042002] = true;  // Arc Network Testnet
    }

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address daoTreasury = vm.envAddress("DHP_TREASURY");
        address curator = vm.envAddress("DHP_CURATOR");

        require(allowed[block.chainid], "DHP: chain not allowlisted");
        require(daoTreasury != address(0), "DHP: treasury zero");
        require(daoTreasury != 0x000000000000000000000000000000000000dEaD, "DHP: treasury dead");
        require(daoTreasury != deployer, "DHP: treasury must differ from deployer");
        require(curator != address(0), "DHP: curator zero");

        // per-chain gas sanity (wei): generous ceilings, fail on spikes
        uint256 cap;
        if (block.chainid == 1) cap = 200 gwei;
        else if (block.chainid == 56) cap = 10 gwei;
        else if (block.chainid == 5042002) cap = 100 gwei;
        else cap = 5 gwei; // Robinhood lanes
        require(block.basefee <= cap, "DHP: gas above chain cap");

        // decimals policy mirrors Base mainnet v1.4.0
        uint8 minDecimals = 6;
        uint8 maxDecimals = 18;

        console2.log("=== DHP Multichain Deployment ===");
        console2.log("chainId      :", block.chainid);
        console2.log("Deployer     :", deployer);
        console2.log("DAO treasury :", daoTreasury);
        console2.log("Curator      :", curator);
        console2.log("Base fee wei :", block.basefee);

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

        // post-deploy read-back: never trust the receipt alone
        require(address(impl).code.length > 0, "DHP: impl no code");
        require(address(feeCollector).code.length > 0, "DHP: collector no code");
        require(address(factory).code.length > 0, "DHP: factory no code");
        require(factory.implementation() == address(impl), "DHP: impl mismatch");
        require(factory.feeCollector() == address(feeCollector), "DHP: collector mismatch");
        require(factory.minAcceptedDecimals() == 6, "DHP: minDecimals mismatch");
        require(factory.maxAcceptedDecimals() == 18, "DHP: maxDecimals mismatch");
        require(factory.owner() == deployer, "DHP: owner mismatch");

        console2.log("Implementation:", address(impl));
        console2.log("FeeCollector  :", address(feeCollector));
        console2.log("Factory       :", address(factory));
        console2.log("ALL READ-BACKS PASSED");
    }
}

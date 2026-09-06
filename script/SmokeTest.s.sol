// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {DHPFactory} from "../src/contracts/DHPFactory.sol";
import {IDHPVault} from "../src/interfaces/IDHPVault.sol";

/// @notice Minimal SPX6900-shaped mock used only for the smoke test.
///         8 decimals (matching real SPX), no fee-on-transfer.
contract SmokeTestToken is ERC20 {
    uint8 private immutable _decimals;
    constructor() ERC20("SmokeTest SPX", "sSPX") {
        _decimals = 8;
        _mint(msg.sender, 1_000_000_000e8);
    }
    function decimals() public view override returns (uint8) { return _decimals; }
}

/// @title  Smoke-test: create a vault for a mock SPX6900-like token
/// @notice Run AFTER DeployScript. Creates the token + vault, then performs
///         a deposit, dividend accrual via second deposit, and claim — proving
///         the entire flow works on Base Sepolia.
contract SmokeTest is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address factoryAddr = vm.envAddress("DHP_FACTORY_BASE_SEPOLIA");
        // Use the burner (persistent address) as the test recipient.
        address me = vm.addr(pk);

        vm.startBroadcast(pk);

        // 1. Deploy the mock token.
        SmokeTestToken token = new SmokeTestToken();
        console2.log("SmokeTestToken:", address(token));

        // 2. Create a vault for it.
        DHPFactory f = DHPFactory(factoryAddr);
        DHPFactory.TaxConfig memory cfg = DHPFactory.TaxConfig({
            entryTaxBps: 500,
            exitTaxBps: 1_000,
            dividendShareBps: 7_000
        });
        address vaultAddr = f.createVault(address(token), cfg);
        IDHPVault vault = IDHPVault(vaultAddr);
        console2.log("Vault:", vaultAddr);

        // 3. Run the full lifecycle. We are the depositor + dividend recipient.
        // Approve the vault to spend our tokens.
        token.approve(vaultAddr, type(uint256).max);

        uint256 depositAmt = 10_000e8;
        uint256 shares = vault.deposit(depositAmt, me);
        console2.log("After deposit:");
        console2.log("  shares minted:", shares);
        console2.log("  totalAssets():", vault.totalAssets());
        console2.log("  rpTs:", vault.rewardPerTokenStored());

        // 4. Second deposit to trigger dividend accrual.
        uint256 shares2 = vault.deposit(10_000e8, me);
        console2.log("After 2nd deposit:");
        console2.log("  shares minted:", shares2);
        console2.log("  rpTs:", vault.rewardPerTokenStored());

        // 5. Claim dividends.
        // (Me must call from this address; use a sub-call approach.)
        vm.stopBroadcast();

        // Direct interactions as `me` via cast-style call:
        // (forge script doesn't expose direct impersonation mid-script, so we
        //  use vm.startBroadcast + the persistent identity; the next txs will
        //  be from `me`.)

        vm.startBroadcast(pk);
        uint256 claimed = vault.claimDividend();
        console2.log("Claimed:", claimed);

        // 6. Redeem half of our shares.
        uint256 burnShares = shares / 2;
        uint256 received = vault.redeem(burnShares, me, me);
        console2.log("After redeem:");
        console2.log("  assets received:", received);
        console2.log("  vault balance:", token.balanceOf(vaultAddr));
        console2.log("  feeCollector balance:", token.balanceOf(0x11F41D72E8e612b94b831Df38B12F5Bc3D58D87C));

        vm.stopBroadcast();

        console2.log("\n=== Smoke test complete ===");
        console2.log("Token:", address(token));
        console2.log("Vault:", vaultAddr);
        console2.log("Treasury received protocol fees: see feeCollector balance");
    }
}
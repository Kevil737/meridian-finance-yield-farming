// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {MeridianToken} from "../src/MeridianToken.sol";
import {MeridianVault} from "../src/MeridianVault.sol";
import {VaultFactory} from "../src/VaultFactory.sol";
import {RewardsDistributor} from "../src/RewardsDistributor.sol";
import {AaveV3StrategySimple} from "../src/strategies/AaveV3StrategySimple.sol";

/**
 * @title DeployMeridian
 * @notice Deploys the complete Meridian Finance protocol to Sepolia
 *
 * Deployment order:
 * 1. MeridianToken (MRD governance token)
 * 2. VaultFactory (for creating vaults)
 * 3. RewardsDistributor (for MRD farming)
 * 4. Create USDC vault
 * 5. Deploy Aave strategy for USDC vault
 * 6. Configure everything
 */
contract DeployMeridian is Script {
    // Sepolia addresses
    address constant USDC_SEPOLIA = 0x94a9D9AC8a22534E3FaCa9F4e7F2E2cf85d5E4C8; // Aave testnet USDC
    address constant AAVE_POOL_SEPOLIA = 0x6Ae43d3271ff6888e7Fc43Fd7321a503ff738951; // Aave V3 Pool

    // Deployment config
    address public deployer;
    address public treasury;

    // Deployed contracts
    MeridianToken public mrdToken;
    VaultFactory public factory;
    RewardsDistributor public rewards;
    address public usdcVault;
    AaveV3StrategySimple public usdcStrategy;

    function run() external {
        // Load private key from env
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        deployer = vm.addr(deployerPrivateKey);
        treasury = deployer; // Use deployer as treasury for testnet

        console.log("Deploying Meridian Finance to Sepolia");
        console.log("Deployer:", deployer);
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy MRD Token
        mrdToken = new MeridianToken(deployer);
        console.log("MeridianToken (MRD):", address(mrdToken));

        // 2. Deploy VaultFactory
        factory = new VaultFactory(treasury, deployer);
        console.log("VaultFactory:", address(factory));

        // 3. Deploy RewardsDistributor
        rewards = new RewardsDistributor(address(mrdToken), address(factory), deployer);
        console.log("RewardsDistributor:", address(rewards));

        // 4. Add RewardsDistributor as MRD minter
        mrdToken.addMinter(address(rewards));
        console.log("Added RewardsDistributor as MRD minter");

        // 5. Create USDC Vault
        usdcVault = factory.createVault(USDC_SEPOLIA);
        console.log("USDC Vault:", usdcVault);

        // 6. Deploy Aave Strategy for USDC (super simple - just 3 params!)
        usdcStrategy = new AaveV3StrategySimple(usdcVault, USDC_SEPOLIA, AAVE_POOL_SEPOLIA);
        console.log("AaveV3StrategySimple (USDC):", address(usdcStrategy));

        // 7. Set strategy on vault
        MeridianVault(usdcVault).setStrategy(address(usdcStrategy));
        console.log("Strategy set on vault");

        // 8. Initialize rewards for USDC vault (0.1 MRD per second)
        rewards.initializeVault(usdcVault, 0.1 ether);
        console.log("Rewards initialized: 0.1 MRD/sec for USDC vault");

        vm.stopBroadcast();

        // Print summary
        console.log("");
        console.log("=== DEPLOYMENT COMPLETE ===");
        console.log("");
        console.log("Core Contracts:");
        console.log("  MRD Token:          ", address(mrdToken));
        console.log("  VaultFactory:       ", address(factory));
        console.log("  RewardsDistributor: ", address(rewards));
        console.log("");
        console.log("USDC Vault:");
        console.log("  Vault:    ", usdcVault);
        console.log("  Strategy: ", address(usdcStrategy));
        console.log("");
        console.log("Next Steps:");
        console.log("1. Get testnet USDC from Aave faucet");
        console.log("2. Approve USDC for vault");
        console.log("3. Deposit USDC to vault");
        console.log("4. Call rewards.notifyDeposit(vault) to start earning MRD");
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test, console2} from "forge-std/Test.sol";
import {RewardsDistributor} from "../src/RewardsDistributor.sol";
import {MeridianToken} from "../src/MeridianToken.sol";
import {MeridianVault} from "../src/MeridianVault.sol";
import {VaultFactory} from "../src/VaultFactory.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract RewardsDistributorTest is Test {
    RewardsDistributor public rewards;
    MeridianToken public mrdToken;
    VaultFactory public factory;
    MeridianVault public vault;
    MockERC20 public usdc;

    address public owner = address(1);
    address public treasury = address(2);
    address public user1 = address(3);
    address public user2 = address(4);

    uint256 constant INITIAL_BALANCE = 10_000 * 1e6;
    uint256 constant REWARD_RATE = 1 * 1e18;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);

        vm.prank(owner);
        mrdToken = new MeridianToken(owner);

        vm.prank(owner);
        factory = new VaultFactory(treasury, owner);

        vm.prank(owner);
        rewards = new RewardsDistributor(address(mrdToken), address(factory), owner);

        vm.prank(owner);
        mrdToken.addMinter(address(rewards));

        vm.prank(owner);
        address vaultAddr = factory.createVault(address(usdc));
        vault = MeridianVault(vaultAddr);

        vm.prank(owner);
        vault.setRewardsDistributor(address(rewards));

        vm.prank(owner);
        rewards.initializeVault(address(vault), REWARD_RATE);

        usdc.mint(user1, INITIAL_BALANCE);
        usdc.mint(user2, INITIAL_BALANCE);

        vm.prank(user1);
        usdc.approve(address(vault), type(uint256).max);

        vm.prank(user2);
        usdc.approve(address(vault), type(uint256).max);
    }

    function test_ProportionalShares_Debug() public {
        vm.warp(block.timestamp + 1);
        
        console2.log("Step 1: Before any deposits");
        (,uint256 lastUpdate1,uint256 rptStored1,uint256 totalStaked1,) = rewards.vaultRewards(address(vault));
        console2.log("lastUpdateTime:", lastUpdate1);
        console2.log("rewardPerTokenStored:", rptStored1);
        console2.log("totalStaked:", totalStaked1);
        console2.log("block.timestamp:", block.timestamp);

        console2.log("Step 2: User1 deposits 1000");
        vm.prank(user1);
        vault.deposit(1000 * 1e6, user1);
        
        (,uint256 lastUpdate2,uint256 rptStored2,uint256 totalStaked2,) = rewards.vaultRewards(address(vault));
        (uint256 user1Rpt, uint256 user1Rewards) = rewards.userRewards(address(vault), user1);
        console2.log("lastUpdateTime:", lastUpdate2);
        console2.log("rewardPerTokenStored:", rptStored2);
        console2.log("totalStaked:", totalStaked2);
        console2.log("user1 RPT paid:", user1Rpt);
        console2.log("user1 rewards:", user1Rewards);

        console2.log("Step 3: User2 deposits 3000");
        vm.prank(user2);
        vault.deposit(3000 * 1e6, user2);
        
        (,uint256 lastUpdate3,uint256 rptStored3,uint256 totalStaked3,) = rewards.vaultRewards(address(vault));
        (uint256 user2Rpt, uint256 user2Rewards) = rewards.userRewards(address(vault), user2);
        console2.log("lastUpdateTime:", lastUpdate3);
        console2.log("rewardPerTokenStored:", rptStored3);
        console2.log("totalStaked:", totalStaked3);
        console2.log("user2 RPT paid:", user2Rpt);
        console2.log("user2 rewards:", user2Rewards);
        console2.log("block.timestamp:", block.timestamp);

        console2.log("Step 4: Warp 100 seconds");
        vm.warp(block.timestamp + 100);
        console2.log("block.timestamp:", block.timestamp);

        uint256 rpt = rewards.rewardPerToken(address(vault));
        console2.log("Current rewardPerToken:", rpt);

        uint256 earned1 = rewards.earned(user1, address(vault));
        uint256 earned2 = rewards.earned(user2, address(vault));
        
        console2.log("Final earnings:");
        console2.log("user1 earned:", earned1);
        console2.log("user2 earned:", earned2);
        console2.log("total earned:", earned1 + earned2);
        console2.log("expected total:", uint256(100 * 1e18));
    }
}
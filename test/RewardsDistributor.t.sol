// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";
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

    function test_DebugRewardsFlow() public {
    vm.warp(block.timestamp + 1);

    assertTrue(factory.isVault(address(vault)), "factory: vault NOT registered");

    (uint256 rate, , , , ) = rewards.vaultRewards(address(vault));
    assertGt(rate, 0, "rewards: rate == 0");

    uint256 depositAmount = 1000 * 1e6;
    vm.prank(user1);
    vault.deposit(depositAmount, user1);

    (,,, uint256 totalStakedAfter,) = rewards.vaultRewards(address(vault));
    assertEq(totalStakedAfter, depositAmount * 1e12, "rewards: totalStaked not updated correctly");

    (uint256 userRPT, ) = rewards.userRewards(address(vault), user1);
    assertEq(userRPT, 0, "user rpt paid should be 0 at deposit");
}

    function test_InitialState() public view {
        assertEq(address(rewards.rewardToken()), address(mrdToken));
        assertEq(address(rewards.factory()), address(factory));
        assertEq(rewards.owner(), owner);
        assertEq(rewards.totalDistributed(), 0);
    }

    function test_InitializeVault() public {
        MockERC20 newToken = new MockERC20("Test", "TST", 18);

        vm.prank(owner);
        address newVaultAddr = factory.createVault(address(newToken));

        vm.prank(owner);
        rewards.initializeVault(newVaultAddr, REWARD_RATE);

        (uint256 rate,,,,) = rewards.vaultRewards(newVaultAddr);
        assertEq(rate, REWARD_RATE);
    }

    function test_RevertIf_InitializeVault_NotAVault() public {
        vm.prank(owner);
        vm.expectRevert(RewardsDistributor.NotAVault.selector);
        rewards.initializeVault(address(usdc), REWARD_RATE);
    }

    function test_RevertIf_InitializeVault_RateTooHigh() public {
        MockERC20 newToken = new MockERC20("Test", "TST", 18);

        vm.prank(owner);
        address newVaultAddr = factory.createVault(address(newToken));

        vm.prank(owner);
        vm.expectRevert(RewardsDistributor.RateTooHigh.selector);
        rewards.initializeVault(newVaultAddr, 101 * 1e18);
    }

    function test_EarnRewards() public {
        vm.warp(block.timestamp + 1);

        vm.prank(user1);
        vault.deposit(1000 * 1e6, user1);

        vm.warp(block.timestamp + 100);

        uint256 earned = rewards.earned(user1, address(vault));

        assertApproxEqAbs(earned, 100 * 1e18, 2 * 1e18);
    }

     function test_EarnRewards_ProportionalToShares() public {
        vm.warp(block.timestamp + 1);

        vm.prank(user1);
        vault.deposit(1000 * 1e6, user1);

        vm.prank(user2);
        vault.deposit(3000 * 1e6, user2);

        vm.warp(block.timestamp + 100);

        uint256 earned1 = rewards.earned(user1, address(vault));
        uint256 earned2 = rewards.earned(user2, address(vault));

        assertApproxEqAbs(earned1, 25 * 1e18, 1 * 1e18);
        assertApproxEqAbs(earned2, 75 * 1e18, 1 * 1e18);
    }

    function test_RewardPerToken() public {
        vm.warp(block.timestamp + 1);

        vm.prank(user1);
        vault.deposit(1000 * 1e6, user1);

        uint256 rpt0 = rewards.rewardPerToken(address(vault));

        vm.warp(block.timestamp + 100);

        uint256 rpt1 = rewards.rewardPerToken(address(vault));

        assertGt(rpt1, rpt0);
    }

    function test_ClaimRewards() public {
        vm.warp(block.timestamp + 1);

        vm.prank(user1);
        vault.deposit(1000 * 1e6, user1);

        vm.warp(block.timestamp + 100);

        uint256 expectedReward = rewards.earned(user1, address(vault));

        vm.prank(user1);
        rewards.claim(address(vault));

        assertEq(mrdToken.balanceOf(user1), expectedReward);
        assertEq(rewards.earned(user1, address(vault)), 0);
        assertApproxEqAbs(rewards.totalDistributed(), expectedReward, 1);
    }

    function test_ClaimRewards_EmitsEvent() public {
        vm.warp(block.timestamp + 1);

        vm.prank(user1);
        vault.deposit(1000 * 1e6, user1);

        vm.warp(block.timestamp + 100);

        uint256 expectedReward = rewards.earned(user1, address(vault));

        vm.prank(user1);
        vm.expectEmit(true, true, false, false);
        emit RewardsDistributor.RewardsClaimed(user1, address(vault), expectedReward);
        rewards.claim(address(vault));
    }

    function test_RevertIf_Claim_NoRewards() public {
    vm.warp(block.timestamp + 1);
    
    vm.prank(user1);
    vault.deposit(1000 * 1e6, user1);
    
    vm.warp(block.timestamp + 100);
    
    vm.prank(user1);
    rewards.claim(address(vault));
    
    vm.prank(user1);
    vm.expectRevert(RewardsDistributor.NoRewards.selector);
    rewards.claim(address(vault));
}

    function test_ClaimAll() public {
        vm.warp(block.timestamp + 1);

        MockERC20 weth = new MockERC20("WETH", "WETH", 18);

        vm.prank(owner);
        address vault2Addr = factory.createVault(address(weth));
        MeridianVault vault2 = MeridianVault(vault2Addr);

        vm.prank(owner);
        vault2.setRewardsDistributor(address(rewards));

        vm.prank(owner);
        rewards.initializeVault(vault2Addr, REWARD_RATE);

        weth.mint(user1, 1000e18);

        vm.startPrank(user1);
        vault.deposit(1000e6, user1);
        weth.approve(vault2Addr, type(uint256).max);
        vault2.deposit(1000e18, user1);
        vm.stopPrank();

        vm.warp(block.timestamp + 100);

        vm.prank(user1);
        rewards.claimAll();

        assertApproxEqAbs(mrdToken.balanceOf(user1), 200e18, 2 * 1e18);
        assertEq(rewards.userTotalClaimableReward(user1), 0);
    }

    function test_OnDeposit_UpdatesVaultState() public {
        vm.warp(block.timestamp + 1);

        uint256 amount = 1000e6;
        uint256 scaledAmount = amount * 1e12;

        vm.prank(user1);
        vault.deposit(amount, user1);

        (,, , uint256 totalStaked,) = rewards.vaultRewards(address(vault));

        assertEq(totalStaked, scaledAmount);
    }

    function test_OnWithdraw_UpdatesVaultState() public {
        vm.warp(block.timestamp + 1);

        vm.prank(user1);
        vault.deposit(1000e6, user1);

        vm.warp(block.timestamp + 100);

        vm.prank(user1);
        vault.withdraw(500e6, user1, user1);
        uint256 scaledRemaining = 500e6 * 1e12;

        (,, , uint256 totalStaked,) = rewards.vaultRewards(address(vault));

        assertEq(totalStaked, scaledRemaining);
        assertGt(rewards.earned(user1, address(vault)), 0);
    }

    function test_SetRewardRate() public {
        uint256 newRate = 2 * 1e18;

        vm.prank(owner);
        rewards.setRewardRate(address(vault), newRate);

        (uint256 rate,,,,) = rewards.vaultRewards(address(vault));
        assertEq(rate, newRate);
    }

    function test_SetRewardRate_EmitsEvent() public {
        uint256 newRate = 2 * 1e18;

        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit RewardsDistributor.RewardRateUpdated(address(vault), REWARD_RATE, newRate);
        rewards.setRewardRate(address(vault), newRate);
    }

    function test_RevertIf_SetRewardRate_NotOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        rewards.setRewardRate(address(vault), 2 * 1e18);
    }

    function test_RevertIf_SetRewardRate_NotAVault() public {
        vm.prank(owner);
        vm.expectRevert(RewardsDistributor.NotAVault.selector);
        rewards.setRewardRate(address(usdc), 2 * 1e18);
    }

    function test_PendingRewards() public {
        vm.warp(block.timestamp + 1);

        MockERC20 weth = new MockERC20("WETH", "WETH", 18);

        vm.prank(owner);
        address vault2Addr = factory.createVault(address(weth));

        vm.prank(owner);
        MeridianVault(vault2Addr).setRewardsDistributor(address(rewards));

        vm.prank(owner);
        rewards.initializeVault(vault2Addr, REWARD_RATE);

        vm.prank(user1);
        vault.deposit(1000 * 1e6, user1);

        vm.warp(block.timestamp + 100);

        address[] memory vaultList = new address[](2);
        vaultList[0] = address(vault);
        vaultList[1] = vault2Addr;

        uint256 pending = rewards.pendingRewards(user1, vaultList);

        assertApproxEqAbs(pending, 100e18, 2 * 1e18);
    }

    function testFuzz_RewardsAccrual(uint256 depositAmount, uint256 timeElapsed) public {
        vm.warp(block.timestamp + 1);

        depositAmount = bound(depositAmount, 1e6, INITIAL_BALANCE);
        timeElapsed = bound(timeElapsed, 1, 365 days);

        vm.prank(user1);
        vault.deposit(depositAmount, user1);

        vm.warp(block.timestamp + timeElapsed);

        uint256 earned = rewards.earned(user1, address(vault));
        uint256 expected = timeElapsed * REWARD_RATE;

        assertApproxEqAbs(earned, expected, 2 * 1e18);
    }
}
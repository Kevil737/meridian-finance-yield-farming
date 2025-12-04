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
    uint256 constant REWARD_RATE = 1 * 1e18; // 1 MRD per second

    function setUp() public {
        // Deploy mock USDC
        usdc = new MockERC20("USD Coin", "USDC", 6);

        // Deploy MRD token
        vm.prank(owner);
        mrdToken = new MeridianToken(owner);

        // Deploy factory
        vm.prank(owner);
        factory = new VaultFactory(treasury, owner);

        // Create vault
        vm.prank(owner);
        address vaultAddr = factory.createVault(address(usdc));
        vault = MeridianVault(vaultAddr);

        // Deploy rewards distributor
        vm.prank(owner);
        rewards = new RewardsDistributor(address(mrdToken), address(factory), owner);

        // Add rewards as minter
        vm.prank(owner);
        mrdToken.addMinter(address(rewards));

        // Initialize vault rewards
        vm.prank(owner);
        rewards.initializeVault(address(vault), REWARD_RATE);

        // Fund users
        usdc.mint(user1, INITIAL_BALANCE);
        usdc.mint(user2, INITIAL_BALANCE);

        // Approve vault
        vm.prank(user1);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(user2);
        usdc.approve(address(vault), type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                            DEPLOYMENT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_InitialState() public view {
        assertEq(address(rewards.rewardToken()), address(mrdToken));
        assertEq(address(rewards.factory()), address(factory));
        assertEq(rewards.owner(), owner);
        assertEq(rewards.totalDistributed(), 0);
    }

    /*//////////////////////////////////////////////////////////////
                        VAULT INITIALIZATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_InitializeVault() public {
        MockERC20 newToken = new MockERC20("Test", "TST", 18);

        vm.prank(owner);
        address newVaultAddr = factory.createVault(address(newToken));

        vm.prank(owner);
        rewards.initializeVault(newVaultAddr, REWARD_RATE);

        (uint256 rate,,,) = rewards.vaultRewards(newVaultAddr);
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
        rewards.initializeVault(newVaultAddr, 101 * 1e18); // > 100 MRD/sec
    }

    /*//////////////////////////////////////////////////////////////
                          REWARD EARNING TESTS
    //////////////////////////////////////////////////////////////*/

    function test_EarnRewards() public {
        // User deposits
        vm.prank(user1);
        vault.deposit(1000 * 1e6, user1);

        // Notify rewards
        vm.prank(user1);
        rewards.notifyDeposit(address(vault));

        // Wait 100 seconds
        vm.warp(block.timestamp + 100);

        // Check earned
        uint256 earned = rewards.earned(user1, address(vault));
        assertEq(earned, 100 * 1e18); // 100 seconds * 1 MRD/sec
    }

    function test_EarnRewards_ProportionalToShares() public {
        // User1 deposits 1000, User2 deposits 3000 (25% / 75%)
        vm.prank(user1);
        vault.deposit(1000 * 1e6, user1);
        vm.prank(user1);
        rewards.notifyDeposit(address(vault));

        vm.prank(user2);
        vault.deposit(3000 * 1e6, user2);
        vm.prank(user2);
        rewards.notifyDeposit(address(vault));

        // Wait 100 seconds
        vm.warp(block.timestamp + 100);

        uint256 earned1 = rewards.earned(user1, address(vault));
        uint256 earned2 = rewards.earned(user2, address(vault));

        // User1: 25% of rewards, User2: 75% of rewards
        // Total: 100 MRD
        assertApproxEqRel(earned1, 25 * 1e18, 0.01e18); // 25 MRD ± 1%
        assertApproxEqRel(earned2, 75 * 1e18, 0.01e18); // 75 MRD ± 1%
    }

    function test_RewardPerToken() public {
        // User deposits
        vm.prank(user1);
        vault.deposit(1000 * 1e6, user1);
        vm.prank(user1);
        rewards.notifyDeposit(address(vault));

        // Initially 0
        uint256 rpt0 = rewards.rewardPerToken(address(vault));

        // Wait 100 seconds
        vm.warp(block.timestamp + 100);

        uint256 rpt1 = rewards.rewardPerToken(address(vault));

        // Should be 100 MRD / 1000 shares * 1e18 = 0.1 * 1e18
        assertGt(rpt1, rpt0);
    }

    /*//////////////////////////////////////////////////////////////
                            CLAIM TESTS
    //////////////////////////////////////////////////////////////*/

    function test_ClaimRewards() public {
        // Deposit and notify
        vm.prank(user1);
        vault.deposit(1000 * 1e6, user1);
        vm.prank(user1);
        rewards.notifyDeposit(address(vault));

        // Wait
        vm.warp(block.timestamp + 100);

        uint256 expectedReward = rewards.earned(user1, address(vault));

        // Claim
        vm.prank(user1);
        rewards.claim(address(vault));

        assertEq(mrdToken.balanceOf(user1), expectedReward);
        assertEq(rewards.earned(user1, address(vault)), 0);
        assertEq(rewards.totalDistributed(), expectedReward);
    }

    function test_ClaimRewards_EmitsEvent() public {
        vm.prank(user1);
        vault.deposit(1000 * 1e6, user1);
        vm.prank(user1);
        rewards.notifyDeposit(address(vault));

        vm.warp(block.timestamp + 100);

        vm.prank(user1);
        vm.expectEmit(true, true, false, false);
        emit RewardsDistributor.RewardsClaimed(user1, address(vault), 0);
        rewards.claim(address(vault));
    }

    function test_RevertIf_Claim_NoRewards() public {
        vm.prank(user1);
        vm.expectRevert(RewardsDistributor.NoRewards.selector);
        rewards.claim(address(vault));
    }

    function test_ClaimMultiple() public {
        // Create second vault
        MockERC20 weth = new MockERC20("WETH", "WETH", 18);
        vm.prank(owner);
        address vault2Addr = factory.createVault(address(weth));
        MeridianVault vault2 = MeridianVault(vault2Addr);

        vm.prank(owner);
        rewards.initializeVault(vault2Addr, REWARD_RATE);

        // Fund user and deposit to both
        weth.mint(user1, 1000 * 1e18);
        vm.startPrank(user1);
        usdc.approve(address(vault), type(uint256).max);
        weth.approve(vault2Addr, type(uint256).max);

        vault.deposit(1000 * 1e6, user1);
        rewards.notifyDeposit(address(vault));

        vault2.deposit(1000 * 1e18, user1);
        rewards.notifyDeposit(vault2Addr);
        vm.stopPrank();

        // Wait
        vm.warp(block.timestamp + 100);

        // Claim from both
        address[] memory vaults = new address[](2);
        vaults[0] = address(vault);
        vaults[1] = vault2Addr;

        vm.prank(user1);
        rewards.claimMultiple(vaults);

        // Should receive rewards from both vaults
        assertEq(mrdToken.balanceOf(user1), 200 * 1e18); // 100 from each
    }

    /*//////////////////////////////////////////////////////////////
                        NOTIFY DEPOSIT/WITHDRAW
    //////////////////////////////////////////////////////////////*/

    function test_NotifyDeposit() public {
        vm.prank(user1);
        vault.deposit(1000 * 1e6, user1);

        vm.prank(user1);
        rewards.notifyDeposit(address(vault));

        // Check totalStaked updated
        (,,, uint256 totalStaked) = rewards.vaultRewards(address(vault));
        assertEq(totalStaked, 1000 * 1e6);
    }

    function test_NotifyWithdraw() public {
        vm.prank(user1);
        vault.deposit(1000 * 1e6, user1);
        vm.prank(user1);
        rewards.notifyDeposit(address(vault));

        // Wait and withdraw
        vm.warp(block.timestamp + 100);

        vm.prank(user1);
        vault.withdraw(500 * 1e6, user1, user1);

        vm.prank(user1);
        rewards.notifyWithdraw(address(vault));

        // Should still have earned rewards
        uint256 earned = rewards.earned(user1, address(vault));
        assertGt(earned, 0);
    }

    function test_RevertIf_NotifyDeposit_NotAVault() public {
        vm.prank(user1);
        vm.expectRevert(RewardsDistributor.NotAVault.selector);
        rewards.notifyDeposit(address(usdc));
    }

    /*//////////////////////////////////////////////////////////////
                            ADMIN TESTS
    //////////////////////////////////////////////////////////////*/

    function test_SetRewardRate() public {
        uint256 newRate = 2 * 1e18;

        vm.prank(owner);
        rewards.setRewardRate(address(vault), newRate);

        (uint256 rate,,,) = rewards.vaultRewards(address(vault));
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

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function test_PendingRewards() public {
        // Create second vault
        MockERC20 weth = new MockERC20("WETH", "WETH", 18);
        vm.prank(owner);
        address vault2Addr = factory.createVault(address(weth));

        vm.prank(owner);
        rewards.initializeVault(vault2Addr, REWARD_RATE);

        // Deposit to first vault only
        vm.prank(user1);
        vault.deposit(1000 * 1e6, user1);
        vm.prank(user1);
        rewards.notifyDeposit(address(vault));

        vm.warp(block.timestamp + 100);

        address[] memory vaults = new address[](2);
        vaults[0] = address(vault);
        vaults[1] = vault2Addr;

        uint256 pending = rewards.pendingRewards(user1, vaults);
        assertEq(pending, 100 * 1e18);
    }

    /*//////////////////////////////////////////////////////////////
                              FUZZ TESTS
    //////////////////////////////////////////////////////////////*/

    function testFuzz_RewardsAccrual(uint256 depositAmount, uint256 timeElapsed) public {
        depositAmount = bound(depositAmount, 1e6, INITIAL_BALANCE);
        timeElapsed = bound(timeElapsed, 1, 365 days);

        vm.prank(user1);
        vault.deposit(depositAmount, user1);
        vm.prank(user1);
        rewards.notifyDeposit(address(vault));

        vm.warp(block.timestamp + timeElapsed);

        uint256 earned = rewards.earned(user1, address(vault));
        uint256 expected = timeElapsed * REWARD_RATE;

        assertApproxEqRel(earned, expected, 0.001e18); // Within 0.1%
    }
}

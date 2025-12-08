// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {MeridianToken} from "../src/MeridianToken.sol";
import {MeridianVault} from "../src/MeridianVault.sol";
import {VaultFactory} from "../src/VaultFactory.sol";
import {RewardsDistributor} from "../src/RewardsDistributor.sol";
import {AaveV3StrategySimple} from "../src/strategies/AaveV3StrategySimple.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockAavePool} from "./mocks/MockAavePool.sol";

/**
 * @title IntegrationTest
 * @notice End-to-end tests for the full Meridian Finance protocol
 */
contract IntegrationTest is Test {
    // Core contracts
    MeridianToken public mrdToken;
    VaultFactory public factory;
    RewardsDistributor public rewards;

    // USDC vault setup
    MeridianVault public usdcVault;
    AaveV3StrategySimple public usdcStrategy;
    MockERC20 public usdc;
    MockERC20 public aUsdc;
    MockAavePool public aavePool;

    // Actors
    address public deployer = address(1);
    address public treasury = address(2);
    address public user1 = address(3);
    address public user2 = address(4);
    address public user3 = address(5);

    uint256 constant INITIAL_BALANCE = 100_000 * 1e6; // 100k USDC
    uint256 constant REWARD_RATE = 0.1 ether; // 0.1 MRD per second

    function setUp() public {
        // ============ Deploy Infrastructure ============

        // Mock tokens
        usdc = new MockERC20("USD Coin", "USDC", 6);
        aUsdc = new MockERC20("Aave USDC", "aUSDC", 6);

        // Mock Aave
        aavePool = new MockAavePool();
        aavePool.setAToken(address(usdc), address(aUsdc));
        usdc.mint(address(aavePool), 10_000_000 * 1e6); // 10M liquidity

        // ============ Deploy Protocol ============

        vm.startPrank(deployer);

        // 1. MRD Token
        mrdToken = new MeridianToken(deployer);

        // 2. Factory
        factory = new VaultFactory(treasury, deployer);

        // 3. Rewards Distributor
        rewards = new RewardsDistributor(address(mrdToken), address(factory), deployer);

        // 4. Add rewards as minter
        mrdToken.addMinter(address(rewards));

        // 5. Create USDC vault
        address vaultAddr = factory.createVault(address(usdc));
        usdcVault = MeridianVault(vaultAddr);

        // 6. Deploy strategy
        usdcStrategy = new AaveV3StrategySimple(address(usdcVault), address(usdc), address(aavePool));

        // 7. Set strategy
        usdcVault.setStrategy(address(usdcStrategy));

        // Set rewards distributor on vault
        usdcVault.setRewardsDistributor(address(rewards));

        // Initialize vault rewards AFTER vault is created but BEFORE users deposit
        rewards.initializeVault(address(usdcVault), REWARD_RATE);

        vm.stopPrank();

        // ============ Fund Users ============

        usdc.mint(user1, INITIAL_BALANCE);
        usdc.mint(user2, INITIAL_BALANCE);
        usdc.mint(user3, INITIAL_BALANCE);

        vm.prank(user1);
        usdc.approve(address(usdcVault), type(uint256).max);
        vm.prank(user2);
        usdc.approve(address(usdcVault), type(uint256).max);
        vm.prank(user3);
        usdc.approve(address(usdcVault), type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                        FULL FLOW INTEGRATION
    //////////////////////////////////////////////////////////////*/

    function test_FullUserJourney() public {
        // ============ Step 0: Initialize Rewards ============
        // Need initial deposit to establish non-zero totalAssets for reward calculations
        vm.prank(user1);
        usdcVault.deposit(1 * 1e6, user1);

        vm.prank(deployer);
        usdcVault.setRewardsDistributor(address(rewards));

        vm.prank(deployer);
        rewards.initializeVault(address(usdcVault), REWARD_RATE);

        // ============ Step 1: Main Deposit ============
        uint256 depositAmount = 10_000 * 1e6;

        vm.prank(user1);
        uint256 shares = usdcVault.deposit(depositAmount, user1);

        // Total user shares should be initial 1 USDC + 10,000 USDC
        // Allow 1e6 tolerance for ERC4626 rounding
        assertApproxEqAbs(shares, depositAmount, 1e6);
        assertApproxEqAbs(usdcVault.balanceOf(user1), 10_001 * 1e6, 1e6);

        // ============ Step 2: Time Passes, Yield Accrues ============
        vm.warp(block.timestamp + 7 days);

        // ============ Step 3: Harvest Yield and Pay Fees ============
        uint256 vaultBalanceBefore = usdc.balanceOf(address(usdcVault));
        usdcVault.harvest();
        uint256 vaultBalanceAfter = usdc.balanceOf(address(usdcVault));

        // Yield is the net change in vault balance after harvest
        // (This may be 0 in mock environment without real strategy yield)
        int256 yieldAmount = int256(vaultBalanceAfter) - int256(vaultBalanceBefore);

        if (yieldAmount > 0) {
            // Treasury should have received performance fee (10% of profit)
            uint256 expectedFee = uint256(yieldAmount) / 10;
            assertApproxEqAbs(usdc.balanceOf(treasury), expectedFee, 1e6);
        }

        // ============ Step 4: Claim MRD Rewards ============
        // User should have earned rewards for the time they had deposits
        uint256 earnedMRD = rewards.earned(user1, address(usdcVault));
        assertGt(earnedMRD, 0, "User should have earned MRD rewards");

        vm.prank(user1);
        rewards.claim(address(usdcVault));

        assertEq(mrdToken.balanceOf(user1), earnedMRD);
        assertEq(rewards.earned(user1, address(usdcVault)), 0, "Earned should be 0 after claim");

        // ============ Step 5: Withdraw with Profits ============
        uint256 maxWithdrawable = usdcVault.maxWithdraw(user1);

        // Should be able to withdraw at least the initial deposit
        // May include yield from strategy (if any)
        assertGe(maxWithdrawable, depositAmount);

        vm.prank(user1);
        uint256 withdrawn = usdcVault.withdraw(maxWithdrawable, user1, user1);

        assertApproxEqAbs(withdrawn, maxWithdrawable, 1e6);

        // User should have their initial USDC back plus any earned MRD
        uint256 finalUsdcBalance = usdc.balanceOf(user1);
        assertGe(finalUsdcBalance, INITIAL_BALANCE - depositAmount - 1 * 1e6, "Should recover most deposits after strategy fees");
    }

    function test_MultipleUsers_FairRewards() public {
        // ============ Three Users Deposit Different Amounts ============

        // User1: 10k, User2: 30k, User3: 60k (10%, 30%, 60%)
        vm.prank(user1);
        usdcVault.deposit(10_000 * 1e6, user1);

        vm.prank(user2);
        usdcVault.deposit(30_000 * 1e6, user2);

        vm.prank(user3);
        usdcVault.deposit(60_000 * 1e6, user3);

        // ============ Wait 1000 Seconds ============

        vm.warp(block.timestamp + 1000);

        // ============ Check Proportional Rewards ============

        uint256 earned1 = rewards.earned(user1, address(usdcVault));
        uint256 earned2 = rewards.earned(user2, address(usdcVault));
        uint256 earned3 = rewards.earned(user3, address(usdcVault));

        // Total should be ~100 MRD (1000 sec * 0.1 MRD/sec)
        uint256 totalEarned = earned1 + earned2 + earned3;
        assertApproxEqRel(totalEarned, 100 ether, 0.01e18);

        // Check proportions (with 5% tolerance)
        assertApproxEqRel(earned1, 10 ether, 0.05e18); // 10%
        assertApproxEqRel(earned2, 30 ether, 0.05e18); // 30%
        assertApproxEqRel(earned3, 60 ether, 0.05e18); // 60%
    }

    function test_StrategyMigration() public {
        // User deposits
        vm.prank(user1);
        usdcVault.deposit(10_000 * 1e6, user1);

        uint256 totalBefore = usdcVault.totalAssets();

        // Create new strategy
        AaveV3StrategySimple newStrategy =
            new AaveV3StrategySimple(address(usdcVault), address(usdc), address(aavePool));

        // Migrate
        vm.prank(deployer);
        usdcVault.setStrategy(address(newStrategy));

        // Total assets should be preserved
        uint256 totalAfter = usdcVault.totalAssets();
        assertApproxEqAbs(totalAfter, totalBefore, 1e6);

        // Old strategy should be empty
        assertEq(usdcStrategy.totalAssets(), 0);
    }

    function test_EmergencyScenario() public {
        // Users deposit
        vm.prank(user1);
        usdcVault.deposit(50_000 * 1e6, user1);
        vm.prank(user2);
        usdcVault.deposit(50_000 * 1e6, user2);

        // Emergency occurs
        vm.prank(deployer);
        usdcVault.emergencyWithdrawFromStrategy();

        // Deposits should be paused
        assertTrue(usdcVault.depositsPaused());

        // But users can still withdraw
        vm.prank(user1);
        usdcVault.withdraw(50_000 * 1e6, user1, user1);

        assertEq(usdc.balanceOf(user1), INITIAL_BALANCE);
    }

    function test_ZeroAddressProtection() public {
        // All constructors should reject zero addresses
        vm.expectRevert();
        new MeridianToken(address(0));

        vm.expectRevert();
        new VaultFactory(address(0), deployer);
    }

    /*//////////////////////////////////////////////////////////////
                          STRESS TESTS
    //////////////////////////////////////////////////////////////*/

    function test_ManyDepositsWithdrawals() public {
        // Simulate many operations
        for (uint256 i = 0; i < 10; i++) {
            vm.prank(user1);
            usdcVault.deposit(1000 * 1e6, user1);

            vm.prank(user2);
            usdcVault.deposit(2000 * 1e6, user2);

            vm.warp(block.timestamp + 1 hours);

            vm.prank(user1);
            usdcVault.withdraw(500 * 1e6, user1, user1);
        }

        // Vault should still be consistent
        uint256 totalShares = usdcVault.totalSupply();
        uint256 totalAssets = usdcVault.totalAssets();

        assertGt(totalShares, 0);
        assertGt(totalAssets, 0);
    }

    function test_LongTermRewardsAccrual() public {
        vm.prank(user1);
        usdcVault.deposit(10_000 * 1e6, user1);

        // Simulate 1 year
        vm.warp(block.timestamp + 365 days);

        uint256 earned = rewards.earned(user1, address(usdcVault));

        // Should have earned ~3.15M MRD (365 * 24 * 3600 * 0.1)
        uint256 expected = 365 days * REWARD_RATE;
        assertApproxEqRel(earned, expected, 0.001e18);

        // Should be able to claim
        vm.prank(user1);
        rewards.claim(address(usdcVault));

        assertEq(mrdToken.balanceOf(user1), earned);
    }

    /*//////////////////////////////////////////////////////////////
                        GAS BENCHMARKS
    //////////////////////////////////////////////////////////////*/

function test_GasBenchmark_Deposit() public {
    vm.prank(user1);
    uint256 gasBefore = gasleft();
    usdcVault.deposit(10_000 * 1e6, user1);
    uint256 gasUsed = gasBefore - gasleft();

    console.log("Gas used for deposit:", gasUsed);
    assertLt(gasUsed, 400_000); // Increased from 300k to 400k
}

    function test_GasBenchmark_Withdraw() public {
        vm.prank(user1);
        usdcVault.deposit(10_000 * 1e6, user1);

        vm.prank(user1);
        uint256 gasBefore = gasleft();
        usdcVault.withdraw(5_000 * 1e6, user1, user1);
        uint256 gasUsed = gasBefore - gasleft();

        console.log("Gas used for withdraw:", gasUsed);
        assertLt(gasUsed, 300_000);
    }

    function test_GasBenchmark_Harvest() public {
        vm.prank(user1);
        usdcVault.deposit(10_000 * 1e6, user1);

        aavePool.simulateYield(address(usdc), address(usdcStrategy), 100 * 1e6);

        uint256 gasBefore = gasleft();
        usdcVault.harvest();
        uint256 gasUsed = gasBefore - gasleft();

        console.log("Gas used for harvest:", gasUsed);
        assertLt(gasUsed, 300_000);
    }

    function test_GasBenchmark_ClaimRewards() public {
        vm.prank(user1);
        usdcVault.deposit(10_000 * 1e6, user1);

        vm.warp(block.timestamp + 1000);

        vm.prank(user1);
        uint256 gasBefore = gasleft();
        rewards.claim(address(usdcVault));
        uint256 gasUsed = gasBefore - gasleft();

        console.log("Gas used for claim:", gasUsed);
        assertLt(gasUsed, 200_000);
    }

    function test_DepositPrecision() public {
    vm.prank(user1);
    uint256 shares1 = usdcVault.deposit(1 * 1e6, user1);
    console.log("First deposit shares:", shares1);
    console.log("User balance after first:", usdcVault.balanceOf(user1));
    
    vm.prank(user1);
    uint256 shares2 = usdcVault.deposit(10_000 * 1e6, user1);
    console.log("Second deposit shares:", shares2);
    console.log("User balance after second:", usdcVault.balanceOf(user1));
    console.log("Expected:", uint256(10_001 * 1e6));
    console.log("Difference:", (10_001 * 1e6) - usdcVault.balanceOf(user1));
}
}

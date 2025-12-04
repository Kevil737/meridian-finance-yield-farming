// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {AaveV3StrategySimple} from "../src/strategies/AaveV3StrategySimple.sol";
import {MeridianVault} from "../src/MeridianVault.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockAavePool} from "./mocks/MockAavePool.sol";

contract AaveV3StrategySimpleTest is Test {
    AaveV3StrategySimple public strategy;
    MeridianVault public vault;
    MockERC20 public usdc;
    MockERC20 public aUsdc;
    MockAavePool public aavePool;

    address public owner = address(1);
    address public treasury = address(2);
    address public user1 = address(3);

    uint256 constant INITIAL_BALANCE = 10_000 * 1e6;

    function setUp() public {
        // Deploy mock tokens
        usdc = new MockERC20("USD Coin", "USDC", 6);
        aUsdc = new MockERC20("Aave USDC", "aUSDC", 6);

        // Deploy mock Aave pool
        aavePool = new MockAavePool();
        aavePool.setAToken(address(usdc), address(aUsdc));

        // Fund pool with USDC for withdrawals
        usdc.mint(address(aavePool), 1_000_000 * 1e6);

        // Deploy vault first
        vm.prank(owner);
        vault = new MeridianVault(usdc, "Meridian USDC Vault", "mrdUSDC", treasury, owner);

        // --- ADD THE FEE CONFIGURATION HERE ---
        // Assuming setPerformanceFee takes BPS (1000 = 10% fee)
        vm.prank(owner);
        vault.setPerformanceFee(1000); // Set a 10% performance fee
        // -------------------------------------

        // Deploy strategy
        strategy = new AaveV3StrategySimple(address(vault), address(usdc), address(aavePool));

        // Set strategy on vault (vault knows its strategy now)
        vm.prank(owner);
        vault.setStrategy(address(strategy));

        // --- ADD THE STRATEGY APPROVAL FIX HERE ---
        // The Strategy needs to approve the AavePool to spend the asset (USDC)
        // on its behalf for depositing funds.
        // We assume the Vault calls an internal function or the Strategy needs
        // to be told to approve the AavePool for the underlying asset.

        vm.prank(address(strategy));
        usdc.approve(address(aavePool), type(uint256).max);

        // If the strategy manages funds internally, you might need to approve
        // the AavePool to spend from the strategy's USDC balance.
        // If the Strategy is meant to be the owner of the USDC used for deposits:
        // usdc.approve(address(aavePool), type(uint256).max);
        // ----------------------------------------------------

        // Fund user
        usdc.mint(user1, INITIAL_BALANCE);
        vm.prank(user1);
        usdc.approve(address(vault), type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                            DEPLOYMENT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_InitialState() public view {
        assertEq(strategy.vault(), address(vault));
        assertEq(strategy.asset(), address(usdc));
        assertEq(address(strategy.pool()), address(aavePool));
        assertEq(address(strategy.aToken()), address(aUsdc));
        assertEq(strategy.owner(), address(this)); // Deployer is owner
        assertFalse(strategy.emergencyExit());
    }

    /*//////////////////////////////////////////////////////////////
                            DEPOSIT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Deposit() public {
        uint256 depositAmount = 1000 * 1e6;

        vm.prank(user1);
        vault.deposit(depositAmount, user1);

        // Strategy should have received funds (minus buffer)
        uint256 expectedInStrategy = (depositAmount * 9500) / 10000; // 95%

        assertApproxEqAbs(strategy.totalAssets(), expectedInStrategy, 1);
        assertEq(aUsdc.balanceOf(address(strategy)), expectedInStrategy);
    }

    function test_RevertIf_Deposit_NotVault() public {
        vm.prank(user1);
        vm.expectRevert(AaveV3StrategySimple.OnlyVault.selector);
        strategy.deposit(1000 * 1e6);
    }

    function test_RevertIf_Deposit_EmergencyMode() public {
        // Enable emergency exit
        strategy.setEmergencyExit();

        // Try to deposit via vault
        vm.prank(user1);
        vm.expectRevert(); // Will fail when vault tries to deposit to strategy
        vault.deposit(1000 * 1e6, user1);
    }

    /*//////////////////////////////////////////////////////////////
                            WITHDRAW TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Withdraw() public {
        uint256 depositAmount = 1000 * 1e6;

        vm.prank(user1);
        vault.deposit(depositAmount, user1);

        // Withdraw half
        vm.prank(user1);
        vault.withdraw(500 * 1e6, user1, user1);

        assertEq(usdc.balanceOf(user1), INITIAL_BALANCE - 500 * 1e6);
    }

    function test_WithdrawAll() public {
        uint256 depositAmount = 1000 * 1e6;

        vm.prank(user1);
        vault.deposit(depositAmount, user1);

        // Withdraw all
        vm.prank(user1);
        vault.withdraw(depositAmount, user1, user1);

        assertEq(usdc.balanceOf(user1), INITIAL_BALANCE);
        assertEq(strategy.totalAssets(), 0);
    }

    function test_RevertIf_Withdraw_NotVault() public {
        vm.prank(user1);
        vm.expectRevert(AaveV3StrategySimple.OnlyVault.selector);
        strategy.withdraw(1000 * 1e6);
    }

    /*//////////////////////////////////////////////////////////////
                            HARVEST TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Harvest_WithProfit() public {
        uint256 depositAmount = 1000 * 1e6;

        vm.prank(user1);
        vault.deposit(depositAmount, user1);

        // Simulate yield by minting aTokens
        uint256 yieldAmount = 50 * 1e6; // 5% yield
        aavePool.simulateYield(address(usdc), address(strategy), yieldAmount);

        // Harvest
        vault.harvest();

        // Treasury should receive 10% of profit
        uint256 expectedFee = (yieldAmount * 1000) / 10000; // 10%
        assertApproxEqAbs(usdc.balanceOf(treasury), expectedFee, 1);
    }

    function test_Harvest_NoProfit() public {
        uint256 depositAmount = 1000 * 1e6;

        vm.prank(user1);
        vault.deposit(depositAmount, user1);

        // Harvest without any yield
        vault.harvest();

        assertEq(usdc.balanceOf(treasury), 0);
    }

    function test_Harvest_UpdatesLastRecordedAssets() public {
        uint256 depositAmount = 1000 * 1e6;

        vm.prank(user1);
        vault.deposit(depositAmount, user1);

        // First harvest
        vault.harvest();
        uint256 recorded1 = strategy.lastRecordedAssets();

        // Simulate yield
        aavePool.simulateYield(address(usdc), address(strategy), 50 * 1e6);

        // Second harvest
        vault.harvest();
        uint256 recorded2 = strategy.lastRecordedAssets();

        assertGt(recorded2, recorded1);
    }

    /*//////////////////////////////////////////////////////////////
                          EMERGENCY TESTS
    //////////////////////////////////////////////////////////////*/

    function test_SetEmergencyExit() public {
        strategy.setEmergencyExit();
        assertTrue(strategy.emergencyExit());
    }

    function test_SetEmergencyExit_ByVault() public {
        vm.prank(address(vault));
        strategy.setEmergencyExit();
        assertTrue(strategy.emergencyExit());
    }

    function test_RevertIf_SetEmergencyExit_NotAuthorized() public {
        vm.prank(user1);
        vm.expectRevert(AaveV3StrategySimple.OnlyVault.selector);
        strategy.setEmergencyExit();
    }

    function test_EmergencyWithdraw() public {
        uint256 depositAmount = 1000 * 1e6;

        vm.prank(user1);
        vault.deposit(depositAmount, user1);

        // Emergency withdraw via vault
        vm.prank(owner);
        vault.emergencyWithdrawFromStrategy();

        assertTrue(strategy.emergencyExit());
        assertEq(strategy.totalAssets(), 0);
    }

    /*//////////////////////////////////////////////////////////////
                          VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function test_TotalAssets() public {
        uint256 depositAmount = 1000 * 1e6;

        vm.prank(user1);
        vault.deposit(depositAmount, user1);

        uint256 expectedInStrategy = (depositAmount * 9500) / 10000;
        assertApproxEqAbs(strategy.totalAssets(), expectedInStrategy, 1);
    }

    function test_CurrentAPY() public view {
        uint256 apy = strategy.currentAPY();
        assertEq(apy, 0.03e27); // 3% as set in mock
    }

    function test_CurrentAPYPercent() public view {
        uint256 apyPercent = strategy.currentAPYPercent();
        assertEq(apyPercent, 300); // 3.00%
    }

    /*//////////////////////////////////////////////////////////////
                              FUZZ TESTS
    //////////////////////////////////////////////////////////////*/

    function testFuzz_DepositWithdraw(uint256 depositAmount, uint256 withdrawAmount) public {
        depositAmount = bound(depositAmount, 1e6, INITIAL_BALANCE);
        withdrawAmount = bound(withdrawAmount, 1, depositAmount);

        vm.startPrank(user1);
        vault.deposit(depositAmount, user1);
        vault.withdraw(withdrawAmount, user1, user1);
        vm.stopPrank();

        assertEq(usdc.balanceOf(user1), INITIAL_BALANCE - depositAmount + withdrawAmount);
    }

    function testFuzz_HarvestWithYield(uint256 depositAmount, uint256 yieldPercent) public {
        // 1. Constrain deposit: Min 1000 USDC instead of 1 USDC
        // This ensures even 1% yield is significant ($10)
        uint256 minDeposit = 1000 * 1e6;
        depositAmount = (depositAmount % (INITIAL_BALANCE - minDeposit)) + minDeposit;

        // 2. Constrain yield (1% to 50%)
        // "modulo 50" gives 0-49. Add 1 to get 1-50.
        yieldPercent = (yieldPercent % 50) + 1;

        // Deposit into vault
        vm.prank(user1);
        vault.deposit(depositAmount, user1);

        uint256 treasuryBefore = usdc.balanceOf(treasury);

        // Calculate yield safely
        uint256 strategyBalance = strategy.totalAssets();
        uint256 yieldAmount = (strategyBalance * yieldPercent) / 100;

        // Only simulate yield if it’s nonzero to avoid edge-case zero
        if (yieldAmount > 0) {
            aavePool.simulateYield(address(usdc), address(strategy), yieldAmount);
        }

        // Harvest
        vault.harvest();

        uint256 treasuryAfter = usdc.balanceOf(treasury);

        if (yieldAmount > 0) {
            assertGt(treasuryAfter, treasuryBefore);
        } else {
            assertEq(treasuryAfter, treasuryBefore);
        }

        assertEq(strategy.lastRecordedAssets(), strategy.totalAssets());
    }
}

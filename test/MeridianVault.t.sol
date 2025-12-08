// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {MeridianVault} from "../src/MeridianVault.sol";
import {IStrategy} from "../src/interfaces/IStrategy.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {
    ZeroAddress,
    DepositsPausedError,
    StrategyAssetMismatch,
    NoStrategy,
    FeeTooHigh
} from "../src/MeridianVault.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/**
 * @title MockStrategy
 * @notice Simple mock strategy for vault testing
 */
contract MockStrategy is IStrategy {
    address public override vault;
    address public override asset;
    bool public override emergencyExit;

    uint256 public totalDeposited;
    uint256 public simulatedProfit;
    uint256 public simulatedLoss;

    constructor(address _vault, address _asset) {
        vault = _vault;
        asset = _asset;
    }

    function updateLastRecordedAssets() external override {
        // This is a mock. We don't need complex logic here.
        // It satisfies the IStrategy interface.
    }

    function deposit(uint256 amount) external override {
        require(msg.sender == vault, "Only vault");
        totalDeposited += amount;
        emit Deposited(amount);
    }

    function withdraw(uint256 amount) external override returns (uint256) {
        require(msg.sender == vault, "Only vault");
        uint256 toWithdraw = amount > totalDeposited ? totalDeposited : amount;
        totalDeposited -= toWithdraw;

        // Transfer back to vault
        MockERC20(asset).transfer(vault, toWithdraw);

        emit Withdrawn(toWithdraw);
        return toWithdraw;
    }

    function withdrawAll() external override returns (uint256) {
        require(msg.sender == vault, "Only vault");
        uint256 total = totalDeposited;
        totalDeposited = 0;

        MockERC20(asset).transfer(vault, total);

        emit Withdrawn(total);
        return total;
    }

    function harvest() external override returns (uint256 profit, uint256 loss) {
        require(msg.sender == vault, "Only vault");
        profit = simulatedProfit;
        loss = simulatedLoss;

        // Reset after harvest
        simulatedProfit = 0;
        simulatedLoss = 0;

        emit Harvested(profit, loss);
    }

    function totalAssets() external view override returns (uint256) {
        return totalDeposited + simulatedProfit;
    }

    function setEmergencyExit() external override {
        emergencyExit = true;
        emit EmergencyExitEnabled();
    }

    // Test helpers
    function setSimulatedProfit(uint256 _profit) external {
        simulatedProfit = _profit;
    }

    function setSimulatedLoss(uint256 _loss) external {
        simulatedLoss = _loss;
    }

    // Receive assets from vault
    function fundStrategy(uint256 amount) external {
        MockERC20(asset).mint(address(this), amount);
        totalDeposited += amount;
    }
}

    contract MeridianVaultTest is Test {
        MeridianVault public vault;
        MockERC20 public usdc;
        MockStrategy public strategy;

        address public owner = address(1);
        address public treasury = address(2);
        address public user1 = address(3);
        address public user2 = address(4);

        uint256 constant INITIAL_BALANCE = 10_000 * 1e6; // 10,000 USDC

        function setUp() public {
            // Deploy mock USDC
            usdc = new MockERC20("USD Coin", "USDC", 6);

            // Deploy vault
            vm.prank(owner);
            vault = new MeridianVault(usdc, "Meridian USDC Vault", "mrdUSDC", treasury, owner);

            // Deploy mock strategy
            strategy = new MockStrategy(address(vault), address(usdc));

            // Fund users
            usdc.mint(user1, INITIAL_BALANCE);
            usdc.mint(user2, INITIAL_BALANCE);
            usdc.mint(address(strategy), 1_000_000 * 1e6); // Fund strategy for withdrawals

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
            assertEq(vault.name(), "Meridian USDC Vault");
            assertEq(vault.symbol(), "mrdUSDC");
            assertEq(vault.asset(), address(usdc));
            assertEq(vault.owner(), owner);
            assertEq(vault.treasury(), treasury);
            assertEq(vault.performanceFee(), 1000); // 10%
            assertEq(vault.bufferPercent(), 500); // 5%
            assertEq(vault.totalAssets(), 0);
        }

        function test_RevertIf_DeployWithZeroTreasury() public {
            vm.expectRevert(abi.encodeWithSelector(ZeroAddress.selector));
            new MeridianVault(usdc, "Test", "TST", address(0), owner);
        }

        function test_RevertIf_DeployWithZeroOwner() public {
            // Change from OwnableInvalidOwner(0x...) != ZeroAddress()

            vm.expectRevert(
                abi.encodeWithSelector(
                    Ownable.OwnableInvalidOwner.selector,
                    address(0) // The owner passed was address(0)
                )
            );
            new MeridianVault(usdc, "Test", "TST", treasury, address(0));
        }

        /*//////////////////////////////////////////////////////////////
                                DEPOSIT TESTS
        //////////////////////////////////////////////////////////////*/

        function test_Deposit() public {
            uint256 depositAmount = 1000 * 1e6;

            vm.prank(user1);
            uint256 shares = vault.deposit(depositAmount, user1);

            assertEq(shares, depositAmount); // 1:1 initially
            assertEq(vault.balanceOf(user1), depositAmount);
            assertEq(vault.totalAssets(), depositAmount);
            assertEq(usdc.balanceOf(address(vault)), depositAmount);
        }

        function test_Deposit_MultipleUsers() public {
            uint256 amount1 = 1000 * 1e6;
            uint256 amount2 = 2000 * 1e6;

            vm.prank(user1);
            vault.deposit(amount1, user1);

            vm.prank(user2);
            vault.deposit(amount2, user2);

            assertEq(vault.balanceOf(user1), amount1);
            assertEq(vault.balanceOf(user2), amount2);
            assertEq(vault.totalAssets(), amount1 + amount2);
        }

        function test_Deposit_WithStrategy() public {
            // Set strategy
            vm.prank(owner);
            vault.setStrategy(address(strategy));

            uint256 depositAmount = 1000 * 1e6;

            vm.prank(user1);
            vault.deposit(depositAmount, user1);

            // 95% should go to strategy, 5% buffer in vault
            uint256 expectedBuffer = (depositAmount * 500) / 10000; // 5%
            uint256 expectedInStrategy = depositAmount - expectedBuffer;

            assertEq(usdc.balanceOf(address(vault)), expectedBuffer);
            assertEq(strategy.totalDeposited(), expectedInStrategy);
        }

        function test_RevertIf_Deposit_WhenPaused() public {
            vm.prank(owner);
            vault.pauseDeposits(true);

            vm.prank(user1);
            vm.expectRevert(abi.encodeWithSelector(DepositsPausedError.selector));
            vault.deposit(1000 * 1e6, user1);
        }

        /*//////////////////////////////////////////////////////////////
                                WITHDRAW TESTS
        //////////////////////////////////////////////////////////////*/

        function test_Withdraw() public {
            uint256 depositAmount = 1000 * 1e6;

            vm.startPrank(user1);
            vault.deposit(depositAmount, user1);

            uint256 withdrawAmount = 500 * 1e6;
            uint256 sharesBurned = vault.withdraw(withdrawAmount, user1, user1);
            vm.stopPrank();

            assertEq(sharesBurned, withdrawAmount);
            assertEq(usdc.balanceOf(user1), INITIAL_BALANCE - depositAmount + withdrawAmount);
            assertEq(vault.balanceOf(user1), depositAmount - withdrawAmount);
        }

        function test_Withdraw_Full() public {
            uint256 depositAmount = 1000 * 1e6;

            vm.startPrank(user1);
            vault.deposit(depositAmount, user1);
            vault.withdraw(depositAmount, user1, user1);
            vm.stopPrank();

            assertEq(vault.balanceOf(user1), 0);
            assertEq(usdc.balanceOf(user1), INITIAL_BALANCE);
        }

        function test_Redeem() public {
            uint256 depositAmount = 1000 * 1e6;

            vm.startPrank(user1);
            uint256 shares = vault.deposit(depositAmount, user1);

            uint256 assets = vault.redeem(shares / 2, user1, user1);
            vm.stopPrank();

            assertEq(assets, depositAmount / 2);
            assertEq(vault.balanceOf(user1), shares / 2);
        }

        function test_Withdraw_FromStrategy() public {
            vm.prank(owner);
            vault.setStrategy(address(strategy));

            uint256 depositAmount = 1000 * 1e6;

            vm.prank(user1);
            vault.deposit(depositAmount, user1);

            // Withdraw more than buffer
            uint256 withdrawAmount = 800 * 1e6;

            vm.prank(user1);
            vault.withdraw(withdrawAmount, user1, user1);

            assertEq(usdc.balanceOf(user1), INITIAL_BALANCE - depositAmount + withdrawAmount);
        }

        /*//////////////////////////////////////////////////////////////
                              STRATEGY TESTS
        //////////////////////////////////////////////////////////////*/

        function test_SetStrategy() public {
            vm.prank(owner);
            vault.setStrategy(address(strategy));

            assertEq(address(vault.strategy()), address(strategy));
        }

        function test_RevertIf_SetStrategy_NotOwner() public {
            vm.prank(user1);
            vm.expectRevert();
            vault.setStrategy(address(strategy));
        }

        function test_RevertIf_SetStrategy_ZeroAddress() public {
            vm.prank(owner);
            vm.expectRevert(abi.encodeWithSelector(ZeroAddress.selector));
            vault.setStrategy(address(0));
        }

        function test_RevertIf_SetStrategy_AssetMismatch() public {
            MockERC20 otherToken = new MockERC20("Other", "OTH", 18);
            MockStrategy wrongStrategy = new MockStrategy(address(vault), address(otherToken));

            vm.prank(owner);
            vm.expectRevert(abi.encodeWithSelector(StrategyAssetMismatch.selector));
            vault.setStrategy(address(wrongStrategy));
        }

        function test_SetStrategy_MigratesFromOldStrategy() public {
            // Set first strategy
            vm.prank(owner);
            vault.setStrategy(address(strategy));

            // Deposit
            vm.prank(user1);
            vault.deposit(1000 * 1e6, user1);

            // Create new strategy
            MockStrategy newStrategy = new MockStrategy(address(vault), address(usdc));
            usdc.mint(address(newStrategy), 1_000_000 * 1e6);

            // Migrate
            vm.prank(owner);
            vault.setStrategy(address(newStrategy));

            // Old strategy should be empty
            assertEq(strategy.totalDeposited(), 0);
        }

        /*//////////////////////////////////////////////////////////////
                                HARVEST TESTS
        //////////////////////////////////////////////////////////////*/

        function test_Harvest_WithProfit() public {
            vm.prank(owner);
            vault.setStrategy(address(strategy));

            vm.prank(user1);
            vault.deposit(1000 * 1e6, user1);

            // Simulate profit
            uint256 profit = 100 * 1e6;
            strategy.setSimulatedProfit(profit);
            usdc.mint(address(strategy), profit); // Fund the profit

            // Harvest
            vault.harvest();

            // Treasury should receive 10% of profit
            uint256 expectedFee = (profit * 1000) / 10000;
            assertEq(usdc.balanceOf(treasury), expectedFee);
        }

        function test_Harvest_NoProfit() public {
            vm.prank(owner);
            vault.setStrategy(address(strategy));

            vm.prank(user1);
            vault.deposit(1000 * 1e6, user1);

            // Harvest with no profit
            vault.harvest();

            assertEq(usdc.balanceOf(treasury), 0);
        }

        function test_RevertIf_Harvest_NoStrategy() public {
            vm.expectRevert(abi.encodeWithSelector(NoStrategy.selector));
            vault.harvest();
        }

        /*//////////////////////////////////////////////////////////////
                                ADMIN TESTS
        //////////////////////////////////////////////////////////////*/

        function test_SetPerformanceFee() public {
            vm.prank(owner);
            vault.setPerformanceFee(1500); // 15%

            assertEq(vault.performanceFee(), 1500);
        }

        function test_RevertIf_SetPerformanceFee_TooHigh() public {
            vm.prank(owner);
            vm.expectRevert(abi.encodeWithSelector(FeeTooHigh.selector));
            vault.setPerformanceFee(2001); // > 20%
        }

        function test_SetTreasury() public {
            address newTreasury = address(99);

            vm.prank(owner);
            vault.setTreasury(newTreasury);

            assertEq(vault.treasury(), newTreasury);
        }

        function test_SetBufferPercent() public {
            vm.prank(owner);
            vault.setBufferPercent(1000); // 10%

            assertEq(vault.bufferPercent(), 1000);
        }

        function test_PauseDeposits() public {
            vm.prank(owner);
            vault.pauseDeposits(true);

            assertTrue(vault.depositsPaused());
        }

        function test_EmergencyWithdraw() public {
            vm.prank(owner);
            vault.setStrategy(address(strategy));

            vm.prank(user1);
            vault.deposit(1000 * 1e6, user1);

            vm.prank(owner);
            vault.emergencyWithdrawFromStrategy();

            assertTrue(vault.depositsPaused());
            assertTrue(strategy.emergencyExit());
        }

        /*//////////////////////////////////////////////////////////////
                                  FUZZ TESTS
        //////////////////////////////////////////////////////////////*/

        function testFuzz_Deposit(uint256 amount) public {
            amount = bound(amount, 1, INITIAL_BALANCE);

            vm.prank(user1);
            uint256 shares = vault.deposit(amount, user1);

            assertEq(shares, amount);
            assertEq(vault.balanceOf(user1), amount);
        }

        function testFuzz_DepositWithdraw(uint256 depositAmount, uint256 withdrawAmount) public {
            depositAmount = bound(depositAmount, 1, INITIAL_BALANCE);
            withdrawAmount = bound(withdrawAmount, 1, depositAmount);

            vm.startPrank(user1);
            vault.deposit(depositAmount, user1);
            vault.withdraw(withdrawAmount, user1, user1);
            vm.stopPrank();

            assertEq(vault.balanceOf(user1), depositAmount - withdrawAmount);
        }

        /*//////////////////////////////////////////////////////////////
                              ERC-4626 COMPLIANCE
        //////////////////////////////////////////////////////////////*/

        function test_PreviewDeposit() public view {
            uint256 assets = 1000 * 1e6;
            uint256 expectedShares = vault.previewDeposit(assets);

            assertEq(expectedShares, assets); // 1:1 when empty
        }

        function test_PreviewMint() public view {
            uint256 shares = 1000 * 1e6;
            uint256 expectedAssets = vault.previewMint(shares);

            assertEq(expectedAssets, shares); // 1:1 when empty
        }

        function test_PreviewWithdraw() public {
            vm.prank(user1);
            vault.deposit(1000 * 1e6, user1);

            uint256 assets = 500 * 1e6;
            uint256 expectedShares = vault.previewWithdraw(assets);

            assertEq(expectedShares, assets); // 1:1
        }

        function test_PreviewRedeem() public {
            vm.prank(user1);
            vault.deposit(1000 * 1e6, user1);

            uint256 shares = 500 * 1e6;
            uint256 expectedAssets = vault.previewRedeem(shares);

            assertEq(expectedAssets, shares); // 1:1
        }

        function test_MaxDeposit() public view {
            uint256 max = vault.maxDeposit(user1);
            assertEq(max, type(uint256).max);
        }

        function test_MaxWithdraw() public {
            vm.prank(user1);
            vault.deposit(1000 * 1e6, user1);

            uint256 max = vault.maxWithdraw(user1);
            assertEq(max, 1000 * 1e6);
        }
    }

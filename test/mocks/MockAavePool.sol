// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "./MockERC20.sol";

/**
 * @title MockAavePool
 * @notice Mock Aave V3 Pool for testing strategies
 * @dev Simulates supply/withdraw with configurable interest rate
 */
contract MockAavePool {
    // asset => aToken
    mapping(address => address) public aTokens;

    // Simulated APY in ray (1e27 = 100%)
    uint128 public liquidityRate = 0.03e27; // 3% APY default

    constructor() {}

    /**
     * @notice Register an asset and its aToken
     */
    function setAToken(address asset, address aToken) external {
        aTokens[asset] = aToken;
    }

    /**
     * @notice Set the liquidity rate for testing
     */
    function setLiquidityRate(uint128 rate) external {
        liquidityRate = rate;
    }

    /**
     * @notice Supply assets to the pool
     */
    function supply(
        address asset,
        uint256 amount,
        address onBehalfOf,
        uint16 /* referralCode */
    )
        external
    {
        // Transfer asset from sender
        IERC20(asset).transferFrom(msg.sender, address(this), amount);

        // Mint aTokens to user
        address aToken = aTokens[asset];
        require(aToken != address(0), "Asset not supported");
        MockERC20(aToken).mint(onBehalfOf, amount);
    }

    /**
     * @notice Withdraw assets from the pool
     */
    function withdraw(address asset, uint256 amount, address to) external returns (uint256) {
        address aToken = aTokens[asset];
        require(aToken != address(0), "Asset not supported");

        uint256 userBalance = IERC20(aToken).balanceOf(msg.sender);
        uint256 toWithdraw = amount == type(uint256).max ? userBalance : amount;

        if (toWithdraw > userBalance) {
            toWithdraw = userBalance;
        }

        // Burn aTokens
        MockERC20(aToken).burn(msg.sender, toWithdraw);

        // Transfer underlying to user
        IERC20(asset).transfer(to, toWithdraw);

        return toWithdraw;
    }

    /**
     * @notice Get reserve data (simplified for testing)
     */
    function getReserveData(address asset)
        external
        view
        returns (
            uint256 configuration,
            uint128 liquidityIndex,
            uint128 currentLiquidityRate,
            uint128 variableBorrowIndex,
            uint128 currentVariableBorrowRate,
            uint128 currentStableBorrowRate,
            uint40 lastUpdateTimestamp,
            uint16 id,
            address aTokenAddress,
            address stableDebtTokenAddress,
            address variableDebtTokenAddress,
            address interestRateStrategyAddress,
            uint128 accruedToTreasury,
            uint128 unbacked,
            uint128 isolationModeTotalDebt
        )
    {
        return (
            0, // configuration
            1e27, // liquidityIndex (1.0 in ray)
            liquidityRate, // currentLiquidityRate
            1e27, // variableBorrowIndex
            0.05e27, // currentVariableBorrowRate (5%)
            0.05e27, // currentStableBorrowRate
            uint40(block.timestamp), // lastUpdateTimestamp
            0, // id
            aTokens[asset], // aTokenAddress
            address(0), // stableDebtTokenAddress
            address(0), // variableDebtTokenAddress
            address(0), // interestRateStrategyAddress
            0, // accruedToTreasury
            0, // unbacked
            0 // isolationModeTotalDebt
        );
    }

    /**
     * @notice Simulate interest accrual by minting extra aTokens
     * @dev Call this in tests to simulate yield
     */
    function simulateYield(address asset, address strategyAddr, uint256 yieldAmount) external {
        address aToken = aTokens[asset];
        MockERC20(aToken).mint(strategyAddr, yieldAmount);
    }
}

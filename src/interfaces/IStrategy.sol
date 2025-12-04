// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/**
 * @title IStrategy
 * @author Meridian Finance
 * @notice Interface for yield-generating strategies
 * @dev All strategies must implement this interface to be compatible with Meridian vaults
 */
interface IStrategy {
    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event Deposited(uint256 amount);
    event Withdrawn(uint256 amount);
    event Harvested(uint256 profit, uint256 loss);
    event EmergencyExitEnabled();

    /*//////////////////////////////////////////////////////////////
                              VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice The vault this strategy reports to
     */
    function vault() external view returns (address);

    /**
     * @notice The underlying asset this strategy accepts
     */
    function asset() external view returns (address);

    /**
     * @notice Total assets managed by this strategy (deposited + earned)
     * @return Total value in terms of the underlying asset
     */
    function totalAssets() external view returns (uint256);

    /**
     * @notice Whether the strategy is in emergency exit mode
     */
    function emergencyExit() external view returns (bool);

    /*//////////////////////////////////////////////////////////////
                            VAULT OPERATIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Deposit assets into the strategy
     * @dev Only callable by the vault
     * @param amount Amount of assets to deposit
     */
    function deposit(uint256 amount) external;

    /**
     * @notice Withdraw assets from the strategy
     * @dev Only callable by the vault. May withdraw less than requested if illiquid.
     * @param amount Amount of assets to withdraw
     * @return actualWithdrawn The actual amount withdrawn
     */
    function withdraw(uint256 amount) external returns (uint256 actualWithdrawn);

    /**
     * @notice Withdraw all assets from the strategy
     * @dev Only callable by the vault
     * @return totalWithdrawn Total amount withdrawn
     */
    function withdrawAll() external returns (uint256 totalWithdrawn);

    /**
     * @notice Harvest profits and report to vault
     * @dev Compounds earnings back into the strategy
     * @return profit Amount of profit realized
     * @return loss Amount of loss realized
     */
    function harvest() external returns (uint256 profit, uint256 loss);

    function updateLastRecordedAssets() external;

    /*//////////////////////////////////////////////////////////////
                               EMERGENCY
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Enable emergency exit mode
     * @dev Prevents new deposits and allows immediate withdrawal
     */
    function setEmergencyExit() external;
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IStrategy} from "../interfaces/IStrategy.sol";
import {ZeroAddress} from "../MeridianVault.sol";

/**
 * @title IPool (Aave V3)
 * @notice Minimal interface - Aave contracts are already deployed
 * @dev Full interface at: @aave/v3-core/contracts/interfaces/IPool.sol
 */
interface IPool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
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
        );
}

/**
 * @title AaveV3StrategySimple
 * @author Meridian Finance
 * @notice Dead-simple Aave V3 strategy - just supply and earn
 *
 * How it works:
 * 1. Vault sends assets to this contract
 * 2. We call pool.supply() to deposit into Aave
 * 3. We receive aTokens (balance grows automatically with interest)
 * 4. On withdraw, we call pool.withdraw()
 *
 * That's it. Aave handles everything else.
 */
contract AaveV3StrategySimple is IStrategy {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                            IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    address public immutable override vault;
    address public immutable override asset;
    IPool public immutable pool;
    IERC20 public immutable aToken;

    address public owner;
    bool public override emergencyExit;
    uint256 public lastRecordedAssets;

    /*//////////////////////////////////////////////////////////////
                             ERRORS
    //////////////////////////////////////////////////////////////*/

    error OnlyVault();
    error OnlyOwner();
    error EmergencyMode();

    /*//////////////////////////////////////////////////////////////
                            MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyVault() {
        if (msg.sender != vault) revert OnlyVault();
        _;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert OnlyOwner();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                           CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @param _vault Your Meridian vault address
     * @param _asset The token to deposit (USDC, WETH, etc)
     * @param _pool Aave V3 Pool address (already deployed by Aave)
     *
     * Aave Pool addresses:
     * - Sepolia: 0x6Ae43d3271ff6888e7Fc43Fd7321a503ff738951
     * - Mainnet: 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2
     */
    constructor(address _vault, address _asset, address _pool) {
        // Check key parameters to prevent contract initialization failure
        if (_vault == address(0)) revert ZeroAddress(); // 👈 FIX 1
        if (_asset == address(0)) revert ZeroAddress(); // 👈 FIX 2

        // Check owner if inherited from Ownable, which you already did in MeridianVault
        // if (_owner == address(0)) revert ZeroAddress(); // (If needed)
        vault = _vault;
        asset = _asset;
        pool = IPool(_pool);
        owner = msg.sender;

        // Get the aToken address from Aave's pool
        (,,,,,,,, address aTokenAddress,,,,,,) = pool.getReserveData(_asset);
        aToken = IERC20(aTokenAddress);

        // Approve pool to take our assets (one-time infinite approval)
        SafeERC20.forceApprove(IERC20(_asset), _pool, type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                         CORE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Deposit assets into Aave
    function deposit(uint256 amount) external override onlyVault {
        if (emergencyExit) revert EmergencyMode();

        // That's literally it - one line to deposit into Aave
        pool.supply(asset, amount, address(this), 0);

        // This is crucial to prevent the first harvest from claiming
        // the entire initial deposit as profit.
        lastRecordedAssets = totalAssets(); // Must be called AFTER supply

        emit Deposited(amount);
    }

    /// @notice Withdraw assets from Aave
    /// @dev Ensures the actual amount received from Aave is captured and transferred to the Vault.
    function withdraw(uint256 amount) external override onlyVault returns (uint256 actualWithdrawn) {
        // 1. CHECKS (Determine amount to redeem)
        uint256 available = aToken.balanceOf(address(this));
        uint256 toWithdraw = amount > available ? available : amount;

        // Safe Guard Clause Check
        // If toWithdraw is 0, we skip the remaining logic.
        if (toWithdraw > 0) {
            // --- Interaction 1 (Aave Withdrawal) ---
            // The Aave Pool's withdraw function returns the actual amount of underlying asset transferred.
            uint256 aaveReturnedAmount = pool.withdraw(asset, toWithdraw, address(this));

            // 2. EFFECTS (Internal State Update)
            actualWithdrawn = aaveReturnedAmount;

            // 3. INTERACTION 2 (Transfer to Vault)
            // This check is now redundant because it relies on the safeTransfer function handling the zero-transfer case.
            // However, keeping it makes the intent explicit and follows the Checks-Effects-Interactions pattern for external calls.
            if (actualWithdrawn > 0) {
                // Transfer the exact amount received from Aave to the vault
                IERC20(asset).safeTransfer(vault, actualWithdrawn);
            }

            emit Withdrawn(actualWithdrawn);
            return actualWithdrawn;
        }
        // If toWithdraw was 0, it falls through here.
        emit Withdrawn(0);
        return 0;
    }

    /// @notice Withdraw everything from Aave
    function withdrawAll() external override onlyVault returns (uint256 total) {
        uint256 balance = aToken.balanceOf(address(this));

        uint256 actualAmountReceived = 0; // Initialize a variable to hold the amount Aave returns

        if (balance > 0) {
            // type(uint256).max tells Aave to withdraw full balance.
            // Capture the return value of the external call.
            actualAmountReceived = pool.withdraw(asset, type(uint256).max, address(this));
        }

        // --- Interaction (Transfer to Vault) ---

        // We now have two possible amounts to transfer:
        // 1. 'actualAmountReceived' (the amount Aave said it sent).
        // 2. 'total' (the contract's current asset balance).

        // The safest approach is to send the contract's entire current balance of the asset,
        // which might include dust or small amounts already present.
        // We will keep your original balance check logic for the transfer, but use the
        // 'actualAmountReceived' for the final return/event if it's cleaner.

        // Get the total current balance of the underlying asset
        total = IERC20(asset).balanceOf(address(this));

        if (total > 0) {
            // Send the entire balance to the vault
            IERC20(asset).safeTransfer(vault, total);
        }

        // EFFECTS (State Updates)
        lastRecordedAssets = 0;

        // Emit the total amount sent to the vault
        emit Withdrawn(total);
        return total;
    }

    /// @notice Calculate profit since last harvest
    function harvest() external override onlyVault returns (uint256 profit, uint256 loss) {
        uint256 current = totalAssets();

        if (lastRecordedAssets == 0) {
            // first harvest, just initialize
            lastRecordedAssets = current;
            emit Harvested(0, 0);
            return (0, 0);
        }

        if (current > lastRecordedAssets) {
            profit = current - lastRecordedAssets;
        } else {
            loss = lastRecordedAssets - current;
        }

        emit Harvested(profit, loss);
    }

    /// @notice Total value: aToken balance + any idle assets
    function totalAssets() public view override returns (uint256) {
        return aToken.balanceOf(address(this)) + IERC20(asset).balanceOf(address(this));
    }

    /*//////////////////////////////////////////////////////////////
                            EMERGENCY
    //////////////////////////////////////////////////////////////*/

    function setEmergencyExit() external override {
        if (msg.sender != vault && msg.sender != owner) revert OnlyVault();
        emergencyExit = true;
        emit EmergencyExitEnabled();
    }

    /*//////////////////////////////////////////////////////////////
                          VIEW HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Current APY from Aave (in ray = 1e27)
    function currentAPY() external view returns (uint256) {
        (,, uint128 liquidityRate,,,,,,,,,,,,) = pool.getReserveData(asset);
        return liquidityRate;
    }

    /// @notice Convert ray APY to human readable percentage
    /// @dev Returns APY with 2 decimals (e.g., 325 = 3.25%)
    function currentAPYPercent() external view returns (uint256) {
        (,, uint128 liquidityRate,,,,,,,,,,,,) = pool.getReserveData(asset);
        // Ray = 1e27, we want percentage with 2 decimals
        return uint256(liquidityRate) * 100 / 1e25;
    }

    /// @notice Set the asset tracking after fee withdrawal
    function updateLastRecordedAssets() external onlyVault {
        lastRecordedAssets = totalAssets();
    }
}

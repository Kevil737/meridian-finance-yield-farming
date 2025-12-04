// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IStrategy} from "./interfaces/IStrategy.sol";

/**
 * @title MeridianVault
 * @author Meridian Finance
 * @notice ERC-4626 vault that delegates funds to yield-generating strategies
 * @dev Users deposit assets, receive shares. Vault allocates to strategy for yield.
 *
 * Key features:
 * - ERC-4626 compliant (composable with other DeFi protocols)
 * - Single active strategy (can be migrated)
 * - Auto-compounding via harvest()
 * - Performance fee on profits
 * - Emergency withdrawal support
 */
contract MeridianVault is ERC4626, ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;
    using Math for uint256;

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Maximum performance fee: 20%
    uint256 public constant MAX_PERFORMANCE_FEE = 2000;

    /// @notice Fee denominator (basis points)
    uint256 public constant FEE_DENOMINATOR = 10000;

    /// @notice Maximum funds that can be sent to strategy: 95%
    uint256 public constant MAX_STRATEGY_ALLOCATION = 9500;

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice Active strategy for this vault
    IStrategy public strategy;

    /// @notice Performance fee in basis points (e.g., 1000 = 10%)
    uint256 public performanceFee;

    /// @notice Address receiving performance fees
    address public treasury;

    /// @notice Total assets reported at last harvest (for profit calculation)
    uint256 public lastTotalAssets;

    /// @notice Percentage of funds to keep in vault for withdrawals (basis points)
    uint256 public bufferPercent;

    /// @notice Whether deposits are paused
    bool public depositsPaused;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event StrategyUpdated(address indexed oldStrategy, address indexed newStrategy);
    event Harvested(uint256 profit, uint256 loss, uint256 feesPaid);
    event PerformanceFeeUpdated(uint256 oldFee, uint256 newFee);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event BufferPercentUpdated(uint256 oldBuffer, uint256 newBuffer);
    event DepositsPaused(bool paused);
    event FundsAllocatedToStrategy(uint256 amount);
    event FundsWithdrawnFromStrategy(uint256 amount);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error ZeroAddress();
    error FeeTooHigh();
    error NoStrategy();
    error StrategyAssetMismatch();
    error DepositsPausedError();
    error AllocationTooHigh();
    error InsufficientBuffer();

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Deploy a new Meridian Vault
     * @param _asset Underlying asset (e.g., USDC, WETH)
     * @param _name Vault share token name
     * @param _symbol Vault share token symbol
     * @param _treasury Address to receive performance fees
     * @param _owner Admin address
     */
    constructor(IERC20 _asset, string memory _name, string memory _symbol, address _treasury, address _owner)
        ERC4626(_asset)
        ERC20(_name, _symbol)
        Ownable(_owner)
    {
        if (_treasury == address(0)) revert ZeroAddress();
        if (_owner == address(0)) revert ZeroAddress();

        treasury = _treasury;
        performanceFee = 1000; // 10% default
        bufferPercent = 500; // 5% kept liquid for withdrawals
    }

    /*//////////////////////////////////////////////////////////////
                           ERC-4626 OVERRIDES
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Total assets managed by vault (in vault + in strategy)
     */
    function totalAssets() public view override returns (uint256) {
        uint256 vaultBalance = IERC20(asset()).balanceOf(address(this));
        uint256 strategyBalance = address(strategy) != address(0) ? strategy.totalAssets() : 0;
        return vaultBalance + strategyBalance;
    }

    /**
     * @notice Deposit assets and receive shares
     * @dev Overridden to add pause check and auto-allocation
     */
    function deposit(uint256 assets, address receiver) public override nonReentrant returns (uint256 shares) {
        if (depositsPaused) revert DepositsPausedError();
        shares = super.deposit(assets, receiver);
        _allocateToStrategy();
    }

    /**
     * @notice Mint exact shares by depositing assets
     */
    function mint(uint256 shares, address receiver) public override nonReentrant returns (uint256 assets) {
        if (depositsPaused) revert DepositsPausedError();
        assets = super.mint(shares, receiver);
        _allocateToStrategy();
    }

    /**
     * @notice Withdraw assets by burning shares
     * @dev May need to withdraw from strategy if vault buffer insufficient
     */
    function withdraw(uint256 assets, address receiver, address owner)
        public
        override
        nonReentrant
        returns (uint256 shares)
    {
        _ensureLiquidity(assets);
        shares = super.withdraw(assets, receiver, owner);
    }

    /**
     * @notice Redeem shares for assets
     */
    function redeem(uint256 shares, address receiver, address owner)
        public
        override
        nonReentrant
        returns (uint256 assets)
    {
        assets = previewRedeem(shares);
        _ensureLiquidity(assets);
        assets = super.redeem(shares, receiver, owner);
    }

    /*//////////////////////////////////////////////////////////////
                          STRATEGY MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Set or update the active strategy
     * @dev Withdraws all funds from old strategy before switching
     * @param _strategy New strategy address
     */
    function setStrategy(address _strategy) external onlyOwner {
        if (_strategy == address(0)) revert ZeroAddress();

        IStrategy newStrategy = IStrategy(_strategy);
        if (newStrategy.asset() != asset()) revert StrategyAssetMismatch();
        if (newStrategy.vault() != address(this)) revert StrategyAssetMismatch();

        // Withdraw from old strategy
        if (address(strategy) != address(0)) {
            strategy.withdrawAll();
        }

        address oldStrategy = address(strategy);
        strategy = newStrategy;
        lastTotalAssets = totalAssets();

        emit StrategyUpdated(oldStrategy, _strategy);

        // Allocate to new strategy
        _allocateToStrategy();
    }

    /**
     * @notice Harvest profits from strategy and compound
     * @dev Anyone can call this (it benefits all depositors)
     */
    function harvest() external nonReentrant {
        if (address(strategy) == address(0)) revert NoStrategy();

        // Tell strategy to realize profits
        (uint256 profit, uint256 loss) = strategy.harvest(); // Strategy records assets at this point (pre-fee)

        uint256 feesPaid = 0;
        if (profit > 0 && performanceFee > 0) {
            feesPaid = (profit * performanceFee) / FEE_DENOMINATOR;
            // 1. Withdraw fees from strategy
            strategy.withdraw(feesPaid); // Strategy assets drop here!
            // 2. Transfer fees to treasury
            IERC20(asset()).safeTransfer(treasury, feesPaid);
        }

        // Now that fees are deducted, tell the Strategy its final asset value.
        strategy.updateLastRecordedAssets();
        // ---------------------------------

        lastTotalAssets = totalAssets();

        emit Harvested(profit, loss, feesPaid);
    }

    /**
     * @notice Manually allocate idle funds to strategy
     */
    function allocateToStrategy() external onlyOwner {
        _allocateToStrategy();
    }

    /**
     * @notice Withdraw specific amount from strategy to vault
     */
    function withdrawFromStrategy(uint256 amount) external onlyOwner {
        if (address(strategy) == address(0)) revert NoStrategy();
        uint256 withdrawn = strategy.withdraw(amount);
        emit FundsWithdrawnFromStrategy(withdrawn);
    }

    /*//////////////////////////////////////////////////////////////
                              ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function setPerformanceFee(uint256 _fee) external onlyOwner {
        if (_fee > MAX_PERFORMANCE_FEE) revert FeeTooHigh();
        emit PerformanceFeeUpdated(performanceFee, _fee);
        performanceFee = _fee;
    }

    function setTreasury(address _treasury) external onlyOwner {
        if (_treasury == address(0)) revert ZeroAddress();
        emit TreasuryUpdated(treasury, _treasury);
        treasury = _treasury;
    }

    function setBufferPercent(uint256 _buffer) external onlyOwner {
        if (_buffer > FEE_DENOMINATOR) revert AllocationTooHigh();
        emit BufferPercentUpdated(bufferPercent, _buffer);
        bufferPercent = _buffer;
    }

    function pauseDeposits(bool _pause) external onlyOwner {
        depositsPaused = _pause;
        emit DepositsPaused(_pause);
    }

    /**
     * @notice Emergency: withdraw all from strategy
     */
    function emergencyWithdrawFromStrategy() external onlyOwner {
        if (address(strategy) != address(0)) {
            strategy.setEmergencyExit();
            strategy.withdrawAll();
        }
        depositsPaused = true;
        emit DepositsPaused(true);
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Allocate excess vault balance to strategy
     * @dev Keeps bufferPercent in vault for withdrawals
     */
    function _allocateToStrategy() internal {
        if (address(strategy) == address(0)) return;

        uint256 vaultBalance = IERC20(asset()).balanceOf(address(this));
        uint256 total = totalAssets();

        // Target buffer amount
        uint256 targetBuffer = (total * bufferPercent) / FEE_DENOMINATOR;

        if (vaultBalance > targetBuffer) {
            uint256 toAllocate = vaultBalance - targetBuffer;
            IERC20(asset()).safeTransfer(address(strategy), toAllocate);
            strategy.deposit(toAllocate);
            emit FundsAllocatedToStrategy(toAllocate);
        }
    }

    /**
     * @notice Ensure vault has enough liquidity for withdrawal
     * @param amount Amount needed
     */
    function _ensureLiquidity(uint256 amount) internal {
        uint256 vaultBalance = IERC20(asset()).balanceOf(address(this));

        if (vaultBalance < amount && address(strategy) != address(0)) {
            uint256 needed = amount - vaultBalance;
            uint256 withdrawn = strategy.withdraw(needed);
            emit FundsWithdrawnFromStrategy(withdrawn);
        }
    }
}

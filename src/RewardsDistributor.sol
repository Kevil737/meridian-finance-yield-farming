// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {MeridianToken} from "./MeridianToken.sol";
import {VaultFactory} from "./VaultFactory.sol";

/**
 * @title RewardsDistributor
 * @author Meridian Finance
 * @notice Distributes MRD governance tokens to vault depositors
 * @dev Implements a staking-like rewards mechanism per vault
 *
 * Mechanism:
 * - Each vault has a configurable reward rate (MRD per second)
 * - Users earn rewards proportional to their share of the vault
 * - Rewards accrue continuously and can be claimed anytime
 * - Uses "reward per token" accumulator pattern (like Synthetix)
 *
 * Example:
 * - Vault has 1000 shares total, rate = 1 MRD/sec
 * - User has 100 shares (10%)
 * - After 100 seconds: User earned 10 MRD (100 sec * 1 MRD/sec * 10%)
 */
contract RewardsDistributor is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                STRUCTS
    //////////////////////////////////////////////////////////////*/

    struct VaultRewardInfo {
        uint256 rewardRate; // MRD per second
        uint256 lastUpdateTime; // Last time rewards were updated
        uint256 rewardPerTokenStored; // Accumulated reward per token
        uint256 totalStaked; // Total vault shares staked (cached)
    }

    struct UserRewardInfo {
        uint256 rewardPerTokenPaid; // User's snapshot of rewardPerToken
        uint256 rewards; // Accumulated unclaimed rewards
    }

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice MRD token
    MeridianToken public immutable rewardToken;

    /// @notice Vault factory (to verify vaults)
    VaultFactory public immutable factory;

    /// @notice Reward info per vault
    mapping(address => VaultRewardInfo) public vaultRewards;

    /// @notice User reward info: vault => user => info
    mapping(address => mapping(address => UserRewardInfo)) public userRewards;

    /// @notice Total MRD distributed so far
    uint256 public totalDistributed;

    /// @notice Reward rate cap (prevent excessive minting)
    uint256 public constant MAX_REWARD_RATE = 100 * 1e18; // 100 MRD per second max

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event RewardRateUpdated(address indexed vault, uint256 oldRate, uint256 newRate);
    event RewardsClaimed(address indexed user, address indexed vault, uint256 amount);
    event Staked(address indexed user, address indexed vault, uint256 amount);
    event Withdrawn(address indexed user, address indexed vault, uint256 amount);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error NotAVault();
    error RateTooHigh();
    error NoRewards();

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Deploy rewards distributor
     * @param _rewardToken MRD token address
     * @param _factory VaultFactory address
     * @param _owner Admin address
     */
    constructor(address _rewardToken, address _factory, address _owner) Ownable(_owner) {
        rewardToken = MeridianToken(_rewardToken);
        factory = VaultFactory(_factory);
    }

    /*//////////////////////////////////////////////////////////////
                          REWARD CALCULATION
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Calculate current reward per token for a vault
     */
    function rewardPerToken(address vault) public view returns (uint256) {
        VaultRewardInfo storage info = vaultRewards[vault];

        if (info.totalStaked == 0) {
            return info.rewardPerTokenStored;
        }

        uint256 timeElapsed = block.timestamp - info.lastUpdateTime;
        uint256 rewardAccrued = timeElapsed * info.rewardRate * 1e18 / info.totalStaked;

        return info.rewardPerTokenStored + rewardAccrued;
    }

    /**
     * @notice Calculate earned rewards for a user in a vault
     */
    function earned(address user, address vault) public view returns (uint256) {
        UserRewardInfo storage userInfo = userRewards[vault][user];
        uint256 balance = IERC20(vault).balanceOf(user);

        uint256 rewardDelta = rewardPerToken(vault) - userInfo.rewardPerTokenPaid;
        uint256 newRewards = balance * rewardDelta / 1e18;

        return userInfo.rewards + newRewards;
    }

    /*//////////////////////////////////////////////////////////////
                           USER OPERATIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Notify the distributor of a deposit (updates rewards)
     * @dev Called by users after depositing to vault
     * @param vault Vault address
     */
    function notifyDeposit(address vault) external nonReentrant {
        if (!factory.isVault(vault)) revert NotAVault();

        _updateReward(msg.sender, vault);

        // Update cached total
        vaultRewards[vault].totalStaked = IERC20(vault).totalSupply();

        emit Staked(msg.sender, vault, IERC20(vault).balanceOf(msg.sender));
    }

    /**
     * @notice Notify the distributor of a withdrawal (updates rewards)
     * @dev Called by users before/after withdrawing from vault
     * @param vault Vault address
     */
    function notifyWithdraw(address vault) external nonReentrant {
        if (!factory.isVault(vault)) revert NotAVault();

        _updateReward(msg.sender, vault);

        // Update cached total
        vaultRewards[vault].totalStaked = IERC20(vault).totalSupply();

        emit Withdrawn(msg.sender, vault, IERC20(vault).balanceOf(msg.sender));
    }

    /**
     * @notice Claim accrued MRD rewards from a vault
     * @param vault Vault to claim from
     */
    function claim(address vault) external nonReentrant {
        if (!factory.isVault(vault)) revert NotAVault();

        _updateReward(msg.sender, vault);

        uint256 reward = userRewards[vault][msg.sender].rewards;
        if (reward == 0) revert NoRewards();

        userRewards[vault][msg.sender].rewards = 0;
        totalDistributed += reward;

        // Mint rewards to user
        rewardToken.mint(msg.sender, reward);

        emit RewardsClaimed(msg.sender, vault, reward);
    }

    /**
     * @notice Claim rewards from multiple vaults
     * @param vaultList Array of vault addresses
     */
    function claimMultiple(address[] calldata vaultList) external nonReentrant {
        uint256 totalReward = 0;

        for (uint256 i = 0; i < vaultList.length; i++) {
            address vault = vaultList[i];
            if (!factory.isVault(vault)) continue;

            _updateReward(msg.sender, vault);

            uint256 reward = userRewards[vault][msg.sender].rewards;
            if (reward > 0) {
                userRewards[vault][msg.sender].rewards = 0;
                totalReward += reward;
                emit RewardsClaimed(msg.sender, vault, reward);
            }
        }

        if (totalReward > 0) {
            totalDistributed += totalReward;
            rewardToken.mint(msg.sender, totalReward);
        }
    }

    /*//////////////////////////////////////////////////////////////
                                 ADMIN
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Set reward rate for a vault
     * @param vault Vault address
     * @param rate MRD per second
     */
    function setRewardRate(address vault, uint256 rate) external onlyOwner {
        if (!factory.isVault(vault)) revert NotAVault();
        if (rate > MAX_REWARD_RATE) revert RateTooHigh();

        // Update rewards before changing rate
        _updateVaultReward(vault);

        uint256 oldRate = vaultRewards[vault].rewardRate;
        vaultRewards[vault].rewardRate = rate;

        emit RewardRateUpdated(vault, oldRate, rate);
    }

    /**
     * @notice Initialize a vault for rewards
     * @param vault Vault address
     * @param rate Initial reward rate
     */
    function initializeVault(address vault, uint256 rate) external onlyOwner {
        if (!factory.isVault(vault)) revert NotAVault();
        if (rate > MAX_REWARD_RATE) revert RateTooHigh();

        vaultRewards[vault] = VaultRewardInfo({
            rewardRate: rate,
            lastUpdateTime: block.timestamp,
            rewardPerTokenStored: 0,
            totalStaked: IERC20(vault).totalSupply()
        });

        emit RewardRateUpdated(vault, 0, rate);
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _updateReward(address user, address vault) internal {
        _updateVaultReward(vault);

        UserRewardInfo storage userInfo = userRewards[vault][user];
        userInfo.rewards = earned(user, vault);
        userInfo.rewardPerTokenPaid = vaultRewards[vault].rewardPerTokenStored;
    }

    function _updateVaultReward(address vault) internal {
        VaultRewardInfo storage info = vaultRewards[vault];
        info.rewardPerTokenStored = rewardPerToken(vault);
        info.lastUpdateTime = block.timestamp;
    }

    /*//////////////////////////////////////////////////////////////
                              VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Get pending rewards across multiple vaults
     */
    function pendingRewards(address user, address[] calldata vaultList) external view returns (uint256 total) {
        for (uint256 i = 0; i < vaultList.length; i++) {
            total += earned(user, vaultList[i]);
        }
    }
}

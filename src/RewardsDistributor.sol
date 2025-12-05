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

    // New storage to track total rewards, replacing per-vault tracking for claiming
    mapping(address => uint256) public userTotalPendingRewards;

    /// @notice Tracks the total claimable reward amount for a user across all vaults.
    mapping(address => uint256) public userTotalClaimableReward;

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
    event TotalRewardsClaimed(address indexed user, uint256 reward);

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
        // Allow the transaction to proceed if the reward is zero/dust,
        // or only proceed if the reward is meaningful.
        if (reward > 0) {
            // Only proceed if a meaningful reward exists

            // Effects (State Updates)
            userRewards[vault][msg.sender].rewards = 0;
            totalDistributed += reward;

            // Interaction (External Call)
            rewardToken.mint(msg.sender, reward);

            emit RewardsClaimed(msg.sender, vault, reward);
        }
        // If reward is <= 0, the function just exits without reverting or changing state/calling external.
        // If you MUST revert on zero reward:
        else {
            revert NoRewards();
        }
    }

    /**
     * @notice Claims all accumulated rewards for the user across all vaults.
     * @dev This replaces claimMultiple and relies on rewards being updated
     * during deposit/withdraw or single claim calls.
     */
    function claimAll() external nonReentrant {
        uint256 rewardToClaim = userTotalClaimableReward[msg.sender];

        if (rewardToClaim > 0) {
            // Effects (State updates - BEFORE external call)
            userTotalClaimableReward[msg.sender] = 0;
            totalDistributed += rewardToClaim;

            // Interaction (External call)
            rewardToken.mint(msg.sender, rewardToClaim);

            emit TotalRewardsClaimed(msg.sender, rewardToClaim); // You'll need to define this event
        } else {
            revert NoRewards();
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
        // 1. Calculate the final earned reward based on current state
        uint256 finalEarnedReward = earned(user, vault);

        // 2. Check if the user had previous, un-claimed rewards in this vault
        // This is the reward amount currently sitting in userInfo.rewards
        // that needs to be added to the total claimable pool.
        uint256 rewardToAccumulate = finalEarnedReward - userInfo.rewards;

        // 3. Accumulate the reward into the user's total claimable pool
        // This removes the need for `claimMultiple` to loop and accumulate.
        if (rewardToAccumulate > 0) {
            userTotalClaimableReward[user] += rewardToAccumulate;
        }

        // 4. Reset the user's per-vault state to the calculated final earned amount
        // The finalEarnedReward is stored here, meaning the reward calculation
        // for the next second will start from this point.
        userInfo.rewards = finalEarnedReward;
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

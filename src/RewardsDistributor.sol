// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {mulDiv} from "prb-math/Common.sol";
import {MeridianToken} from "./MeridianToken.sol";
import {VaultFactory} from "./VaultFactory.sol";

interface ITokenDecimals {
    function decimals() external view returns (uint8);
}

/**
 * @title RewardsDistributor
 * @notice Distributes MRD governance tokens to vault depositors
 * @dev Vaults call notifyDepositFor / notifyWithdrawFor to update user rewards.
 */
contract RewardsDistributor is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                STRUCTS
    //////////////////////////////////////////////////////////////*/

    struct VaultRewardInfo {
        uint256 rewardRate; // MRD per second (scaled to 1e18)
        uint256 lastUpdateTime; // Last time rewards were updated
        uint256 rewardPerTokenStored; // Accumulated reward per token (1e18 precision)
        uint256 totalStaked; // Cached total vault shares (totalSupply) - SCALED TO 1e18
        uint8 vaultDecimals; // The decimals of the vault share token (e.g., 6 for USDC vault shares)
    }

    struct UserRewardInfo {
        uint256 rewardPerTokenPaid; // User's snapshot of rewardPerToken
        uint256 rewards; // Accumulated reward (finalEarnedReward)
    }

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    MeridianToken public immutable rewardToken;
    VaultFactory public immutable factory;

    mapping(address => VaultRewardInfo) public vaultRewards;
    mapping(address => mapping(address => UserRewardInfo)) public userRewards;

    uint256 public totalDistributed;

    mapping(address => address[]) private userVaults;
    mapping(address => mapping(address => bool)) private userHasVault;

    mapping(address => uint256) public userTotalClaimableReward;

    uint256 public constant MAX_REWARD_RATE = 100 * 1e18;

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

    constructor(address _rewardToken, address _factory, address _owner) Ownable(_owner) {
        require(_rewardToken != address(0), "zero reward token");
        require(_factory != address(0), "zero factory");
        rewardToken = MeridianToken(_rewardToken);
        factory = VaultFactory(_factory);
    }

    /*//////////////////////////////////////////////////////////////
                          REWARD CALCULATION
    //////////////////////////////////////////////////////////////*/

    function rewardPerToken(address vault) public view returns (uint256) {
        VaultRewardInfo storage info = vaultRewards[vault];

        if (info.totalStaked == 0) {
            return info.rewardPerTokenStored;
        }

        uint256 timeElapsed = block.timestamp - info.lastUpdateTime;

        uint256 rewardAccrued = mulDiv(
            info.rewardRate * timeElapsed,
            1e18,
            info.totalStaked
        );

        return info.rewardPerTokenStored + rewardAccrued;
    }

    function earned(address user, address vault) public view returns (uint256) {
        VaultRewardInfo storage info = vaultRewards[vault];
        UserRewardInfo storage u = userRewards[vault][user];

        uint256 rpt = rewardPerToken(vault);

        uint256 rawBalance = IERC20(vault).balanceOf(user);
        uint256 scaledBalance = _scaleTo18DecimalsUint(rawBalance, info.vaultDecimals);

        uint256 rptDelta = rpt - u.rewardPerTokenPaid;

        return u.rewards + (scaledBalance * rptDelta) / 1e18;
    }

    /*//////////////////////////////////////////////////////////////
                           VAULT-CALLED FUNCTIONS
    //////////////////////////////////////////////////////////////*/

function notifyDepositFor(address user, address vault) external nonReentrant {
    if (!factory.isVault(msg.sender)) revert NotAVault();

    uint8 decimals = vaultRewards[vault].vaultDecimals;
    require(decimals > 0, "Vault not initialized");

    uint256 rawTotalSupply = IERC20(vault).totalSupply();
    vaultRewards[vault].totalStaked = _scaleTo18DecimalsUint(rawTotalSupply, decimals);

    // Initialize user's rewardPerTokenPaid snapshot if first time
    if (!userHasVault[user][vault]) {
        userVaults[user].push(vault);
        userHasVault[user][vault] = true;
        userRewards[vault][user].rewardPerTokenPaid = vaultRewards[vault].rewardPerTokenStored;
    }

    emit Staked(user, vault, IERC20(vault).balanceOf(user));
}

    function notifyWithdrawFor(address user, address vault) external nonReentrant {
    if (!factory.isVault(msg.sender)) revert NotAVault();

    uint8 decimals = vaultRewards[vault].vaultDecimals;
    require(decimals > 0, "Vault not initialized");

    uint256 rawTotalSupply = IERC20(vault).totalSupply();
    vaultRewards[vault].totalStaked = _scaleTo18DecimalsUint(rawTotalSupply, decimals);

    // Initialize user's rewardPerTokenPaid snapshot if first time
    if (!userHasVault[user][vault]) {
        userVaults[user].push(vault);
        userHasVault[user][vault] = true;
        userRewards[vault][user].rewardPerTokenPaid = vaultRewards[vault].rewardPerTokenStored;
    }

    emit Withdrawn(user, vault, IERC20(vault).balanceOf(user));
}

    /*//////////////////////////////////////////////////////////////
                           USER CLAIMS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Claim accrued rewards from a single vault
     * @param vault Address of the vault to claim rewards from
     * @dev Only callable if user has a positive balance in the vault
     * Calculates accrued rewards since last claim and mints MRD tokens to user
     */
    function claim(address vault) external nonReentrant {
        uint256 userBalance = IERC20(vault).balanceOf(msg.sender);
        require(userBalance > 0, "No balance in vault");

        _updateReward(msg.sender, vault);

        uint256 reward = userRewards[vault][msg.sender].rewards;
        if (reward == 0) revert NoRewards();

        userRewards[vault][msg.sender].rewards = 0;

        if (userTotalClaimableReward[msg.sender] >= reward) {
            userTotalClaimableReward[msg.sender] -= reward;
        } else {
            userTotalClaimableReward[msg.sender] = 0;
        }

        totalDistributed += reward;

        rewardToken.mint(msg.sender, reward);

        emit RewardsClaimed(msg.sender, vault, reward);
    }

    /**
     * @notice Claim all accrued rewards across all vaults the user has interacted with
     * @dev Iterates through all user vaults and claims rewards from those with positive balances
     * Skips vaults where user has zero balance to save gas
     * Aggregates rewards and mints total MRD tokens in single transaction
     */
    function claimAll() external nonReentrant {
        address[] storage vaults = userVaults[msg.sender];
        uint256 totalReward = 0;

        for (uint256 i = 0; i < vaults.length; i++) {
            address v = vaults[i];

            uint256 userBalance = IERC20(v).balanceOf(msg.sender);
            if (userBalance == 0) continue;

            _updateReward(msg.sender, v);

            uint256 r = userRewards[v][msg.sender].rewards;
            if (r > 0) {
                totalReward += r;
                userRewards[v][msg.sender].rewards = 0;
            }
        }

        if (totalReward == 0) revert NoRewards();

        userTotalClaimableReward[msg.sender] = 0;

        totalDistributed += totalReward;

        rewardToken.mint(msg.sender, totalReward);

        emit TotalRewardsClaimed(msg.sender, totalReward);
    }

    /*//////////////////////////////////////////////////////////////
                                 ADMIN
    //////////////////////////////////////////////////////////////*/

    function setRewardRate(address vault, uint256 rate) external onlyOwner {
        if (!factory.isVault(vault)) revert NotAVault();
        if (rate > MAX_REWARD_RATE) revert RateTooHigh();

        VaultRewardInfo storage info = vaultRewards[vault];
        uint256 currentRpt = rewardPerToken(vault);
        info.rewardPerTokenStored = currentRpt;
        info.lastUpdateTime = block.timestamp;

        uint256 oldRate = vaultRewards[vault].rewardRate;
        vaultRewards[vault].rewardRate = rate;

        emit RewardRateUpdated(vault, oldRate, rate);
    }

    function initializeVault(address vault, uint256 rate) external onlyOwner {
        if (!factory.isVault(vault)) revert NotAVault();
        if (rate > MAX_REWARD_RATE) revert RateTooHigh();

        uint8 decimals = ITokenDecimals(vault).decimals();

        uint256 rawTotalSupply = IERC20(vault).totalSupply();
        uint256 scaledTotalStaked = _scaleTo18DecimalsUint(rawTotalSupply, decimals);

        vaultRewards[vault] = VaultRewardInfo({
            rewardRate: rate,
            lastUpdateTime: block.timestamp,
            rewardPerTokenStored: 0,
            totalStaked: scaledTotalStaked,
            vaultDecimals: decimals
        });

        emit RewardRateUpdated(vault, 0, rate);
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    function _scaleTo18DecimalsUint(uint256 amount, uint8 tokenDecimals) internal pure returns (uint256) {
        if (tokenDecimals == 18) {
            return amount;
        } else if (tokenDecimals > 18) {
            return amount / (10 ** (tokenDecimals - 18));
        } else {
            return amount * (10 ** (18 - tokenDecimals));
        }
    }

    function _updateReward(address user, address vault) internal {
        VaultRewardInfo storage info = vaultRewards[vault];
        UserRewardInfo storage userInfo = userRewards[vault][user];

        // Step 1: Update vault state FIRST (rewardPerTokenStored and lastUpdateTime)
        // This ensures we're using the correct snapshot for user calculations
        uint256 currentRpt;
        if (info.totalStaked == 0) {
            currentRpt = info.rewardPerTokenStored;
        } else {
            uint256 timeElapsed = block.timestamp - info.lastUpdateTime;
            uint256 rewardAccrued = mulDiv(
                info.rewardRate * timeElapsed,
                1e18,
                info.totalStaked
            );
            currentRpt = info.rewardPerTokenStored + rewardAccrued;
        }

        // Step 2: Update vault storage immediately
        info.rewardPerTokenStored = currentRpt;
        info.lastUpdateTime = block.timestamp;

        // Step 3: Now calculate user rewards using the updated rewardPerTokenStored
        uint256 rawBalance = IERC20(vault).balanceOf(user);
        uint256 scaledBalance = _scaleTo18DecimalsUint(rawBalance, info.vaultDecimals);
        uint256 rptDelta = currentRpt - userInfo.rewardPerTokenPaid;
        uint256 newEarned = (scaledBalance * rptDelta) / 1e18;
        uint256 finalEarned = userInfo.rewards + newEarned;

        // Step 4: Update user state
        uint256 rewardToAccumulate = finalEarned - userInfo.rewards;
        if (rewardToAccumulate > 0) {
            userTotalClaimableReward[user] += rewardToAccumulate;
        }

        userInfo.rewards = finalEarned;
        userInfo.rewardPerTokenPaid = currentRpt;
    }

    /*//////////////////////////////////////////////////////////////
                              VIEW HELPERS
    //////////////////////////////////////////////////////////////*/

    function getUserVaults(address user) external view returns (address[] memory) {
        return userVaults[user];
    }

    function pendingRewards(address user, address[] calldata vaultList) external view returns (uint256 total) {
        for (uint256 i = 0; i < vaultList.length; i++) {
            total += earned(user, vaultList[i]);
        }
    }
}
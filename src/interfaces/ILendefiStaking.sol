// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title ILendefiStaking
 * @notice Interface for Lendefi DeFi staking contract
 * @dev Users stake LDF tokens to earn gas sponsorship tiers
 */
interface ILendefiStaking {
    // ============ Enums ============

    enum Tier {
        NONE, // 0 tokens - no subsidy
        BASIC, // >= 1,000 LDF - 50% subsidy
        PREMIUM, // >= 10,000 LDF - 90% subsidy
        ULTIMATE // >= 100,000 LDF - 100% subsidy
    }

    // ============ Structs ============

    struct StakeInfo {
        uint256 amount; // Total staked amount
        uint256 stakedAt; // Timestamp of first stake
        uint256 lastStakeTime; // Timestamp of last stake action
        uint256 gasUsedThisMonth; // Gas used in current month
        uint256 lastResetTime; // Last monthly reset timestamp
    }

    // ============ Events ============

    event Staked(address indexed user, uint256 amount, uint256 totalStaked, Tier newTier);
    event Unstaked(address indexed user, uint256 amount, uint256 remaining, Tier newTier);
    event TierThresholdsUpdated(uint256 basic, uint256 premium, uint256 ultimate);
    event GasLimitsUpdated(uint256 basic, uint256 premium, uint256 ultimate);
    event MinStakePeriodUpdated(uint256 oldPeriod, uint256 newPeriod);
    event GasUsageRecorded(address indexed user, uint256 gasUsed, uint256 totalThisMonth);
    event MonthlyGasReset(address indexed user);
    event PaymasterAuthorized(address indexed paymaster);
    event PaymasterRevoked(address indexed paymaster);

    // ============ Errors ============

    error ZeroAmount();
    error InsufficientStake();
    error StakePeriodNotMet();
    error NotAuthorizedPaymaster();
    error InvalidThresholds();
    error ZeroAddress();
    error TransferFailed();

    // ============ External Functions ============

    /// @notice Stake tokens to earn gas sponsorship tier
    function stake(uint256 amount) external;

    /// @notice Unstake tokens
    function unstake(uint256 amount) external;

    /// @notice Record gas usage for a user (called by paymaster)
    function recordGasUsage(address user, uint256 gasUsed) external;

    // ============ View Functions ============

    /// @notice Get user's current tier based on staked amount
    function getTier(address user) external view returns (Tier);

    /// @notice Get subsidy percentage for a tier
    function getSubsidyPercentage(Tier tier) external pure returns (uint256);

    /// @notice Get monthly gas limit for a tier
    function getMonthlyGasLimit(Tier tier) external view returns (uint256);

    /// @notice Check if user has enough gas allowance remaining
    function checkGasAllowance(address user, uint256 gasNeeded)
        external
        view
        returns (bool hasAllowance, uint256 remainingGas);

    /// @notice Get complete stake info for a user
    function getUserInfo(address user)
        external
        view
        returns (
            uint256 staked,
            Tier tier,
            uint256 subsidyPercent,
            uint256 gasUsed,
            uint256 gasLimit,
            uint256 canUnstakeAt
        );

    /// @notice Get tokens needed to reach next tier
    function getTokensToNextTier(address user) external view returns (uint256 tokensNeeded, Tier nextTier);

    // ============ Admin Functions ============

    function authorizePaymaster(address paymaster) external;
    function revokePaymaster(address paymaster) external;
    function setTierThresholds(uint256 basic, uint256 premium, uint256 ultimate) external;
    function setGasLimits(uint256 basic, uint256 premium, uint256 ultimate) external;
    function setMinStakePeriod(uint256 newPeriod) external;
}

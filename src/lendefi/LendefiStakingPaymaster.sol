// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "../interfaces/IPaymaster.sol";
import "../interfaces/IEntryPoint.sol";
import "../interfaces/PackedUserOperation.sol";
import "./LendefiStaking.sol";

/**
 * @title LendefiStakingPaymaster
 * @notice ERC-4337 Paymaster that sponsors gas based on LDFI token staking
 * @dev Users stake LDFI tokens in LendefiStaking contract to earn gas subsidies
 *      Upgradeable via UUPS proxy pattern
 * 
 * Flow:
 * 1. User stakes LDFI tokens in LendefiStaking contract
 * 2. Staking determines user's tier (BASIC/PREMIUM/ULTIMATE)
 * 3. When user submits UserOp, paymaster checks tier and gas allowance
 * 4. Paymaster sponsors gas based on tier's subsidy percentage
 * 5. Gas usage is recorded back to staking contract
 */
contract LendefiStakingPaymaster is 
    Initializable,
    UUPSUpgradeable,
    OwnableUpgradeable,
    PausableUpgradeable,
    ReentrancyGuard,
    IPaymaster 
{
    // ============ Errors ============
    
    error NotFromEntryPoint();
    error InvalidWallet();
    error NoStake();
    error MonthlyLimitExceeded();
    error GasLimitExceeded();
    error PaymasterDepositTooLow();
    error InvalidGasLimit();
    error ZeroAddress();

    // ============ State Variables ============

    /// @notice Contract version for upgrade tracking
    uint256 public constant VERSION = 1;

    /// @notice EntryPoint contract
    IEntryPoint public entryPoint;

    /// @notice Staking contract that determines tiers
    LendefiStaking public stakingContract;

    /// @notice Maximum gas allowed per single operation
    uint256 public maxGasPerOperation;

    /// @notice Minimum deposit required in paymaster
    uint256 public minPaymasterDeposit;

    /// @notice Storage gap for future upgrades
    uint256[30] private __gap;

    // ============ Events ============

    event GasSponsored(
        address indexed user,
        uint256 gasUsed,
        uint256 subsidyAmount,
        LendefiStaking.Tier tier
    );
    event MaxGasPerOperationUpdated(uint256 oldLimit, uint256 newLimit);
    event MinDepositUpdated(uint256 oldMin, uint256 newMin);
    event Deposited(address indexed sender, uint256 amount);
    event Withdrawn(address indexed to, uint256 amount);
    event StakingContractUpdated(address indexed oldContract, address indexed newContract);

    // ============ Modifiers ============

    modifier onlyEntryPoint() {
        if (msg.sender != address(entryPoint)) revert NotFromEntryPoint();
        _;
    }

    // ============ Constructor (for implementation) ============

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // ============ Initializer ============

    /**
     * @notice Initialize the contract (called once via proxy)
     * @param _entryPoint EntryPoint contract address
     * @param _stakingContract LendefiStaking contract address
     * @param _owner Owner address
     */
    function initialize(
        IEntryPoint _entryPoint,
        LendefiStaking _stakingContract,
        address _owner
    ) external initializer {
        if (address(_entryPoint) == address(0)) revert ZeroAddress();
        if (address(_stakingContract) == address(0)) revert ZeroAddress();
        if (_owner == address(0)) revert ZeroAddress();

        __Ownable_init(_owner);
        __Pausable_init();
        
        entryPoint = _entryPoint;
        stakingContract = _stakingContract;
        
        // Set defaults
        maxGasPerOperation = 500_000;
        minPaymasterDeposit = 0.1 ether;
    }

    // ============ Receive ============

    receive() external payable {
        emit Deposited(msg.sender, msg.value);
    }

    // ============ IPaymaster Implementation ============

    /**
     * @notice Validate paymaster is willing to sponsor this UserOp
     * @param userOp The user operation
     * @param maxCost Maximum cost of the operation
     * @return context Context for postOp
     * @return validationData Validation result
     */
    function validatePaymasterUserOp(
        PackedUserOperation calldata userOp,
        bytes32,
        uint256 maxCost
    ) external view override onlyEntryPoint returns (bytes memory context, uint256 validationData) {
        // Check not paused (view function can't use whenNotPaused modifier)
        require(!paused(), "Pausable: paused");
        
        address user = userOp.sender;

        // Check paymaster has enough deposit
        uint256 paymasterDeposit = entryPoint.balanceOf(address(this));
        if (paymasterDeposit < minPaymasterDeposit || paymasterDeposit < maxCost) {
            revert PaymasterDepositTooLow();
        }

        // Get user's tier from staking contract
        LendefiStaking.Tier tier = stakingContract.getTier(user);
        if (tier == LendefiStaking.Tier.NONE) {
            revert NoStake();
        }

        // Validate gas limits
        uint256 estimatedGas = _extractGasLimits(userOp);
        if (estimatedGas > maxGasPerOperation) {
            revert GasLimitExceeded();
        }

        // Check user has enough gas allowance remaining this month
        (bool hasAllowance, ) = stakingContract.checkGasAllowance(user, estimatedGas);
        if (!hasAllowance) {
            revert MonthlyLimitExceeded();
        }

        // Calculate subsidy amount
        uint256 subsidyPercentage = stakingContract.getSubsidyPercentage(tier);
        uint256 subsidyAmount = (maxCost * subsidyPercentage) / 100;

        // Pack context for postOp
        context = abi.encode(user, estimatedGas, subsidyAmount, tier);

        // Return success with no time bounds
        validationData = 0;
    }

    /**
     * @notice Post-operation handler - records gas usage
     * @param mode Operation result mode
     * @param context Context from validatePaymasterUserOp
     * @param actualGasCost Actual gas cost incurred
     * @param actualUserOpFeePerGas Actual fee per gas used to calculate actual gas units
     */
    function postOp(
        PostOpMode mode,
        bytes calldata context,
        uint256 actualGasCost,
        uint256 actualUserOpFeePerGas
    ) external override onlyEntryPoint {
        if (mode == PostOpMode.opSucceeded || mode == PostOpMode.opReverted) {
            (
                address user,
                ,  // estimatedGas - no longer used
                ,
                LendefiStaking.Tier tier
            ) = abi.decode(context, (address, uint256, uint256, LendefiStaking.Tier));

            // Calculate actual gas used from actual cost
            uint256 actualGasUsed = actualUserOpFeePerGas > 0 
                ? actualGasCost / actualUserOpFeePerGas 
                : 0;

            // Record actual gas usage in staking contract
            if (actualGasUsed > 0) {
                stakingContract.recordGasUsage(user, actualGasUsed);
            }

            // Calculate actual subsidy for event
            uint256 subsidyPercentage = stakingContract.getSubsidyPercentage(tier);
            uint256 actualSubsidy = (actualGasCost * subsidyPercentage) / 100;

            emit GasSponsored(user, actualGasUsed, actualSubsidy, tier);
        }
    }

    // ============ View Functions ============

    /**
     * @notice Check if a user is eligible for gas sponsorship
     * @param user User address
     * @param gasNeeded Estimated gas needed
     * @return eligible True if eligible
     * @return tier User's current tier
     * @return subsidyPercent Subsidy percentage
     */
    function checkEligibility(
        address user,
        uint256 gasNeeded
    ) external view returns (bool eligible, LendefiStaking.Tier tier, uint256 subsidyPercent) {
        tier = stakingContract.getTier(user);
        
        if (tier == LendefiStaking.Tier.NONE) {
            return (false, tier, 0);
        }

        (bool hasAllowance, ) = stakingContract.checkGasAllowance(user, gasNeeded);
        subsidyPercent = stakingContract.getSubsidyPercentage(tier);
        eligible = hasAllowance && gasNeeded <= maxGasPerOperation;
    }

    /**
     * @notice Get paymaster's deposit in EntryPoint
     * @return Deposit amount
     */
    function getDeposit() external view returns (uint256) {
        return entryPoint.balanceOf(address(this));
    }

    // ============ Admin Functions ============

    /**
     * @notice Deposit ETH to EntryPoint for gas sponsorship
     */
    function deposit() external payable onlyOwner {
        entryPoint.depositTo{value: msg.value}(address(this));
        emit Deposited(msg.sender, msg.value);
    }

    /**
     * @notice Withdraw deposit from EntryPoint
     * @param to Recipient address
     * @param amount Amount to withdraw
     */
    function withdrawDeposit(address payable to, uint256 amount) external onlyOwner nonReentrant {
        entryPoint.withdrawTo(to, amount);
        emit Withdrawn(to, amount);
    }

    /**
     * @notice Add stake to EntryPoint (required for paymaster)
     * @param unstakeDelaySec Unstake delay in seconds
     */
    function addStake(uint32 unstakeDelaySec) external payable onlyOwner {
        entryPoint.addStake{value: msg.value}(unstakeDelaySec);
    }

    /**
     * @notice Unlock stake from EntryPoint
     */
    function unlockStake() external onlyOwner {
        entryPoint.unlockStake();
    }

    /**
     * @notice Withdraw stake from EntryPoint
     * @param to Recipient address
     */
    function withdrawStake(address payable to) external onlyOwner nonReentrant {
        entryPoint.withdrawStake(to);
    }

    /**
     * @notice Update maximum gas per operation
     * @param newLimit New gas limit
     */
    function setMaxGasPerOperation(uint256 newLimit) external onlyOwner {
        if (newLimit == 0) revert InvalidGasLimit();
        uint256 oldLimit = maxGasPerOperation;
        maxGasPerOperation = newLimit;
        emit MaxGasPerOperationUpdated(oldLimit, newLimit);
    }

    /**
     * @notice Update minimum paymaster deposit threshold
     * @param newMin New minimum deposit (must be > 0)
     */
    function setMinPaymasterDeposit(uint256 newMin) external onlyOwner {
        if (newMin == 0) revert PaymasterDepositTooLow();
        uint256 oldMin = minPaymasterDeposit;
        minPaymasterDeposit = newMin;
        emit MinDepositUpdated(oldMin, newMin);
    }

    /**
     * @notice Update the staking contract address
     * @param newStakingContract New staking contract address
     */
    function setStakingContract(LendefiStaking newStakingContract) external onlyOwner {
        if (address(newStakingContract) == address(0)) revert ZeroAddress();
        address oldContract = address(stakingContract);
        stakingContract = newStakingContract;
        emit StakingContractUpdated(oldContract, address(newStakingContract));
    }

    /**
     * @notice Pause the contract
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Unpause the contract
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    // ============ Internal Functions ============

    /**
     * @dev Extract gas limits from packed UserOp
     */
    function _extractGasLimits(PackedUserOperation calldata userOp) internal pure returns (uint256) {
        // accountGasLimits is packed as: verificationGasLimit (16 bytes) | callGasLimit (16 bytes)
        bytes32 gasLimits = userOp.accountGasLimits;
        uint256 verificationGasLimit = uint128(bytes16(gasLimits));
        uint256 callGasLimit = uint128(uint256(gasLimits));
        
        return verificationGasLimit + callGasLimit + userOp.preVerificationGas;
    }

    /**
     * @dev Authorize upgrade (UUPS)
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}

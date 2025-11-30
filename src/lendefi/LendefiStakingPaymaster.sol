// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "../aa-v07/contracts/interfaces/IPaymaster.sol";
import "../aa-v07/contracts/interfaces/IEntryPoint.sol";
import "../aa-v07/contracts/interfaces/PackedUserOperation.sol";
import "./LendefiStaking.sol";

/**
 * @title LendefiStakingPaymaster
 * @notice ERC-4337 v0.7 Paymaster that sponsors gas based on LDF token staking
 * @dev Upgradeable version implementing BasePaymaster patterns from aa-v07
 *      Users stake LDF tokens in LendefiStaking contract to earn gas subsidies
 *
 * Architecture:
 * - Cannot inherit from BasePaymaster due to immutable entryPoint (breaks UUPS)
 * - Implements all BasePaymaster functions with identical signatures
 * - Uses same _requireFromEntryPoint pattern for security
 *
 * Flow:
 * 1. User stakes LDF tokens in LendefiStaking contract
 * 2. Staking determines user's tier (BASIC/PREMIUM/ULTIMATE)
 * 3. When user submits UserOp, paymaster checks tier and gas allowance
 * 4. Paymaster sponsors gas based on tier's subsidy percentage
 * 5. Gas usage is recorded back to staking contract
 */
contract LendefiStakingPaymaster is
    Initializable,
    UUPSUpgradeable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable,
    IPaymaster
{
    // ═══════════════════════════════════════════════════════════════════════════
    // ERRORS
    // ═══════════════════════════════════════════════════════════════════════════

    error NotFromEntryPoint();
    error InvalidWallet();
    error NoStake();
    error MonthlyLimitExceeded();
    error GasLimitExceeded();
    error PaymasterDepositTooLow();
    error InvalidGasLimit();
    error ZeroAddress();

    // ═══════════════════════════════════════════════════════════════════════════
    // STATE VARIABLES
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice EntryPoint contract (stored instead of immutable for upgradeability)
    IEntryPoint public entryPoint;

    /// @notice Staking contract that determines tiers
    LendefiStaking public stakingContract;

    /// @notice Maximum gas allowed per single operation
    uint256 public maxGasPerOperation;

    /// @notice Minimum deposit required in paymaster
    uint256 public minPaymasterDeposit;

    /// @notice Deployed version (increments on each upgrade)
    uint256 public version;

    /// @notice Storage gap for future upgrades
    uint256[44] private __gap;

    // ═══════════════════════════════════════════════════════════════════════════
    // EVENTS
    // ═══════════════════════════════════════════════════════════════════════════

    event GasSponsored(address indexed user, uint256 gasUsed, uint256 subsidyAmount, LendefiStaking.Tier tier);
    event MaxGasPerOperationUpdated(uint256 oldLimit, uint256 newLimit);
    event MinDepositUpdated(uint256 oldMin, uint256 newMin);
    event Deposited(address indexed sender, uint256 amount);
    event Withdrawn(address indexed to, uint256 amount);
    event StakingContractUpdated(address indexed oldContract, address indexed newContract);

    // ═══════════════════════════════════════════════════════════════════════════
    // CONSTRUCTOR (for implementation)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // INITIALIZER
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Initialize the contract (called once via proxy)
     * @param _entryPoint EntryPoint contract address
     * @param _stakingContract LendefiStaking contract address
     * @param _owner Owner address
     */
    function initialize(IEntryPoint _entryPoint, LendefiStaking _stakingContract, address _owner) external initializer {
        if (address(_entryPoint) == address(0)) revert ZeroAddress();
        if (address(_stakingContract) == address(0)) revert ZeroAddress();
        if (_owner == address(0)) revert ZeroAddress();

        __Ownable_init(_owner);
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        entryPoint = _entryPoint;
        stakingContract = _stakingContract;

        // Set defaults
        maxGasPerOperation = 500_000;
        minPaymasterDeposit = 0.1 ether;
        version = 1;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // RECEIVE
    // ═══════════════════════════════════════════════════════════════════════════

    receive() external payable {
        emit Deposited(msg.sender, msg.value);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // IPAYMASTER IMPLEMENTATION (BasePaymaster pattern)
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Validate paymaster is willing to sponsor this UserOp
     * @dev Follows BasePaymaster pattern: external validates entrypoint, delegates to internal
     * @param userOp The user operation
     * @param userOpHash Hash of the user operation
     * @param maxCost Maximum cost of the operation
     * @return context Context for postOp
     * @return validationData Validation result
     */
    function validatePaymasterUserOp(PackedUserOperation calldata userOp, bytes32 userOpHash, uint256 maxCost)
        external
        override
        returns (bytes memory context, uint256 validationData)
    {
        _requireFromEntryPoint();
        return _validatePaymasterUserOp(userOp, userOpHash, maxCost);
    }

    /**
     * @notice Post-operation handler - records gas usage
     * @dev Follows BasePaymaster pattern: external validates entrypoint, delegates to internal
     * @param mode Operation result mode
     * @param context Context from validatePaymasterUserOp
     * @param actualGasCost Actual gas cost incurred
     * @param actualUserOpFeePerGas Actual fee per gas
     */
    function postOp(PostOpMode mode, bytes calldata context, uint256 actualGasCost, uint256 actualUserOpFeePerGas)
        external
        override
    {
        _requireFromEntryPoint();
        _postOp(mode, context, actualGasCost, actualUserOpFeePerGas);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // BASEPAYMASTER STAKE MANAGEMENT FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Add a deposit for this paymaster, used for paying for transaction fees
     * @dev Matches BasePaymaster.deposit() signature - public, payable
     */
    function deposit() public payable {
        entryPoint.depositTo{value: msg.value}(address(this));
        emit Deposited(msg.sender, msg.value);
    }

    /**
     * @notice Withdraw value from the deposit
     * @dev Matches BasePaymaster.withdrawTo() signature
     * @param withdrawAddress Target to send to
     * @param amount Amount to withdraw
     */
    function withdrawTo(address payable withdrawAddress, uint256 amount) public onlyOwner {
        entryPoint.withdrawTo(withdrawAddress, amount);
        emit Withdrawn(withdrawAddress, amount);
    }

    /**
     * @notice Add stake for this paymaster
     * @dev Matches BasePaymaster.addStake() signature
     * @param unstakeDelaySec The unstake delay for this paymaster
     */
    function addStake(uint32 unstakeDelaySec) external payable onlyOwner {
        entryPoint.addStake{value: msg.value}(unstakeDelaySec);
    }

    /**
     * @notice Return current paymaster's deposit on the entryPoint
     * @dev Matches BasePaymaster.getDeposit() signature
     */
    function getDeposit() public view returns (uint256) {
        return entryPoint.balanceOf(address(this));
    }

    /**
     * @notice Unlock the stake, in order to withdraw it
     * @dev Matches BasePaymaster.unlockStake() signature
     */
    function unlockStake() external onlyOwner {
        entryPoint.unlockStake();
    }

    /**
     * @notice Withdraw the entire paymaster's stake
     * @dev Matches BasePaymaster.withdrawStake() signature
     * @param withdrawAddress The address to send withdrawn value
     */
    function withdrawStake(address payable withdrawAddress) external onlyOwner {
        entryPoint.withdrawStake(withdrawAddress);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Check if a user is eligible for gas sponsorship
     * @param user User address
     * @param gasNeeded Estimated gas needed
     * @return eligible True if eligible
     * @return tier User's current tier
     * @return subsidyPercent Subsidy percentage
     */
    function checkEligibility(address user, uint256 gasNeeded)
        external
        view
        returns (bool eligible, LendefiStaking.Tier tier, uint256 subsidyPercent)
    {
        tier = stakingContract.getTier(user);

        if (tier == LendefiStaking.Tier.NONE) {
            return (false, tier, 0);
        }

        (bool hasAllowance,) = stakingContract.checkGasAllowance(user, gasNeeded);
        subsidyPercent = stakingContract.getSubsidyPercentage(tier);
        eligible = hasAllowance && gasNeeded <= maxGasPerOperation;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ADMIN FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

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

    // ═══════════════════════════════════════════════════════════════════════════
    // INTERNAL FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @dev Validate the call is made from a valid entrypoint
     *      Matches BasePaymaster._requireFromEntryPoint()
     */
    function _requireFromEntryPoint() internal view {
        require(msg.sender == address(entryPoint), "Sender not EntryPoint");
    }

    /**
     * @dev Internal validation logic
     */
    function _validatePaymasterUserOp(
        PackedUserOperation calldata userOp,
        bytes32,
        /*userOpHash*/
        uint256 maxCost
    )
        internal
        view
        returns (bytes memory context, uint256 validationData)
    {
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
        (bool hasAllowance,) = stakingContract.checkGasAllowance(user, estimatedGas);
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
     * @dev Internal post-operation logic
     */
    function _postOp(PostOpMode mode, bytes calldata context, uint256 actualGasCost, uint256 actualUserOpFeePerGas)
        internal
    {
        if (mode == PostOpMode.opSucceeded || mode == PostOpMode.opReverted) {
            (
                address user,, // estimatedGas - no longer used
                ,
                LendefiStaking.Tier tier
            ) = abi.decode(context, (address, uint256, uint256, LendefiStaking.Tier));

            // Calculate actual gas used from actual cost
            uint256 actualGasUsed = actualUserOpFeePerGas > 0 ? actualGasCost / actualUserOpFeePerGas : 0;

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
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {
        version++;
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {BasePaymaster} from "../aa-v07/contracts/core/BasePaymaster.sol";
import {IEntryPoint} from "../aa-v07/contracts/interfaces/IEntryPoint.sol";
import {PackedUserOperation} from "../aa-v07/contracts/interfaces/PackedUserOperation.sol";

/**
 * @title LendefiPaymaster
 * @notice ERC-4337 v0.7 Paymaster that subsidizes gas for users with valid sponsorship attestations
 * @dev Inherits from audited BasePaymaster for stake/deposit management
 *      The app backend signs attestations for staked users, paymaster verifies signatures
 *      Works across all chains - staking happens on one chain, app is the source of truth
 * @custom:security-contact security@lendefimarkets.com
 */
contract LendefiPaymaster is BasePaymaster, ReentrancyGuard {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    // ═══════════════════════════════════════════════════════════════════════════
    // CONSTANTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Signature validity period
    uint256 public constant SIGNATURE_VALIDITY = 5 minutes;

    // ═══════════════════════════════════════════════════════════════════════════
    // STATE
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Authorized signer (app backend)
    address public sponsorshipSigner;

    /// @notice Used attestation nonces to prevent replay
    mapping(address => uint256) public nonces;

    /// @notice Sponsor deposit balance (tracked separately from EntryPoint deposit)
    uint256 public sponsorBalance;

    /// @notice Maximum gas to sponsor per operation
    uint256 public maxGasPerOp;

    // ═══════════════════════════════════════════════════════════════════════════
    // EVENTS
    // ═══════════════════════════════════════════════════════════════════════════

    event SignerUpdated(address indexed oldSigner, address indexed newSigner);
    event Sponsored(address indexed user, bytes32 indexed userOpHash, uint256 gasUsed);
    event Deposited(address indexed depositor, uint256 amount);
    event Withdrawn(address indexed to, uint256 amount);
    event MaxGasUpdated(uint256 oldMax, uint256 newMax);

    // ═══════════════════════════════════════════════════════════════════════════
    // ERRORS
    // ═══════════════════════════════════════════════════════════════════════════

    error ZeroAddress();
    error ZeroAmount();
    error InvalidSignature();
    error ExpiredSignature(uint256 deadline, uint256 current);
    error InvalidNonce(uint256 expected, uint256 provided);
    error InsufficientBalance(uint256 required, uint256 available);
    error GasLimitExceeded(uint256 requested, uint256 max);

    // ═══════════════════════════════════════════════════════════════════════════
    // CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Deploy the paymaster
     * @param _entryPoint ERC-4337 EntryPoint address
     * @param _signer Initial sponsorship signer (app backend)
     * @param _maxGasPerOp Maximum gas to sponsor per operation
     */
    constructor(
        IEntryPoint _entryPoint,
        address _signer,
        uint256 _maxGasPerOp
    ) BasePaymaster(_entryPoint) {
        if (_signer == address(0)) revert ZeroAddress();
        if (_maxGasPerOp == 0) revert ZeroAmount();

        sponsorshipSigner = _signer;
        maxGasPerOp = _maxGasPerOp;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // RECEIVE
    // ═══════════════════════════════════════════════════════════════════════════

    receive() external payable {
        // Accept ETH deposits directly
        sponsorBalance += msg.value;
        emit Deposited(msg.sender, msg.value);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // PAYMASTER IMPLEMENTATION (overrides BasePaymaster)
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Validate a user operation for sponsorship
     * @dev Called by BasePaymaster.validatePaymasterUserOp after _requireFromEntryPoint
     * @param userOp The user operation
     * @param userOpHash Hash of the user operation
     * @param maxCost Maximum cost of the operation
     * @return context Context to pass to postOp
     * @return validationData Packed validation data (sigFailed, validUntil, validAfter)
     */
    function _validatePaymasterUserOp(
        PackedUserOperation calldata userOp,
        bytes32 userOpHash,
        uint256 maxCost
    ) internal override returns (bytes memory context, uint256 validationData) {
        // Check sponsor balance
        if (sponsorBalance < maxCost) {
            revert InsufficientBalance(maxCost, sponsorBalance);
        }

        // Validate and decode paymaster data
        (bool valid, uint256 deadline) = _validatePaymasterData(userOp, userOpHash);
        
        if (!valid) {
            return ("", _packValidationData(true, 0, 0));
        }

        // Check gas limit
        uint256 totalGas = _unpackGas(userOp.accountGasLimits) + _unpackGas(userOp.gasFees);
        if (totalGas > maxGasPerOp) {
            revert GasLimitExceeded(totalGas, maxGasPerOp);
        }

        // Reserve the max cost
        sponsorBalance -= maxCost;

        // Return context for postOp and validation data
        context = abi.encode(userOp.sender, maxCost);
        validationData = _packValidationData(false, uint48(deadline), 0);
    }

    /**
     * @notice Post-operation handler
     * @dev Called by BasePaymaster.postOp after _requireFromEntryPoint
     * @param context Context from validatePaymasterUserOp
     * @param actualGasCost Actual gas cost
     */
    function _postOp(
        PostOpMode,
        bytes calldata context,
        uint256 actualGasCost,
        uint256
    ) internal override {
        (address sender, uint256 maxCost) = abi.decode(context, (address, uint256));

        // Refund unused gas reservation
        uint256 refund = maxCost - actualGasCost;
        if (refund > 0) {
            sponsorBalance += refund;
        }

        emit Sponsored(sender, bytes32(0), actualGasCost);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ADMIN FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Update the sponsorship signer
     * @param newSigner New signer address
     */
    function setSigner(address newSigner) external onlyOwner {
        if (newSigner == address(0)) revert ZeroAddress();
        address oldSigner = sponsorshipSigner;
        sponsorshipSigner = newSigner;
        emit SignerUpdated(oldSigner, newSigner);
    }

    /**
     * @notice Update max gas per operation
     * @param newMaxGas New max gas limit
     */
    function setMaxGasPerOp(uint256 newMaxGas) external onlyOwner {
        if (newMaxGas == 0) revert ZeroAmount();
        uint256 oldMax = maxGasPerOp;
        maxGasPerOp = newMaxGas;
        emit MaxGasUpdated(oldMax, newMaxGas);
    }

    /**
     * @notice Deposit funds for sponsorship (also deposits to EntryPoint)
     */
    function depositSponsorship() external payable nonReentrant {
        if (msg.value == 0) revert ZeroAmount();
        
        // Deposit to EntryPoint
        entryPoint.depositTo{value: msg.value}(address(this));
        sponsorBalance += msg.value;
        
        emit Deposited(msg.sender, msg.value);
    }

    /**
     * @notice Withdraw funds from sponsorship pool
     * @param to Recipient address
     * @param amount Amount to withdraw
     */
    function withdrawSponsorship(address to, uint256 amount) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (amount > sponsorBalance) revert InsufficientBalance(amount, sponsorBalance);

        sponsorBalance -= amount;
        entryPoint.withdrawTo(payable(to), amount);
        
        emit Withdrawn(to, amount);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Get the current nonce for a user
     * @param user User address
     * @return Current nonce
     */
    function getNonce(address user) external view returns (uint256) {
        return nonces[user];
    }

    /**
     * @notice Generate hash for sponsorship attestation (for app backend)
     * @param sender User wallet address
     * @param nonce Current nonce
     * @param deadline Signature deadline
     * @param userOpHash Hash of the user operation
     * @return Attestation hash to sign
     */
    function getAttestationHash(
        address sender,
        uint256 nonce,
        uint256 deadline,
        bytes32 userOpHash
    ) external view returns (bytes32) {
        return _getHash(sender, nonce, deadline, userOpHash);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // INTERNAL FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @dev Internal validation of paymaster data and signature
     */
    function _validatePaymasterData(
        PackedUserOperation calldata userOp,
        bytes32 userOpHash
    ) internal returns (bool valid, uint256 deadline) {
        // Decode paymasterAndData: [paymaster(20)] [deadline(32)] [nonce(32)] [signature(65)]
        bytes calldata paymasterData = userOp.paymasterAndData[20:];
        
        if (paymasterData.length < 129) {
            return (false, 0);
        }

        deadline = uint256(bytes32(paymasterData[0:32]));
        uint256 nonce = uint256(bytes32(paymasterData[32:64]));

        // Check deadline
        if (block.timestamp > deadline) {
            revert ExpiredSignature(deadline, block.timestamp);
        }

        // Check nonce
        address sender = userOp.sender;
        if (nonce != nonces[sender]) {
            revert InvalidNonce(nonces[sender], nonce);
        }

        // Verify signature
        bytes32 hash = _getHash(sender, nonce, deadline, userOpHash);
        bytes memory signature = paymasterData[64:129];
        
        address recovered = hash.recover(signature);
        if (recovered != sponsorshipSigner) {
            return (false, deadline);
        }

        // Increment nonce
        nonces[sender]++;
        
        return (true, deadline);
    }

    /**
     * @dev Generate hash for signature verification
     */
    function _getHash(
        address sender,
        uint256 nonce,
        uint256 deadline,
        bytes32 userOpHash
    ) internal view returns (bytes32) {
        return keccak256(abi.encodePacked(
            sender,
            block.chainid,
            address(this),
            nonce,
            deadline,
            userOpHash
        )).toEthSignedMessageHash();
    }

    /**
     * @dev Pack validation data for ERC-4337
     */
    function _packValidationData(
        bool sigFailed,
        uint48 validUntil,
        uint48 validAfter
    ) internal pure returns (uint256) {
        return (sigFailed ? 1 : 0) | (uint256(validUntil) << 160) | (uint256(validAfter) << 208);
    }

    /**
     * @dev Unpack gas limits from packed format
     */
    function _unpackGas(bytes32 packed) internal pure returns (uint256) {
        return uint128(uint256(packed)) + uint128(uint256(packed) >> 128);
    }
}

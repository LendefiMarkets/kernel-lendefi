// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title ILendefiPaymaster
 * @notice Interface for the Lendefi sponsorship paymaster
 */
interface ILendefiPaymaster {
    // ============ Events ============

    event SignerUpdated(address indexed oldSigner, address indexed newSigner);
    event Sponsored(address indexed user, bytes32 indexed userOpHash, uint256 gasUsed);
    event Deposited(address indexed depositor, uint256 amount);
    event Withdrawn(address indexed to, uint256 amount);
    event MaxGasUpdated(uint256 oldMax, uint256 newMax);
    event Paused(address indexed by);
    event Unpaused(address indexed by);

    // ============ Errors ============

    error ZeroAddress();
    error ZeroAmount();
    error InvalidSignature();
    error ExpiredSignature(uint256 deadline, uint256 current);
    error InvalidNonce(uint256 expected, uint256 provided);
    error InsufficientBalance(uint256 required, uint256 available);
    error GasLimitExceeded(uint256 requested, uint256 max);
    error ContractPaused();
    error OnlyEntryPoint();

    // ============ View Functions ============

    /**
     * @notice Get the current nonce for a user
     * @param user User address
     * @return Current nonce
     */
    function getNonce(address user) external view returns (uint256);

    /**
     * @notice Generate hash for sponsorship attestation
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
    ) external view returns (bytes32);

    /**
     * @notice Get the sponsorship signer address
     */
    function sponsorshipSigner() external view returns (address);

    /**
     * @notice Get the sponsor balance
     */
    function sponsorBalance() external view returns (uint256);

    /**
     * @notice Get the max gas per operation
     */
    function maxGasPerOp() external view returns (uint256);

    /**
     * @notice Check if paused
     */
    function paused() external view returns (bool);

    // ============ Admin Functions ============

    /**
     * @notice Update the sponsorship signer
     * @param newSigner New signer address
     */
    function setSigner(address newSigner) external;

    /**
     * @notice Update max gas per operation
     * @param newMaxGas New max gas limit
     */
    function setMaxGasPerOp(uint256 newMaxGas) external;

    /**
     * @notice Deposit funds for sponsorship
     */
    function deposit() external payable;

    /**
     * @notice Withdraw funds from sponsorship pool
     * @param to Recipient address
     * @param amount Amount to withdraw
     */
    function withdraw(address to, uint256 amount) external;

    /**
     * @notice Pause the paymaster
     */
    function pause() external;

    /**
     * @notice Unpause the paymaster
     */
    function unpause() external;
}

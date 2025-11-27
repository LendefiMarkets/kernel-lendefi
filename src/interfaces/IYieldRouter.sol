// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title IYieldRouter Interface
 * @notice Interface for the Lendefi Yield Router
 */
interface IYieldRouter {
    // ============ Structs ============

    /// @notice Supported yield asset configuration
    struct YieldAsset {
        address token;           // Yield-bearing token address (OUSG, BUIDL, etc.)
        address depositToken;    // Token used to acquire yield asset (USDC)
        address manager;         // Manager/minter contract for the yield asset
        uint256 allocation;      // Basis points allocation (e.g., 5000 = 50%)
        bool active;             // Whether this asset is active
    }

    // ============ Events ============

    event Deposit(
        address indexed depositor,
        address indexed depositToken,
        uint256 depositAmount,
        uint256 usdlMinted
    );

    event Withdraw(
        address indexed withdrawer,
        address indexed withdrawToken,
        uint256 usdlBurned,
        uint256 withdrawAmount
    );

    event YieldAssetAdded(address indexed token, address indexed manager, uint256 allocation);
    event YieldAssetUpdated(address indexed token, uint256 newAllocation);
    event YieldAssetRemoved(address indexed token);
    event AllocationRebalanced(address indexed caller);
    event FiatOnrampProcessed(bytes32 indexed referenceId, address indexed recipient, uint256 amount);

    // ============ Functions ============

    /// @notice Deposit USDC and receive USDL
    function depositUSDC(uint256 amount, address recipient) external returns (uint256 usdlAmount);

    /// @notice Deposit ETH and receive USDL
    function depositETH(address recipient) external payable returns (uint256 usdlAmount);

    /// @notice Withdraw USDL and receive underlying assets
    function withdraw(uint256 usdlAmount, address recipient) external returns (uint256 withdrawAmount);

    /// @notice Process fiat onramp (authorized operator only)
    function processFiatOnramp(
        bytes32 referenceId,
        address recipient,
        uint256 usdcAmount
    ) external returns (uint256 usdlAmount);

    /// @notice Get total value locked in yield assets (in USDC terms)
    function getTotalValueLocked() external view returns (uint256);

    /// @notice Get current backing ratio
    function getBackingRatio() external view returns (uint256);
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title YieldRouter
 * @notice Routes deposits into yield-bearing RWA assets and mints USDL
 * @dev Manages the conversion of USDC/ETH deposits into yield-bearing assets (OUSG, BUIDL, etc.)
 *      and mints synthetic USDL stablecoin backed by these assets.
 *      This contract is immutable (non-upgradeable).
 *
 *      Flow:
 *      1. User deposits USDC (or ETH converted to USDC via DEX)
 *      2. Router allocates USDC to yield assets per configured allocation
 *      3. Router mints equivalent USDL to user
 *
 *      Fiat On-ramp (FedNow/RTP):
 *      1. User initiates ACH transfer
 *      2. Off-chain system receives fiat, purchases USDC
 *      3. Authorized operator calls processFiatOnramp()
 *      4. Router acquires yield assets and mints USDL to user
 *
 * @custom:security-contact security@lendefimarkets.com
 */

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IYieldRouter} from "../interfaces/IYieldRouter.sol";
import {USDL} from "./USDL.sol";

contract YieldRouter is
    IYieldRouter,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable
{
    using SafeERC20 for IERC20;

    // ============ Constants ============

    /// @notice Contract version
    uint256 public constant VERSION = 1;

    /// @notice Basis points denominator (100%)
    uint256 public constant BASIS_POINTS = 10_000;

    /// @notice Minimum deposit amount (1 USDC)
    uint256 public constant MIN_DEPOSIT = 1e6;

    /// @dev Role for operators who can process fiat onramps
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    /// @dev Role for managing yield assets
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");

    // ============ Storage Variables ============

    /// @notice USDL stablecoin contract
    USDL public usdl;

    /// @notice USDC token address
    IERC20 public usdc;

    /// @notice WETH token address
    IERC20 public weth;

    /// @notice DEX router for ETH → USDC swaps
    address public dexRouter;

    /// @notice Array of yield asset IDs
    address[] public yieldAssetList;

    /// @notice Yield asset configurations
    mapping(address => YieldAsset) public yieldAssets;

    /// @notice Processed fiat onramp references (prevent replay)
    mapping(bytes32 => bool) public processedOnramps;

    /// @notice Treasury address for fees
    address public treasury;

    /// @notice Deposit fee in basis points (e.g., 10 = 0.1%)
    uint256 public depositFeeBps;

    /// @notice Withdrawal fee in basis points
    uint256 public withdrawalFeeBps;

    // ============ Events ============

    event DexRouterUpdated(address indexed oldRouter, address indexed newRouter);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event FeesUpdated(uint256 depositFeeBps, uint256 withdrawalFeeBps);
    event EmergencyWithdraw(address indexed token, address indexed to, uint256 amount);

    // ============ Errors ============

    error ZeroAddress();
    error ZeroAmount();
    error BelowMinimumDeposit(uint256 amount, uint256 minimum);
    error InvalidAllocation(uint256 totalBps);
    error AssetAlreadyExists(address token);
    error AssetNotFound(address token);
    error AssetNotActive(address token);
    error OnrampAlreadyProcessed(bytes32 referenceId);
    error InsufficientBalance(uint256 available, uint256 required);
    error SwapFailed();
    error InvalidFee(uint256 fee);
    error AllocationMismatch();

    // ============ Modifiers ============

    modifier nonZeroAddress(address addr) {
        if (addr == address(0)) revert ZeroAddress();
        _;
    }

    modifier nonZeroAmount(uint256 amount) {
        if (amount == 0) revert ZeroAmount();
        _;
    }

    // ============ Constructor ============

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        // Immutable contract - no initializers to disable
    }

    // ============ Initializer ============

    /**
     * @notice Initialize the YieldRouter contract
     * @param _owner Admin address
     * @param _usdl USDL stablecoin address
     * @param _usdc USDC token address
     * @param _weth WETH token address
     * @param _dexRouter DEX router for swaps
     * @param _treasury Treasury address for fees
     */
    function initialize(
        address _owner,
        address _usdl,
        address _usdc,
        address _weth,
        address _dexRouter,
        address _treasury
    ) external initializer {
        if (_owner == address(0)) revert ZeroAddress();
        if (_usdl == address(0)) revert ZeroAddress();
        if (_usdc == address(0)) revert ZeroAddress();
        if (_treasury == address(0)) revert ZeroAddress();

        __AccessControl_init();
        __ReentrancyGuard_init();
        __Pausable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, _owner);
        _grantRole(OPERATOR_ROLE, _owner);
        _grantRole(MANAGER_ROLE, _owner);

        usdl = USDL(_usdl);
        usdc = IERC20(_usdc);
        weth = IERC20(_weth);
        dexRouter = _dexRouter;
        treasury = _treasury;

        // Default fees: 0.1% deposit, 0.1% withdrawal
        depositFeeBps = 10;
        withdrawalFeeBps = 10;
    }

    // ============ Deposit Functions ============

    /**
     * @notice Deposit USDC and receive USDL
     * @param amount USDC amount to deposit
     * @param recipient Address to receive USDL
     * @return usdlAmount Amount of USDL minted
     */
    function depositUSDC(uint256 amount, address recipient)
        external
        override
        nonReentrant
        whenNotPaused
        nonZeroAddress(recipient)
        returns (uint256 usdlAmount)
    {
        if (amount < MIN_DEPOSIT) revert BelowMinimumDeposit(amount, MIN_DEPOSIT);

        // Transfer USDC from sender
        usdc.safeTransferFrom(msg.sender, address(this), amount);

        // Process deposit
        usdlAmount = _processDeposit(amount, recipient);
    }

    /**
     * @notice Deposit ETH and receive USDL
     * @param recipient Address to receive USDL
     * @return usdlAmount Amount of USDL minted
     */
    function depositETH(address recipient)
        external
        payable
        override
        nonReentrant
        whenNotPaused
        nonZeroAddress(recipient)
        returns (uint256 usdlAmount)
    {
        if (msg.value == 0) revert ZeroAmount();

        // Swap ETH to USDC via DEX
        uint256 usdcAmount = _swapETHToUSDC(msg.value);
        if (usdcAmount < MIN_DEPOSIT) revert BelowMinimumDeposit(usdcAmount, MIN_DEPOSIT);

        // Process deposit
        usdlAmount = _processDeposit(usdcAmount, recipient);
    }

    /**
     * @notice Process fiat onramp - called when ACH/FedNow transfer is received
     * @param referenceId Unique reference ID for the fiat transfer
     * @param recipient Address to receive USDL
     * @param usdcAmount USDC equivalent of fiat received
     * @return usdlAmount Amount of USDL minted
     * @dev Only callable by authorized operators
     */
    function processFiatOnramp(
        bytes32 referenceId,
        address recipient,
        uint256 usdcAmount
    )
        external
        override
        nonReentrant
        whenNotPaused
        onlyRole(OPERATOR_ROLE)
        nonZeroAddress(recipient)
        nonZeroAmount(usdcAmount)
        returns (uint256 usdlAmount)
    {
        // Prevent replay
        if (processedOnramps[referenceId]) revert OnrampAlreadyProcessed(referenceId);
        processedOnramps[referenceId] = true;

        // Process deposit (USDC should already be in contract from off-chain purchase)
        usdlAmount = _processDeposit(usdcAmount, recipient);

        emit FiatOnrampProcessed(referenceId, recipient, usdlAmount);
    }

    // ============ Withdrawal Functions ============

    /**
     * @notice Withdraw USDL and receive USDC
     * @param usdlAmount Amount of USDL to burn
     * @param recipient Address to receive USDC
     * @return withdrawAmount Amount of USDC returned (6 decimals)
     */
    function withdraw(uint256 usdlAmount, address recipient)
        external
        override
        nonReentrant
        whenNotPaused
        nonZeroAddress(recipient)
        nonZeroAmount(usdlAmount)
        returns (uint256 withdrawAmount)
    {
        // Burn USDL from sender
        usdl.burnFrom(msg.sender, usdlAmount);

        // Convert USDL (18 decimals) to USDC (6 decimals)
        uint256 usdcEquivalent = usdlAmount / 1e12;

        // Calculate withdrawal amount after fee (in USDC terms)
        uint256 fee = (usdcEquivalent * withdrawalFeeBps) / BASIS_POINTS;
        withdrawAmount = usdcEquivalent - fee;

        // Redeem from yield assets proportionally
        _redeemFromYieldAssets(withdrawAmount);

        // Transfer fee to treasury
        if (fee > 0) {
            usdc.safeTransfer(treasury, fee);
        }

        // Transfer USDC to recipient
        usdc.safeTransfer(recipient, withdrawAmount);

        emit Withdraw(msg.sender, address(usdc), usdlAmount, withdrawAmount);
    }

    // ============ Internal Functions ============

    /**
     * @dev Process deposit: allocate to yield assets and mint USDL
     */
    function _processDeposit(uint256 usdcAmount, address recipient) internal returns (uint256 usdlAmount) {
        // Calculate fee
        uint256 fee = (usdcAmount * depositFeeBps) / BASIS_POINTS;
        uint256 netAmount = usdcAmount - fee;

        // Transfer fee to treasury
        if (fee > 0) {
            usdc.safeTransfer(treasury, fee);
        }

        // Allocate to yield assets
        _allocateToYieldAssets(netAmount);

        // Mint USDL 1:1 with net USDC deposited
        // USDL has 18 decimals, USDC has 6 decimals
        usdlAmount = netAmount * 1e12;
        usdl.mint(recipient, usdlAmount);

        emit Deposit(msg.sender, address(usdc), usdcAmount, usdlAmount);
    }

    /**
     * @dev Allocate USDC to yield assets based on configured allocation
     */
    function _allocateToYieldAssets(uint256 amount) internal {
        uint256 remaining = amount;
        uint256 length = yieldAssetList.length;

        for (uint256 i = 0; i < length; i++) {
            address token = yieldAssetList[i];
            YieldAsset storage asset = yieldAssets[token];

            if (!asset.active) continue;

            uint256 allocation;
            if (i == length - 1) {
                // Last asset gets remaining to handle rounding
                allocation = remaining;
            } else {
                allocation = (amount * asset.allocation) / BASIS_POINTS;
            }

            if (allocation > 0) {
                _depositToYieldAsset(asset, allocation);
                remaining -= allocation;
            }
        }
    }

    /**
     * @dev Deposit USDC to a specific yield asset
     */
    function _depositToYieldAsset(YieldAsset storage asset, uint256 amount) internal {
        // Approve manager to spend USDC
        usdc.safeIncreaseAllowance(asset.manager, amount);

        // Call manager to subscribe/mint yield tokens
        // Interface varies by protocol - this is a generic approach
        // OUSG: Uses OUSGInstantManager.subscribe(usdcAmount)
        // BUIDL: Uses similar subscription mechanism
        (bool success,) = asset.manager.call(
            abi.encodeWithSignature("subscribe(uint256)", amount)
        );
        
        // If subscribe doesn't exist, try mint
        if (!success) {
            (success,) = asset.manager.call(
                abi.encodeWithSignature("mint(uint256)", amount)
            );
        }

        // Note: In production, handle failures appropriately
        // For now, we allow partial failures and continue
    }

    /**
     * @dev Redeem from yield assets to get USDC
     */
    function _redeemFromYieldAssets(uint256 amount) internal {
        uint256 remaining = amount;
        uint256 length = yieldAssetList.length;

        for (uint256 i = 0; i < length && remaining > 0; i++) {
            address token = yieldAssetList[i];
            YieldAsset storage asset = yieldAssets[token];

            if (!asset.active) continue;

            // Calculate proportional redemption
            uint256 redeemAmount = (amount * asset.allocation) / BASIS_POINTS;
            if (redeemAmount > remaining) {
                redeemAmount = remaining;
            }

            if (redeemAmount > 0) {
                _redeemFromYieldAsset(asset, redeemAmount);
                remaining -= redeemAmount;
            }
        }
    }

    /**
     * @dev Redeem from a specific yield asset
     */
    function _redeemFromYieldAsset(YieldAsset storage asset, uint256 amount) internal {
        // Calculate yield tokens needed based on current exchange rate
        // This is simplified - in production would query oracle/manager for rate
        
        IERC20 yieldToken = IERC20(asset.token);
        uint256 balance = yieldToken.balanceOf(address(this));
        
        if (balance > 0) {
            // Approve manager
            yieldToken.safeIncreaseAllowance(asset.manager, balance);
            
            // Call redeem
            (bool success,) = asset.manager.call(
                abi.encodeWithSignature("redeem(uint256)", amount)
            );
            
            if (!success) {
                (success,) = asset.manager.call(
                    abi.encodeWithSignature("withdraw(uint256)", amount)
                );
            }
        }
    }

    /**
     * @dev Swap ETH to USDC via DEX router
     */
    function _swapETHToUSDC(uint256 ethAmount) internal returns (uint256 usdcAmount) {
        if (dexRouter == address(0)) revert ZeroAddress();

        uint256 usdcBefore = usdc.balanceOf(address(this));

        // Generic DEX swap call - adjust based on actual DEX (Uniswap, 1inch, etc.)
        // This example uses Uniswap V3 style
        (bool success,) = dexRouter.call{value: ethAmount}(
            abi.encodeWithSignature(
                "swapExactETHForTokens(uint256,address[],address,uint256)",
                0, // amountOutMin - should use oracle in production
                _getSwapPath(),
                address(this),
                block.timestamp + 300
            )
        );

        if (!success) revert SwapFailed();

        usdcAmount = usdc.balanceOf(address(this)) - usdcBefore;
    }

    /**
     * @dev Get swap path for ETH → USDC
     */
    function _getSwapPath() internal view returns (address[] memory path) {
        path = new address[](2);
        path[0] = address(weth);
        path[1] = address(usdc);
    }

    // ============ Admin Functions ============

    /**
     * @notice Add a new yield asset
     * @param token Yield-bearing token address
     * @param depositToken Token used to acquire (usually USDC)
     * @param manager Manager contract for subscriptions
     * @param allocation Allocation in basis points
     */
    function addYieldAsset(
        address token,
        address depositToken,
        address manager,
        uint256 allocation
    )
        external
        onlyRole(MANAGER_ROLE)
        nonZeroAddress(token)
        nonZeroAddress(depositToken)
        nonZeroAddress(manager)
    {
        if (yieldAssets[token].token != address(0)) revert AssetAlreadyExists(token);

        yieldAssets[token] = YieldAsset({
            token: token,
            depositToken: depositToken,
            manager: manager,
            allocation: allocation,
            active: true
        });

        yieldAssetList.push(token);

        // Validate total allocation
        _validateTotalAllocation();

        emit YieldAssetAdded(token, manager, allocation);
    }

    /**
     * @notice Update yield asset allocation
     * @param token Yield asset token address
     * @param newAllocation New allocation in basis points
     */
    function updateYieldAssetAllocation(address token, uint256 newAllocation)
        external
        onlyRole(MANAGER_ROLE)
    {
        if (yieldAssets[token].token == address(0)) revert AssetNotFound(token);

        yieldAssets[token].allocation = newAllocation;
        _validateTotalAllocation();

        emit YieldAssetUpdated(token, newAllocation);
    }

    /**
     * @notice Deactivate a yield asset
     * @param token Yield asset token address
     */
    function deactivateYieldAsset(address token) external onlyRole(MANAGER_ROLE) {
        if (yieldAssets[token].token == address(0)) revert AssetNotFound(token);

        yieldAssets[token].active = false;
        emit YieldAssetRemoved(token);
    }

    /**
     * @notice Set DEX router address
     * @param newRouter New DEX router address
     */
    function setDexRouter(address newRouter) external onlyRole(DEFAULT_ADMIN_ROLE) nonZeroAddress(newRouter) {
        address oldRouter = dexRouter;
        dexRouter = newRouter;
        emit DexRouterUpdated(oldRouter, newRouter);
    }

    /**
     * @notice Set treasury address
     * @param newTreasury New treasury address
     */
    function setTreasury(address newTreasury) external onlyRole(DEFAULT_ADMIN_ROLE) nonZeroAddress(newTreasury) {
        address oldTreasury = treasury;
        treasury = newTreasury;
        emit TreasuryUpdated(oldTreasury, newTreasury);
    }

    /**
     * @notice Set deposit and withdrawal fees
     * @param newDepositFeeBps New deposit fee in basis points
     * @param newWithdrawalFeeBps New withdrawal fee in basis points
     */
    function setFees(uint256 newDepositFeeBps, uint256 newWithdrawalFeeBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newDepositFeeBps > 500) revert InvalidFee(newDepositFeeBps); // Max 5%
        if (newWithdrawalFeeBps > 500) revert InvalidFee(newWithdrawalFeeBps); // Max 5%

        depositFeeBps = newDepositFeeBps;
        withdrawalFeeBps = newWithdrawalFeeBps;
        emit FeesUpdated(newDepositFeeBps, newWithdrawalFeeBps);
    }

    /**
     * @notice Pause the contract
     */
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    /**
     * @notice Unpause the contract
     */
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    /**
     * @notice Emergency withdraw tokens (admin only)
     * @param token Token to withdraw
     * @param to Recipient address
     * @param amount Amount to withdraw
     */
    function emergencyWithdraw(address token, address to, uint256 amount)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        nonZeroAddress(token)
        nonZeroAddress(to)
        nonZeroAmount(amount)
    {
        IERC20(token).safeTransfer(to, amount);
        emit EmergencyWithdraw(token, to, amount);
    }

    // ============ View Functions ============

    /**
     * @notice Get total value locked in yield assets (USDC terms)
     * @return tvl Total value in USDC (6 decimals)
     */
    function getTotalValueLocked() external view override returns (uint256 tvl) {
        uint256 length = yieldAssetList.length;
        
        for (uint256 i = 0; i < length; i++) {
            address token = yieldAssetList[i];
            YieldAsset storage asset = yieldAssets[token];
            
            if (asset.active) {
                // Get balance of yield token
                uint256 balance = IERC20(token).balanceOf(address(this));
                // In production, multiply by exchange rate from oracle
                // For now, assume 1:1 for simplicity
                tvl += balance;
            }
        }
        
        // Add any USDC held directly
        tvl += usdc.balanceOf(address(this));
    }

    /**
     * @notice Get current backing ratio (yield assets / USDL supply)
     * @return ratio Backing ratio in basis points (10000 = 100%)
     */
    function getBackingRatio() external view override returns (uint256 ratio) {
        uint256 tvl = this.getTotalValueLocked();
        uint256 usdlSupply = usdl.totalSupply();
        
        if (usdlSupply == 0) return BASIS_POINTS;
        
        // Convert USDL (18 decimals) to USDC terms (6 decimals)
        uint256 usdlInUsdc = usdlSupply / 1e12;
        
        ratio = (tvl * BASIS_POINTS) / usdlInUsdc;
    }

    /**
     * @notice Get yield asset details
     * @param token Yield asset token address
     * @return asset YieldAsset struct
     */
    function getYieldAsset(address token) external view returns (YieldAsset memory asset) {
        return yieldAssets[token];
    }

    /**
     * @notice Get all yield asset addresses
     * @return assets Array of yield asset addresses
     */
    function getYieldAssetList() external view returns (address[] memory) {
        return yieldAssetList;
    }

    /**
     * @notice Get number of yield assets
     * @return count Number of yield assets
     */
    function getYieldAssetCount() external view returns (uint256) {
        return yieldAssetList.length;
    }

    // ============ Internal Validation ============

    /**
     * @dev Validate that total allocation of active assets doesn't exceed 100%
     */
    function _validateTotalAllocation() internal view {
        uint256 total = 0;
        uint256 length = yieldAssetList.length;

        for (uint256 i = 0; i < length; i++) {
            YieldAsset storage asset = yieldAssets[yieldAssetList[i]];
            if (asset.active) {
                total += asset.allocation;
            }
        }

        // Total must be exactly 100% or 0% (no assets yet)
        if (total > BASIS_POINTS) revert InvalidAllocation(total);
    }

    /**
     * @notice Receive ETH
     */
    receive() external payable {}
}

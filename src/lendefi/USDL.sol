// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

/**
 * @title USDL - Yield-Bearing USD Vault
 * @notice ERC-4626 vault that accepts USDC and allocates to yield-bearing RWA assets
 * @dev Users deposit USDC, receive USDL shares. Share price increases as yield accrues.
 *      
 *      Example:
 *      - User deposits 1000 USDC at launch → gets 1000 USDL
 *      - After 1 year of 5% yield → 1000 USDL redeemable for 1050 USDC
 *      
 *      Supported yield assets:
 *      - ERC-4626 vaults (sDAI, Morpho, etc.)
 *      - Aave V3 (aUSDC)
 *      - Ondo OUSG (requires whitelist)
 *
 * @custom:security-contact security@lendefimarkets.com
 */

import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {ERC20PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PausableUpgradeable.sol";
import {ERC20PermitUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IGetCCIPAdmin} from "../interfaces/IGetCCIPAdmin.sol";
import {
    AssetType,
    IERC4626 as IExternalERC4626,
    IAaveV3Pool,
    IOUSGInstantManager,
    IRWAOracle
} from "../interfaces/IYieldProtocols.sol";

/// @custom:oz-upgrades
contract USDL is
    IERC165,
    IGetCCIPAdmin,
    ERC4626Upgradeable,
    ERC20PausableUpgradeable,
    ERC20PermitUpgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;
    using Math for uint256;

    // ============ Yield Asset Configuration ============

    /// @notice Yield asset configuration
    struct YieldAsset {
        address token;          // Yield-bearing token (sDAI, aUSDC, OUSG)
        address depositToken;   // Token to deposit (USDC, DAI)
        address manager;        // Manager contract (vault, pool, instant manager)
        uint256 allocation;     // Target allocation in basis points
        AssetType assetType;    // Protocol type for routing
        bool active;            // Whether asset is accepting new deposits
    }

    // ============ Constants ============

    /// @notice Basis points denominator (100%)
    uint256 public constant BASIS_POINTS = 10_000;

    /// @notice Minimum deposit amount (1 USDC)
    uint256 public constant MIN_DEPOSIT = 1e6;

    /// @notice Maximum deposit fee in basis points (5%)
    uint256 public constant MAX_FEE_BPS = 500;

    /// @dev AccessControl Role Constants
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
    bytes32 public constant BRIDGE_ROLE = keccak256("BRIDGE_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant BLACKLISTER_ROLE = keccak256("BLACKLISTER_ROLE");

    // ============ Storage Variables ============

    /// @notice Deployed version (increments on each upgrade)
    uint256 public version;

    /// @notice CCIP admin address for token admin registry
    address public ccipAdmin;

    /// @notice Blacklisted addresses (for compliance)
    mapping(address account => bool isBlacklisted) public blacklisted;

    /// @notice Treasury address for fees
    address public treasury;

    /// @notice Deposit fee in basis points (e.g., 10 = 0.1%)
    uint256 public depositFeeBps;

    /// @notice Total assets deposited by users (internal accounting)
    /// @dev This tracks actual deposited liquidity, separate from totalSupply() which can be
    ///      inflated by bridge mints. Used for share price calculations to prevent inflation attacks.
    uint256 public totalDepositedAssets;

    /// @notice Array of yield asset addresses
    address[] public yieldAssetList;

    /// @notice Yield asset configurations
    mapping(address token => YieldAsset config) public yieldAssets;

    /// @notice Storage gap for future upgrades
    uint256[40] private __gap;

    // ============ Events ============

    event CCIPAdminTransferred(address indexed previousAdmin, address indexed newAdmin);
    event Blacklisted(address indexed account);
    event UnBlacklisted(address indexed account);
    event Upgrade(address indexed sender, address indexed implementation);
    event YieldAssetAdded(address indexed token, address indexed manager, uint256 allocation);
    event YieldAssetUpdated(address indexed token, uint256 newAllocation);
    event YieldAssetRemoved(address indexed token);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event DepositFeeUpdated(uint256 oldFeeBps, uint256 newFeeBps);
    event EmergencyWithdraw(address indexed token, address indexed to, uint256 amount);
    event InternalAccountingUpdated(uint256 oldAmount, uint256 newAmount);
    event YieldAccrued(uint256 yieldAmount, uint256 newTotalAssets);
    event DonatedTokensRescued(address indexed to, uint256 amount);

    // ============ Errors ============

    error ZeroAddress();
    error ZeroAmount();
    error InvalidRecipient(address recipient);
    error AddressBlacklisted(address account);
    error BelowMinimumDeposit(uint256 amount, uint256 minimum);
    error AssetAlreadyExists(address token);
    error AssetNotFound(address token);
    error InvalidAllocation(uint256 totalBps);
    error InvalidFee(uint256 fee);
    error InsufficientLiquidity(uint256 requested, uint256 available);

    // ============ Modifiers ============

    modifier nonZeroAmount(uint256 amount) {
        if (amount == 0) revert ZeroAmount();
        _;
    }

    modifier nonZeroAddress(address addr) {
        if (addr == address(0)) revert ZeroAddress();
        _;
    }

    modifier notBlacklisted(address account) {
        if (blacklisted[account]) revert AddressBlacklisted(account);
        _;
    }

    // ============ Constructor ============

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // ============ Initializer ============

    /**
     * @notice Initialize the USDL vault
     * @param _owner Owner/admin address
     * @param _usdc USDC token address (underlying asset)
     * @param _treasury Treasury address for fees
     */
    function initialize(
        address _owner,
        address _usdc,
        address _treasury
    ) external initializer {
        if (_owner == address(0)) revert ZeroAddress();
        if (_usdc == address(0)) revert ZeroAddress();
        if (_treasury == address(0)) revert ZeroAddress();

        __ERC4626_init(IERC20(_usdc));
        __ERC20_init("Lendefi USD", "USDL");
        __ERC20Pausable_init();
        __ERC20Permit_init("Lendefi USD");
        __AccessControl_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, _owner);
        _grantRole(PAUSER_ROLE, _owner);
        _grantRole(UPGRADER_ROLE, _owner);
        _grantRole(MANAGER_ROLE, _owner);
        _grantRole(BLACKLISTER_ROLE, _owner);

        version = 1;
        ccipAdmin = _owner;
        treasury = _treasury;

        // Default deposit fee: 0.1%
        depositFeeBps = 10;
    }

    // ============ ERC-4626 Overrides ============

    /**
     * @notice Returns total assets under management (USDC value)
     * @dev Uses internal accounting (totalDepositedAssets) to prevent donation attacks.
     *      External actors cannot manipulate this by sending USDC directly to contract.
     */
    function totalAssets() public view override returns (uint256) {
        return totalDepositedAssets;
    }

    /**
     * @notice Preview deposit - uses internal accounting to prevent inflation attacks
     * @dev Returns shares that would be minted for given assets (before fee)
     */
    function previewDeposit(uint256 assets) public view override returns (uint256) {
        return _convertToSharesInternal(assets, Math.Rounding.Floor);
    }

    /**
     * @notice Preview mint - uses internal accounting to prevent inflation attacks
     * @dev Returns assets needed to mint given shares (before fee)
     */
    function previewMint(uint256 shares) public view override returns (uint256) {
        return _convertToAssetsInternal(shares, Math.Rounding.Ceil);
    }

    /**
     * @notice Preview withdraw - uses internal accounting to prevent inflation attacks
     * @dev Returns shares that would be burned for given assets
     */
    function previewWithdraw(uint256 assets) public view override returns (uint256) {
        return _convertToSharesInternal(assets, Math.Rounding.Ceil);
    }

    /**
     * @notice Preview redeem - uses internal accounting to prevent inflation attacks
     * @dev Returns assets that would be returned for given shares
     */
    function previewRedeem(uint256 shares) public view override returns (uint256) {
        return _convertToAssetsInternal(shares, Math.Rounding.Floor);
    }

    /**
     * @notice Deposit USDC and receive USDL shares
     * @dev Overrides ERC4626 to add fee logic and yield asset allocation
     */
    function deposit(uint256 assets, address receiver)
        public
        override
        nonReentrant
        whenNotPaused
        notBlacklisted(msg.sender)
        notBlacklisted(receiver)
        returns (uint256 shares)
    {
        if (assets < MIN_DEPOSIT) revert BelowMinimumDeposit(assets, MIN_DEPOSIT);
        if (receiver == address(0)) revert ZeroAddress();
        if (receiver == address(this)) revert InvalidRecipient(receiver);

        // Calculate fee
        uint256 fee = (assets * depositFeeBps) / BASIS_POINTS;
        uint256 netAssets = assets - fee;

        // Calculate shares based on net assets using internal accounting
        shares = _convertToSharesInternal(netAssets, Math.Rounding.Floor);
        if (shares == 0) revert ZeroAmount();

        // Transfer assets from sender
        IERC20(asset()).safeTransferFrom(msg.sender, address(this), assets);

        // Transfer fee to treasury
        if (fee > 0) {
            IERC20(asset()).safeTransfer(treasury, fee);
        }

        // Update internal accounting BEFORE allocation
        totalDepositedAssets += netAssets;

        // Allocate net assets to yield positions
        _allocateToYieldAssets(netAssets);

        // Mint shares to receiver
        _mint(receiver, shares);

        emit Deposit(msg.sender, receiver, assets, shares);
    }

    /**
     * @notice Mint exact shares by depositing USDC
     * @dev Overrides ERC4626 to add fee logic
     */
    function mint(uint256 shares, address receiver)
        public
        override
        nonReentrant
        whenNotPaused
        notBlacklisted(msg.sender)
        notBlacklisted(receiver)
        returns (uint256 assets)
    {
        if (shares == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();
        if (receiver == address(this)) revert InvalidRecipient(receiver);

        // Calculate assets needed using internal accounting
        uint256 netAssets = _convertToAssetsInternal(shares, Math.Rounding.Ceil);
        uint256 fee = (netAssets * depositFeeBps) / (BASIS_POINTS - depositFeeBps);
        assets = netAssets + fee;

        if (assets < MIN_DEPOSIT) revert BelowMinimumDeposit(assets, MIN_DEPOSIT);

        // Transfer assets from sender
        IERC20(asset()).safeTransferFrom(msg.sender, address(this), assets);

        // Transfer fee to treasury
        if (fee > 0) {
            IERC20(asset()).safeTransfer(treasury, fee);
        }

        // Update internal accounting BEFORE allocation
        totalDepositedAssets += netAssets;

        // Allocate to yield positions
        _allocateToYieldAssets(netAssets);

        // Mint shares
        _mint(receiver, shares);

        emit Deposit(msg.sender, receiver, assets, shares);
    }

    /**
     * @notice Withdraw USDC by burning shares
     * @dev Overrides ERC4626 to add fee logic and yield asset redemption
     */
    function withdraw(uint256 assets, address receiver, address owner)
        public
        override
        nonReentrant
        whenNotPaused
        notBlacklisted(msg.sender)
        notBlacklisted(receiver)
        notBlacklisted(owner)
        returns (uint256 shares)
    {
        if (assets == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();
        if (assets > totalDepositedAssets) revert InsufficientLiquidity(assets, totalDepositedAssets);

        // Calculate shares to burn using internal accounting
        shares = _convertToSharesInternal(assets, Math.Rounding.Ceil);

        // Check allowance if not owner
        if (msg.sender != owner) {
            _spendAllowance(owner, msg.sender, shares);
        }

        // Update internal accounting BEFORE redemption
        totalDepositedAssets -= assets;

        // Redeem from yield assets
        _redeemFromYieldAssets(assets);

        // Burn shares
        _burn(owner, shares);

        // Transfer assets to receiver
        IERC20(asset()).safeTransfer(receiver, assets);

        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }

    /**
     * @notice Redeem shares for USDC
     * @dev Overrides ERC4626 to add fee logic
     */
    function redeem(uint256 shares, address receiver, address owner)
        public
        override
        nonReentrant
        whenNotPaused
        notBlacklisted(msg.sender)
        notBlacklisted(receiver)
        notBlacklisted(owner)
        returns (uint256 assets)
    {
        if (shares == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();

        // Check allowance if not owner
        if (msg.sender != owner) {
            _spendAllowance(owner, msg.sender, shares);
        }

        // Calculate assets to return using internal accounting
        assets = _convertToAssetsInternal(shares, Math.Rounding.Floor);
        if (assets > totalDepositedAssets) revert InsufficientLiquidity(assets, totalDepositedAssets);

        // Update internal accounting BEFORE redemption
        totalDepositedAssets -= assets;

        // Redeem from yield assets
        _redeemFromYieldAssets(assets);

        // Burn shares
        _burn(owner, shares);

        // Transfer assets to receiver
        IERC20(asset()).safeTransfer(receiver, assets);

        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }

    // ============ CCIP Bridge Functions ============

    /**
     * @notice Mint shares for CCIP bridge (burn-and-mint pattern)
     * @param account Address to receive shares
     * @param amount Amount of shares to mint
     * @dev Only callable by BRIDGE_ROLE (CCIP Token Pool)
     */
    function bridgeMint(address account, uint256 amount)
        external
        whenNotPaused
        onlyRole(BRIDGE_ROLE)
        notBlacklisted(account)
    {
        if (account == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (account == address(this)) revert InvalidRecipient(account);

        _mint(account, amount);
    }

    /**
     * @notice Burn shares for CCIP bridge (burn-and-mint pattern)
     * @param account Address to burn from
     * @param amount Amount of shares to burn
     * @dev Only callable by BRIDGE_ROLE (CCIP Token Pool)
     */
    function bridgeBurn(address account, uint256 amount)
        external
        whenNotPaused
        onlyRole(BRIDGE_ROLE)
    {
        if (account == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        _burn(account, amount);
    }

    // ============ Yield Asset Management ============

    /**
     * @notice Add a new yield asset
     * @param token Yield-bearing token address
     * @param depositToken Token used to acquire (USDC, DAI)
     * @param manager Manager contract address
     * @param allocation Allocation in basis points
     * @param assetType Protocol type for routing
     */
    function addYieldAsset(
        address token,
        address depositToken,
        address manager,
        uint256 allocation,
        AssetType assetType
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
            assetType: assetType,
            active: true
        });

        yieldAssetList.push(token);
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
     * @notice Completely remove a yield asset from the list
     * @dev M-02 Fix: Allows full cleanup of yield assets to prevent gas DoS
     *      Must ensure no funds remain in the asset before removal
     * @param token Yield asset token address to remove
     */
    function removeYieldAsset(address token) external onlyRole(MANAGER_ROLE) {
        if (yieldAssets[token].token == address(0)) revert AssetNotFound(token);
        
        // Ensure no funds remain in this yield asset
        uint256 balance = IERC20(token).balanceOf(address(this));
        require(balance == 0, "Withdraw funds first");

        // Find and remove from array (swap-and-pop)
        uint256 length = yieldAssetList.length;
        for (uint256 i = 0; i < length; i++) {
            if (yieldAssetList[i] == token) {
                yieldAssetList[i] = yieldAssetList[length - 1];
                yieldAssetList.pop();
                break;
            }
        }

        delete yieldAssets[token];
        emit YieldAssetRemoved(token);
    }

    // ============ Admin Functions ============

    /**
     * @notice Grant bridge role (for CCIP Token Pool)
     */
    function grantBridgeRole(address bridge) external nonZeroAddress(bridge) onlyRole(DEFAULT_ADMIN_ROLE) {
        _grantRole(BRIDGE_ROLE, bridge);
    }

    /**
     * @notice Revoke bridge role
     */
    function revokeBridgeRole(address bridge) external nonZeroAddress(bridge) onlyRole(DEFAULT_ADMIN_ROLE) {
        _revokeRole(BRIDGE_ROLE, bridge);
    }

    /**
     * @notice Set CCIP admin address
     */
    function setCCIPAdmin(address newAdmin) external nonZeroAddress(newAdmin) onlyRole(DEFAULT_ADMIN_ROLE) {
        address oldAdmin = ccipAdmin;
        ccipAdmin = newAdmin;
        emit CCIPAdminTransferred(oldAdmin, newAdmin);
    }

    /**
     * @notice Set treasury address
     */
    function setTreasury(address newTreasury) external nonZeroAddress(newTreasury) onlyRole(DEFAULT_ADMIN_ROLE) {
        address oldTreasury = treasury;
        treasury = newTreasury;
        emit TreasuryUpdated(oldTreasury, newTreasury);
    }

    /**
     * @notice Set deposit fee
     * @param newFeeBps New deposit fee in basis points (max MAX_FEE_BPS = 5%)
     */
    function setDepositFee(uint256 newFeeBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newFeeBps > MAX_FEE_BPS) revert InvalidFee(newFeeBps);

        uint256 oldFeeBps = depositFeeBps;
        depositFeeBps = newFeeBps;
        emit DepositFeeUpdated(oldFeeBps, newFeeBps);
    }

    /**
     * @notice Blacklist an address
     */
    function blacklist(address account) external nonZeroAddress(account) onlyRole(BLACKLISTER_ROLE) {
        blacklisted[account] = true;
        emit Blacklisted(account);
    }

    /**
     * @notice Remove address from blacklist
     */
    function unblacklist(address account) external nonZeroAddress(account) onlyRole(BLACKLISTER_ROLE) {
        blacklisted[account] = false;
        emit UnBlacklisted(account);
    }

    /**
     * @notice Pause the contract
     */
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /**
     * @notice Unpause the contract
     */
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    /**
     * @notice Emergency withdraw tokens
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

    /**
     * @notice Accrue yield from underlying yield assets into internal accounting
     * @dev This function calculates the actual value of yield positions and updates
     *      totalDepositedAssets to reflect accrued yield. Should be called periodically.
     *      Only increases totalDepositedAssets (yield accrual), never decreases.
     */
    function accrueYield() external onlyRole(MANAGER_ROLE) {
        uint256 actualValue = _calculateActualYieldValue();
        uint256 currentDeposited = totalDepositedAssets;
        
        // Only accrue if there's positive yield (actual value > tracked deposits)
        if (actualValue > currentDeposited) {
            uint256 yieldAccrued = actualValue - currentDeposited;
            totalDepositedAssets = actualValue;
            emit YieldAccrued(yieldAccrued, actualValue);
        }
    }

    /**
     * @notice Rescue any tokens accidentally sent to the contract
     * @dev Allows recovery of donations/dust. Cannot withdraw more than excess above tracked assets.
     * @param to Address to send rescued tokens
     */
    function rescueDonatedTokens(address to) external onlyRole(DEFAULT_ADMIN_ROLE) nonZeroAddress(to) {
        IERC20 usdc = IERC20(asset());
        uint256 balance = usdc.balanceOf(address(this));
        uint256 tracked = totalDepositedAssets;
        
        // Can only rescue excess tokens (donations)
        if (balance > tracked) {
            uint256 excess = balance - tracked;
            usdc.safeTransfer(to, excess);
            emit DonatedTokensRescued(to, excess);
        }
    }

    // ============ View Functions ============

    /// @inheritdoc IGetCCIPAdmin
    function getCCIPAdmin() external view override returns (address) {
        return ccipAdmin;
    }

    /**
     * @notice Get yield asset details
     */
    function getYieldAsset(address token) external view returns (YieldAsset memory) {
        return yieldAssets[token];
    }

    /**
     * @notice Get all yield asset addresses
     */
    function getYieldAssetList() external view returns (address[] memory) {
        return yieldAssetList;
    }

    /**
     * @notice Get number of yield assets
     */
    function getYieldAssetCount() external view returns (uint256) {
        return yieldAssetList.length;
    }

    /**
     * @notice Get current share price (assets per share)
     * @return price Share price scaled by 1e6 (USDC decimals)
     */
    function sharePrice() external view returns (uint256 price) {
        uint256 supply = totalSupply();
        if (supply == 0) return 1e6; // 1:1 initially
        
        price = (totalAssets() * 1e6) / supply;
    }

    /**
     * @notice Get the price of 1 USDL share in USDC
     * @dev Uses previewRedeem to calculate how much USDC 1 full share would return
     * @return price Price of 1 USDL in USDC (6 decimals)
     */
    function getPrice() external view returns (uint256 price) {
        // 1 full share = 1e6 (6 decimals)
        price = previewRedeem(1e6);
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId)
        public
        pure
        override(AccessControlUpgradeable, IERC165)
        returns (bool)
    {
        return 
            interfaceId == type(IERC20).interfaceId ||
            interfaceId == type(IERC4626).interfaceId ||
            interfaceId == type(IERC165).interfaceId ||
            interfaceId == type(IAccessControl).interfaceId ||
            interfaceId == type(IGetCCIPAdmin).interfaceId;
    }

    // ============ Internal Functions ============

    /**
     * @dev Convert assets to shares using internal accounting (totalDepositedAssets)
     *      This prevents bridge mint inflation attacks by using actual deposited
     *      liquidity rather than totalSupply() which can be inflated.
     * @param assets Amount of assets to convert
     * @param rounding Rounding direction (Floor for deposits, Ceil for withdrawals)
     * @return shares Number of shares
     */
    function _convertToSharesInternal(uint256 assets, Math.Rounding rounding) internal view returns (uint256 shares) {
        uint256 supply = totalSupply();
        uint256 depositedAssets = totalDepositedAssets;
        
        // If no shares exist, 1:1 ratio
        if (supply == 0 || depositedAssets == 0) {
            return assets;
        }
        
        // shares = assets * totalSupply / totalDepositedAssets
        return assets.mulDiv(supply, depositedAssets, rounding);
    }

    /**
     * @dev Convert shares to assets using internal accounting (totalDepositedAssets)
     *      This prevents bridge mint inflation attacks by using actual deposited
     *      liquidity rather than totalSupply() which can be inflated.
     * @param shares Number of shares to convert
     * @param rounding Rounding direction (Ceil for mints, Floor for redeems)
     * @return assets Amount of assets
     */
    function _convertToAssetsInternal(uint256 shares, Math.Rounding rounding) internal view returns (uint256 assets) {
        uint256 supply = totalSupply();
        uint256 depositedAssets = totalDepositedAssets;
        
        // If no shares exist, 1:1 ratio
        if (supply == 0 || depositedAssets == 0) {
            return shares;
        }
        
        // assets = shares * totalDepositedAssets / totalSupply
        return shares.mulDiv(depositedAssets, supply, rounding);
    }

    /**
     * @dev Calculate the actual value of all yield positions in USDC terms
     *      Used for yield accrual to update internal accounting
     * @return total Total value of all yield assets plus any USDC held
     */
    function _calculateActualYieldValue() internal view returns (uint256 total) {
        // Add value of all yield assets
        uint256 length = yieldAssetList.length;
        for (uint256 i = 0; i < length; i++) {
            address token = yieldAssetList[i];
            YieldAsset storage yieldAsset = yieldAssets[token];
            
            if (!yieldAsset.active) continue;
            
            total += _getYieldAssetValue(yieldAsset);
        }
        
        // Add USDC held directly (only the tracked portion, not donations)
        // We use min(balance, totalDepositedAssets) to avoid counting donations
        uint256 usdcBalance = IERC20(asset()).balanceOf(address(this));
        uint256 usdcTracked = totalDepositedAssets > total ? totalDepositedAssets - total : 0;
        total += usdcBalance < usdcTracked ? usdcBalance : usdcTracked;
    }

    /**
     * @notice Calculates the USDC-equivalent value of a yield asset position
     * @dev Routes valuation logic based on asset type:
     *      - ERC4626: Uses vault's convertToAssets() for share-to-asset conversion
     *      - AAVE_V3: Returns balance directly (aTokens rebase 1:1 with underlying)
     *      - ONDO_OUSG: Fetches price from RWA Oracle (Chainlink-compatible, 8 decimals)
     *
     *      For OUSG valuation formula:
     *      value = (balance * oraclePrice) / 1e20
     *      where balance is 18 decimals, price is 8 decimals, result is 6 decimals (USDC)
     *
     * @param yieldAsset Storage pointer to the yield asset configuration struct
     * @return value The USDC-equivalent value of the vault's holdings in this asset (6 decimals)
     *
     * @custom:requirements
     *   - For OUSG: yieldAsset.manager must be the RWA Oracle address
     *   - Oracle price must be positive (reverts otherwise)
     *
     * @custom:gas-optimization Uses storage pointer to avoid copying struct
     */
    function _getYieldAssetValue(YieldAsset storage yieldAsset) internal view returns (uint256 value) {
        IERC20 yieldToken = IERC20(yieldAsset.token);
        uint256 balance = yieldToken.balanceOf(address(this));
        
        if (balance == 0) return 0;

        if (yieldAsset.assetType == AssetType.ERC4626) {
            // ERC-4626: convertToAssets gives underlying value
            value = IExternalERC4626(yieldAsset.manager).convertToAssets(balance);
        } 
        else if (yieldAsset.assetType == AssetType.AAVE_V3) {
            // Aave aTokens are 1:1 with underlying (they rebase)
            value = balance;
        } 
        else if (yieldAsset.assetType == AssetType.ONDO_OUSG) {
            // OUSG - use RWA oracle for price (Chainlink-compatible, 8 decimals)
            // yieldAsset.manager stores the oracle address for OUSG
            IRWAOracle oracle = IRWAOracle(yieldAsset.manager);
            (, int256 price,,,) = oracle.latestRoundData();
            require(price > 0, "Invalid oracle price");
            // OUSG has 18 decimals, oracle price has 8 decimals (Chainlink standard)
            // Example: OUSG balance = 100e18, price = 113.47e8 (=$113.47)
            // value = 100e18 * 113.47e8 / 1e8 / 1e12 = 11347e6 USDC
            // Formula: balance * price / 1e8 / 1e12 = balance * price / 1e20
            value = (balance * uint256(price)) / 1e20;
        }
    }

    /**
     * @notice Distributes USDC across yield-generating protocols based on configured allocations
     * @dev Iterates through active yield assets and deposits proportionally based on their
     *      allocation percentages (in basis points). The last active asset receives any
     *      remaining dust to handle integer division rounding.
     *
     *      Allocation strategy:
     *      1. Find the last active yield asset in the array
     *      2. For each active asset (except last): allocate = amount × allocation / BASIS_POINTS
     *      3. For last active asset: allocate = remaining (handles rounding dust)
     *
     * @param amount Total USDC amount to allocate across yield assets (6 decimals)
     *
     * @custom:requirements
     *   - Total active allocations should sum to <= BASIS_POINTS (10000)
     *   - USDC must be held in this contract before calling
     *
     * @custom:state-changes
     *   - Transfers USDC from this contract to yield protocols
     *   - Receives yield tokens in return
     *
     * @custom:edge-cases
     *   - If no yield assets configured: USDC remains in vault (no-op)
     *   - If no active yield assets: USDC remains in vault (no-op)
     *   - If allocation is 0 for an asset: skipped
     */
    function _allocateToYieldAssets(uint256 amount) internal {
        uint256 remaining = amount;
        uint256 length = yieldAssetList.length;

        // If no yield assets configured, keep USDC in vault
        if (length == 0) return;

        // M-03 Fix: Find last active asset index to give it the remaining amount
        uint256 lastActiveIndex = type(uint256).max;
        for (uint256 i = length; i > 0; i--) {
            if (yieldAssets[yieldAssetList[i - 1]].active) {
                lastActiveIndex = i - 1;
                break;
            }
        }

        // No active assets, keep USDC in vault
        if (lastActiveIndex == type(uint256).max) return;

        for (uint256 i = 0; i < length; i++) {
            address token = yieldAssetList[i];
            YieldAsset storage yieldAsset = yieldAssets[token];

            if (!yieldAsset.active) continue;

            uint256 allocation;
            if (i == lastActiveIndex) {
                // Last active asset gets remaining to handle rounding
                allocation = remaining;
            } else {
                allocation = (amount * yieldAsset.allocation) / BASIS_POINTS;
            }

            if (allocation > 0) {
                _depositToYieldAsset(yieldAsset, allocation);
                remaining -= allocation;
            }
        }
    }

    /**
     * @notice Deposits USDC into a specific yield-generating protocol
     * @dev Routes deposit based on asset type:
     *      - ERC4626: Calls deposit(amount, address(this))
     *      - AAVE_V3: Calls supply(depositToken, amount, address(this), 0)
     *      - ONDO_OUSG: Calls mint(amount) on InstantManager
     *
     * @param yieldAsset Storage pointer to the yield asset configuration
     * @param amount Amount of USDC to deposit (6 decimals)
     *
     * @custom:requirements
     *   - USDC balance must be >= amount
     *   - yieldAsset.manager must be the correct protocol address:
     *     - ERC4626: The vault address
     *     - AAVE_V3: The Aave V3 Pool address
     *     - ONDO_OUSG: The OUSG InstantManager address
     *
     * @custom:state-changes
     *   - Approves manager to spend depositToken
     *   - Transfers USDC out, receives yield tokens back
     *
     * @custom:security Uses safeIncreaseAllowance to prevent approval race conditions
     */
    function _depositToYieldAsset(YieldAsset storage yieldAsset, uint256 amount) internal {
        IERC20(yieldAsset.depositToken).safeIncreaseAllowance(yieldAsset.manager, amount);

        if (yieldAsset.assetType == AssetType.ERC4626) {
            IExternalERC4626(yieldAsset.manager).deposit(amount, address(this));
        } 
        else if (yieldAsset.assetType == AssetType.AAVE_V3) {
            IAaveV3Pool(yieldAsset.manager).supply(
                yieldAsset.depositToken,
                amount,
                address(this),
                0
            );
        } 
        else if (yieldAsset.assetType == AssetType.ONDO_OUSG) {
            IOUSGInstantManager(yieldAsset.manager).mint(amount);
        }
    }

    /**
     * @notice Retrieves USDC from yield protocols to fulfill withdrawal requests
     * @dev Implements a waterfall redemption strategy:
     *      1. First checks if sufficient USDC is already held in contract
     *      2. If not, iterates through yield assets and redeems proportionally
     *      3. Tracks actual USDC received (not requested) to handle slippage/liquidity issues
     *      4. Final verification ensures requested amount was obtained
     *
     *      This function protects against yield protocols that may not honor full redemptions
     *      due to liquidity constraints (e.g., Aave at 100% utilization, OUSG redemption delays).
     *
     * @param amount Total USDC amount required for the withdrawal (6 decimals)
     *
     * @custom:requirements
     *   - Combined liquidity across vault + yield assets must be >= amount
     *
     * @custom:state-changes
     *   - Burns/redeems yield tokens from protocols
     *   - Receives USDC from yield protocols
     *
     * @custom:error-cases
     *   - InsufficientLiquidity: When final USDC balance < requested amount
     *
     * @custom:security
     *   - H-01 Fix: Tracks actual balance changes, not assumed amounts
     *   - Prevents silent failures from illiquid yield protocols
     */
    function _redeemFromYieldAssets(uint256 amount) internal {
        IERC20 usdc = IERC20(asset());
        uint256 length = yieldAssetList.length;

        // First, check if we have enough USDC held directly
        uint256 usdcBalanceBefore = usdc.balanceOf(address(this));
        if (usdcBalanceBefore >= amount) return; // Have enough USDC
        
        uint256 remaining = amount - usdcBalanceBefore;

        for (uint256 i = 0; i < length && remaining > 0; i++) {
            address token = yieldAssetList[i];
            YieldAsset storage yieldAsset = yieldAssets[token];

            if (!yieldAsset.active) continue;

            uint256 redeemAmount = (amount * yieldAsset.allocation) / BASIS_POINTS;
            if (redeemAmount > remaining) {
                redeemAmount = remaining;
            }

            if (redeemAmount > 0) {
                // H-01 Fix: Track actual USDC received, not requested amount
                uint256 balanceBeforeRedeem = usdc.balanceOf(address(this));
                _redeemFromYieldAsset(yieldAsset, redeemAmount);
                uint256 actualRedeemed = usdc.balanceOf(address(this)) - balanceBeforeRedeem;
                remaining -= actualRedeemed;
            }
        }

        // H-01 Fix: Final verification that we have enough USDC
        uint256 finalBalance = usdc.balanceOf(address(this));
        if (finalBalance < amount) {
            revert InsufficientLiquidity(amount, finalBalance);
        }
    }

    /**
     * @notice Redeems USDC from a specific yield protocol
     * @dev Routes redemption based on asset type:
     *      - ERC4626: Converts amount to shares, redeems up to available balance
     *      - AAVE_V3: Withdraws min(amount, balance) from Aave Pool
     *      - ONDO_OUSG: Redeems entire balance (OUSG has minimum redemption requirements)
     *
     * @param yieldAsset Storage pointer to the yield asset configuration
     * @param amount Target amount of USDC to redeem (6 decimals)
     *
     * @custom:requirements
     *   - yieldAsset.manager must be the correct protocol address
     *   - For Aave: requires approval for aToken transfer
     *   - For OUSG: requires approval for OUSG token transfer
     *
     * @custom:state-changes
     *   - Burns/transfers yield tokens to protocols
     *   - Receives USDC from yield protocols
     *
     * @custom:edge-cases
     *   - If balance is 0: returns immediately (no-op)
     *   - OUSG redeems entire balance regardless of amount parameter
     *     due to protocol minimum redemption requirements
     *
     * @custom:security Uses safeIncreaseAllowance for Aave/OUSG token approvals
     */
    function _redeemFromYieldAsset(YieldAsset storage yieldAsset, uint256 amount) internal {
        IERC20 yieldToken = IERC20(yieldAsset.token);
        uint256 balance = yieldToken.balanceOf(address(this));
        
        if (balance == 0) return;

        if (yieldAsset.assetType == AssetType.ERC4626) {
            uint256 sharesToRedeem = IExternalERC4626(yieldAsset.manager).convertToShares(amount);
            if (sharesToRedeem > balance) sharesToRedeem = balance;
            IExternalERC4626(yieldAsset.manager).redeem(sharesToRedeem, address(this), address(this));
        } 
        else if (yieldAsset.assetType == AssetType.AAVE_V3) {
            uint256 withdrawAmount = amount > balance ? balance : amount;
            yieldToken.safeIncreaseAllowance(yieldAsset.manager, withdrawAmount);
            IAaveV3Pool(yieldAsset.manager).withdraw(
                yieldAsset.depositToken,
                withdrawAmount,
                address(this)
            );
        } 
        else if (yieldAsset.assetType == AssetType.ONDO_OUSG) {
            yieldToken.safeIncreaseAllowance(yieldAsset.manager, balance);
            IOUSGInstantManager(yieldAsset.manager).redeem(balance);
        }
    }

    /**
     * @notice Validates that total allocation percentages don't exceed 100%
     * @dev Iterates through all active yield assets and sums their allocation values.
     *      Called after addYieldAsset() and updateYieldAssetAllocation() to maintain
     *      system invariants.
     *
     *      Allocation values are in basis points (1 = 0.01%, 10000 = 100%).
     *      Only active assets are counted; deactivated assets are ignored.
     *
     * @custom:requirements
     *   - Sum of active allocations must be <= BASIS_POINTS (10000)
     *
     * @custom:error-cases
     *   - InvalidAllocation(total): When total > BASIS_POINTS
     *
     * @custom:invariant sum(yieldAssets[i].allocation for active i) <= 10000
     */
    function _validateTotalAllocation() internal view {
        uint256 total = 0;
        uint256 length = yieldAssetList.length;

        for (uint256 i = 0; i < length; i++) {
            YieldAsset storage yieldAsset = yieldAssets[yieldAssetList[i]];
            if (yieldAsset.active) {
                total += yieldAsset.allocation;
            }
        }

        if (total > BASIS_POINTS) revert InvalidAllocation(total);
    }

    /// @inheritdoc ERC20Upgradeable
    function _update(address from, address to, uint256 value)
        internal
        override(ERC20Upgradeable, ERC20PausableUpgradeable)
    {
        if (from != address(0) && blacklisted[from]) revert AddressBlacklisted(from);
        if (to != address(0) && blacklisted[to]) revert AddressBlacklisted(to);
        
        super._update(from, to, value);
    }

    /**
     * @notice Authorizes contract upgrades through the UUPS proxy pattern
     * @dev Internal function called by the UUPS upgrade mechanism to verify
     *      that the caller has permission to upgrade the contract implementation.
     *      Increments version number for tracking and emits Upgrade event.
     *
     * @param newImplementation Address of the new implementation contract
     *
     * @custom:access-control Restricted to UPGRADER_ROLE
     * @custom:state-changes Increments version number with each upgrade
     * @custom:error-cases ZeroAddress when newImplementation is address(0)
     * @custom:emits Upgrade(msg.sender, newImplementation)
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {
        if (newImplementation == address(0)) revert ZeroAddress();
        version++;
        emit Upgrade(msg.sender, newImplementation);
    }

    /**
     * @notice Returns the number of decimals for the vault token
     * @dev Overrides ERC4626 and ERC20 to match USDC's 6 decimals.
     *      This ensures 1:1 share-to-asset ratio at initialization and
     *      maintains consistency with the underlying USDC asset.
     * @return uint8 Always returns 6 (USDC decimals)
     */
    function decimals() public pure override(ERC4626Upgradeable, ERC20Upgradeable) returns (uint8) {
        return 6;
    }
}

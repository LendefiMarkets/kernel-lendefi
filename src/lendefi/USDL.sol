// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {
    ERC20PausableUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PausableUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IGetCCIPAdmin} from "../interfaces/IGetCCIPAdmin.sol";
import {IBurnMintERC20} from "../interfaces/IBurnMintERC20.sol";
import {AssetType, IOUSGInstantManager, IRWAOracle} from "../interfaces/IYieldProtocols.sol";
import {AutomationCompatibleInterface} from "../interfaces/AutomationCompatibleInterface.sol";

/**
 * @title USDL - Yield-Bearing USD Vault
 * @author Lendefi Markets
 * @notice ERC-4626 vault that accepts USDC deposits and allocates to yield-bearing RWA assets
 * @dev Users deposit USDC, receive USDL shares. Share price increases as yield accrues from underlying protocols.
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
 *      Key mechanisms:
 *      - Internal Accounting: totalDepositedAssets tracks user deposits to prevent inflation
 *        attacks from bridge mints
 *      - Rebase Index: Increases with yield accrual, distributing gains proportionally while
 *        maintaining 1:1 USDC peg
 *      - Bridge Compatibility: CCIP burn-and-mint operations bypass internal accounting to
 *        avoid double-counting
 *
 *      Security features:
 *      - Blacklist for regulatory compliance
 *      - Emergency pause functionality
 *      - Role-based access control (DEFAULT_ADMIN, PAUSER, MANAGER, etc.)
 *      - Reentrancy protection on state-changing functions
 *      - UUPS upgradeable proxy pattern
 *
 *      Yield management:
 *      - Automated yield accrual via Chainlink Automation
 *      - Configurable allocation across multiple protocols
 *      - Waterfall redemption strategy for withdrawals
 *
 * @custom:security-contact security@lendefimarkets.com
 */
/// @custom:oz-upgrades
contract USDL is
    IERC165,
    IGetCCIPAdmin,
    IBurnMintERC20,
    IERC4626,
    ERC20Upgradeable,
    ERC20PausableUpgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable,
    AutomationCompatibleInterface
{
    using SafeERC20 for IERC20;
    using Math for uint256;

    // ============ Yield Asset Configuration ============

    /// @notice Yield asset configuration
    struct YieldAsset {
        address token; // Yield-bearing token (sDAI, aUSDC, OUSG)
        address manager; // Manager contract (vault, pool, instant manager)
        address depositToken; // Token to deposit (USDC, DAI)
        bool active; // Whether asset is accepting new deposits
        AssetType assetType; // Protocol type for routing
        uint256 allocation; // Target allocation in basis points
    }

    // ============ Constants ============

    /// @notice Basis points divisor (10000 = 100%)
    uint256 public constant BASIS_POINTS = 10_000;
    /// @notice Minimum deposit amount in USDC (1 USDC with 6 decimals)
    uint256 public constant MIN_DEPOSIT = 1e6;
    /// @notice Maximum deposit fee in basis points (5%)
    uint256 public constant MAX_FEE_BPS = 500;

    /// @notice Precision for rebase index (1e6 for 6 decimal token)
    uint256 public constant REBASE_INDEX_PRECISION = 1e6;

    /// @notice Minimum interval allowed for automated yield accrual (1 hour)
    uint256 public constant MIN_AUTOMATION_INTERVAL = 1 hours;

    /// @dev AccessControl Role Constants
    /// @notice Role for pausing contract operations
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    /// @notice Role for managing yield assets
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
    /// @notice Role for CCIP bridge token pool
    bytes32 public constant BRIDGE_ROLE = keccak256("BRIDGE_ROLE");
    /// @notice Role for authorizing contract upgrades
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    /// @notice Role for blacklisting addresses
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

    /// @notice Underlying asset address (USDC)
    address public assetAddress;

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

    /// @notice Minimum interval (seconds) between automated yield accruals (0 disables automation)
    uint256 public yieldAccrualInterval;

    /// @notice Timestamp of last yield accrual (manual or automated)
    uint256 public lastYieldAccrualTimestamp;

    /// @notice Rebase index for yield distribution (starts at 1e6, increases with yield)
    /// @dev balanceOf(user) = shares[user] * rebaseIndex / REBASE_INDEX_PRECISION
    ///      This maintains 1:1 USDC peg while distributing yield to all holders
    uint256 public rebaseIndex;

    /// @notice Storage gap for future upgrades
    uint256[37] private __gap;

    // ============ Events ============

    /// @notice Emitted when CCIP admin is transferred
    /// @param previousAdmin Previous CCIP admin address
    /// @param newAdmin New CCIP admin address
    event CCIPAdminTransferred(address indexed previousAdmin, address indexed newAdmin);
    /// @notice Emitted when an address is blacklisted
    /// @param account Blacklisted address
    event Blacklisted(address indexed account);
    /// @notice Emitted when an address is removed from blacklist
    /// @param account Address removed from blacklist
    event UnBlacklisted(address indexed account);
    /// @notice Emitted when contract is upgraded
    /// @param sender Address initiating the upgrade
    /// @param implementation New implementation address
    event Upgrade(address indexed sender, address indexed implementation);
    /// @notice Emitted when a yield asset is added
    /// @param token Yield asset token address
    /// @param manager Manager contract address
    /// @param allocation Allocation in basis points (indexed for gas optimization)
    event YieldAssetAdded(address indexed token, address indexed manager, uint256 indexed allocation);
    /// @notice Emitted when yield asset allocation is updated
    /// @param token Yield asset token address
    /// @param newAllocation New allocation in basis points (indexed for gas optimization)
    event YieldAssetUpdated(address indexed token, uint256 indexed newAllocation);
    /// @notice Emitted when a yield asset is removed
    /// @param token Yield asset token address
    event YieldAssetRemoved(address indexed token);
    /// @notice Emitted when treasury address is updated
    /// @param oldTreasury Previous treasury address (indexed for gas optimization)
    /// @param newTreasury New treasury address (indexed for gas optimization)
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    /// @notice Emitted when deposit fee is updated
    /// @param oldFeeBps Previous fee in basis points (indexed for gas optimization)
    /// @param newFeeBps New fee in basis points (indexed for gas optimization)
    event DepositFeeUpdated(uint256 indexed oldFeeBps, uint256 indexed newFeeBps);
    /// @notice Emitted when tokens are emergency withdrawn
    /// @param token Token address (indexed for gas optimization)
    /// @param to Recipient address (indexed for gas optimization)
    /// @param amount Amount withdrawn (indexed for gas optimization)
    event EmergencyWithdraw(address indexed token, address indexed to, uint256 indexed amount);
    /// @notice Emitted when internal accounting is updated
    /// @param oldAmount Previous tracked amount (indexed for gas optimization)
    /// @param newAmount New tracked amount (indexed for gas optimization)
    event InternalAccountingUpdated(uint256 indexed oldAmount, uint256 indexed newAmount);
    /// @notice Emitted when yield is accrued
    /// @param yieldAmount Amount of yield accrued (indexed for gas optimization)
    /// @param newTotalAssets New total assets after accrual (indexed for gas optimization)
    event YieldAccrued(uint256 indexed yieldAmount, uint256 indexed newTotalAssets);
    /// @notice Emitted when donated tokens are rescued
    /// @param to Recipient address (indexed for gas optimization)
    /// @param amount Amount rescued (indexed for gas optimization)
    event DonatedTokensRescued(address indexed to, uint256 indexed amount);
    /// @notice Emitted when yield accrual interval is updated
    /// @param oldInterval Previous interval in seconds (indexed for gas optimization)
    /// @param newInterval New interval in seconds (indexed for gas optimization)
    event YieldAccrualIntervalUpdated(uint256 indexed oldInterval, uint256 indexed newInterval);
    /// @notice Emitted when rebase index is updated
    /// @param oldIndex Previous rebase index (indexed for gas optimization)
    /// @param newIndex New rebase index (indexed for gas optimization)
    event RebaseIndexUpdated(uint256 indexed oldIndex, uint256 indexed newIndex);
    /// @notice Emitted when the bridge mints shares on this chain
    /// @param caller BRIDGE_ROLE contract performing the mint
    /// @param account Recipient receiving freshly minted shares
    /// @param amount Number of shares minted
    event BridgeMint(address indexed caller, address indexed account, uint256 indexed amount);
    /// @notice Emitted when the bridge burns shares as part of CCIP flows
    /// @param caller BRIDGE_ROLE contract initiating the burn
    /// @param account Address whose shares were burned
    /// @param amount Number of shares burned
    event BridgeBurn(address indexed caller, address indexed account, uint256 indexed amount);

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
    error AutomationIntervalTooShort(uint256 providedInterval);
    error UpkeepNotNeeded();
    error FundsRemaining(uint256 balance);
    error InvalidOraclePrice();

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

    /// @notice Disables initializers for upgradeable contract
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
    function initialize(address _owner, address _usdc, address _treasury) external initializer {
        if (_owner == address(0)) revert ZeroAddress();
        if (_usdc == address(0)) revert ZeroAddress();
        if (_treasury == address(0)) revert ZeroAddress();

        __ERC20_init("Lendefi USD", "USDL");
        __ERC20Pausable_init();
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
        assetAddress = _usdc;

        // Default deposit fee: 0.1%
        depositFeeBps = 10;

        // Default automation settings: daily accruals
        yieldAccrualInterval = 1 days;
        lastYieldAccrualTimestamp = block.timestamp;

        // Initialize rebase index at 1:1 (1e6 precision for 6 decimal token)
        rebaseIndex = REBASE_INDEX_PRECISION;
    }

    // ============ EXTERNAL NONPAYABLE (State-changing) ============

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
    ) external onlyRole(MANAGER_ROLE) nonZeroAddress(token) nonZeroAddress(depositToken) nonZeroAddress(manager) {
        if (yieldAssets[token].token != address(0)) {
            revert AssetAlreadyExists(token);
        }

        yieldAssets[token] = YieldAsset({
            token: token,
            manager: manager,
            depositToken: depositToken,
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
    function updateYieldAssetAllocation(address token, uint256 newAllocation) external onlyRole(MANAGER_ROLE) {
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
        if (balance != 0) revert FundsRemaining(balance);

        // Find and remove from array (swap-and-pop)
        uint256 length = yieldAssetList.length;
        for (uint256 i = 0; i < length; ++i) {
            if (yieldAssetList[i] == token) {
                yieldAssetList[i] = yieldAssetList[length - 1];
                yieldAssetList.pop();
                break;
            }
        }

        delete yieldAssets[token];
        emit YieldAssetRemoved(token);
    }

    /**
     * @notice Grant bridge role (for CCIP Token Pool)
     * @param bridge Address to grant BRIDGE_ROLE to
     */
    function grantBridgeRole(address bridge) external nonZeroAddress(bridge) onlyRole(DEFAULT_ADMIN_ROLE) {
        _grantRole(BRIDGE_ROLE, bridge);
    }

    /**
     * @notice Revoke bridge role
     * @param bridge Address to revoke BRIDGE_ROLE from
     */
    function revokeBridgeRole(address bridge) external nonZeroAddress(bridge) onlyRole(DEFAULT_ADMIN_ROLE) {
        _revokeRole(BRIDGE_ROLE, bridge);
    }

    /**
     * @notice Set CCIP admin address
     * @param newAdmin New CCIP admin address
     */
    function setCCIPAdmin(address newAdmin) external nonZeroAddress(newAdmin) onlyRole(DEFAULT_ADMIN_ROLE) {
        address oldAdmin = ccipAdmin;
        ccipAdmin = newAdmin;
        emit CCIPAdminTransferred(oldAdmin, newAdmin);
    }

    /**
     * @notice Set treasury address
     * @param newTreasury New treasury address
     */
    function setTreasury(address newTreasury) external nonZeroAddress(newTreasury) onlyRole(DEFAULT_ADMIN_ROLE) {
        address oldTreasury = treasury;
        treasury = newTreasury;
        emit TreasuryUpdated(oldTreasury, newTreasury);
    }

    /**
     * @notice Configure the interval used by Chainlink Automation for yield accruals
     * @param newInterval Interval in seconds. Set to 0 to disable automation.
     * @dev Minimum non-zero interval is 1 hour to avoid spamming keepers
     */
    function setYieldAccrualInterval(uint256 newInterval) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newInterval != 0 && newInterval < MIN_AUTOMATION_INTERVAL) {
            revert AutomationIntervalTooShort(newInterval);
        }

        uint256 oldInterval = yieldAccrualInterval;
        yieldAccrualInterval = newInterval;
        emit YieldAccrualIntervalUpdated(oldInterval, newInterval);
    }

    /**
     * @notice Set deposit fee
     * @dev Fee is deducted from user deposits and transferred to the treasury address.
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
     * @param account Address to blacklist
     */
    function blacklist(address account) external nonZeroAddress(account) onlyRole(BLACKLISTER_ROLE) {
        blacklisted[account] = true;
        emit Blacklisted(account);
    }

    /**
     * @notice Remove address from blacklist
     * @param account Address to remove from blacklist
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
     * @param token Token address to withdraw
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

    /**
     * @notice Accrue yield from underlying yield assets into internal accounting
     * @dev This function calculates the actual value of yield positions and updates
     *      totalDepositedAssets to reflect accrued yield. Should be called periodically.
     *      Only increases totalDepositedAssets (yield accrual), never decreases.
     * @return yieldAccrued Amount of yield accrued
     */
    function accrueYield() external onlyRole(MANAGER_ROLE) returns (uint256 yieldAccrued) {
        (yieldAccrued,) = _accrueYieldInternal();
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

    /**
     * @inheritdoc AutomationCompatibleInterface
     */
    function performUpkeep(bytes calldata) external override {
        uint256 interval = yieldAccrualInterval;
        if (interval == 0) revert UpkeepNotNeeded();

        if (block.timestamp - lastYieldAccrualTimestamp < interval) revert UpkeepNotNeeded();

        uint256 currentDeposited = totalDepositedAssets;
        uint256 actualValue = _calculateActualYieldValue(currentDeposited);
        if (actualValue < currentDeposited) revert UpkeepNotNeeded();

        _accrueYieldInternal();
    }

    /**
     * @notice Mint shares for CCIP bridge (burn-and-mint pattern)
     * @dev Conforms to Chainlink IBurnMintERC20 signature: mint(address,uint256).
     *      This mint operation does not update totalDepositedAssets, as it's for cross-chain transfers only.
     * @param account Address receiving the newly minted shares on this chain
     * @param amount Amount of shares to mint
     */
    function mint(address account, uint256 amount)
        external
        whenNotPaused
        onlyRole(BRIDGE_ROLE)
        notBlacklisted(account)
    {
        if (account == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (account == address(this)) revert InvalidRecipient(account);

        _mint(account, amount);
        emit BridgeMint(msg.sender, account, amount);
    }

    /**
     * @notice Burn shares for CCIP bridge (burn-and-mint pattern)
     * @dev Only callable by BRIDGE_ROLE (CCIP Token Pool). Does not update totalDepositedAssets.
     * @param account Address to burn from
     * @param amount Amount of shares to burn
     */
    function burn(address account, uint256 amount) external whenNotPaused onlyRole(BRIDGE_ROLE) {
        if (account == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        _burn(account, amount);
        emit BridgeBurn(msg.sender, account, amount);
    }

    /**
     * @notice Burn shares from caller's balance
     * @dev Conforms to Chainlink IBurnMintERC20 signature: burn(uint256)
     *      Only callable by BRIDGE_ROLE for CCIP compatibility
     * @param amount Amount of shares to burn
     */
    function burn(uint256 amount) external whenNotPaused onlyRole(BRIDGE_ROLE) {
        if (amount == 0) revert ZeroAmount();

        _burn(msg.sender, amount);
        emit BridgeBurn(msg.sender, msg.sender, amount);
    }

    /**
     * @notice Burn shares from account using allowance
     * @dev Conforms to Chainlink IBurnMintERC20 signature: burnFrom(address,uint256)
     *      Only callable by BRIDGE_ROLE for CCIP compatibility
     * @param account Address to burn from
     * @param amount Amount of shares to burn
     */
    function burnFrom(address account, uint256 amount) external whenNotPaused onlyRole(BRIDGE_ROLE) {
        if (account == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        _spendAllowance(account, msg.sender, amount);
        _burn(account, amount);
        emit BridgeBurn(msg.sender, account, amount);
    }

    // ============ EXTERNAL VIEW ============

    /**
     * @inheritdoc AutomationCompatibleInterface
     */
    function checkUpkeep(bytes calldata) external view override returns (bool upkeepNeeded, bytes memory performData) {
        uint256 interval = yieldAccrualInterval;
        if (interval == 0) {
            return (false, "");
        }

        if (block.timestamp - lastYieldAccrualTimestamp < interval) {
            return (false, "");
        }

        uint256 currentDeposited = totalDepositedAssets;
        uint256 actualValue = _calculateActualYieldValue(currentDeposited);
        if (actualValue > currentDeposited) {
            upkeepNeeded = true;
            performData = abi.encode(actualValue, currentDeposited);
        }
    }

    /// @inheritdoc IGetCCIPAdmin
    function getCCIPAdmin() external view override returns (address) {
        return ccipAdmin;
    }

    /**
     * @notice Get yield asset details
     * @param token Yield asset token address
     * @return Yield asset configuration
     */
    function getYieldAsset(address token) external view returns (YieldAsset memory) {
        return yieldAssets[token];
    }

    /**
     * @notice Get all yield asset addresses
     * @return Array of yield asset token addresses
     */
    function getYieldAssetList() external view returns (address[] memory) {
        return yieldAssetList;
    }

    /**
     * @notice Get number of yield assets
     * @return Number of configured yield assets
     */
    function getYieldAssetCount() external view returns (uint256) {
        return yieldAssetList.length;
    }

    /**
     * @notice Get the current rebase index
     * @dev Index starts at 1e6 and increases as yield accrues
     *      balance = rawShares * rebaseIndex / 1e6
     * @return The current rebase index
     */
    function getRebaseIndex() external view returns (uint256) {
        return rebaseIndex;
    }

    /**
     * @notice Get current share price (assets per share)
     * @dev Calculates the price per share including accrued yield. Uses totalAssets() for numerator.
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

    // ============ EXTERNAL PURE ============
    // (none)

    // ============ PUBLIC NONPAYABLE (State-changing) ============

    /**
     * @notice Deposit USDC to receive shares
     * @dev Implements ERC4626 with fee logic and yield allocation
     * @param assets Amount of USDC to deposit
     * @param receiver Address receiving the shares
     * @return shares Number of shares minted
     */
    function deposit(uint256 assets, address receiver)
        public
        nonReentrant
        whenNotPaused
        notBlacklisted(msg.sender)
        notBlacklisted(receiver)
        returns (uint256 shares)
    {
        if (assets < MIN_DEPOSIT) {
            revert BelowMinimumDeposit(assets, MIN_DEPOSIT);
        }
        if (receiver == address(0)) revert ZeroAddress();
        if (receiver == address(this)) revert InvalidRecipient(receiver);

        // Calculate fee
        uint256 fee = (assets * depositFeeBps) / BASIS_POINTS;
        uint256 netAssets = assets - fee;

        // Calculate shares based on net assets using internal accounting
        shares = _convertToShares(netAssets, Math.Rounding.Floor);
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

        // Mint shares
        _mint(receiver, shares);

        emit Deposit(msg.sender, receiver, assets, shares);
    }

    /**
     * @notice Mint shares by depositing USDC
     * @dev Implements ERC4626 with fee logic and yield allocation
     * @param shares Number of shares to mint
     * @param receiver Address receiving the shares
     * @return assets Amount of USDC deposited (including fee)
     */
    function mint(uint256 shares, address receiver)
        public
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
        uint256 netAssets = _convertToAssets(shares, Math.Rounding.Ceil);
        uint256 fee = (netAssets * depositFeeBps) / (BASIS_POINTS - depositFeeBps);
        assets = netAssets + fee;

        if (assets < MIN_DEPOSIT) {
            revert BelowMinimumDeposit(assets, MIN_DEPOSIT);
        }

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
     * @dev Implements ERC4626 with fee logic and yield asset redemption
     * @param assets Amount of USDC to withdraw
     * @param receiver Address receiving the USDC
     * @param owner Address whose shares are being burned
     * @return shares Number of shares burned
     */
    function withdraw(uint256 assets, address receiver, address owner)
        public
        nonReentrant
        whenNotPaused
        notBlacklisted(msg.sender)
        notBlacklisted(receiver)
        notBlacklisted(owner)
        returns (uint256 shares)
    {
        if (assets == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();
        if (assets > totalDepositedAssets) {
            revert InsufficientLiquidity(assets, totalDepositedAssets);
        }

        // Calculate shares to burn using internal accounting
        shares = _convertToShares(assets, Math.Rounding.Ceil);

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
     * @dev Implements ERC4626 with fee logic
     * @param shares Amount of shares to redeem
     * @param receiver Address receiving the USDC
     * @param owner Address whose shares are being redeemed
     * @return assets Amount of USDC returned
     */
    function redeem(uint256 shares, address receiver, address owner)
        public
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
        assets = _convertToAssets(shares, Math.Rounding.Floor);
        if (assets > totalDepositedAssets) {
            revert InsufficientLiquidity(assets, totalDepositedAssets);
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
     * @notice Transfer rebased tokens
     * @dev Converts rebased amount to raw shares before transfer
     * @param to Recipient address
     * @param value Rebased amount to transfer
     * @return True if successful
     */
    function transfer(address to, uint256 value) public override(ERC20Upgradeable, IERC20) returns (bool) {
        uint256 rawShares = _toRawShares(value);
        return super.transfer(to, rawShares);
    }

    /**
     * @notice Transfer rebased tokens from another account
     * @dev Converts rebased amount to raw shares before transfer
     *      Note: Allowances are in rebased amounts for user convenience
     * @param from Sender address
     * @param to Recipient address
     * @param value Rebased amount to transfer
     * @return True if successful
     */
    function transferFrom(address from, address to, uint256 value)
        public
        override(ERC20Upgradeable, IERC20)
        returns (bool)
    {
        uint256 rawShares = _toRawShares(value);
        // Spend allowance in rebased terms (what user approved)
        _spendAllowance(from, _msgSender(), value);
        // Transfer raw shares
        _transfer(from, to, rawShares);
        return true;
    }

    // ============ PUBLIC VIEW ============

    /**
     * @notice Get the underlying asset address (USDC)
     * @return Address of the underlying asset
     */
    function asset() public view override returns (address) {
        return assetAddress;
    }

    /**
     * @notice Get total assets managed by the vault
     * @dev Uses internal accounting (totalDepositedAssets) to prevent donation attacks.
     *      External actors cannot manipulate this by sending USDC directly to contract.
     * @return Total assets in USDC (6 decimals)
     */
    function totalAssets() public view override returns (uint256) {
        return totalDepositedAssets;
    }

    /**
     * @notice Get total supply of shares (rebased)
     * @dev Returns rebased total supply for ERC20 compatibility
     *      totalSupply = rawTotalSupply * rebaseIndex / PRECISION
     * @return Total supply in rebased units
     */
    function totalSupply() public view override(ERC20Upgradeable, IERC20) returns (uint256) {
        return (super.totalSupply() * rebaseIndex) / REBASE_INDEX_PRECISION;
    }

    /**
     * @notice Get balance of account (rebased)
     * @dev Returns rebased balance for ERC20 compatibility
     *      balance = rawShares * rebaseIndex / PRECISION
     * @param account Address to query
     * @return Balance in rebased units
     */
    function balanceOf(address account) public view override(ERC20Upgradeable, IERC20) returns (uint256) {
        return (super.balanceOf(account) * rebaseIndex) / REBASE_INDEX_PRECISION;
    }

    /**
     * @notice Get raw share balance (not rebased)
     * @param account Address to query
     * @return Raw share balance
     */
    function sharesOf(address account) public view returns (uint256) {
        return super.balanceOf(account);
    }

    /**
     * @notice Get total raw shares (not rebased)
     * @return Total raw shares
     */
    function totalShares() public view returns (uint256) {
        return super.totalSupply();
    }

    /**
     * @notice Preview deposit amount
     * @dev Returns shares that would be minted for given assets (after fee)
     * @param assets Amount of assets to deposit
     * @return Shares that would be minted
     */
    function previewDeposit(uint256 assets) public view override returns (uint256) {
        uint256 fee = (assets * depositFeeBps) / BASIS_POINTS;
        uint256 netAssets = assets - fee;
        return _convertToShares(netAssets, Math.Rounding.Floor);
    }

    /**
     * @notice Preview mint amount
     * @dev Returns assets needed to mint given shares (including fee)
     * @param shares Amount of shares to mint
     * @return Assets needed (including fee)
     */
    function previewMint(uint256 shares) public view override returns (uint256) {
        uint256 netAssets = _convertToAssets(shares, Math.Rounding.Ceil);
        uint256 fee = (netAssets * depositFeeBps) / (BASIS_POINTS - depositFeeBps);
        return netAssets + fee;
    }

    /**
     * @notice Preview withdraw amount
     * @dev Returns shares needed to withdraw given assets
     * @param assets Amount of assets to withdraw
     * @return Shares needed
     */
    function previewWithdraw(uint256 assets) public view override returns (uint256) {
        return _convertToShares(assets, Math.Rounding.Ceil);
    }

    /**
     * @notice Preview redeem amount
     * @dev Returns assets received for redeeming given shares
     * @param shares Amount of shares to redeem
     * @return Assets received
     */
    function previewRedeem(uint256 shares) public view override returns (uint256) {
        return _convertToAssets(shares, Math.Rounding.Floor);
    }

    /**
     * @notice Convert assets to shares
     * @dev Returns shares equivalent to given assets
     * @param assets Amount of assets
     * @return Equivalent shares
     */
    function convertToShares(uint256 assets) public view override returns (uint256) {
        return _convertToShares(assets, Math.Rounding.Floor);
    }

    /**
     * @notice Convert shares to assets
     * @dev Returns assets equivalent to given shares
     * @param shares Amount of shares
     * @return Equivalent assets
     */
    function convertToAssets(uint256 shares) public view override returns (uint256) {
        return _convertToAssets(shares, Math.Rounding.Floor);
    }

    /**
     * @notice Get maximum withdraw amount for account
     * @param owner Address whose shares to withdraw
     * @return Maximum withdraw amount
     */
    function maxWithdraw(address owner) public view override returns (uint256) {
        return _convertToAssets(balanceOf(owner), Math.Rounding.Floor);
    }

    /**
     * @notice Get maximum redeem amount for account
     * @param owner Address whose shares to redeem
     * @return Maximum redeem amount
     */
    function maxRedeem(address owner) public view override returns (uint256) {
        return balanceOf(owner);
    }

    // ============ PUBLIC PURE ============

    /// @inheritdoc IERC4626
    function maxDeposit(address) public pure override returns (uint256) {
        return type(uint256).max;
    }

    /// @inheritdoc IERC4626
    function maxMint(address) public pure override returns (uint256) {
        return type(uint256).max;
    }

    /**
     * @notice Get token decimals
     * @return Number of decimals (6 for USDC compatibility)
     */
    function decimals() public pure override(ERC20Upgradeable, IERC20Metadata) returns (uint8) {
        return 6;
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId)
        public
        pure
        override(AccessControlUpgradeable, IERC165)
        returns (bool)
    {
        return interfaceId == type(IERC20).interfaceId || interfaceId == type(IERC4626).interfaceId
            || interfaceId == type(IERC165).interfaceId || interfaceId == type(IAccessControl).interfaceId
            || interfaceId == type(IGetCCIPAdmin).interfaceId || interfaceId == type(IBurnMintERC20).interfaceId
            || interfaceId == type(AutomationCompatibleInterface).interfaceId;
    }

    // ============ INTERNAL FUNCTIONS ============

    /**
     * @notice Allocate amount to yield assets
     * @param amount Amount to allocate
     */
    function _allocateToYieldAssets(uint256 amount) internal {
        // Simplified: allocate proportionally or to first active asset
        for (uint256 i = 0; i < yieldAssetList.length; ++i) {
            address token = yieldAssetList[i];
            YieldAsset storage yieldAsset = yieldAssets[token];
            if (yieldAsset.active) {
                _depositToYieldAsset(yieldAsset, amount);
                break;
            }
        }
    }

    /**
     * @notice Deposits USDC into a specific yield-generating protocol
     * @dev Routes deposit based on asset type:
     *      - ERC4626: Calls deposit(amount, address(this))
     *      - ONDO_OUSG: Calls mint(amount) on InstantManager
     * @param yieldAsset Storage pointer to the yield asset configuration
     * @param amount Amount of USDC to deposit (6 decimals)
     */
    function _depositToYieldAsset(YieldAsset storage yieldAsset, uint256 amount) internal {
        if (yieldAsset.assetType == AssetType.ONDO_OUSG) {
            IOUSGInstantManager(yieldAsset.manager).mint(amount);
        } else {
            _depositIntoERC4626Vault(yieldAsset, amount);
        }
    }

    /**
     * @notice Deposits USDC into an ERC4626 vault
     * @dev Approves vault manager and calls deposit function
     * @param yieldAsset Storage pointer to yield asset configuration
     * @param amount Amount of USDC to deposit
     */
    function _depositIntoERC4626Vault(YieldAsset storage yieldAsset, uint256 amount) internal {
        IERC20(yieldAsset.depositToken).safeIncreaseAllowance(yieldAsset.manager, amount);
        IERC4626(yieldAsset.manager).deposit(amount, address(this));
    }

    /**
     * @notice Redeem from yield assets (enforces exact amount)
     * @dev H-01 Fix: Tracks actual balance changes, not assumed amounts.
     *      Prevents silent failures from illiquid yield protocols.
     * @param amount Amount to redeem
     */
    function _redeemFromYieldAssets(uint256 amount) internal {
        _redeemFromYieldAssets(amount, true);
    }

    /**
     * @notice Internal variant that supports best-effort withdrawals (used for harvesting)
     * @param amount Total USDC amount requested
     * @param enforceExactAmount When false, allows rounding shortfalls instead of reverting
     */
    function _redeemFromYieldAssets(uint256 amount, bool enforceExactAmount) internal {
        IERC20 usdc = IERC20(asset());
        uint256 length = yieldAssetList.length;

        // First, check if we have enough USDC held directly
        uint256 usdcBalanceBefore = usdc.balanceOf(address(this));
        if (usdcBalanceBefore > amount) return; // Have enough USDC

        uint256 remaining = amount - usdcBalanceBefore;

        for (uint256 i = 0; i < length && remaining > 0; ++i) {
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
        if (enforceExactAmount && finalBalance < amount) {
            revert InsufficientLiquidity(amount, finalBalance);
        }
    }

    /**
     * @notice Redeems USDC from a specific yield protocol
     * @dev Routes redemption based on asset type:
     *      - ERC4626: Converts amount to shares, redeems up to available balance
     *      - ONDO_OUSG: Redeems entire balance (OUSG has minimum redemption requirements)
     * @param yieldAsset Storage pointer to the yield asset configuration
     * @param amount Target amount of USDC to redeem (6 decimals)
     */
    function _redeemFromYieldAsset(YieldAsset storage yieldAsset, uint256 amount) internal {
        IERC20 yieldToken = IERC20(yieldAsset.token);
        uint256 balance = yieldToken.balanceOf(address(this));

        if (balance == 0) return;

        if (yieldAsset.assetType == AssetType.ONDO_OUSG) {
            yieldToken.safeIncreaseAllowance(yieldAsset.manager, balance);
            IOUSGInstantManager(yieldAsset.manager).redeem(balance);
        } else {
            _withdrawFromERC4626Vault(yieldAsset, amount, balance);
        }
    }

    /**
     * @notice Withdraws assets from an ERC4626 vault
     * @dev Converts assets to shares and redeems from vault
     * @param yieldAsset Storage pointer to yield asset configuration
     * @param requestedAssets Requested amount of assets to redeem
     * @param shareBalance Current share balance in the vault
     */
    function _withdrawFromERC4626Vault(YieldAsset storage yieldAsset, uint256 requestedAssets, uint256 shareBalance)
        internal
    {
        if (shareBalance == 0 || requestedAssets == 0) {
            return;
        }

        IERC4626 vault = IERC4626(yieldAsset.manager);
        uint256 sharesToRedeem = vault.convertToShares(requestedAssets);
        if (sharesToRedeem == 0) {
            sharesToRedeem = shareBalance;
        }
        if (sharesToRedeem > shareBalance) {
            sharesToRedeem = shareBalance;
        }

        vault.redeem(sharesToRedeem, address(this), address(this));
    }

    /**
     * @notice Accrue yield internally
     * @dev Shared by manual accruals and Chainlink Automation
     *      Updates rebaseIndex so that: newBalance = oldBalance * newIndex / oldIndex
     *      This maintains 1:1 USDC peg while distributing yield proportionally
     * @return yieldAccrued Amount of yield accrued
     * @return actualValue Actual value after accrual
     */
    function _accrueYieldInternal() internal returns (uint256 yieldAccrued, uint256 actualValue) {
        uint256 currentDeposited = totalDepositedAssets;
        actualValue = _calculateActualYieldValue(currentDeposited);

        lastYieldAccrualTimestamp = block.timestamp;

        if (actualValue > currentDeposited && currentDeposited > 0) {
            yieldAccrued = actualValue - currentDeposited;
            // Pull realized gains back into USDC before updating accounting
            _harvestYield(yieldAccrued);

            // After harvest, recalculate with all USDC now in contract
            uint256 vaultValue = _sumActiveYieldAssetValue();
            IERC20 usdc = IERC20(assetAddress);
            uint256 usdcBalance = usdc.balanceOf(address(this));
            actualValue = vaultValue + usdcBalance;

            // Update rebase index proportionally to distribute yield to all holders
            // newIndex = oldIndex * actualValue / currentDeposited
            uint256 oldIndex = rebaseIndex;
            uint256 newIndex = (oldIndex * actualValue) / currentDeposited;
            rebaseIndex = newIndex;

            totalDepositedAssets = actualValue;

            emit RebaseIndexUpdated(oldIndex, newIndex);
            emit YieldAccrued(yieldAccrued, actualValue);
        }
    }

    /**
     * @notice Withdraws accrued yield from external protocols into USDC held by this contract
     * @dev Reuses the redemption waterfall to realize profits before updating internal accounting
     * @param amount Amount of yield to harvest
     */
    function _harvestYield(uint256 amount) internal {
        if (amount == 0) return;
        _redeemFromYieldAssets(amount, false);
    }

    /**
     * @notice Override ERC20 _update to enforce blacklist
     * @dev Checks both from and to addresses against blacklist
     * @param from Sender address
     * @param to Recipient address
     * @param value Amount being transferred
     */
    function _update(address from, address to, uint256 value)
        internal
        override(ERC20Upgradeable, ERC20PausableUpgradeable)
    {
        if (from != address(0) && blacklisted[from]) {
            revert AddressBlacklisted(from);
        }
        if (to != address(0) && blacklisted[to]) revert AddressBlacklisted(to);

        super._update(from, to, value);
    }

    /**
     * @notice Authorizes contract upgrades through the UUPS proxy pattern
     * @dev Internal function called by the UUPS upgrade mechanism to verify
     *      that the caller has permission to upgrade the contract implementation.
     *      Increments version number for tracking and emits Upgrade event.
     * @param newImplementation Address of the new implementation contract
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {
        if (newImplementation == address(0)) revert ZeroAddress();
        ++version;
        emit Upgrade(msg.sender, newImplementation);
    }

    /**
     * @notice Convert assets to shares internally
     * @dev Prevents bridge mint inflation attacks by using actual deposited liquidity
     * @param assets Amount of assets
     * @param rounding Rounding direction
     * @return shares Amount of shares
     */
    function _convertToShares(uint256 assets, Math.Rounding rounding) internal view returns (uint256 shares) {
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
     * @notice Convert shares to assets internally
     * @dev Prevents bridge mint inflation attacks by using actual deposited liquidity
     * @param shares Amount of shares
     * @param rounding Rounding direction
     * @return assets Amount of assets
     */
    function _convertToAssets(uint256 shares, Math.Rounding rounding) internal view returns (uint256 assets) {
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
     * @notice Calculate the actual value of all yield positions in USDC terms
     * @dev Used for yield accrual to update internal accounting
     * @param trackedDeposits Current tracked deposits
     * @return total Total value of all yield assets plus any USDC held
     */
    function _calculateActualYieldValue(uint256 trackedDeposits) internal view returns (uint256 total) {
        uint256 vaultValue = _sumActiveYieldAssetValue();
        total = vaultValue;

        // Add USDC held directly (only the tracked portion, not donations)
        // We use min(balance, trackedDeposits - vaultValue) to avoid counting donations
        IERC20 usdc = IERC20(assetAddress);
        uint256 usdcBalance = usdc.balanceOf(address(this));
        uint256 usdcTracked = trackedDeposits > vaultValue ? trackedDeposits - vaultValue : 0;
        total += usdcBalance < usdcTracked ? usdcBalance : usdcTracked;
    }

    /**
     * @notice Sum value of all active yield assets
     * @return vaultValue Total value in yield positions
     */
    function _sumActiveYieldAssetValue() internal view returns (uint256 vaultValue) {
        for (uint256 i = 0; i < yieldAssetList.length; ++i) {
            address token = yieldAssetList[i];
            vaultValue += _getYieldAssetValue(yieldAssets[token]);
        }
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
            value = IERC4626(yieldAsset.manager).convertToAssets(balance);
        } else if (yieldAsset.assetType == AssetType.AAVE_V3) {
            // Aave aTokens are 1:1 with underlying (they rebase)
            value = balance;
        } else if (yieldAsset.assetType == AssetType.ONDO_OUSG) {
            // OUSG - use RWA oracle for price (Chainlink-compatible, 8 decimals)
            // yieldAsset.manager stores the oracle address for OUSG
            IRWAOracle oracle = IRWAOracle(yieldAsset.manager);
            (, int256 price,,,) = oracle.latestRoundData();
            if (price < 1) revert InvalidOraclePrice();
            // OUSG has 18 decimals, oracle price has 8 decimals (Chainlink standard)
            // Example: OUSG balance = 100e18, price = 113.47e8 (=$113.47)
            // value = 100e18 * 113.47e8 / 1e8 / 1e12 = 11347e6 USDC
            // Formula: balance * price / 1e8 / 1e12 = balance * price / 1e20
            value = (balance * uint256(price)) / 1e20;
        }
    }

    /**
     * @notice Validates that total allocation percentages don't exceed 100%
     * @dev Iterates through all active yield assets and sums their allocation values.
     *      Only active assets are counted; deactivated assets are ignored.
     */
    function _validateTotalAllocation() internal view {
        uint256 total = 0;
        uint256 length = yieldAssetList.length;

        for (uint256 i = 0; i < length; ++i) {
            YieldAsset storage yieldAsset = yieldAssets[yieldAssetList[i]];
            if (yieldAsset.active) {
                total += yieldAsset.allocation;
            }
        }

        if (total > BASIS_POINTS) revert InvalidAllocation(total);
    }

    /**
     * @notice Convert rebased amount to raw shares
     * @param rebasedAmount Rebased amount
     * @return rawShares Raw share amount
     */
    function _toRawShares(uint256 rebasedAmount) internal view returns (uint256 rawShares) {
        if (rebaseIndex == 0) return rebasedAmount;
        return rebasedAmount * REBASE_INDEX_PRECISION / rebaseIndex;
    }

    /**
     * @notice Convert raw shares to rebased amount
     * @param rawShares Raw share amount
     * @return rebasedAmount Rebased amount
     */
    function _toRebasedAmount(uint256 rawShares) internal view returns (uint256 rebasedAmount) {
        if (rebaseIndex == 0) return rawShares;
        return rawShares * rebaseIndex / REBASE_INDEX_PRECISION;
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title USDL Stablecoin
 * @notice Lendefi USD synthetic stablecoin backed by yield-bearing assets (OUSG, BUIDL, etc.)
 * @dev Synthetic stablecoin where deposits are 100% converted to RWA yield-bearing assets.
 *      Minting is controlled via MINTER_ROLE granted to:
 *      - YieldRouter: Mints USDL when users deposit collateral (converted to yield assets)
 *      - CCIP Token Pool: Mints USDL for cross-chain transfers (burn-and-mint mechanism)
 *      Upgradeable via UUPS proxy pattern
 * @custom:security-contact security@lendefimarkets.com
 */

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {ERC20BurnableUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20BurnableUpgradeable.sol";
import {ERC20PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PausableUpgradeable.sol";
import {ERC20PermitUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IBurnMintERC20} from "../interfaces/IBurnMintERC20.sol";
import {IGetCCIPAdmin} from "../interfaces/IGetCCIPAdmin.sol";

/// @custom:oz-upgrades
contract USDL is
    IERC165,
    IGetCCIPAdmin,
    IBurnMintERC20,
    ERC20Upgradeable,
    ERC20BurnableUpgradeable,
    ERC20PausableUpgradeable,
    ERC20PermitUpgradeable,
    AccessControlUpgradeable,
    UUPSUpgradeable
{
    // ============ Constants ============

    /// @notice Contract version for upgrade tracking
    uint256 public constant VERSION = 1;

    /// @dev AccessControl Role Constants
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BRIDGE_ROLE = keccak256("BRIDGE_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant BLACKLISTER_ROLE = keccak256("BLACKLISTER_ROLE");

    // ============ Storage Variables ============

    /// @notice Deployed version (increments on each upgrade)
    uint256 public version;

    /// @notice CCIP admin address for token admin registry
    address internal ccipAdmin;

    /// @notice Blacklisted addresses (for compliance)
    mapping(address => bool) public blacklisted;

    /// @notice Storage gap for future upgrades
    uint256[45] private __gap;

    // ============ Events ============

    event Minted(address indexed minter, address indexed to, uint256 amount);
    event BridgeMinted(address indexed bridge, address indexed to, uint256 amount);
    event CCIPAdminTransferred(address indexed previousAdmin, address indexed newAdmin);
    event Blacklisted(address indexed account);
    event UnBlacklisted(address indexed account);
    event Upgrade(address indexed sender, address indexed implementation);

    // ============ Errors ============

    error ZeroAddress();
    error ZeroAmount();
    error InvalidRecipient(address recipient);
    error AddressBlacklisted(address account);

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
     * @notice Initialize the USDL stablecoin contract
     * @param _owner Owner/admin address
     */
    function initialize(address _owner) external initializer {
        if (_owner == address(0)) revert ZeroAddress();

        __ERC20_init("Lendefi USD", "USDL");
        __ERC20Burnable_init();
        __ERC20Pausable_init();
        __ERC20Permit_init("Lendefi USD");
        __AccessControl_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, _owner);
        _grantRole(PAUSER_ROLE, _owner);
        _grantRole(UPGRADER_ROLE, _owner);
        _grantRole(MINTER_ROLE, _owner);
        _grantRole(BLACKLISTER_ROLE, _owner);

        version = 1;
        ccipAdmin = _owner;
    }

    // ============ Minting Functions ============

    /**
     * @notice Mint USDL stablecoins (admin minting)
     * @param account Address receiving the tokens
     * @param amount Amount to mint
     * @dev Only callable by addresses with ADMIN_MINTER_ROLE (YieldRouter, admin)
     */
    function mint(address account, uint256 amount)
        external
        override
        whenNotPaused
    {
        if (!hasRole(MINTER_ROLE, msg.sender) && !hasRole(BRIDGE_ROLE, msg.sender)) {
            revert AccessControlUnauthorizedAccount(msg.sender, MINTER_ROLE);
        }
        if (account == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (blacklisted[account]) revert AddressBlacklisted(account);
        if (account == address(this)) revert InvalidRecipient(account);

        _mint(account, amount);
        
        if (hasRole(BRIDGE_ROLE, msg.sender)) {
            emit BridgeMinted(msg.sender, account, amount);
        } else {
            emit Minted(msg.sender, account, amount);
        }
    }

    // ============ Burn Functions ============

    /// @inheritdoc ERC20BurnableUpgradeable
    function burn(uint256 amount) public override(IBurnMintERC20, ERC20BurnableUpgradeable) {
        super.burn(amount);
    }

    /// @inheritdoc IBurnMintERC20
    function burn(address account, uint256 amount) public override {
        burnFrom(account, amount);
    }

    /// @inheritdoc ERC20BurnableUpgradeable
    function burnFrom(address account, uint256 amount) 
        public 
        override(IBurnMintERC20, ERC20BurnableUpgradeable) 
    {
        super.burnFrom(account, amount);
    }

    // ============ Admin Functions ============

    /**
     * @notice Grant minter role (for YieldRouter, admin operations)
     * @param minter Address to grant minting rights
     */
    function grantMinterRole(address minter) external nonZeroAddress(minter) onlyRole(DEFAULT_ADMIN_ROLE) {
        _grantRole(MINTER_ROLE, minter);
    }

    /**
     * @notice Revoke minter role
     * @param minter Address to revoke
     */
    function revokeMinterRole(address minter) external nonZeroAddress(minter) onlyRole(DEFAULT_ADMIN_ROLE) {
        _revokeRole(MINTER_ROLE, minter);
    }

    /**
     * @notice Grant bridge role (for CCIP Token Pool bridge)
     * @param bridge Address to grant bridge minting rights
     */
    function grantBridgeRole(address bridge) external nonZeroAddress(bridge) onlyRole(DEFAULT_ADMIN_ROLE) {
        _grantRole(BRIDGE_ROLE, bridge);
    }

    /**
     * @notice Revoke bridge role
     * @param bridge Address to revoke
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
     * @notice Blacklist an address (compliance requirement for stablecoins)
     * @param account Address to blacklist
     */
    function blacklist(address account) external nonZeroAddress(account) onlyRole(BLACKLISTER_ROLE) {
        blacklisted[account] = true;
        emit Blacklisted(account);
    }

    /**
     * @notice Remove address from blacklist
     * @param account Address to unblacklist
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

    // ============ View Functions ============

    /// @inheritdoc IGetCCIPAdmin
    function getCCIPAdmin() external view override returns (address) {
        return ccipAdmin;
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
            interfaceId == type(IBurnMintERC20).interfaceId ||
            interfaceId == type(IERC165).interfaceId ||
            interfaceId == type(IAccessControl).interfaceId ||
            interfaceId == type(IGetCCIPAdmin).interfaceId;
    }

    // ============ Internal Functions ============

    /// @inheritdoc ERC20Upgradeable
    function _update(address from, address to, uint256 value)
        internal
        override(ERC20Upgradeable, ERC20PausableUpgradeable)
    {
        // Check blacklist for transfers (but allow minting to address(0) -> to and burning from -> address(0))
        if (from != address(0) && blacklisted[from]) revert AddressBlacklisted(from);
        if (to != address(0) && blacklisted[to]) revert AddressBlacklisted(to);
        
        super._update(from, to, value);
    }

    /**
     * @dev Authorize upgrade (UUPS)
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {
        if (newImplementation == address(0)) revert ZeroAddress();
        version++;
        emit Upgrade(msg.sender, newImplementation);
    }
}

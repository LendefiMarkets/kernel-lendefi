// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title LDF Token
 * @notice Lendefi utility token with Chainlink CCIP cross-chain support
 * @dev Implements burn-and-mint mechanism for CCIP bridge transfers
 *      Upgradeable via UUPS proxy pattern
 * @custom:security-contact security@lendefimarkets.com
 */

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {ERC20BurnableUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20BurnableUpgradeable.sol";
import {ERC20PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PausableUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IBurnMintERC20} from "../interfaces/IBurnMintERC20.sol";
import {IGetCCIPAdmin} from "../interfaces/IGetCCIPAdmin.sol";

/// @custom:oz-upgrades
contract LDF is
    IERC165,
    IGetCCIPAdmin,
    IBurnMintERC20,
    ERC20Upgradeable,
    ERC20BurnableUpgradeable,
    ERC20PausableUpgradeable,
    AccessControlUpgradeable,
    UUPSUpgradeable
{
    // ============ Constants ============

    /// @notice Contract version for upgrade tracking
    uint256 public constant VERSION = 1;

    /// @notice Initial token supply (50 million tokens)
    uint256 private constant INITIAL_SUPPLY = 50_000_000 ether;

    /// @dev AccessControl Role Constants
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    // ============ Storage Variables ============

    /// @notice Maximum supply cap
    uint256 public maxSupply;

    /// @notice Deployed version (increments on each upgrade)
    uint256 public version;

    /// @notice CCIP admin address for token admin registry
    address internal ccipAdmin;

    /// @notice Storage gap for future upgrades
    uint256[46] private __gap;

    // ============ Events ============

    event Minted(address indexed minter, address indexed to, uint256 amount);
    event CCIPAdminTransferred(address indexed previousAdmin, address indexed newAdmin);
    event Upgrade(address indexed sender, address indexed implementation);

    // ============ Errors ============

    error ZeroAddress();
    error ZeroAmount();
    error MaxSupplyExceeded(uint256 requested, uint256 maxAllowed);
    error InvalidRecipient(address recipient);

    // ============ Modifiers ============

    modifier nonZeroAmount(uint256 amount) {
        if (amount == 0) revert ZeroAmount();
        _;
    }

    modifier nonZeroAddress(address addr) {
        if (addr == address(0)) revert ZeroAddress();
        _;
    }

    // ============ Constructor ============

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // ============ Initializer ============

    /**
     * @notice Initialize the LDF token contract
     * @param _owner Owner/admin address
     * @param _treasury Treasury address to receive initial supply
     */
    function initialize(address _owner, address _treasury) external initializer {
        if (_owner == address(0)) revert ZeroAddress();
        if (_treasury == address(0)) revert ZeroAddress();

        __ERC20_init("Lendefi Token", "LDF");
        __ERC20Burnable_init();
        __ERC20Pausable_init();
        __AccessControl_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, _owner);
        _grantRole(PAUSER_ROLE, _owner);
        _grantRole(UPGRADER_ROLE, _owner);
        _grantRole(MINTER_ROLE, _owner);

        maxSupply = INITIAL_SUPPLY;
        version = 1;
        ccipAdmin = _owner;

        // Mint initial supply to treasury
        _mint(_treasury, INITIAL_SUPPLY);
    }

    // ============ CCIP Bridge Functions ============

    /**
     * @notice Mint tokens (for CCIP cross-chain transfers)
     * @param account Address receiving the tokens
     * @param amount Amount to mint
     * @dev Only callable by addresses with MINTER_ROLE (CCIP Token Pool)
     */
    function mint(address account, uint256 amount)
        external
        override
        whenNotPaused
        onlyRole(MINTER_ROLE)
    {
        if (account == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (account == address(this)) revert InvalidRecipient(account);

        // Supply constraint validation
        uint256 newSupply = totalSupply() + amount;
        if (newSupply > maxSupply) {
            revert MaxSupplyExceeded(newSupply, maxSupply);
        }

        _mint(account, amount);
        emit Minted(msg.sender, account, amount);
    }

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
     * @notice Grant minter role (for CCIP Token Pool)
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
     * @notice Set CCIP admin address
     * @param newAdmin New CCIP admin address
     */
    function setCCIPAdmin(address newAdmin) external nonZeroAddress(newAdmin) onlyRole(DEFAULT_ADMIN_ROLE) {
        address oldAdmin = ccipAdmin;
        ccipAdmin = newAdmin;
        emit CCIPAdminTransferred(oldAdmin, newAdmin);
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

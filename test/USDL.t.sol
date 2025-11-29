// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import "../src/lendefi/USDL.sol";
import {AssetType} from "../src/interfaces/IYieldProtocols.sol";
import {IBurnMintERC20} from "../src/interfaces/IBurnMintERC20.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract MockUSDC {
    string public name = "USD Coin";
    string public symbol = "USDC";
    uint8 public decimals = 6;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function burn(address from, uint256 amount) external {
        balanceOf[from] -= amount;
        totalSupply -= amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (allowance[from][msg.sender] != type(uint256).max) {
            allowance[from][msg.sender] -= amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract MockERC4626Vault {
    MockUSDC public depositToken;
    string public name = "Mock Yield Token";
    string public symbol = "mYLD";
    uint8 public decimals = 6;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;
    uint256 public yieldMultiplier = 1e18;

    constructor(address _depositToken) {
        depositToken = MockUSDC(_depositToken);
    }

    function setYieldMultiplier(uint256 _multiplier) external {
        yieldMultiplier = _multiplier;
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        depositToken.transferFrom(msg.sender, address(this), assets);
        shares = assets;
        balanceOf[receiver] += shares;
        totalSupply += shares;
    }

    function redeem(uint256 shares, address receiver, address _owner) external returns (uint256 assets) {
        if (msg.sender != _owner) allowance[_owner][msg.sender] -= shares;
        balanceOf[_owner] -= shares;
        totalSupply -= shares;
        assets = (shares * yieldMultiplier) / 1e18;
        depositToken.mint(receiver, assets);
    }

    function convertToShares(uint256 assets) external view returns (uint256) {
        return (assets * 1e18) / yieldMultiplier;
    }

    function convertToAssets(uint256 shares) external view returns (uint256) {
        return (shares * yieldMultiplier) / 1e18;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (allowance[from][msg.sender] != type(uint256).max) allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract USDLTest is Test {
    USDL public usdl;
    USDL public usdlProxy;
    MockUSDC public usdc;
    MockERC4626Vault public yieldVault;
    MockERC4626Vault public yieldVault2;

    address public owner = address(0x1);
    address public treasury = address(0x2);
    address public user1 = address(0x3);
    address public user2 = address(0x4);
    address public bridge = address(0x5);
    address public manager = address(0x6);
    address public pauser = address(0x8);
    address public upgrader = address(0x9);
    address public blacklister = address(0xA);
    uint256 public constant INITIAL_USDC = 100_000e6;

    function setUp() public {
        usdc = new MockUSDC();
        yieldVault = new MockERC4626Vault(address(usdc));
        yieldVault2 = new MockERC4626Vault(address(usdc));
        usdl = new USDL();

        bytes memory initData = abi.encodeWithSelector(USDL.initialize.selector, owner, address(usdc), treasury);
        ERC1967Proxy proxy = new ERC1967Proxy(address(usdl), initData);
        usdlProxy = USDL(address(proxy));

        vm.startPrank(owner);
        usdlProxy.grantBridgeRole(bridge);
        usdlProxy.grantRole(usdlProxy.MANAGER_ROLE(), manager);
        usdlProxy.grantRole(usdlProxy.PAUSER_ROLE(), pauser);
        usdlProxy.grantRole(usdlProxy.UPGRADER_ROLE(), upgrader);
        usdlProxy.grantRole(usdlProxy.BLACKLISTER_ROLE(), blacklister);
        vm.stopPrank();

        usdc.mint(user1, INITIAL_USDC);
        usdc.mint(user2, INITIAL_USDC);
    }

    function _addDefaultYieldAsset() internal {
        vm.prank(manager);
        usdlProxy.addYieldAsset(address(yieldVault), address(usdc), address(yieldVault), 10000, AssetType.ERC4626);
    }

    function _userDeposit(address user, uint256 amount) internal {
        vm.startPrank(user);
        usdc.approve(address(usdlProxy), amount);
        usdlProxy.deposit(amount, user);
        vm.stopPrank();
    }

    function _warpPastInterval() internal {
        uint256 interval = usdlProxy.yieldAccrualInterval();
        vm.warp(block.timestamp + interval + 1);
    }

    // ============ Initialization Tests (6) ============
    function test_Initialize() public view {
        assertEq(usdlProxy.name(), "Lendefi USD");
        assertEq(usdlProxy.symbol(), "USDL");
        assertEq(usdlProxy.decimals(), 6);
        assertEq(usdlProxy.version(), 1);
        assertEq(usdlProxy.asset(), address(usdc));
        assertEq(usdlProxy.treasury(), treasury);
        assertEq(usdlProxy.getCCIPAdmin(), owner);
        assertEq(usdlProxy.depositFeeBps(), 10);
    }

    function test_InitializeZeroOwnerReverts() public {
        USDL newImpl = new USDL();
        bytes memory initData = abi.encodeWithSelector(USDL.initialize.selector, address(0), address(usdc), treasury);
        vm.expectRevert(USDL.ZeroAddress.selector);
        new ERC1967Proxy(address(newImpl), initData);
    }

    function test_InitializeZeroUsdcReverts() public {
        USDL newImpl = new USDL();
        bytes memory initData = abi.encodeWithSelector(USDL.initialize.selector, owner, address(0), treasury);
        vm.expectRevert(USDL.ZeroAddress.selector);
        new ERC1967Proxy(address(newImpl), initData);
    }

    function test_InitializeZeroTreasuryReverts() public {
        USDL newImpl = new USDL();
        bytes memory initData = abi.encodeWithSelector(USDL.initialize.selector, owner, address(usdc), address(0));
        vm.expectRevert(USDL.ZeroAddress.selector);
        new ERC1967Proxy(address(newImpl), initData);
    }

    function test_CannotInitializeTwice() public {
        vm.expectRevert();
        usdlProxy.initialize(owner, address(usdc), treasury);
    }

    function test_RolesGrantedOnInitialize() public view {
        assertTrue(usdlProxy.hasRole(usdlProxy.DEFAULT_ADMIN_ROLE(), owner));
        assertTrue(usdlProxy.hasRole(usdlProxy.PAUSER_ROLE(), owner));
        assertTrue(usdlProxy.hasRole(usdlProxy.UPGRADER_ROLE(), owner));
        assertTrue(usdlProxy.hasRole(usdlProxy.MANAGER_ROLE(), owner));
        assertTrue(usdlProxy.hasRole(usdlProxy.BLACKLISTER_ROLE(), owner));
    }

    // ============ Deposit Tests (12) ============
    function test_DepositUSDC() public {
        uint256 depositAmount = 1000e6;
        vm.startPrank(user1);
        usdc.approve(address(usdlProxy), depositAmount);
        uint256 shares = usdlProxy.deposit(depositAmount, user1);
        vm.stopPrank();

        uint256 fee = (depositAmount * 10) / 10000;
        assertEq(shares, depositAmount - fee);
        assertEq(usdc.balanceOf(treasury), fee);
    }

    function test_DepositToOtherReceiver() public {
        vm.startPrank(user1);
        usdc.approve(address(usdlProxy), 1000e6);
        uint256 shares = usdlProxy.deposit(1000e6, user2);
        vm.stopPrank();

        assertEq(usdlProxy.balanceOf(user2), shares);
        assertEq(usdlProxy.balanceOf(user1), 0);
    }

    function test_DepositBelowMinimumReverts() public {
        vm.startPrank(user1);
        usdc.approve(address(usdlProxy), 0.5e6);
        vm.expectRevert(abi.encodeWithSelector(USDL.BelowMinimumDeposit.selector, 0.5e6, 1e6));
        usdlProxy.deposit(0.5e6, user1);
        vm.stopPrank();
    }

    function test_DepositExactMinimum() public {
        vm.startPrank(user1);
        usdc.approve(address(usdlProxy), 1e6);
        uint256 shares = usdlProxy.deposit(1e6, user1);
        vm.stopPrank();
        assertGt(shares, 0);
    }

    function test_DepositToZeroAddressReverts() public {
        vm.startPrank(user1);
        usdc.approve(address(usdlProxy), 1000e6);
        vm.expectRevert(USDL.ZeroAddress.selector);
        usdlProxy.deposit(1000e6, address(0));
        vm.stopPrank();
    }

    function test_DepositToContractReverts() public {
        vm.startPrank(user1);
        usdc.approve(address(usdlProxy), 1000e6);
        vm.expectRevert(abi.encodeWithSelector(USDL.InvalidRecipient.selector, address(usdlProxy)));
        usdlProxy.deposit(1000e6, address(usdlProxy));
        vm.stopPrank();
    }

    function test_DepositBlacklistedSenderReverts() public {
        vm.prank(blacklister);
        usdlProxy.blacklist(user1);

        vm.startPrank(user1);
        usdc.approve(address(usdlProxy), 1000e6);
        vm.expectRevert(abi.encodeWithSelector(USDL.AddressBlacklisted.selector, user1));
        usdlProxy.deposit(1000e6, user1);
        vm.stopPrank();
    }

    function test_DepositBlacklistedReceiverReverts() public {
        vm.prank(blacklister);
        usdlProxy.blacklist(user2);

        vm.startPrank(user1);
        usdc.approve(address(usdlProxy), 1000e6);
        vm.expectRevert(abi.encodeWithSelector(USDL.AddressBlacklisted.selector, user2));
        usdlProxy.deposit(1000e6, user2);
        vm.stopPrank();
    }

    function test_DepositWhenPausedReverts() public {
        vm.prank(pauser);
        usdlProxy.pause();

        vm.startPrank(user1);
        usdc.approve(address(usdlProxy), 1000e6);
        vm.expectRevert();
        usdlProxy.deposit(1000e6, user1);
        vm.stopPrank();
    }

    function test_DepositWithZeroFee() public {
        vm.prank(owner);
        usdlProxy.setDepositFee(0);

        vm.startPrank(user1);
        usdc.approve(address(usdlProxy), 1000e6);
        uint256 shares = usdlProxy.deposit(1000e6, user1);
        vm.stopPrank();

        assertEq(shares, 1000e6);
    }

    function test_DepositMultipleUsers() public {
        vm.startPrank(user1);
        usdc.approve(address(usdlProxy), 1000e6);
        usdlProxy.deposit(1000e6, user1);
        vm.stopPrank();

        vm.startPrank(user2);
        usdc.approve(address(usdlProxy), 2000e6);
        usdlProxy.deposit(2000e6, user2);
        vm.stopPrank();

        assertGt(usdlProxy.balanceOf(user2), usdlProxy.balanceOf(user1));
    }

    function testFuzz_Deposit(uint256 amount) public {
        amount = bound(amount, 1e6, 10_000e6);
        vm.startPrank(user1);
        usdc.approve(address(usdlProxy), amount);
        uint256 shares = usdlProxy.deposit(amount, user1);
        vm.stopPrank();
        assertGt(shares, 0);
    }

    // ============ Mint Tests (4) ============
    function test_MintShares() public {
        vm.startPrank(user1);
        usdc.approve(address(usdlProxy), 2000e6);
        uint256 assets = usdlProxy.mint(1000e6, user1);
        vm.stopPrank();

        assertEq(usdlProxy.balanceOf(user1), 1000e6);
        assertGt(assets, 1000e6);
    }

    function test_MintZeroSharesReverts() public {
        vm.prank(user1);
        vm.expectRevert(USDL.ZeroAmount.selector);
        usdlProxy.mint(0, user1);
    }

    function test_MintToZeroAddressReverts() public {
        vm.startPrank(user1);
        usdc.approve(address(usdlProxy), 1000e6);
        vm.expectRevert(USDL.ZeroAddress.selector);
        usdlProxy.mint(1000e6, address(0));
        vm.stopPrank();
    }

    function test_MintBlacklistedReverts() public {
        vm.prank(blacklister);
        usdlProxy.blacklist(user1);

        vm.startPrank(user1);
        usdc.approve(address(usdlProxy), 1000e6);
        vm.expectRevert(abi.encodeWithSelector(USDL.AddressBlacklisted.selector, user1));
        usdlProxy.mint(500e6, user1);
        vm.stopPrank();
    }

    // ============ Withdraw Tests (9) ============
    function test_WithdrawUSDC() public {
        vm.startPrank(user1);
        usdc.approve(address(usdlProxy), 1000e6);
        usdlProxy.deposit(1000e6, user1);
        uint256 shares = usdlProxy.balanceOf(user1);
        uint256 usdcBefore = usdc.balanceOf(user1);
        usdlProxy.redeem(shares, user1, user1);
        vm.stopPrank();

        assertGt(usdc.balanceOf(user1), usdcBefore);
        assertEq(usdlProxy.balanceOf(user1), 0);
    }

    function test_WithdrawZeroAmountReverts() public {
        vm.prank(user1);
        vm.expectRevert(USDL.ZeroAmount.selector);
        usdlProxy.withdraw(0, user1, user1);
    }

    function test_WithdrawToZeroAddressReverts() public {
        vm.startPrank(user1);
        usdc.approve(address(usdlProxy), 1000e6);
        usdlProxy.deposit(1000e6, user1);
        vm.expectRevert(USDL.ZeroAddress.selector);
        usdlProxy.withdraw(100e6, address(0), user1);
        vm.stopPrank();
    }

    function test_WithdrawBlacklistedSenderReverts() public {
        vm.startPrank(user1);
        usdc.approve(address(usdlProxy), 1000e6);
        usdlProxy.deposit(1000e6, user1);
        vm.stopPrank();

        vm.prank(blacklister);
        usdlProxy.blacklist(user1);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(USDL.AddressBlacklisted.selector, user1));
        usdlProxy.withdraw(100e6, user1, user1);
    }

    function test_WithdrawBlacklistedReceiverReverts() public {
        vm.startPrank(user1);
        usdc.approve(address(usdlProxy), 1000e6);
        usdlProxy.deposit(1000e6, user1);
        vm.stopPrank();

        vm.prank(blacklister);
        usdlProxy.blacklist(user2);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(USDL.AddressBlacklisted.selector, user2));
        usdlProxy.withdraw(100e6, user2, user1);
    }

    function test_WithdrawBlacklistedOwnerReverts() public {
        vm.startPrank(user1);
        usdc.approve(address(usdlProxy), 1000e6);
        usdlProxy.deposit(1000e6, user1);
        usdlProxy.approve(user2, type(uint256).max);
        vm.stopPrank();

        vm.prank(blacklister);
        usdlProxy.blacklist(user1);

        vm.prank(user2);
        vm.expectRevert(abi.encodeWithSelector(USDL.AddressBlacklisted.selector, user1));
        usdlProxy.withdraw(100e6, user2, user1);
    }

    function test_WithdrawWithAllowance() public {
        vm.startPrank(user1);
        usdc.approve(address(usdlProxy), 1000e6);
        usdlProxy.deposit(1000e6, user1);
        usdlProxy.approve(user2, 500e6);
        vm.stopPrank();

        vm.prank(user2);
        usdlProxy.withdraw(100e6, user2, user1);

        assertGt(usdc.balanceOf(user2), INITIAL_USDC);
    }

    function test_WithdrawWhenPausedReverts() public {
        vm.startPrank(user1);
        usdc.approve(address(usdlProxy), 1000e6);
        usdlProxy.deposit(1000e6, user1);
        vm.stopPrank();

        vm.prank(pauser);
        usdlProxy.pause();

        vm.prank(user1);
        vm.expectRevert();
        usdlProxy.withdraw(100e6, user1, user1);
    }

    function test_WithdrawPartial() public {
        vm.startPrank(user1);
        usdc.approve(address(usdlProxy), 1000e6);
        usdlProxy.deposit(1000e6, user1);
        uint256 sharesBefore = usdlProxy.balanceOf(user1);
        usdlProxy.withdraw(100e6, user1, user1);
        vm.stopPrank();

        assertLt(usdlProxy.balanceOf(user1), sharesBefore);
        assertGt(usdlProxy.balanceOf(user1), 0);
    }

    // ============ Redeem Tests (5) ============
    function test_RedeemShares() public {
        vm.startPrank(user1);
        usdc.approve(address(usdlProxy), 1000e6);
        usdlProxy.deposit(1000e6, user1);
        uint256 shares = usdlProxy.balanceOf(user1);
        uint256 assets = usdlProxy.redeem(shares, user1, user1);
        vm.stopPrank();

        assertGt(assets, 0);
        assertEq(usdlProxy.balanceOf(user1), 0);
    }

    function test_RedeemZeroSharesReverts() public {
        vm.prank(user1);
        vm.expectRevert(USDL.ZeroAmount.selector);
        usdlProxy.redeem(0, user1, user1);
    }

    function test_RedeemToZeroAddressReverts() public {
        vm.startPrank(user1);
        usdc.approve(address(usdlProxy), 1000e6);
        usdlProxy.deposit(1000e6, user1);
        vm.expectRevert(USDL.ZeroAddress.selector);
        usdlProxy.redeem(100e6, address(0), user1);
        vm.stopPrank();
    }

    function test_RedeemWithAllowance() public {
        vm.startPrank(user1);
        usdc.approve(address(usdlProxy), 1000e6);
        usdlProxy.deposit(1000e6, user1);
        usdlProxy.approve(user2, 500e6);
        vm.stopPrank();

        vm.prank(user2);
        usdlProxy.redeem(100e6, user2, user1);
        assertGt(usdc.balanceOf(user2), INITIAL_USDC);
    }

    function test_RedeemPartial() public {
        vm.startPrank(user1);
        usdc.approve(address(usdlProxy), 1000e6);
        usdlProxy.deposit(1000e6, user1);
        uint256 shares = usdlProxy.balanceOf(user1);
        usdlProxy.redeem(shares / 2, user1, user1);
        vm.stopPrank();

        assertGt(usdlProxy.balanceOf(user1), 0);
    }

    // ============ Bridge Tests (11) ============
    function test_BridgeMint() public {
        vm.prank(bridge);
        usdlProxy.mint(user1, 1000e6);
        assertEq(usdlProxy.balanceOf(user1), 1000e6);
    }

    function test_BridgeMintZeroAddressReverts() public {
        vm.prank(bridge);
        vm.expectRevert(USDL.ZeroAddress.selector);
        usdlProxy.mint(address(0), 1000e6);
    }

    function test_BridgeMintZeroAmountReverts() public {
        vm.prank(bridge);
        vm.expectRevert(USDL.ZeroAmount.selector);
        usdlProxy.mint(user1, 0);
    }

    function test_BridgeMintToContractReverts() public {
        vm.prank(bridge);
        vm.expectRevert(abi.encodeWithSelector(USDL.InvalidRecipient.selector, address(usdlProxy)));
        usdlProxy.mint(address(usdlProxy), 1000e6);
    }

    function test_BridgeMintBlacklistedReverts() public {
        vm.prank(blacklister);
        usdlProxy.blacklist(user1);

        vm.prank(bridge);
        vm.expectRevert(abi.encodeWithSelector(USDL.AddressBlacklisted.selector, user1));
        usdlProxy.mint(user1, 1000e6);
    }

    function test_BridgeMintWhenPausedReverts() public {
        vm.prank(pauser);
        usdlProxy.pause();

        vm.prank(bridge);
        vm.expectRevert();
        usdlProxy.mint(user1, 1000e6);
    }

    function test_BridgeMintRequiresRole() public {
        vm.prank(owner);
        usdlProxy.revokeBridgeRole(bridge);

        vm.prank(bridge);
        vm.expectRevert();
        usdlProxy.mint(user1, 1000e6);
    }

    function test_BridgeBurn() public {
        vm.prank(bridge);
        usdlProxy.mint(user1, 1000e6);

        vm.prank(bridge);
        usdlProxy.burn(user1, 500e6);
        assertEq(usdlProxy.balanceOf(user1), 500e6);
    }

    function test_BridgeBurnZeroAddressReverts() public {
        vm.prank(bridge);
        vm.expectRevert(USDL.ZeroAddress.selector);
        usdlProxy.burn(address(0), 1000e6);
    }

    function test_BridgeBurnZeroAmountReverts() public {
        vm.prank(bridge);
        vm.expectRevert(USDL.ZeroAmount.selector);
        usdlProxy.burn(user1, 0);
    }

    function test_BridgeBurnNotBridgeReverts() public {
        vm.prank(user1);
        vm.expectRevert();
        usdlProxy.burn(user1, 1000e6);
    }

    function test_BridgeBurnSelfAmount() public {
        // First mint some tokens to bridge
        vm.prank(bridge);
        usdlProxy.mint(bridge, 1000e6);
        assertEq(usdlProxy.balanceOf(bridge), 1000e6);

        // Bridge burns from own balance using burn(uint256)
        vm.prank(bridge);
        usdlProxy.burn(500e6);
        assertEq(usdlProxy.balanceOf(bridge), 500e6);
    }

    function test_BridgeBurnSelfZeroAmountReverts() public {
        vm.prank(bridge);
        vm.expectRevert(USDL.ZeroAmount.selector);
        usdlProxy.burn(0);
    }

    function test_BridgeBurnFrom() public {
        // User deposits to get tokens
        vm.startPrank(user1);
        usdc.approve(address(usdlProxy), 1000e6);
        usdlProxy.deposit(1000e6, user1);

        // User approves bridge to burn
        usdlProxy.approve(bridge, 500e6);
        vm.stopPrank();

        uint256 balanceBefore = usdlProxy.balanceOf(user1);

        // Bridge burns using burnFrom
        vm.prank(bridge);
        usdlProxy.burnFrom(user1, 500e6);

        assertEq(usdlProxy.balanceOf(user1), balanceBefore - 500e6);
    }

    function test_BridgeBurnFromZeroAddressReverts() public {
        vm.prank(bridge);
        vm.expectRevert(USDL.ZeroAddress.selector);
        usdlProxy.burnFrom(address(0), 1000e6);
    }

    function test_BridgeBurnFromZeroAmountReverts() public {
        vm.prank(bridge);
        vm.expectRevert(USDL.ZeroAmount.selector);
        usdlProxy.burnFrom(user1, 0);
    }

    // ============ Yield Asset Tests (12) ============
    function test_AddYieldAsset() public {
        vm.prank(manager);
        usdlProxy.addYieldAsset(address(yieldVault), address(usdc), address(yieldVault), 10000, AssetType.ERC4626);

        assertEq(usdlProxy.getYieldAssetCount(), 1);
        USDL.YieldAsset memory asset = usdlProxy.getYieldAsset(address(yieldVault));
        assertEq(asset.token, address(yieldVault));
        assertTrue(asset.active);
    }

    function test_AddYieldAssetZeroTokenReverts() public {
        vm.prank(manager);
        vm.expectRevert(USDL.ZeroAddress.selector);
        usdlProxy.addYieldAsset(address(0), address(usdc), address(yieldVault), 10000, AssetType.ERC4626);
    }

    function test_AddYieldAssetZeroDepositTokenReverts() public {
        vm.prank(manager);
        vm.expectRevert(USDL.ZeroAddress.selector);
        usdlProxy.addYieldAsset(address(yieldVault), address(0), address(yieldVault), 10000, AssetType.ERC4626);
    }

    function test_AddYieldAssetZeroManagerReverts() public {
        vm.prank(manager);
        vm.expectRevert(USDL.ZeroAddress.selector);
        usdlProxy.addYieldAsset(address(yieldVault), address(usdc), address(0), 10000, AssetType.ERC4626);
    }

    function test_AddYieldAssetDuplicateReverts() public {
        vm.startPrank(manager);
        usdlProxy.addYieldAsset(address(yieldVault), address(usdc), address(yieldVault), 10000, AssetType.ERC4626);
        vm.expectRevert(abi.encodeWithSelector(USDL.AssetAlreadyExists.selector, address(yieldVault)));
        usdlProxy.addYieldAsset(address(yieldVault), address(usdc), address(yieldVault), 10000, AssetType.ERC4626);
        vm.stopPrank();
    }

    function test_AddYieldAssetNotManagerReverts() public {
        vm.prank(user1);
        vm.expectRevert();
        usdlProxy.addYieldAsset(address(yieldVault), address(usdc), address(yieldVault), 10000, AssetType.ERC4626);
    }

    function test_AddMultipleYieldAssets() public {
        vm.startPrank(manager);
        usdlProxy.addYieldAsset(address(yieldVault), address(usdc), address(yieldVault), 5000, AssetType.ERC4626);
        usdlProxy.addYieldAsset(address(yieldVault2), address(usdc), address(yieldVault2), 5000, AssetType.ERC4626);
        vm.stopPrank();

        assertEq(usdlProxy.getYieldAssetCount(), 2);
    }

    function test_AddYieldAssetAllocationOver100Reverts() public {
        vm.startPrank(manager);
        usdlProxy.addYieldAsset(address(yieldVault), address(usdc), address(yieldVault), 6000, AssetType.ERC4626);
        vm.expectRevert(abi.encodeWithSelector(USDL.InvalidAllocation.selector, 11000));
        usdlProxy.addYieldAsset(address(yieldVault2), address(usdc), address(yieldVault2), 5000, AssetType.ERC4626);
        vm.stopPrank();
    }

    function test_UpdateYieldAssetAllocation() public {
        vm.startPrank(manager);
        usdlProxy.addYieldAsset(address(yieldVault), address(usdc), address(yieldVault), 5000, AssetType.ERC4626);
        usdlProxy.updateYieldAssetAllocation(address(yieldVault), 8000);
        vm.stopPrank();

        USDL.YieldAsset memory asset = usdlProxy.getYieldAsset(address(yieldVault));
        assertEq(asset.allocation, 8000);
    }

    function test_UpdateYieldAssetAllocationNotFoundReverts() public {
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(USDL.AssetNotFound.selector, address(yieldVault)));
        usdlProxy.updateYieldAssetAllocation(address(yieldVault), 5000);
    }

    function test_DeactivateYieldAsset() public {
        vm.startPrank(manager);
        usdlProxy.addYieldAsset(address(yieldVault), address(usdc), address(yieldVault), 10000, AssetType.ERC4626);
        usdlProxy.deactivateYieldAsset(address(yieldVault));
        vm.stopPrank();

        USDL.YieldAsset memory asset = usdlProxy.getYieldAsset(address(yieldVault));
        assertFalse(asset.active);
    }

    function test_DeactivateYieldAssetNotFoundReverts() public {
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(USDL.AssetNotFound.selector, address(yieldVault)));
        usdlProxy.deactivateYieldAsset(address(yieldVault));
    }

    // M-02 Fix: Test removeYieldAsset function
    function test_RemoveYieldAsset() public {
        vm.startPrank(manager);
        usdlProxy.addYieldAsset(address(yieldVault), address(usdc), address(yieldVault), 10000, AssetType.ERC4626);

        // Should be in the list
        assertEq(usdlProxy.getYieldAssetCount(), 1);

        // Remove it (no funds in it)
        usdlProxy.removeYieldAsset(address(yieldVault));
        vm.stopPrank();

        // Should be completely removed
        assertEq(usdlProxy.getYieldAssetCount(), 0);
        USDL.YieldAsset memory asset = usdlProxy.getYieldAsset(address(yieldVault));
        assertEq(asset.token, address(0), "Asset should be deleted");
    }

    function test_RemoveYieldAssetWithFundsReverts() public {
        vm.prank(manager);
        usdlProxy.addYieldAsset(address(yieldVault), address(usdc), address(yieldVault), 10000, AssetType.ERC4626);

        // Deposit so funds go to yield asset
        vm.startPrank(user1);
        usdc.approve(address(usdlProxy), 1000e6);
        usdlProxy.deposit(1000e6, user1);
        vm.stopPrank();

        // Try to remove - should revert because funds exist
        vm.prank(manager);
        vm.expectRevert("Withdraw funds first");
        usdlProxy.removeYieldAsset(address(yieldVault));
    }

    function test_RemoveYieldAssetNotFoundReverts() public {
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(USDL.AssetNotFound.selector, address(yieldVault)));
        usdlProxy.removeYieldAsset(address(yieldVault));
    }

    // ============ Yield Accrual Tests (4) ============
    function test_RebaseIndexIncreasesWithYield() public {
        vm.prank(manager);
        usdlProxy.addYieldAsset(address(yieldVault), address(usdc), address(yieldVault), 10000, AssetType.ERC4626);

        vm.startPrank(user1);
        usdc.approve(address(usdlProxy), 1000e6);
        usdlProxy.deposit(1000e6, user1);
        vm.stopPrank();

        uint256 rebaseIndexBefore = usdlProxy.getRebaseIndex();
        uint256 balanceBefore = usdlProxy.balanceOf(user1);

        // Simulate yield in the underlying vault
        yieldVault.setYieldMultiplier(1.1e18);

        // Accrue yield to update internal accounting and rebase index
        vm.prank(manager);
        usdlProxy.accrueYield();

        uint256 rebaseIndexAfter = usdlProxy.getRebaseIndex();
        uint256 balanceAfter = usdlProxy.balanceOf(user1);

        assertGt(rebaseIndexAfter, rebaseIndexBefore, "Rebase index should increase after yield accrual");
        assertGt(balanceAfter, balanceBefore, "User balance should increase after yield accrual");

        // Share price stays ~1:1 because both totalAssets and totalSupply increase
        uint256 sharePriceAfter = usdlProxy.sharePrice();
        assertApproxEqAbs(sharePriceAfter, 1e6, 1000, "Share price stays ~1:1 with rebasing");
    }

    function test_TotalAssetsReflectsYield() public {
        vm.prank(manager);
        usdlProxy.addYieldAsset(address(yieldVault), address(usdc), address(yieldVault), 10000, AssetType.ERC4626);

        vm.startPrank(user1);
        usdc.approve(address(usdlProxy), 1000e6);
        usdlProxy.deposit(1000e6, user1);
        vm.stopPrank();

        uint256 before = usdlProxy.totalAssets();

        // Simulate yield in the underlying vault
        yieldVault.setYieldMultiplier(1.1e18);

        // Accrue yield to update internal accounting
        vm.prank(manager);
        usdlProxy.accrueYield();

        assertGt(usdlProxy.totalAssets(), before, "Total assets should increase after yield accrual");
    }

    function test_AccrueYieldHarvestsUSDC() public {
        _addDefaultYieldAsset();
        _userDeposit(user1, 1000e6);

        uint256 netDeposited = usdlProxy.totalAssets();
        assertEq(usdc.balanceOf(address(usdlProxy)), 0, "all funds allocated to yield assets");

        uint256 multiplier = 1.05e18;
        yieldVault.setYieldMultiplier(multiplier);

        vm.prank(manager);
        usdlProxy.accrueYield();

        uint256 expectedYield = (netDeposited * (multiplier - 1e18)) / 1e18;
        assertApproxEqAbs(usdc.balanceOf(address(usdlProxy)), expectedYield, 1, "harvested yield should sit in USDC");
        assertEq(usdlProxy.totalAssets(), netDeposited + expectedYield, "accounting reflects realized yield");
    }

    function test_DepositAllocatesToYieldAsset() public {
        vm.prank(manager);
        usdlProxy.addYieldAsset(address(yieldVault), address(usdc), address(yieldVault), 10000, AssetType.ERC4626);

        vm.startPrank(user1);
        usdc.approve(address(usdlProxy), 1000e6);
        usdlProxy.deposit(1000e6, user1);
        vm.stopPrank();

        assertGt(yieldVault.balanceOf(address(usdlProxy)), 0);
    }

    function test_TotalAssetsWithNoYieldAssets() public {
        vm.startPrank(user1);
        usdc.approve(address(usdlProxy), 1000e6);
        usdlProxy.deposit(1000e6, user1);
        vm.stopPrank();

        uint256 fee = (1000e6 * 10) / 10000;
        assertEq(usdlProxy.totalAssets(), 1000e6 - fee);
    }

    // ============ Donation Attack Protection Tests ============
    function test_DonationDoesNotAffectTotalAssets() public {
        // User1 deposits
        vm.startPrank(user1);
        usdc.approve(address(usdlProxy), 1000e6);
        usdlProxy.deposit(1000e6, user1);
        vm.stopPrank();

        uint256 totalAssetsBefore = usdlProxy.totalAssets();
        uint256 sharePriceBefore = usdlProxy.sharePrice();

        // Attacker donates USDC directly to contract
        usdc.mint(address(usdlProxy), 1000e6);

        // Total assets should NOT change (internal accounting)
        assertEq(usdlProxy.totalAssets(), totalAssetsBefore, "Donation should not affect totalAssets");
        assertEq(usdlProxy.sharePrice(), sharePriceBefore, "Donation should not affect share price");
    }

    function test_DonationDoesNotAffectGetPrice() public {
        // User1 deposits
        vm.startPrank(user1);
        usdc.approve(address(usdlProxy), 1000e6);
        usdlProxy.deposit(1000e6, user1);
        vm.stopPrank();

        uint256 priceBefore = usdlProxy.getPrice();

        // Attacker donates USDC directly to contract (trying to inflate price)
        usdc.mint(address(usdlProxy), 10000e6); // 10x the deposit!

        uint256 priceAfter = usdlProxy.getPrice();

        // Price should NOT change
        assertEq(priceAfter, priceBefore, "Donation should not affect getPrice");
    }

    function test_DonationDoesNotAffectNewDepositors() public {
        // User1 deposits first
        vm.startPrank(user1);
        usdc.approve(address(usdlProxy), 1000e6);
        uint256 user1Shares = usdlProxy.deposit(1000e6, user1);
        vm.stopPrank();

        // Attacker donates USDC directly
        usdc.mint(address(usdlProxy), 5000e6);

        // User2 deposits same amount - should get same shares (minus any fee variance)
        vm.startPrank(user2);
        usdc.approve(address(usdlProxy), 1000e6);
        uint256 user2Shares = usdlProxy.deposit(1000e6, user2);
        vm.stopPrank();

        // Shares should be approximately equal (donation didn't affect exchange rate)
        assertEq(user2Shares, user1Shares, "Donation should not affect share calculation for new depositors");
    }

    function test_RescueDonatedTokens() public {
        // User1 deposits
        vm.startPrank(user1);
        usdc.approve(address(usdlProxy), 1000e6);
        usdlProxy.deposit(1000e6, user1);
        vm.stopPrank();

        // Someone donates USDC directly to contract
        usdc.mint(address(usdlProxy), 500e6);

        // Admin rescues the donated tokens
        uint256 treasuryBefore = usdc.balanceOf(treasury);
        vm.prank(owner);
        usdlProxy.rescueDonatedTokens(treasury);
        uint256 treasuryAfter = usdc.balanceOf(treasury);

        assertEq(treasuryAfter - treasuryBefore, 500e6, "Donated tokens should be rescued");
    }

    function test_RescueDonatedTokensNotAdmin() public {
        vm.prank(user1);
        vm.expectRevert();
        usdlProxy.rescueDonatedTokens(user1);
    }

    // ============ Bridge Mint/Burn Internal Accounting Tests ============
    function test_BridgeMintDoesNotInflateSharePrice() public {
        // User1 deposits normally
        vm.startPrank(user1);
        usdc.approve(address(usdlProxy), 1000e6);
        usdlProxy.deposit(1000e6, user1);
        vm.stopPrank();

        uint256 sharePriceBefore = usdlProxy.sharePrice();

        // Bridge mints shares (without backing assets)
        vm.prank(owner);
        usdlProxy.grantBridgeRole(bridge);

        vm.prank(bridge);
        usdlProxy.mint(user2, 1000e6);

        // Share price should DECREASE (more shares, same assets)
        // This is correct behavior - bridge mints dilute share price
        // The key is that attackers can't profit from this
        uint256 sharePriceAfter = usdlProxy.sharePrice();
        assertLt(sharePriceAfter, sharePriceBefore, "Bridge mint should decrease share price");
    }

    function test_BridgeBurnDoesNotAffectTotalAssets() public {
        // User1 deposits normally
        vm.startPrank(user1);
        usdc.approve(address(usdlProxy), 1000e6);
        usdlProxy.deposit(1000e6, user1);
        vm.stopPrank();

        uint256 totalAssetsBefore = usdlProxy.totalAssets();

        // Setup bridge
        vm.prank(owner);
        usdlProxy.grantBridgeRole(bridge);

        // Bridge burns some of user1's shares (simulating cross-chain transfer out)
        vm.prank(bridge);
        usdlProxy.burn(user1, 500e6);

        // Total assets should NOT change (internal accounting tracks deposits, not supply)
        uint256 totalAssetsAfter = usdlProxy.totalAssets();
        assertEq(totalAssetsAfter, totalAssetsBefore, "Bridge burn should not affect totalAssets");
    }

    function test_BridgeBurnIncreasesSharePrice() public {
        // User1 deposits normally
        vm.startPrank(user1);
        usdc.approve(address(usdlProxy), 1000e6);
        usdlProxy.deposit(1000e6, user1);
        vm.stopPrank();

        uint256 priceBefore = usdlProxy.getPrice();

        // Setup bridge
        vm.prank(owner);
        usdlProxy.grantBridgeRole(bridge);

        // Bridge burns some shares (simulating cross-chain transfer out)
        vm.prank(bridge);
        usdlProxy.burn(user1, 500e6);

        // Price should INCREASE (fewer shares, same assets)
        uint256 priceAfter = usdlProxy.getPrice();
        assertGt(priceAfter, priceBefore, "Bridge burn should increase share price (fewer shares for same assets)");
    }

    function test_BridgeMintBurnCycleAccountingCorrect() public {
        // User1 deposits
        vm.startPrank(user1);
        usdc.approve(address(usdlProxy), 1000e6);
        usdlProxy.deposit(1000e6, user1);
        vm.stopPrank();

        uint256 initialTotalAssets = usdlProxy.totalAssets();
        uint256 initialSupply = usdlProxy.totalSupply();
        uint256 initialPrice = usdlProxy.getPrice();

        // Setup bridge
        vm.prank(owner);
        usdlProxy.grantBridgeRole(bridge);

        // Simulate bridging out (burn on source chain)
        vm.prank(bridge);
        usdlProxy.burn(user1, 300e6);

        // Simulate bridging in (mint on destination chain, but we're simulating it here)
        vm.prank(bridge);
        usdlProxy.mint(user2, 300e6);

        // After complete cycle: supply should be back to initial
        assertEq(usdlProxy.totalSupply(), initialSupply, "Supply should be restored after mint/burn cycle");

        // Total assets should be unchanged (internal accounting)
        assertEq(usdlProxy.totalAssets(), initialTotalAssets, "Total assets unchanged after bridge cycle");

        // Price should be restored
        assertEq(usdlProxy.getPrice(), initialPrice, "Price should be restored after bridge cycle");
    }

    function test_MultipleBridgeOperationsAccountingCorrect() public {
        // User1 deposits
        vm.startPrank(user1);
        usdc.approve(address(usdlProxy), 2000e6);
        usdlProxy.deposit(2000e6, user1);
        vm.stopPrank();

        uint256 initialTotalAssets = usdlProxy.totalAssets();

        // Setup bridge
        vm.prank(owner);
        usdlProxy.grantBridgeRole(bridge);

        // Multiple bridge mints (simulating incoming cross-chain transfers)
        vm.startPrank(bridge);
        usdlProxy.mint(user2, 500e6);
        usdlProxy.mint(user2, 300e6);
        usdlProxy.mint(user2, 200e6);
        vm.stopPrank();

        // Total assets should NOT change
        assertEq(usdlProxy.totalAssets(), initialTotalAssets, "Multiple bridge mints should not affect totalAssets");

        // Now bridge burns
        vm.startPrank(bridge);
        usdlProxy.burn(user2, 1000e6); // Burn all that was minted
        vm.stopPrank();

        // Total assets still unchanged
        assertEq(usdlProxy.totalAssets(), initialTotalAssets, "Bridge burns should not affect totalAssets");
    }

    function test_WithdrawAfterBridgeMintCalculatesCorrectly() public {
        // User1 deposits 1000 USDC
        vm.startPrank(user1);
        usdc.approve(address(usdlProxy), 1000e6);
        usdlProxy.deposit(1000e6, user1);
        vm.stopPrank();

        uint256 user1Shares = usdlProxy.balanceOf(user1);
        uint256 fee = (1000e6 * 10) / 10000; // 0.1% fee
        uint256 expectedAssets = 1000e6 - fee; // ~999 USDC

        // Setup bridge and mint extra shares to user2
        vm.prank(owner);
        usdlProxy.grantBridgeRole(bridge);

        vm.prank(bridge);
        usdlProxy.mint(user2, 1000e6);

        // Now user1 tries to redeem all their shares
        // They should get proportional share of totalDepositedAssets
        // totalDepositedAssets = 999 USDC, totalSupply = ~1999 shares
        // user1 has ~999 shares, so they get 999 * 999 / 1999 ≈ 499.75 USDC

        uint256 expectedRedeemAmount = (user1Shares * usdlProxy.totalAssets()) / usdlProxy.totalSupply();

        vm.prank(user1);
        uint256 actualAssets = usdlProxy.redeem(user1Shares, user1, user1);

        assertEq(actualAssets, expectedRedeemAmount, "Redeem should return correct proportional amount");
        // Since bridge minted unbacked shares, user1 gets less than they deposited
        assertLt(actualAssets, expectedAssets, "User should get less due to dilution from unbacked bridge mints");
    }

    function test_InternalAccountingAfterComplexOperations() public {
        // Setup yield asset
        vm.prank(manager);
        usdlProxy.addYieldAsset(address(yieldVault), address(usdc), address(yieldVault), 10000, AssetType.ERC4626);

        // User1 deposits
        vm.startPrank(user1);
        usdc.approve(address(usdlProxy), 1000e6);
        usdlProxy.deposit(1000e6, user1);
        vm.stopPrank();

        uint256 afterDeposit = usdlProxy.totalAssets();

        // Donation attack
        usdc.mint(address(usdlProxy), 5000e6);
        assertEq(usdlProxy.totalAssets(), afterDeposit, "Donation should not affect totalAssets");

        // Bridge mint attack
        vm.prank(owner);
        usdlProxy.grantBridgeRole(bridge);
        vm.prank(bridge);
        usdlProxy.mint(user2, 10000e6);
        assertEq(usdlProxy.totalAssets(), afterDeposit, "Bridge mint should not affect totalAssets");

        // Yield accrual
        yieldVault.setYieldMultiplier(1.1e18);
        vm.prank(manager);
        usdlProxy.accrueYield();

        // Now totalAssets should be higher (yield)
        assertGt(usdlProxy.totalAssets(), afterDeposit, "Yield should increase totalAssets");

        // Bridge burn
        vm.prank(bridge);
        usdlProxy.burn(user2, 5000e6);

        // Total assets unchanged by burn
        uint256 afterYield = usdlProxy.totalAssets();
        assertGt(afterYield, afterDeposit, "Total assets still reflects yield after bridge burn");
    }

    function test_AccrueYieldOnlyManager() public {
        vm.prank(user1);
        vm.expectRevert();
        usdlProxy.accrueYield();
    }

    // ============ Automation Tests (5) ============

    function test_CheckUpkeepFalseBeforeInterval() public {
        _addDefaultYieldAsset();
        _userDeposit(user1, 1_000e6);
        yieldVault.setYieldMultiplier(1.1e18);

        (bool upkeepNeeded,) = usdlProxy.checkUpkeep("");
        assertFalse(upkeepNeeded);
    }

    function test_CheckUpkeepFalseWithoutYield() public {
        _addDefaultYieldAsset();
        _userDeposit(user1, 1_000e6);
        _warpPastInterval();

        (bool upkeepNeeded,) = usdlProxy.checkUpkeep("");
        assertFalse(upkeepNeeded);
    }

    function test_PerformUpkeepAccruesYield() public {
        _addDefaultYieldAsset();
        _userDeposit(user1, 1_000e6);
        yieldVault.setYieldMultiplier(1.1e18);
        _warpPastInterval();

        uint256 beforeAssets = usdlProxy.totalAssets();
        usdlProxy.performUpkeep("");
        uint256 afterAssets = usdlProxy.totalAssets();

        assertGt(afterAssets, beforeAssets, "automation should accrue yield");
    }

    function test_PerformUpkeepRevertsWhenNotNeeded() public {
        _addDefaultYieldAsset();
        _userDeposit(user1, 1_000e6);

        vm.expectRevert(USDL.UpkeepNotNeeded.selector);
        usdlProxy.performUpkeep("");
    }

    function test_SetYieldAccrualIntervalValidationAndDisable() public {
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(USDL.AutomationIntervalTooShort.selector, 10));
        usdlProxy.setYieldAccrualInterval(10);

        usdlProxy.setYieldAccrualInterval(0);
        vm.stopPrank();

        _addDefaultYieldAsset();
        _userDeposit(user1, 1_000e6);
        yieldVault.setYieldMultiplier(1.1e18);

        vm.warp(block.timestamp + 30 days);
        (bool upkeepNeeded,) = usdlProxy.checkUpkeep("");
        assertFalse(upkeepNeeded, "automation disabled via interval = 0");
    }

    // ============ Blacklist Tests (6) ============
    function test_Blacklist() public {
        vm.prank(blacklister);
        usdlProxy.blacklist(user1);
        assertTrue(usdlProxy.blacklisted(user1));
    }

    function test_BlacklistZeroAddressReverts() public {
        vm.prank(blacklister);
        vm.expectRevert(USDL.ZeroAddress.selector);
        usdlProxy.blacklist(address(0));
    }

    function test_BlacklistNotBlacklisterReverts() public {
        vm.prank(user1);
        vm.expectRevert();
        usdlProxy.blacklist(user2);
    }

    function test_Unblacklist() public {
        vm.startPrank(blacklister);
        usdlProxy.blacklist(user1);
        usdlProxy.unblacklist(user1);
        vm.stopPrank();
        assertFalse(usdlProxy.blacklisted(user1));
    }

    function test_UnblacklistZeroAddressReverts() public {
        vm.prank(blacklister);
        vm.expectRevert(USDL.ZeroAddress.selector);
        usdlProxy.unblacklist(address(0));
    }

    function test_BlacklistedCannotTransfer() public {
        vm.startPrank(user1);
        usdc.approve(address(usdlProxy), 1000e6);
        usdlProxy.deposit(1000e6, user1);
        vm.stopPrank();

        vm.prank(blacklister);
        usdlProxy.blacklist(user1);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(USDL.AddressBlacklisted.selector, user1));
        usdlProxy.transfer(user2, 100e6);
    }

    // ============ Fee Tests (6) ============
    function test_SetDepositFee() public {
        vm.prank(owner);
        usdlProxy.setDepositFee(50);
        assertEq(usdlProxy.depositFeeBps(), 50);
    }

    function test_SetDepositFeeEmitsEvent() public {
        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit USDL.DepositFeeUpdated(10, 50);
        usdlProxy.setDepositFee(50);
    }

    function test_SetDepositFeeTooHighReverts() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(USDL.InvalidFee.selector, 600));
        usdlProxy.setDepositFee(600);
    }

    function test_SetDepositFeeZeroAllowed() public {
        vm.prank(owner);
        usdlProxy.setDepositFee(0);
        assertEq(usdlProxy.depositFeeBps(), 0);
    }

    function test_SetDepositFeeMax() public {
        vm.prank(owner);
        usdlProxy.setDepositFee(500);
        assertEq(usdlProxy.depositFeeBps(), 500);
    }

    function test_SetDepositFeeNotAdminReverts() public {
        vm.prank(user1);
        vm.expectRevert();
        usdlProxy.setDepositFee(50);
    }

    function test_DepositFeeExactCalculation() public {
        // Default fee is 10 bps (0.1%)
        uint256 depositAmount = 1000e6; // 1000 USDC
        uint256 expectedFee = (depositAmount * 10) / 10000; // 0.1 USDC = 100000
        uint256 expectedNetAssets = depositAmount - expectedFee; // 999.9 USDC = 999900000

        uint256 treasuryBefore = usdc.balanceOf(treasury);

        vm.startPrank(user1);
        usdc.approve(address(usdlProxy), depositAmount);
        uint256 shares = usdlProxy.deposit(depositAmount, user1);
        vm.stopPrank();

        uint256 treasuryAfter = usdc.balanceOf(treasury);

        // Verify exact fee sent to treasury
        assertEq(treasuryAfter - treasuryBefore, expectedFee, "Fee to treasury incorrect");
        // Verify shares equal net assets (1:1 ratio on first deposit)
        assertEq(shares, expectedNetAssets, "Shares incorrect");
        // Verify total assets in vault equals net assets
        assertEq(usdlProxy.totalAssets(), expectedNetAssets, "Total assets incorrect");
    }

    function test_MintFeeExactCalculation() public {
        // Default fee is 10 bps (0.1%)
        uint256 sharesToMint = 1000e6; // Want exactly 1000e6 shares

        // Calculate expected assets: netAssets = sharesToMint (1:1 ratio when empty)
        // fee = netAssets * 10 / (10000 - 10) = netAssets * 10 / 9990
        uint256 expectedNetAssets = sharesToMint;
        uint256 expectedFee = (expectedNetAssets * 10) / 9990; // Should be ~1001001
        uint256 expectedTotalAssets = expectedNetAssets + expectedFee;

        uint256 treasuryBefore = usdc.balanceOf(treasury);

        vm.startPrank(user1);
        usdc.approve(address(usdlProxy), expectedTotalAssets + 1e6); // Extra for safety
        uint256 assetsSpent = usdlProxy.mint(sharesToMint, user1);
        vm.stopPrank();

        uint256 treasuryAfter = usdc.balanceOf(treasury);

        // Verify exact shares received
        assertEq(usdlProxy.balanceOf(user1), sharesToMint, "Shares received incorrect");
        // Verify assets spent matches calculation
        assertEq(assetsSpent, expectedTotalAssets, "Assets spent incorrect");
        // Verify fee sent to treasury
        assertEq(treasuryAfter - treasuryBefore, expectedFee, "Fee to treasury incorrect");
    }

    function test_DepositAndMintSymmetry() public {
        // Test that deposit(X) and mint(previewDeposit(X)) produce same results
        uint256 depositAmount = 1000e6;

        // First: deposit
        vm.startPrank(user1);
        usdc.approve(address(usdlProxy), depositAmount);
        uint256 sharesFromDeposit = usdlProxy.deposit(depositAmount, user1);
        vm.stopPrank();

        // Calculate what mint would need for same shares
        // netAssets for those shares = sharesFromDeposit (1:1 initially)
        // But now there are assets in vault, so ratio is established

        uint256 assetsNeeded = usdlProxy.previewMint(sharesFromDeposit);
        uint256 feeForMint = (assetsNeeded * 10) / 9990;
        uint256 totalForMint = assetsNeeded + feeForMint;

        // Second user: mint same number of shares
        vm.startPrank(user2);
        usdc.approve(address(usdlProxy), totalForMint + 1e6);
        uint256 assetsForMint = usdlProxy.mint(sharesFromDeposit, user2);
        vm.stopPrank();

        // Both users should have same shares
        assertEq(usdlProxy.balanceOf(user2), sharesFromDeposit, "Shares mismatch");
        // Verify assets spent is close to our calculated totalForMint (may differ slightly due to rounding)
        assertApproxEqAbs(assetsForMint, totalForMint, 1, "Assets for mint should match calculated total");
    }

    function test_FeeWithYieldAccrual() public {
        // First: Add yield asset
        vm.prank(owner);
        usdlProxy.addYieldAsset(address(yieldVault), address(usdc), address(yieldVault), 10000, AssetType.ERC4626);

        // First deposit - goes to yield vault
        vm.startPrank(user1);
        usdc.approve(address(usdlProxy), 1000e6);
        uint256 user1Shares = usdlProxy.deposit(1000e6, user1);
        vm.stopPrank();

        uint256 user1Fee = (1000e6 * 10) / 10000; // 0.1 USDC
        uint256 user1NetAssets = 1000e6 - user1Fee; // 999.9 USDC
        assertEq(user1Shares, user1NetAssets, "User1 shares should equal net assets on first deposit");

        // Record initial values
        uint256 totalAssetsBefore = usdlProxy.totalAssets();
        uint256 user1BalanceBefore = usdlProxy.balanceOf(user1);
        uint256 rebaseIndexBefore = usdlProxy.getRebaseIndex();

        // Simulate 10% yield (multiply by 1.1)
        yieldVault.setYieldMultiplier(1.1e18);

        // Accrue yield to update internal accounting
        vm.prank(manager);
        usdlProxy.accrueYield();

        // Now total assets should be higher (yield accrued)
        uint256 totalAssetsAfter = usdlProxy.totalAssets();
        assertGt(totalAssetsAfter, totalAssetsBefore, "Total assets should increase with yield");

        // With rebasing: rebaseIndex increases, user balance increases
        uint256 rebaseIndexAfter = usdlProxy.getRebaseIndex();
        uint256 user1BalanceAfter = usdlProxy.balanceOf(user1);
        assertGt(rebaseIndexAfter, rebaseIndexBefore, "Rebase index should increase");
        assertGt(user1BalanceAfter, user1BalanceBefore, "User balance should increase with yield");

        // Second deposit - user gets shares at current rebase index
        uint256 depositAmount = 1000e6;
        uint256 fee = (depositAmount * 10) / 10000;
        uint256 netAssets = depositAmount - fee;

        vm.startPrank(user2);
        usdc.approve(address(usdlProxy), depositAmount);
        uint256 shares = usdlProxy.deposit(depositAmount, user2);
        vm.stopPrank();

        // With rebasing token: shares are calculated using rebased totalSupply
        // Raw shares = netAssets * totalSupply / totalDepositedAssets
        // Then balanceOf returns rawShares * rebaseIndex / PRECISION
        // The end result is that user2's balance reflects the current rebase index
        uint256 user2Balance = usdlProxy.balanceOf(user2);
        uint256 user2RawShares = usdlProxy.sharesOf(user2);

        // User2's raw shares should approximately equal netAssets adjusted for current ratio
        // And their rebased balance = rawShares * rebaseIndex / 1e6
        uint256 expectedBalance = (user2RawShares * rebaseIndexAfter) / 1e6;
        assertApproxEqAbs(user2Balance, expectedBalance, 1000, "User2 balance should match shares * rebaseIndex");

        // The raw shares should be approximately netAssets (since totalSupply/totalDepositedAssets ≈ 1)
        assertGt(shares, 0, "User2 should receive shares");
    }

    // ============ Pause Tests (4) ============
    function test_Pause() public {
        vm.prank(pauser);
        usdlProxy.pause();
        assertTrue(usdlProxy.paused());
    }

    function test_PauseNotPauserReverts() public {
        vm.prank(user1);
        vm.expectRevert();
        usdlProxy.pause();
    }

    function test_Unpause() public {
        vm.startPrank(pauser);
        usdlProxy.pause();
        usdlProxy.unpause();
        vm.stopPrank();
        assertFalse(usdlProxy.paused());
    }

    function test_UnpauseNotPauserReverts() public {
        vm.prank(pauser);
        usdlProxy.pause();

        vm.prank(user1);
        vm.expectRevert();
        usdlProxy.unpause();
    }

    // ============ Admin Tests (16) ============
    function test_SetTreasury() public {
        vm.prank(owner);
        usdlProxy.setTreasury(address(0x999));
        assertEq(usdlProxy.treasury(), address(0x999));
    }

    function test_SetTreasuryEmitsEvent() public {
        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit USDL.TreasuryUpdated(treasury, address(0x999));
        usdlProxy.setTreasury(address(0x999));
    }

    function test_SetTreasuryZeroAddressReverts() public {
        vm.prank(owner);
        vm.expectRevert(USDL.ZeroAddress.selector);
        usdlProxy.setTreasury(address(0));
    }

    function test_SetTreasuryNotAdminReverts() public {
        vm.prank(user1);
        vm.expectRevert();
        usdlProxy.setTreasury(address(0x999));
    }

    function test_SetCCIPAdmin() public {
        vm.prank(owner);
        usdlProxy.setCCIPAdmin(address(0x888));
        assertEq(usdlProxy.getCCIPAdmin(), address(0x888));
    }

    function test_SetCCIPAdminEmitsEvent() public {
        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit USDL.CCIPAdminTransferred(owner, address(0x888));
        usdlProxy.setCCIPAdmin(address(0x888));
    }

    function test_SetCCIPAdminZeroAddressReverts() public {
        vm.prank(owner);
        vm.expectRevert(USDL.ZeroAddress.selector);
        usdlProxy.setCCIPAdmin(address(0));
    }

    function test_SetCCIPAdminNotAdminReverts() public {
        vm.prank(user1);
        vm.expectRevert();
        usdlProxy.setCCIPAdmin(address(0x888));
    }

    function test_GrantBridgeRole() public {
        vm.prank(owner);
        usdlProxy.grantBridgeRole(address(0x777));
        assertTrue(usdlProxy.hasRole(usdlProxy.BRIDGE_ROLE(), address(0x777)));
    }

    function test_GrantBridgeRoleZeroAddressReverts() public {
        vm.prank(owner);
        vm.expectRevert(USDL.ZeroAddress.selector);
        usdlProxy.grantBridgeRole(address(0));
    }

    function test_RevokeBridgeRole() public {
        vm.prank(owner);
        usdlProxy.revokeBridgeRole(bridge);
        assertFalse(usdlProxy.hasRole(usdlProxy.BRIDGE_ROLE(), bridge));
    }

    function test_RevokeBridgeRoleZeroAddressReverts() public {
        vm.prank(owner);
        vm.expectRevert(USDL.ZeroAddress.selector);
        usdlProxy.revokeBridgeRole(address(0));
    }

    function test_EmergencyWithdraw() public {
        usdc.mint(address(usdlProxy), 1000e6);
        uint256 before = usdc.balanceOf(treasury);

        vm.prank(owner);
        usdlProxy.emergencyWithdraw(address(usdc), treasury, 1000e6);

        assertEq(usdc.balanceOf(treasury), before + 1000e6);
    }

    function test_EmergencyWithdrawZeroTokenReverts() public {
        vm.prank(owner);
        vm.expectRevert(USDL.ZeroAddress.selector);
        usdlProxy.emergencyWithdraw(address(0), treasury, 1000e6);
    }

    function test_EmergencyWithdrawZeroToReverts() public {
        vm.prank(owner);
        vm.expectRevert(USDL.ZeroAddress.selector);
        usdlProxy.emergencyWithdraw(address(usdc), address(0), 1000e6);
    }

    function test_EmergencyWithdrawZeroAmountReverts() public {
        vm.prank(owner);
        vm.expectRevert(USDL.ZeroAmount.selector);
        usdlProxy.emergencyWithdraw(address(usdc), treasury, 0);
    }

    // ============ View Functions (10) ============
    function test_SharePriceInitial() public view {
        assertEq(usdlProxy.sharePrice(), 1e6);
    }

    function test_GetPriceInitial() public view {
        // When no deposits, 1 USDL = 1 USDC
        assertEq(usdlProxy.getPrice(), 1e6);
    }

    function test_GetPriceAfterDeposit() public {
        vm.startPrank(user1);
        usdc.approve(address(usdlProxy), 1000e6);
        usdlProxy.deposit(1000e6, user1);
        vm.stopPrank();

        // Price should still be ~1 USDC (slight variance due to fees)
        uint256 price = usdlProxy.getPrice();
        assertGt(price, 0.9e6, "Price should be > 0.9 USDC");
        assertLt(price, 1.1e6, "Price should be < 1.1 USDC");
    }

    function test_BalanceIncreasesWithYield() public {
        vm.prank(manager);
        usdlProxy.addYieldAsset(address(yieldVault), address(usdc), address(yieldVault), 10000, AssetType.ERC4626);

        vm.startPrank(user1);
        usdc.approve(address(usdlProxy), 1000e6);
        usdlProxy.deposit(1000e6, user1);
        vm.stopPrank();

        uint256 balanceBefore = usdlProxy.balanceOf(user1);

        // Simulate 10% yield
        yieldVault.setYieldMultiplier(1.1e18);
        vm.prank(manager);
        usdlProxy.accrueYield();

        uint256 balanceAfter = usdlProxy.balanceOf(user1);

        // Balance increases with yield (rebasing)
        assertGt(balanceAfter, balanceBefore, "Balance should increase with yield");

        // Price stays ~1:1 (rebasing token)
        uint256 priceAfter = usdlProxy.getPrice();
        assertApproxEqAbs(priceAfter, 1e6, 1000, "Price stays ~1:1 with rebasing");
    }

    function test_SharePriceAfterDeposit() public {
        vm.startPrank(user1);
        usdc.approve(address(usdlProxy), 1000e6);
        usdlProxy.deposit(1000e6, user1);
        vm.stopPrank();

        uint256 price = usdlProxy.sharePrice();
        assertGt(price, 0.9e6);
        assertLt(price, 1.1e6);
    }

    function test_SupportsInterfaceERC20() public view {
        assertTrue(usdlProxy.supportsInterface(type(IERC20).interfaceId));
    }

    function test_SupportsInterfaceERC4626() public view {
        assertTrue(usdlProxy.supportsInterface(type(IERC4626).interfaceId));
    }

    function test_SupportsInterfaceERC165() public view {
        assertTrue(usdlProxy.supportsInterface(type(IERC165).interfaceId));
    }

    function test_SupportsInterfaceAccessControl() public view {
        assertTrue(usdlProxy.supportsInterface(type(IAccessControl).interfaceId));
    }

    function test_SupportsInterfaceIGetCCIPAdmin() public view {
        assertTrue(usdlProxy.supportsInterface(type(IGetCCIPAdmin).interfaceId));
    }

    function test_SupportsInterfaceIBurnMintERC20() public view {
        assertTrue(usdlProxy.supportsInterface(type(IBurnMintERC20).interfaceId));
    }

    function test_Decimals() public view {
        assertEq(usdlProxy.decimals(), 6);
    }

    function test_Asset() public view {
        assertEq(usdlProxy.asset(), address(usdc));
    }

    function test_GetYieldAssetList() public {
        vm.startPrank(manager);
        usdlProxy.addYieldAsset(address(yieldVault), address(usdc), address(yieldVault), 5000, AssetType.ERC4626);
        usdlProxy.addYieldAsset(address(yieldVault2), address(usdc), address(yieldVault2), 5000, AssetType.ERC4626);
        vm.stopPrank();

        address[] memory list = usdlProxy.getYieldAssetList();
        assertEq(list.length, 2);
    }

    // ============ Transfer Tests (3) ============
    function test_Transfer() public {
        vm.startPrank(user1);
        usdc.approve(address(usdlProxy), 1000e6);
        usdlProxy.deposit(1000e6, user1);
        usdlProxy.transfer(user2, 100e6);
        vm.stopPrank();

        assertEq(usdlProxy.balanceOf(user2), 100e6);
    }

    function test_TransferFrom() public {
        vm.startPrank(user1);
        usdc.approve(address(usdlProxy), 1000e6);
        usdlProxy.deposit(1000e6, user1);
        usdlProxy.approve(user2, 200e6);
        vm.stopPrank();

        vm.prank(user2);
        usdlProxy.transferFrom(user1, user2, 100e6);

        assertEq(usdlProxy.balanceOf(user2), 100e6);
    }

    function test_Approve() public {
        vm.prank(user1);
        usdlProxy.approve(user2, 1000e6);
        assertEq(usdlProxy.allowance(user1, user2), 1000e6);
    }

    // ============ Constants Tests (3) ============
    function test_BasisPointsConstant() public view {
        assertEq(usdlProxy.BASIS_POINTS(), 10_000);
    }

    function test_MinDepositConstant() public view {
        assertEq(usdlProxy.MIN_DEPOSIT(), 1e6);
    }

    function test_RoleConstants() public view {
        assertEq(usdlProxy.PAUSER_ROLE(), keccak256("PAUSER_ROLE"));
        assertEq(usdlProxy.MANAGER_ROLE(), keccak256("MANAGER_ROLE"));
        assertEq(usdlProxy.BRIDGE_ROLE(), keccak256("BRIDGE_ROLE"));
        assertEq(usdlProxy.UPGRADER_ROLE(), keccak256("UPGRADER_ROLE"));
        assertEq(usdlProxy.BLACKLISTER_ROLE(), keccak256("BLACKLISTER_ROLE"));
    }

    // ============ Security Fix Tests ============

    // M-03: Test allocation rounding with inactive last asset
    function test_AllocationRoundingWithInactiveLastAsset() public {
        // Add two yield assets
        vm.startPrank(manager);
        usdlProxy.addYieldAsset(address(yieldVault), address(usdc), address(yieldVault), 5000, AssetType.ERC4626);
        usdlProxy.addYieldAsset(address(yieldVault2), address(usdc), address(yieldVault2), 5000, AssetType.ERC4626);

        // Deactivate the LAST asset
        usdlProxy.deactivateYieldAsset(address(yieldVault2));
        vm.stopPrank();

        // Deposit - should allocate ALL to the first (and only active) asset
        vm.startPrank(user1);
        usdc.approve(address(usdlProxy), 1000e6);
        usdlProxy.deposit(1000e6, user1);
        vm.stopPrank();

        // First vault should have received the deposit (minus fee)
        uint256 fee = (1000e6 * 10) / 10000;
        uint256 expectedDeposit = 1000e6 - fee;

        // The first active vault should get ALL the funds (not just 50%)
        assertEq(yieldVault.balanceOf(address(usdlProxy)), expectedDeposit, "First vault should get all funds");
        assertEq(yieldVault2.balanceOf(address(usdlProxy)), 0, "Inactive vault should have 0");
    }

    // H-01: Test withdrawal verification works
    function test_WithdrawalVerifiesActualRedemption() public {
        // Add yield asset
        vm.prank(manager);
        usdlProxy.addYieldAsset(address(yieldVault), address(usdc), address(yieldVault), 10000, AssetType.ERC4626);

        // Deposit
        vm.startPrank(user1);
        usdc.approve(address(usdlProxy), 1000e6);
        usdlProxy.deposit(1000e6, user1);
        vm.stopPrank();

        // Normal withdrawal should work - the H-01 fix verifies actual redemption
        uint256 shares = usdlProxy.balanceOf(user1);
        vm.prank(user1);
        usdlProxy.redeem(shares / 2, user1, user1);

        // Verify user got their USDC back
        assertGt(usdc.balanceOf(user1), INITIAL_USDC - 1000e6, "User should have received USDC");
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {YieldRouter} from "../src/lendefi/YieldRouter.sol";
import {USDL} from "../src/lendefi/USDL.sol";
import {ERC20Mock} from "./mock/ERC20Mock.sol";

/// @notice Mock yield manager for testing
contract MockYieldManager {
    ERC20Mock public depositToken;
    ERC20Mock public yieldToken;
    
    constructor(address _depositToken, address _yieldToken) {
        depositToken = ERC20Mock(_depositToken);
        yieldToken = ERC20Mock(_yieldToken);
    }
    
    function subscribe(uint256 amount) external returns (uint256) {
        depositToken.transferFrom(msg.sender, address(this), amount);
        yieldToken.mint(msg.sender, amount); // 1:1 for simplicity
        return amount;
    }
    
    function redeem(uint256 amount) external returns (uint256) {
        yieldToken.transferFrom(msg.sender, address(this), amount);
        depositToken.transfer(msg.sender, amount);
        return amount;
    }
}

/// @notice Mock DEX router for testing
contract MockDexRouter {
    ERC20Mock public weth;
    ERC20Mock public usdc;
    uint256 public rate = 3000e6; // 1 ETH = 3000 USDC
    
    constructor(address _weth, address _usdc) {
        weth = ERC20Mock(_weth);
        usdc = ERC20Mock(_usdc);
    }
    
    function swapExactETHForTokens(
        uint256, // amountOutMin
        address[] calldata, // path
        address to,
        uint256 // deadline
    ) external payable returns (uint256[] memory amounts) {
        uint256 usdcOut = (msg.value * rate) / 1e18;
        usdc.mint(to, usdcOut);
        
        amounts = new uint256[](2);
        amounts[0] = msg.value;
        amounts[1] = usdcOut;
    }
    
    function setRate(uint256 _rate) external {
        rate = _rate;
    }
    
    receive() external payable {}
}

contract YieldRouterTest is Test {
    YieldRouter public router;
    YieldRouter public routerProxy;
    USDL public usdl;
    USDL public usdlProxy;
    
    ERC20Mock public usdc;
    ERC20Mock public weth;
    ERC20Mock public ousg;
    ERC20Mock public buidl;
    
    MockYieldManager public ousgManager;
    MockYieldManager public buidlManager;
    MockDexRouter public dexRouter;
    
    address public owner = address(0x1);
    address public treasury = address(0x2);
    address public user1 = address(0x3);
    address public user2 = address(0x4);
    address public operator = address(0x5);
    
    uint256 public constant INITIAL_USDC = 1_000_000e6; // 1M USDC
    
    function setUp() public {
        // Deploy mock tokens
        usdc = new ERC20Mock("USD Coin", "USDC", 6);
        weth = new ERC20Mock("Wrapped ETH", "WETH", 18);
        ousg = new ERC20Mock("Ondo US Government", "OUSG", 18);
        buidl = new ERC20Mock("BlackRock BUIDL", "BUIDL", 18);
        
        // Deploy mock managers
        ousgManager = new MockYieldManager(address(usdc), address(ousg));
        buidlManager = new MockYieldManager(address(usdc), address(buidl));
        
        // Deploy mock DEX
        dexRouter = new MockDexRouter(address(weth), address(usdc));
        
        // Fund managers with USDC for redemptions
        usdc.mint(address(ousgManager), 10_000_000e6);
        usdc.mint(address(buidlManager), 10_000_000e6);
        
        // Deploy USDL
        usdl = new USDL();
        bytes memory usdlInitData = abi.encodeWithSelector(
            USDL.initialize.selector,
            owner
        );
        ERC1967Proxy usdlProxyContract = new ERC1967Proxy(address(usdl), usdlInitData);
        usdlProxy = USDL(address(usdlProxyContract));
        
        // Deploy YieldRouter
        router = new YieldRouter();
        bytes memory routerInitData = abi.encodeWithSelector(
            YieldRouter.initialize.selector,
            owner,
            address(usdlProxy),
            address(usdc),
            address(weth),
            address(dexRouter),
            treasury
        );
        ERC1967Proxy routerProxyContract = new ERC1967Proxy(address(router), routerInitData);
        routerProxy = YieldRouter(payable(address(routerProxyContract)));
        
        // Grant MINTER_ROLE to router on USDL (must be done by owner)
        vm.prank(owner);
        usdlProxy.grantMinterRole(address(routerProxy));
        
        // Cache role to avoid static call consuming prank
        bytes32 operatorRole = routerProxy.OPERATOR_ROLE();
        
        // Grant OPERATOR_ROLE to operator (must be done by owner)
        vm.prank(owner);
        routerProxy.grantRole(operatorRole, operator);
        
        // Fund users with USDC
        usdc.mint(user1, INITIAL_USDC);
        usdc.mint(user2, INITIAL_USDC);
        
        // Fund router with USDC for fiat onramp tests
        usdc.mint(address(routerProxy), INITIAL_USDC);
        
        // Give users ETH
        vm.deal(user1, 100 ether);
        vm.deal(user2, 100 ether);
    }
    
    // ============ Initialization Tests ============
    
    function test_Initialize() public view {
        assertEq(address(routerProxy.usdl()), address(usdlProxy));
        assertEq(address(routerProxy.usdc()), address(usdc));
        assertEq(address(routerProxy.weth()), address(weth));
        assertEq(routerProxy.dexRouter(), address(dexRouter));
        assertEq(routerProxy.treasury(), treasury);
        assertEq(routerProxy.VERSION(), 1);
        assertEq(routerProxy.depositFeeBps(), 10); // 0.1%
        assertEq(routerProxy.withdrawalFeeBps(), 10); // 0.1%
    }
    
    function test_InitializeZeroAddressReverts() public {
        YieldRouter newRouter = new YieldRouter();
        bytes memory initData = abi.encodeWithSelector(
            YieldRouter.initialize.selector,
            address(0), // zero owner
            address(usdlProxy),
            address(usdc),
            address(weth),
            address(dexRouter),
            treasury
        );
        vm.expectRevert(YieldRouter.ZeroAddress.selector);
        new ERC1967Proxy(address(newRouter), initData);
    }
    
    // ============ Add Yield Asset Tests ============
    
    function test_AddYieldAsset() public {
        vm.prank(owner);
        routerProxy.addYieldAsset(
            address(ousg),
            address(usdc),
            address(ousgManager),
            10000 // 100%
        );
        
        YieldRouter.YieldAsset memory asset = routerProxy.getYieldAsset(address(ousg));
        assertEq(asset.token, address(ousg));
        assertEq(asset.depositToken, address(usdc));
        assertEq(asset.manager, address(ousgManager));
        assertEq(asset.allocation, 10000);
        assertTrue(asset.active);
    }
    
    function test_AddMultipleYieldAssets() public {
        vm.startPrank(owner);
        routerProxy.addYieldAsset(
            address(ousg),
            address(usdc),
            address(ousgManager),
            5000 // 50%
        );
        routerProxy.addYieldAsset(
            address(buidl),
            address(usdc),
            address(buidlManager),
            5000 // 50%
        );
        vm.stopPrank();
        
        assertEq(routerProxy.getYieldAssetCount(), 2);
        
        address[] memory assets = routerProxy.getYieldAssetList();
        assertEq(assets[0], address(ousg));
        assertEq(assets[1], address(buidl));
    }
    
    function test_AddYieldAssetInvalidAllocationReverts() public {
        vm.startPrank(owner);
        routerProxy.addYieldAsset(
            address(ousg),
            address(usdc),
            address(ousgManager),
            5000 // 50%
        );
        
        // Adding another with 60% should fail (total 110%)
        vm.expectRevert(abi.encodeWithSelector(YieldRouter.InvalidAllocation.selector, 11000));
        routerProxy.addYieldAsset(
            address(buidl),
            address(usdc),
            address(buidlManager),
            6000 // 60%
        );
        vm.stopPrank();
    }
    
    function test_AddYieldAssetAlreadyExistsReverts() public {
        vm.startPrank(owner);
        routerProxy.addYieldAsset(
            address(ousg),
            address(usdc),
            address(ousgManager),
            10000
        );
        
        vm.expectRevert(abi.encodeWithSelector(YieldRouter.AssetAlreadyExists.selector, address(ousg)));
        routerProxy.addYieldAsset(
            address(ousg),
            address(usdc),
            address(ousgManager),
            10000
        );
        vm.stopPrank();
    }
    
    // ============ Deposit USDC Tests ============
    
    function test_DepositUSDC() public {
        // Setup yield asset
        vm.prank(owner);
        routerProxy.addYieldAsset(address(ousg), address(usdc), address(ousgManager), 10000);
        
        uint256 depositAmount = 10_000e6; // 10,000 USDC
        
        vm.startPrank(user1);
        usdc.approve(address(routerProxy), depositAmount);
        uint256 usdlAmount = routerProxy.depositUSDC(depositAmount, user1);
        vm.stopPrank();
        
        // Fee is 0.1% = 10 USDC
        uint256 expectedFee = (depositAmount * 10) / 10000;
        uint256 netDeposit = depositAmount - expectedFee;
        uint256 expectedUsdl = netDeposit * 1e12; // Convert 6 decimals to 18
        
        assertEq(usdlAmount, expectedUsdl);
        assertEq(usdlProxy.balanceOf(user1), expectedUsdl);
        assertEq(usdc.balanceOf(treasury), expectedFee);
    }
    
    function test_DepositUSDCBelowMinimumReverts() public {
        vm.prank(owner);
        routerProxy.addYieldAsset(address(ousg), address(usdc), address(ousgManager), 10000);
        
        vm.startPrank(user1);
        usdc.approve(address(routerProxy), 0.5e6); // 0.5 USDC
        
        vm.expectRevert(abi.encodeWithSelector(YieldRouter.BelowMinimumDeposit.selector, 0.5e6, 1e6));
        routerProxy.depositUSDC(0.5e6, user1);
        vm.stopPrank();
    }
    
    function test_DepositUSDCToRecipient() public {
        vm.prank(owner);
        routerProxy.addYieldAsset(address(ousg), address(usdc), address(ousgManager), 10000);
        
        uint256 depositAmount = 10_000e6;
        
        vm.startPrank(user1);
        usdc.approve(address(routerProxy), depositAmount);
        routerProxy.depositUSDC(depositAmount, user2); // Deposit for user2
        vm.stopPrank();
        
        assertEq(usdlProxy.balanceOf(user1), 0);
        assertGt(usdlProxy.balanceOf(user2), 0);
    }
    
    // ============ Deposit ETH Tests ============
    
    function test_DepositETH() public {
        vm.prank(owner);
        routerProxy.addYieldAsset(address(ousg), address(usdc), address(ousgManager), 10000);
        
        uint256 ethAmount = 1 ether;
        
        vm.prank(user1);
        uint256 usdlAmount = routerProxy.depositETH{value: ethAmount}(user1);
        
        // 1 ETH = 3000 USDC (mock rate)
        // Fee = 3000 * 0.1% = 3 USDC
        // Net = 2997 USDC = 2997e18 USDL
        assertGt(usdlAmount, 0);
        assertEq(usdlProxy.balanceOf(user1), usdlAmount);
    }
    
    function test_DepositETHZeroAmountReverts() public {
        vm.prank(user1);
        vm.expectRevert(YieldRouter.ZeroAmount.selector);
        routerProxy.depositETH{value: 0}(user1);
    }
    
    // ============ Fiat Onramp Tests ============
    
    function test_ProcessFiatOnramp() public {
        vm.prank(owner);
        routerProxy.addYieldAsset(address(ousg), address(usdc), address(ousgManager), 10000);
        
        bytes32 refId = keccak256("ACH-12345");
        uint256 usdcAmount = 50_000e6; // 50,000 USDC
        
        vm.prank(operator);
        uint256 usdlAmount = routerProxy.processFiatOnramp(refId, user1, usdcAmount);
        
        assertGt(usdlAmount, 0);
        assertEq(usdlProxy.balanceOf(user1), usdlAmount);
    }
    
    function test_ProcessFiatOnrampReplayReverts() public {
        vm.prank(owner);
        routerProxy.addYieldAsset(address(ousg), address(usdc), address(ousgManager), 10000);
        
        bytes32 refId = keccak256("ACH-12345");
        
        vm.startPrank(operator);
        routerProxy.processFiatOnramp(refId, user1, 10_000e6);
        
        // Try to replay
        vm.expectRevert(abi.encodeWithSelector(YieldRouter.OnrampAlreadyProcessed.selector, refId));
        routerProxy.processFiatOnramp(refId, user1, 10_000e6);
        vm.stopPrank();
    }
    
    function test_ProcessFiatOnrampNotOperatorReverts() public {
        bytes32 refId = keccak256("ACH-12345");
        
        vm.prank(user1);
        vm.expectRevert();
        routerProxy.processFiatOnramp(refId, user1, 10_000e6);
    }
    
    // ============ Withdraw Tests ============
    
    function test_Withdraw() public {
        // Setup - no yield asset, just hold USDC in router
        // Fund router with USDC for withdrawal
        usdc.mint(address(routerProxy), 100_000e6);
        
        // Mint USDL to user via fiat onramp (simulates deposit)
        vm.prank(owner);
        routerProxy.addYieldAsset(address(ousg), address(usdc), address(ousgManager), 10000);
        
        bytes32 refId = keccak256("test-deposit");
        vm.prank(operator);
        uint256 usdlMinted = routerProxy.processFiatOnramp(refId, user1, 10_000e6);
        
        // Approve router to burn USDL
        vm.startPrank(user1);
        usdlProxy.approve(address(routerProxy), usdlMinted);
        
        // Withdraw half
        uint256 withdrawUsdl = usdlMinted / 2;
        uint256 usdcReceived = routerProxy.withdraw(withdrawUsdl, user1);
        vm.stopPrank();
        
        assertGt(usdcReceived, 0);
        assertEq(usdlProxy.balanceOf(user1), usdlMinted - withdrawUsdl);
    }
    
    // ============ Fee Tests ============
    
    function test_SetFees() public {
        vm.prank(owner);
        routerProxy.setFees(50, 100); // 0.5% deposit, 1% withdrawal
        
        assertEq(routerProxy.depositFeeBps(), 50);
        assertEq(routerProxy.withdrawalFeeBps(), 100);
    }
    
    function test_SetFeesTooHighReverts() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(YieldRouter.InvalidFee.selector, 600));
        routerProxy.setFees(600, 10); // 6% is too high (max 5%)
    }
    
    // ============ Admin Tests ============
    
    function test_SetDexRouter() public {
        address newRouter = address(0x999);
        
        vm.prank(owner);
        routerProxy.setDexRouter(newRouter);
        
        assertEq(routerProxy.dexRouter(), newRouter);
    }
    
    function test_SetTreasury() public {
        address newTreasury = address(0x888);
        
        vm.prank(owner);
        routerProxy.setTreasury(newTreasury);
        
        assertEq(routerProxy.treasury(), newTreasury);
    }
    
    function test_UpdateYieldAssetAllocation() public {
        vm.startPrank(owner);
        routerProxy.addYieldAsset(address(ousg), address(usdc), address(ousgManager), 10000);
        routerProxy.updateYieldAssetAllocation(address(ousg), 5000);
        vm.stopPrank();
        
        YieldRouter.YieldAsset memory asset = routerProxy.getYieldAsset(address(ousg));
        assertEq(asset.allocation, 5000);
    }
    
    function test_DeactivateYieldAsset() public {
        vm.startPrank(owner);
        routerProxy.addYieldAsset(address(ousg), address(usdc), address(ousgManager), 10000);
        routerProxy.deactivateYieldAsset(address(ousg));
        vm.stopPrank();
        
        YieldRouter.YieldAsset memory asset = routerProxy.getYieldAsset(address(ousg));
        assertFalse(asset.active);
    }
    
    function test_Pause() public {
        vm.prank(owner);
        routerProxy.pause();
        
        vm.prank(user1);
        usdc.approve(address(routerProxy), 10_000e6);
        
        vm.expectRevert();
        vm.prank(user1);
        routerProxy.depositUSDC(10_000e6, user1);
    }
    
    function test_Unpause() public {
        vm.prank(owner);
        routerProxy.addYieldAsset(address(ousg), address(usdc), address(ousgManager), 10000);
        
        vm.prank(owner);
        routerProxy.pause();
        
        vm.prank(owner);
        routerProxy.unpause();
        
        // Should work now
        vm.startPrank(user1);
        usdc.approve(address(routerProxy), 10_000e6);
        routerProxy.depositUSDC(10_000e6, user1);
        vm.stopPrank();
        
        assertGt(usdlProxy.balanceOf(user1), 0);
    }
    
    function test_EmergencyWithdraw() public {
        uint256 amount = 1000e6;
        usdc.mint(address(routerProxy), amount);
        
        uint256 balanceBefore = usdc.balanceOf(treasury);
        
        vm.prank(owner);
        routerProxy.emergencyWithdraw(address(usdc), treasury, amount);
        
        assertEq(usdc.balanceOf(treasury), balanceBefore + amount);
    }
    
    // ============ View Function Tests ============
    
    function test_GetTotalValueLocked() public {
        vm.prank(owner);
        routerProxy.addYieldAsset(address(ousg), address(usdc), address(ousgManager), 10000);
        
        // Deposit
        vm.startPrank(user1);
        usdc.approve(address(routerProxy), 100_000e6);
        routerProxy.depositUSDC(100_000e6, user1);
        vm.stopPrank();
        
        uint256 tvl = routerProxy.getTotalValueLocked();
        assertGt(tvl, 0);
    }
    
    function test_GetBackingRatio() public {
        vm.prank(owner);
        routerProxy.addYieldAsset(address(ousg), address(usdc), address(ousgManager), 10000);
        
        // Deposit
        vm.startPrank(user1);
        usdc.approve(address(routerProxy), 100_000e6);
        routerProxy.depositUSDC(100_000e6, user1);
        vm.stopPrank();
        
        uint256 ratio = routerProxy.getBackingRatio();
        // Should be close to 100% (10000 bps)
        assertGt(ratio, 0);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "../src/lendefi/USDL.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract USDLTest is Test {
    USDL public usdl;
    USDL public usdlProxy;
    
    address public owner = address(0x1);
    address public user1 = address(0x3);
    address public user2 = address(0x4);
    address public bridge = address(0x5);
    address public minter = address(0x6);
    address public blacklisted = address(0x7);
    
    function setUp() public {
        // Deploy implementation
        usdl = new USDL();
        
        // Deploy proxy
        bytes memory initData = abi.encodeWithSelector(
            USDL.initialize.selector,
            owner
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(usdl), initData);
        usdlProxy = USDL(address(proxy));
        
        // Setup minter role (must be done by owner)
        // Cache the role first to avoid staticcall clearing the prank
        bytes32 minterRole = usdlProxy.MINTER_ROLE();
        vm.prank(owner);
        usdlProxy.grantRole(minterRole, minter);
    }
    
    // ============ Initialization Tests ============
    
    function test_Initialize() public view {
        assertEq(usdlProxy.name(), "Lendefi USD");
        assertEq(usdlProxy.symbol(), "USDL");
        assertEq(usdlProxy.totalSupply(), 0); // Stablecoin starts with 0 supply
        assertEq(usdlProxy.version(), 1);
        assertEq(usdlProxy.VERSION(), 1);
        assertEq(usdlProxy.getCCIPAdmin(), owner);
    }
    
    function test_InitializeZeroOwnerReverts() public {
        USDL newImpl = new USDL();
        bytes memory initData = abi.encodeWithSelector(
            USDL.initialize.selector,
            address(0)
        );
        vm.expectRevert(USDL.ZeroAddress.selector);
        new ERC1967Proxy(address(newImpl), initData);
    }
    
    // ============ Minting Tests ============
    
    function test_Mint() public {
        vm.prank(minter);
        usdlProxy.mint(user1, 10_000 ether);
        
        assertEq(usdlProxy.balanceOf(user1), 10_000 ether);
        assertEq(usdlProxy.totalSupply(), 10_000 ether);
    }
    
    function test_MintNotMinterReverts() public {
        vm.prank(user1);
        vm.expectRevert();
        usdlProxy.mint(user1, 10_000 ether);
    }
    
    function test_MintZeroAmountReverts() public {
        vm.prank(minter);
        vm.expectRevert(USDL.ZeroAmount.selector);
        usdlProxy.mint(user1, 0);
    }
    
    function test_MintToSelfReverts() public {
        vm.prank(minter);
        vm.expectRevert(abi.encodeWithSelector(USDL.InvalidRecipient.selector, address(usdlProxy)));
        usdlProxy.mint(address(usdlProxy), 10_000 ether);
    }
    
    // ============ Bridge Role Tests ============
    
    function test_GrantBridgeRole() public {
        vm.prank(owner);
        usdlProxy.grantMinterRole(bridge);
        assertTrue(usdlProxy.hasRole(usdlProxy.MINTER_ROLE(), bridge));
    }
    
    function test_RevokeBridgeRole() public {
        vm.startPrank(owner);
        usdlProxy.grantMinterRole(bridge);
        usdlProxy.revokeMinterRole(bridge);
        vm.stopPrank();
        assertFalse(usdlProxy.hasRole(usdlProxy.MINTER_ROLE(), bridge));
    }
    
    // ============ Bridge Mint Tests ============
    
    function test_MinterMint() public {
        vm.prank(owner);
        usdlProxy.grantMinterRole(bridge);
        
        vm.prank(bridge);
        usdlProxy.mint(user1, 10_000 ether);
        
        assertEq(usdlProxy.balanceOf(user1), 10_000 ether);
    }
    
    function test_MinterMintWithoutRoleReverts() public {
        vm.prank(user1);
        vm.expectRevert();
        usdlProxy.mint(user1, 10_000 ether);
    }
    
    // ============ Burn Tests ============
    
    function test_Burn() public {
        vm.prank(minter);
        usdlProxy.mint(user1, 10_000 ether);
        
        vm.prank(user1);
        usdlProxy.burn(5_000 ether);
        
        assertEq(usdlProxy.balanceOf(user1), 5_000 ether);
    }
    
    function test_BurnFrom() public {
        vm.prank(minter);
        usdlProxy.mint(user1, 10_000 ether);
        
        vm.prank(user1);
        usdlProxy.approve(user2, 5_000 ether);
        
        vm.prank(user2);
        usdlProxy.burnFrom(user1, 5_000 ether);
        
        assertEq(usdlProxy.balanceOf(user1), 5_000 ether);
    }
    
    // ============ Blacklist Tests ============
    
    function test_Blacklist() public {
        vm.prank(owner);
        usdlProxy.blacklist(blacklisted);
        assertTrue(usdlProxy.blacklisted(blacklisted));
    }
    
    function test_Unblacklist() public {
        vm.startPrank(owner);
        usdlProxy.blacklist(blacklisted);
        usdlProxy.unblacklist(blacklisted);
        vm.stopPrank();
        assertFalse(usdlProxy.blacklisted(blacklisted));
    }
    
    function test_BlacklistNotBlacklisterReverts() public {
        vm.prank(user1);
        vm.expectRevert();
        usdlProxy.blacklist(blacklisted);
    }
    
    function test_MintToBlacklistedReverts() public {
        vm.prank(owner);
        usdlProxy.blacklist(blacklisted);
        
        vm.prank(minter);
        vm.expectRevert(abi.encodeWithSelector(USDL.AddressBlacklisted.selector, blacklisted));
        usdlProxy.mint(blacklisted, 10_000 ether);
    }
    
    function test_TransferFromBlacklistedReverts() public {
        vm.prank(minter);
        usdlProxy.mint(user1, 10_000 ether);
        
        vm.prank(owner);
        usdlProxy.blacklist(user1);
        
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(USDL.AddressBlacklisted.selector, user1));
        usdlProxy.transfer(user2, 5_000 ether);
    }
    
    function test_TransferToBlacklistedReverts() public {
        vm.prank(minter);
        usdlProxy.mint(user1, 10_000 ether);
        
        vm.prank(owner);
        usdlProxy.blacklist(user2);
        
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(USDL.AddressBlacklisted.selector, user2));
        usdlProxy.transfer(user2, 5_000 ether);
    }
    
    function test_MinterMintToBlacklistedReverts() public {
        vm.startPrank(owner);
        usdlProxy.grantMinterRole(bridge);
        usdlProxy.blacklist(blacklisted);
        vm.stopPrank();
        
        vm.prank(bridge);
        vm.expectRevert(abi.encodeWithSelector(USDL.AddressBlacklisted.selector, blacklisted));
        usdlProxy.mint(blacklisted, 10_000 ether);
    }
    
    // ============ CCIP Admin Tests ============
    
    function test_SetCCIPAdmin() public {
        vm.prank(owner);
        usdlProxy.setCCIPAdmin(user1);
        assertEq(usdlProxy.getCCIPAdmin(), user1);
    }
    
    function test_SetCCIPAdminZeroReverts() public {
        vm.prank(owner);
        vm.expectRevert(USDL.ZeroAddress.selector);
        usdlProxy.setCCIPAdmin(address(0));
    }
    
    // ============ Pause Tests ============
    
    function test_Pause() public {
        vm.prank(owner);
        usdlProxy.pause();
        assertTrue(usdlProxy.paused());
    }
    
    function test_PauseMintReverts() public {
        vm.prank(owner);
        usdlProxy.pause();
        
        vm.prank(minter);
        vm.expectRevert();
        usdlProxy.mint(user1, 10_000 ether);
    }
    
    function test_Unpause() public {
        vm.startPrank(owner);
        usdlProxy.pause();
        usdlProxy.unpause();
        vm.stopPrank();
        assertFalse(usdlProxy.paused());
    }
    
    // ============ Transfer Tests ============
    
    function test_Transfer() public {
        vm.prank(minter);
        usdlProxy.mint(user1, 10_000 ether);
        
        vm.prank(user1);
        usdlProxy.transfer(user2, 5_000 ether);
        
        assertEq(usdlProxy.balanceOf(user1), 5_000 ether);
        assertEq(usdlProxy.balanceOf(user2), 5_000 ether);
    }
    
    // ============ Supports Interface Tests ============
    
    function test_SupportsInterface() public view {
        // IERC20
        assertTrue(usdlProxy.supportsInterface(type(IERC20).interfaceId));
        // IBurnMintERC20
        assertTrue(usdlProxy.supportsInterface(type(IBurnMintERC20).interfaceId));
        // IERC165
        assertTrue(usdlProxy.supportsInterface(type(IERC165).interfaceId));
        // IGetCCIPAdmin
        assertTrue(usdlProxy.supportsInterface(type(IGetCCIPAdmin).interfaceId));
    }
    
    // ============ Upgrade Tests ============
    
    function test_UpgradeOnlyUpgrader() public {
        USDL newImpl = new USDL();
        
        vm.prank(user1);
        vm.expectRevert();
        usdlProxy.upgradeToAndCall(address(newImpl), "");
    }
    
    function test_UpgradeIncrementsVersion() public {
        USDL newImpl = new USDL();
        
        vm.prank(owner);
        usdlProxy.upgradeToAndCall(address(newImpl), "");
        
        assertEq(usdlProxy.version(), 2);
    }
}

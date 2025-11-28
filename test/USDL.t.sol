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
    address public blacklistedUser = address(0x7);
    
    // Events for testing
    event Minted(address indexed minter, address indexed to, uint256 amount);
    event BridgeMinted(address indexed bridge, address indexed to, uint256 amount);
    
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
        vm.startPrank(owner);
        usdlProxy.grantMinterRole(minter);
        usdlProxy.grantBridgeRole(bridge);
        vm.stopPrank();
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
    
    function test_MinterMint() public {
        vm.expectEmit(true, true, false, true);
        emit Minted(minter, user1, 10_000 ether);
        
        vm.prank(minter);
        usdlProxy.mint(user1, 10_000 ether);
        
        assertEq(usdlProxy.balanceOf(user1), 10_000 ether);
        assertEq(usdlProxy.totalSupply(), 10_000 ether);
    }
    
    function test_MinterMintEmitsMintedEvent() public {
        vm.expectEmit(true, true, false, true);
        emit Minted(minter, user1, 10_000 ether);
        
        vm.prank(minter);
        usdlProxy.mint(user1, 10_000 ether);
    }
    
    function test_OwnerCanMint() public {
        // Owner has MINTER_ROLE from initialization
        vm.expectEmit(true, true, false, true);
        emit Minted(owner, user1, 10_000 ether);
        
        vm.prank(owner);
        usdlProxy.mint(user1, 10_000 ether);
        
        assertEq(usdlProxy.balanceOf(user1), 10_000 ether);
    }
    
    function test_MintNotMinterOrBridgeReverts() public {
        vm.prank(user1);
        vm.expectRevert();
        usdlProxy.mint(user1, 10_000 ether);
    }
    
    function test_MintZeroAmountReverts() public {
        vm.prank(minter);
        vm.expectRevert(USDL.ZeroAmount.selector);
        usdlProxy.mint(user1, 0);
    }
    
    function test_MintToZeroAddressReverts() public {
        vm.prank(minter);
        vm.expectRevert(USDL.ZeroAddress.selector);
        usdlProxy.mint(address(0), 10_000 ether);
    }
    
    function test_MintToSelfReverts() public {
        vm.prank(minter);
        vm.expectRevert(abi.encodeWithSelector(USDL.InvalidRecipient.selector, address(usdlProxy)));
        usdlProxy.mint(address(usdlProxy), 10_000 ether);
    }
    
    // ============ Bridge Mint Tests ============
    
    function test_BridgeMint() public {
        vm.expectEmit(true, true, false, true);
        emit BridgeMinted(bridge, user1, 10_000 ether);
        
        vm.prank(bridge);
        usdlProxy.mint(user1, 10_000 ether);
        
        assertEq(usdlProxy.balanceOf(user1), 10_000 ether);
    }
    
    function test_BridgeMintEmitsBridgeMintedEvent() public {
        vm.expectEmit(true, true, false, true);
        emit BridgeMinted(bridge, user1, 5_000 ether);
        
        vm.prank(bridge);
        usdlProxy.mint(user1, 5_000 ether);
    }
    
    function test_BridgeMintDoesNotEmitMintedEvent() public {
        // Ensure bridge mint emits BridgeMinted, not Minted
        vm.recordLogs();
        
        vm.prank(bridge);
        usdlProxy.mint(user1, 10_000 ether);
        
        Vm.Log[] memory logs = vm.getRecordedLogs();
        
        // Find the event and verify it's BridgeMinted
        bool foundBridgeMinted = false;
        for (uint i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("BridgeMinted(address,address,uint256)")) {
                foundBridgeMinted = true;
            }
            // Ensure Minted event was NOT emitted
            assertFalse(logs[i].topics[0] == keccak256("Minted(address,address,uint256)"));
        }
        assertTrue(foundBridgeMinted, "BridgeMinted event should be emitted");
    }
    
    function test_MinterMintDoesNotEmitBridgeMintedEvent() public {
        vm.recordLogs();
        
        vm.prank(minter);
        usdlProxy.mint(user1, 10_000 ether);
        
        Vm.Log[] memory logs = vm.getRecordedLogs();
        
        // Find the event and verify it's Minted
        bool foundMinted = false;
        for (uint i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("Minted(address,address,uint256)")) {
                foundMinted = true;
            }
            // Ensure BridgeMinted event was NOT emitted
            assertFalse(logs[i].topics[0] == keccak256("BridgeMinted(address,address,uint256)"));
        }
        assertTrue(foundMinted, "Minted event should be emitted");
    }
    
    // ============ Minter Role Tests ============
    
    function test_GrantMinterRole() public {
        address newMinter = address(0x99);
        vm.prank(owner);
        usdlProxy.grantMinterRole(newMinter);
        assertTrue(usdlProxy.hasRole(usdlProxy.MINTER_ROLE(), newMinter));
    }
    
    function test_RevokeMinterRole() public {
        vm.prank(owner);
        usdlProxy.revokeMinterRole(minter);
        assertFalse(usdlProxy.hasRole(usdlProxy.MINTER_ROLE(), minter));
    }
    
    function test_GrantMinterRoleZeroAddressReverts() public {
        vm.prank(owner);
        vm.expectRevert(USDL.ZeroAddress.selector);
        usdlProxy.grantMinterRole(address(0));
    }
    
    function test_RevokeMinterRoleZeroAddressReverts() public {
        vm.prank(owner);
        vm.expectRevert(USDL.ZeroAddress.selector);
        usdlProxy.revokeMinterRole(address(0));
    }
    
    function test_GrantMinterRoleNotAdminReverts() public {
        vm.prank(user1);
        vm.expectRevert();
        usdlProxy.grantMinterRole(user2);
    }
    
    // ============ Bridge Role Tests ============
    
    function test_GrantBridgeRole() public {
        address newBridge = address(0x88);
        vm.prank(owner);
        usdlProxy.grantBridgeRole(newBridge);
        assertTrue(usdlProxy.hasRole(usdlProxy.BRIDGE_ROLE(), newBridge));
    }
    
    function test_RevokeBridgeRole() public {
        vm.prank(owner);
        usdlProxy.revokeBridgeRole(bridge);
        assertFalse(usdlProxy.hasRole(usdlProxy.BRIDGE_ROLE(), bridge));
    }
    
    function test_GrantBridgeRoleZeroAddressReverts() public {
        vm.prank(owner);
        vm.expectRevert(USDL.ZeroAddress.selector);
        usdlProxy.grantBridgeRole(address(0));
    }
    
    function test_RevokeBridgeRoleZeroAddressReverts() public {
        vm.prank(owner);
        vm.expectRevert(USDL.ZeroAddress.selector);
        usdlProxy.revokeBridgeRole(address(0));
    }
    
    function test_GrantBridgeRoleNotAdminReverts() public {
        vm.prank(user1);
        vm.expectRevert();
        usdlProxy.grantBridgeRole(user2);
    }
    
    function test_RevokedBridgeCannotMint() public {
        vm.prank(owner);
        usdlProxy.revokeBridgeRole(bridge);
        
        vm.prank(bridge);
        vm.expectRevert();
        usdlProxy.mint(user1, 10_000 ether);
    }
    
    function test_RevokedMinterCannotMint() public {
        vm.prank(owner);
        usdlProxy.revokeMinterRole(minter);
        
        vm.prank(minter);
        vm.expectRevert();
        usdlProxy.mint(user1, 10_000 ether);
    }
    
    // ============ Dual Role Tests ============
    
    function test_AddressWith_BothRolesEmitsBridgeMintedEvent() public {
        // Grant both roles to same address - BRIDGE_ROLE takes precedence
        address dualRole = address(0x77);
        vm.startPrank(owner);
        usdlProxy.grantMinterRole(dualRole);
        usdlProxy.grantBridgeRole(dualRole);
        vm.stopPrank();
        
        vm.expectEmit(true, true, false, true);
        emit BridgeMinted(dualRole, user1, 10_000 ether);
        
        vm.prank(dualRole);
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
        usdlProxy.blacklist(blacklistedUser);
        assertTrue(usdlProxy.blacklisted(blacklistedUser));
    }
    
    function test_Unblacklist() public {
        vm.startPrank(owner);
        usdlProxy.blacklist(blacklistedUser);
        usdlProxy.unblacklist(blacklistedUser);
        vm.stopPrank();
        assertFalse(usdlProxy.blacklisted(blacklistedUser));
    }
    
    function test_BlacklistNotBlacklisterReverts() public {
        vm.prank(user1);
        vm.expectRevert();
        usdlProxy.blacklist(blacklistedUser);
    }
    
    function test_MinterMintToBlacklistedReverts() public {
        vm.prank(owner);
        usdlProxy.blacklist(blacklistedUser);
        
        vm.prank(minter);
        vm.expectRevert(abi.encodeWithSelector(USDL.AddressBlacklisted.selector, blacklistedUser));
        usdlProxy.mint(blacklistedUser, 10_000 ether);
    }
    
    function test_BridgeMintToBlacklistedReverts() public {
        vm.prank(owner);
        usdlProxy.blacklist(blacklistedUser);
        
        vm.prank(bridge);
        vm.expectRevert(abi.encodeWithSelector(USDL.AddressBlacklisted.selector, blacklistedUser));
        usdlProxy.mint(blacklistedUser, 10_000 ether);
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
    
    function test_SetCCIPAdminNotAdminReverts() public {
        vm.prank(user1);
        vm.expectRevert();
        usdlProxy.setCCIPAdmin(user2);
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
    
    function test_PauseBridgeMintReverts() public {
        vm.prank(owner);
        usdlProxy.pause();
        
        vm.prank(bridge);
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

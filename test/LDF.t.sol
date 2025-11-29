// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "../src/lendefi/LDF.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract LDFTest is Test {
    LDF public ldf;
    LDF public ldfProxy;

    address public owner = address(0x1);
    address public treasury = address(0x2);
    address public user1 = address(0x3);
    address public user2 = address(0x4);
    address public bridge = address(0x5);

    uint256 public constant INITIAL_SUPPLY = 50_000_000 ether;

    function setUp() public {
        // Deploy implementation
        ldf = new LDF();

        // Deploy proxy
        bytes memory initData = abi.encodeWithSelector(LDF.initialize.selector, owner, treasury);
        ERC1967Proxy proxy = new ERC1967Proxy(address(ldf), initData);
        ldfProxy = LDF(address(proxy));
    }

    // ============ Initialization Tests ============

    function test_Initialize() public view {
        assertEq(ldfProxy.name(), "Lendefi Token");
        assertEq(ldfProxy.symbol(), "LDF");
        assertEq(ldfProxy.totalSupply(), INITIAL_SUPPLY);
        assertEq(ldfProxy.balanceOf(treasury), INITIAL_SUPPLY);
        assertEq(ldfProxy.maxSupply(), INITIAL_SUPPLY);
        assertEq(ldfProxy.version(), 1);
        assertEq(ldfProxy.VERSION(), 1);
        assertEq(ldfProxy.getCCIPAdmin(), owner);
    }

    function test_InitializeZeroOwnerReverts() public {
        LDF newImpl = new LDF();
        bytes memory initData = abi.encodeWithSelector(LDF.initialize.selector, address(0), treasury);
        vm.expectRevert(LDF.ZeroAddress.selector);
        new ERC1967Proxy(address(newImpl), initData);
    }

    function test_InitializeZeroTreasuryReverts() public {
        LDF newImpl = new LDF();
        bytes memory initData = abi.encodeWithSelector(LDF.initialize.selector, owner, address(0));
        vm.expectRevert(LDF.ZeroAddress.selector);
        new ERC1967Proxy(address(newImpl), initData);
    }

    // ============ Bridge Role Tests ============

    function test_GrantBridgeRole() public {
        vm.prank(owner);
        ldfProxy.grantMinterRole(bridge);
        assertTrue(ldfProxy.hasRole(ldfProxy.MINTER_ROLE(), bridge));
    }

    function test_GrantBridgeRoleNotAdminReverts() public {
        vm.prank(user1);
        vm.expectRevert();
        ldfProxy.grantMinterRole(bridge);
    }

    function test_RevokeBridgeRole() public {
        vm.startPrank(owner);
        ldfProxy.grantMinterRole(bridge);
        ldfProxy.revokeMinterRole(bridge);
        vm.stopPrank();
        assertFalse(ldfProxy.hasRole(ldfProxy.MINTER_ROLE(), bridge));
    }

    // ============ Bridge Mint Tests ============

    function test_BridgeMint() public {
        vm.prank(owner);
        ldfProxy.grantMinterRole(bridge);

        // Transfer some tokens out first to make room for minting
        vm.prank(treasury);
        ldfProxy.burn(1000 ether);

        vm.prank(bridge);
        ldfProxy.mint(user1, 1000 ether);

        assertEq(ldfProxy.balanceOf(user1), 1000 ether);
    }

    function test_BridgeMintExceedsMaxSupplyReverts() public {
        vm.prank(owner);
        ldfProxy.grantMinterRole(bridge);

        // Already at max supply
        vm.prank(bridge);
        vm.expectRevert();
        ldfProxy.mint(user1, 1000 ether);
    }

    function test_BridgeMintToSelfReverts() public {
        vm.prank(owner);
        ldfProxy.grantMinterRole(bridge);

        vm.prank(bridge);
        vm.expectRevert(abi.encodeWithSelector(LDF.InvalidRecipient.selector, address(ldfProxy)));
        ldfProxy.mint(address(ldfProxy), 1000 ether);
    }

    function test_BridgeMintZeroAmountReverts() public {
        vm.prank(owner);
        ldfProxy.grantMinterRole(bridge);

        vm.prank(bridge);
        vm.expectRevert(LDF.ZeroAmount.selector);
        ldfProxy.mint(user1, 0);
    }

    function test_BridgeMintWithoutRoleReverts() public {
        vm.prank(user1);
        vm.expectRevert();
        ldfProxy.mint(user1, 1000 ether);
    }

    // ============ Burn Tests ============

    function test_Burn() public {
        vm.prank(treasury);
        ldfProxy.burn(1000 ether);

        assertEq(ldfProxy.balanceOf(treasury), INITIAL_SUPPLY - 1000 ether);
        assertEq(ldfProxy.totalSupply(), INITIAL_SUPPLY - 1000 ether);
    }

    function test_BurnFrom() public {
        vm.prank(treasury);
        ldfProxy.approve(user1, 1000 ether);

        vm.prank(user1);
        ldfProxy.burnFrom(treasury, 1000 ether);

        assertEq(ldfProxy.balanceOf(treasury), INITIAL_SUPPLY - 1000 ether);
    }

    // ============ CCIP Admin Tests ============

    function test_SetCCIPAdmin() public {
        vm.prank(owner);
        ldfProxy.setCCIPAdmin(user1);
        assertEq(ldfProxy.getCCIPAdmin(), user1);
    }

    function test_SetCCIPAdminZeroReverts() public {
        vm.prank(owner);
        vm.expectRevert(LDF.ZeroAddress.selector);
        ldfProxy.setCCIPAdmin(address(0));
    }

    // ============ Pause Tests ============

    function test_Pause() public {
        vm.prank(owner);
        ldfProxy.pause();
        assertTrue(ldfProxy.paused());
    }

    function test_PauseBridgeMintReverts() public {
        vm.startPrank(owner);
        ldfProxy.grantMinterRole(bridge);
        ldfProxy.pause();
        vm.stopPrank();

        vm.prank(bridge);
        vm.expectRevert();
        ldfProxy.mint(user1, 1000 ether);
    }

    function test_Unpause() public {
        vm.startPrank(owner);
        ldfProxy.pause();
        ldfProxy.unpause();
        vm.stopPrank();
        assertFalse(ldfProxy.paused());
    }

    // ============ Transfer Tests ============

    function test_Transfer() public {
        vm.prank(treasury);
        ldfProxy.transfer(user1, 1000 ether);
        assertEq(ldfProxy.balanceOf(user1), 1000 ether);
    }

    // ============ Supports Interface Tests ============

    function test_SupportsInterface() public view {
        // IERC20
        assertTrue(ldfProxy.supportsInterface(type(IERC20).interfaceId));
        // IBurnMintERC20
        assertTrue(ldfProxy.supportsInterface(type(IBurnMintERC20).interfaceId));
        // IERC165
        assertTrue(ldfProxy.supportsInterface(type(IERC165).interfaceId));
        // IGetCCIPAdmin
        assertTrue(ldfProxy.supportsInterface(type(IGetCCIPAdmin).interfaceId));
    }

    // ============ Upgrade Tests ============

    function test_UpgradeOnlyUpgrader() public {
        LDF newImpl = new LDF();

        vm.prank(user1);
        vm.expectRevert();
        ldfProxy.upgradeToAndCall(address(newImpl), "");
    }

    function test_UpgradeIncrementsVersion() public {
        LDF newImpl = new LDF();

        vm.prank(owner);
        ldfProxy.upgradeToAndCall(address(newImpl), "");

        assertEq(ldfProxy.version(), 2);
    }
}

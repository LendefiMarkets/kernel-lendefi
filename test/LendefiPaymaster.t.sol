// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "src/lendefi/LendefiStaking.sol";
import "src/lendefi/LendefiStakingPaymaster.sol";
import "src/interfaces/IEntryPoint.sol";
import "src/interfaces/PackedUserOperation.sol";
import "./mock/MockLDFI.sol";
import "./base/erc4337Util.sol";

/**
 * @title LendefiPaymasterTest
 * @notice Foundry tests for LendefiStakingPaymaster contract
 */
contract LendefiPaymasterTest is Test {
    LendefiStaking public staking;
    LendefiStakingPaymaster public paymaster;
    MockLDFI public ldfi;
    IEntryPoint public entryPoint;
    
    address public owner = address(0x1);
    address public user1 = address(0x2);
    address public user2 = address(0x3);

    // Tier thresholds
    uint256 constant BASIC_THRESHOLD = 1_000 * 1e18;
    uint256 constant PREMIUM_THRESHOLD = 10_000 * 1e18;
    uint256 constant ULTIMATE_THRESHOLD = 100_000 * 1e18;

    function setUp() public {
        // Deploy EntryPoint
        entryPoint = IEntryPoint(EntryPointLib.deploy());
        
        // Deploy mock LDFI token
        ldfi = new MockLDFI();
        
        // Deploy staking contract
        vm.prank(owner);
        staking = new LendefiStaking(ERC20(address(ldfi)), owner);
        
        // Deploy paymaster
        vm.prank(owner);
        paymaster = new LendefiStakingPaymaster(entryPoint, staking, owner);
        
        // Authorize paymaster in staking contract
        vm.prank(owner);
        staking.authorizePaymaster(address(paymaster));
        
        // Fund paymaster
        vm.deal(owner, 100 ether);
        vm.prank(owner);
        paymaster.deposit{value: 10 ether}();
        
        // Add stake to paymaster
        vm.prank(owner);
        paymaster.addStake{value: 1 ether}(86400);
        
        // Mint and stake tokens for users
        ldfi.mint(user1, 500_000 * 1e18);
        ldfi.mint(user2, 500_000 * 1e18);
        
        vm.prank(user1);
        ldfi.approve(address(staking), type(uint256).max);
        
        vm.prank(user2);
        ldfi.approve(address(staking), type(uint256).max);
    }

    // ============ Setup Tests ============

    function test_PaymasterDeployed() public {
        assertEq(address(paymaster.entryPoint()), address(entryPoint));
        assertEq(address(paymaster.stakingContract()), address(staking));
    }

    function test_PaymasterHasDeposit() public {
        assertGt(paymaster.getDeposit(), 0);
    }

    // ============ Eligibility Tests ============

    function test_CheckEligibilityNoStake() public {
        (bool eligible, LendefiStaking.Tier tier, uint256 subsidy) = paymaster.checkEligibility(user1, 100_000);
        
        assertFalse(eligible);
        assertEq(uint256(tier), uint256(LendefiStaking.Tier.NONE));
        assertEq(subsidy, 0);
    }

    function test_CheckEligibilityBasicTier() public {
        vm.prank(user1);
        staking.stake(BASIC_THRESHOLD);
        
        (bool eligible, LendefiStaking.Tier tier, uint256 subsidy) = paymaster.checkEligibility(user1, 100_000);
        
        assertTrue(eligible);
        assertEq(uint256(tier), uint256(LendefiStaking.Tier.BASIC));
        assertEq(subsidy, 50);
    }

    function test_CheckEligibilityPremiumTier() public {
        vm.prank(user1);
        staking.stake(PREMIUM_THRESHOLD);
        
        (bool eligible, LendefiStaking.Tier tier, uint256 subsidy) = paymaster.checkEligibility(user1, 100_000);
        
        assertTrue(eligible);
        assertEq(uint256(tier), uint256(LendefiStaking.Tier.PREMIUM));
        assertEq(subsidy, 90);
    }

    function test_CheckEligibilityUltimateTier() public {
        vm.prank(user1);
        staking.stake(ULTIMATE_THRESHOLD);
        
        (bool eligible, LendefiStaking.Tier tier, uint256 subsidy) = paymaster.checkEligibility(user1, 100_000);
        
        assertTrue(eligible);
        assertEq(uint256(tier), uint256(LendefiStaking.Tier.ULTIMATE));
        assertEq(subsidy, 100);
    }

    function test_CheckEligibilityGasExceedsMax() public {
        vm.prank(user1);
        staking.stake(ULTIMATE_THRESHOLD);
        
        // Request more gas than max allowed per operation
        uint256 tooMuchGas = paymaster.maxGasPerOperation() + 1;
        (bool eligible, , ) = paymaster.checkEligibility(user1, tooMuchGas);
        
        assertFalse(eligible);
    }

    // ============ Validation Tests ============

    function test_ValidatePaymasterUserOpNoStakeReverts() public {
        PackedUserOperation memory userOp = _createMockUserOp(user1);
        
        vm.prank(address(entryPoint));
        vm.expectRevert(LendefiStakingPaymaster.NoStake.selector);
        paymaster.validatePaymasterUserOp(userOp, bytes32(0), 1 ether);
    }

    function test_ValidatePaymasterUserOpWithStake() public {
        // User stakes to get tier
        vm.prank(user1);
        staking.stake(BASIC_THRESHOLD);
        
        PackedUserOperation memory userOp = _createMockUserOp(user1);
        
        vm.prank(address(entryPoint));
        (bytes memory context, uint256 validationData) = paymaster.validatePaymasterUserOp(userOp, bytes32(0), 0.1 ether);
        
        // Should succeed (validationData = 0 means success)
        assertEq(validationData, 0);
        assertGt(context.length, 0);
    }

    function test_ValidatePaymasterUserOpGasExceeded() public {
        vm.prank(user1);
        staking.stake(BASIC_THRESHOLD);
        
        // Create userOp with excessive gas
        PackedUserOperation memory userOp = _createMockUserOp(user1);
        userOp.accountGasLimits = bytes32(abi.encodePacked(uint128(1_000_000), uint128(1_000_000))); // 2M total
        
        vm.prank(address(entryPoint));
        vm.expectRevert(LendefiStakingPaymaster.GasLimitExceeded.selector);
        paymaster.validatePaymasterUserOp(userOp, bytes32(0), 1 ether);
    }

    function test_ValidatePaymasterUserOpMonthlyLimitExceeded() public {
        vm.prank(user1);
        staking.stake(BASIC_THRESHOLD);
        
        // Exhaust monthly gas limit via staking contract directly
        vm.prank(address(paymaster));
        staking.recordGasUsage(user1, 500_000); // Max for BASIC tier
        
        PackedUserOperation memory userOp = _createMockUserOp(user1);
        
        vm.prank(address(entryPoint));
        vm.expectRevert(LendefiStakingPaymaster.MonthlyLimitExceeded.selector);
        paymaster.validatePaymasterUserOp(userOp, bytes32(0), 0.1 ether);
    }

    function test_ValidateOnlyEntryPointCanCall() public {
        vm.prank(user1);
        staking.stake(BASIC_THRESHOLD);
        
        PackedUserOperation memory userOp = _createMockUserOp(user1);
        
        vm.prank(user1); // Not entrypoint
        vm.expectRevert(LendefiStakingPaymaster.NotFromEntryPoint.selector);
        paymaster.validatePaymasterUserOp(userOp, bytes32(0), 0.1 ether);
    }

    // ============ PostOp Tests ============

    function test_PostOpRecordsGasUsage() public {
        vm.prank(user1);
        staking.stake(BASIC_THRESHOLD);
        
        // Encode context (user, estimatedGas, subsidyAmount, tier)
        bytes memory context = abi.encode(
            user1,
            100_000, // estimated gas
            0.05 ether, // subsidy amount
            LendefiStaking.Tier.BASIC
        );
        
        vm.prank(address(entryPoint));
        paymaster.postOp(IPaymaster.PostOpMode.opSucceeded, context, 0.1 ether, 1 gwei);
        
        // Check gas was recorded
        (,,, uint256 gasUsed,,) = staking.getUserInfo(user1);
        assertEq(gasUsed, 100_000);
    }

    function test_PostOpOnlyEntryPoint() public {
        bytes memory context = abi.encode(user1, 100_000, 0.05 ether, LendefiStaking.Tier.BASIC);
        
        vm.prank(user1);
        vm.expectRevert(LendefiStakingPaymaster.NotFromEntryPoint.selector);
        paymaster.postOp(IPaymaster.PostOpMode.opSucceeded, context, 0.1 ether, 1 gwei);
    }

    // ============ Admin Tests ============

    function test_SetMaxGasPerOperation() public {
        uint256 newMax = 1_000_000;
        
        vm.prank(owner);
        paymaster.setMaxGasPerOperation(newMax);
        
        assertEq(paymaster.maxGasPerOperation(), newMax);
    }

    function test_SetMaxGasZeroReverts() public {
        vm.prank(owner);
        vm.expectRevert(LendefiStakingPaymaster.InvalidGasLimit.selector);
        paymaster.setMaxGasPerOperation(0);
    }

    function test_SetMinPaymasterDeposit() public {
        uint256 newMin = 0.5 ether;
        
        vm.prank(owner);
        paymaster.setMinPaymasterDeposit(newMin);
        
        assertEq(paymaster.minPaymasterDeposit(), newMin);
    }

    function test_WithdrawDeposit() public {
        uint256 balanceBefore = owner.balance;
        uint256 withdrawAmount = 1 ether;
        
        vm.prank(owner);
        paymaster.withdrawDeposit(payable(owner), withdrawAmount);
        
        assertEq(owner.balance, balanceBefore + withdrawAmount);
    }

    function test_OnlyOwnerCanWithdraw() public {
        vm.prank(user1);
        vm.expectRevert();
        paymaster.withdrawDeposit(payable(user1), 1 ether);
    }

    // ============ Helper Functions ============

    function _createMockUserOp(address sender) internal pure returns (PackedUserOperation memory) {
        return PackedUserOperation({
            sender: sender,
            nonce: 0,
            initCode: "",
            callData: "",
            accountGasLimits: bytes32(abi.encodePacked(uint128(100_000), uint128(100_000))),
            preVerificationGas: 50_000,
            gasFees: bytes32(abi.encodePacked(uint128(1 gwei), uint128(10 gwei))),
            paymasterAndData: "",
            signature: ""
        });
    }
}

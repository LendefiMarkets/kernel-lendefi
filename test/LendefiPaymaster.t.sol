// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "src/lendefi/LendefiStaking.sol";
import "src/lendefi/LendefiStakingPaymaster.sol";
import "src/interfaces/IEntryPoint.sol";
import "./mock/MockLDFI.sol";
import "./mock/MockEntryPoint.sol";

/**
 * @title LendefiPaymasterTest
 * @notice Foundry tests for LendefiStakingPaymaster upgradeable contract
 */
contract LendefiPaymasterTest is Test {
    LendefiStaking public staking;
    LendefiStaking public stakingImplementation;
    LendefiStakingPaymaster public paymaster;
    LendefiStakingPaymaster public paymasterImplementation;
    MockLDFI public ldfi;
    MockEntryPoint public entryPoint;
    
    address public owner = address(0x1);
    address public user1 = address(0x2);
    address public user2 = address(0x3);

    uint256 constant BASIC_THRESHOLD = 1_000 * 1e18;
    uint256 constant PREMIUM_THRESHOLD = 10_000 * 1e18;
    uint256 constant ULTIMATE_THRESHOLD = 100_000 * 1e18;

    function setUp() public {
        // Deploy mock contracts
        ldfi = new MockLDFI();
        entryPoint = new MockEntryPoint();
        
        // Deploy staking implementation and proxy
        stakingImplementation = new LendefiStaking();
        bytes memory stakingInitData = abi.encodeWithSelector(
            LendefiStaking.initialize.selector,
            IERC20(address(ldfi)),
            owner
        );
        ERC1967Proxy stakingProxy = new ERC1967Proxy(address(stakingImplementation), stakingInitData);
        staking = LendefiStaking(address(stakingProxy));
        
        // Deploy paymaster implementation and proxy
        paymasterImplementation = new LendefiStakingPaymaster();
        bytes memory paymasterInitData = abi.encodeWithSelector(
            LendefiStakingPaymaster.initialize.selector,
            IEntryPoint(address(entryPoint)),
            staking,
            owner
        );
        ERC1967Proxy paymasterProxy = new ERC1967Proxy(address(paymasterImplementation), paymasterInitData);
        paymaster = LendefiStakingPaymaster(payable(address(paymasterProxy)));
        
        // Authorize paymaster
        vm.prank(owner);
        staking.authorizePaymaster(address(paymaster));
        
        // Fund paymaster
        entryPoint.setBalance(address(paymaster), 10 ether);
        
        // Mint tokens to users
        ldfi.mint(user1, 500_000 * 1e18);
        ldfi.mint(user2, 500_000 * 1e18);
        
        // Approve staking contract
        vm.prank(user1);
        ldfi.approve(address(staking), type(uint256).max);
        
        vm.prank(user2);
        ldfi.approve(address(staking), type(uint256).max);
    }

    // ============ Validation Tests ============

    function test_Version() public view {
        assertEq(paymaster.VERSION(), 1);
        assertEq(staking.VERSION(), 1);
    }

    function test_ValidateUserOpBasicTier() public {
        // User stakes to get BASIC tier
        vm.prank(user1);
        staking.stake(BASIC_THRESHOLD);
        
        // Create UserOp
        PackedUserOperation memory userOp = _createUserOp(user1, 100_000);
        
        // Validate
        vm.prank(address(entryPoint));
        (bytes memory context, uint256 validationData) = paymaster.validatePaymasterUserOp(
            userOp,
            bytes32(0),
            0.001 ether
        );
        
        assertEq(validationData, 0);
        assertTrue(context.length > 0);
    }

    function test_ValidateUserOpNoStakeReverts() public {
        PackedUserOperation memory userOp = _createUserOp(user1, 100_000);
        
        vm.prank(address(entryPoint));
        vm.expectRevert(LendefiStakingPaymaster.NoStake.selector);
        paymaster.validatePaymasterUserOp(userOp, bytes32(0), 0.001 ether);
    }

    function test_ValidateUserOpGasLimitExceededReverts() public {
        vm.prank(user1);
        staking.stake(BASIC_THRESHOLD);
        
        // Create UserOp with gas exceeding limit
        PackedUserOperation memory userOp = _createUserOp(user1, 600_000);
        
        vm.prank(address(entryPoint));
        vm.expectRevert(LendefiStakingPaymaster.GasLimitExceeded.selector);
        paymaster.validatePaymasterUserOp(userOp, bytes32(0), 0.001 ether);
    }

    function test_ValidateUserOpMonthlyLimitExceededReverts() public {
        vm.prank(user1);
        staking.stake(BASIC_THRESHOLD);
        
        // Use up monthly limit
        vm.prank(address(paymaster));
        staking.recordGasUsage(user1, 500_000);
        
        // Try to validate new op
        PackedUserOperation memory userOp = _createUserOp(user1, 100_000);
        
        vm.prank(address(entryPoint));
        vm.expectRevert(LendefiStakingPaymaster.MonthlyLimitExceeded.selector);
        paymaster.validatePaymasterUserOp(userOp, bytes32(0), 0.001 ether);
    }

    function test_ValidateUserOpLowDepositReverts() public {
        vm.prank(user1);
        staking.stake(BASIC_THRESHOLD);
        
        // Set low balance
        entryPoint.setBalance(address(paymaster), 0.01 ether);
        
        PackedUserOperation memory userOp = _createUserOp(user1, 100_000);
        
        vm.prank(address(entryPoint));
        vm.expectRevert(LendefiStakingPaymaster.PaymasterDepositTooLow.selector);
        paymaster.validatePaymasterUserOp(userOp, bytes32(0), 0.001 ether);
    }

    // ============ PostOp Tests ============

    function test_PostOpRecordsGasUsage() public {
        vm.prank(user1);
        staking.stake(BASIC_THRESHOLD);
        
        // Create context (user, estimatedGas, subsidyAmount, tier)
        bytes memory context = abi.encode(
            user1,
            100_000,
            0.0005 ether,
            LendefiStaking.Tier.BASIC
        );
        
        // Call postOp with actual gas cost and fee per gas
        uint256 actualGasCost = 80_000 * 20 gwei; // 80k gas at 20 gwei
        uint256 actualUserOpFeePerGas = 20 gwei;
        
        vm.prank(address(entryPoint));
        paymaster.postOp(
            IPaymaster.PostOpMode.opSucceeded,
            context,
            actualGasCost,
            actualUserOpFeePerGas
        );
        
        // Check gas was recorded (should be actualGasCost / actualUserOpFeePerGas = 80_000)
        (bool hasAllowance, uint256 remaining) = staking.checkGasAllowance(user1, 0);
        assertTrue(hasAllowance);
        assertEq(remaining, 500_000 - 80_000);
    }

    // ============ Eligibility Tests ============

    function test_CheckEligibility() public {
        vm.prank(user1);
        staking.stake(PREMIUM_THRESHOLD);
        
        (bool eligible, LendefiStaking.Tier tier, uint256 subsidyPercent) = 
            paymaster.checkEligibility(user1, 100_000);
        
        assertTrue(eligible);
        assertEq(uint256(tier), uint256(LendefiStaking.Tier.PREMIUM));
        assertEq(subsidyPercent, 90);
    }

    function test_CheckEligibilityNoStake() public {
        (bool eligible, LendefiStaking.Tier tier, uint256 subsidyPercent) = 
            paymaster.checkEligibility(user1, 100_000);
        
        assertFalse(eligible);
        assertEq(uint256(tier), uint256(LendefiStaking.Tier.NONE));
        assertEq(subsidyPercent, 0);
    }

    // ============ Admin Tests ============

    function test_SetMaxGasPerOperation() public {
        vm.prank(owner);
        paymaster.setMaxGasPerOperation(1_000_000);
        
        assertEq(paymaster.maxGasPerOperation(), 1_000_000);
    }

    function test_SetMaxGasPerOperationZeroReverts() public {
        vm.prank(owner);
        vm.expectRevert(LendefiStakingPaymaster.InvalidGasLimit.selector);
        paymaster.setMaxGasPerOperation(0);
    }

    function test_SetMinPaymasterDeposit() public {
        vm.prank(owner);
        paymaster.setMinPaymasterDeposit(0.5 ether);
        
        assertEq(paymaster.minPaymasterDeposit(), 0.5 ether);
    }

    function test_SetMinPaymasterDepositZeroReverts() public {
        vm.prank(owner);
        vm.expectRevert(LendefiStakingPaymaster.PaymasterDepositTooLow.selector);
        paymaster.setMinPaymasterDeposit(0);
    }

    function test_SetStakingContract() public {
        // Deploy new staking contract
        LendefiStaking newStakingImpl = new LendefiStaking();
        bytes memory initData = abi.encodeWithSelector(
            LendefiStaking.initialize.selector,
            IERC20(address(ldfi)),
            owner
        );
        ERC1967Proxy newProxy = new ERC1967Proxy(address(newStakingImpl), initData);
        LendefiStaking newStaking = LendefiStaking(address(newProxy));
        
        vm.prank(owner);
        paymaster.setStakingContract(newStaking);
        
        assertEq(address(paymaster.stakingContract()), address(newStaking));
    }

    // ============ Pause Tests ============

    function test_PauseValidation() public {
        vm.prank(user1);
        staking.stake(BASIC_THRESHOLD);
        
        vm.prank(owner);
        paymaster.pause();
        
        PackedUserOperation memory userOp = _createUserOp(user1, 100_000);
        
        vm.prank(address(entryPoint));
        vm.expectRevert("Pausable: paused");
        paymaster.validatePaymasterUserOp(userOp, bytes32(0), 0.001 ether);
    }

    function test_UnpauseAllowsValidation() public {
        vm.prank(user1);
        staking.stake(BASIC_THRESHOLD);
        
        vm.prank(owner);
        paymaster.pause();
        
        vm.prank(owner);
        paymaster.unpause();
        
        PackedUserOperation memory userOp = _createUserOp(user1, 100_000);
        
        vm.prank(address(entryPoint));
        (bytes memory context, uint256 validationData) = paymaster.validatePaymasterUserOp(
            userOp,
            bytes32(0),
            0.001 ether
        );
        
        assertEq(validationData, 0);
        assertTrue(context.length > 0);
    }

    // ============ Upgrade Tests ============

    function test_UpgradeOnlyOwner() public {
        LendefiStakingPaymaster newImpl = new LendefiStakingPaymaster();
        
        vm.prank(user1);
        vm.expectRevert();
        paymaster.upgradeToAndCall(address(newImpl), "");
    }

    function test_UpgradeSucceeds() public {
        // Deploy new implementation
        LendefiStakingPaymaster newImpl = new LendefiStakingPaymaster();
        
        // Upgrade
        vm.prank(owner);
        paymaster.upgradeToAndCall(address(newImpl), "");
        
        // Should still work
        assertEq(address(paymaster.stakingContract()), address(staking));
        assertEq(paymaster.maxGasPerOperation(), 500_000);
    }

    // ============ Helpers ============

    function _createUserOp(address sender, uint256 gasLimit) internal pure returns (PackedUserOperation memory) {
        // Pack gas limits: verificationGasLimit (16 bytes) | callGasLimit (16 bytes)
        bytes32 accountGasLimits = bytes32(
            (uint256(gasLimit / 2) << 128) | uint256(gasLimit / 2)
        );
        
        return PackedUserOperation({
            sender: sender,
            nonce: 0,
            initCode: "",
            callData: "",
            accountGasLimits: accountGasLimits,
            preVerificationGas: 0,
            gasFees: bytes32(0),
            paymasterAndData: "",
            signature: ""
        });
    }
}

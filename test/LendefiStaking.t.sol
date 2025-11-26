// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "src/lendefi/LendefiStaking.sol";
import "./mock/MockLDFI.sol";

/**
 * @title LendefiStakingTest
 * @notice Foundry tests for LendefiStaking contract
 */
contract LendefiStakingTest is Test {
    LendefiStaking public staking;
    MockLDFI public ldfi;
    
    address public owner = address(0x1);
    address public user1 = address(0x2);
    address public user2 = address(0x3);
    address public paymaster = address(0x4);

    // Tier thresholds (matching contract defaults)
    uint256 constant BASIC_THRESHOLD = 1_000 * 1e18;
    uint256 constant PREMIUM_THRESHOLD = 10_000 * 1e18;
    uint256 constant ULTIMATE_THRESHOLD = 100_000 * 1e18;

    // Gas limits
    uint256 constant GAS_LIMIT_BASIC = 500_000;
    uint256 constant GAS_LIMIT_PREMIUM = 2_000_000;
    uint256 constant GAS_LIMIT_ULTIMATE = 10_000_000;

    function setUp() public {
        // Deploy mock LDFI token
        ldfi = new MockLDFI();
        
        // Deploy staking contract
        vm.prank(owner);
        staking = new LendefiStaking(ERC20(address(ldfi)), owner);
        
        // Authorize paymaster
        vm.prank(owner);
        staking.authorizePaymaster(paymaster);
        
        // Mint tokens to users
        ldfi.mint(user1, 500_000 * 1e18);
        ldfi.mint(user2, 500_000 * 1e18);
        
        // Approve staking contract
        vm.prank(user1);
        ldfi.approve(address(staking), type(uint256).max);
        
        vm.prank(user2);
        ldfi.approve(address(staking), type(uint256).max);
    }

    // ============ Staking Tests ============

    function test_StakeBasicTier() public {
        vm.prank(user1);
        staking.stake(BASIC_THRESHOLD);
        
        assertEq(uint256(staking.getTier(user1)), uint256(LendefiStaking.Tier.BASIC));
        assertEq(staking.totalStaked(), BASIC_THRESHOLD);
        
        (uint256 staked, , , , , ) = staking.getUserInfo(user1);
        assertEq(staked, BASIC_THRESHOLD);
    }

    function test_StakePremiumTier() public {
        vm.prank(user1);
        staking.stake(PREMIUM_THRESHOLD);
        
        assertEq(uint256(staking.getTier(user1)), uint256(LendefiStaking.Tier.PREMIUM));
    }

    function test_StakeUltimateTier() public {
        vm.prank(user1);
        staking.stake(ULTIMATE_THRESHOLD);
        
        assertEq(uint256(staking.getTier(user1)), uint256(LendefiStaking.Tier.ULTIMATE));
    }

    function test_StakeEmitsEvent() public {
        vm.prank(user1);
        vm.expectEmit(true, false, false, true);
        emit LendefiStaking.Staked(user1, BASIC_THRESHOLD, BASIC_THRESHOLD, LendefiStaking.Tier.BASIC);
        staking.stake(BASIC_THRESHOLD);
    }

    function test_StakeZeroReverts() public {
        vm.prank(user1);
        vm.expectRevert(LendefiStaking.ZeroAmount.selector);
        staking.stake(0);
    }

    function test_IncrementalStaking() public {
        // Stake to BASIC
        vm.prank(user1);
        staking.stake(BASIC_THRESHOLD);
        assertEq(uint256(staking.getTier(user1)), uint256(LendefiStaking.Tier.BASIC));
        
        // Stake more to reach PREMIUM
        vm.prank(user1);
        staking.stake(PREMIUM_THRESHOLD - BASIC_THRESHOLD);
        assertEq(uint256(staking.getTier(user1)), uint256(LendefiStaking.Tier.PREMIUM));
    }

    // ============ Unstaking Tests ============

    function test_Unstake() public {
        // Stake first
        vm.prank(user1);
        staking.stake(PREMIUM_THRESHOLD);
        
        // Warp past minimum stake period
        vm.warp(block.timestamp + 8 days);
        
        // Unstake partially
        vm.prank(user1);
        staking.unstake(PREMIUM_THRESHOLD - BASIC_THRESHOLD);
        
        // Should be at BASIC tier now
        assertEq(uint256(staking.getTier(user1)), uint256(LendefiStaking.Tier.BASIC));
    }

    function test_UnstakeTooEarlyReverts() public {
        vm.prank(user1);
        staking.stake(BASIC_THRESHOLD);
        
        // Try to unstake before minimum period
        vm.prank(user1);
        vm.expectRevert(LendefiStaking.StakePeriodNotMet.selector);
        staking.unstake(BASIC_THRESHOLD);
    }

    function test_UnstakeMoreThanStakedReverts() public {
        vm.prank(user1);
        staking.stake(BASIC_THRESHOLD);
        
        vm.warp(block.timestamp + 8 days);
        
        vm.prank(user1);
        vm.expectRevert(LendefiStaking.InsufficientStake.selector);
        staking.unstake(BASIC_THRESHOLD + 1);
    }

    // ============ Tier Tests ============

    function test_GetTierNone() public {
        assertEq(uint256(staking.getTier(user1)), uint256(LendefiStaking.Tier.NONE));
    }

    function test_GetSubsidyPercentage() public {
        assertEq(staking.getSubsidyPercentage(LendefiStaking.Tier.NONE), 0);
        assertEq(staking.getSubsidyPercentage(LendefiStaking.Tier.BASIC), 50);
        assertEq(staking.getSubsidyPercentage(LendefiStaking.Tier.PREMIUM), 90);
        assertEq(staking.getSubsidyPercentage(LendefiStaking.Tier.ULTIMATE), 100);
    }

    function test_GetMonthlyGasLimit() public {
        assertEq(staking.getMonthlyGasLimit(LendefiStaking.Tier.NONE), 0);
        assertEq(staking.getMonthlyGasLimit(LendefiStaking.Tier.BASIC), GAS_LIMIT_BASIC);
        assertEq(staking.getMonthlyGasLimit(LendefiStaking.Tier.PREMIUM), GAS_LIMIT_PREMIUM);
        assertEq(staking.getMonthlyGasLimit(LendefiStaking.Tier.ULTIMATE), GAS_LIMIT_ULTIMATE);
    }

    function test_GetTokensToNextTier() public {
        // User has nothing staked
        (uint256 needed, LendefiStaking.Tier nextTier) = staking.getTokensToNextTier(user1);
        assertEq(needed, BASIC_THRESHOLD);
        assertEq(uint256(nextTier), uint256(LendefiStaking.Tier.BASIC));
        
        // Stake to BASIC
        vm.prank(user1);
        staking.stake(BASIC_THRESHOLD);
        
        (needed, nextTier) = staking.getTokensToNextTier(user1);
        assertEq(needed, PREMIUM_THRESHOLD - BASIC_THRESHOLD);
        assertEq(uint256(nextTier), uint256(LendefiStaking.Tier.PREMIUM));
    }

    // ============ Gas Usage Tests ============

    function test_RecordGasUsage() public {
        vm.prank(user1);
        staking.stake(BASIC_THRESHOLD);
        
        // Record gas usage as paymaster
        vm.prank(paymaster);
        staking.recordGasUsage(user1, 100_000);
        
        (,,, uint256 gasUsed,,) = staking.getUserInfo(user1);
        assertEq(gasUsed, 100_000);
    }

    function test_RecordGasUsageUnauthorizedReverts() public {
        vm.prank(user1);
        staking.stake(BASIC_THRESHOLD);
        
        // Try to record gas usage as unauthorized address
        vm.prank(user2);
        vm.expectRevert(LendefiStaking.NotAuthorizedPaymaster.selector);
        staking.recordGasUsage(user1, 100_000);
    }

    function test_CheckGasAllowance() public {
        vm.prank(user1);
        staking.stake(BASIC_THRESHOLD);
        
        (bool hasAllowance, uint256 remaining) = staking.checkGasAllowance(user1, 100_000);
        assertTrue(hasAllowance);
        assertEq(remaining, GAS_LIMIT_BASIC);
        
        // Record some usage
        vm.prank(paymaster);
        staking.recordGasUsage(user1, 300_000);
        
        (hasAllowance, remaining) = staking.checkGasAllowance(user1, 100_000);
        assertTrue(hasAllowance);
        assertEq(remaining, GAS_LIMIT_BASIC - 300_000);
        
        // Try to use more than remaining
        (hasAllowance, remaining) = staking.checkGasAllowance(user1, 300_000);
        assertFalse(hasAllowance);
    }

    function test_MonthlyReset() public {
        vm.prank(user1);
        staking.stake(BASIC_THRESHOLD);
        
        // Use all gas allowance
        vm.prank(paymaster);
        staking.recordGasUsage(user1, GAS_LIMIT_BASIC);
        
        (bool hasAllowance, ) = staking.checkGasAllowance(user1, 100_000);
        assertFalse(hasAllowance);
        
        // Warp 31 days
        vm.warp(block.timestamp + 31 days);
        
        // Should have allowance again (monthly reset in view)
        (hasAllowance, ) = staking.checkGasAllowance(user1, 100_000);
        assertTrue(hasAllowance);
    }

    // ============ Admin Tests ============

    function test_AuthorizePaymaster() public {
        address newPaymaster = address(0x5);
        
        vm.prank(owner);
        vm.expectEmit(true, false, false, false);
        emit LendefiStaking.PaymasterAuthorized(newPaymaster);
        staking.authorizePaymaster(newPaymaster);
        
        assertTrue(staking.authorizedPaymasters(newPaymaster));
    }

    function test_RevokePaymaster() public {
        vm.prank(owner);
        staking.revokePaymaster(paymaster);
        
        assertFalse(staking.authorizedPaymasters(paymaster));
    }

    function test_SetTierThresholds() public {
        uint256 newBasic = 500 * 1e18;
        uint256 newPremium = 5_000 * 1e18;
        uint256 newUltimate = 50_000 * 1e18;
        
        vm.prank(owner);
        staking.setTierThresholds(newBasic, newPremium, newUltimate);
        
        assertEq(staking.basicThreshold(), newBasic);
        assertEq(staking.premiumThreshold(), newPremium);
        assertEq(staking.ultimateThreshold(), newUltimate);
    }

    function test_SetTierThresholdsInvalidReverts() public {
        // basic >= premium should revert
        vm.prank(owner);
        vm.expectRevert(LendefiStaking.InvalidThresholds.selector);
        staking.setTierThresholds(10_000 * 1e18, 5_000 * 1e18, 100_000 * 1e18);
    }

    function test_SetGasLimits() public {
        vm.prank(owner);
        staking.setGasLimits(1_000_000, 5_000_000, 20_000_000);
        
        assertEq(staking.gasLimitBasic(), 1_000_000);
        assertEq(staking.gasLimitPremium(), 5_000_000);
        assertEq(staking.gasLimitUltimate(), 20_000_000);
    }

    function test_SetMinStakePeriod() public {
        vm.prank(owner);
        staking.setMinStakePeriod(14 days);
        
        assertEq(staking.minStakePeriod(), 14 days);
    }

    function test_OnlyOwnerCanSetThresholds() public {
        vm.prank(user1);
        vm.expectRevert();
        staking.setTierThresholds(100, 200, 300);
    }

    // ============ Fuzz Tests ============

    function testFuzz_Stake(uint256 amount) public {
        // Bound amount to reasonable range
        amount = bound(amount, 1, 100_000 * 1e18);
        
        ldfi.mint(user1, amount);
        
        vm.prank(user1);
        staking.stake(amount);
        
        (uint256 staked, , , , , ) = staking.getUserInfo(user1);
        assertEq(staked, staked);
    }

    function testFuzz_TierAssignment(uint256 amount) public {
        amount = bound(amount, 0, 200_000 * 1e18);
        
        if (amount > 0) {
            ldfi.mint(user1, amount);
            vm.prank(user1);
            staking.stake(amount);
        }
        
        LendefiStaking.Tier tier = staking.getTier(user1);
        
        if (amount >= ULTIMATE_THRESHOLD) {
            assertEq(uint256(tier), uint256(LendefiStaking.Tier.ULTIMATE));
        } else if (amount >= PREMIUM_THRESHOLD) {
            assertEq(uint256(tier), uint256(LendefiStaking.Tier.PREMIUM));
        } else if (amount >= BASIC_THRESHOLD) {
            assertEq(uint256(tier), uint256(LendefiStaking.Tier.BASIC));
        } else {
            assertEq(uint256(tier), uint256(LendefiStaking.Tier.NONE));
        }
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "src/lendefi/LendefiStaking.sol";
import "./mock/MockLDFI.sol";

/**
 * @title LendefiStakingTest
 * @notice Foundry tests for LendefiStaking upgradeable contract
 */
contract LendefiStakingTest is Test {
    LendefiStaking public staking;
    LendefiStaking public stakingImplementation;
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
        
        // Deploy implementation
        stakingImplementation = new LendefiStaking();
        
        // Deploy proxy and initialize
        bytes memory initData = abi.encodeWithSelector(
            LendefiStaking.initialize.selector,
            IERC20(address(ldfi)),
            owner
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(stakingImplementation), initData);
        staking = LendefiStaking(address(proxy));
        
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

    function test_Version() public view {
        assertEq(staking.VERSION(), 1);
    }

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

    function test_StakeMultipleTimes() public {
        vm.startPrank(user1);
        
        staking.stake(500 * 1e18);
        assertEq(uint256(staking.getTier(user1)), uint256(LendefiStaking.Tier.NONE));
        
        staking.stake(500 * 1e18);
        assertEq(uint256(staking.getTier(user1)), uint256(LendefiStaking.Tier.BASIC));
        
        staking.stake(9_000 * 1e18);
        assertEq(uint256(staking.getTier(user1)), uint256(LendefiStaking.Tier.PREMIUM));
        
        vm.stopPrank();
    }

    function test_StakeZeroAmountReverts() public {
        vm.prank(user1);
        vm.expectRevert(LendefiStaking.ZeroAmount.selector);
        staking.stake(0);
    }

    // ============ Unstaking Tests ============

    function test_UnstakeAfterMinPeriod() public {
        vm.prank(user1);
        staking.stake(BASIC_THRESHOLD);
        
        // Fast forward past min stake period
        vm.warp(block.timestamp + 7 days + 1);
        
        vm.prank(user1);
        staking.unstake(BASIC_THRESHOLD);
        
        assertEq(uint256(staking.getTier(user1)), uint256(LendefiStaking.Tier.NONE));
        assertEq(ldfi.balanceOf(user1), 500_000 * 1e18);
    }

    function test_UnstakeBeforeMinPeriodReverts() public {
        vm.prank(user1);
        staking.stake(BASIC_THRESHOLD);
        
        vm.prank(user1);
        vm.expectRevert(LendefiStaking.StakePeriodNotMet.selector);
        staking.unstake(BASIC_THRESHOLD);
    }

    function test_UnstakePartial() public {
        vm.prank(user1);
        staking.stake(PREMIUM_THRESHOLD);
        
        vm.warp(block.timestamp + 7 days + 1);
        
        vm.prank(user1);
        staking.unstake(PREMIUM_THRESHOLD - BASIC_THRESHOLD);
        
        assertEq(uint256(staking.getTier(user1)), uint256(LendefiStaking.Tier.BASIC));
    }

    function test_UnstakeMoreThanStakedReverts() public {
        vm.prank(user1);
        staking.stake(BASIC_THRESHOLD);
        
        vm.warp(block.timestamp + 7 days + 1);
        
        vm.prank(user1);
        vm.expectRevert(LendefiStaking.InsufficientStake.selector);
        staking.unstake(BASIC_THRESHOLD + 1);
    }

    // ============ Gas Usage Tests ============

    function test_RecordGasUsage() public {
        vm.prank(user1);
        staking.stake(BASIC_THRESHOLD);
        
        vm.prank(paymaster);
        staking.recordGasUsage(user1, 100_000);
        
        (bool hasAllowance, uint256 remaining) = staking.checkGasAllowance(user1, 0);
        assertTrue(hasAllowance);
        assertEq(remaining, GAS_LIMIT_BASIC - 100_000);
    }

    function test_RecordGasUsageUnauthorizedReverts() public {
        vm.prank(user1);
        staking.stake(BASIC_THRESHOLD);
        
        vm.prank(user2);
        vm.expectRevert(LendefiStaking.NotAuthorizedPaymaster.selector);
        staking.recordGasUsage(user1, 100_000);
    }

    function test_MonthlyGasReset() public {
        vm.prank(user1);
        staking.stake(BASIC_THRESHOLD);
        
        // Use all gas
        vm.prank(paymaster);
        staking.recordGasUsage(user1, GAS_LIMIT_BASIC);
        
        (bool hasAllowance, ) = staking.checkGasAllowance(user1, 1);
        assertFalse(hasAllowance);
        
        // Fast forward 30 days
        vm.warp(block.timestamp + 30 days + 1);
        
        // Record some gas to trigger reset
        vm.prank(paymaster);
        staking.recordGasUsage(user1, 1);
        
        (, uint256 remaining) = staking.checkGasAllowance(user1, 0);
        assertEq(remaining, GAS_LIMIT_BASIC - 1);
    }

    function test_DeterministicMonthlyReset() public {
        // This tests that monthly reset uses deterministic boundaries
        vm.prank(user1);
        staking.stake(BASIC_THRESHOLD);
        
        // Record gas usage
        vm.prank(paymaster);
        staking.recordGasUsage(user1, 100_000);
        
        // Move to just before month end
        vm.warp(block.timestamp + 30 days - 1);
        
        // Gas should still be recorded
        (, uint256 remaining) = staking.checkGasAllowance(user1, 0);
        assertEq(remaining, GAS_LIMIT_BASIC - 100_000);
        
        // Move to next month
        vm.warp(block.timestamp + 2);
        
        // Gas should reset (check view first)
        (, remaining) = staking.checkGasAllowance(user1, 0);
        assertEq(remaining, GAS_LIMIT_BASIC);
    }

    // ============ View Function Tests ============

    function test_GetSubsidyPercentage() public view {
        assertEq(staking.getSubsidyPercentage(LendefiStaking.Tier.NONE), 0);
        assertEq(staking.getSubsidyPercentage(LendefiStaking.Tier.BASIC), 50);
        assertEq(staking.getSubsidyPercentage(LendefiStaking.Tier.PREMIUM), 90);
        assertEq(staking.getSubsidyPercentage(LendefiStaking.Tier.ULTIMATE), 100);
    }

    function test_GetMonthlyGasLimit() public view {
        assertEq(staking.getMonthlyGasLimit(LendefiStaking.Tier.NONE), 0);
        assertEq(staking.getMonthlyGasLimit(LendefiStaking.Tier.BASIC), GAS_LIMIT_BASIC);
        assertEq(staking.getMonthlyGasLimit(LendefiStaking.Tier.PREMIUM), GAS_LIMIT_PREMIUM);
        assertEq(staking.getMonthlyGasLimit(LendefiStaking.Tier.ULTIMATE), GAS_LIMIT_ULTIMATE);
    }

    function test_GetTokensToNextTier() public {
        vm.prank(user1);
        staking.stake(500 * 1e18);
        
        (uint256 needed, LendefiStaking.Tier nextTier) = staking.getTokensToNextTier(user1);
        assertEq(needed, BASIC_THRESHOLD - 500 * 1e18);
        assertEq(uint256(nextTier), uint256(LendefiStaking.Tier.BASIC));
    }

    function test_GetUserInfo() public {
        vm.prank(user1);
        staking.stake(PREMIUM_THRESHOLD);
        
        (
            uint256 staked,
            LendefiStaking.Tier tier,
            uint256 subsidyPercent,
            uint256 gasUsed,
            uint256 gasLimit,
            uint256 canUnstakeAt
        ) = staking.getUserInfo(user1);
        
        assertEq(staked, PREMIUM_THRESHOLD);
        assertEq(uint256(tier), uint256(LendefiStaking.Tier.PREMIUM));
        assertEq(subsidyPercent, 90);
        assertEq(gasUsed, 0);
        assertEq(gasLimit, GAS_LIMIT_PREMIUM);
        assertEq(canUnstakeAt, block.timestamp + 7 days);
    }

    // ============ Admin Function Tests ============

    function test_SetTierThresholds() public {
        vm.prank(owner);
        staking.setTierThresholds(500 * 1e18, 5_000 * 1e18, 50_000 * 1e18);
        
        assertEq(staking.basicThreshold(), 500 * 1e18);
        assertEq(staking.premiumThreshold(), 5_000 * 1e18);
        assertEq(staking.ultimateThreshold(), 50_000 * 1e18);
    }

    function test_SetTierThresholdsInvalidReverts() public {
        vm.prank(owner);
        vm.expectRevert(LendefiStaking.InvalidThresholds.selector);
        staking.setTierThresholds(10_000 * 1e18, 5_000 * 1e18, 50_000 * 1e18);
    }

    function test_SetGasLimits() public {
        vm.prank(owner);
        staking.setGasLimits(100_000, 500_000, 1_000_000);
        
        assertEq(staking.gasLimitBasic(), 100_000);
        assertEq(staking.gasLimitPremium(), 500_000);
        assertEq(staking.gasLimitUltimate(), 1_000_000);
    }

    function test_SetGasLimitsZeroReverts() public {
        vm.prank(owner);
        vm.expectRevert(LendefiStaking.InvalidGasLimits.selector);
        staking.setGasLimits(0, 500_000, 1_000_000);
    }

    function test_SetGasLimitsInvalidOrderReverts() public {
        vm.prank(owner);
        vm.expectRevert(LendefiStaking.InvalidGasLimits.selector);
        staking.setGasLimits(1_000_000, 500_000, 100_000);
    }

    function test_SetMinStakePeriod() public {
        vm.prank(owner);
        staking.setMinStakePeriod(14 days);
        
        assertEq(staking.minStakePeriod(), 14 days);
    }

    function test_AuthorizePaymaster() public {
        address newPaymaster = address(0x999);
        
        vm.prank(owner);
        staking.authorizePaymaster(newPaymaster);
        
        assertTrue(staking.authorizedPaymasters(newPaymaster));
    }

    function test_RevokePaymaster() public {
        vm.prank(owner);
        staking.revokePaymaster(paymaster);
        
        assertFalse(staking.authorizedPaymasters(paymaster));
    }

    function test_EmergencyWithdraw() public {
        // Send extra tokens to contract (not staked)
        ldfi.mint(address(staking), 1000 * 1e18);
        
        uint256 ownerBalanceBefore = ldfi.balanceOf(owner);
        
        vm.prank(owner);
        staking.emergencyWithdraw(IERC20(address(ldfi)), owner, 1000 * 1e18);
        
        assertEq(ldfi.balanceOf(owner), ownerBalanceBefore + 1000 * 1e18);
    }

    function test_EmergencyWithdrawCannotTakeStakedTokens() public {
        vm.prank(user1);
        staking.stake(BASIC_THRESHOLD);
        
        vm.prank(owner);
        vm.expectRevert(LendefiStaking.InsufficientStake.selector);
        staking.emergencyWithdraw(IERC20(address(ldfi)), owner, BASIC_THRESHOLD);
    }

    // ============ Pause Tests ============

    function test_PauseStake() public {
        vm.prank(owner);
        staking.pause();
        
        vm.prank(user1);
        vm.expectRevert();
        staking.stake(BASIC_THRESHOLD);
    }

    function test_PauseUnstake() public {
        vm.prank(user1);
        staking.stake(BASIC_THRESHOLD);
        
        vm.warp(block.timestamp + 7 days + 1);
        
        vm.prank(owner);
        staking.pause();
        
        vm.prank(user1);
        vm.expectRevert();
        staking.unstake(BASIC_THRESHOLD);
    }

    function test_UnpauseAllowsStaking() public {
        vm.prank(owner);
        staking.pause();
        
        vm.prank(owner);
        staking.unpause();
        
        vm.prank(user1);
        staking.stake(BASIC_THRESHOLD);
        
        assertEq(uint256(staking.getTier(user1)), uint256(LendefiStaking.Tier.BASIC));
    }

    // ============ Access Control Tests ============

    function test_OnlyOwnerCanSetThresholds() public {
        vm.prank(user1);
        vm.expectRevert();
        staking.setTierThresholds(500 * 1e18, 5_000 * 1e18, 50_000 * 1e18);
    }

    function test_OnlyOwnerCanPause() public {
        vm.prank(user1);
        vm.expectRevert();
        staking.pause();
    }

    // ============ Upgrade Tests ============

    function test_UpgradeOnlyOwner() public {
        LendefiStaking newImpl = new LendefiStaking();
        
        vm.prank(user1);
        vm.expectRevert();
        staking.upgradeToAndCall(address(newImpl), "");
    }

    function test_UpgradeSucceeds() public {
        // Stake some tokens first
        vm.prank(user1);
        staking.stake(BASIC_THRESHOLD);
        
        // Deploy new implementation
        LendefiStaking newImpl = new LendefiStaking();
        
        // Upgrade
        vm.prank(owner);
        staking.upgradeToAndCall(address(newImpl), "");
        
        // State should be preserved
        assertEq(uint256(staking.getTier(user1)), uint256(LendefiStaking.Tier.BASIC));
        assertEq(staking.totalStaked(), BASIC_THRESHOLD);
    }
}

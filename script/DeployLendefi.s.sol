// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import "forge-std/console.sol";

import "src/lendefi/LendefiStaking.sol";
import "src/lendefi/LendefiStakingPaymaster.sol";
import "src/interfaces/IEntryPoint.sol";
import "solady/tokens/ERC20.sol";

/**
 * @title DeployStakingOnly
 * @notice Deploy LendefiStaking contract only
 * 
 * Usage:
 *   npm run deploy:staking
 * 
 * Required .env:
 *   PRIVATE_KEY, LDFI_TOKEN, OWNER, RPC_URL
 */
contract DeployStakingOnly is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address ldfiToken = vm.envAddress("LDFI_TOKEN");
        address owner = vm.envAddress("OWNER");

        console.log("=== Deploy LendefiStaking ===");
        console.log("LDFI Token:", ldfiToken);
        console.log("Owner:", owner);

        vm.startBroadcast(deployerPrivateKey);

        LendefiStaking staking = new LendefiStaking(ERC20(ldfiToken), owner);
        console.log("LendefiStaking deployed:", address(staking));

        vm.stopBroadcast();

        console.log("");
        console.log("Add to .env: STAKING_ADDRESS=", address(staking));
    }
}

/**
 * @title DeployPaymasterOnly
 * @notice Deploy LendefiStakingPaymaster contract only
 * 
 * Usage:
 *   npm run deploy:paymaster
 * 
 * Required .env:
 *   PRIVATE_KEY, STAKING_ADDRESS, OWNER, RPC_URL
 */
contract DeployPaymasterOnly is Script {
    address constant ENTRYPOINT_V07 = 0x0000000071727De22E5E9d8BAf0edAc6f37da032;
    address constant ENTRYPOINT_V08 = 0x4337084D9E255Ff0702461CF8895CE9E3b5Ff108;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address stakingAddress = vm.envAddress("STAKING_ADDRESS");
        address owner = vm.envAddress("OWNER");
        
        address entryPoint = vm.envOr("USE_ENTRYPOINT_V08", false) 
            ? ENTRYPOINT_V08 
            : ENTRYPOINT_V07;

        console.log("=== Deploy LendefiStakingPaymaster ===");
        console.log("Staking:", stakingAddress);
        console.log("Owner:", owner);
        console.log("EntryPoint:", entryPoint);

        vm.startBroadcast(deployerPrivateKey);

        LendefiStakingPaymaster paymaster = new LendefiStakingPaymaster(
            IEntryPoint(entryPoint),
            LendefiStaking(stakingAddress),
            owner
        );
        console.log("LendefiStakingPaymaster deployed:", address(paymaster));

        // Authorize paymaster in staking contract
        LendefiStaking(stakingAddress).authorizePaymaster(address(paymaster));
        console.log("Paymaster authorized in staking contract");

        vm.stopBroadcast();

        console.log("");
        console.log("Add to .env: PAYMASTER_ADDRESS=", address(paymaster));
        console.log("");
        console.log("Next: npm run fund:paymaster");
    }
}

/**
 * @title FundPaymaster
 * @notice Fund an existing paymaster with ETH deposit and stake
 * 
 * Usage:
 *   npm run fund:paymaster
 * 
 * Required .env:
 *   PRIVATE_KEY, PAYMASTER_ADDRESS, RPC_URL
 * 
 * Optional .env:
 *   DEPOSIT_AMOUNT (default: 1 ETH)
 *   STAKE_AMOUNT (default: 0.1 ETH)
 *   UNSTAKE_DELAY (default: 86400 = 1 day)
 */
contract FundPaymaster is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address payable paymaster = payable(vm.envAddress("PAYMASTER_ADDRESS"));
        uint256 depositAmount = vm.envOr("DEPOSIT_AMOUNT", uint256(1 ether));
        uint256 stakeAmount = vm.envOr("STAKE_AMOUNT", uint256(0.1 ether));
        uint32 unstakeDelaySec = uint32(vm.envOr("UNSTAKE_DELAY", uint256(86400)));

        console.log("=== Fund Paymaster ===");
        console.log("Paymaster:", paymaster);
        console.log("Deposit:", depositAmount);
        console.log("Stake:", stakeAmount);

        vm.startBroadcast(deployerPrivateKey);

        LendefiStakingPaymaster(paymaster).deposit{value: depositAmount}();
        console.log("Deposited", depositAmount, "wei");

        LendefiStakingPaymaster(paymaster).addStake{value: stakeAmount}(unstakeDelaySec);
        console.log("Staked with delay:", unstakeDelaySec);

        vm.stopBroadcast();

        console.log("");
        console.log("=== Paymaster Ready! ===");
        console.log("Configure Privy with this paymaster address");
    }
}

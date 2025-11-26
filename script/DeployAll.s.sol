// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import "forge-std/console.sol";

import "src/Kernel.sol";
import "src/factory/KernelFactory.sol";
import "src/lendefi/LendefiStaking.sol";
import "src/lendefi/LendefiStakingPaymaster.sol";
import "src/interfaces/IEntryPoint.sol";
import "solady/tokens/ERC20.sol";

/**
 * @title DeployKernelOnly
 * @notice Deploy Kernel implementation and factory
 * 
 * Usage:
 *   npm run deploy:kernel
 */
contract DeployKernelOnly is Script {
    address constant ENTRYPOINT_V07 = 0x0000000071727De22E5E9d8BAf0edAc6f37da032;
    address constant ENTRYPOINT_V08 = 0x4337084D9E255Ff0702461CF8895CE9E3b5Ff108;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        
        address entryPoint = vm.envOr("USE_ENTRYPOINT_V08", false) 
            ? ENTRYPOINT_V08 
            : ENTRYPOINT_V07;

        console.log("=== Kernel Deployment ===");
        console.log("EntryPoint:", entryPoint);

        vm.startBroadcast(deployerPrivateKey);

        // Deploy Kernel implementation
        Kernel kernel = new Kernel(IEntryPoint(entryPoint));
        console.log("Kernel Implementation:", address(kernel));

        // Deploy KernelFactory
        KernelFactory factory = new KernelFactory(address(kernel));
        console.log("KernelFactory:", address(factory));

        vm.stopBroadcast();

        console.log("");
        console.log("=== Kernel Deployment Complete ===");
        console.log("KERNEL_IMPL:", address(kernel));
        console.log("KERNEL_FACTORY:", address(factory));
    }
}

/**
 * @title DeployAll
 * @notice Deploy everything: Kernel + Factory + Staking + Paymaster
 * 
 * Usage:
 *   npm run deploy:all
 */
contract DeployAll is Script {
    address constant ENTRYPOINT_V07 = 0x0000000071727De22E5E9d8BAf0edAc6f37da032;
    address constant ENTRYPOINT_V08 = 0x4337084D9E255Ff0702461CF8895CE9E3b5Ff108;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address ldfiToken = vm.envAddress("LDFI_TOKEN");
        address owner = vm.envAddress("OWNER");
        
        address entryPoint = vm.envOr("USE_ENTRYPOINT_V08", false) 
            ? ENTRYPOINT_V08 
            : ENTRYPOINT_V07;

        console.log("=== Full Deployment ===");
        console.log("LDFI Token:", ldfiToken);
        console.log("Owner:", owner);
        console.log("EntryPoint:", entryPoint);
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy Kernel implementation
        Kernel kernel = new Kernel(IEntryPoint(entryPoint));
        console.log("Kernel Implementation:", address(kernel));

        // 2. Deploy KernelFactory
        KernelFactory factory = new KernelFactory(address(kernel));
        console.log("KernelFactory:", address(factory));

        // 3. Deploy LendefiStaking
        LendefiStaking staking = new LendefiStaking(ERC20(ldfiToken), owner);
        console.log("LendefiStaking:", address(staking));

        // 4. Deploy LendefiStakingPaymaster
        LendefiStakingPaymaster paymaster = new LendefiStakingPaymaster(
            IEntryPoint(entryPoint),
            staking,
            owner
        );
        console.log("LendefiStakingPaymaster:", address(paymaster));

        // 5. Authorize paymaster in staking contract
        staking.authorizePaymaster(address(paymaster));
        console.log("Paymaster authorized");

        vm.stopBroadcast();

        // Print summary for config
        console.log("");
        console.log("=== DEPLOYMENT COMPLETE ===");
        console.log("");
        console.log("Add to your config.ts:");
        console.log("------------------------");
        console.log("KERNEL_IMPL:", address(kernel));
        console.log("KERNEL_FACTORY:", address(factory));
        console.log("STAKING:", address(staking));
        console.log("PAYMASTER:", address(paymaster));
        console.log("ENTRY_POINT:", entryPoint);
        console.log("");
        console.log("Next steps:");
        console.log("1. Run: npm run fund:paymaster");
        console.log("2. Configure Privy dashboard with PAYMASTER address");
        console.log("3. Ship!");
    }
}

/**
 * @title DeployAllDeterministic
 * @notice Deploy everything with CREATE2 for same addresses on all chains
 */
contract DeployAllDeterministic is Script {
    address constant ENTRYPOINT_V07 = 0x0000000071727De22E5E9d8BAf0edAc6f37da032;
    address constant ENTRYPOINT_V08 = 0x4337084D9E255Ff0702461CF8895CE9E3b5Ff108;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address ldfiToken = vm.envAddress("LDFI_TOKEN");
        address owner = vm.envAddress("OWNER");
        bytes32 salt = vm.envOr("DEPLOY_SALT", bytes32(0));
        
        address entryPoint = vm.envOr("USE_ENTRYPOINT_V08", false) 
            ? ENTRYPOINT_V08 
            : ENTRYPOINT_V07;

        console.log("=== Deterministic Full Deployment ===");
        console.log("Salt:", vm.toString(salt));

        vm.startBroadcast(deployerPrivateKey);

        Kernel kernel = new Kernel{salt: salt}(IEntryPoint(entryPoint));
        console.log("Kernel:", address(kernel));

        KernelFactory factory = new KernelFactory{salt: salt}(address(kernel));
        console.log("Factory:", address(factory));

        LendefiStaking staking = new LendefiStaking{salt: salt}(ERC20(ldfiToken), owner);
        console.log("Staking:", address(staking));

        LendefiStakingPaymaster paymaster = new LendefiStakingPaymaster{salt: salt}(
            IEntryPoint(entryPoint),
            staking,
            owner
        );
        console.log("Paymaster:", address(paymaster));

        staking.authorizePaymaster(address(paymaster));

        vm.stopBroadcast();

        console.log("");
        console.log("=== Same addresses on all chains with this salt ===");
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import "forge-std/console.sol";

import {Upgrades} from "@openzeppelin/foundry-upgrades/Upgrades.sol";
import "../src/Kernel.sol";
import "../src/factory/KernelFactory.sol";
import "../src/lendefi/LendefiStaking.sol";
import "../src/lendefi/LendefiStakingPaymaster.sol";
import "../src/interfaces/IEntryPoint.sol";

/**
 * @title DeployKernel
 * @notice Deploy Kernel implementation and factory
 * 
 * Usage:
 *   npm run deploy:kernel
 *   forge script script/DeployLendefi.s.sol:DeployKernel --rpc-url $RPC_URL --broadcast --verify
 * 
 * Required .env:
 *   PRIVATE_KEY
 */
contract DeployKernel is Script {
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
        console.log("KERNEL_IMPL=", address(kernel));
        console.log("KERNEL_FACTORY=", address(factory));
    }
}

/**
 * @title DeployLendefiStaking
 * @notice Deploy LendefiStaking upgradeable contract with UUPS proxy
 * @dev Uses OpenZeppelin Foundry Upgrades for safe deployment
 * 
 * Usage:
 *   npm run deploy:staking
 *   forge script script/DeployLendefi.s.sol:DeployLendefiStaking --rpc-url $RPC_URL --broadcast --verify
 * 
 * Required .env:
 *   PRIVATE_KEY, LDFI_TOKEN, OWNER
 */
contract DeployLendefiStaking is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address ldfiToken = vm.envAddress("LDFI_TOKEN");
        address owner = vm.envAddress("OWNER");

        console.log("=== Deploy LendefiStaking (UUPS Upgradeable) ===");
        console.log("LDFI Token:", ldfiToken);
        console.log("Owner:", owner);

        vm.startBroadcast(deployerPrivateKey);

        // Deploy using OpenZeppelin Upgrades - handles proxy + implementation
        address proxy = Upgrades.deployUUPSProxy(
            "LendefiStaking.sol:LendefiStaking",
            abi.encodeCall(LendefiStaking.initialize, (IERC20(ldfiToken), owner))
        );

        console.log("Proxy deployed:", proxy);
        console.log("Version:", LendefiStaking(proxy).VERSION());

        vm.stopBroadcast();

        console.log("");
        console.log("=== Deployment Complete ===");
        console.log("STAKING_ADDRESS=", proxy);
    }
}

/**
 * @title DeployLendefiPaymaster
 * @notice Deploy LendefiStakingPaymaster upgradeable contract with UUPS proxy
 * @dev Uses OpenZeppelin Foundry Upgrades for safe deployment
 * 
 * Usage:
 *   npm run deploy:paymaster
 *   forge script script/DeployLendefi.s.sol:DeployLendefiPaymaster --rpc-url $RPC_URL --broadcast --verify
 * 
 * Required .env:
 *   PRIVATE_KEY, STAKING_ADDRESS, OWNER
 */
contract DeployLendefiPaymaster is Script {
    address constant ENTRYPOINT_V07 = 0x0000000071727De22E5E9d8BAf0edAc6f37da032;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address stakingAddress = vm.envAddress("STAKING_ADDRESS");
        address owner = vm.envAddress("OWNER");
        address entryPoint = vm.envOr("ENTRYPOINT", ENTRYPOINT_V07);

        console.log("=== Deploy LendefiStakingPaymaster (UUPS Upgradeable) ===");
        console.log("Staking:", stakingAddress);
        console.log("Owner:", owner);
        console.log("EntryPoint:", entryPoint);

        vm.startBroadcast(deployerPrivateKey);

        // Deploy using OpenZeppelin Upgrades
        address proxy = Upgrades.deployUUPSProxy(
            "LendefiStakingPaymaster.sol:LendefiStakingPaymaster",
            abi.encodeCall(
                LendefiStakingPaymaster.initialize,
                (IEntryPoint(entryPoint), LendefiStaking(stakingAddress), owner)
            )
        );

        console.log("Proxy deployed:", proxy);
        console.log("Version:", LendefiStakingPaymaster(payable(proxy)).VERSION());

        // Authorize paymaster in staking contract
        LendefiStaking(stakingAddress).authorizePaymaster(proxy);
        console.log("Paymaster authorized in staking contract");

        vm.stopBroadcast();

        console.log("");
        console.log("=== Deployment Complete ===");
        console.log("PAYMASTER_ADDRESS=", proxy);
        console.log("");
        console.log("Next: Fund the paymaster with ETH using fund:paymaster");
    }
}

/**
 * @title DeployLendefiFull
 * @notice Deploy complete Lendefi system: Staking + Paymaster (both upgradeable)
 * @dev Uses OpenZeppelin Foundry Upgrades for safe deployment
 * 
 * Usage:
 *   npm run deploy:full
 *   forge script script/DeployLendefi.s.sol:DeployLendefiFull --rpc-url $RPC_URL --broadcast --verify
 * 
 * Required .env:
 *   PRIVATE_KEY, LDFI_TOKEN, OWNER
 */
contract DeployLendefiFull is Script {
    address constant ENTRYPOINT_V07 = 0x0000000071727De22E5E9d8BAf0edAc6f37da032;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address ldfiToken = vm.envAddress("LDFI_TOKEN");
        address owner = vm.envAddress("OWNER");
        address entryPoint = vm.envOr("ENTRYPOINT", ENTRYPOINT_V07);

        console.log("=== Deploy Lendefi Staking System (Full) ===");
        console.log("LDFI Token:", ldfiToken);
        console.log("Owner:", owner);
        console.log("EntryPoint:", entryPoint);
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy LendefiStaking with UUPS proxy
        address stakingProxy = Upgrades.deployUUPSProxy(
            "LendefiStaking.sol:LendefiStaking",
            abi.encodeCall(LendefiStaking.initialize, (IERC20(ldfiToken), owner))
        );
        LendefiStaking staking = LendefiStaking(stakingProxy);
        console.log("Staking proxy:", stakingProxy);
        console.log("Staking version:", staking.VERSION());

        // 2. Deploy LendefiStakingPaymaster with UUPS proxy
        address paymasterProxy = Upgrades.deployUUPSProxy(
            "LendefiStakingPaymaster.sol:LendefiStakingPaymaster",
            abi.encodeCall(
                LendefiStakingPaymaster.initialize,
                (IEntryPoint(entryPoint), staking, owner)
            )
        );
        LendefiStakingPaymaster paymaster = LendefiStakingPaymaster(payable(paymasterProxy));
        console.log("Paymaster proxy:", paymasterProxy);
        console.log("Paymaster version:", paymaster.VERSION());

        // 3. Authorize paymaster in staking contract
        staking.authorizePaymaster(paymasterProxy);
        console.log("Paymaster authorized in staking contract");

        vm.stopBroadcast();

        console.log("");
        console.log("=== Deployment Complete ===");
        console.log("STAKING_ADDRESS=", stakingProxy);
        console.log("PAYMASTER_ADDRESS=", paymasterProxy);
        console.log("");
        console.log("Next steps:");
        console.log("1. npm run fund:paymaster");
        console.log("2. Configure your app with PAYMASTER_ADDRESS");
    }
}

/**
 * @title DeployAll
 * @notice Deploy complete system: Kernel + Factory + Staking + Paymaster
 * @dev Kernel/Factory are not upgradeable, Staking/Paymaster use UUPS
 * 
 * Usage:
 *   npm run deploy:all
 *   forge script script/DeployLendefi.s.sol:DeployAll --rpc-url $RPC_URL --broadcast --verify
 * 
 * Required .env:
 *   PRIVATE_KEY, LDFI_TOKEN, OWNER
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

        console.log("=== Full System Deployment ===");
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

        // 3. Deploy LendefiStaking with UUPS proxy
        address stakingProxy = Upgrades.deployUUPSProxy(
            "LendefiStaking.sol:LendefiStaking",
            abi.encodeCall(LendefiStaking.initialize, (IERC20(ldfiToken), owner))
        );
        LendefiStaking staking = LendefiStaking(stakingProxy);
        console.log("LendefiStaking (proxy):", stakingProxy);

        // 4. Deploy LendefiStakingPaymaster with UUPS proxy
        address paymasterProxy = Upgrades.deployUUPSProxy(
            "LendefiStakingPaymaster.sol:LendefiStakingPaymaster",
            abi.encodeCall(
                LendefiStakingPaymaster.initialize,
                (IEntryPoint(entryPoint), staking, owner)
            )
        );
        console.log("LendefiStakingPaymaster (proxy):", paymasterProxy);

        // 5. Authorize paymaster in staking contract
        staking.authorizePaymaster(paymasterProxy);
        console.log("Paymaster authorized");

        vm.stopBroadcast();

        console.log("");
        console.log("=== DEPLOYMENT COMPLETE ===");
        console.log("");
        console.log("Add to your config:");
        console.log("--------------------");
        console.log("KERNEL_IMPL=", address(kernel));
        console.log("KERNEL_FACTORY=", address(factory));
        console.log("STAKING_ADDRESS=", stakingProxy);
        console.log("PAYMASTER_ADDRESS=", paymasterProxy);
        console.log("ENTRY_POINT=", entryPoint);
        console.log("");
        console.log("Next steps:");
        console.log("1. npm run fund:paymaster");
        console.log("2. Configure Privy/app with PAYMASTER_ADDRESS");
    }
}

/**
 * @title UpgradeLendefiStaking
 * @notice Upgrade LendefiStaking to new implementation
 * @dev Uses OpenZeppelin Foundry Upgrades for safe upgrade with validation
 * 
 * Usage:
 *   npm run upgrade:staking
 *   forge script script/DeployLendefi.s.sol:UpgradeLendefiStaking --rpc-url $RPC_URL --broadcast --verify
 * 
 * Required .env:
 *   PRIVATE_KEY, STAKING_ADDRESS
 */
contract UpgradeLendefiStaking is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address stakingProxy = vm.envAddress("STAKING_ADDRESS");

        console.log("=== Upgrade LendefiStaking ===");
        console.log("Proxy:", stakingProxy);
        console.log("Current version:", LendefiStaking(stakingProxy).VERSION());

        vm.startBroadcast(deployerPrivateKey);

        // Upgrade using OpenZeppelin Upgrades - validates storage layout compatibility
        Upgrades.upgradeProxy(
            stakingProxy,
            "LendefiStaking.sol:LendefiStaking",
            "" // No reinitializer call for v1->v1 upgrade
        );

        console.log("Upgrade complete");
        console.log("New version:", LendefiStaking(stakingProxy).VERSION());

        vm.stopBroadcast();
    }
}

/**
 * @title UpgradeLendefiPaymaster
 * @notice Upgrade LendefiStakingPaymaster to new implementation
 * @dev Uses OpenZeppelin Foundry Upgrades for safe upgrade with validation
 * 
 * Usage:
 *   npm run upgrade:paymaster
 *   forge script script/DeployLendefi.s.sol:UpgradeLendefiPaymaster --rpc-url $RPC_URL --broadcast --verify
 * 
 * Required .env:
 *   PRIVATE_KEY, PAYMASTER_ADDRESS
 */
contract UpgradeLendefiPaymaster is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address paymasterProxy = vm.envAddress("PAYMASTER_ADDRESS");

        console.log("=== Upgrade LendefiStakingPaymaster ===");
        console.log("Proxy:", paymasterProxy);
        console.log("Current version:", LendefiStakingPaymaster(payable(paymasterProxy)).VERSION());

        vm.startBroadcast(deployerPrivateKey);

        // Upgrade using OpenZeppelin Upgrades - validates storage layout compatibility
        Upgrades.upgradeProxy(
            paymasterProxy,
            "LendefiStakingPaymaster.sol:LendefiStakingPaymaster",
            "" // No reinitializer call for v1->v1 upgrade
        );

        console.log("Upgrade complete");
        console.log("New version:", LendefiStakingPaymaster(payable(paymasterProxy)).VERSION());

        vm.stopBroadcast();
    }
}

/**
 * @title FundPaymaster
 * @notice Fund an existing paymaster with ETH deposit to EntryPoint
 * 
 * Usage:
 *   npm run fund:paymaster
 *   forge script script/DeployLendefi.s.sol:FundPaymaster --rpc-url $RPC_URL --broadcast
 * 
 * Required .env:
 *   PRIVATE_KEY, PAYMASTER_ADDRESS
 * 
 * Optional .env:
 *   DEPOSIT_AMOUNT (in wei, defaults to 1 ether)
 */
contract FundPaymaster is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address paymasterAddress = vm.envAddress("PAYMASTER_ADDRESS");
        uint256 depositAmount = vm.envOr("DEPOSIT_AMOUNT", uint256(1 ether));

        console.log("=== Fund Paymaster ===");
        console.log("Paymaster:", paymasterAddress);
        console.log("Deposit amount:", depositAmount);

        LendefiStakingPaymaster paymaster = LendefiStakingPaymaster(payable(paymasterAddress));
        console.log("Current deposit:", paymaster.getDeposit());

        vm.startBroadcast(deployerPrivateKey);

        paymaster.deposit{value: depositAmount}();
        
        console.log("Deposit complete");
        console.log("New deposit balance:", paymaster.getDeposit());

        vm.stopBroadcast();
    }
}

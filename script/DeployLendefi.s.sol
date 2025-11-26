// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import "forge-std/console.sol";

import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "src/lendefi/LendefiStaking.sol";
import "src/lendefi/LendefiStakingPaymaster.sol";
import "src/interfaces/IEntryPoint.sol";

/**
 * @title DeployLendefiStaking
 * @notice Deploy LendefiStaking upgradeable contract with UUPS proxy
 * 
 * Usage:
 *   forge script script/DeployLendefi.s.sol:DeployLendefiStaking --rpc-url $RPC_URL --broadcast
 * 
 * Required .env:
 *   PRIVATE_KEY, LDFI_TOKEN, OWNER
 */
contract DeployLendefiStaking is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address ldfiToken = vm.envAddress("LDFI_TOKEN");
        address owner = vm.envAddress("OWNER");

        console.log("=== Deploy LendefiStaking (Upgradeable) ===");
        console.log("LDFI Token:", ldfiToken);
        console.log("Owner:", owner);

        vm.startBroadcast(deployerPrivateKey);

        // Deploy implementation
        LendefiStaking implementation = new LendefiStaking();
        console.log("Implementation deployed:", address(implementation));

        // Prepare initialization data
        bytes memory initData = abi.encodeWithSelector(
            LendefiStaking.initialize.selector,
            IERC20(ldfiToken),
            owner
        );

        // Deploy proxy
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        console.log("Proxy deployed:", address(proxy));

        vm.stopBroadcast();

        console.log("");
        console.log("=== Deployment Complete ===");
        console.log("STAKING_IMPLEMENTATION=", address(implementation));
        console.log("STAKING_ADDRESS=", address(proxy));
    }
}

/**
 * @title DeployLendefiPaymaster
 * @notice Deploy LendefiStakingPaymaster upgradeable contract with UUPS proxy
 * 
 * Usage:
 *   forge script script/DeployLendefi.s.sol:DeployLendefiPaymaster --rpc-url $RPC_URL --broadcast
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

        console.log("=== Deploy LendefiStakingPaymaster (Upgradeable) ===");
        console.log("Staking:", stakingAddress);
        console.log("Owner:", owner);
        console.log("EntryPoint:", entryPoint);

        vm.startBroadcast(deployerPrivateKey);

        // Deploy implementation
        LendefiStakingPaymaster implementation = new LendefiStakingPaymaster();
        console.log("Implementation deployed:", address(implementation));

        // Prepare initialization data
        bytes memory initData = abi.encodeWithSelector(
            LendefiStakingPaymaster.initialize.selector,
            IEntryPoint(entryPoint),
            LendefiStaking(stakingAddress),
            owner
        );

        // Deploy proxy
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        console.log("Proxy deployed:", address(proxy));

        // Authorize paymaster in staking contract
        LendefiStaking(stakingAddress).authorizePaymaster(address(proxy));
        console.log("Paymaster authorized in staking contract");

        vm.stopBroadcast();

        console.log("");
        console.log("=== Deployment Complete ===");
        console.log("PAYMASTER_IMPLEMENTATION=", address(implementation));
        console.log("PAYMASTER_ADDRESS=", address(proxy));
        console.log("");
        console.log("Next: Fund the paymaster with ETH");
    }
}

/**
 * @title DeployLendefiFull
 * @notice Deploy both LendefiStaking and LendefiStakingPaymaster
 * 
 * Usage:
 *   forge script script/DeployLendefi.s.sol:DeployLendefiFull --rpc-url $RPC_URL --broadcast
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

        vm.startBroadcast(deployerPrivateKey);

        // Deploy staking implementation
        LendefiStaking stakingImpl = new LendefiStaking();
        console.log("Staking implementation:", address(stakingImpl));

        // Deploy staking proxy
        bytes memory stakingInitData = abi.encodeWithSelector(
            LendefiStaking.initialize.selector,
            IERC20(ldfiToken),
            owner
        );
        ERC1967Proxy stakingProxy = new ERC1967Proxy(address(stakingImpl), stakingInitData);
        LendefiStaking staking = LendefiStaking(address(stakingProxy));
        console.log("Staking proxy:", address(staking));

        // Deploy paymaster implementation
        LendefiStakingPaymaster paymasterImpl = new LendefiStakingPaymaster();
        console.log("Paymaster implementation:", address(paymasterImpl));

        // Deploy paymaster proxy
        bytes memory paymasterInitData = abi.encodeWithSelector(
            LendefiStakingPaymaster.initialize.selector,
            IEntryPoint(entryPoint),
            staking,
            owner
        );
        ERC1967Proxy paymasterProxy = new ERC1967Proxy(address(paymasterImpl), paymasterInitData);
        LendefiStakingPaymaster paymaster = LendefiStakingPaymaster(payable(address(paymasterProxy)));
        console.log("Paymaster proxy:", address(paymaster));

        // Authorize paymaster
        staking.authorizePaymaster(address(paymaster));
        console.log("Paymaster authorized in staking contract");

        vm.stopBroadcast();

        console.log("");
        console.log("=== Deployment Complete ===");
        console.log("STAKING_IMPLEMENTATION=", address(stakingImpl));
        console.log("STAKING_ADDRESS=", address(staking));
        console.log("PAYMASTER_IMPLEMENTATION=", address(paymasterImpl));
        console.log("PAYMASTER_ADDRESS=", address(paymaster));
    }
}

/**
 * @title UpgradeLendefiStaking
 * @notice Upgrade LendefiStaking to new implementation
 * 
 * Usage:
 *   forge script script/DeployLendefi.s.sol:UpgradeLendefiStaking --rpc-url $RPC_URL --broadcast
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

        vm.startBroadcast(deployerPrivateKey);

        // Deploy new implementation
        LendefiStaking newImplementation = new LendefiStaking();
        console.log("New implementation:", address(newImplementation));

        // Upgrade
        LendefiStaking(stakingProxy).upgradeToAndCall(address(newImplementation), "");
        console.log("Upgrade complete");

        vm.stopBroadcast();
    }
}

/**
 * @title UpgradeLendefiPaymaster
 * @notice Upgrade LendefiStakingPaymaster to new implementation
 * 
 * Usage:
 *   forge script script/DeployLendefi.s.sol:UpgradeLendefiPaymaster --rpc-url $RPC_URL --broadcast
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

        vm.startBroadcast(deployerPrivateKey);

        // Deploy new implementation
        LendefiStakingPaymaster newImplementation = new LendefiStakingPaymaster();
        console.log("New implementation:", address(newImplementation));

        // Upgrade
        LendefiStakingPaymaster(payable(paymasterProxy)).upgradeToAndCall(address(newImplementation), "");
        console.log("Upgrade complete");

        vm.stopBroadcast();
    }
}

/**
 * @title FundPaymaster
 * @notice Fund an existing paymaster with ETH deposit
 * 
 * Usage:
 *   forge script script/DeployLendefi.s.sol:FundPaymaster --rpc-url $RPC_URL --broadcast
 * 
 * Required .env:
 *   PRIVATE_KEY, PAYMASTER_ADDRESS, DEPOSIT_AMOUNT (in wei)
 */
contract FundPaymaster is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address paymasterAddress = vm.envAddress("PAYMASTER_ADDRESS");
        uint256 depositAmount = vm.envOr("DEPOSIT_AMOUNT", uint256(1 ether));

        console.log("=== Fund Paymaster ===");
        console.log("Paymaster:", paymasterAddress);
        console.log("Deposit amount:", depositAmount);

        vm.startBroadcast(deployerPrivateKey);

        LendefiStakingPaymaster paymaster = LendefiStakingPaymaster(payable(paymasterAddress));
        paymaster.deposit{value: depositAmount}();
        
        console.log("Deposit complete");
        console.log("New balance:", paymaster.getDeposit());

        vm.stopBroadcast();
    }
}

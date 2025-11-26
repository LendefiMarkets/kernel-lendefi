// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "src/interfaces/IEntryPoint.sol";
import "src/interfaces/PackedUserOperation.sol";

/**
 * @title MockEntryPoint
 * @notice Mock EntryPoint for testing paymaster
 */
contract MockEntryPoint is IEntryPoint {
    mapping(address => uint256) public balances;
    mapping(address => uint256) public stakes;
    mapping(address => mapping(uint192 => uint256)) public nonces;

    function setBalance(address account, uint256 balance) external {
        balances[account] = balance;
    }

    function balanceOf(address account) external view override returns (uint256) {
        return balances[account];
    }

    function depositTo(address account) external payable override {
        balances[account] += msg.value;
    }

    function withdrawTo(address payable withdrawAddress, uint256 withdrawAmount) external override {
        require(balances[msg.sender] >= withdrawAmount, "Insufficient balance");
        balances[msg.sender] -= withdrawAmount;
        withdrawAddress.transfer(withdrawAmount);
    }

    function addStake(uint32) external payable override {
        stakes[msg.sender] += msg.value;
    }

    function unlockStake() external pure override {}

    function withdrawStake(address payable withdrawAddress) external override {
        uint256 stake = stakes[msg.sender];
        stakes[msg.sender] = 0;
        withdrawAddress.transfer(stake);
    }

    function getDepositInfo(address account) external view override returns (DepositInfo memory) {
        return DepositInfo({
            deposit: balances[account],
            staked: stakes[account] > 0,
            stake: uint112(stakes[account]),
            unstakeDelaySec: 0,
            withdrawTime: 0
        });
    }

    function getNonce(address sender, uint192 key) external view override returns (uint256) {
        return nonces[sender][key];
    }

    function incrementNonce(uint192 key) external override {
        nonces[msg.sender][key]++;
    }

    function getUserOpHash(PackedUserOperation calldata) external pure override returns (bytes32) {
        return bytes32(0);
    }

    function handleOps(PackedUserOperation[] calldata, address payable) external pure override {}

    function handleAggregatedOps(UserOpsPerAggregator[] calldata, address payable) external pure override {}

    function getSenderAddress(bytes memory) external pure override {
        revert();
    }

    function delegateAndRevert(address, bytes calldata) external pure override {
        revert();
    }
}

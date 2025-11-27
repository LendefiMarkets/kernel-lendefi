// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title IBurnMintERC20
 * @notice Interface for ERC20 tokens that support burning and minting
 * @dev Required for Chainlink CCIP cross-chain token transfers (Burn & Mint mechanism)
 */
interface IBurnMintERC20 is IERC20 {
    /**
     * @notice Mints tokens to an account
     * @param account The address to mint tokens to
     * @param amount The amount of tokens to mint
     */
    function mint(address account, uint256 amount) external;

    /**
     * @notice Burns tokens from the caller's balance
     * @param amount The amount of tokens to burn
     */
    function burn(uint256 amount) external;

    /**
     * @notice Burns tokens from an account (requires approval)
     * @param account The address to burn tokens from
     * @param amount The amount of tokens to burn
     */
    function burn(address account, uint256 amount) external;

    /**
     * @notice Burns tokens from an account using allowance
     * @param account The address to burn tokens from
     * @param amount The amount of tokens to burn
     */
    function burnFrom(address account, uint256 amount) external;
}

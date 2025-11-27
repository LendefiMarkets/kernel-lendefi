// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title IGetCCIPAdmin
 * @notice Interface for getting the CCIP admin address
 * @dev Used by Chainlink CCIP token admin registry
 */
interface IGetCCIPAdmin {
    /**
     * @notice Returns the current CCIP admin address
     * @return The address of the CCIP admin
     */
    function getCCIPAdmin() external view returns (address);
}

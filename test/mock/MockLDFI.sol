// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "solady/tokens/ERC20.sol";

/**
 * @title MockLDFI
 * @notice Mock Lendefi token for testing
 */
contract MockLDFI is ERC20 {
    constructor() ERC20() {}

    function name() public pure override returns (string memory) {
        return "Lendefi Token";
    }

    function symbol() public pure override returns (string memory) {
        return "LDFI";
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }
}

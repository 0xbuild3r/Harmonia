// contracts/mocks/MockSTETH.sol

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockSTETH is ERC20 {

    constructor() ERC20("Staked ETH", "stETH") {}

    // Mint function accessible only by the owner (MockLido)
    function mint(address to, uint256 amount) external  {
        _mint(to, amount);
    }

    // Burn function accessible only by the owner (MockLido)
    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }
    
}

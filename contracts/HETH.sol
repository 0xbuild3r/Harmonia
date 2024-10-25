// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Import OpenZeppelin Contracts
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract HETH is IERC20, Ownable {
    string public constant name = "Harmonia ETH";
    string public constant symbol = "hETH";
    uint8 public constant decimals = 18;

    uint256 private _totalSupply;
    mapping(address => uint256) private _balances;

    constructor(address initialOwner) Ownable(initialOwner){}

    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external onlyOwner {
        require(_balances[from] >= amount, "Burn amount exceeds balance");
        _burn(from, amount);
    }

    // Internal mint function
    function _mint(address to, uint256 amount) internal {
        _totalSupply += amount;
        _balances[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    // Internal burn function
    function _burn(address from, uint256 amount) internal {
        _totalSupply -= amount;
        _balances[from] -= amount;
        emit Transfer(from, address(0), amount);
    }

    // ERC20 standard functions
    function totalSupply() external view override returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) external view override returns (uint256) {
        return _balances[account];
    }

    // Disabled functions (transfers not allowed)
    function transfer(address, uint256) external pure override returns (bool) {
        revert("hETH is non-transferable");
    }

    function allowance(address, address) external pure override returns (uint256) {
        return 0;
    }

    function approve(address, uint256) external pure override returns (bool) {
        revert("hETH is non-transferable");
    }

    function transferFrom(address, address, uint256) external pure override returns (bool) {
        revert("hETH is non-transferable");
    }
}
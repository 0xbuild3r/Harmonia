// contracts/mocks/MockLido.sol

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./MockSTETH.sol";
import "hardhat/console.sol";

/**
 * @title MockLido
 * @dev A mock implementation of the Lido protocol for testing purposes.
 */
contract MockLido {
    MockSTETH public stETHToken;
    uint256 lossAmount;
    // Events
    event Submit(address indexed sender, uint256 amountETH, uint256 shares);
    event Rebase(uint256 additionalETH);
    event LossReported(uint256 lossAmount);

    /**
     * @dev Constructor that initializes the stETH token.
     */
    constructor() {
        stETHToken = new MockSTETH();
    }

    /**
     * @dev Allows users to deposit ETH and receive stETH.
     * Mints stETH 1:1 for the ETH sent.
     * @param _referral Address of the referrer (not used in mock).
     * @return shares The amount of stETH minted.
     */
    function submit(address _referral) external payable returns (uint256 shares) {
        require(msg.value > 0, "Must send ETH to deposit");
        shares = msg.value; // 1:1 ratio for simplicity
        stETHToken.mint(msg.sender, shares);
        emit Submit(msg.sender, msg.value, shares);
    }

    /**
     * @dev Simulates the accrual of yield by performing a rebase.
     * Mints additional stETH to this contract.
     * @param _additionalETH The amount of ETH to simulate as yield.
     */
    function rebase(uint256 _additionalETH, address _to) external {
        require(_additionalETH > 0, "Rebase amount must be greater than zero");

        // Mint additional stETH to this contract
        stETHToken.mint(_to, _additionalETH);

        emit Rebase(_additionalETH);
    }

    /**
     * @dev Simulates a loss in staked ETH.
     * @param _lossAmount The amount of ETH lost.
     */
    function reportLoss(uint256 _lossAmount) external {
        require(_lossAmount > 0, "Loss amount must be greater than zero");
        
        lossAmount += _lossAmount;

        emit LossReported(_lossAmount);
    }

    function getTotalPooledEther() public view returns (uint256) {
        return stETHToken.totalSupply() - lossAmount;
    }

    function getPooledEthByShares(uint256 _share) external view returns (uint256) {
        uint total = getTotalPooledEther();
        return stETHToken.totalSupply() * total / _share;
    }
    
    // Function to transfer ETH for finalized withdrawals
    function transferETH(address _to, uint256 _amount) external {
        require(address(this).balance >= _amount, "Insufficient ETH in contract");
        console.log("eth transfer", _to);
        (bool success, ) = _to.call{value: _amount}("");
        require(success, "ETH transfer failed");
    }
    
    /**
     * @dev Returns the stETH token address.
     * @return The address of the stETH token.
     */
    function stETH() external view returns (address) {
        return address(stETHToken);
    }

    /**
     * @dev Fallback function to receive ETH.
     */
    receive() external payable {}
}

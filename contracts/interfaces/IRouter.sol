// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Interface for the Router
interface IRouter {
    function deposit() external payable returns (uint256);
    function requestWithdrawal(uint256 _amount) external returns (uint256);
    function isWithdrawalFinalized(uint256 requestId) external view returns (bool);
    function claimWithdrawal(uint256 requestId, address _to) external returns (uint256);
    function getTotalDepositedETH() external view returns (uint256);
    function getStETHBalance() external view returns (uint256);
}
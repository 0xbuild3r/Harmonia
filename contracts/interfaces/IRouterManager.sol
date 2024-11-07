// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IRouterManager {
    function deposit() external payable returns (uint256);
    function requestWithdrawal(uint256 _amount) external returns (uint256);
    function isWithdrawalFinalized(uint256 requestId) external view returns (bool);
    function claimWithdrawal(uint256 requestId, address _to) external  returns (uint256);
    function transferETH(address _to, uint256 _amount) external;
    function getTotalETHBalance() external view returns (uint256);
    function getTotalStakedETH() external view returns (uint256);
}

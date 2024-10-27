// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Import statements
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "./MockSTETH.sol";
import "./MockLido.sol";
import "hardhat/console.sol";

// MockWithdrawalQueue Contract
contract MockWithdrawalQueue {
    MockSTETH public stETHToken;
    MockLido public lido;
    uint256 public nextRequestId;
    mapping(uint256 => WithdrawalRequest) public withdrawalRequests;
    
    struct WithdrawalRequest {
        address requester;
        uint256 shares; // Amount of stETH shares
        bool finalized;
    }

    mapping(uint256 => address) public requestOwners;

    event RequestWithdraw(address indexed requester, uint256 shares, uint256 requestId);
    event WithdrawalFinalized(uint256 requestId);
    event ClaimWithdrawal(address indexed requester, uint256 amountETH, uint256 requestId);

    constructor(address _stETH, address payable _lido) {
        nextRequestId = 1;
        stETHToken = MockSTETH(_stETH);
        lido = MockLido(_lido);
    }

    /**
     * @dev Allows users to request withdrawal of stETH.
     * Burns the specified stETH shares and creates a withdrawal request.
     * @param _sharesAmount The amount of stETH shares to withdraw.
     * @param _recipient The address to receive the withdrawn ETH.
     * @return requestIds The ID of the withdrawal request.
     */
     function requestWithdrawals(uint256[] memory _sharesAmount, address _recipient) external returns (uint256[] memory requestIds) {
        require(_sharesAmount[0] > 0, "Shares amount must be greater than zero");
        require(stETHToken.balanceOf(msg.sender) >= _sharesAmount[0], "Insufficient stETH balance");

        // Burn stETH from the user
        stETHToken.burn(msg.sender, _sharesAmount[0]);

        // Create withdrawal request
        uint256 requestId = nextRequestId++;
        
        withdrawalRequests[requestId] = WithdrawalRequest({
            requester: _recipient,
            shares: _sharesAmount[0],
            finalized: false
        });

        requestIds = new uint256[](1);
        requestIds[0] = requestId;

        emit RequestWithdraw(_recipient, _sharesAmount[0], requestId);
    }

    // Simulate finalizing the withdrawal (admin function)
    function finalizeWithdrawal(uint256 _requestId) external {
        WithdrawalRequest storage request = withdrawalRequests[_requestId];
        require(request.requester != address(0), "Invalid requestId");
        require(!request.finalized, "Already finalized");
        console.log("finalizing", _requestId);
        request.finalized = true;
    }

    /**
     * @dev Allows users to claim their ETH after withdrawal is finalized.
     * @param _requestId The ID of the withdrawal request to claim.
     * @return amountETH The amount of ETH claimed.
     */
     /*
    function claimWithdrawal(uint256 _requestId) external returns (uint256 amountETH) {
        WithdrawalRequest storage request = withdrawalRequests[_requestId];
        require(request.requester == msg.sender, "Not the requester");
        require(request.finalized, "Withdrawal not finalized");

        // Calculate the ETH amount corresponding to the shares
        amountETH = request.shares;//getPooledEthByShares(request.shares);
        console.log("aaa", address(this).balance, request.shares);

        require(address(lido).balance >= request.shares, "Insufficient ETH in contract");
        require(lido.transferETH(msg.sender, request.shares), "ETH transfer failed");

        // Transfer ETH to the requester

        // Reset the withdrawal request
        request.shares = 0;
        request.finalized = false;

        emit ClaimWithdrawal(msg.sender, request.shares, _requestId);
    }    
    */
    /**
    * @dev Allows users to claim their ETH after withdrawal is finalized.
    * @param _requestId The ID of the withdrawal request to claim.
    * @return amountETH The amount of ETH claimed.
    */
    function claimWithdrawal(uint256 _requestId) external returns (uint256 amountETH) {
        WithdrawalRequest storage request = withdrawalRequests[_requestId];
        require(request.requester == msg.sender, "Not the requester");
        require(request.finalized, "Withdrawal not finalized");

        // Calculate the ETH amount corresponding to the shares
        amountETH = request.shares;
        require(address(lido).balance >= amountETH, "Insufficient ETH in Lido contract");
        console.log("eth withdraw requester", request.requester);
        // Transfer ETH to the requester
        (bool success, ) = address(lido).call(abi.encodeWithSignature("transferETH(address,uint256)", msg.sender, amountETH));
        require(success, "ETH transfer failed");

        // Reset the withdrawal request
        request.shares = 0;
        request.finalized = false;

        emit ClaimWithdrawal(msg.sender, amountETH, _requestId);
    }


    function isWithdrawalFinalized(uint256 _requestId) external view returns (bool) {
        return withdrawalRequests[_requestId].finalized;
    }

}

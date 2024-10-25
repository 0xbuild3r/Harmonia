// contracts/mocks/MockLido.sol

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

contract MockLido {
    uint256 public totalStaked;
    uint256 public totalShares;
    uint256 public nextRequestId;
    mapping(address => uint256) public balances; // stETH balances
    mapping(uint256 => WithdrawalRequest) public withdrawalRequests;

    struct WithdrawalRequest {
        address requester;
        uint256 shares;
        bool finalized;
    }

    event Submit(address indexed sender, uint256 amount, uint256 shares);
    event RequestWithdraw(address indexed requester, uint256 shares, uint256 requestId);
    event ClaimWithdrawal(address indexed requester, uint256 amount, uint256 requestId);
    event Rebase(uint256 newTotalShares, uint256 totalStaked);
    event Loss(uint256 amount);

    constructor() {
        nextRequestId = 1;
        totalShares = 0;
        totalStaked = 0;
    }

    // Simulate the deposit function
    function submit(address _referral) external payable returns (uint256) {
        require(msg.value > 0, "Must send ETH to deposit");

        // Calculate shares to mint based on current exchange rate
        uint256 shares;
        if (totalShares == 0 || totalStaked == 0) {
            shares = msg.value;
        } else {
            shares = (msg.value * totalShares) / totalStaked;
        }

        totalStaked += msg.value;
        totalShares += shares;
        balances[msg.sender] += shares;

        emit Submit(msg.sender, msg.value, shares);
        return shares;
    }

    // Simulate the withdrawal request function
    function requestWithdraw(uint256 _shares, address _recipient) external returns (uint256) {
        require(_shares > 0, "Amount must be greater than zero");
        require(balances[msg.sender] >= _shares, "Insufficient balance");

        balances[msg.sender] -= _shares;
        totalShares -= _shares;

        uint256 requestId = nextRequestId++;
        withdrawalRequests[requestId] = WithdrawalRequest({
            requester: msg.sender,
            shares: _shares,
            finalized: false
        });

        emit RequestWithdraw(msg.sender, _shares, requestId);
        return requestId;
    }

    // Simulate finalizing the withdrawal (admin function)
    function finalizeWithdrawal(uint256 _requestId) external {
        WithdrawalRequest storage request = withdrawalRequests[_requestId];
        require(request.requester != address(0), "Invalid requestId");
        require(!request.finalized, "Already finalized");

        request.finalized = true;
    }

    // Simulate checking if the withdrawal is finalized
    function isWithdrawalFinalized(uint256 _requestId) external view returns (bool) {
        return withdrawalRequests[_requestId].finalized;
    }

    // Simulate claiming the withdrawal
    function claimWithdrawal(uint256 _requestId) external returns (uint256) {
        WithdrawalRequest storage request = withdrawalRequests[_requestId];
        require(request.requester == msg.sender, "Not the requester");
        require(request.finalized, "Withdrawal not finalized yet");

        // Calculate ETH amount based on shares and current exchange rate
        uint256 amount = (request.shares * totalStaked) / totalShares;
        request.shares = 0;

        totalStaked -= amount;

        // Transfer ETH to the requester
        payable(msg.sender).transfer(amount);

        emit ClaimWithdrawal(msg.sender, amount, _requestId);
        return amount;
    }

    // Simulate rebasing (earnings)
    function rebase(uint256 _profitAmount) external {
        require(_profitAmount > 0, "Profit amount must be greater than zero");
        totalStaked += _profitAmount;
        emit Rebase(totalShares, totalStaked);
    }

    // Simulate loss (e.g., slashing)
    function reportLoss(uint256 _lossAmount) external {
        require(_lossAmount > 0, "Loss amount must be greater than zero");
        require(totalStaked >= _lossAmount, "Loss exceeds total staked");

        totalStaked -= _lossAmount;
        emit Loss(_lossAmount);
    }

    // Fallback function to receive ETH
    receive() external payable {}
}

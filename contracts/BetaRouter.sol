// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Import statements
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./interfaces/IRouter.sol";

// Interface for Lido contract
interface ILido {
    function submit(address _referral) external payable returns (uint256);
    function requestWithdraw(uint256 _sharesAmount, address _recipient) external returns (uint256);
    function isWithdrawalFinalized(uint256 _requestId) external view returns (bool);
    function claimWithdrawal(uint256 _requestId) external returns (uint256);
    function getPooledEthByShares(uint256 _amount) external view returns (uint256);
    function stETH() external view returns (address);
}

// Router contract


contract Router is AccessControl, ReentrancyGuard {
    // Roles
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    // Lido Contract
    ILido public lido;

    // stETH token
    IERC20 public stETH;

    // Admin fee percentage in basis points (e.g., 1000 = 1%)
    uint256 public adminFeePercent = 1000; // Default 1%
    uint256 public constant PERCENTAGE_DENOMINATOR = 100_000;
    uint256 public constant MAX_ADMIN_FEE = 10_000; // Max 10%

    // Accumulated admin fees in stETH shares
    uint256 public accumulatedAdminFees;

    // Last recorded stETH balance for yield calculation
    uint256 public lastStETHBalance;

    // Total stETH balance excluding admin fees
    uint256 public totalStETHBalance;

    // Events
    event AdminFeeUpdated(uint256 newFee);
    event AdminFeeCollected(uint256 feeAmountShares);
    event AdminFeesWithdrawn(uint256 feeAmountETH);
    event Deposit(address indexed user, uint256 amountETH);
    event WithdrawalRequested(address indexed user, uint256 amountETH, uint256 requestId);
    event WithdrawalClaimed(address indexed user, uint256 amountETH, uint256 requestId);

    constructor(address _lidoContract) {
        require(_lidoContract != address(0), "Invalid Lido contract address");

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);

        lido = ILido(_lidoContract);
        stETH = IERC20(lido.stETH());

        // Initialize lastStETHBalance
        lastStETHBalance = stETH.balanceOf(address(this));

        // Initialize totalStETHBalance to current stETH balance
        totalStETHBalance = stETH.balanceOf(address(this));
    }

    // Modifier to restrict functions to RouterManager
    modifier onlyRouterManager() {
        // Implement RouterManager address check if needed
        // For simplicity, assuming RouterManager holds DEFAULT_ADMIN_ROLE
        require(hasRole(DEFAULT_ADMIN_ROLE, msg.sender), "Caller is not RouterManager");
        _;
    }

    // Function to set admin fee percentage
    function setAdminFeePercent(uint256 _newFee) external onlyRole(ADMIN_ROLE) {
        require(_newFee <= MAX_ADMIN_FEE, "Admin fee exceeds maximum limit");
        adminFeePercent = _newFee;

        emit AdminFeeUpdated(_newFee);
    }

    // Function to withdraw accumulated admin fees
    function withdrawAdminFees() external onlyRole(ADMIN_ROLE) nonReentrant {
        require(accumulatedAdminFees > 0, "No admin fees to withdraw");

        uint256 feeShares = accumulatedAdminFees;
        accumulatedAdminFees = 0;

        // Transfer stETH to admin
        require(stETH.transfer(msg.sender, feeShares), "stETH transfer failed");

        emit AdminFeesWithdrawn(feeShares);
    }

    // Deposit ETH to Lido and handle admin fee
    function deposit() external payable nonReentrant {
        require(msg.value > 0, "Must deposit ETH");

        // Collect admin fee from yield before deposit
        uint256 currentStETHBalance = stETH.balanceOf(address(this));
        uint256 yield = _calculateYield(currentStETHBalance);

        if (yield > 0) {
            uint256 adminFee = _calculateAdminFee(yield);
            accumulatedAdminFees += adminFee;

            emit AdminFeeCollected(adminFee);
        }

        // Deposit ETH into Lido
        lido.submit{value: msg.value}(address(0));

        // Record new stETH balance after deposit
        uint256 newTotalShares = stETH.balanceOf(address(this));

        // Update totalStETHBalance to new balance
        totalStETHBalance = newTotalShares;

        // Update lastStETHBalance to new balance
        lastStETHBalance = newTotalShares;

        emit Deposit(msg.sender, msg.value);
    }

    // Request withdrawal from Lido
    function requestWithdrawal(address _user, uint256 _amountETH) external nonReentrant onlyRouterManager returns (uint256) {
        require(_amountETH > 0, "Amount must be greater than zero");
        require(_user != address(0), "Invalid user address");

        // Collect admin fee from yield before withdrawal
        uint256 currentStETHBalance = stETH.balanceOf(address(this));
        uint256 yield = _calculateYield(currentStETHBalance);

        if (yield > 0) {
            uint256 adminFee = _calculateAdminFee(yield);
            accumulatedAdminFees += adminFee;

            emit AdminFeeCollected(adminFee);
        }

        // Request withdrawal from Lido
        stETH.approve(address(lido), _amountETH);
        uint256 requestId = lido.requestWithdraw(_amountETH, address(this));

        // Update totalStETHBalance after fee collection
        totalStETHBalance = stETH.balanceOf(address(this));

        emit WithdrawalRequested(_user, _amountETH, requestId);

        return requestId;
    }

    // Claim withdrawal from Lido
    function claimWithdrawal(uint256 _requestId) external nonReentrant onlyRouterManager returns (uint256) {
        // Claim withdrawal from Lido
        uint256 amountETH = lido.claimWithdrawal(_requestId);

        emit WithdrawalClaimed(msg.sender, amountETH, _requestId);

        return amountETH;
    }

    // Internal view function to calculate yield
    function _calculateYield(uint256 _currentStETHBalance) internal view returns (uint256) {
        if (_currentStETHBalance > totalStETHBalance) {
            return _currentStETHBalance - totalStETHBalance;
        }
        return 0;
    }

    // Internal view function to calculate admin fee from yield
    function _calculateAdminFee(uint256 _yield) internal view returns (uint256) {
        return (_yield * adminFeePercent) / PERCENTAGE_DENOMINATOR;
    }

    // Internal function to collect admin fee from yield
    function _collectAdminFee(uint256 _yield) internal returns (uint256) {
        if (_yield > 0) {
            uint256 adminFeeShares = _calculateAdminFee(_yield);
            accumulatedAdminFees += adminFeeShares;

            emit AdminFeeCollected(adminFeeShares);

            return adminFeeShares;
        }

        return 0;
    }

    // Function to get total ETH deposited (excluding admin fees)
    function getTotalDepositedETH() external view returns (uint256) {
        // Calculate stETH balance excluding admin fees
        uint256 stETHBalanceExcludingFees = stETH.balanceOf(address(this)) - accumulatedAdminFees;
        return lido.getPooledEthByShares(stETHBalanceExcludingFees);
    }

    // Function to get stETH balance (excluding admin fees)
    function getStETHBalance() external view returns (uint256) {
        return stETH.balanceOf(address(this)) - accumulatedAdminFees;
    }

    // Fallback function to receive ETH
    receive() external payable {}
}

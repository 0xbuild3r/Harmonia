// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Import statements
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./interfaces/IRouter.sol";
import "hardhat/console.sol";
// RouterManager contract
contract RouterManager is AccessControl, ReentrancyGuard {
    // Roles
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    // Current Router address
    IRouter public router;

    // Harmonia Interface address
    address public harmoniaInterface;

    // Migration variables
    uint256 public migrationRequestId;
    bool public isMigrating;

    // Pending deposits during migration
    uint256 public pendingDeposits;

    // Pending withdrawals during migration
    struct PendingWithdrawal {
        uint256 amount;
        bool claimed;
    }

    uint256 constant internal REQUEST_ID_PREFIX = 1e18; // Prefix for our own IDs
    uint256 public nextRequestId = 1; // Our own request IDs start from REQUEST_ID_PREFIX + 1

    mapping(uint256 => PendingWithdrawal) public pendingWithdrawals; // requestId => PendingWithdrawal
    uint256 public totalPendingWithdrawalAmount;

    // Mapping from router-issued request IDs to router addresses
    mapping(uint256 => address) public requestRouterMap; // requestId => router address

    // List of past routers
    address[] public pastRouters;

    // Events
    event RouterUpdated(address newRouter);
    event MigrationInitiated(uint256 requestId);
    event MigrationFinalized();
    event DepositReceivedDuringMigration(uint256 amount);
    event WithdrawalRequestedDuringMigration(uint256 amount, uint256 requestId);
    event WithdrawalClaimed(uint256 amount, uint256 requestId);
    event HarmoniaInterfaceUpdated(address newHarmoniaInterface);

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
    }

    // Function to initialize the router address
    function initializeRouter(address _routerAddress) external {
        require(hasRole(ADMIN_ROLE, msg.sender), "Caller is not an admin");
        require(address(router) == address(0), "Router already initialized");
        router = IRouter(_routerAddress);
    }

    // Function to set the Harmonia Interface address
    function setHarmoniaInterface(address _harmoniaInterface) external {
        require(hasRole(ADMIN_ROLE, msg.sender), "Caller is not an admin");
        require(_harmoniaInterface != address(0), "Invalid address");
        harmoniaInterface = _harmoniaInterface;
        emit HarmoniaInterfaceUpdated(_harmoniaInterface);
    }

    // Deposit function callable only by Harmonia Interface
    function deposit() external payable returns (uint256) {
        require(msg.sender == harmoniaInterface, "Only Harmonia Interface can call this function");
        require(msg.value > 0, "Must deposit ETH");
        if (isMigrating) {
            // Keep ETH in RouterManager to be deposited later
            pendingDeposits += msg.value;
            emit DepositReceivedDuringMigration(msg.value);
        } else {
            // Forward ETH to Router
            router.deposit{value: msg.value}();
        }
        return msg.value;
    }

    // Request withdrawal function callable only by Harmonia Interface
    function requestWithdrawal(uint256 _amount) external returns (uint256) {
        require(msg.sender == harmoniaInterface, "Only Harmonia Interface can call this function");
        require(_amount > 0, "Amount must be greater than zero");

        if (isMigrating) {
            // Generate a new request ID and store the amount
            uint256 requestId = REQUEST_ID_PREFIX + nextRequestId++;
            pendingWithdrawals[requestId] = PendingWithdrawal({
                amount: _amount,
                claimed: false
            });
            totalPendingWithdrawalAmount += _amount;
            emit WithdrawalRequestedDuringMigration(_amount, requestId);
            return requestId;
        } else {
            // Forward the request to the router
            uint256 routerRequestId = router.requestWithdrawal(_amount);

            // Map the router's requestId to the router address
            requestRouterMap[routerRequestId] = address(router);
            return routerRequestId;
        }
    }

    // Function to check if a withdrawal is finalized
    function isWithdrawalFinalized(uint256 requestId) external view returns (bool) {
        if (requestId >= REQUEST_ID_PREFIX) {
            // This is a pending withdrawal during migration
            PendingWithdrawal storage pw = pendingWithdrawals[requestId];
            return !isMigrating && address(this).balance >= pw.amount && !pw.claimed;
        } else {
            // Retrieve the router address for the requestId
            address routerAddress = requestRouterMap[requestId];
            if (routerAddress == address(0)) {
                // Unknown requestId
                return false;
            }
            IRouter requestRouter = IRouter(routerAddress);
            return requestRouter.isWithdrawalFinalized(requestId);
        }
    }

    // Function to claim a withdrawal
    function claimWithdrawal(uint256 requestId, address _to) external nonReentrant returns (uint256) {
        require(msg.sender == harmoniaInterface, "Only Harmonia Interface can call this function");

        if (requestId >= REQUEST_ID_PREFIX) {
            // Handle internally managed withdrawals during migration
            PendingWithdrawal storage pw = pendingWithdrawals[requestId];
            require(pw.amount > 0, "Invalid requestId");
            require(!pw.claimed, "Withdrawal already claimed");
            require(!isMigrating, "Migration not finalized yet");
            uint256 amount = pw.amount;
            require(address(this).balance >= amount, "Insufficient balance in contract");

            // Mark as claimed before external call
            pw.claimed = true;
            totalPendingWithdrawalAmount -= amount;

            // Transfer ETH back to Harmonia Interface
            (bool success, ) = _to.call{value: amount}("");
            require(success, "Transfer failed");

            emit WithdrawalClaimed(amount, requestId);
            return amount;
        } else {
            // Retrieve the router address for the requestId
            address routerAddress = requestRouterMap[requestId];
            require(routerAddress != address(0), "Unknown requestId");
            IRouter requestRouter = IRouter(routerAddress);

            // Claim withdrawal from the router
            uint256 amount = requestRouter.claimWithdrawal(requestId, _to);

            // Remove mapping to free storage
            delete requestRouterMap[requestId];

            emit WithdrawalClaimed(amount, requestId);
            return amount;
        }
    }

    // Function to initiate migration
    function initiateMigration() external {
        require(hasRole(ADMIN_ROLE, msg.sender), "Caller is not an admin");
        require(!isMigrating, "Migration already initiated");
        require(address(router) != address(0), "Router zero address");

        // Request withdrawal of all staked ETH from the Router
        uint256 totalDepositedETH = router.getTotalDepositedETH();
        
        if(totalDepositedETH > 0){
            migrationRequestId = router.requestWithdrawal(totalDepositedETH);
        }
        
        isMigrating = true;
        
        // Record the current router as a past router
        pastRouters.push(address(router));

        emit MigrationInitiated(migrationRequestId);
    }

    // Function to check if migration withdrawal is finalized
    function isMigrationReady() external view returns (bool) {
        require(isMigrating, "Migration not initiated");
        return router.isWithdrawalFinalized(migrationRequestId);
    }

    // Function to finalize migration and update Router
    function finalizeMigration(address _newRouter) external {
        require(hasRole(ADMIN_ROLE, msg.sender), "Caller is not an admin");
        require(isMigrating, "Migration not initiated");

        if (migrationRequestId > 0){
            require(router.isWithdrawalFinalized(migrationRequestId), "Withdrawal not finalized yet");
            // Claim withdrawal from the Router
            uint256 withdrawnAmount = router.claimWithdrawal(migrationRequestId, address(this));
        }

        // Update Router address
        router = IRouter(_newRouter);

        // Deposit the ETH into the new Router, keeping enough for pending withdrawals and deposits
        uint256 balance = address(this).balance;

        // Calculate amount to reserve for pending withdrawals and deposits
        uint256 amountToReserve = totalPendingWithdrawalAmount + pendingDeposits;
        uint256 amountToDeposit = 0;

        if (balance > amountToReserve) {
            amountToDeposit = balance - amountToReserve;
            router.deposit{value: amountToDeposit}();
        }

        // Deposit pending deposits into the new Router
        if (pendingDeposits > 0) {
            router.deposit{value: pendingDeposits}();
            pendingDeposits = 0;
        }

        isMigrating = false;
        migrationRequestId = 0;

        emit RouterUpdated(_newRouter);
        emit MigrationFinalized();
    }

    // Function to get total ETH balance, including any ETH held by RouterManager during migration
    function getTotalETHBalance() external view returns (uint256) {
        uint256 totalBalance = address(this).balance;
        //console.log("getTotalETHBalance1",totalBalance);
        // Include balances from all routers
        totalBalance += router.getTotalDepositedETH();
        //console.log("getTotalETHBalance2",totalBalance);
        for (uint256 i = 0; i < pastRouters.length; i++) {
            IRouter pastRouter = IRouter(pastRouters[i]);
            totalBalance += pastRouter.getTotalDepositedETH();
        }

        return totalBalance;
    }



    // Fallback function to receive ETH
    receive() external payable {}
}
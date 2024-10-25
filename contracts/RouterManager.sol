// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Import statements
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";


// Interface for the Router
interface IRouter {
    function deposit() external payable returns (uint256);
    function requestWithdrawal(address _user, uint256 _amount) external returns (uint256);
    function isWithdrawalFinalized(uint256 requestId) external view returns (bool);
    function claimWithdrawal(uint256 requestId) external returns (uint256);
    function getTotalDepositedETH() external view returns (uint256);
    function getStETHBalance() external view returns (uint256);
}

// RouterManager contract
contract RouterManager is AccessControl, ReentrancyGuard {
    // Roles
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    // Router address
    IRouter public router;

    // Migration variables
    uint256 public migrationRequestId;
    bool public isMigrating;

    // Pending deposits during migration
    uint256 public pendingDeposits;

    // Events
    event RouterUpdated(address newRouter);
    event MigrationInitiated(uint256 requestId);
    event MigrationFinalized();
    event DepositReceivedDuringMigration(address indexed user, uint256 amount);

    constructor(address _routerAddress) {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
        router = IRouter(_routerAddress);
    }

    // Function to initiate migration
    function initiateMigration() external {
        require(hasRole(ADMIN_ROLE, msg.sender), "Caller is not an admin");
        require(!isMigrating, "Migration already initiated");

        // Request withdrawal of all staked ETH from the Router
        uint256 totalDepositedETH = router.getTotalDepositedETH();
        require(totalDepositedETH > 0, "No staked ETH to withdraw");

        migrationRequestId = router.requestWithdrawal(address(this), totalDepositedETH);
        isMigrating = true;

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
        require(router.isWithdrawalFinalized(migrationRequestId), "Withdrawal not finalized yet");

        // Claim withdrawal from the Router
        router.claimWithdrawal(migrationRequestId);

        // Update Router address
        router = IRouter(_newRouter);

        // Deposit the ETH into the new Router
        uint256 balance = address(this).balance;

        if (balance > 0) {
            router.deposit{value: balance}();
        }

        // Deposit pending deposits
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
        uint256 routerBalance = router.getTotalDepositedETH();
        uint256 managerBalance = address(this).balance + pendingDeposits;
        return routerBalance + managerBalance;
    }

    // Function to get total staked ETH
    function getTotalStakedETH() external view returns (uint256) {
        return router.getTotalDepositedETH();
    }

    // Proxy functions to interact with the router
    function deposit() external payable returns (uint256) {
        require(msg.value > 0, "Must deposit ETH");

        if (isMigrating) {
            // Keep ETH in RouterManager to be deposited later
            pendingDeposits += msg.value;
            emit DepositReceivedDuringMigration(msg.sender, msg.value);
        } else {
            // Forward ETH to Router
            router.deposit{value: msg.value}();
        }
        return msg.value;
    }

    function requestWithdrawal(address _user, uint256 _amount) external returns (uint256) {
        return router.requestWithdrawal(_user, _amount);
    }

    function isWithdrawalFinalized(uint256 requestId) external view returns (bool) {
        return router.isWithdrawalFinalized(requestId);
    }

    function claimWithdrawal(uint256 requestId) external returns (uint256) {
        return router.claimWithdrawal(requestId);
    }

    // Fallback function to receive ETH
    receive() external payable {}
}


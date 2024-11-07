// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Import statements
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./interfaces/IRouterManager.sol";
import "./HETH.sol";
import "hardhat/console.sol";

contract HarmoniaInterface is AccessControl, ReentrancyGuard {
    // hETH Token (1:1 pegged to ETH)
    HETH public hEthToken;

    // routerManager contract
    IRouterManager public routerManager;

    // Constants
    uint256 public constant PERCENTAGE_DENOMINATOR = 100_000; // 100% = 100,000

    // Define roles
    bytes32 public constant LISTING_MANAGER_ROLE = keccak256("LISTING_MANAGER_ROLE");

    // Community struct
    struct Community {
        uint256 minDonationPercent; // Minimum donation percentage
        uint256 totalDonations;     // Total donations received
        bool exists;                // To check if the community exists

        // Reward variables per community
        uint256 accETHPerShare;     // Accumulated ETH per share, times 1e12
        uint256 totalStaked;        // Total hETH staked in this community
        uint256 lastTotalETH;       // Community's ETH balance at last update

        // Variables for unified donation rate
        uint256 totalDonationWeightedStake; // Sum of (donationPercent × stakeAmount) for all users
        uint256 unifiedDonationRate;        // Calculated unified donation rate (times 1e5)

        address recipient;                  // Address to receive community donations
    }

    // Mapping of community ID to Community struct
    mapping(uint256 => Community) public communities;

    // User information
    struct UserStake {
        uint256 amount;             // Amount staked in the community (in hETH)
        uint256 rewardDebt;         // Reward debt for the user
        uint256 donationPercent;    // Donation percentage selected by the user
    }

    struct UserInfo {
        uint256[] stakedCommunities;                // Array of community IDs the user has staked in
        mapping(uint256 => uint256) communityIndex; // Mapping from community ID to index in stakedCommunities
        mapping(uint256 => UserStake) stakes;       // Mapping from community ID to UserStake
        uint256[] requestIds;                       // Array of withdrawal request IDs for this user
        mapping(uint256 => uint256) requestIdIndex; // Mapping from requestId to index in requestIds array
    }

    // Mapping from user address to UserInfo
    mapping(address => UserInfo) userInfo;

    // Mapping from withdrawal request ID to user address
    mapping(uint256 => address) public requestIdToUser; // Manages ownership of withdrawal NFTs (request IDs)

    // Total ETH owed to users (sum of all user ETH balances)
    uint256 public totalUserETH;

    // Events
    event Stake(address indexed user, uint256 amount, uint256 communityId, uint256 donationPercent);
    event UnstakeRequested(address indexed user, uint256 amount, uint256 communityId, uint256 requestId);
    event UnstakeClaimed(address indexed user, uint256 amount, uint256 requestId);
    event ClaimETH(address indexed user, uint256 amount, uint256 communityId);
    event EmergencyWithdraw(address indexed user, uint256 amount, uint256 communityId);
    event CommunityAdded(uint256 indexed communityId, uint256 minDonationPercent);
    event CommunityUpdated(uint256 indexed communityId, uint256 minDonationPercent);
    event CommunityDonationWithdrawn(uint256 indexed communityId, address indexed recipient, uint256 amount);
    event DonationRateChanged(address indexed user, uint256 communityId, uint256 oldDonationPercent, uint256 newDonationPercent);
    event RouterUpdated(address newRouter);
    event CommunityRecipientUpdated(uint256 indexed communityId, address newRecipient);
    event ListingManagerUpdated(address newManager);

    constructor(address _routerAddress) {
        routerManager = IRouterManager(_routerAddress);

        // Deploy hETH token
        hEthToken = new HETH(address(this));

        // Grant the contract deployer both roles
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(LISTING_MANAGER_ROLE, msg.sender);
    }

    // Add a new community. Only listing manager can call.
    function addCommunity(uint256 _communityId, uint256 _minDonationPercent, address _recipient) external {
        require(hasRole(LISTING_MANAGER_ROLE, msg.sender), "Caller is not a listing manager");
        require(!communities[_communityId].exists, "Community already exists");
        require(_minDonationPercent <= PERCENTAGE_DENOMINATOR, "Invalid donation percent");
        require(_recipient != address(0), "Invalid recipient address");

        communities[_communityId] = Community({
            minDonationPercent: _minDonationPercent,
            totalDonations: 0,
            exists: true,
            accETHPerShare: 0,
            totalStaked: 0,
            lastTotalETH: 0,
            totalDonationWeightedStake: 0,
            unifiedDonationRate: 0,
            recipient: _recipient
        });

        emit CommunityAdded(_communityId, _minDonationPercent);
    }

    // Update the listing manager address. Only default admin can call.
    function updateListingManager(address newManager) external {
        require(hasRole(DEFAULT_ADMIN_ROLE, msg.sender), "Caller is not a default admin");
        require(newManager != address(0), "Invalid address");

        _grantRole(LISTING_MANAGER_ROLE, newManager);

        emit ListingManagerUpdated(newManager);
    }
    
    // Update an existing community's minimum donation percent. Only community owner can call.
    function updateCommunity(uint256 _communityId, uint256 _minDonationPercent) external {
        Community storage community = communities[_communityId];
        require(community.exists, "Community does not exist");
        require(msg.sender == community.recipient, "Caller is not the community owner");
        require(_minDonationPercent <= PERCENTAGE_DENOMINATOR, "Invalid donation percent");

        community.minDonationPercent = _minDonationPercent;

        emit CommunityUpdated(_communityId, _minDonationPercent);
    }
    
    // Function to update the recipient address of a community
    function updateCommunityRecipient(uint256 _communityId, address _newRecipient) external {
        Community storage community = communities[_communityId];
        require(community.exists, "Community does not exist");
        require(msg.sender == community.recipient, "Caller is not the community owner");
        require(_newRecipient != address(0), "Invalid recipient address");

        community.recipient = _newRecipient;

        emit CommunityRecipientUpdated(_communityId, _newRecipient);
    }

    // Internal function to update the unified donation rate
    function updateUnifiedDonationRate(uint256 _communityId) internal {
        Community storage community = communities[_communityId];
        if (community.totalStaked == 0) {
            community.unifiedDonationRate = 0;
        } else {
            community.unifiedDonationRate = (community.totalDonationWeightedStake * PERCENTAGE_DENOMINATOR) / community.totalStaked;
        }
    }

    // Update reward variables of the community pool to be up-to-date.
    function updateCommunityRewards(uint256 _communityId) public {
        Community storage community = communities[_communityId];
        uint256 communityTotalStaked = community.totalStaked;
        if (communityTotalStaked == 0) {
            return;
        }

        // Get total ETH balance from the routerManager
        uint256 totalETHBalance = routerManager.getTotalETHBalance();
        uint256 totalStakedETH = hEthToken.totalSupply();

        if (totalETHBalance == 0 || totalStakedETH == 0) {
            return;
        }

        // Calculate the community's current ETH balance
        uint256 communityETHBalance = (communityTotalStaked * totalETHBalance) / totalStakedETH;
        //uint256 communityETHBalance = totalStaked * totalETHBalance / totalStakedETH;
        // Initialization Check
        if (community.lastTotalETH == 0) {
            community.lastTotalETH = communityETHBalance;
            return;
        }

        // Calculate the ETH change since last update (could be negative in case of loss)
        int256 communityETHChange = int256(communityETHBalance) - int256(community.lastTotalETH);
        console.log("updateCommunityRewards",uint256(communityETHChange), communityETHBalance,  uint256(communityETHChange));
        if (communityETHChange == 0) {
            return;
        }

        if (communityETHChange > 0) {
            // Positive yield scenario
            uint256 communityETHIncrement = uint256(communityETHChange);

            // Calculate ETH generated by stakers and donations
            uint256 stakersETH = (community.totalStaked * communityETHIncrement) / communityTotalStaked;
            uint256 donationsETH = communityETHIncrement - stakersETH;

            // Calculate donation amount from stakers' ETH based on unified donation rate
            uint256 donationFromStakersETH = (stakersETH * community.unifiedDonationRate) / PERCENTAGE_DENOMINATOR;
            uint256 stakersNetETH = stakersETH - donationFromStakersETH;

            // Total new donations
            uint256 totalNewDonations = donationFromStakersETH + donationsETH;
            community.totalDonations += totalNewDonations;

            // Update accumulated ETH per share using stakers' net ETH
            if (community.totalStaked > 0) {
                community.accETHPerShare += (stakersNetETH * 1e12) / community.totalStaked;
            }

            // Update lastTotalETH
            community.lastTotalETH = communityETHBalance; //- totalNewDonations;
        } else {
            // Negative yield scenario (loss)
            uint256 lossAmount = uint256(-communityETHChange);

            // Adjust community.totalDonations proportionally
            uint256 donationLoss = (community.totalDonations * lossAmount) / communityETHBalance;
            if (community.totalDonations > donationLoss) {
                community.totalDonations -= donationLoss;
            } else {
                community.totalDonations = 0;
            }

            // Adjust accumulated ETH per share to reflect the loss
            uint256 stakersLoss = lossAmount - donationLoss;
            if (community.totalStaked > 0) {
                uint256 lossPerShare = (stakersLoss * 1e12) / community.totalStaked;
                if (community.accETHPerShare > lossPerShare) {
                    community.accETHPerShare -= lossPerShare;
                } else {
                    community.accETHPerShare = 0;
                }
            }

            // Update lastTotalETH
            community.lastTotalETH = communityETHBalance;
        }
    }

    // Stake ETH to HarmoniaNetwork and receive hETH tokens
    function stake(uint256 _communityId, uint256 _donationPercent) external payable nonReentrant {
        require(msg.value > 0, "Must stake ETH");
        Community storage community = communities[_communityId];
        require(community.exists, "Community does not exist");
        require(
            _donationPercent >= community.minDonationPercent && _donationPercent <= PERCENTAGE_DENOMINATOR,
            "Invalid donation percent"
        );

        UserInfo storage user = userInfo[msg.sender];
        UserStake storage stakeInfo = user.stakes[_communityId];

        updateCommunityRewards(_communityId);

        uint256 oldDonationWeightedStake = 0;
        uint256 newDonationWeightedStake = 0;

        if (stakeInfo.amount > 0) {
            // Existing stake
            uint256 pending = (stakeInfo.amount * community.accETHPerShare) / 1e12 - stakeInfo.rewardDebt;
            if (pending > 0) {
                _distributeETH(msg.sender, _communityId, pending);
            }

            // Calculate old donation weighted stake
            oldDonationWeightedStake = (stakeInfo.amount * stakeInfo.donationPercent) / PERCENTAGE_DENOMINATOR;

            // Update user's stake amount
            stakeInfo.amount += msg.value;

            // Update donation percent if different
            if (stakeInfo.donationPercent != _donationPercent) {
                stakeInfo.donationPercent = _donationPercent;
            }

            // Calculate new donation weighted stake
            newDonationWeightedStake = (stakeInfo.amount * stakeInfo.donationPercent) / PERCENTAGE_DENOMINATOR;

            // Adjust totalDonationWeightedStake
            community.totalDonationWeightedStake = community.totalDonationWeightedStake - oldDonationWeightedStake + newDonationWeightedStake;

        } else {
            // New stake in this community
            stakeInfo.amount = msg.value;
            stakeInfo.donationPercent = _donationPercent;
            user.communityIndex[_communityId] = user.stakedCommunities.length;
            user.stakedCommunities.push(_communityId);

            // Calculate new donation weighted stake
            newDonationWeightedStake = (stakeInfo.amount * stakeInfo.donationPercent) / PERCENTAGE_DENOMINATOR;

            // Adjust totalDonationWeightedStake
            community.totalDonationWeightedStake += newDonationWeightedStake;
        }

        // Update community's total staked
        community.totalStaked += msg.value;

        // Update unified donation rate
        updateUnifiedDonationRate(_communityId);

        // Stake ETH via routerManager
        uint256 ethReceived = routerManager.deposit{value: msg.value}();

        // Update totalUserETH
        totalUserETH += ethReceived;

        // Mint hETH to the user at a 1:1 ratio with ETH staked
        hEthToken.mint(msg.sender, msg.value);

        // Update user's reward debt
        console.log("stake,rewardDebt", stakeInfo.amount, community.accETHPerShare);
        stakeInfo.rewardDebt = (stakeInfo.amount * community.accETHPerShare) / 1e12;

        // Update community's lastTotalETH
        uint256 totalETHBalance = routerManager.getTotalETHBalance();
        uint256 totalStakedETH = hEthToken.totalSupply();
        if (totalStakedETH > 0) {
            community.lastTotalETH = ((community.totalStaked + community.totalDonations) * totalETHBalance) / totalStakedETH;
        }

        emit Stake(msg.sender, msg.value, _communityId, stakeInfo.donationPercent);
    }

    // Request to unstake hETH tokens from HarmoniaNetwork
    function unstake(uint256 _communityId, uint256 _amount) external nonReentrant returns (uint256) {
        Community storage community = communities[_communityId];
        UserInfo storage user = userInfo[msg.sender];
        UserStake storage stakeInfo = user.stakes[_communityId];
        require(community.exists, "Community does not exist");
        require(stakeInfo.amount >= _amount, "Unstake: insufficient balance");

        updateCommunityRewards(_communityId);

        uint256 pending = (stakeInfo.amount * community.accETHPerShare) / 1e12 - stakeInfo.rewardDebt;
        if (pending > 0) {
            _distributeETH(msg.sender, _communityId, pending);
        }

        // Calculate old and new donation weighted stake
        uint256 oldDonationWeightedStake = (stakeInfo.amount * stakeInfo.donationPercent) / PERCENTAGE_DENOMINATOR;

        // Update user's stake amount
        stakeInfo.amount -= _amount;

        uint256 newDonationWeightedStake = (stakeInfo.amount * stakeInfo.donationPercent) / PERCENTAGE_DENOMINATOR;

        // Adjust totalDonationWeightedStake
        community.totalDonationWeightedStake = community.totalDonationWeightedStake - oldDonationWeightedStake + newDonationWeightedStake;

        // Update unified donation rate
        updateUnifiedDonationRate(_communityId);

        // Burn hETH from the user
        hEthToken.burn(msg.sender, _amount);

        // Update totalUserETH
        totalUserETH -= _amount;

        // Update community's total staked
        community.totalStaked -= _amount;

        // Update user's reward debt
        if (stakeInfo.amount > 0) {
            stakeInfo.rewardDebt = (stakeInfo.amount * community.accETHPerShare) / 1e12;
        } else {
            // Remove community from user's staked communities
            uint256 index = user.communityIndex[_communityId];
            uint256 lastIndex = user.stakedCommunities.length - 1;
            if (index != lastIndex) {
                uint256 lastCommunityId = user.stakedCommunities[lastIndex];
                user.stakedCommunities[index] = lastCommunityId;
                user.communityIndex[lastCommunityId] = index;
            }
            user.stakedCommunities.pop();
            delete user.communityIndex[_communityId];
            delete user.stakes[_communityId];
        }

        // Request withdrawal via routerManager and get the single request ID
        uint256 requestId = routerManager.requestWithdrawal(_amount);

        // Store the ownership of the request ID
        requestIdToUser[requestId] = msg.sender;

        // Track the withdrawal request in the user's info
        user.requestIdIndex[requestId] = user.requestIds.length;
        user.requestIds.push(requestId);

        emit UnstakeRequested(msg.sender, _amount, _communityId, requestId);

        // Return the withdrawal request ID directly to the caller
        return requestId;
    }

    // Claim unstaked ETH once withdrawal is finalized
    function claimUnstakedETH(uint256 requestId) external nonReentrant {
        // Ensure the caller is the owner of the request ID (i.e., owns the withdrawal NFT)
        require(requestIdToUser[requestId] == msg.sender, "Not the owner of this request");

        // Check if the withdrawal is finalized via routerManager
        require(routerManager.isWithdrawalFinalized(requestId), "Withdrawal not yet finalized");

        // Claim the withdrawn ETH
        uint256 amount = routerManager.claimWithdrawal(requestId, msg.sender);

        // Remove the requestId from user's list
        _removeRequestId(msg.sender, requestId);

        // Remove ownership mapping
        delete requestIdToUser[requestId];

        emit UnstakeClaimed(msg.sender, amount, requestId);
    }

    // Internal function to remove a requestId from the user's array and mapping
    function _removeRequestId(address _user, uint256 requestId) internal {
        UserInfo storage user = userInfo[_user];
        uint256 index = user.requestIdIndex[requestId];
        uint256 lastIndex = user.requestIds.length - 1;

        if (index != lastIndex) {
            uint256 lastRequestId = user.requestIds[lastIndex];
            user.requestIds[index] = lastRequestId;
            user.requestIdIndex[lastRequestId] = index;
        }

        user.requestIds.pop();
        delete user.requestIdIndex[requestId];
    }

    // Internal function to distribute ETH
    function _distributeETH(address _user, uint256 _communityId, uint256 _pendingETH) internal {
        // Update totalUserETH
        totalUserETH -= _pendingETH;

        // Transfer the pending ETH to the user via routerManager
        routerManager.transferETH(_user, _pendingETH);

        emit ClaimETH(_user, _pendingETH, _communityId);
    }

    // Claim pending ETH for a specific community
    function claimETH(uint256 _communityId) external nonReentrant {
        Community storage community = communities[_communityId];
        UserInfo storage user = userInfo[msg.sender];
        UserStake storage stakeInfo = user.stakes[_communityId];
        require(community.exists, "Community does not exist");
        require(stakeInfo.amount > 0, "No stake in this community");

        updateCommunityRewards(_communityId);

        uint256 pending = (stakeInfo.amount * community.accETHPerShare) / 1e12 - stakeInfo.rewardDebt;
        require(pending > 0, "No ETH to claim");

        _distributeETH(msg.sender, _communityId, pending);

        stakeInfo.rewardDebt = (stakeInfo.amount * community.accETHPerShare) / 1e12;
    }

    // View function to see pending ETH for a user in a community
    /*
    function pendingETH(address _user, uint256 _communityId) external view returns (uint256) {
        Community storage community = communities[_communityId];
        UserStake storage stakeInfo = userInfo[_user].stakes[_communityId];

        uint256 accETHPerShare = community.accETHPerShare;
        uint256 totalStaked = community.totalStaked;
        uint256 totalDonations = community.totalDonations;

        if (totalStaked == 0) {
            return 0;
        }

        // Get total ETH balance from the routerManager
        uint256 totalETHBalance = routerManager.getTotalETHBalance();
        uint256 totalStakedETH = hEthToken.totalSupply();

        if (totalStakedETH == 0) {
            return 0;
        }

        // Calculate the community's current ETH balance
        uint256 communityETHBalance = (totalStaked + totalDonations) * totalETHBalance / totalStakedETH;
        console.log("num check1",totalStaked, totalDonations, (totalStaked + totalDonations) * totalETHBalance);
        console.log("num check2",totalETHBalance, totalStakedETH, community.lastTotalETH);
        
        // Calculate the ETH change since last update
        int256 communityETHChange = int256(communityETHBalance) - int256(community.lastTotalETH);
        
        if (communityETHChange > 0) {
            console.log("bif");
            uint256 communityETH = uint256(communityETHChange);

            // Calculate ETH generated by stakers and donations
            uint256 stakersETH = (totalStaked * communityETH) / (totalStaked + totalDonations);

            // Calculate donation amount from stakers' ETH based on unified donation rate
            uint256 donationFromStakersETH = (stakersETH * community.unifiedDonationRate) / PERCENTAGE_DENOMINATOR;
            uint256 stakersNetETH = stakersETH - donationFromStakersETH;

            // Update accETHPerShare
            accETHPerShare += (stakersNetETH * 1e12) / totalStaked;
            console.log("communityETHChange",stakersETH, stakersNetETH, totalStaked);
        } else if (communityETHChange < 0) {
            console.log("small");
            uint256 lossAmount = uint256(-communityETHChange);

            // Adjust accETHPerShare to reflect the loss
            uint256 stakersLoss = (totalStaked * lossAmount) / (totalStaked + totalDonations);
            if (totalStaked > 0) {
                uint256 lossPerShare = (stakersLoss * 1e12) / totalStaked;
                if (accETHPerShare > lossPerShare) {
                    accETHPerShare -= lossPerShare;
                } else {
                    accETHPerShare = 0;
                }
            }
        } else {
            console.log("zerooo");
        }

        uint256 pending = (stakeInfo.amount * accETHPerShare) / 1e12 - stakeInfo.rewardDebt;
        console.log("pendingETH", stakeInfo.amount, accETHPerShare, uint256(communityETHChange));
        return pending;
    }
    
    function pendingETH(address _user, uint256 _communityId) external view returns (uint256) {
        Community storage community = communities[_communityId];
        UserStake storage stakeInfo = userInfo[_user].stakes[_communityId];
    
        uint256 accETHPerShare = community.accETHPerShare;
        uint256 communityTotalStaked = community.totalStaked;
        uint256 communityTotalDonations = community.totalDonations;
    
        if (communityTotalStaked == 0) {
            return 0;
        }
    
        // Get total ETH balance from the routerManager
        uint256 totalETHBalance = routerManager.getTotalETHBalance();
        uint256 totalStakedETH = hEthToken.totalSupply();
    
        if (totalStakedETH == 0) {
            return 0;
        }
    
        // Calculate the community's current ETH balance
        uint256 communityTotalStakeIncludingDonations = communityTotalStaked + communityTotalDonations;
        //uint256 communityETHBalance = (communityTotalStakeIncludingDonations * totalETHBalance) / totalStakedETH;
        uint256 communityETHBalance = communityTotalStaked * totalETHBalance / totalStakedETH;
    
        // Calculate the ETH change and record accETHPerShare since last update
        uint256 communityETHChange = communityETHBalance - community.lastTotalETH;
        console.log("pendingETH: communityETHChange", communityETHChange, communityETHBalance, community.lastTotalETH);
        if (communityETHChange > 0) {
            uint256 stakersETH = communityTotalStaked * communityETHChange / communityTotalStakeIncludingDonations;
            uint256 donationsETH = communityETHChange - stakersETH;
    
            uint256 donationFromStakersETH = (stakersETH * community.unifiedDonationRate) / PERCENTAGE_DENOMINATOR;
            uint256 stakersNetETH = stakersETH - donationFromStakersETH;
            uint temp = community.unifiedDonationRate;
            console.log("pendingETH: stakersNetETH", stakersETH, donationFromStakersETH, temp);
            // Update accETHPerShare
            accETHPerShare += (stakersNetETH * 1e12) / communityTotalStaked;
        } else if (communityETHChange < 0) {
            uint256 lossAmount = uint256(-int256(communityETHChange));
    
            uint256 stakersLoss = (communityTotalStaked * lossAmount) / communityTotalStakeIncludingDonations;
            if (communityTotalStaked > 0) {
                uint256 lossPerShare = (stakersLoss * 1e12) / communityTotalStaked;
                if (accETHPerShare > lossPerShare) {
                    accETHPerShare -= lossPerShare;
                } else {
                    accETHPerShare = 0;
                }
            }
        }
        
        uint256 pending = (stakeInfo.amount * accETHPerShare) / 1e12 - stakeInfo.rewardDebt;
        console.log('pendingETH: last', pending, accETHPerShare, stakeInfo.rewardDebt);
        return pending;
    }
    */
    function pendingETH(address _user, uint256 _communityId) external view returns (uint256) {
        Community storage community = communities[_communityId];
        UserStake storage stakeInfo = userInfo[_user].stakes[_communityId];
    
        uint256 accETHPerShare = community.accETHPerShare;
        uint256 communityTotalStaked = community.totalStaked;
        uint256 communityTotalDonations = community.totalDonations;
    
        if (communityTotalStaked == 0 || stakeInfo.amount == 0) {
            return 0;
        }
    
        // Get total ETH balance from the routerManager
        uint256 totalETHBalance = routerManager.getTotalETHBalance();
        uint256 totalStakedETH = hEthToken.totalSupply();
    
        if (totalStakedETH == 0) {
            return 0;
        }
    
        // Calculate the community's current ETH balance
        // Exclude totalDonations from the calculation
        uint256 communityETHBalance = (communityTotalStaked * totalETHBalance) / totalStakedETH;
        console.log("pendingETH: check", communityTotalStaked, totalETHBalance, totalStakedETH);
        // Calculate the ETH change since last update
        int256 communityETHChange = int256(communityETHBalance) - int256(community.lastTotalETH);
        console.log("pendingETH: communityETHChange", uint256(communityETHChange), communityETHBalance, community.lastTotalETH);
    
        if (communityETHChange > 0) {
            uint256 stakersETH = uint256(communityETHChange);
    
            // Calculate donation amount from stakers' ETH based on unified donation rate
            uint256 donationFromStakersETH = (stakersETH * community.unifiedDonationRate) / PERCENTAGE_DENOMINATOR;
            uint256 stakersNetETH = stakersETH - donationFromStakersETH;
            
            // Update accETHPerShare (simulated for view function)
            accETHPerShare += (stakersNetETH * 1e12) / communityTotalStaked;
            console.log("pendingETH: stakersNetETH", stakersETH, donationFromStakersETH, accETHPerShare);
        } else if (communityETHChange < 0) {
            uint256 lossAmount = uint256(-communityETHChange);
    
            // Adjust accETHPerShare to reflect the loss
            uint256 lossPerShare = (lossAmount * 1e12) / communityTotalStaked;
            if (accETHPerShare > lossPerShare) {
                accETHPerShare -= lossPerShare;
            } else {
                accETHPerShare = 0;
            }
        }
        // If communityETHChange == 0, accETHPerShare remains unchanged
    
        // Calculate pending rewards for the user
        
        uint256 pending = (stakeInfo.amount * accETHPerShare) / 1e12 - stakeInfo.rewardDebt;
        console.log('pendingETH: last', pending, accETHPerShare, stakeInfo.rewardDebt);
        return pending;
    }
    
    
    // Function to get the list of withdrawal request IDs for a user
    function getUserWithdrawalRequests(address _user) external view returns (uint256[] memory) {
        return userInfo[_user].requestIds;
    }

    // Function to get user's staked communities
    function getUserStakedCommunities(address _user) external view returns (uint256[] memory) {
        return userInfo[_user].stakedCommunities;
    }

    // Function to get user's donation info for a community
    function getUserDonationInfo(address _user, uint256 _communityId) external view returns (uint256 donationPercent) {
        UserStake storage stakeInfo = userInfo[_user].stakes[_communityId];
        return stakeInfo.donationPercent;
    }

    // Function to get the unified donation rate for a community
    function getUnifiedDonationRate(uint256 _communityId) external view returns (uint256) {
        return communities[_communityId].unifiedDonationRate;
    }

    // Function for the community recipient to withdraw accumulated donations
    function withdrawCommunityDonations(uint256 _communityId) external nonReentrant {
        Community storage community = communities[_communityId];
        require(community.exists, "Community does not exist");
        require(msg.sender == community.recipient, "Only the community recipient can withdraw donations");

        // Update community rewards to ensure all pending donations are accounted for
        updateCommunityRewards(_communityId);

        uint256 donationAmount = community.totalDonations;
        require(donationAmount > 0, "No donations to withdraw");

        // Reset totalDonations before transferring to prevent reentrancy attacks
        community.totalDonations = 0;

        // Transfer the donations to the community recipient via routerManager
        routerManager.transferETH(community.recipient, donationAmount);

        emit CommunityDonationWithdrawn(_communityId, community.recipient, donationAmount);
    }

    // Function to allow users to change their donation percentage without staking more
    function changeDonationRate(uint256 _communityId, uint256 _newDonationPercent) external nonReentrant {
        Community storage community = communities[_communityId];
        require(community.exists, "Community does not exist");
        require(
            _newDonationPercent >= community.minDonationPercent && _newDonationPercent <= PERCENTAGE_DENOMINATOR,
            "Invalid donation percent"
        );

        UserInfo storage user = userInfo[msg.sender];
        UserStake storage stakeInfo = user.stakes[_communityId];
        require(stakeInfo.amount > 0, "No stake in this community");

        // Update community rewards to ensure accurate reward calculations
        updateCommunityRewards(_communityId);

        // Calculate and distribute any pending ETH
        uint256 pending = (stakeInfo.amount * community.accETHPerShare) / 1e12 - stakeInfo.rewardDebt;
        if (pending > 0) {
            _distributeETH(msg.sender, _communityId, pending);
        }

        // Adjust totalDonationWeightedStake for the existing stake
        uint256 oldDonationWeightedStake = (stakeInfo.amount * stakeInfo.donationPercent) / PERCENTAGE_DENOMINATOR;
        uint256 oldDonationPercent = stakeInfo.donationPercent;
        stakeInfo.donationPercent = _newDonationPercent;
        uint256 newDonationWeightedStake = (stakeInfo.amount * stakeInfo.donationPercent) / PERCENTAGE_DENOMINATOR;
        community.totalDonationWeightedStake = community.totalDonationWeightedStake - oldDonationWeightedStake + newDonationWeightedStake;

        // Update unified donation rate
        updateUnifiedDonationRate(_communityId);

        // Update user's reward debt after changing donation rate
        stakeInfo.rewardDebt = (stakeInfo.amount * community.accETHPerShare) / 1e12;

        emit DonationRateChanged(msg.sender, _communityId, oldDonationPercent, _newDonationPercent);
    }
}

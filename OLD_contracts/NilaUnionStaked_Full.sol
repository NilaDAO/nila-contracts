// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * NilaUnion
 */

contract NilaUnion {

    // ------------------- DATA STRUCTS -------------------
    struct Demand {
        uint256 cropType;
        uint256 amount;
        uint256 interestRate; // In basis points (1% = 100 bps)
        uint256 harvestDeadline;
        string location;

        bool isConfirmed;
        address winner;
        bool isFrozen;
        bool isClosed;

        uint256 acceptedBlock;
        uint256 totalDebt;
        uint256 repaid;
    }

    struct RepayInputs {
        uint256 totalDebt;
        uint256 interestRate;
        uint256 acceptedBlock;
        uint256 repaid;
        address[] selected;
        address[] stAddrs;
        uint256 str;
        uint256 stakedNILA;
        bool commitToWinner;
        uint256 lastClaimTime;
        uint256 timeDiff;
    }

    struct DemandOutput {
        uint256 cropType;
        uint256 amount;
        uint256 interestRate;
        uint256 harvestDeadline;
        string location;

        bool isConfirmed;
        address winner;
        bool isFrozen;
        bool isClosed;

        uint256 totalDebt;
        uint256 repaid;
    }

    struct Stake {
        uint256 stakedNILA;
        bool commitToWinner;
        uint256 lastClaimTime;
    }

    // ------------------- STATE -------------------
    address public unionLeader;
    address public masterNode;
    IERC20 public nila;
    IERC20 public usdc;

    Demand[] public demands;

    // Keep track of addresses selected for a demand
    mapping(uint256 => address[]) private selectedListForDemand;

    // Map each selected address to its index in the array above
    mapping(uint256 => mapping(address => uint256)) public selectedAddressIndex;

    // Map each address that staked to demandId
    mapping(uint256 => address[]) public stakedAddresses;
    // Map how much each address in selected list receives as a stake for demandId
    mapping(uint256 => mapping(address => uint256)) public stakesReceived;
    // Map how much each address has staked to demandId
    mapping(uint256 => mapping(address => Stake)) public stakesInvested;
    // Map (bool) if the address has already staked, so to add the new amount to the existing.
    mapping(uint256 => mapping(address => bool)) public hasStaked;

    uint256 private constant YEAR_IN_SECONDS = 365 * 86400;
    uint256 public exchangeRateNilaToUSDC = 1;

    // ------------------- EVENTS -------------------
    event DemandCreated(uint256 demandId, uint256 cropType, uint256 amount);
    event SelectedListAdded(uint256 demandId, address[] selectedAddresses);
    event StakeToDemand(uint256 demandId, address indexed funder, address indexed staker, uint256 amount, bool commit);
    event DemandConfirmed(uint256 demandId, address winner);
    event DebtRepaid(uint256 demandId, address payer, uint256 paymentAmount);
    event InterestClaimed(uint256 demandId, address user, uint256 interest);
    event DemandFrozen(uint256 demandId);
    event DemandClosed(uint256 demandId);
    event InterestCalculated(uint256 demandId, address user, uint256 interest);

    // ------------------- CONSTRUCTOR -------------------
    constructor(
        address _unionLeader,
        address _masterNode,
        address _nila,
        address _usdc
    ) {
        unionLeader = _unionLeader;
        masterNode = _masterNode;
        nila = IERC20(_nila);
        usdc = IERC20(_usdc);
    }

    // ----------------------------------------------------
    //                  STATE-CHANGING
    // ----------------------------------------------------

    // 1) createDemand
    function createDemand(
        uint256 _cropType,
        uint256 _amount,
        uint256 _interestRate,
        uint256 _harvestDeadline,
        string calldata _location
        ) external {
            require(msg.sender == unionLeader, "Only unionLeader");

            Demand memory d = Demand({
                cropType: _cropType,
                amount: _amount,
                interestRate: _interestRate,
                harvestDeadline: _harvestDeadline,
                location: _location,
                isConfirmed: false,
                acceptedBlock: 0,
                winner: address(0),
                isFrozen: false,
                isClosed: false,
                totalDebt: 0,
                repaid: 0
            });

            demands.push(d);
            emit DemandCreated(demands.length - 1, _cropType, _amount);
        }

    // 2) addSelectedList
    function addSelectedList(
        uint256 demandId,
        address[] calldata selected
        ) external {
            require(msg.sender == masterNode || msg.sender == unionLeader, "Only masterNode or unionLeader");

            Demand storage d = demands[demandId];
            require(!d.isConfirmed && !d.isClosed, "Demand must be open/unconfirmed");

            for (uint256 i = 0; i < selected.length; i++) {
                address addr = selected[i];
                selectedListForDemand[demandId].push(addr);
                selectedAddressIndex[demandId][addr] = selectedListForDemand[demandId].length - 1;
            }

            emit SelectedListAdded(demandId, selected);
        }

    /**
     * 3) stakeToDemand
     *
     * Allows someone (msg.sender) to fund multiple addresses
     * within the selected list, in a single transaction.
     *
     * - `addresses` and `amounts` must be the same length.
     * - We sum all amounts, then do one transferFrom for NILA.
     * - Each address gets its stake updated.
     */
    function stakeToDemand(
        uint256 demandId,
        address[] calldata addresses,
        uint256[] calldata amounts,
        bool commitToWinner
    ) external {
        Demand storage d = demands[demandId];
        require(!d.isConfirmed && !d.isClosed && !d.isFrozen, "Demand not open");
        require(addresses.length == amounts.length, "Length mismatch");

        // Sum total
        uint256 totalAmount;
        for (uint256 i = 0; i < addresses.length; i++) {
            totalAmount += amounts[i];
        }

        // Transfer total NILA from sender
        require(nila.transferFrom(msg.sender, address(this), totalAmount), "NILA fail");

        // Distribute stake amounts among addresses
        for (uint256 i = 0; i < addresses.length; i++) {
            if (!hasStaked[demandId][addresses[i]]) {  
                stakedAddresses[demandId].push(addresses[i]); // Store new staker
                hasStaked[demandId][addresses[i]] = true;  
            }

            // stakes received only tracks the amount to a selected 
            stakesReceived[demandId][addresses[i]] += amounts[i];

        // Stakes invested set the total amount, commitment and the claimtime for the investor
        Stake storage sti = stakesInvested[demandId][msg.sender];
        sti.stakedNILA += amounts[i];
        sti.commitToWinner = commitToWinner;
        if (sti.lastClaimTime == 0) {
            // this would mean rewards start when invested, not when demand accepted! Contract pays the difference
            sti.lastClaimTime = block.timestamp;
        }

        emit StakeToDemand(demandId, msg.sender, addresses[i], amounts[i], commitToWinner);
        }
    }

    // 4) acceptDemand
    function acceptDemand(uint256 demandId) external {
        Demand storage d = demands[demandId];
        require(!d.isConfirmed && !d.isClosed && !d.isFrozen, "Cannot accept");
        
        // Make sure msg.sender was in the selection list
        uint256 idx = selectedAddressIndex[demandId][msg.sender];
        require(selectedListForDemand[demandId].length > idx && selectedListForDemand[demandId][idx] == msg.sender, "Not selected");

        d.isConfirmed = true;
        d.winner = msg.sender;
        // setting timestamp to calculate rate cost
        d.acceptedBlock = block.timestamp;

        // Sum and send all NILA staked for this demand to msg.sender
        // SET THE FIRST CALLER AS THE WINNER..!!
        address[] memory selected = selectedListForDemand[demandId];
        uint256 totalNila;
        for (uint256 i = 0; i < selected.length; i++) {
            totalNila += stakesReceived[demandId][selected[i]];
            stakesReceived[demandId][selected[i]] = 0; // set amount to 0
        }

        // payout the total debt
        if (totalNila > 0) {
            d.totalDebt = totalNila; // Added debt equal to paid out
            require(nila.transfer(msg.sender, totalNila), "Transfer failed");
        }

        emit DemandConfirmed(demandId, msg.sender);
    }

    // 5) repayDebt
    function repayDebt(uint256 demandId, uint256 paymentAmount) external {
        Demand storage d = demands[demandId];
        require(d.isConfirmed && !d.isClosed && !d.isFrozen, "Not active");
        require(d.winner == msg.sender, "Only winner can call this");
        require(nila.transferFrom(msg.sender, address(this), paymentAmount), "not enough NILA in the wallet");

        emit DebtRepaid(demandId, msg.sender, paymentAmount);
        // update repaid store
        d.repaid += paymentAmount;

        // DEBT REPAID, CLOSE DEMAND RETURN FUNDS TO INVESTORS
        // refund investors and close demand if debt is completely repaid
        if (d.repaid >= d.totalDebt ) {
            // Iterate through selected addresses/stakers
            address[] storage stAddrs = stakedAddresses[demandId];
            for (uint256 i = 0; i < stAddrs.length; i++) {
                address addr = stAddrs[i];
                // get stake amount for this address
                Stake storage sti = stakesInvested[demandId][addr];
                // base amount to refund
                uint256 refundAmount = sti.stakedNILA; // Initial stake amount

                // time passed since last reward claim
                uint256 timeDiff = block.timestamp - sti.lastClaimTime;
                // Calculate pending interest if any
                if (timeDiff > 0 && d.interestRate > 0 && sti.commitToWinner) {
                    uint256 interest = (refundAmount * d.interestRate * timeDiff) 
                                    / (10000 * YEAR_IN_SECONDS);
                    refundAmount += interest;
                }

                // Refund staker
                nila.transfer(addr, refundAmount);

                // Clear stake record
                delete stakesInvested[demandId][addr];
            }

            // CLEAN UP

            // iterate over selected list and delete each mapping of stake amount and bool
            address[] memory selected = selectedListForDemand[demandId];            
            for (uint256 i = 0; i < selected.length; i++) {
                delete stakesReceived[demandId][selected[i]]; 
                delete hasStaked[demandId][selected[i]];
            }
            // finally remove the selected list aswell
            delete selectedListForDemand[demandId];

            // Close the demand completely
            delete demands[demandId];
            emit DemandClosed(demandId);

            // Refund any excess payment
            if (paymentAmount > d.totalDebt) {
                uint256 excess = paymentAmount - d.totalDebt;
                nila.transfer(msg.sender, excess);
            }
    }}   

    // 6) claimInterest
    function claimInterest(uint256 demandId) external {
        Demand storage d = demands[demandId];
        require(d.isConfirmed && !d.isClosed, "Demand not active");
        require(!d.isFrozen, "Frozen => no interest");

        // check that this user has ANY stake to the demand
        Stake storage sti = stakesInvested[demandId][msg.sender];
        require(sti.stakedNILA > 0 && sti.commitToWinner, "No stake or not committed");

        // calculate what time has passed since the last claim
        uint256 timeDiff = block.timestamp - sti.lastClaimTime;
        require(timeDiff > 0, "No new interest");
        require(d.interestRate > 0, "No interest rate");

        // calculate the interest since last claim
        uint256 interest = (sti.stakedNILA * d.interestRate * timeDiff)
                         / (10000 * YEAR_IN_SECONDS);

        // set the new claim time to now
        sti.lastClaimTime = block.timestamp;
        
        // send the tokens to the claimer
        require(nila.transfer(msg.sender, interest), "NILA fail");

        emit InterestClaimed(demandId, msg.sender, interest);
    }

    // 7) noActivitySignal
    function noActivitySignal(uint256 demandId) external {
        require(msg.sender == masterNode, "Only masterNode");
        Demand storage d = demands[demandId];
        require(!d.isClosed && !d.isFrozen, "Closed/frozen");

        if (d.isConfirmed && d.repaid < d.totalDebt) {
            d.isFrozen = true;
            emit DemandFrozen(demandId);
        }
    }

    // 8) dissolveContract
    function dissolveContract(uint256 demandId) external {
        require(msg.sender == unionLeader, "Only unionLeader");
        Demand storage d = demands[demandId];
        require(d.isClosed || d.isFrozen, "Not done/frozen");

        uint256 nilaLeft = nila.balanceOf(address(this));
        if (nilaLeft > 0) {
            nila.transfer(unionLeader, nilaLeft);
        }
        uint256 usdcLeft = usdc.balanceOf(address(this));
        if (usdcLeft > 0) {
            usdc.transfer(unionLeader, usdcLeft);
        }

        d.isClosed = true;
        emit DemandClosed(demandId);
    }

    // ----------------------------------------------------
    //               READ-ONLY (VIEW) METHODS
    // ----------------------------------------------------
    function getDemandsCount() external view returns (uint256) {
        return demands.length;
    }

    function getDemandInfo(uint256 demandId)
        external
        view
        returns (DemandOutput memory out, address[] memory selectedList)
        {
        Demand storage d = demands[demandId];

        DemandOutput memory temp = DemandOutput({
            cropType:        d.cropType,
            amount:          d.amount,
            interestRate:    d.interestRate,
            harvestDeadline: d.harvestDeadline,
            location:        d.location,
            isConfirmed:     d.isConfirmed,
            winner:          d.winner,
            isFrozen:        d.isFrozen,
            isClosed:        d.isClosed,
            totalDebt:       d.totalDebt,
            repaid:          d.repaid
        });

        address[] memory arr = selectedListForDemand[demandId];
        return (temp, arr);
    }

    // get staked amount to the demand by an investor
    function getInvestorStake(uint256 demandId, address user)
        external
        view
        returns (
            uint256 staked,
            bool committed,
            uint256 lastClaim
        )
        {
        Stake storage s = stakesInvested[demandId][user];
        return (s.stakedNILA, s.commitToWinner, s.lastClaimTime);
    }

    // Single stake record for user in this demand (TOTAL -> PRE-ACCEPTED)
    function getStakeReceived(uint256 demandId, address user)
        external
        view
        returns (uint256)
        {
        uint256 amount = stakesReceived[demandId][user];
        return amount;
    }

    // Multiple stake record for user in this demand
    function getAllStakesReceived(uint256 demandId)
        external
        view
        returns (
            uint256[] memory stakes
        )
        {
        address[] memory selected = selectedListForDemand[demandId];
        uint256 len = selected.length;

        stakes = new uint256[](len);

        for (uint256 i = 0; i < len; i++) {
            address user = selected[i];
            stakes[i] = stakesReceived[demandId][user];
        }

        return stakes;
    }

    // Info about reward to be claimed (using claimInterest)
    function getStakeRewards(uint256 demandId)
        external
        view
        returns (
            uint256 apr,
            uint256 staked,
            uint256 rate,
            uint256 time
            )
        {
        Demand storage d = demands[demandId];
        // Frozen accounts still accumulate interest
        if (d.isClosed || !d.isConfirmed) { return (0,0,0,0);}

        // Load stake of this user
        Stake storage sti = stakesInvested[demandId][msg.sender];

        // Calculate time passed since last claim
        uint256 timeDiff = block.timestamp - sti.lastClaimTime;
        if (timeDiff == 0) {
            return (0,0,0,0); // return coded output
        }

        // Interest calculation using Basis Points (bps)
        uint256 interest = (sti.stakedNILA * d.interestRate * timeDiff) 
                          / (10000 * YEAR_IN_SECONDS);

        return (interest, sti.stakedNILA, d.interestRate,timeDiff);
    }

    // Function to get total debt (TOTAL + APR -> POST-ACCEPTED)
    function getTotalDebt(uint256 demandId) external view returns (uint256) {
        Demand storage d = demands[demandId];
        if (!d.isConfirmed) return 0;

        uint256 timeElapsed = block.timestamp - d.acceptedBlock;

        // Interest calculation using Basis Points (bps)
        uint256 interest = (d.totalDebt * d.interestRate * timeElapsed) 
                          / (10000 * YEAR_IN_SECONDS);
        uint256 totalOwed = d.totalDebt + interest;

        if (d.repaid >= totalOwed) return 0;
        return totalOwed - d.repaid;
    }

    function isDemandSettled(uint256 demandId) external view returns (bool) {
        return demands[demandId].isClosed;
    }

    function timeToHarvestDeadline(uint256 demandId) external view returns (uint256) {
        Demand storage d = demands[demandId];
        if (block.timestamp >= d.harvestDeadline) {
            return 0;
        }
        // returns as polygon blocks from deadline.
        return d.harvestDeadline - block.timestamp;
    }

    function isDemandFrozen(uint256 demandId) external view returns (bool) {
        return demands[demandId].isFrozen;
    }

    // ----------------------------------------------------
    //                 EXTRA HELPERS
    // ----------------------------------------------------
    function removeDemand(uint256 demandId) external {
        require(msg.sender == unionLeader, "Only unionLeader");
        // CLEAN UP

        // iterate over selected list and delete each mapping of stake amount and bool
        address[] memory selected = selectedListForDemand[demandId];            
        for (uint256 i = 0; i < selected.length; i++) {
            delete stakesReceived[demandId][selected[i]]; 
            delete hasStaked[demandId][selected[i]];
        }
        // finally remove the selected list aswell
        delete selectedListForDemand[demandId];

        // Close the demand completely
        delete demands[demandId];
        emit DemandClosed(demandId);
    }

    function setTotalDebt(uint256 demandId, uint256 newDebt) external {
        require(msg.sender == unionLeader, "Only unionLeader");
        Demand storage d = demands[demandId];
        require(d.isConfirmed && !d.isClosed, "Must be active");
        d.totalDebt = newDebt;
    }

    function setExchangeRate(uint256 rate) external {
        require(msg.sender == unionLeader, "Only unionLeader");
        exchangeRateNilaToUSDC = rate;
    }
    
    // Getter for intermediate calculation parameters
    function getRepayInputs(uint256 demandId, address user, address sel)
        external
        view
        returns (RepayInputs memory)

    {
        Demand storage d = demands[demandId];

        return RepayInputs({
            totalDebt: d.totalDebt,
            interestRate: d.interestRate,
            acceptedBlock: d.acceptedBlock,
            repaid: d.repaid,
            selected: selectedListForDemand[demandId],  // Copy to memory
            stAddrs: stakedAddresses[demandId],  // Copy to memory
            str: stakesReceived[demandId][sel],
            stakedNILA: stakesInvested[demandId][user].stakedNILA,
            commitToWinner: stakesInvested[demandId][user].commitToWinner,
            lastClaimTime: stakesInvested[demandId][user].lastClaimTime,
            timeDiff: block.timestamp - d.acceptedBlock
        });
    }
 
    // Getter for intermediate calculation parameters
    function getInterestCalculationParams(uint256 demandId, address user)
        external
        view
        returns (
            uint256 str,
            uint256 interestRate,
            uint256 timeDiff,
            uint256 interest,
            bool commitToWinner,
            uint256 stakedNILA,
            uint256 lastClaimTime
        )
    {
        Demand storage d = demands[demandId];
        // user is the winner for this demand
        interestRate = d.interestRate;
        Stake storage sti = stakesInvested[demandId][msg.sender];

        str = stakesReceived[demandId][user];
        stakedNILA = sti.stakedNILA;
        commitToWinner = sti.commitToWinner;
        lastClaimTime = sti.lastClaimTime;
        // time between now and debt received
        timeDiff = block.timestamp - d.acceptedBlock;

        if (d.isClosed || !d.isConfirmed || timeDiff == 0) {
            interest = 0;
        } else {
            interest = (str * interestRate * timeDiff) 
                       / (10000 * YEAR_IN_SECONDS);
        }
    }
}

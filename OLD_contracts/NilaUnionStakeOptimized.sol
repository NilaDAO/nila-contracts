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
        uint256 selectedListIndex; 
    }

    // ------------------- STATE -------------------
    address public unionLeader;
    address public masterNode;
    IERC20 public nila;
    IERC20 public usdc;

    Demand[] public demands;

    // For membership checks
    mapping(uint256 => mapping(address => bool)) public isAllowed;

    // Keep track of addresses selected for a demand
    mapping(uint256 => address[]) private selectedListForDemand;

    // Map each selected address to its index in the array above
    mapping(uint256 => mapping(address => uint256)) public selectedAddressIndex;

    // Staking records: stakes[demandId][someAddress]
    mapping(uint256 => mapping(address => Stake)) public stakes;

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
    event RefundedLoser(uint256 demandId, address user, uint256 amount);

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
            isAllowed[demandId][addr] = true;
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
            require(isAllowed[demandId][addresses[i]], "Not allowed");
            totalAmount += amounts[i];
        }

        // Transfer total NILA from sender
        require(nila.transferFrom(msg.sender, address(this), totalAmount), "NILA fail");

        // Distribute stake amounts among addresses
        for (uint256 i = 0; i < addresses.length; i++) {
            Stake storage st = stakes[demandId][addresses[i]];
            st.stakedNILA += amounts[i];
            st.commitToWinner = commitToWinner;
            if (st.lastClaimTime == 0) {
                st.lastClaimTime = block.timestamp;
            }
            st.selectedListIndex = selectedAddressIndex[demandId][addresses[i]];

            emit StakeToDemand(demandId, msg.sender, addresses[i], amounts[i], commitToWinner);
        }
    }

    // 4) confirmDemand
    function confirmDemand(uint256 demandId) external {
        Demand storage d = demands[demandId];
        require(!d.isConfirmed && !d.isClosed && !d.isFrozen, "Cannot confirm");
        require(isAllowed[demandId][msg.sender], "Caller not in list");

        d.isConfirmed = true;
        d.winner = msg.sender;

        // Example: sending some USDC to unionLeader
        uint256 testAmountUSDC = 100 ether; 
        if (usdc.balanceOf(address(this)) >= testAmountUSDC) {
            usdc.transfer(unionLeader, testAmountUSDC);
        }

        emit DemandConfirmed(demandId, msg.sender);
    }

    // losers call self-refund
    function refundLoser(uint256 demandId) external {
        Demand storage d = demands[demandId];
        require(d.isConfirmed && !d.isClosed && !d.isFrozen, "Not open for refund");

        Stake storage st = stakes[demandId][msg.sender];
        require(st.stakedNILA > 0, "No stake found");
        require(!st.commitToWinner, "Committed => no refund");

        uint256 amount = st.stakedNILA;
        st.stakedNILA = 0;
        require(nila.transfer(msg.sender, amount), "NILA fail");

        emit RefundedLoser(demandId, msg.sender, amount);
    }

    // 5) repayDebt
    function repayDebt(uint256 demandId, uint256 paymentAmount) external {
        Demand storage d = demands[demandId];
        require(d.isConfirmed && !d.isClosed && !d.isFrozen, "Not active");
        require(d.winner == msg.sender, "Only winner");

        require(nila.transferFrom(msg.sender, address(this), paymentAmount), "NILA fail");
        d.repaid += paymentAmount;

        emit DebtRepaid(demandId, msg.sender, paymentAmount);

        if (d.repaid >= d.totalDebt) {
            d.isClosed = true;
            emit DemandClosed(demandId);
        }
    }

    // 6) claimInterest
    function claimInterest(uint256 demandId) external {
        Demand storage d = demands[demandId];
        require(d.isConfirmed && !d.isClosed, "Demand not active");
        require(!d.isFrozen, "Frozen => no interest");

        Stake storage st = stakes[demandId][msg.sender];
        require(st.stakedNILA > 0 && st.commitToWinner, "No stake or not committed");

        uint256 timeDiff = block.timestamp - st.lastClaimTime;
        require(timeDiff > 0, "No new interest");
        require(d.interestRate > 0, "No interest rate");

        uint256 interest = (st.stakedNILA * d.interestRate * timeDiff)
                         / (10000 * YEAR_IN_SECONDS);

        st.lastClaimTime = block.timestamp;
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

    // Single stake record for user in this demand
    function getUserStake(uint256 demandId, address user)
        external
        view
        returns (
            uint256 staked,
            bool committed,
            uint256 lastClaim,
            uint256 selectedIdx
        )
    {
        Stake storage s = stakes[demandId][user];
        return (s.stakedNILA, s.commitToWinner, s.lastClaimTime, s.selectedListIndex);
    }

    /**
     * Show stake info for *all* addresses in selectedListForDemand[demandId].
     * This helps you see each address's total stakedNILA, etc.
     */
    function getAllStakesForDemand(uint256 demandId)
        external
        view
        returns (
            address[] memory addrs,
            uint256[] memory stakedNILAs,
            bool[] memory commits,
            uint256[] memory lastClaims,
            uint256[] memory selectedIndexes
        )
    {
        address[] memory sel = selectedListForDemand[demandId];
        uint256 len = sel.length;

        addrs = new address[](len);
        stakedNILAs = new uint256[](len);
        commits = new bool[](len);
        lastClaims = new uint256[](len);
        selectedIndexes = new uint256[](len);

        for (uint256 i = 0; i < len; i++) {
            address user = sel[i];
            Stake storage s = stakes[demandId][user];

            addrs[i] = user;
            stakedNILAs[i] = s.stakedNILA;
            commits[i] = s.commitToWinner;
            lastClaims[i] = s.lastClaimTime;
            selectedIndexes[i] = s.selectedListIndex;
        }

        return (addrs, stakedNILAs, commits, lastClaims, selectedIndexes);
    }

    function getAccruedInterest(uint256 demandId, address user)
        external
        view
        returns (uint256)
    {
        Demand storage d = demands[demandId];
        if (d.isFrozen || d.isClosed || !d.isConfirmed) {
            return 0;
        }

        Stake storage st = stakes[demandId][user];
        if (st.stakedNILA == 0 || !st.commitToWinner) {
            return 0;
        }

        uint256 timeDiff = block.timestamp - st.lastClaimTime;
        if (timeDiff == 0) {
            return 0;
        }

        uint256 interest = (st.stakedNILA * d.interestRate * timeDiff)
                         / (10000 * YEAR_IN_SECONDS);
        return interest;
    }

    function getTotalDebt(uint256 demandId) external view returns (uint256) {
        Demand storage d = demands[demandId];
        if (d.repaid >= d.totalDebt) {
            return 0;
        }
        return d.totalDebt - d.repaid;
    }

    function isDemandSettled(uint256 demandId) external view returns (bool) {
        return demands[demandId].isClosed;
    }

    function timeToHarvestDeadline(uint256 demandId) external view returns (uint256) {
        Demand storage d = demands[demandId];
        if (block.timestamp >= d.harvestDeadline) {
            return 0;
        }
        return d.harvestDeadline - block.timestamp;
    }

    function isDemandFrozen(uint256 demandId) external view returns (bool) {
        return demands[demandId].isFrozen;
    }

    // ----------------------------------------------------
    //                 EXTRA HELPERS
    // ----------------------------------------------------
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
}
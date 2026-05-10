// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { GenericFundMathLib } from "./GenericFundMathLib.sol";

interface IFundCore {
    enum Tranche { JUNIOR, SENIOR }

    struct MarketLite {
        uint256 cash;
        uint256 index;      // RAY
        uint256 totalShares;
        uint256 totalBorrows;
        uint256 claimablePrincipal;
    }

    struct InvestorLite {
        uint40 unbondPeriod;
        uint256 shares;
        uint256 locked;     // pending + claimable
        uint256 pending;
        uint256 pendingPrincipalSnap;
        uint256 entryIndex;
    }

    struct Loan {
        address borrower;
        bytes32 loanType;
        uint128 principal;
        uint16  rateBP;
        uint40  createTs;
        uint40  drawdownTs;
        uint40  maturityTs;
        uint128 principalPaid;
        uint128 interestPaid;
        uint128 fundedFromJunior;
        uint128 fundedFromSenior;
        bool    defaulted;
        bool    liquidated;
        uint16  milestone;
        bytes32 milestoneDigest;
        uint40  digestTs;
        uint40  lastAccrualTs;
        uint128 interestAccrued;
        bool    lowerRate;
        uint40  sosDate;
    }

    function DEFAULT_UNBONDING() external view returns (uint256);

    // markets
    function getJuniorMarket(address unionAddr, bytes32 loanType) external view returns (MarketLite memory);
    function getSeniorMarket(address unionAddr) external view returns (MarketLite memory);

    // investors
    function getInvestorJunior(address unionAddr, bytes32 loanType, address investor) external view returns (InvestorLite memory);
    function getInvestorSenior(address unionAddr, address investor) external view returns (InvestorLite memory);

    // caps / rates / utilization
    function bucketTresholds(address unionAddr, bytes32 loanType) external view returns (uint256);

    // viewer write-back primitives (onlyOwner on Core)
    function writeLoanMeta(address unionAddr, bytes32 loanId, uint40 maturityTs, uint8 milestone) external;
    function addJuniorCash(address unionAddr, bytes32 loanType, uint256 amount) external;

    // registry
    function getFundTypes(address union) external view returns (bytes32[] memory);

    // rate params
    function rateParamsByUnion(address unionAddr) external view returns (uint16 baseRateBP,  uint16 kinkUtilBP, uint16 slope1BP,uint16 slope2BP, uint16 maxRateBP );
    function unionBorrowsAgg(address unionAddr) external view returns (uint256);

    // liquidity buffer (public vars)
    function reserveCfgByUnion(address unionAddr) external view returns (uint32 safetyBP, uint224 safetyFloor, bool hardStop, bool exists, uint32 escrowDuration, uint32 collectDeadline);
    function unionClaimable(address unionAddr) external view returns (uint256);
    function unionRainyDay(address unionAddr) external view returns (uint256);
    function unionTreasury(address unionAddr) external view returns (uint256);

    // CS019 pending principal aggregates
    function juniorPendingPrincipal(address unionAddr, bytes32 loanType) external view returns (uint256);
    function seniorPendingPrincipal(address unionAddr) external view returns (uint256);

    // loans mapping getter
    function loans(address unionAddr, bytes32 loanId) external view returns (Loan memory);

    // loan cancellation
    function removeLoan(address unionAddr, bytes32 loanId) external;
}

interface IRoles {
    function isCore(address) external view returns (bool);
    function isLeader(address unionAddr, address account) external view returns (bool);
    function isOracle(address account) external view returns (bool);
}

// Minimal Chainlink interface (for systemHealth oracle read)
interface IAggregatorV3 {
    function latestRoundData() external view returns (
        uint80 roundId, int256 answer, uint256 startedAt,
        uint256 updatedAt, uint80 answeredInRound
    );
}

/// @dev Minimal interface for NilaFxPool view reads (CS028: view functions moved here)
interface IFxPool {
    struct CashEscrow {
        address union_;    // 'union' is a Yul keyword; name doesn't affect ABI layout
        address fundAddr;
        uint256 ninAmount;
        uint256 inrValue;
        uint256 mintRate;
        uint64  deadline;
        uint8   status;
        bytes32 scanHash;
        bytes32 loanType;
    }

    function lastFxRate() external view returns (uint256);
    function lastEpochTimestamp() external view returns (uint256);
    function epochDuration() external view returns (uint256);
    function escrows(uint256 escrowId) external view returns (CashEscrow memory);
    function previewRedeem(uint256 ninAmount) external view returns (
        uint256 usdtOut, uint256 feeUsdt, uint256 compUsdt,
        uint256 epochRate, uint256 currentRate, uint256 diffBps, bool userGained
    );
    function usdt() external view returns (address);
    function fundCore() external view returns (address);
    function inrUsdOracle() external view returns (address);
    function oracleDecimals() external view returns (uint8);
    function usdtDecimals() external view returns (uint8);
    function maxOracleDelay() external view returns (uint256);
    function twapRate() external view returns (uint256);
    function unionActiveEscrowNin(address unionAddr) external view returns (uint256);
}

contract GenericFundViewer is
    Initializable,
    OwnableUpgradeable,
    UUPSUpgradeable
    {
    // ── constants ──────────────────────────────────────────────────────────────
    uint256 constant RAY = 1e27;
    uint256 constant YEAR = 365 days;

    // EIP-712 (OZ v4 domain shape)
    bytes32 private constant EIP712_DOMAIN_TYPEHASH = keccak256("EIP712Domain(string name,uint256 chainId,address verifyingContract)");
    bytes32 private constant NAME_HASH              = keccak256("GenericFund");

    // the mapping that tracks each borrowers loan by id
    mapping(address => mapping(address => bytes32[])) public loansByBorrower;

    // we keep a user readable struct only in viewer
    struct Union {
        string name;
        bytes32[] fundTypes;
        string[] fundIds;
        string location;
        bool active;
    }

    mapping(address => Union) internal unions;
    mapping(address => mapping(bytes32 => bool)) fundTypeEnabled;
    
    // ── Custom errors (short revert strings save code size) ──
    error ReserveConfigSet();
    error NotCore();
    error NotOracleOrLeader();
    error LoanNotExist();
    error MaturityAlreadySet();
    error BadMaturity();
    error NotDefaulted();
    error AmountZero();

    // ── Events emitted by oracle functions (moved here from Core in CS006) ──
    event MaturityReported(address indexed union, bytes32 indexed loanId, uint40 maturityTs);
    event MilestoneReported(address indexed union, bytes32 indexed loanId, uint8 milestone, bytes32 digest);
    event RecoveryCredited(address indexed union, bytes32 indexed loanId, uint256 amount);

    // typed data typehashes (single-token: no `token` field)
    bytes32 private constant VOUCHER_TYPEHASH =
        keccak256("Voucher(address borrower,address union,bytes32 loanId,uint256 maxAmount,uint16 minRateBP,bytes32 loanType,bytes32 paramsHash,bool fastDraw,uint256 escrowId,uint40 sosDate,uint256 nonce)");
    bytes32 private constant QUOTE1155_TYPEHASH =
        keccak256("Quote1155(address union,bytes32 loanType,address investor,address collection,uint256 id,uint256 amount1155,uint256 quoteAmount,uint40 expiry)");

    // Core proxy address (mutable so we can repoint if needed)
    IFundCore public core;
    IRoles public roles;

    // ---------- Modifiers ----------
    modifier onlyOracleOrLeader(address unionAddr) { 
        bool ok = (address(roles) != address(0) && (roles.isOracle(msg.sender) || roles.isLeader(unionAddr, msg.sender)))
            || owner() == msg.sender;
        if (!ok) revert NotOracleOrLeader();
        _;
    }

    modifier onlyCore() {
        if (!roles.isCore(msg.sender)) revert NotCore();
        _;
    }

    // ---------- Initializer / Upgrader ----------
    function initialize(address core_, address _roles) public initializer {
        __Ownable_init(msg.sender);
        __UUPSUpgradeable_init();
        core = IFundCore(core_);
        roles = IRoles(_roles);
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    //////////////////////////////////////////////////////////
    //////////////////////  --- ADMIN --- //////////////////// 
    //////////////////////////////////////////////////////////

    function _domainSeparatorFor(address coreAddr) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH,
                NAME_HASH,
                block.chainid,
                coreAddr
            )
        );
    }

    function _hashTypedDataFor(address coreAddr, bytes32 structHash) internal view returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", _domainSeparatorFor(coreAddr), structHash));
    }

    // --- handle Subcontract admins
    function setCore(address core_) external onlyOwner {
        core = IFundCore(core_);
    }

    function setRoles(address _roles) external onlyOwner {
        roles = IRoles(_roles);
    }

    // --- handle Union Admin (union name and fund type names)
    function CreateUnion(address unionAddr, string calldata name, string calldata location) external onlyOwner {
        Union storage u = unions[unionAddr];
        u.name      = name;
        u.location  = location;
        u.active    = true;
    }

    function ActivateUnion(address unionAddr) external onlyOwner {
        Union storage u = unions[unionAddr];
        u.active    = true;
    }

    function DeactivateUnion(address unionAddr) external onlyOwner {
        Union storage u = unions[unionAddr];
        u.active    = false;
    }
    
    function AddFundType(address unionAddr, bytes32 encodedName, string calldata fundid ) external onlyOwner {
        Union storage u = unions[unionAddr];
        u.fundTypes.push(encodedName);
        u.fundIds.push(fundid);
    }

    function RemoveFundType(address unionAddr, uint256 i) external onlyOwner {
        Union storage u = unions[unionAddr];
        uint256 n = u.fundTypes.length;
        if (n == 0 || i >= n) return;              // ← guard out-of-sync / empty
        if (i != n - 1) {
            u.fundTypes[i] = u.fundTypes[n - 1];
        }
        u.fundTypes.pop();
    }

    // --- handle loan administation
    function onLoanCreated(address unionAddr, bytes32 loanId, address borrower) external onlyCore {
        loansByBorrower[unionAddr][borrower].push(loanId);
    }

    function onLoanClosed(address unionAddr, bytes32 loanId, address borrower) external onlyCore {
        bytes32[] storage arr = loansByBorrower[unionAddr][borrower];
        uint256 len = arr.length;
        for (uint256 i = 0; i < len; i++) {
            if (arr[i] == loanId) {
                arr[i] = arr[len - 1]; // move last into the hole
                arr.pop();
                break;
            }
        }
    }

    //////////////////////////////////////////////////////////
    ////////////////////  --- GETTERS --- //////////////////// 
    //////////////////////////////////////////////////////////

    function getUnion(address unionAddr) external view returns (Union memory) { return unions[unionAddr]; }

    // fund types in core and names in viewer index positions have to always be in sync 
    function getFundTypes(address unionAddr) external view returns (bytes32[] memory) {
        Union storage u = unions[unionAddr];
        uint256 len = u.fundTypes.length;
        bytes32[] memory out = new bytes32[](len);
        for (uint256 i = 0; i < len; ++i) {
            out[i] = u.fundTypes[i];
        }
        return out;
    }

    // get the ratio between junior and senior buckets for a specific fund
    function getBucketRatio(address unionAddr, bytes32 loanType)
        external
        view
        returns (uint256 ratioWad, uint256 thresholdWad)
        {
        IFundCore.MarketLite memory jm = core.getJuniorMarket(unionAddr, loanType);
        IFundCore.MarketLite memory sm = core.getSeniorMarket(unionAddr);

        thresholdWad = core.bucketTresholds(unionAddr, loanType);

        if (sm.cash == 0) {
            ratioWad = jm.cash == 0 ? 0 : type(uint256).max;
        } else {
            ratioWad = Math.mulDiv(jm.cash, 1e18, sm.cash);
        }
    }

    function getTreasuryBalances(address unionAddr)
        external
        view
        returns (uint256 treasury, uint256 rainyDay)
    {
        treasury = core.unionTreasury(unionAddr);
        rainyDay = core.unionRainyDay(unionAddr);
    }

    /// @notice Preview reserve headroom after applying a hypothetical cash delta (positive for repay, negative for draw)
    function previewReserveHeadroom(
        address unionAddr,
        bytes32 loanType,
        int256 cashDelta
        ) external view returns (
            uint256 requiredReserve,
            uint256 idleAfter,
            uint256 headroomAfter,
            bool hardStop
        )
    {
        (uint32 safetyBP, uint224 safetyFloor, bool hs, bool exists,,) = core.reserveCfgByUnion(unionAddr);
        require(exists, "reserve cfg !set");
        hardStop = hs;

        uint256 claimable = core.unionClaimable(unionAddr);
        uint256 bump = (uint256(safetyBP) * claimable) / 10_000;
        requiredReserve = claimable + bump + uint256(safetyFloor);

        IFundCore.MarketLite memory jm = core.getJuniorMarket(unionAddr, loanType);
        IFundCore.MarketLite memory sm = core.getSeniorMarket(unionAddr);

        // current idle for this loanType (junior + senior)
        uint256 idle = jm.cash + sm.cash;

        if (cashDelta < 0) {
            uint256 sub = uint256(-cashDelta);
            idleAfter = idle > sub ? (idle - sub) : 0;
        } else {
            idleAfter = idle + uint256(cashDelta);
        }

        headroomAfter = idleAfter > requiredReserve ? (idleAfter - requiredReserve) : 0;
    }

    // ── borrower-centric info ─────────────────────────────────────────────────
    function getBorrowerInfo(address unionAddr, bytes32 loanId)
        external
        view
        returns (
            address borrower,
            bytes32 loanType,
            uint256 principal,
            uint256 principalRepaid,
            uint16  rateBP,
            uint40  dueDate,
            bool    closed,
            bool    defaulted,
            uint256 outstanding,
            uint16  milestone,
            bytes32 milestoneDigest,
            uint40  digestTs,
            uint40  drawdownTs
        )
        {   
        IFundCore.Loan memory ln = core.loans(unionAddr, loanId);

        borrower        = ln.borrower;
        loanType        = ln.loanType;
        principal       = ln.principal;
        principalRepaid = ln.principalPaid;
        rateBP          = ln.rateBP;
        dueDate         = ln.maturityTs;
        closed          = ln.liquidated;
        defaulted       = ln.defaulted;
        milestone       = ln.milestone;
        milestoneDigest = ln.milestoneDigest;
        digestTs        = ln.digestTs;        
        drawdownTs      = ln.drawdownTs;


        // -----------------------------
        // Interest & outstanding amount
        // -----------------------------

        // principal still due
        uint256 principalDue =
            principal > principalRepaid
                ? (principal - principalRepaid)
                : 0;

        // last time interest was accrued in core
        uint40 lastTs = ln.lastAccrualTs == 0 ? ln.createTs : ln.lastAccrualTs;

        uint256 elapsed = block.timestamp > uint256(lastTs)
            ? (block.timestamp - uint256(lastTs))
            : 0;

        // interest from lastAccrualTs -> now on *leftover* principal
        uint256 interestForPeriod = GenericFundMathLib.accruedInterest(
            principalDue,
            rateBP,
            elapsed,
            YEAR
        );

        // total interest that "exists" now for this loan
        uint256 totalAccrued = uint256(ln.interestAccrued) + interestForPeriod;

        // unpaid interest = accrued - already paid
        uint256 unpaidInterest = totalAccrued > uint256(ln.interestPaid)
            ? (totalAccrued - uint256(ln.interestPaid))
            : 0;

        // what the borrower still owes in total
        outstanding = principalDue + unpaidInterest;
    }

    // ── borrowers call to list ACTIVE LOANS ─
    function getLoansByBorrower(address union, address borrower) external view returns (bytes32[] memory) {
        return loansByBorrower[union][borrower];
    }

    function _unionIdleCash(address unionAddr) internal view returns (uint256 idle) {
        IFundCore.MarketLite memory sm = core.getSeniorMarket(unionAddr);
        idle = sm.cash;

        Union storage u = unions[unionAddr];
        uint256 len = u.fundTypes.length;
        for (uint256 i = 0; i < len; ++i) {
            IFundCore.MarketLite memory jm = core.getJuniorMarket(unionAddr, u.fundTypes[i]);
            idle += jm.cash;
        }
    }

    function previewRateBP(address unionAddr, uint256 amount)
        external
        view
        returns (uint16)
    {
        (
            uint16 base,
            uint16 kink,
            uint16 s1,
            uint16 s2,
            uint16 max
        ) = core.rateParamsByUnion(unionAddr);

        GenericFundMathLib.RateParams memory p = GenericFundMathLib.RateParams({
            baseRateBP:   base,
            kinkUtilBP:   kink,
            slope1BP:     s1,
            slope2BP:     s2,
            maxRateBP:    max
        });

        uint256 borrows = core.unionBorrowsAgg(unionAddr);
        uint256 liquidity = _unionIdleCash(unionAddr);

        return GenericFundMathLib.quoteRateBP(p, borrows, liquidity, amount);
    }

    function getFundTotalsByTranche(
        IFundCore.Tranche tranche,
        address unionAddr,
        bytes32 loanType
        ) external view returns (uint256 totalDeposits, uint256 totalBorrows, uint256 index) {
        if (tranche == IFundCore.Tranche.JUNIOR) {
            IFundCore.MarketLite memory m = core.getJuniorMarket(unionAddr, loanType);
            totalDeposits = m.index == 0 ? 0 : Math.mulDiv(m.totalShares, m.index, RAY);
            totalBorrows  = m.totalBorrows;
            index   = m.index;
        } else {
            IFundCore.MarketLite memory s = core.getSeniorMarket(unionAddr);
            totalDeposits = s.index == 0 ? 0 : Math.mulDiv(s.totalShares, s.index, RAY);
            totalBorrows  = s.totalBorrows;
            index   = s.index;
        }
    }

    // Preview senior unbond eligibility & timing — mirrors Core.claimSenior (CS019)
    function previewUnbondSenior(address unionAddr, address investor)
        external
        view
        returns (
            uint40  requestTs,
            uint40  minWindowTs,
            uint256 pendingPrincipalSnap,
            bool    pastMin,
            bool    coveredByBucket,
            bool    eligibleNow,
            uint256 pendingShares
        )
        {
        IFundCore.InvestorLite memory inv = core.getInvestorSenior(unionAddr, investor);
        uint256 minWindow = core.DEFAULT_UNBONDING();

        requestTs            = inv.unbondPeriod;
        pendingPrincipalSnap = inv.pendingPrincipalSnap;
        minWindowTs          = requestTs == 0 ? 0 : (requestTs + uint40(minWindow));
        pastMin              = (requestTs != 0) && (block.timestamp >= minWindowTs);
        pendingShares        = inv.pending;

        // CS019: bucket-local snap check (same gate as Core.claimSenior)
        IFundCore.MarketLite memory sm = core.getSeniorMarket(unionAddr);
        coveredByBucket = (pendingPrincipalSnap > 0) && (sm.cash >= pendingPrincipalSnap);

        eligibleNow = (inv.shares > 0) || (inv.pending > 0 && pastMin && coveredByBucket);
    }

    // CS019: bucket-local snap coverage — mirrors Core.claimJunior
    function previewUnbondJunior(address unionAddr, bytes32 loanType, address investor)
        external
        view
        returns (
            uint40 requestTs,
            uint40 minWindowTs,
            uint256 pendingPrincipalSnap,
            bool pastMin,
            bool coveredByBucket,
            bool eligibleNow,
            uint256 pendingShares
        )
        {
        IFundCore.InvestorLite memory inv = core.getInvestorJunior(unionAddr, loanType, investor);
        uint256 minWindow = core.DEFAULT_UNBONDING();

        requestTs = inv.unbondPeriod;
        pendingPrincipalSnap = inv.pendingPrincipalSnap;
        minWindowTs = requestTs == 0 ? 0 : (requestTs + uint40(minWindow));
        pastMin = (requestTs != 0) && (block.timestamp >= minWindowTs);
        pendingShares = inv.pending;

        // CS019: bucket-local snap check (same gate as Core.claimJunior)
        IFundCore.MarketLite memory jm = core.getJuniorMarket(unionAddr, loanType);
        coveredByBucket = (pendingPrincipalSnap > 0) && (jm.cash >= pendingPrincipalSnap);

        eligibleNow = (inv.shares > 0) || (inv.pending > 0 && pastMin && coveredByBucket);
    }

    function getLiquidityBuffer(
        address unionAddr,
        bytes32 loanType
        ) external view returns (
        uint16 safetyBP,
        uint256 safetyFloor,
        uint256 claimableReserved,
        uint256 idleCashForType,   // junior[union,loanType].cash + senior[union].cash
        bool hardStop,
        uint256 requiredReserve,
        uint256 headroom,          // max interest payout if !hardStop; else min(idle - req, junior.cash) typically enforced in core
        uint256 lockedCash         // CS019: junior pending principal (snap-denominated)
        ) {
        (uint32 bp, uint224 floor, bool hs, bool exists,,) = core.reserveCfgByUnion(unionAddr);
        require(exists, "reserve cfg !set");
        if (!exists) revert ReserveConfigSet();
        safetyBP = uint16(bp);
        safetyFloor = uint256(floor);
        hardStop = hs;

        claimableReserved = core.unionClaimable(unionAddr);

        IFundCore.MarketLite memory jm = core.getJuniorMarket(unionAddr, loanType);
        IFundCore.MarketLite memory sm = core.getSeniorMarket(unionAddr);

        uint256 idle = jm.cash + sm.cash;
        idleCashForType = idle;

        uint256 bump = (uint256(safetyBP) * claimableReserved) / 10_000;
        requiredReserve = claimableReserved + bump + safetyFloor;

        headroom = idle > requiredReserve ? (idle - requiredReserve) : 0;
        lockedCash = core.juniorPendingPrincipal(unionAddr, loanType);
    }

    function recoverVoucherSigner(
        address coreAddr,
        address borrower,
        address unionAddr,
        bytes32 loanId,
        uint256 maxAmount,
        uint16  minRateBP,
        bytes32 loanType,
        bytes32 paramsHash,
        bool    fastDraw,
        uint256 escrowId,
        uint40  sosDate,
        uint256 nonce,
        bytes calldata sig
        ) external view returns (address) {
        bytes32 structHash = keccak256(abi.encode(
            VOUCHER_TYPEHASH,
            borrower, unionAddr, loanId, maxAmount, minRateBP, loanType, paramsHash,
            fastDraw, escrowId, sosDate, nonce
        ));
        bytes32 digest = _hashTypedDataFor(coreAddr, structHash);
        return ECDSA.recover(digest, sig);
    }

    function recoverQuote1155Signer(
        address coreAddr,
        address unionAddr,
        bytes32 loanType,
        address investor,
        address collection,
        uint256 id,
        uint256 amount1155,
        uint256 quoteAmount,
        uint40  expiry,
        bytes calldata sig
        ) external view returns (address) {
        bytes32 structHash = keccak256(abi.encode(
            QUOTE1155_TYPEHASH,
            unionAddr,
            loanType,
            investor,
            collection,
            id,
            amount1155,
            quoteAmount,
            expiry
        ));
        bytes32 digest = _hashTypedDataFor(coreAddr, structHash);
        return ECDSA.recover(digest, sig);
    }

    function getMaturityMilestone(address unionAddr, bytes32 loanId) 
        external 
        view 
        returns (
            uint40 maturityTs,
            uint16 milestone,
            uint40 digestTs,
            bytes32 milestoneDigest
        ) 
        {

        IFundCore.Loan memory ln = core.loans(unionAddr, loanId);
        maturityTs = ln.maturityTs;
        milestone = ln.milestone;
        digestTs = ln.digestTs;
        milestoneDigest = ln.milestoneDigest;
    }

    function getUnionCollectDeadline(address unionAddr) external view returns (uint32 collectDeadline) {
        (,,,,,collectDeadline) = core.reserveCfgByUnion(unionAddr);
    }

    // ---------- Oracle / leader write functions (moved from Core in CS006) ----------

    /// @notice Set the maturity date on a loan and snap the remaining principal as scheduled.
    ///         Callable by oracle or union leader. Writes through to Core via writeLoanMeta.
    function reportMaturity(address unionAddr, bytes32 loanId, uint40 maturityTs)
        external onlyOracleOrLeader(unionAddr)
    {
        IFundCore.Loan memory ln = core.loans(unionAddr, loanId);
        if (ln.createTs == 0) revert LoanNotExist();
        if (ln.maturityTs != 0) revert MaturityAlreadySet();
        if (maturityTs < ln.createTs) revert BadMaturity();
        core.writeLoanMeta(unionAddr, loanId, maturityTs, ln.milestone == 0 ? uint8(10) : uint8(ln.milestone));
        emit MaturityReported(unionAddr, loanId, maturityTs);
    }

    /// @notice Record a crop/repayment milestone on a loan.
    ///         Callable by oracle or union leader.
    function reportMilestone(address unionAddr, bytes32 loanId, uint8 milestone, bytes32 digest)
        external onlyOracleOrLeader(unionAddr)
    {
        IFundCore.Loan memory ln = core.loans(unionAddr, loanId);
        if (ln.createTs == 0) revert LoanNotExist();
        core.writeLoanMeta(unionAddr, loanId, 0, milestone);
        emit MilestoneReported(unionAddr, loanId, milestone, digest);
    }

    /// @notice Credit a recovery amount back to the junior pool after a defaulted loan.
    ///         Callable by oracle or union leader.
    function creditRecovery(address unionAddr, bytes32 loanId, uint256 recovered)
        external onlyOracleOrLeader(unionAddr)
    {
        if (recovered == 0) revert AmountZero();
        IFundCore.Loan memory ln = core.loans(unionAddr, loanId);
        if (ln.createTs == 0) revert LoanNotExist();
        if (!ln.defaulted) revert NotDefaulted();
        core.addJuniorCash(unionAddr, ln.loanType, recovered);
        emit RecoveryCredited(unionAddr, loanId, recovered);
    }

    // ─────────────────────────────────────────────────────────────
    // FxPool view functions (CS028: moved from NilaFxPool to reduce its bytecode)
    // All state is read from the pool via public getters — no storage here.
    // ─────────────────────────────────────────────────────────────

    /// @notice Returns the current FX epoch reference rate and its timestamp.
    function getFxEpoch(address fxPool)
        external
        view
        returns (uint256 epochRate, uint256 epochTimestamp, uint256 epochDurationSec)
    {
        IFxPool pool = IFxPool(fxPool);
        return (pool.lastFxRate(), pool.lastEpochTimestamp(), pool.epochDuration());
    }

    /// @notice Returns the full CashEscrow struct for a given escrow ID.
    function getEscrow(address fxPool, uint256 escrowId)
        external
        view
        returns (IFxPool.CashEscrow memory)
    {
        return IFxPool(fxPool).escrows(escrowId);
    }

    /// @notice Returns true if the escrow is still active (status=0) but past its deadline.
    function isEscrowExpired(address fxPool, uint256 escrowId)
        external
        view
        returns (bool)
    {
        IFxPool.CashEscrow memory e = IFxPool(fxPool).escrows(escrowId);
        return e.status == 0 && block.timestamp > e.deadline;
    }

    /// @notice Preview USDT output for redeeming ninAmount right now.
    ///         Delegates to FxPool.previewRedeem — same math, same reverts.
    function quoteRedeem(address fxPool, uint256 ninAmount)
        external
        view
        returns (
            uint256 usdtOut,
            uint256 feeUsdt,
            uint256 compUsdt,
            uint256 epochRate,
            uint256 currentRate,
            uint256 diffBps,
            bool userGained
        )
    {
        return IFxPool(fxPool).previewRedeem(ninAmount);
    }

    /// @notice Three-layer health snapshot for a union.
    ///         Reads FxPool public state + Core pending principals + live oracle rate.
    function systemHealth(address fxPool, address unionAddr, bytes32 loanType)
        external
        view
        returns (
            uint256 usdtDeposited,
            uint256 usdtPromised,
            uint256 cashEscrowNin,
            uint256 healthRatio
        )
    {
        IFxPool pool = IFxPool(fxPool);

        usdtDeposited = IERC20(pool.usdt()).balanceOf(fxPool);

        // LP pending withdrawals from Core → convert to USDT at live oracle rate
        uint256 pending = core.seniorPendingPrincipal(unionAddr)
                        + core.juniorPendingPrincipal(unionAddr, loanType);
        if (pending > 0) {
            // Read oracle directly — same inversion logic as FxPool._getOracleView
            IAggregatorV3 oracle = IAggregatorV3(pool.inrUsdOracle());
            (, int256 answer, , uint256 updatedAt,) = oracle.latestRoundData();
            require(answer > 0 && block.timestamp - updatedAt <= pool.maxOracleDelay(), "oracle stale");
            uint256 oracDec = pool.oracleDecimals();
            uint256 scale = 10 ** oracDec;
            uint256 rate = (scale * scale) / uint256(answer); // invert: USD/INR → INR/USD
            uint256 usd18 = (pending * scale) / rate;
            usdtPromised = usd18 / (10 ** (18 - pool.usdtDecimals()));
        }

        cashEscrowNin = pool.unionActiveEscrowNin(unionAddr);
        healthRatio = (usdtDeposited * 1e18) / (usdtPromised > 0 ? usdtPromised : 1);
    }

    // storage gap for future variables
    uint256[48] private __gap;
}

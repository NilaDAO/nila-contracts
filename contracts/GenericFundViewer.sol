// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

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
        uint256 unclaimed;
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
    function maturedCreditByUnion(address unionAddr) external view returns (uint256);
    function maturedConsumedByUnion(address unionAddr) external view returns (uint256);

    // registry
    function getFundTypes(address union) external view returns (bytes32[] memory);

    // rate params
    function rateParamsByUnion(address unionAddr) external view returns (uint16 baseRateBP,  uint16 kinkUtilBP, uint16 slope1BP,uint16 slope2BP, uint16 maxRateBP );
    function unionBorrowsAgg(address unionAddr) external view returns (uint256);

    // liquidity buffer (public vars)
    function reserveCfgByUnion(address unionAddr) external view returns (uint32 safetyBP, uint224 safetyFloor, bool hardStop, bool exists);
    function unionClaimable(address unionAddr) external view returns (uint256);
    function unionRainyDay(address unionAddr) external view returns (uint256);
    function unionTreasury(address unionAddr) external view returns (uint256);

    // loans mapping getter
    function loans(address unionAddr, bytes32 loanId) external view returns (Loan memory);
}

interface IRoles {
    function isCore(address) external view returns (bool);
    function isLeader(address unionAddr, address account) external view returns (bool);
    function isOracle(address account) external view returns (bool);
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
        (uint32 safetyBP, uint224 safetyFloor, bool hs, bool exists) = core.reserveCfgByUnion(unionAddr);
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

    function getMaturityCoverageForUnion(address unionAddr)
        external
        view
        returns (uint256 availableCoverage, uint256 maturedCredit, uint256 maturedConsumed)
    {
        maturedCredit = core.maturedCreditByUnion(unionAddr);
        maturedConsumed = core.maturedConsumedByUnion(unionAddr);
        availableCoverage = maturedCredit > maturedConsumed ? (maturedCredit - maturedConsumed) : 0;
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

    // Preview senior unbond eligibility & timing
    function previewUnbondSenior(address unionAddr, address investor)
        external
        view
        returns (
            uint40 requestTs,
            uint40 minWindowTs,
            bool pastMin,
            bool eligibleNow
        )
        {
        IFundCore.InvestorLite memory inv  = core.getInvestorSenior(unionAddr, investor);
        uint256 minWindow = core.DEFAULT_UNBONDING();
        requestTs = inv.unbondPeriod;
        minWindowTs = requestTs == 0 ? 0 : (requestTs + uint40(minWindow));
        pastMin = (inv.unbondPeriod != 0) && (block.timestamp >= minWindowTs);

        // same semantics as Core.claimSenior auto-promotion rule
        eligibleNow = (inv.shares > 0) || (inv.pending > 0 && pastMin);
    }

    function previewUnbondJunior(address unionAddr, bytes32 loanType, address investor)
        external
        view
        returns (
            uint40 requestTs,
            uint40 minWindowTs,
            uint256 pendingPrincipalSnap,
            uint256 maturedBudget,
            bool pastMin,
            bool coveredByMaturities,
            bool coveredByIdle,
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

        // matured budget
        uint256 maturedCredit   = core.maturedCreditByUnion(unionAddr);
        uint256 maturedConsumed = core.maturedConsumedByUnion(unionAddr);
        maturedBudget = maturedCredit > maturedConsumed ? (maturedCredit - maturedConsumed) : 0;

        // reserve requirement AFTER promoting this investor (avoid double-counting)
        (uint32 safetyBP, uint224 safetyFloor, , bool exists) = core.reserveCfgByUnion(unionAddr);
        require(exists, "reserve cfg !set");

        uint256 claimable = core.unionClaimable(unionAddr);
        uint256 claimableAfter = claimable > pendingPrincipalSnap ? (claimable - pendingPrincipalSnap) : 0;
        uint256 bumpAfter = (uint256(safetyBP) * claimableAfter) / 10_000;
        uint256 requiredReserveAfter = claimableAfter + bumpAfter + uint256(safetyFloor);

        // idle for this loanType = Jr cash for type + Sr cash
        IFundCore.MarketLite memory jm = core.getJuniorMarket(unionAddr, loanType);
        IFundCore.MarketLite memory sm = core.getSeniorMarket(unionAddr);
        uint256 idle = jm.cash + sm.cash;

        coveredByMaturities = (pendingPrincipalSnap > 0) && (maturedBudget >= pendingPrincipalSnap);
        coveredByIdle       = (pendingPrincipalSnap > 0) && (idle >= (requiredReserveAfter + pendingPrincipalSnap));

        // same gate as Core.claimJunior (post-fix)
        eligibleNow = (inv.shares > 0) || (inv.pending > 0 && pastMin && (coveredByMaturities || coveredByIdle));
    }

    function getLiquidityBuffer(
        address unionAddr,
        bytes32 loanType
        ) external view returns (
        uint16 safetyBP,
        uint256 safetyFloor,
        uint256 claimableReserved,
        uint256 idleCashForType,   // junior[union,loanType].cash + senior[union].cash + moduleCashByUnion[union]
        bool hardStop,
        uint256 requiredReserve,
        uint256 headroom           // max interest payout if !hardStop; else min(idle - req, junior.cash) typically enforced in core
        ) {
        (uint32 bp, uint224 floor, bool hs, bool exists) = core.reserveCfgByUnion(unionAddr);
        require(exists, "reserve cfg !set");
        if (!exists) revert ReserveConfigSet();
        safetyBP = uint16(bp);
        safetyFloor = uint256(floor);
        hardStop = hs;

        claimableReserved = core.unionClaimable(unionAddr);

        IFundCore.MarketLite memory jm = core.getJuniorMarket(unionAddr, loanType);
        IFundCore.MarketLite memory sm = core.getSeniorMarket(unionAddr);

        uint256 idle = jm.cash + sm.cash; // + core.moduleCashByUnion(unionAddr);
        idleCashForType = idle;

        uint256 bump = (uint256(safetyBP) * claimableReserved) / 10_000;
        requiredReserve = claimableReserved + bump + safetyFloor;

        headroom = idle > requiredReserve ? (idle - requiredReserve) : 0;
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

    // storage gap for future variables
    uint256[48] private __gap;
}

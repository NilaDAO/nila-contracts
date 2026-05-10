// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

/*
 * GenericFund Core — Single ERC20 (v2-simplified)
 *
 * Assumptions:
 * - Exactly ONE ERC20 nin for all unions/markets (address stored in `nin`).
 * - Senior markets are per-UNION.
 * - Junior markets are per-UNION + loanType (bytes32).
 * - Per-UNION liquidity buffers (safetyBP, floor, hardStop).
 * - Maturity-aware unbond promotion (later of: min window, or covered by scheduled maturities).
 * - NFT gating: juniors & borrowers MUST hold union NFT; seniors MUST NOT hold it.
 *
 * What lives here:
 * - State (unions, markets, investors, loans)
 * - Loan lifecycle: fund → claim → repay → default → transfer/rollover (leader-only)
 * - ERC20 Senior/Junior deposits & unbonding (ERC20 only; ERC1155 in module)
 * - Liquidity buffer checks (per union) before funding loans and on claims
 * - Interest distribution: 1% fee to union treasury bucket, split 50/50 Jr/Sr (matching union/loanType)
 * - Index accounting (RAY)
 *
 * What does NOT live here:
 * - Read-only helpers/Viewer
 * - ERC1155 quoting & in-kind paths (module-only). Union-aware hooks provided.
 */

/*

DEVNOTES

    - I set drawdownTs to 0, only using createTs, as both sare set on autoloan at the same time. 
    - But when we do manual acceptance, this is not longer true, and it is unfair to already accrue interest when the loan has not been accepted....

*/

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

//  ----------- Custom math libary -----------
import { GenericFundMathLib } from "./GenericFundMathLib.sol";

interface INilaNIN is IERC20 {
    function permit(address owner, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s) external;
}

// interface to viewer
interface IViewer {
    function recoverVoucherSigner( address coreAddr, address borrower,address unionAddr, bytes32 loanId, uint256 maxAmount, uint16  minRateBP,bytes32 loanType,bytes32 paramsHash, bool fastDraw, uint256 escrowId, uint40 sosDate, uint256 nonce, bytes calldata sig ) external view returns (address);
    function onLoanCreated(address unionAddr, bytes32 loanId, address borrower) external;
    function onLoanClosed(address unionAddr, bytes32 loanId, address borrower) external;
    function onAddFundType(address unionAddr, string calldata displayName ) external;
    function onRemoveFundType(address unionAddr, uint256 i ) external;
}

interface IFxPool {
    function resolveEscrowCash(uint256 escrowId, uint256 amount, address unionAddr) external;
}
interface IRoles {
    function isLeader(address unionAddr, address account) external view returns (bool);
    function isOracle(address account) external view returns (bool);
}

interface IERC721Like {
    function balanceOf(address owner) external view returns (uint256);
}

library ICore {
    enum Tranche { JUNIOR, SENIOR }

    struct InvestorLite {
        uint40  unbondPeriod;
        uint256 shares;
        uint256 locked;     // pending + claimable
        uint256 pending;
        uint256 pendingPrincipalSnap;
        uint256 entryIndex;             // last settled index (RAY)
    }

    struct MarketLite {
        uint256 cash;
        uint256 index;      // RAY
        uint256 totalShares;
        uint256 totalBorrows;
        uint256 claimablePrincipal;
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
        uint40  lastAccrualTs;      // last time interest was accrued into interestAccrued
        uint128 interestAccrued;    // total interest accrued so far (monotonic)
        bool    lowerRate;
        uint40  sosDate;            // oracle-signed start-of-season date (informational)
    }
}

contract GenericFundCore is
    Initializable,
    OwnableUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable
{
    using GenericFundMathLib for uint256;
    INilaNIN public nin;
    address private fxPool; // RESERVED — storage slot must not be removed for upgrade safety

    // ---------- Constants ----------
    uint256 public constant YEAR               = 365 days;
    uint256 private constant HUNDRED_PERCENT_BP = 10_000;
    uint256 public constant DEFAULT_UNBONDING  = 14 days;
    uint256 private constant WAD                = 1e18;

    // ---------- Admin addresses ----------
    IRoles           public roles;         // oracle/leader registry
    address          public viewer;        // for voucher verification
    address          public landNFT;

    // ---------- Per-union liquidity buffer ----------
    struct ReserveCfg {
        uint32  safetyBP;
        uint224 safetyFloor;
        bool    hardStop;
        bool    exists;
        uint32  escrowDuration;     // seconds; 0 = use FxPool global default
        uint32  collectDeadline;    // seconds — burn permit window for farmer cash collection
    }
    mapping(address => ReserveCfg) public reserveCfgByUnion;   // union => cfg
    mapping(address => uint256) public unionClaimable;         // union => reserved principal (ERC20 paths + 1155 via hook)

    // ---------- Caps & rates ----------
    mapping(address => mapping(bytes32 => uint256)) public bucketTresholds;
    mapping(address => GenericFundMathLib.RateParams) public rateParamsByUnion;
    mapping(address => uint256) public unionBorrowsAgg;      // utilization per union
    mapping(address => uint256) public unionTreasury;

    // ---------- Markets ----------
    struct SeniorMarket {
        uint256 cash;
        uint256 index;       // RAY
        uint256 totalShares;
        uint256 totalBorrows;
        uint256 claimablePrincipal;
    }
    mapping(address => SeniorMarket) internal senior; // union => market

    struct JuniorMarket {
        uint256 cash;
        uint256 index;       // RAY
        uint256 totalShares;
        uint256 claimablePrincipal;
        uint256 totalBorrows;
        bool exists;
    }
    mapping(address => mapping(bytes32 => JuniorMarket)) internal junior; // union => loanType => market
 
    // ---------- Investors ----------
    struct Investor {
        uint256 shares;
        uint256 pending;     // shares awaiting promotion
        uint256 claimable;   // shares ready to claim
        uint40  requestTs;
        // yield settlement
        uint256 entryIndex;  // RAY
        uint256 unclaimed;   // RESERVED — kept for storage layout compatibility, do not use
        // snapshot for maturity-aware promotion
        uint256 pendingPrincipalSnap;
    }
    mapping(address => mapping(address => Investor)) internal seniorInv; // union => investor => inv
    mapping(address => mapping(bytes32 => mapping(address => Investor))) internal juniorInv; // union => loanType => investor => inv

    // ---------- Loans ----------
    mapping(address => mapping(bytes32 => ICore.Loan)) public loans; // union => loanId => loan

    // ---------- Module accounting (1155) ----------
    // uncomment on ERC1155 virtual liquidity: mapping(address => uint256) public foodTokenLiquidity; // union => net cash in ERC1155 tokens

    // ---------- Maturity ledger (per union) — RESERVED, no longer used post-CS006 ----------
    mapping(address => mapping(uint40 => uint256)) internal _reservedScheduledPrincipalByDate;
    mapping(address => uint256) private _reservedMaturedCredit;
    mapping(address => uint256) private _reservedMaturedConsumed;
    mapping(address => mapping(bytes32 => uint256)) internal _reservedLoanScheduledPrincipal;

    // ---------- New storage (append-only) ----------
    mapping(address => mapping(bytes32 => uint256)) public bucketMaxAmount;
    mapping(address => uint256) public unionRainyDay;
    uint16 public treasuryFeeBP; // basis points, defaults 1%
    uint16 public rainyFeeBP;    // basis points, defaults 2%

    // ---------- CS003 storage (append-only) ----------
    address public fxPoolAddr;                       // NilaFxPool — authorized to call burnEscrowNin
    mapping(address => uint256) public nonces;       // per-borrower nonce for voucher replay protection

    // ---------- CS019 storage (append-only) ----------
    mapping(address => mapping(bytes32 => uint256)) public juniorPendingPrincipal; // union => loanType => sum of inv.pendingPrincipalSnap
    mapping(address => uint256) public seniorPendingPrincipal;                     // union => sum of inv.pendingPrincipalSnap

    // ---------- Upgrade gap (append new vars ABOVE this line, reduce gap by count added) ----------
    uint256[46] private __gap;

    // ── Custom errors (short revert strings save code size) ──
    error NotOracleOrLeader();
    error AmountZero();
    error ReserveStop();
    error InsufficientCash();
    error NothingToClaim();
    error NotEligibleMaturity();
    error NftRequired();
    error NftForbidden();
    error SignatureInvalid();
    error NotExists();
    error BadKink();
    error BadShares();
    error BadState();
    error BadArg();
    error LoanNotExist();
    error LoanClosed();
    error LoanHasBeenAccepted();
    error MaxLoanAmount();
    error VoucherAmountTooHigh();
    error BadRatio();
    error BadNonce();

    // ---------- Events ----------
    event UnionReserveUpdated(address indexed unionAddr, uint32 safetyBP, uint224 safetyFloor, bool hardStop);
    event RateParamsUpdated(address indexed unionAddr, uint16 baseRateBP, uint16 kinkUtilBP, uint16 slope1BP, uint16 slope2BP, uint16 maxRateBP);
    event JuniorMarketCreated(address indexed unionAddr, bytes32 indexed loanType);

    event Deposit(address indexed investor, ICore.Tranche tranche, address indexed unionAddr, bytes32 loanType, uint256 amount, uint256 sharesOut);
    event UnbondRequested(address indexed investor, ICore.Tranche tranche, address indexed unionAddr, bytes32 loanType, uint256 shares, uint256 principalSnap);
    event UnbondPromoted(address indexed investor, ICore.Tranche tranche, address indexed unionAddr, bytes32 loanType, uint256 shares, uint256 principalSnap);
    event Claimed(address indexed investor, ICore.Tranche tranche, address indexed unionAddr, bytes32 loanType, uint256 amount);

    event LoanClaimed(address indexed unionAddr, bytes32 indexed loanId, address borrower, bytes32 loanType, uint256 amount, uint16 rateBP, uint40 sosDate, uint40 drawdownTs, bool fastDraw);
    event LoanAccepted(address indexed unionAddr, bytes32 indexed loanId, uint256 amount, address borrower);
    event LoanRepaid(address indexed unionAddr, bytes32 indexed loanId, uint256 interestPaid, uint256 principalPaid);
    event LoanDefaulted(address indexed unionAddr, bytes32 indexed loanId, uint256 juniorApplied, uint256 seniorApplied);
    event BucketThresholdAdjusted(address indexed unionAddr, bytes32 indexed loanType, uint256 oldThreshold, uint256 newThreshold, bool wasDefault);
    event MilestoneReported(address indexed unionAddr, bytes32 indexed loanId, uint16 milestone, bytes32 milestoneDigest);
    event TreasuryBurnedForExpiry(address indexed unionAddr, uint256 burned, uint256 requested);

    // ---------- Modifiers ----------
    modifier onlyOracleOrLeader(address unionAddr) { 
        bool ok = (address(roles) != address(0) && (roles.isOracle(msg.sender) || roles.isLeader(unionAddr, msg.sender)))
            || owner() == msg.sender;
        if (!ok) revert NotOracleOrLeader();
        _;
    }

    modifier onlyLeader(address unionAddr) { 
        bool ok = (address(roles) != address(0) && roles.isLeader(unionAddr, msg.sender))
            || owner() == msg.sender;
        if (!ok) revert NotOracleOrLeader();
        _;
    }

    // ---------- Initializer / Upgrader ----------
    function initialize(address landTitle, address _roles, address _nin ) external initializer {
        __Ownable_init(msg.sender);
        __Pausable_init();
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();

        roles = IRoles(_roles);
        landNFT = landTitle;
        nin = INilaNIN(_nin);
        treasuryFeeBP = 100;
        rainyFeeBP    = 200;
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    /// @notice One-time migration: swap NIN token to NINv2. Called as part of upgradeAndCall.
    /// @dev reinitializer(2) ensures this can never be called again after the upgrade.
    function reinitialize(address ninv2) external reinitializer(2) {
        if (ninv2 == address(0)) revert BadArg();
        nin = INilaNIN(ninv2);
    }

    // ---------- Admin ----------
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    // ---------- Setters ----------
    function setViewer(address v) external onlyOwner { viewer = v; }
    function setRoles(address v) external onlyOwner { roles = IRoles(v); }
    function setLandTitle(address v) external onlyOwner { landNFT = v; }

    uint32 private constant MIN_DURATION = 3 hours;

    function setReserveConfigForUnion(address unionAddr, uint32 safetyBP, uint224 safetyFloor, bool hardStop, uint32 escrowDuration, uint32 collectDeadline)
        external onlyOracleOrLeader(unionAddr)
        {
        if (escrowDuration < MIN_DURATION || collectDeadline < MIN_DURATION) revert BadArg();
        reserveCfgByUnion[unionAddr] = ReserveCfg({
            safetyBP: safetyBP,
            safetyFloor: safetyFloor,
            hardStop: hardStop,
            exists: true,
            escrowDuration: escrowDuration,
            collectDeadline: collectDeadline
        });
        emit UnionReserveUpdated(unionAddr, safetyBP, safetyFloor, hardStop);
    }

    function setFxPoolAddr(address _fxPool) external onlyOwner {
        fxPoolAddr = _fxPool;
    }

    /// @notice Credit nIN cash to a junior market on behalf of a cash-scan escrow.
    /// @dev Called by FxPool immediately after minting nIN to this contract (cashScanMint).
    ///      If member != address(0), mints junior shares attributed to that member (contribution).
    ///      If member == address(0), credits pool cash only — no investor owner (loan liquidity).
    function creditEscrowNin(address unionAddr, bytes32 loanType, uint256 amount, address member) external {
        if (msg.sender != fxPoolAddr) revert NotOracleOrLeader();
        if (amount == 0) revert AmountZero();
        _ensureJuniorMarket(unionAddr, loanType);

        JuniorMarket storage m = junior[unionAddr][loanType];
        m.cash += amount;

        if (member != address(0)) {
            // Member contribution path: attribute shares to member
            _settleYield(juniorInv[unionAddr][loanType][member], m.index);
            uint256 shares = (amount * GenericFundMathLib.RAY) / m.index;
            m.totalShares += shares;
            juniorInv[unionAddr][loanType][member].shares += shares;
            emit Deposit(member, ICore.Tranche.JUNIOR, unionAddr, loanType, amount, shares);
        }
    }

    /// @notice Burn nIN held in this contract. Callable ONLY by FxPool for expired escrow cleanup.
    /// @dev Debits the junior market cash that was credited at scan time, then sends nIN to FxPool for burning.
    function burnEscrowNin(address unionAddr, bytes32 loanType, uint256 amount) external {
        if (msg.sender != fxPoolAddr) revert NotOracleOrLeader();
        if (amount == 0) revert AmountZero();
        JuniorMarket storage m = junior[unionAddr][loanType];
        // Deduct only what remains — loan draws may have already consumed some or all of this cash.
        if (m.cash >= amount) {
            m.cash -= amount;
        } else {
            m.cash = 0;
        }
        nin.transfer(msg.sender, amount);
    }

    /// @notice Return the per-union escrow duration. Used by FxPool when creating escrows.
    function getUnionEscrowDuration(address unionAddr) external view returns (uint32) {
        return reserveCfgByUnion[unionAddr].escrowDuration;
    }

    function setBucketThresholds(
        address unionAddr,
        bytes32 loanType,
        uint256 thresholdWad,
        uint256 maxLoanAmount
        ) external onlyOwner {
        bucketTresholds[unionAddr][loanType] = thresholdWad;
        bucketMaxAmount[unionAddr][loanType] = maxLoanAmount;
    }

    function setRateParams(
        address unionAddr,
        uint16 baseRateBP,
        uint16 kinkUtilBP,
        uint16 slope1BP,
        uint16 slope2BP,
        uint16 maxRateBP
        ) external onlyOracleOrLeader(unionAddr) {
        if (kinkUtilBP == 0 || kinkUtilBP > 10_000) revert BadKink();
        rateParamsByUnion[unionAddr] = GenericFundMathLib.RateParams({
            baseRateBP: baseRateBP,
            kinkUtilBP: kinkUtilBP,
            slope1BP:   slope1BP,
            slope2BP:   slope2BP,
            maxRateBP:  maxRateBP
        });
        emit RateParamsUpdated(unionAddr, baseRateBP, kinkUtilBP, slope1BP, slope2BP, maxRateBP);
    }

    function setFeeBps(uint16 treasuryBP, uint16 rainyBP) external onlyOwner {
        treasuryFeeBP = treasuryBP;
        rainyFeeBP = rainyBP;
    }

    function withdrawUnionTreasury(address unionAddr, uint256 amount, bool fromRainy, bool deposit) external nonReentrant onlyLeader(unionAddr) {
        if (amount == 0) revert AmountZero();
        if (deposit) {
            nin.transferFrom(msg.sender, address(this), amount);
            unionTreasury[unionAddr] += amount;
        } else if (fromRainy) {
            uint256 rainy = unionRainyDay[unionAddr];
            if (amount > rainy) revert InsufficientCash();
            unionRainyDay[unionAddr] = rainy - amount;
            nin.transfer(msg.sender, amount);
        } else {
            uint256 bal = unionTreasury[unionAddr];
            if (amount > bal) revert InsufficientCash();
            unionTreasury[unionAddr] = bal - amount;
            nin.transfer(msg.sender, amount);
        }
    }

    /// @notice Called by FxPool when a cash escrow expires.
    /// @dev Debits unionTreasury (not junior.cash) and transfers nIN to FxPool for burning.
    ///      Clamped to treasury balance — cap enforcement in cashScanMint ensures treasury >= active escrows.
    /// @return burned Actual nIN transferred (may be less than amount if treasury is depleted).
    function burnTreasuryForExpiry(address unionAddr, uint256 amount)
        external
        returns (uint256 burned)
    {
        if (msg.sender != fxPoolAddr) revert NotOracleOrLeader();
        if (amount == 0) revert AmountZero();
        uint256 bal = unionTreasury[unionAddr];
        burned = amount > bal ? bal : amount;
        unionTreasury[unionAddr] = bal - burned;
        if (burned > 0) nin.transfer(msg.sender, burned);
        emit TreasuryBurnedForExpiry(unionAddr, burned, amount);
    }

    // ---------- Internals ----------
    function _ensureJuniorMarket(address unionAddr, bytes32 loanType) internal {
        JuniorMarket storage m = junior[unionAddr][loanType];
        if (!m.exists) {
            m.exists = true;
            m.index = GenericFundMathLib.RAY;
            emit JuniorMarketCreated(unionAddr, loanType);
        }
    }

    function _ensureSeniorMarket(address unionAddr) internal {
        SeniorMarket storage m = senior[unionAddr];
        if (m.index == 0) m.index = GenericFundMathLib.RAY;
    }

    // Bucket threshold adjustment constants (WAD = 1e18)
    uint256 private constant BUCKET_THRESHOLD_MIN = 0.1e18;  // 10%
    uint256 private constant BUCKET_THRESHOLD_MAX = 1e18;    // 100%
    uint256 private constant BUCKET_DEFAULT_STEP  = 0.1e18;  // +10pp on default
    uint256 private constant BUCKET_REPAY_STEP    = 0.01e18; // -1pp on full repay

    /// @dev Nudges bucketTresholds up on default, down on full repayment.
    ///      Only acts when a threshold is already set (non-zero) for the market.
    function _adjustBucketThreshold(address unionAddr, bytes32 loanType, bool isDefault) internal {
        uint256 current = bucketTresholds[unionAddr][loanType];
        if (current == 0) return; // ratio check disabled for this market — don't auto-enable it

        uint256 next;
        if (isDefault) {
            next = current + BUCKET_DEFAULT_STEP;
            if (next > BUCKET_THRESHOLD_MAX) next = BUCKET_THRESHOLD_MAX;
        } else {
            next = current > BUCKET_REPAY_STEP + BUCKET_THRESHOLD_MIN
                ? current - BUCKET_REPAY_STEP
                : BUCKET_THRESHOLD_MIN;
        }

        if (next == current) return; // already at bound, skip storage write + event
        bucketTresholds[unionAddr][loanType] = next;
        emit BucketThresholdAdjusted(unionAddr, loanType, current, next, isDefault);
    }

    /// @dev Fix B (CS019): equity-based ratio on both sides, adjusted for pending withdrawals.
    ///      Threshold expresses: "junior effective equity must be >= X% of senior effective equity."
    function _verifyBucketRatio(
        address unionAddr,
        bytes32 loanType,
        uint256 /* takeJunior — kept for call-site compat */
        ) internal view {
        uint256 threshold = bucketTresholds[unionAddr][loanType];
        if (threshold == 0) return; // ratio check disabled for this market

        JuniorMarket storage jm = junior[unionAddr][loanType];
        SeniorMarket storage sm = senior[unionAddr];

        uint256 jrIndex = GenericFundMathLib.normalizeIndex(jm.index);
        uint256 srIndex = GenericFundMathLib.normalizeIndex(sm.index);

        // junior effective equity = totalShares × index − pending unbonds (snap value)
        uint256 juniorEquity = GenericFundMathLib.toUnderlying(jm.totalShares, jrIndex);
        uint256 jrPending = juniorPendingPrincipal[unionAddr][loanType];
        uint256 juniorEffective = juniorEquity > jrPending ? juniorEquity - jrPending : 0;

        // senior effective equity = totalShares × index − pending unbonds (snap value)
        uint256 seniorEquity = GenericFundMathLib.toUnderlying(sm.totalShares, srIndex);
        uint256 srPending = seniorPendingPrincipal[unionAddr];
        uint256 seniorEffective = seniorEquity > srPending ? seniorEquity - srPending : 0;

        if (seniorEffective == 0) return;

        uint256 ratio = Math.mulDiv(juniorEffective, WAD, seniorEffective);
        if (ratio < threshold) revert BadRatio();
    }

    function _requireHoldsNFT(address holder) internal view {
        if (IERC721Like(landNFT).balanceOf(holder) == 0) revert NftRequired();
    }

    function _requireNotHoldingNFT( address holder) internal view {
        if (IERC721Like(landNFT).balanceOf(holder) != 0) revert NftForbidden();
    }

    function _bumpUnionClaimable(address unionAddr, int256 delta) internal {
        if (delta > 0) unionClaimable[unionAddr] += uint256(delta);
        else if (delta < 0) unionClaimable[unionAddr] -= uint256(-delta);
    }

    function _requiredReserveFor(address unionAddr) internal view returns (ReserveCfg memory cfg, uint256 req) {
        cfg = reserveCfgByUnion[unionAddr];
        if (!cfg.exists) revert NotExists();
        uint256 claimable = unionClaimable[unionAddr];
        uint256 bump = (uint256(cfg.safetyBP) * claimable) / HUNDRED_PERCENT_BP;
        req = claimable + bump + uint256(cfg.safetyFloor);
    }

    function _checkReserveBeforeFundingFor(address unionAddr, bytes32 loanType, uint256 amount) internal view {
        (, uint256 req) = _requiredReserveFor(unionAddr);
        uint256 idle = junior[unionAddr][loanType].cash + senior[unionAddr].cash; // uncomment on ERC1155 virtual liquidity: + foodTokenLiquidity[unionAddr];
        if (idle < amount + req) revert ReserveStop();
    }

    function _settleYield(Investor storage inv, uint256 currentIndex) internal {
        inv.entryIndex = GenericFundMathLib.normalizeIndex(currentIndex);
    }



    function _distributeInterest(
        address unionAddr,
        bytes32 loanType,
        uint256 interest,
        uint16  rateBP
        ) internal {
        // Union fee is a proportional slice of interest: totalFeeBP / rateBP.
        // This keeps LP yield at a stable (rateBP - totalFeeBP) / rateBP fraction regardless of rate.
        // Skipped when rateBP <= totalFeeBP (union forfeits — not enough spread to reward investors).
        uint256 totalFeeBP = uint256(treasuryFeeBP) + uint256(rainyFeeBP);
        uint256 fee;
        uint256 rainy;
        if (rateBP > totalFeeBP && interest > 0) {
            uint256 totalFee = (interest * totalFeeBP) / uint256(rateBP);
            fee   = (totalFee * uint256(treasuryFeeBP)) / totalFeeBP;
            rainy = totalFee - fee;
        }
        if (fee > 0)   unionTreasury[unionAddr] += fee;
        if (rainy > 0) unionRainyDay[unionAddr] += rainy;

        uint256 net = interest - fee - rainy;

        JuniorMarket storage jm = junior[unionAddr][loanType];
        SeniorMarket storage sm = senior[unionAddr];

        // Split interest proportional to each market's total deposit value (shares * index / RAY).
        // index is initialised to RAY and only increases, so no underflow guard needed.
        uint256 jDeposits = Math.mulDiv(jm.totalShares, jm.index, GenericFundMathLib.RAY);
        uint256 sDeposits = Math.mulDiv(sm.totalShares, sm.index, GenericFundMathLib.RAY);
        uint256 totalDeposits = jDeposits + sDeposits;
        uint256 toJunior;
        uint256 toSenior;
        if (totalDeposits == 0) {
            toJunior = net / 2;
            toSenior = net - toJunior;
        } else {
            toJunior = Math.mulDiv(net, jDeposits, totalDeposits);
            toSenior = net - toJunior;
        }

        // add cash
        jm.cash += toJunior;
        sm.cash += toSenior;

        // index bumps
        if (jm.totalShares > 0) {
            uint256 dIdxJ = (toJunior * GenericFundMathLib.RAY) / jm.totalShares;
            jm.index += dIdxJ;
        }
        if (sm.totalShares > 0) {
            uint256 dIdxS = (toSenior * GenericFundMathLib.RAY) / sm.totalShares;
            sm.index += dIdxS;
        }
    }

    function _redeemClaimable(
        bool isJunior,
        address unionAddr,
        bytes32 loanType,
        address investor,
        uint256 maxShares
        ) internal {
        Investor storage inv = isJunior
            ? juniorInv[unionAddr][loanType][investor]
            : seniorInv[unionAddr][investor];

        if (inv.claimable == 0) revert NothingToClaim();

        uint256 burnShares = (maxShares == 0 || maxShares > inv.claimable) ? inv.claimable : maxShares;

        if (isJunior) {
            JuniorMarket storage m = junior[unionAddr][loanType];
            // Camp B: pay the snap (value at request time), not the live index
            uint256 amount = inv.pendingPrincipalSnap * burnShares / inv.claimable;
            uint256 currentValue = GenericFundMathLib.toUnderlying(burnShares, m.index);
            uint256 idle = m.cash + senior[unionAddr].cash;
            (ReserveCfg memory cfg,) = _requiredReserveFor(unionAddr);
            if (cfg.hardStop) {
                uint256 postClaimable = unionClaimable[unionAddr] > amount ? unionClaimable[unionAddr] - amount : 0;
                uint256 req = postClaimable + (uint256(cfg.safetyBP) * postClaimable) / HUNDRED_PERCENT_BP + uint256(cfg.safetyFloor);
                if (idle < amount + req) revert ReserveStop();
            }
            if (m.cash < amount) revert InsufficientCash();
            inv.claimable -= burnShares; inv.shares -= burnShares;
            m.totalShares -= burnShares; m.cash -= amount;
            inv.pendingPrincipalSnap -= amount;
            juniorPendingPrincipal[unionAddr][loanType] = juniorPendingPrincipal[unionAddr][loanType] > amount
                ? juniorPendingPrincipal[unionAddr][loanType] - amount : 0;
            m.claimablePrincipal = m.claimablePrincipal > amount ? m.claimablePrincipal - amount : 0;
            _bumpUnionClaimable(unionAddr, -int256(amount));
            // Lazy index adjustment: remaining shares absorb the delta between snap and live value
            if (m.totalShares > 0) {
                if (amount > currentValue) {
                    uint256 dropPerShare = (amount - currentValue) * GenericFundMathLib.RAY / m.totalShares;
                    m.index = m.index > dropPerShare ? m.index - dropPerShare : 0;
                } else if (currentValue > amount) {
                    uint256 bumpPerShare = (currentValue - amount) * GenericFundMathLib.RAY / m.totalShares;
                    m.index += bumpPerShare;
                }
            }
            // if totalShares == 0, index is irrelevant — no shares left to apply to
            nin.transfer(investor, amount);
            emit Claimed(investor, ICore.Tranche.JUNIOR, unionAddr, loanType, amount);
        } else {
            SeniorMarket storage m = senior[unionAddr];
            // Camp B: pay the snap (value at request time), not the live index
            uint256 amount = inv.pendingPrincipalSnap * burnShares / inv.claimable;
            uint256 currentValue = GenericFundMathLib.toUnderlying(burnShares, m.index);
            (ReserveCfg memory cfg,) = _requiredReserveFor(unionAddr);
            if (cfg.hardStop) {
                uint256 postClaimable = unionClaimable[unionAddr] > amount ? unionClaimable[unionAddr] - amount : 0;
                uint256 req = postClaimable + (uint256(cfg.safetyBP) * postClaimable) / HUNDRED_PERCENT_BP + uint256(cfg.safetyFloor);
                if (m.cash < amount + req) revert ReserveStop();
            }
            if (m.cash < amount) revert InsufficientCash();
            inv.claimable -= burnShares; inv.shares -= burnShares;
            m.totalShares -= burnShares; m.cash -= amount;
            inv.pendingPrincipalSnap -= amount;
            seniorPendingPrincipal[unionAddr] = seniorPendingPrincipal[unionAddr] > amount
                ? seniorPendingPrincipal[unionAddr] - amount : 0;
            m.claimablePrincipal = m.claimablePrincipal > amount ? m.claimablePrincipal - amount : 0;
            _bumpUnionClaimable(unionAddr, -int256(amount));
            // Lazy index adjustment: remaining shares absorb the delta
            if (m.totalShares > 0) {
                if (amount > currentValue) {
                    uint256 dropPerShare = (amount - currentValue) * GenericFundMathLib.RAY / m.totalShares;
                    m.index = m.index > dropPerShare ? m.index - dropPerShare : 0;
                } else if (currentValue > amount) {
                    uint256 bumpPerShare = (currentValue - amount) * GenericFundMathLib.RAY / m.totalShares;
                    m.index += bumpPerShare;
                }
            }
            // if totalShares == 0, index is irrelevant — no shares left to apply to
            nin.transfer(investor, amount);
            emit Claimed(investor, ICore.Tranche.SENIOR, unionAddr, bytes32(0), amount);
        }
    }

    // ---------- Senior (ERC20) ----------
    function depositSenior(address unionAddr, uint256 amount) external whenNotPaused nonReentrant {
        if (amount == 0) revert AmountZero();
        // TODO(next update): allow union leader to bypass this NFT restriction.
        _requireNotHoldingNFT(msg.sender);

        _ensureSeniorMarket(unionAddr);
        _settleYield(seniorInv[unionAddr][msg.sender], senior[unionAddr].index);

        nin.transferFrom(msg.sender, address(this), amount);

        SeniorMarket storage m = senior[unionAddr];
        m.cash += amount;

        uint256 pps = GenericFundMathLib.normalizeIndex(m.index);
        uint256 shares = (amount * GenericFundMathLib.RAY) / pps;
        m.totalShares += shares;
        seniorInv[unionAddr][msg.sender].shares += shares;

        emit Deposit(msg.sender, ICore.Tranche.SENIOR, unionAddr, bytes32(0), amount, shares);
    }

    function requestUnbondSenior(address unionAddr, uint256 shares) external whenNotPaused {
        Investor storage inv = seniorInv[unionAddr][msg.sender];
        if (shares == 0 || shares > inv.shares - inv.pending - inv.claimable) revert BadShares();

        inv.pending += shares;
        inv.requestTs = uint40(block.timestamp);

        uint256 amountSnap = GenericFundMathLib.toUnderlying(shares, senior[unionAddr].index);
        inv.pendingPrincipalSnap += amountSnap;
        senior[unionAddr].claimablePrincipal += amountSnap;
        seniorPendingPrincipal[unionAddr] += amountSnap;
        _bumpUnionClaimable(unionAddr, int256(amountSnap));

        emit UnbondRequested(msg.sender, ICore.Tranche.SENIOR, unionAddr, bytes32(0), shares, amountSnap);
    }

    function claimSenior(address unionAddr, uint256 maxShares) external nonReentrant {
        Investor storage inv = seniorInv[unionAddr][msg.sender];

        // ── Eligibility: min window + bucket-local snap coverage ──
        if (inv.claimable == 0 && inv.pending > 0) {
            bool pastMin = block.timestamp >= inv.requestTs + DEFAULT_UNBONDING;
            bool coveredByBucket = senior[unionAddr].cash >= inv.pendingPrincipalSnap;

            if (!(pastMin && coveredByBucket)) revert NotEligibleMaturity();

            _settleYield(inv, senior[unionAddr].index);

            uint256 toPromote = inv.pending;
            inv.pending = 0;
            inv.claimable += toPromote;
            // pendingPrincipalSnap kept — used by _redeemClaimable for snap payout

            emit UnbondPromoted(msg.sender, ICore.Tranche.SENIOR, unionAddr, bytes32(0), toPromote, 0);
        }

        if (inv.claimable == 0) revert NothingToClaim();
        _redeemClaimable(false, unionAddr, bytes32(0), msg.sender, maxShares);
    }

    // ---------- Junior (ERC20) ----------
    /// @notice Deposit nIN into the junior market.
    /// @param member  Address to receive shares. Pass address(0) or msg.sender for self-deposit.
    ///                Union leaders may pass a member address to deposit on their behalf (cash contribution).
    ///                When called by a union leader on behalf of a member, msg.sender must be a leader for unionAddr.
    function depositJunior(address unionAddr, bytes32 loanType, uint256 amount, address member) external whenNotPaused nonReentrant {
        if (amount == 0) revert AmountZero();

        // Resolve beneficiary: default to caller
        address beneficiary = (member == address(0)) ? msg.sender : member;

        // If depositing on behalf of someone else, caller must be a union leader
        if (beneficiary != msg.sender) {
            bool ok = (address(roles) != address(0) && roles.isLeader(unionAddr, msg.sender))
                || owner() == msg.sender;
            if (!ok) revert NotOracleOrLeader();
        }

        _ensureJuniorMarket(unionAddr, loanType);
        _settleYield(juniorInv[unionAddr][loanType][beneficiary], junior[unionAddr][loanType].index);

        nin.transferFrom(msg.sender, address(this), amount);

        JuniorMarket storage m = junior[unionAddr][loanType];
        m.cash += amount;

        uint256 shares = (amount * GenericFundMathLib.RAY) / m.index;
        m.totalShares += shares;
        juniorInv[unionAddr][loanType][beneficiary].shares += shares;

        emit Deposit(beneficiary, ICore.Tranche.JUNIOR, unionAddr, loanType, amount, shares);
    }

    function requestUnbondJunior(address unionAddr, bytes32 loanType, uint256 shares) external whenNotPaused {
        _ensureJuniorMarket(unionAddr, loanType);
        Investor storage inv = juniorInv[unionAddr][loanType][msg.sender];
        if (shares == 0 || shares > inv.shares - inv.pending - inv.claimable) revert BadShares();

        inv.pending += shares;
        inv.requestTs = uint40(block.timestamp);

        uint256 amountSnap = GenericFundMathLib.toUnderlying(shares, junior[unionAddr][loanType].index);
        inv.pendingPrincipalSnap += amountSnap;
        junior[unionAddr][loanType].claimablePrincipal += amountSnap;
        juniorPendingPrincipal[unionAddr][loanType] += amountSnap;
        _bumpUnionClaimable(unionAddr, int256(amountSnap));

        emit UnbondRequested(msg.sender, ICore.Tranche.JUNIOR, unionAddr, loanType, shares, amountSnap);
    }

    function claimJunior(address unionAddr, bytes32 loanType, uint256 maxShares) external nonReentrant {
        _ensureJuniorMarket(unionAddr, loanType);
        Investor storage inv = juniorInv[unionAddr][loanType][msg.sender];

        // ── Eligibility: min window + bucket-local snap coverage ──
        if (inv.claimable == 0 && inv.pending > 0) {
            bool pastMin = block.timestamp >= inv.requestTs + DEFAULT_UNBONDING;
            bool coveredByBucket = junior[unionAddr][loanType].cash >= inv.pendingPrincipalSnap;

            if (!(pastMin && coveredByBucket)) revert NotEligibleMaturity();

            _settleYield(juniorInv[unionAddr][loanType][msg.sender], junior[unionAddr][loanType].index);

            // promote pending -> claimable
            uint256 toPromote = inv.pending;
            inv.pending = 0;
            inv.claimable += toPromote;
            // pendingPrincipalSnap kept — used by _redeemClaimable for snap payout

            emit UnbondPromoted(msg.sender, ICore.Tranche.JUNIOR, unionAddr, loanType, toPromote, 0);
        }
        if (inv.claimable == 0) revert NothingToClaim();
        _redeemClaimable(true, unionAddr, loanType, msg.sender, maxShares);
    }

    // ---------- Loans ----------
    function drawLoanWithVoucher(
        address unionAddr,
        bytes32 loanId,          // supplied by borrower (must be unique per union)
        bytes32 loanType,
        uint128 amount,
        uint16  rateBP,
        uint40  maturityTs,
        bytes32 paramsHash,      // optional additional constraints (can be 0x0)
        bytes   calldata oracleSig,
        uint256 maxAmount,       // from the voucher (signed)
        uint16  minRateBP,       // from the voucher (signed)
        bool    fastDraw,        // from the voucher (signed)
        uint256 escrowId,        // cash-scan escrow to resolve on disbursement (0 = none)
        uint40  sosDate,         // start-of-season date (informational, stored on loan)
        uint256 nonce,           // per-borrower nonce for replay protection
        uint256 burnDeadline,    // exact deadline signed in the burn permit (0 = no permit / fxPool not set)
        uint8 permitV, bytes32 permitR, bytes32 permitS  // EIP-2612 permit for FxPool to burn nIN at collection
        ) external nonReentrant whenNotPaused {
        // 1) union + fund type + gating
        _requireHoldsNFT(msg.sender);

        // 2) voucher: oracle-signed, bound to borrower (msg.sender)
        address signer = IViewer(viewer).recoverVoucherSigner(
            address(this), msg.sender, unionAddr, loanId, maxAmount, minRateBP, loanType, paramsHash, fastDraw, escrowId, sosDate, nonce, oracleSig
        );
        if (!roles.isOracle(signer)) revert SignatureInvalid();

        // 3) nonce check — prevents voucher replay even with a different loanId
        if (nonce != nonces[msg.sender]) revert BadNonce();
        nonces[msg.sender]++;

        // 4) enforce borrower’s chosen terms within voucher bounds
        if (amount > maxAmount) revert VoucherAmountTooHigh();
        uint256 cap = bucketMaxAmount[unionAddr][loanType];
        if (cap > 0 && amount > cap) revert MaxLoanAmount();

        uint256 borrows = unionBorrowsAgg[unionAddr];

        // 5) buffer check & take cash (junior-to-floor, then senior)
        _checkReserveBeforeFundingFor(unionAddr, loanType, amount);

        JuniorMarket storage jm = junior[unionAddr][loanType];
        SeniorMarket storage sm = senior[unionAddr];

        // Drain junior only down to the ratio floor; use senior for the remainder.
        // This ensures senior deposits are actually utilised and the ratio check
        // is satisfied by construction (juniorCashAfter >= floor >= threshold * totalS).
        uint256 threshold = bucketTresholds[unionAddr][loanType];
        uint256 juniorFloor = 0;
        if (threshold > 0 && sm.totalShares > 0) {
            uint256 srIdx = GenericFundMathLib.normalizeIndex(sm.index);
            uint256 totalS = GenericFundMathLib.toUnderlying(sm.totalShares, srIdx);
            juniorFloor = Math.mulDiv(threshold, totalS, WAD, Math.Rounding.Ceil);
        }
        // Fix A: lock junior cash for pending unbond requests (snap-denominated)
        uint256 lockedCash = juniorPendingPrincipal[unionAddr][loanType];
        uint256 juniorReserved = juniorFloor + lockedCash;
        uint256 juniorAvailable = jm.cash > juniorReserved ? jm.cash - juniorReserved : 0;
        uint256 takeJunior = amount <= juniorAvailable ? amount : juniorAvailable;
        uint256 takeSenior = amount - takeJunior;

        // basic safety
        if (takeSenior > sm.cash) revert InsufficientCash();

        // ratio check (equity-based post-CS019)
        _verifyBucketRatio(unionAddr, loanType, takeJunior);

        // now actually subtract cash
        jm.cash -= takeJunior;
        if (takeSenior > 0) {
            sm.cash -= takeSenior;
        }

        // 6) write loan and disburse immediately (no stranded liquidity)
        uint40 createTs = uint40(block.timestamp);
        ICore.Loan storage ln = loans[unionAddr][loanId];
        if (ln.createTs != 0) revert LoanNotExist();
        ln.borrower         = msg.sender;
        ln.loanType         = loanType;
        ln.principal        = amount;
        ln.rateBP           = rateBP;
        ln.createTs         = createTs;
        ln.maturityTs       = maturityTs;
        ln.drawdownTs       = 0;
        ln.lastAccrualTs    = 0;     // <-- no accrual until funds actually drawn
        ln.interestAccrued  = 0;
        ln.lowerRate        = rateBP < minRateBP;  // true = borrower got a below-floor rate (fees waived)
        ln.sosDate          = sosDate;

        // set funded to use principal in reserve calculation
        ln.fundedFromJunior = uint128(takeJunior);
        ln.fundedFromSenior = uint128(takeSenior);

        unionBorrowsAgg[unionAddr] = borrows + amount;
        junior[unionAddr][loanType].totalBorrows += amount;
        IViewer(viewer).onLoanCreated(unionAddr, loanId, msg.sender);

        // Set FxPool burn allowance — caller provides the exact deadline they signed.
        if (fxPoolAddr != address(0) && burnDeadline > 0) {
            nin.permit(msg.sender, fxPoolAddr, amount, burnDeadline, permitV, permitR, permitS);
        }

        // fastDraw: disburse immediately if rate is within voucher bounds and oracle allowed it.
        // If rateBP < minRateBP the loan is created but held — union leader calls AcceptLoan manually.
        bool doFastDraw = fastDraw && rateBP >= minRateBP;
        if (doFastDraw) {
            ln.drawdownTs    = createTs;
            ln.lastAccrualTs = createTs;
            nin.transfer(msg.sender, amount);
            if (fxPoolAddr != address(0)) {
                IFxPool(fxPoolAddr).resolveEscrowCash(escrowId, amount, unionAddr);
            }
        }

        emit LoanClaimed(unionAddr, loanId, msg.sender, loanType, amount, rateBP, sosDate, ln.drawdownTs, doFastDraw);
    }

    function AcceptLoan(address unionAddr, bytes32 loanId, uint256 escrowId) external onlyLeader(unionAddr) {
        ICore.Loan storage ln = loans[unionAddr][loanId];
        if (ln.createTs == 0) revert LoanNotExist();
        if (ln.drawdownTs != 0) revert LoanHasBeenAccepted(); // already drawn

        uint128 amount = ln.principal;
        address borrower = ln.borrower;

        ln.drawdownTs   = uint40(block.timestamp);
        ln.lastAccrualTs = ln.drawdownTs; // interest starts now

        nin.transfer(borrower, amount);
        // resolve cash-scan escrow (or gate-check only when escrowId=0)
        if (fxPoolAddr != address(0)) {
            IFxPool(fxPoolAddr).resolveEscrowCash(escrowId, uint256(amount), unionAddr);
        }

        emit LoanAccepted(unionAddr, loanId, amount, borrower);
    }

    function repayLoan(address unionAddr, bytes32 loanId, uint256 amount)
        external
        nonReentrant
        whenNotPaused
        returns (bool fullyRepaid)
        {
        ICore.Loan storage ln = loans[unionAddr][loanId];
        if (ln.defaulted || ln.liquidated) revert BadState();
        if (amount == 0) revert AmountZero();

        // pull funds in
        nin.transferFrom(msg.sender, address(this), amount);

        // ------------------------------------------------------------------
        // 1) Interest: accrue on LEFTOVER principal, from lastAccrualTs → now
        // ------------------------------------------------------------------

        // principal outstanding BEFORE applying this payment
        uint256 principalOutstanding =
            uint256(ln.principal) > uint256(ln.principalPaid)
                ? (uint256(ln.principal) - uint256(ln.principalPaid))
                : 0;

        // from when do we accrue?
        uint40 lastTs = ln.lastAccrualTs == 0 ? ln.createTs : ln.lastAccrualTs;
        uint256 elapsed = block.timestamp > uint256(lastTs)
            ? (block.timestamp - uint256(lastTs))
            : 0;

        // simple interest for this period, ONLY on leftover principal
        uint256 interestForPeriod = GenericFundMathLib.accruedInterest(
            principalOutstanding,
            ln.rateBP,
            elapsed,
            YEAR
        );

        // total interest that exists so far for this loan
        uint256 totalAccrued = uint256(ln.interestAccrued) + interestForPeriod;

        // how much of that is still unpaid?
        uint256 interestOwed = totalAccrued > uint256(ln.interestPaid)
            ? (totalAccrued - uint256(ln.interestPaid))
            : 0;

        // take interest first from the incoming amount
        uint256 payInterest = amount < interestOwed ? amount : interestOwed;
        uint256 leftover    = amount - payInterest;

        if (interestForPeriod > 0 || ln.interestAccrued > 0) {
            // bump tracked totals
            ln.interestAccrued = uint128(totalAccrued);
        }
        if (payInterest > 0) {
            ln.interestPaid = uint128(uint256(ln.interestPaid) + payInterest);
        }

        // update accrual anchor
        ln.lastAccrualTs = uint40(block.timestamp);

        // ------------------------------------------------------------------
        // 2) Principal repayment (clamped to outstanding)
        // ------------------------------------------------------------------

        uint256 payPrincipal = leftover > principalOutstanding
            ? principalOutstanding
            : leftover;

        if (payInterest > 0) {
            _distributeInterest(unionAddr, ln.loanType, payInterest, ln.rateBP);
        }

        uint256 principalForUtil = payPrincipal; // keep copy for utilization+ledgers

        if (payPrincipal > 0) {
            // refill JUNIOR cash up to remaining junior-funded amount
            uint256 remJ = uint256(ln.fundedFromJunior);
            if (remJ > 0) {
                uint256 toJ = payPrincipal <= remJ ? payPrincipal : remJ;
                ln.fundedFromJunior = uint128(remJ - toJ);
                junior[unionAddr][ln.loanType].cash += toJ;
                payPrincipal -= toJ;
            }

            // refill SENIOR cash up to remaining senior-funded amount
            if (payPrincipal > 0) {
                uint256 remS = uint256(ln.fundedFromSenior);
                uint256 toS  = payPrincipal <= remS ? payPrincipal : remS;
                ln.fundedFromSenior = uint128(remS - toS);
                senior[unionAddr].cash += toS;
                payPrincipal -= toS;
            }

            // any rounding dust → senior cash
            if (payPrincipal > 0) {
                senior[unionAddr].cash += payPrincipal;
                payPrincipal = 0;
            }

            // utilization and borrow counters shrink by the principal portion
            uint256 ub = unionBorrowsAgg[unionAddr];
            unionBorrowsAgg[unionAddr] = principalForUtil >= ub ? 0 : (ub - principalForUtil);

            JuniorMarket storage jm = junior[unionAddr][ln.loanType];
            uint256 tb = jm.totalBorrows;
            jm.totalBorrows = principalForUtil >= tb ? 0 : (tb - principalForUtil);

            // book the principal as repaid
            ln.principalPaid = uint128(uint256(ln.principalPaid) + principalForUtil);

        }

        // ------------------------------------------------------------------
        // 3) Close loan if principal ~zero (dust allowed)
        // ------------------------------------------------------------------
        uint256 remainingPrincipal =
            uint256(ln.principal) > uint256(ln.principalPaid)
                ? (uint256(ln.principal) - uint256(ln.principalPaid))
                : 0;
        
        uint256 unpaidInterest = totalAccrued > uint256(ln.interestPaid)
                ? (totalAccrued - uint256(ln.interestPaid))
                : 0;
        
        uint256 outstandingDust = remainingPrincipal + unpaidInterest;
        fullyRepaid = outstandingDust <= 1e17; // DUST = 0.1 nIN

        if (fullyRepaid) {
            IViewer(viewer).onLoanClosed(unionAddr, loanId, ln.borrower);
            ln.principalPaid = uint128(ln.principal);
            ln.liquidated = true;
            _adjustBucketThreshold(unionAddr, ln.loanType, false);
            emit LoanRepaid(unionAddr, loanId, payInterest, principalForUtil);
        }
    }


    function markDefault(address unionAddr, bytes32 loanId) external onlyOracleOrLeader(unionAddr) {
        ICore.Loan storage ln = loans[unionAddr][loanId];
        if (ln.createTs == 0) revert LoanNotExist();
        if (ln.defaulted || ln.liquidated) revert LoanClosed();
        JuniorMarket storage jm = junior[unionAddr][ln.loanType];

        uint256 principalRemaining = ln.principal > ln.principalPaid
            ? uint256(ln.principal) - uint256(ln.principalPaid)
            : 0;

        if (principalRemaining > 0) {
            uint256 ub = unionBorrowsAgg[unionAddr];
            unionBorrowsAgg[unionAddr] = principalRemaining >= ub ? 0 : (ub - principalRemaining);

            uint256 tb = jm.totalBorrows;
            jm.totalBorrows = principalRemaining >= tb ? 0 : (tb - principalRemaining);
        }

        (uint256 juniorApplied, uint256 newIdxJ) = GenericFundMathLib.applyLoss(jm.index, jm.totalShares, principalRemaining);
        jm.index = newIdxJ;

        uint256 remaining = principalRemaining > juniorApplied ? (principalRemaining - juniorApplied) : 0;

        uint256 seniorApplied = 0;
        if (remaining > 0) {
            SeniorMarket storage __sm = senior[unionAddr];
            (seniorApplied, __sm.index) = GenericFundMathLib.applyLoss(__sm.index, __sm.totalShares, remaining);
        }

        ln.defaulted  = true;
        ln.liquidated = true;

        _adjustBucketThreshold(unionAddr, ln.loanType, true);
        emit LoanDefaulted(unionAddr, loanId, juniorApplied, seniorApplied);
    }

    // ---------- Viewer write-back primitives ----------

    /// @notice Called by the Viewer to persist maturity / milestone fields on a loan.
    ///         Gated to the contract owner (= Viewer, set at init time).
    function writeLoanMeta(
        address unionAddr,
        bytes32 loanId,
        uint40  maturityTs,
        uint8   milestone
    ) external onlyOwner {
        ICore.Loan storage ln = loans[unionAddr][loanId];
        if (ln.createTs == 0) revert LoanNotExist();
        if (maturityTs != 0) ln.maturityTs = maturityTs;
        ln.milestone = milestone;
    }

    /// @notice Called by the Viewer to credit a recovery amount back into a junior pool.
    function addJuniorCash(
        address unionAddr,
        bytes32 loanType,
        uint256 amount
    ) external onlyOwner {
        if (amount == 0) revert AmountZero();
        junior[unionAddr][loanType].cash += amount;
    }

    ////////////////////////////////////////////////////////////
    ///////////////  --- GETTERS BY VIEWER --- /////////////////

    function getSeniorMarket(address unionAddr) external view returns (ICore.MarketLite memory m) {
        SeniorMarket storage s = senior[unionAddr];
        m = ICore.MarketLite({
            cash: s.cash,
            index: GenericFundMathLib.normalizeIndex(s.index),
            totalShares: s.totalShares,
            totalBorrows: s.totalBorrows,
            claimablePrincipal: s.claimablePrincipal
        });
    }

    function getJuniorMarket(address unionAddr, bytes32 loanType) external view returns (ICore.MarketLite memory m) {
        JuniorMarket storage j = junior[unionAddr][loanType];
        m = ICore.MarketLite({
            cash: j.cash,
            index: GenericFundMathLib.normalizeIndex(j.index),
            totalShares: j.totalShares,
            totalBorrows: j.totalBorrows,
            claimablePrincipal: j.claimablePrincipal
        });
    }

    ////////////////////////////////////////////////////////////
    ///////////////  --- GETTERS PUBLIC --- //////////////////// 

    function getInvestorSenior(address unionAddr, address investor)
        external
        view
        returns (ICore.InvestorLite memory out)
        {
        Investor storage inv = seniorInv[unionAddr][investor];
        out = ICore.InvestorLite({
            unbondPeriod:         inv.requestTs,
            shares:               inv.shares,
            locked:               inv.pending + inv.claimable,
            pending:              inv.pending,
            pendingPrincipalSnap: inv.pendingPrincipalSnap,
            entryIndex:           inv.entryIndex
        });
    }

    function getInvestorJunior(address unionAddr, bytes32 loanType, address investor)
        external
        view
        returns (ICore.InvestorLite memory out)
        {
        Investor storage inv = juniorInv[unionAddr][loanType][investor];
        out = ICore.InvestorLite({
            unbondPeriod:         inv.requestTs,
            shares:               inv.shares,
            locked:               inv.pending + inv.claimable,
            pending:              inv.pending,
            pendingPrincipalSnap: inv.pendingPrincipalSnap,
            entryIndex:           inv.entryIndex
        });
    }

    function reportMilestone(address unionAddr, bytes32 loanId, uint16 milestone, bytes32 milestoneDigest)
        external onlyOracleOrLeader(unionAddr)
        {
        ICore.Loan storage ln = loans[unionAddr][loanId];
        ln.milestone = milestone;
        ln.digestTs = uint40(block.timestamp);
        ln.milestoneDigest = milestoneDigest;

        emit MilestoneReported(unionAddr, loanId, milestone, milestoneDigest);
    }

    ////////////////////////////////////////////////////////////
    ///////////////  --- LOAN REMOVAL --- //////////////////////

    event LoanRemoved(address indexed unionAddr, bytes32 indexed loanId, address borrower);

    /// @notice Hard-delete a loan that was created but never drawn down.
    /// @dev    Callable by the borrower, oracle, union leader, or owner.
    ///         Restricted to loans where no funds left the contract (drawdownTs == 0).
    ///         Fully unwinds market accounting: restores cash and borrow counters.
    function removeLoan(address unionAddr, bytes32 loanId)
        external
    {
        ICore.Loan storage ln = loans[unionAddr][loanId];
        if (ln.borrower == address(0)) revert LoanNotExist();

        bool isBorrower   = msg.sender == ln.borrower;
        bool isPrivileged = owner() == msg.sender
            || (address(roles) != address(0) && (roles.isOracle(msg.sender) || roles.isLeader(unionAddr, msg.sender)));
        if (!isBorrower && !isPrivileged) revert NotOracleOrLeader();

        // Only safe to cancel before funds leave the contract
        if (ln.drawdownTs != 0 || ln.defaulted || ln.liquidated) revert BadState();

        // Unwind market accounting — restore cash and shrink borrow counters
        uint256 principal = uint256(ln.principal);
        uint256 fromJunior = uint256(ln.fundedFromJunior);
        uint256 fromSenior = uint256(ln.fundedFromSenior);
        bytes32 loanType   = ln.loanType;

        if (fromJunior > 0) junior[unionAddr][loanType].cash += fromJunior;
        if (fromSenior > 0) senior[unionAddr].cash += fromSenior;

        uint256 ub = unionBorrowsAgg[unionAddr];
        unionBorrowsAgg[unionAddr] = principal >= ub ? 0 : ub - principal;

        uint256 tb = junior[unionAddr][loanType].totalBorrows;
        junior[unionAddr][loanType].totalBorrows = principal >= tb ? 0 : tb - principal;

        address borrower = ln.borrower;
        delete loans[unionAddr][loanId];

        if (viewer != address(0)) {
            IViewer(viewer).onLoanClosed(unionAddr, loanId, borrower);
        }

        emit LoanRemoved(unionAddr, loanId, borrower);
    }
}

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
 * - Interest-only claim (claimYield) with buffer-aware headroom.
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

interface INilaNIN is IERC20 {}

interface INilaFxPool {
    function quoteRedeem(uint256 ninAmount) external view
      returns (uint256, uint256, uint256, uint256, uint256, uint256, bool);
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
    function resolveEscrowCash(uint256 escrowId, uint256 amount) external;
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
        uint256 unclaimed;              // interest bucket (token units)
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
    INilaFxPool public fxPool;

    // ---------- Constants ----------
    uint256 public constant YEAR               = 365 days;
    uint256 public constant HUNDRED_PERCENT_BP = 10_000;
    uint256 public constant DEFAULT_UNBONDING  = 14 days;
    uint256 public constant CARRYOVER_WINDOW   = 3 days; // tolerance for unpaid interest on transfer
    uint256 public constant WAD                = 1e18;

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
        uint256 unclaimed;   // token units (interest only)
        // FIFO snapshot for maturity-aware promotion (junior only)
        uint256 pendingPrincipalSnap;
    }
    mapping(address => mapping(address => Investor)) internal seniorInv; // union => investor => inv
    mapping(address => mapping(bytes32 => mapping(address => Investor))) internal juniorInv; // union => loanType => investor => inv

    // ---------- Loans ----------
    mapping(address => mapping(bytes32 => ICore.Loan)) public loans; // union => loanId => loan

    // ---------- Module accounting (1155) ----------
    // uncomment on ERC1155 virtual liquidity: mapping(address => uint256) public foodTokenLiquidity; // union => net cash in ERC1155 tokens

    // ---------- Maturity ledger (per union) ----------
    mapping(address => mapping(uint40 => uint256)) internal scheduledPrincipalByDate; // union => date => amount
    mapping(address => uint256) public maturedCreditByUnion;    // union => matured principal credited
    mapping(address => uint256) public maturedConsumedByUnion;  // union => consumed by promotions
    mapping(address => mapping(bytes32 => uint256)) internal loanScheduledPrincipal; // union => loanId => remaining scheduled

    // ---------- New storage (append-only) ----------
    mapping(address => mapping(bytes32 => uint256)) public bucketMaxAmount;
    mapping(address => uint256) public unionRainyDay;
    uint16 public treasuryFeeBP; // basis points, defaults 1%
    uint16 public rainyFeeBP;    // basis points, defaults 2%

    // ---------- CS003 storage (append-only) ----------
    address public fxPoolAddr;                       // NilaFxPool — authorized to call burnEscrowNin
    mapping(address => uint256) public nonces;       // per-borrower nonce for voucher replay protection

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
    error InterestNotSettled();
    error MaturityAlreadySet();
    error BadMaturity();
    error DateInFuture();
    error NotDefaulted();
    error NoYield();
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
    event YieldClaimed(address indexed investor, ICore.Tranche tranche, address indexed unionAddr, bytes32 loanType, uint256 amount);

    event LoanClaimed(address indexed unionAddr, bytes32 indexed loanId, address borrower, bytes32 loanType, uint256 amount, uint16 rateBP, uint40 sosDate, uint40 drawdownTs, bool fastDraw);
    event LoanAccepted(address indexed unionAddr, bytes32 indexed loanId, uint256 amount, address borrower);
    event LoanRepaid(address indexed unionAddr, bytes32 indexed loanId, uint256 interestPaid, uint256 principalPaid);
    event LoanDefaulted(address indexed unionAddr, bytes32 indexed loanId, uint256 juniorApplied, uint256 seniorApplied);
    event RecoveryCredited(address indexed unionAddr, bytes32 indexed loanId, uint256 recovered);
    event MaturityReported(address indexed unionAddr, bytes32 indexed loanId, uint40 maturityTs);
    event MilestoneReported(address indexed unionAddr, bytes32 indexed loanId, uint16 milestone, bytes32 milestoneDigest);
    event MaturitiesCredited(address indexed unionAddr, uint40 date, uint256 amount);

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

    // ---------- Admin ----------
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    // ---------- Setters ----------
    function setViewer(address v) external onlyOwner { viewer = v; }
    function setRoles(address v) external onlyOwner { roles = IRoles(v); }
    function setLandTitle(address v) external onlyOwner { landNFT = v; }

    function setReserveConfigForUnion(address unionAddr, uint32 safetyBP, uint224 safetyFloor, bool hardStop, uint32 escrowDuration)
        external onlyOracleOrLeader(unionAddr)
        {
        reserveCfgByUnion[unionAddr] = ReserveCfg({
            safetyBP: safetyBP,
            safetyFloor: safetyFloor,
            hardStop: hardStop,
            exists: true,
            escrowDuration: escrowDuration
        });
        emit UnionReserveUpdated(unionAddr, safetyBP, safetyFloor, hardStop);
    }

    function setFxPoolAddr(address _fxPool) external onlyOwner {
        fxPoolAddr = _fxPool;
    }

    function setNin(address _nin) external onlyOwner {
        require(_nin != address(0), "zero address");
        nin = INilaNIN(_nin);
    }

    /// @notice Credit nIN cash to a junior market on behalf of a cash-scan escrow.
    /// @dev Called by FxPool immediately after minting nIN to this contract (cashScanMint).
    ///      Registers the cash in the market so it is visible as loanable liquidity.
    ///      No shares are minted — escrow nIN has no investor owner.
    function creditEscrowNin(address unionAddr, bytes32 loanType, uint256 amount) external {
        require(msg.sender == fxPoolAddr, "only FxPool");
        require(amount > 0, "zero amount");
        _ensureJuniorMarket(unionAddr, loanType);
        junior[unionAddr][loanType].cash += amount;
    }

    /// @notice Burn nIN held in this contract. Callable ONLY by FxPool for expired escrow cleanup.
    /// @dev Debits the junior market cash that was credited at scan time, then sends nIN to FxPool for burning.
    function burnEscrowNin(address unionAddr, bytes32 loanType, uint256 amount) external {
        require(msg.sender == fxPoolAddr, "only FxPool");
        require(amount > 0, "zero amount");
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

    function withdrawUnionTreasury(address unionAddr, uint256 amount, bool fromRainy) external nonReentrant onlyLeader(unionAddr) {
        if (amount == 0) revert AmountZero();
        if (fromRainy) {
            uint256 rainy = unionRainyDay[unionAddr];
            if (amount > rainy) revert InsufficientCash();
            unionRainyDay[unionAddr] = rainy - amount;
        } else {
            uint256 bal = unionTreasury[unionAddr];
            if (amount > bal) revert InsufficientCash();
            unionTreasury[unionAddr] = bal - amount;
        }
        nin.transfer(msg.sender, amount);
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

    function _verifyBucketRatio(
        address unionAddr,
        bytes32 loanType
        ) internal view {
        uint256 threshold = bucketTresholds[unionAddr][loanType];
        if (threshold == 0) return; // ratio check disabled for this market

        JuniorMarket storage jm = junior[unionAddr][loanType];
        SeniorMarket storage sm = senior[unionAddr];

        uint256 jrIndex = jm.index == 0 ? GenericFundMathLib.RAY : jm.index;
        uint256 srIndex = sm.index == 0 ? GenericFundMathLib.RAY : sm.index;

        uint256 totalJ = jm.totalShares == 0 ? 0 : GenericFundMathLib.toUnderlying(jm.totalShares, jrIndex);
        uint256 totalS = sm.totalShares == 0 ? 0 : GenericFundMathLib.toUnderlying(sm.totalShares, srIndex);

        // if no senior, ratio is either 0/0 (ignore) or +inf (passes)
        if (totalS == 0) return;

        uint256 ratio = Math.mulDiv(totalJ, WAD, totalS); // junior / senior in WAD (pre-funding)
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
        uint256 idx = (currentIndex == 0) ? GenericFundMathLib.RAY : currentIndex;

        uint256 prev = inv.entryIndex;
        if (prev == 0) { 
            inv.entryIndex = idx; 
            return; 
        }

        if (idx > prev && inv.shares > 0) {
            // same math as before, just centralized
            unchecked {
                uint256 delta = idx - prev;
                inv.unclaimed += (inv.shares * delta) / GenericFundMathLib.RAY;
            }
        }

        inv.entryIndex = idx;
    }

    function _applyLoss(
        uint256 supplyIndex,
        uint256 totalShares,
        uint256 loss
        ) internal pure returns (uint256 applied, uint256 newIndex) {
        if (loss == 0 || supplyIndex == 0 || totalShares == 0) return (0, supplyIndex);
        uint256 underlying = GenericFundMathLib.toUnderlying(totalShares, supplyIndex);
        if (underlying == 0) return (0, supplyIndex);
        (applied, newIndex) = GenericFundMathLib.haircutIndex(supplyIndex, underlying, loss);
    }

    function _distributeInterest(
        address unionAddr,
        bytes32 loanType,
        uint256 interest,
        uint256 fundedFromJunior,
        uint256 fundedFromSenior,
        bool skipFees
        ) internal {
        // 1% fee to treasury unless skipping for lower-rate loans
        uint256 fee = skipFees ? 0 : (interest * treasuryFeeBP) / HUNDRED_PERCENT_BP;
        if (fee > 0) {
            unionTreasury[unionAddr] += fee; // fee accrued within contract.
        }

        uint256 rainy = (skipFees || rainyFeeBP == 0) ? 0 : (interest * rainyFeeBP) / HUNDRED_PERCENT_BP;
        if (rainy > 0) {
            unionRainyDay[unionAddr] += rainy;
        }

        uint256 net = interest - fee - rainy;

        JuniorMarket storage jm = junior[unionAddr][loanType];
        SeniorMarket storage sm = senior[unionAddr];

        uint256 totalFunded = fundedFromJunior + fundedFromSenior;
        uint256 toJunior;
        uint256 toSenior;
        if (totalFunded == 0) {
            // fall back to 50/50 if we somehow have no funded balance context
            toJunior = net / 2;
            toSenior = net - toJunior;
        } else {
            toJunior = Math.mulDiv(net, fundedFromJunior, totalFunded);
            toSenior = net - toJunior; // remainder to avoid dust loss
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
        // Select investor + market
        Investor storage inv = isJunior
            ? juniorInv[unionAddr][loanType][investor]
            : seniorInv[unionAddr][investor];

        if (inv.claimable == 0) revert NothingToClaim();

        // Determine shares to burn
        uint256 burnShares = (maxShares == 0 || maxShares > inv.claimable) ? inv.claimable : maxShares;

        if (isJunior) {
            JuniorMarket storage m = junior[unionAddr][loanType];
            uint256 amount = GenericFundMathLib.toUnderlying(burnShares, m.index);

            // Reserve/headroom
            (ReserveCfg memory cfg, uint256 req) = _requiredReserveFor(unionAddr);
            uint256 idle = m.cash + senior[unionAddr].cash; // (add 1155 virtual liquidity here if enabled)
            if (cfg.hardStop && idle < amount + req) revert ReserveStop();
            if (m.cash < amount) revert InsufficientCash();

            // Burn & move cash
            inv.claimable -= burnShares;
            inv.shares    -= burnShares;
            m.totalShares -= burnShares;
            m.cash        -= amount;

            // Release reserved principal (market + union)
            uint256 release = amount;
            if (release > m.claimablePrincipal) release = m.claimablePrincipal;
            m.claimablePrincipal -= release;
            _bumpUnionClaimable(unionAddr, -int256(release));

            // Transfer & event
            nin.transfer(investor, amount);
            emit Claimed(investor, ICore.Tranche.JUNIOR, unionAddr, loanType, amount);
        } else {
            SeniorMarket storage m = senior[unionAddr];
            uint256 amount = GenericFundMathLib.toUnderlying(burnShares, m.index);

            // Reserve/headroom
            (ReserveCfg memory cfg, uint256 req) = _requiredReserveFor(unionAddr);
            uint256 idle = m.cash; // (add 1155 virtual liquidity here if enabled)
            if (cfg.hardStop && idle < amount + req) revert ReserveStop();
            if (m.cash < amount) revert InsufficientCash();

            // Burn & move cash
            inv.claimable -= burnShares;
            inv.shares    -= burnShares;
            m.totalShares -= burnShares;
            m.cash        -= amount;

            // Release reserved principal (market + union)
            uint256 release = amount;
            if (release > m.claimablePrincipal) release = m.claimablePrincipal;
            m.claimablePrincipal -= release;
            _bumpUnionClaimable(unionAddr, -int256(release));

            // Transfer & event
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

        uint256 pps = m.index == 0 ? GenericFundMathLib.RAY : m.index;
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
        senior[unionAddr].claimablePrincipal += amountSnap;
        _bumpUnionClaimable(unionAddr, int256(amountSnap));

        emit UnbondRequested(msg.sender, ICore.Tranche.SENIOR, unionAddr, bytes32(0), shares, amountSnap);
    }

    function claimSenior(address unionAddr, uint256 maxShares) external nonReentrant {
        _settleYield(seniorInv[unionAddr][msg.sender], senior[unionAddr].index);

        Investor storage inv = seniorInv[unionAddr][msg.sender];

        // auto-promote if min window elapsed
        if (inv.claimable == 0 && inv.pending > 0 && block.timestamp >= inv.requestTs + DEFAULT_UNBONDING) {
            uint256 sharesAuto = inv.pending;
            inv.pending = 0;
            inv.claimable += sharesAuto;
            emit UnbondPromoted(msg.sender, ICore.Tranche.SENIOR, unionAddr, bytes32(0), sharesAuto, 0);
        }

        if (inv.claimable == 0) revert NothingToClaim();

        _redeemClaimable(false, unionAddr, bytes32(0), msg.sender, maxShares);
    }

    // ---------- Junior (ERC20) ----------
    function depositJunior(address unionAddr, bytes32 loanType, uint256 amount) external whenNotPaused nonReentrant {
        if (amount == 0) revert AmountZero();

        // TODO(next update): remove NFT restriction, everybody should be able to use the junior pool.
        _requireHoldsNFT(msg.sender);
        _ensureJuniorMarket(unionAddr, loanType);
        _settleYield(juniorInv[unionAddr][loanType][msg.sender], junior[unionAddr][loanType].index);

        nin.transferFrom(msg.sender, address(this), amount);

        JuniorMarket storage m = junior[unionAddr][loanType];
        m.cash += amount;

        uint256 pps = m.index;
        uint256 shares = (amount * GenericFundMathLib.RAY) / pps;
        m.totalShares += shares;

        Investor storage inv = juniorInv[unionAddr][loanType][msg.sender];
        inv.shares += shares;

        emit Deposit(msg.sender, ICore.Tranche.JUNIOR, unionAddr, loanType, amount, shares);
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
        _bumpUnionClaimable(unionAddr, int256(amountSnap));

        emit UnbondRequested(msg.sender, ICore.Tranche.JUNIOR, unionAddr, loanType, shares, amountSnap);
    }

    function claimJunior(address unionAddr, bytes32 loanType, uint256 maxShares) external nonReentrant {
        _ensureJuniorMarket(unionAddr, loanType);
        Investor storage inv = juniorInv[unionAddr][loanType][msg.sender];

        // ── Eligibility: later-of(min window, (maturity coverage OR idle-cash coverage)) ──
        if (inv.claimable == 0 && inv.pending > 0) {
            bool pastMin = block.timestamp >= inv.requestTs + DEFAULT_UNBONDING;

            // maturity coverage budget
            uint256 availableBudget = maturedCreditByUnion[unionAddr] - maturedConsumedByUnion[unionAddr];
            bool coveredByMaturities = (inv.pendingPrincipalSnap > 0 && availableBudget >= inv.pendingPrincipalSnap);

            // idle-cash coverage (post-buffer headroom)
            (ReserveCfg memory cfg,) = _requiredReserveFor(unionAddr);
            uint256 claimable = unionClaimable[unionAddr];
            uint256 claimableAfter = claimable > inv.pendingPrincipalSnap
                ? (claimable - inv.pendingPrincipalSnap)
                : 0;

            uint256 bumpAfter = (uint256(cfg.safetyBP) * claimableAfter) / 10_000;
            uint256 reqAfter  = claimableAfter + bumpAfter + uint256(cfg.safetyFloor);

            uint256 idle = junior[unionAddr][loanType].cash + senior[unionAddr].cash;
            bool coveredByIdle = idle >= (inv.pendingPrincipalSnap + reqAfter);

            if (!(pastMin && (coveredByMaturities || coveredByIdle))) revert NotEligibleMaturity();
            
            // adds investor earned into the personal unclaimed bucket (no actual transfer)
            _settleYield(juniorInv[unionAddr][loanType][msg.sender], junior[unionAddr][loanType].index);

            // promote pending -> claimable
            uint256 toPromote = inv.pending;
            inv.pending = 0;
            inv.claimable += toPromote;

            // consume maturity budget only if we actually used it
            if (coveredByMaturities) {
                maturedConsumedByUnion[unionAddr] += inv.pendingPrincipalSnap;
            }
            inv.pendingPrincipalSnap = 0;

            emit UnbondPromoted(msg.sender, ICore.Tranche.JUNIOR, unionAddr, loanType, toPromote, 0);
        }
        if (inv.claimable == 0) revert NothingToClaim();

        _redeemClaimable(true, unionAddr, loanType, msg.sender, maxShares);
    }

    // ---------- Instant interest claim ----------
    function claimYield(
        ICore.Tranche tranche,
        address unionAddr,
        bytes32 loanType,
        uint256 maxAmount
        ) external nonReentrant whenNotPaused {
        ReserveCfg memory cfg;
        uint256 req;
        uint256 idle;
        uint256 available;
        uint256 payout;

        if (tranche == ICore.Tranche.SENIOR) {
            _ensureSeniorMarket(unionAddr);
            _settleYield(seniorInv[unionAddr][msg.sender], senior[unionAddr].index);

            Investor storage inv = seniorInv[unionAddr][msg.sender];
            available = inv.unclaimed;
            if (available == 0) revert NoYield();

            (cfg, req) = _requiredReserveFor(unionAddr);
            idle = senior[unionAddr].cash; // uncomment on ERC1155 virtual liquidity: + foodTokenLiquidity[unionAddr];

            payout = (maxAmount == 0 || maxAmount > available) ? available : maxAmount;
            uint256 headroom = idle > req ? (idle - req) : 0;
            if (cfg.hardStop) {
                if (idle < req + payout) revert ReserveStop();
            } else if (payout > headroom) {
                payout = headroom;
            }
            if (payout == 0 || payout > senior[unionAddr].cash) revert InsufficientCash();

            inv.unclaimed -= payout;
            senior[unionAddr].cash -= payout;
            nin.transfer(msg.sender, payout);
            emit YieldClaimed(msg.sender, ICore.Tranche.SENIOR, unionAddr, bytes32(0), payout);
        } else {
            _ensureJuniorMarket(unionAddr, loanType);
            _settleYield(juniorInv[unionAddr][loanType][msg.sender], junior[unionAddr][loanType].index);

            Investor storage invJ = juniorInv[unionAddr][loanType][msg.sender];
            available = invJ.unclaimed;
            if (available == 0) revert NoYield();

            (cfg, req) = _requiredReserveFor(unionAddr);
            idle = junior[unionAddr][loanType].cash + senior[unionAddr].cash; // uncomment on ERC1155 virtual liquidity: + foodTokenLiquidity[unionAddr];

            payout = (maxAmount == 0 || maxAmount > available) ? available : maxAmount;
            uint256 headroom = idle > req ? (idle - req) : 0;
            if (cfg.hardStop) {
                if (idle < req + payout) revert ReserveStop();
            } else if (payout > headroom) {
                payout = headroom;
            }
            if (payout == 0 || payout > junior[unionAddr][loanType].cash) revert InsufficientCash();

            invJ.unclaimed -= payout;
            junior[unionAddr][loanType].cash -= payout;
            nin.transfer(msg.sender, payout);
            emit YieldClaimed(msg.sender, ICore.Tranche.JUNIOR, unionAddr, loanType, payout);
        }
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
        uint256 nonce            // per-borrower nonce for replay protection
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

        // 5) buffer check & take cash (junior→senior waterfall)
        _checkReserveBeforeFundingFor(unionAddr, loanType, amount);

        JuniorMarket storage jm = junior[unionAddr][loanType];
        SeniorMarket storage sm = senior[unionAddr];

        uint256 takeJunior = amount <= jm.cash ? amount : jm.cash;
        uint256 takeSenior = amount - takeJunior;

        // basic safety
        if (takeSenior > sm.cash) revert InsufficientCash();

        // ratio check on *post*-funding balances
        _verifyBucketRatio(unionAddr, loanType);
        // COMMENT: make sure in front-end, that if BadRatio is emitted, this means more junior liquidity is needed. 

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
        ln.lowerRate        = rateBP >= minRateBP;
        ln.sosDate          = sosDate;

        // set funded to use principal in reserve calculation
        ln.fundedFromJunior = uint128(takeJunior);
        ln.fundedFromSenior = uint128(takeSenior);

        unionBorrowsAgg[unionAddr] = borrows + amount;
        junior[unionAddr][loanType].totalBorrows += amount;
        IViewer(viewer).onLoanCreated(unionAddr, loanId, msg.sender);

        if (rateBP >= minRateBP && fastDraw) { // oracle can set bool to false to force union manual acceptance
            ln.drawdownTs = createTs;
            ln.lastAccrualTs = createTs;
            nin.transfer(msg.sender, amount);
            // resolve cash-scan escrow now that nIN has been physically disbursed
            if (escrowId != 0 && fxPoolAddr != address(0)) {
                IFxPool(fxPoolAddr).resolveEscrowCash(escrowId, amount);
            }
        }

        emit LoanClaimed(unionAddr, loanId, msg.sender, loanType, amount, rateBP, sosDate, ln.drawdownTs, fastDraw);
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
        // partially (or fully) resolve cash-scan escrow by the loan amount disbursed
        if (escrowId != 0 && fxPoolAddr != address(0)) {
            IFxPool(fxPoolAddr).resolveEscrowCash(escrowId, uint256(amount));
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
            _distributeInterest(
                unionAddr,
                ln.loanType,
                payInterest,
                uint256(ln.fundedFromJunior),
                uint256(ln.fundedFromSenior),
                ln.lowerRate
            );
        }

        // update accrual anchor
        ln.lastAccrualTs = uint40(block.timestamp);

        // ------------------------------------------------------------------
        // 2) Principal repayment (clamped to outstanding)
        // ------------------------------------------------------------------

        uint256 payPrincipal = leftover > principalOutstanding
            ? principalOutstanding
            : leftover;

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

            // early repayment trims the scheduled-maturity bucket
            if (ln.maturityTs != 0 && block.timestamp < uint256(ln.maturityTs)) {
                uint256 sched = loanScheduledPrincipal[unionAddr][loanId];
                if (sched > 0) {
                    uint256 cut = principalForUtil <= sched ? principalForUtil : sched;
                    loanScheduledPrincipal[unionAddr][loanId] = sched - cut;
                    scheduledPrincipalByDate[unionAddr][ln.maturityTs] -= cut;
                }
            }
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

        (uint256 juniorApplied, uint256 newIdxJ) = _applyLoss(jm.index, jm.totalShares, principalRemaining);
        jm.index = newIdxJ;

        uint256 remaining = principalRemaining > juniorApplied ? (principalRemaining - juniorApplied) : 0;

        uint256 seniorApplied = 0;
        if (remaining > 0) {
            SeniorMarket storage __sm = senior[unionAddr];
            (seniorApplied, __sm.index) = _applyLoss(__sm.index, __sm.totalShares, remaining);
        }

        ln.defaulted  = true;
        ln.liquidated = true;

        if (ln.maturityTs != 0) {
            uint256 sched = loanScheduledPrincipal[unionAddr][loanId];
            if (sched > 0) {
                loanScheduledPrincipal[unionAddr][loanId] = 0;
                scheduledPrincipalByDate[unionAddr][ln.maturityTs] -= sched;
            }
        }

        emit LoanDefaulted(unionAddr, loanId, juniorApplied, seniorApplied);
    }

    // ---------- Maturity tracking ----------
    function reportMaturity(address unionAddr, bytes32 loanId, uint40 maturityTs)
        external onlyOracleOrLeader(unionAddr)
        {
        ICore.Loan storage ln = loans[unionAddr][loanId];
        if (ln.createTs == 0) revert LoanNotExist();
        if (ln.maturityTs != 0) revert MaturityAlreadySet();
        if (maturityTs < ln.createTs) revert BadMaturity();

        ln.maturityTs = maturityTs;
        ln.milestone = 10;

        uint256 remaining = uint256(ln.principal) > uint256(ln.principalPaid)
            ? uint256(ln.principal) - uint256(ln.principalPaid)
            : 0;
        if (remaining > 0) {
            scheduledPrincipalByDate[unionAddr][maturityTs] += remaining;
            loanScheduledPrincipal[unionAddr][loanId] = remaining;
        }

        emit MaturityReported(unionAddr, loanId, maturityTs);
    }

    function creditMaturedRepayments(address unionAddr, uint40[] calldata dates)
        external onlyOracleOrLeader(unionAddr)
        {
        for (uint256 i = 0; i < dates.length; i++) {
            uint40 d = dates[i];
            if (d > block.timestamp) revert DateInFuture();
            uint256 amt = scheduledPrincipalByDate[unionAddr][d];
            if (amt == 0) continue;
            scheduledPrincipalByDate[unionAddr][d] = 0;
            maturedCreditByUnion[unionAddr] += amt;
            emit MaturitiesCredited(unionAddr, d, amt);
        }
    }

    function creditRecovery(address unionAddr, bytes32 loanId, uint256 recovered)
        external onlyOracleOrLeader(unionAddr)
        {   
        if (recovered == 0) revert AmountZero();
        ICore.Loan storage ln = loans[unionAddr][loanId];
        if (ln.createTs == 0) revert LoanNotExist();
        if (!ln.defaulted) revert NotDefaulted();

        junior[unionAddr][ln.loanType].cash += recovered;
        emit RecoveryCredited(unionAddr, loanId, recovered);
    }

    ////////////////////////////////////////////////////////////
    ///////////////  --- GETTERS BY VIEWER --- /////////////////

    function getSeniorMarket(address unionAddr) external view returns (ICore.MarketLite memory m) {
        SeniorMarket storage s = senior[unionAddr];
        m = ICore.MarketLite({
            cash: s.cash,
            index: s.index == 0 ? GenericFundMathLib.RAY : s.index,
            totalShares: s.totalShares,
            totalBorrows: s.totalBorrows,
            claimablePrincipal: s.claimablePrincipal
        });
    }

    function getJuniorMarket(address unionAddr, bytes32 loanType) external view returns (ICore.MarketLite memory m) {
        JuniorMarket storage j = junior[unionAddr][loanType];
        m = ICore.MarketLite({
            cash: j.cash,
            index: j.index == 0 ? GenericFundMathLib.RAY : j.index,
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
            unclaimed:            inv.unclaimed,
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
            unclaimed:            inv.unclaimed,
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
}

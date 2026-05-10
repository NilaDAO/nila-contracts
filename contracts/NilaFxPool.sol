// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

interface INilaNIN {
    function mint(address to, uint256 amount) external;
    function burn(address from, uint256 amount) external;
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function permit(address owner, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s) external;
}

interface IRolesRegistry {
    function isLeader(address unionAddr, address acct) external view returns (bool);
}

interface IGenericFundCore {
    function creditEscrowNin(address unionAddr, bytes32 loanType, uint256 amount, address member) external;
    function burnEscrowNin(address unionAddr, bytes32 loanType, uint256 amount) external;
    function getUnionEscrowDuration(address unionAddr) external view returns (uint32);
    function repayLoan(address unionAddr, bytes32 loanId, uint256 amount) external returns (bool fullyRepaid);
    function unionTreasury(address unionAddr) external view returns (uint256);
    function burnTreasuryForExpiry(address unionAddr, uint256 amount) external returns (uint256 burned);
    function isLeaderOf(address unionAddr, address addr) external view returns (bool);
    // --- Three-layer reactive views (auto-generated getters + view functions on Core) ---
    function seniorPendingPrincipal(address unionAddr) external view returns (uint256);
    function juniorPendingPrincipal(address unionAddr, bytes32 loanType) external view returns (uint256);
}

enum ScanPurpose { INVEST, REPAY, DISBURSE }

// Minimal Chainlink Aggregator interface
interface AggregatorV3Interface {
    function decimals() external view returns (uint8);
    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );
}

/// @notice Upgradeable FX pool: USDT <-> nIN (synthetic INR)
/// USDT assumed 6 decimals, nIN 18 decimals.
/// Oracle gives INR per USD (e.g. 83.5 * 1e8).
/// FX fees/compensation use a *global epoch* reference rate (lastFxRate).
contract NilaFxPool is
    Initializable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    // --- Roles ---
    // Single governance role (name kept from your version)
    bytes32 public constant ONLY_OWNER = keccak256("ONLY_ORACLE");
    bytes32 public constant UNION_ROLE = keccak256("UNION_ROLE");

    // --- Custom errors (saves bytecode vs long require strings) ---
    error MintVolatilityBlocked();
    error RedeemVolatilityBlocked();
    error OracleInvalid();
    error OracleStale();
    error OracleTooOld();
    error UsdtTransferFailed();
    error InsufficientUsdt();
    error EscrowNotActive();
    error EscrowIsExpired();
    error EscrowNotExpired();
    error ExceedsUnionReserve();
    error UsdtRoundsToZero();
    error DurationOutOfRange();
    error RedeemIsPaused();
    error LengthMismatch();
    error Unauthorized();
    error InvalidInput();

    // --- Tokens & oracle ---
    IERC20 public usdt;
    INilaNIN public nin;
    uint8 public usdtDecimals; // expected 6

    AggregatorV3Interface public inrUsdOracle;
    uint8 public oracleDecimals;

    // --- FX fee / guarantee pool accounting (USDT units, 6 decimals) ---
    // This is a *virtual bucket* inside this contract, not a separate address.
    uint256 public fxTreasuryUsdt;

    // --- Configurable params ---
    // threshold in basis points (200 = 2%)
    uint256 public fxThresholdBps;
    // max oracle age in seconds
    uint256 public maxOracleDelay;
    // global USDT out per day (6 decimals)
    uint256 public globalCapPerDay;

    // Epoch configuration (how often you conceptually "reset" FX reference)
    uint256 public epochDuration;        // in seconds, e.g. 90 days
    uint256 public lastFxRate;           // INR per USD at last epoch (oracleDecimals)
    uint256 public lastEpochTimestamp;   // when lastFxRate was set

    // --- TWAP state for INR/USD oracle ---
    uint256 public twapRate;        // time-weighted average INR per USD (oracleDecimals)
    uint256 public lastObsRate;     // last raw oracle rate we used
    uint64  public lastObsTimestamp;
    uint32  public twapWindow;      // desired TWAP window in seconds, e.g. 3600 = 1 hour
    uint256 public maxRawVsTwapDiffBps;   // e.g. 500 = 5%

    // Redeem pause flag (mint still allowed when true)
    bool public redeemPaused;

    // --- Rolling 24h limits (global) ---
    struct LimitInfo {
        uint64 windowStart; // timestamp
        uint192 amount;     // USDT out in this window (6 decimals)
    }

    LimitInfo public globalLimit;

    // --- Cash Scan Escrow ---
    struct CashEscrow {
        address union;      // which union scanned
        address fundAddr;   // GenericFundCore address where nIN was deposited
        uint256 ninAmount;  // nIN minted (18 decimals, = INR value * 1e18)
        uint256 inrValue;   // INR value recorded at scan (human units, e.g. 84000 for ₹84,000)
        uint256 mintRate;   // INR/USD rate at time of scan (oracleDecimals)
        uint64  deadline;   // block.timestamp + escrowDuration at scan time
        uint8   status;     // 0=Active, 1=ResolvedCash, 2=ResolvedUsdt, 3=Burned
        bytes32 scanHash;   // keccak256 of scan data (serials, image hash, etc.)
        bytes32 loanType;   // junior market the nIN was credited to (appended for upgrade safety)
    }

    uint256 public nextEscrowId;
    mapping(uint256 => CashEscrow) public escrows;
    uint256 public totalEscrowedNin;   // total nIN in active cash escrow
    uint256 public escrowDuration;     // global fallback duration (seconds)
    address public fundCore;           // GenericFundCore address
    address public rolesRegistry;      // RolesRegistry — for isLeader checks

    // --- CS004: per-union active escrow tracking + P2P order books ---
    mapping(address => uint256) public unionActiveEscrowNin; // live INVEST+REPAY nIN liability per union

    struct RedeemOrder {
        address union;
        address farmer;          // farmer whose nIN is locked (burned in confirmCashDelivery, returned in cancel)
        uint256 inrValue;        // ₹ LP must physically deliver to union
        uint256 usdtLocked;      // USDT locked by union at post time (6 dec)
        uint64  deadline;
        uint16  feeBP;           // extra USDT bonus already included in usdtLocked
        address lp;              // LP who committed (address(0) until committed)
        uint8   status;          // 0=Open, 1=LP Committed, 2=Confirmed (USDT paid), 3=Cancelled
    }
    mapping(uint256 => RedeemOrder) public redeemOrders;
    uint256 public nextRedeemOrderId;
    mapping(uint256 => uint256) public redeemOrderLockedNin; // orderId → nIN locked in contract (CS027)

    struct CashOffer {
        address union;
        uint256 escrowId;        // existing CONTRIBUTE/REPAY escrow being resolved
        uint256 ninAmount;       // nIN amount of the escrow
        uint256 inrValue;        // ₹ value union will deliver to LP as physical cash
        uint16  feeBP;           // extra INR cash bonus union gives LP above inrValue (off-chain)
        address lp;              // address(0) until filled
        uint64  deadline;        // inherits from escrow deadline
        uint8   status;          // 0=Open, 1=Filled, 2=Confirmed, 3=LPReclaimed, 4=Cancelled
    }
    mapping(uint256 => CashOffer) public cashOffers;
    uint256 public nextCashOfferId;

    // --- Events ---
    event MintNin(address indexed user, uint256 usdtIn, uint256 ninOut, uint256 rate);
    event RedeemNin(
        address indexed user,
        uint256 ninIn,
        uint256 usdtOut,
        uint256 feeUsdt,
        uint256 compUsdt,
        uint256 epochRate,
        uint256 currentRate,
        uint256 diffBps,
        bool userGained
    );
    event FxThresholdUpdated(uint256 oldValue, uint256 newValue);
    event GlobalCapUpdated(uint256 oldValue, uint256 newValue);
    event RedeemPaused(bool paused);
    event OracleUpdated(address oracle, uint8 decimals);
    event MaxOracleDelayUpdated(uint256 oldValue, uint256 newValue);
    event SupervisorDrain(address indexed to, uint256 amountUsdt);
    event FxEpochUpdated(uint256 oldRate, uint256 newRate, uint256 timestamp);
    event EpochDurationUpdated(uint256 oldValue, uint256 newValue);
    event CashScanMint(uint256 indexed escrowId, address indexed union, address indexed fundAddr, uint256 ninAmount, uint256 inrValue, uint256 rate, uint64 deadline, bytes32 scanHash);
    event EscrowResolved(uint256 indexed escrowId, uint8 resolution);
    event EscrowBurned(uint256 indexed escrowId, uint256 ninAmount);
    event EscrowDurationUpdated(uint256 oldValue, uint256 newValue);
    event FundCoreUpdated(address oldAddr, address newAddr);
    event FarmerNinBurned(address indexed union, address indexed farmer, uint256 amount);
    event FarmerNinLocked(address indexed union, address indexed farmer, uint256 amount);
    event FarmerNinUnlocked(address indexed union, address indexed farmer, uint256 amount);
    event RedeemOrderPosted(uint256 indexed orderId, address indexed union, address indexed farmer, uint256 inrValue, uint256 usdtLocked, uint16 feeBP);
    event RedeemOrderDelivered(uint256 indexed orderId);
    event RedeemOrderReclaimed(uint256 indexed orderId);
    event CashOfferPosted(uint256 indexed offerId, address indexed union, uint256 indexed escrowId, uint256 ninAmount, uint256 inrValue, uint16 feeBP);
    event CashOfferFilled(uint256 indexed offerId, address indexed lp, uint256 usdtDeposited);
    event CashOfferDelivered(uint256 indexed offerId);
    event CashOfferReclaimed(uint256 indexed offerId);
    event CashOfferCancelled(uint256 indexed offerId);

    // --------------------------------
    // Initializer (replaces constructor)
    // --------------------------------
    function initialize(
        address usdt_,
        address nin_,
        address oracle_,
        uint256 fxThresholdBps_,   // e.g. 200 = 2%
        uint256 globalCapPerDay_,  // e.g. 2_500e6 (USDT 6 decimals)
        uint256 maxOracleDelay_,   // e.g. 3600
        uint256 epochDuration_,    // e.g. 90 days in seconds
        address admin_
        ) public initializer {
        require(usdt_ != address(0) && nin_ != address(0), "Zero address");

        __AccessControl_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        usdt = IERC20(usdt_);
        nin = INilaNIN(nin_);

        uint8 dec = IERC20Metadata(usdt_).decimals();
        require(dec <= 18, "invalid usdt decimals");
        usdtDecimals = dec;

        inrUsdOracle = AggregatorV3Interface(oracle_);
        oracleDecimals = inrUsdOracle.decimals();

        fxThresholdBps = fxThresholdBps_;
        globalCapPerDay = globalCapPerDay_;
        maxOracleDelay = maxOracleDelay_;
        epochDuration = epochDuration_;

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(ONLY_OWNER, admin_);

        // Initialize FX epoch using current oracle rate
        (uint256 rate,) = _getOracle();
        lastFxRate = rate;
        lastEpochTimestamp = block.timestamp;

        // TWAP init: start with current rate
        twapRate = rate;
        lastObsRate = rate;
        lastObsTimestamp = uint64(block.timestamp);
        twapWindow = 3600 * 24 ; // e.g. daily for INR/USD should be ok
        maxRawVsTwapDiffBps = 300; // 3%

        emit OracleUpdated(oracle_, oracleDecimals);
        emit FxEpochUpdated(0, rate, block.timestamp);
    }

    // --- Internal helpers ---
    /// @notice Read fresh oracle, enforce staleness, and update TWAP.
    /// @dev Returns both raw oracle rate and twapRate (both in oracleDecimals).
    function _getOracle()
        internal
        returns (uint256 rawRate, uint256 twap)
        {
        (
            uint80 roundId,
            int256 answer,
            ,
            uint256 updatedAt,
            uint80 answeredInRound
        ) = inrUsdOracle.latestRoundData();

        if (answer <= 0) revert OracleInvalid();
        if (answeredInRound < roundId || updatedAt == 0) revert OracleStale();
        if (block.timestamp - updatedAt > maxOracleDelay) revert OracleTooOld();

        rawRate = uint256(answer); // USD per INR with oracleDecimals

        // Invert to INR per USD in the same decimal basis.
        uint256 scale = 10 ** oracleDecimals;
        rawRate = (scale * scale) / rawRate;

        // --- update TWAP in storage (stateful) ---
        if (lastObsTimestamp == 0 || twapWindow == 0) {
            twapRate = rawRate;
            lastObsRate = rawRate;
            lastObsTimestamp = uint64(block.timestamp);
        } else {
            uint256 nowTs = block.timestamp;
            uint256 dt = nowTs - lastObsTimestamp;
            if (dt > 0) {
                uint256 cappedDt = dt > twapWindow ? twapWindow : dt;
                uint256 window = twapWindow;
                uint256 weightOld = window > cappedDt ? (window - cappedDt) : 0;

                uint256 newTwap =
                    (twapRate * weightOld + lastObsRate * cappedDt) /
                    (weightOld + cappedDt);

                twapRate = newTwap;
                lastObsRate = rawRate;
                lastObsTimestamp = uint64(nowTs);
            }
        }

        twap = twapRate;
    }
    
    function _getOracleView()
        internal
        view
        returns (uint256 rawRate, uint256 twap)
        {
        (
            uint80 roundId,
            int256 answer,
            ,
            uint256 updatedAt,
            uint80 answeredInRound
        ) = inrUsdOracle.latestRoundData();

        if (answer <= 0) revert OracleInvalid();
        if (answeredInRound < roundId || updatedAt == 0) revert OracleStale();
        if (block.timestamp - updatedAt > maxOracleDelay) revert OracleTooOld();

        rawRate = uint256(answer); // USD per INR with oracleDecimals

        // Invert to INR per USD in the same decimal basis.
        uint256 scale = 10 ** oracleDecimals;
        rawRate = (scale * scale) / rawRate;

        // TWAP is just whatever was last written by a state-changing tx
        twap = twapRate;
    }

    // UUPS auth
    function _authorizeUpgrade(address newImplementation)
        internal
        override
        onlyRole(ONLY_OWNER)
    {}

    function _resetWindowIfNeeded(LimitInfo storage info) internal {
        if (info.windowStart == 0) {
            info.windowStart = uint64(block.timestamp);
        } else if (block.timestamp >= uint256(info.windowStart) + 1 days) {
            info.windowStart = uint64(block.timestamp);
            info.amount = 0;
        }
    }

    function _enforceGlobalCap(uint256 usdtAmount) internal {
        _resetWindowIfNeeded(globalLimit);
        uint256 newAmount = uint256(globalLimit.amount) + usdtAmount;
        require(newAmount <= globalCapPerDay, "global cap exceeded");
        globalLimit.amount = uint192(newAmount);
    }

    // --- Admin / config functions ---
    function setFxThresholdBps(uint256 newThreshold) external onlyRole(ONLY_OWNER) {
        require(newThreshold <= 10_000, "invalid threshold");
        uint256 old = fxThresholdBps;
        fxThresholdBps = newThreshold;
        emit FxThresholdUpdated(old, newThreshold);
    }

    function setGlobalCapPerDay(uint256 newCap) external onlyRole(ONLY_OWNER) {
        uint256 old = globalCapPerDay;
        globalCapPerDay = newCap;
        emit GlobalCapUpdated(old, newCap);
    }

    function setRedeemPaused(bool paused) external onlyRole(ONLY_OWNER) {
        redeemPaused = paused;
        emit RedeemPaused(paused);
    }

    function setOracle(address oracle, uint256 newMaxDelay) external onlyRole(ONLY_OWNER) {
        uint256 oldDelay = maxOracleDelay;
        inrUsdOracle = AggregatorV3Interface(oracle);
        oracleDecimals = inrUsdOracle.decimals();
        maxOracleDelay = newMaxDelay;
        emit OracleUpdated(oracle, oracleDecimals);
        emit MaxOracleDelayUpdated(oldDelay, newMaxDelay);
    }

    function setMaxOracleDelay(uint256 newMaxDelay) external onlyRole(ONLY_OWNER) {
        uint256 old = maxOracleDelay;
        maxOracleDelay = newMaxDelay;
        emit MaxOracleDelayUpdated(old, newMaxDelay);
    }

    function setEpochDuration(uint256 newDuration) external onlyRole(ONLY_OWNER) {
        uint256 old = epochDuration;
        epochDuration = newDuration;
        emit EpochDurationUpdated(old, newDuration);
    }

    function rescueToken(address token, address to, uint256 amount)
        external
        onlyRole(ONLY_OWNER)
        nonReentrant
        {
        require(token != address(usdt), "cannot rescue USDT");
        require(token != address(nin),  "cannot rescue NIN");
        require(to != address(0), "zero to");
        IERC20(token).transfer(to, amount);
    }

    /// @notice Manually update the FX epoch reference rate.
    /// Can be called e.g. every 90–180 days. You can enforce min spacing via epochDuration.
    function updateFxEpoch() external onlyRole(ONLY_OWNER) {
        require(
            block.timestamp >= lastEpochTimestamp + epochDuration,
            "epoch not elapsed"
        );
        uint256 old = lastFxRate;
        (uint256 rate, ) = _getOracle();
        lastFxRate = rate;
        lastEpochTimestamp = block.timestamp;
        emit FxEpochUpdated(old, rate, block.timestamp);
    }

    // --- Core logic ---
    /// @notice Mint nIN by depositing USDT.
    /// @dev User must have approved USDT to this contract.
    
    function mintNin(uint256 amountUsdt) external nonReentrant {
        require(amountUsdt > 0, "zero amount");
        (uint256 rate, uint256 twap) = _getOracle();

        // --- Sanity: raw vs TWAP ---
        if (twap > 0 && maxRawVsTwapDiffBps > 0) {
            uint256 hi = rate > twap ? rate : twap;
            uint256 lo = rate > twap ? twap   : rate;
            uint256 diffBps = ( (hi - lo) * 10_000 ) / lo;
            if (diffBps > maxRawVsTwapDiffBps) revert MintVolatilityBlocked();
        }

        // Pull USDT
        if (!usdt.transferFrom(msg.sender, address(this), amountUsdt)) revert UsdtTransferFailed();

        // Convert USDT -> nIN (INR amount at current rate)
        // 1) Promote USDT to 18-dec USD: usdtAmount * 10^(18-usdtDecimals)
        // 2) Multiply by rate (INR per USD) and divide by 10^oracleDecimals
        uint256 usdAmount18 = amountUsdt * (10 ** (18 - usdtDecimals));
        uint256 ninAmount = (usdAmount18 * rate) / (10 ** oracleDecimals); // 18 decimals

        // Mint nIN
        nin.mint(msg.sender, ninAmount);

        emit MintNin(msg.sender, amountUsdt, ninAmount, rate);
    }

    /// @dev Pure math + checks for a redeem, without state changes.
    /// Reverts in the same conditions as redeemNin (e.g. insufficient fxTreasuryUsdt).
    function previewRedeem(uint256 ninAmount)
        public
        view
        returns (
            uint256 usdtOut,
            uint256 feeUsdt,
            uint256 compUsdt,
            uint256 epochRate,
            uint256 rate,
            uint256 diffBps,
            bool userGained
        )
        {
        require(ninAmount > 0, "zero amount");

        epochRate = lastFxRate;
        uint256 twap;
        require(epochRate > 0, "no epoch rate");

        (rate,twap) = _getOracleView(); // INR per USD

        // --- Sanity: raw vs TWAP ---
        if (twap > 0 && maxRawVsTwapDiffBps > 0) {
            uint256 hi = rate > twap ? rate : twap;
            uint256 lo = rate > twap ? twap   : rate;
            uint256 twapdiffBps = ( (hi - lo) * 10_000 ) / lo;
            if (twapdiffBps > maxRawVsTwapDiffBps) revert RedeemVolatilityBlocked();
        }

        // Base USD in 18 decimals: USD = INR / rate
        uint256 usdBase18 = (ninAmount * (10 ** oracleDecimals)) / rate;

        // Convert to USDT units (e.g. 6 decimals)
        uint256 usdBaseUsdt = usdBase18 / (10 ** (18 - usdtDecimals));
        require(usdBaseUsdt > 0, "too small");

        // FX diff vs epoch
        if (rate < epochRate) {
            // INR stronger vs USD -> INR holder gains vs USD
            userGained = true;
            uint256 diff = epochRate - rate;
            diffBps = (diff * 10_000) / epochRate;
        } else if (rate > epochRate) {
            // INR weaker vs USD -> INR holder loses vs USD
            userGained = false;
            uint256 diff = rate - epochRate;
            diffBps = (diff * 10_000) / epochRate;
        } else {
            userGained = false;
            diffBps = 0;
        }

        uint256 threshold = fxThresholdBps;
        usdtOut = usdBaseUsdt; // start from base

        if (diffBps < threshold) {
            // small move: user always pays (threshold - diff)
            uint256 feePct = threshold - diffBps; // bps
            feeUsdt = (usdBaseUsdt * feePct) / 10_000;
            usdtOut = usdBaseUsdt - feeUsdt;
            // no compUsdt
        } else {
            if (userGained) {
                // move in user's favor: protocol takes at most `threshold` as fee
                uint256 feePct = threshold; // cap fee at fxThresholdBps
                if (feePct > diffBps) {
                    // if diff is smaller than threshold, don’t overcharge
                    feePct = diffBps;
                }

                feeUsdt = (usdBaseUsdt * feePct) / 10_000;
                if (feeUsdt > usdBaseUsdt) {
                    feeUsdt = usdBaseUsdt; // ultra-safety
                }
                usdtOut = usdBaseUsdt - feeUsdt;
                // no compUsdt
            } else {
                // move against user: protocol compensates above threshold
                uint256 lossPctUser = threshold; // bps
                uint256 maxLossUsdt = (usdBaseUsdt * lossPctUser) / 10_000;
                if (maxLossUsdt > usdBaseUsdt) {
                    maxLossUsdt = usdBaseUsdt; // safety
                }
                usdtOut = usdBaseUsdt - maxLossUsdt;

                // extra loss beyond threshold, covered by fxTreasury
                uint256 extraPct = diffBps - threshold; // bps
                uint256 extraLossUsdt = (usdBaseUsdt * extraPct) / 10_000;

                if (extraLossUsdt > 0) {
                    require(fxTreasuryUsdt >= extraLossUsdt, "insufficient fx treasury");
                    compUsdt = extraLossUsdt;
                    usdtOut += compUsdt;
                }
            }
        }

        require(usdtOut > 0, "usdtOut zero");
    }

    /// @notice Redeem nIN for USDT with FX-aware fee/compensation.
    /// Uses global FX epoch reference (lastFxRate) vs current oracle rate.
    function redeemNin(uint256 ninAmount) external nonReentrant {
        if (redeemPaused) revert RedeemIsPaused();

        (
            uint256 usdtOut,
            uint256 feeUsdt,
            uint256 compUsdt,
            uint256 epochRate,
            uint256 currentRate,
            uint256 diffBps,
            bool userGained
        ) = previewRedeem(ninAmount);

        // enforce global 24h cap on actual USDT out
        _enforceGlobalCap(usdtOut);

        // Burn nIN from user (this also checks user balance)
        nin.burn(msg.sender, ninAmount);

        // Update fxTreasuryUsdt: +fees -comp
        if (feeUsdt > 0) {
            fxTreasuryUsdt += feeUsdt;
        }
        if (compUsdt > 0) {
            // safe due to require in _previewRedeem
            fxTreasuryUsdt -= compUsdt;
        }

        // Transfer USDT
        if (usdt.balanceOf(address(this)) < usdtOut) revert InsufficientUsdt();
        if (!usdt.transfer(msg.sender, usdtOut)) revert UsdtTransferFailed();

        emit RedeemNin(
            msg.sender,
            ninAmount,
            usdtOut,
            feeUsdt,
            compUsdt,
            epochRate,
            currentRate,
            diffBps,
            userGained
        );
    }

    /// @notice Governance can drain USDT in 24h-limited batches (e.g. 2500 USDT/day).
    /// This uses the same global cap as user redemptions.
    function supervisorDrain(address to, uint256 amountUsdt)
        external
        onlyRole(ONLY_OWNER)
        nonReentrant
        {
        require(to != address(0), "zero to");
        require(amountUsdt > 0, "zero amount");

        // use the same rolling 24h cap as user redemptions
        _enforceGlobalCap(amountUsdt);

        if (usdt.balanceOf(address(this)) < amountUsdt) revert InsufficientUsdt();
        if (!usdt.transfer(to, amountUsdt)) revert UsdtTransferFailed();

        emit SupervisorDrain(to, amountUsdt);
    }

    // ------------------- VIEWER FUNCTIONS -------------------
    /// @notice View-only quote of a redeem: what you'd get and what fees/comp apply
    // ─────────────────────────────────────────────────────────────
    // Cash Scan Escrow — admin setters
    // ─────────────────────────────────────────────────────────────

    function setEscrowDuration(uint256 newDuration) external onlyRole(ONLY_OWNER) {
        if (newDuration < 1 days || newDuration > 30 days) revert DurationOutOfRange();
        uint256 old = escrowDuration;
        escrowDuration = newDuration;
        emit EscrowDurationUpdated(old, newDuration);
    }

    function setFundCore(address _fundCore) external onlyRole(ONLY_OWNER) {
        require(_fundCore != address(0), "zero address");
        address old = fundCore;
        fundCore = _fundCore;
        emit FundCoreUpdated(old, _fundCore);
    }

    function setRolesRegistry(address _roles) external onlyRole(ONLY_OWNER) {
        require(_roles != address(0), "zero address");
        rolesRegistry = _roles;
    }

    /// @notice One-time migration: swap NIN token to NINv2. Called as part of upgradeAndCall.
    /// @dev reinitializer(2) ensures this can never be called again after the upgrade.
    function reinitialize(address ninv2) external reinitializer(2) {
        require(ninv2 != address(0), "zero address");
        nin = INilaNIN(ninv2);
    }

    /// @notice Pull nIN from a farmer and burn it. Called by the union when a farmer physically
    ///         collects cash. The farmer must have granted this contract an allowance (via the
    ///         EIP-2612 permit signed at drawLoanWithVoucher time). Reverts if allowance is
    ///         insufficient — prevents burning tokens the holder never authorised.
    /// @param farmer  Address that holds the nIN to burn.
    /// @param amount  Amount of nIN to burn (must be <= farmer's allowance for this contract).
    function burnFarmerNin(address farmer, uint256 amount)
        external
        onlyRole(UNION_ROLE)
        nonReentrant
    {
        require(farmer != address(0), "zero address");
        require(amount > 0, "zero amount");
        nin.transferFrom(farmer, address(this), amount); // consumes permit-set allowance; reverts if insufficient
        nin.burn(address(this), amount);
        emit FarmerNinBurned(msg.sender, farmer, amount);
    }

    /// @notice Atomic cash-out: burn farmer's nIN AND resolve escrows in one tx.
    /// @dev Eliminates the partial-completion window where nIN is burned but escrows stay active.
    /// @param farmer     The farmer whose nIN to burn.
    /// @param burnAmount Total nIN to burn from farmer.
    /// @param escrowIds  Escrows to resolve (sorted by deadline asc recommended).
    /// @param amounts    Amount to consume from each escrow (sum should == burnAmount for escrow-only path).
    function burnAndDrainEscrows(
        address farmer,
        uint256 burnAmount,
        uint256[] calldata escrowIds,
        uint256[] calldata amounts
    ) external onlyRole(UNION_ROLE) nonReentrant {
        require(farmer != address(0), "zero address");
        require(burnAmount > 0, "zero amount");
        require(escrowIds.length == amounts.length, "length mismatch");

        // 1. Pull nIN from farmer via allowance, then burn — reverts if allowance or balance is insufficient
        nin.transferFrom(farmer, address(this), burnAmount);
        nin.burn(address(this), burnAmount);

        // 2. Drain escrows — reverts if any escrow is invalid/expired/over-drained
        for (uint256 i = 0; i < escrowIds.length; i++) {
            require(block.timestamp <= escrows[escrowIds[i]].deadline, "escrow expired");
            _resolveEscrowCash(escrowIds[i], amounts[i]);
        }

        emit FarmerNinBurned(msg.sender, farmer, burnAmount);
    }

    // ─────────────────────────────────────────────────────────────
    // Cash Scan Escrow — core functions
    // ─────────────────────────────────────────────────────────────

    /// @notice Union scans physical cash: invest, repay a loan, or disburse (resolve existing escrow).
    /// @param unionAddr         The union this cash belongs to.
    /// @param loanType          The junior market (INVEST/REPAY only).
    /// @param inrValue          Total INR value scanned (INVEST/REPAY only; ignored for DISBURSE).
    /// @param scanHash          keccak256 of scan data (serial numbers, image hash, denomination breakdown).
    /// @param purpose           INVEST — credit junior market; REPAY — close loan; DISBURSE — resolve existing escrow.
    /// @param loanId            The loan to repay (REPAY only; bytes32(0) otherwise).
    /// @param member            Member address for share attribution (INVEST with shares; address(0) for anonymous).
    /// @param escrowIdToResolve Existing escrow to close (DISBURSE only; 0 otherwise).
    /// @return escrowId         ID of the created escrow (INVEST/REPAY) or resolved escrow (DISBURSE).
    function cashScanMint(
        address unionAddr,
        bytes32 loanType,
        uint256 inrValue,
        bytes32 scanHash,
        ScanPurpose purpose,
        bytes32 loanId,
        address member,
        uint256 escrowIdToResolve
    ) external onlyRole(UNION_ROLE) nonReentrant returns (uint256 escrowId) {
        require(unionAddr != address(0), "zero union address");
        require(fundCore != address(0), "fund core not set");

        // ── DISBURSE: union gives ₹ cash to member/borrower, resolving an existing escrow ──
        if (purpose == ScanPurpose.DISBURSE) {
            if (escrowIdToResolve == 0) revert EscrowNotActive();
            CashEscrow storage de = escrows[escrowIdToResolve];
            if (de.union != unionAddr || de.status != 0) revert EscrowNotActive();
            if (block.timestamp > de.deadline) revert EscrowIsExpired();
            totalEscrowedNin -= de.ninAmount;
            unionActiveEscrowNin[unionAddr] -= de.ninAmount;
            de.status = 1; // ResolvedCash
            emit EscrowResolved(escrowIdToResolve, 1);
            return escrowIdToResolve;
        }

        // ── INVEST / REPAY: cash arrives at union, nIN minted ──
        require(inrValue > 0, "zero amount");

        (uint256 rate, uint256 twap) = _getOracle();

        // Volatility check (same as mintNin)
        if (twap > 0 && maxRawVsTwapDiffBps > 0) {
            uint256 hi = rate > twap ? rate : twap;
            uint256 lo = rate > twap ? twap   : rate;
            uint256 diffBps = ((hi - lo) * 10_000) / lo;
            if (diffBps > maxRawVsTwapDiffBps) revert MintVolatilityBlocked();
        }

        // nIN amount = INR value * 1e18 (1:1, both 18 decimals)
        uint256 ninAmount = inrValue * 1e18;

        // Treasury cap: union cannot create more cash liability than their treasury reserve
        uint256 reserve = IGenericFundCore(fundCore).unionTreasury(unionAddr);
        uint256 active  = unionActiveEscrowNin[unionAddr];
        if (active + ninAmount > reserve) revert ExceedsUnionReserve();
        unionActiveEscrowNin[unionAddr] = active + ninAmount;

        // Mint nIN to this contract, then route based on purpose
        nin.mint(address(this), ninAmount);

        if (purpose == ScanPurpose.INVEST) {
            // Transfer nIN to fund and credit the junior market escrow bucket.
            // member != address(0) → shares attributed to that member (contribution).
            // member == address(0) → anonymous pool liquidity (loan backing).
            nin.transfer(fundCore, ninAmount);
            IGenericFundCore(fundCore).creditEscrowNin(unionAddr, loanType, ninAmount, member);
        } else {
            // Repay path: approve fundCore to pull, then call repayLoan
            require(loanId != bytes32(0), "loanId required for repay");
            nin.approve(fundCore, ninAmount);
            IGenericFundCore(fundCore).repayLoan(unionAddr, loanId, ninAmount);
        }

        // Determine deadline: use per-union config from fund, fall back to global default
        uint32 unionDuration = IGenericFundCore(fundCore).getUnionEscrowDuration(unionAddr);
        uint64 deadline = uint64(block.timestamp + (unionDuration > 0 ? uint256(unionDuration) : escrowDuration));

        // Create escrow record — union still holds physical cash until resolved
        escrowId = nextEscrowId++;
        escrows[escrowId] = CashEscrow({
            union: unionAddr,
            fundAddr: fundCore,
            loanType: loanType,
            ninAmount: ninAmount,
            inrValue: inrValue,
            mintRate: rate,
            deadline: deadline,
            status: 0,
            scanHash: scanHash
        });

        totalEscrowedNin += ninAmount;

        // --- Reactive arrow: auto-post CashOffer only when pool is short on USDT
        // relative to pending LP withdrawals. Pending principal alone is not enough —
        // if the pool already holds sufficient USDT the union keeps the physical cash
        // for new disbursements and no LP conversion is needed.
        {
            uint256 srPending = IGenericFundCore(fundCore).seniorPendingPrincipal(unionAddr);
            uint256 jrPending = IGenericFundCore(fundCore).juniorPendingPrincipal(unionAddr, loanType);
            if (srPending + jrPending > 0) {
                (uint256 rate,) = _getOracle();
                uint256 neededUsdt = ((srPending + jrPending) * (10 ** oracleDecimals)) / rate / (10 ** (18 - usdtDecimals));
                if (usdt.balanceOf(address(this)) < neededUsdt) {
                    uint256 _offerId = nextCashOfferId++;
                    cashOffers[_offerId] = CashOffer({
                        union: unionAddr,
                        escrowId: escrowId,
                        ninAmount: ninAmount,
                        inrValue: inrValue,
                        feeBP: defaultCashOfferFeeBP,
                        lp: address(0),
                        deadline: deadline,
                        status: 0
                    });
                    emit CashOfferPosted(_offerId, unionAddr, escrowId, ninAmount, inrValue, defaultCashOfferFeeBP);
                }
            }
        }

        // --- FIFO head: track oldest active escrow per union ---
        if (unionActiveEscrowNin[unionAddr] == ninAmount) {
            // This was the first active escrow for this union (active was 0, now equals ninAmount)
            unionOldestEscrow[unionAddr] = escrowId;
        }

        emit CashScanMint(escrowId, unionAddr, fundCore, ninAmount, inrValue, rate, deadline, scanHash);
    }

    /// @notice Resolve escrow as USDt-backed.
    /// @dev The union physically converted the scanned INR cash to USDt and is depositing it here.
    ///      USDt amount is computed from the escrow's ninAmount at the rate locked at scan time
    ///      (stored as mintRate, in oracleDecimals, INR per USD) — the union bears the FX risk.
    ///      The nIN already in the junior market stays there as normal liquidity; it now has USDt
    ///      backing in this contract. The escrow status is set to ResolvedUsdt so the burn path
    ///      is permanently blocked for this escrow.
    function resolveEscrowUsdt(uint256 escrowId) external onlyRole(UNION_ROLE) nonReentrant {
        CashEscrow storage e = escrows[escrowId];
        if (e.status != 0) revert EscrowNotActive();
        if (e.union != msg.sender) revert Unauthorized();
        if (block.timestamp > e.deadline) revert EscrowIsExpired();

        // Compute the USDT amount that backs this nIN:
        //   ninAmount  = inrValue * 1e18                    (18 dec, integer INR)
        //   mintRate   = INR per USD in oracleDecimals
        //   usdAmount18 = ninAmount * 10^oracleDec / mintRate   (18 dec USD)
        //   usdtAmount  = usdAmount18 / 10^(18-usdtDecimals)    (6 dec USDT)
        uint256 usdAmount18 = (e.ninAmount * (10 ** oracleDecimals)) / e.mintRate;
        uint256 usdtAmount  = usdAmount18 / (10 ** (18 - usdtDecimals));
        if (usdtAmount == 0) revert UsdtRoundsToZero();

        // Pull USDT from the union into this contract (backs the existing nIN in the system)
        usdt.transferFrom(msg.sender, address(this), usdtAmount);

        e.status = 2; // ResolvedUsdt
        totalEscrowedNin -= e.ninAmount;
        unionActiveEscrowNin[e.union] -= e.ninAmount;

        // Advance FIFO head if this was the oldest escrow
        if (unionOldestEscrow[e.union] == escrowId) {
            unionOldestEscrow[e.union] = escrowId + 1;
        }

        emit EscrowResolved(escrowId, 2);
    }

    /// @notice FIFO deposit: union deposits USDT, protocol routes to oldest active escrows.
    /// @dev Leader doesn't pick which escrow — protocol serves oldest first.
    ///      Unused USDT is refunded to caller.
    function depositUsdt(address unionAddr, uint256 usdtAmount) external onlyRole(UNION_ROLE) nonReentrant {
        require(usdtAmount > 0, "zero amount");
        usdt.transferFrom(msg.sender, address(this), usdtAmount);

        uint256 remaining = usdtAmount;
        uint256 cursor = unionOldestEscrow[unionAddr];

        while (remaining > 0 && cursor < nextEscrowId) {
            CashEscrow storage e = escrows[cursor];
            if (e.union == unionAddr && e.status == 0 && block.timestamp <= e.deadline) {
                uint256 usdAmt18 = (e.ninAmount * (10 ** oracleDecimals)) / e.mintRate;
                uint256 needed   = usdAmt18 / (10 ** (18 - usdtDecimals));
                if (needed > 0 && needed <= remaining) {
                    e.status = 2; // ResolvedUsdt
                    totalEscrowedNin -= e.ninAmount;
                    unionActiveEscrowNin[unionAddr] -= e.ninAmount;
                    remaining -= needed;
                    emit EscrowResolved(cursor, 2);
                } else {
                    break; // Can't fully resolve next escrow — stop
                }
            }
            cursor++;
        }

        unionOldestEscrow[unionAddr] = cursor;

        // Refund unused USDT
        if (remaining > 0) {
            usdt.transfer(msg.sender, remaining);
        }
    }

    /// @notice Partially or fully resolve an active escrow.
    /// @dev Two callers allowed:
    ///      - GenericFundCore (loan disbursal): reduces escrow as nIN flows to borrowers.
    ///      - UNION_ROLE (direct cash-out): union operator marks cash physically handed out.
    ///      Status becomes ResolvedCash (1) only when ninAmount reaches zero; until then
    ///      the escrow stays Active so subsequent draws and burn/USDT paths still work.
    ///      UNION_ROLE callers additionally cannot act on expired escrows.
    /// @notice Resolve (or gate-check) a cash escrow during loan disbursal.
    /// @param escrowId  Escrow to resolve (0 = gate check only, no escrow to resolve)
    /// @param amount    nIN amount being disbursed
    /// @param unionAddr Union address (passed by Core for gate check; ignored by UNION_ROLE callers)
    function resolveEscrowCash(uint256 escrowId, uint256 amount, address unionAddr) external nonReentrant {
        bool isFundCore = msg.sender == fundCore;
        bool isUnion    = hasRole(UNION_ROLE, msg.sender);
        if (!isFundCore && !isUnion) revert Unauthorized();

        // --- LP withdrawal gate: block large loan disbursals when USDT is short ---
        if (isFundCore && amount > INSTANT_THRESHOLD) {
            address union = escrowId > 0 ? escrows[escrowId].union : unionAddr;
            uint256 pending = IGenericFundCore(fundCore).seniorPendingPrincipal(union);
            if (pending > 0) {
                (uint256 rate,) = _getOracle();
                uint256 needed = (pending * (10 ** oracleDecimals)) / rate / (10 ** (18 - usdtDecimals));
                if (usdt.balanceOf(address(this)) < needed) revert InsufficientUsdt();
            }
        }

        // escrowId=0: Core calls for gate check only — no escrow to resolve
        if (escrowId == 0) return;

        if (isUnion && block.timestamp > escrows[escrowId].deadline) revert EscrowIsExpired();
        _resolveEscrowCash(escrowId, amount);
    }

    function _resolveEscrowCash(uint256 escrowId, uint256 amount) internal {
        if (amount == 0) revert InvalidInput();
        CashEscrow storage e = escrows[escrowId];
        if (e.status != 0) revert EscrowNotActive();

        // Cap at escrow balance: loan principal may slightly exceed escrow nIN
        // when the two were created from separate INR→nIN conversions.
        uint256 resolved = amount > e.ninAmount ? e.ninAmount : amount;

        e.ninAmount      -= resolved;
        totalEscrowedNin -= resolved;
        unionActiveEscrowNin[e.union] -= resolved;

        if (e.ninAmount == 0) {
            e.status = 1; // ResolvedCash — fully consumed
        }

        emit EscrowResolved(escrowId, e.status);
    }

    /// @notice Burn nIN for an expired, unresolved escrow. Permissionless.
    /// @dev Debits unionTreasury (not junior.cash) so investors are not penalised for the union's inaction.
    ///      For REPAY escrows the nIN was already consumed by repayLoan — treasury absorbs the accounting entry.
    function burnExpiredEscrow(uint256 escrowId) external nonReentrant {
        CashEscrow storage e = escrows[escrowId];
        if (e.status != 0) revert EscrowNotActive();
        if (block.timestamp <= e.deadline) revert EscrowNotExpired();

        uint256 amount = e.ninAmount;
        e.status = 3; // Burned
        totalEscrowedNin -= amount;
        unionActiveEscrowNin[e.union] -= amount;

        // Debit union treasury instead of junior.cash — union bears the penalty
        uint256 burned = IGenericFundCore(fundCore).burnTreasuryForExpiry(e.union, amount);
        if (burned > 0) nin.burn(address(this), burned);

        // Advance FIFO head if this was the oldest escrow
        if (unionOldestEscrow[e.union] == escrowId) {
            unionOldestEscrow[e.union] = escrowId + 1;
        }

        emit EscrowBurned(escrowId, amount);
    }

    /// @notice Batch burn multiple expired escrows. Permissionless. Skips ineligible entries.
    function burnExpiredEscrowBatch(uint256[] calldata escrowIds) external nonReentrant {
        for (uint256 i = 0; i < escrowIds.length; i++) {
            CashEscrow storage e = escrows[escrowIds[i]];
            if (e.status != 0 || block.timestamp <= e.deadline) continue;

            uint256 amount = e.ninAmount;
            e.status = 3; // Burned
            totalEscrowedNin -= amount;
            unionActiveEscrowNin[e.union] -= amount;

            uint256 burned = IGenericFundCore(fundCore).burnTreasuryForExpiry(e.union, amount);
            if (burned > 0) nin.burn(address(this), burned);

            emit EscrowBurned(escrowIds[i], amount);
        }
    }

    // ─────────────────────────────────────────────────────────────
    // Redeem order book
    // Flow: union redeemFarmerNin → postRedeemOrder → LP brings cash → confirmCashDelivery
    // USDT never leaves the pool until confirmCashDelivery sends it directly to the LP.
    // ─────────────────────────────────────────────────────────────

    /// @notice Step 1: lock farmer's nIN in contract — USDT earmarked, burn deferred to confirmCashDelivery.
    /// @dev CS027: nIN is NOT burned here. It is burned atomically in confirmCashDelivery when the LP
    ///      delivers cash, or returned to the farmer in cancelRedeemOrder if no LP is found.
    ///      This eliminates the stuck state where nIN was burned but no cash reached the farmer.
    /// @dev Requires the farmer to have granted this contract an allowance. Reverts if insufficient.
    ///      Swap preview uses the same fee/compensation logic as redeemNin (previewRedeem).
    ///      Union must then call postRedeemOrder, passing ninAmount as returned here.
    function redeemFarmerNin(
        address farmer,
        uint256 ninAmount
    ) external onlyRole(UNION_ROLE) nonReentrant returns (uint256 usdtOut) {
        require(farmer != address(0) && ninAmount > 0, "invalid");
        uint256 feeUsdt; uint256 compUsdt;
        (usdtOut, feeUsdt, compUsdt, , , , ) = previewRedeem(ninAmount);
        _enforceGlobalCap(usdtOut);
        nin.transferFrom(farmer, address(this), ninAmount); // locked in contract; burn deferred
        if (feeUsdt > 0) fxTreasuryUsdt += feeUsdt;
        if (compUsdt > 0) fxTreasuryUsdt -= compUsdt;
        emit FarmerNinLocked(msg.sender, farmer, ninAmount);
    }

    /// @notice Step 2: record earmarked USDT + locked nIN as a cash request — LP brings INR cash to earn it.
    /// @dev usdtAmount and ninAmount come from redeemFarmerNin return values. USDT is already in the pool.
    ///      ninAmount is stored in redeemOrderLockedNin[orderId] for deferred burn in confirmCashDelivery.
    function postRedeemOrder(
        address unionAddr,
        address farmer,
        uint256 inrValue,
        uint256 usdtAmount,
        uint256 ninAmount,
        uint16  feeBP
    ) external onlyRole(UNION_ROLE) returns (uint256 orderId) {
        require(unionAddr != address(0) && inrValue > 0 && usdtAmount > 0 && ninAmount > 0, "invalid");
        // USDT already in pool from redeemFarmerNin — no transferFrom needed.
        uint32 unionDuration = fundCore != address(0)
            ? IGenericFundCore(fundCore).getUnionEscrowDuration(unionAddr)
            : 0;
        uint64 deadline = uint64(block.timestamp + (unionDuration > 0 ? uint256(unionDuration) : escrowDuration));
        orderId = nextRedeemOrderId++;
        redeemOrders[orderId] = RedeemOrder({
            union:      unionAddr,
            farmer:     farmer,
            inrValue:   inrValue,
            usdtLocked: usdtAmount,
            deadline:   deadline,
            feeBP:      feeBP,
            lp:         address(0),
            status:     0
        });
        redeemOrderLockedNin[orderId] = ninAmount;
        emit RedeemOrderPosted(orderId, unionAddr, farmer, inrValue, usdtAmount, feeBP);
    }

    /// @notice LP commits to bring cash — registers their address on-chain, no USDT required.
    function commitCashRequest(uint256 orderId) external {
        RedeemOrder storage o = redeemOrders[orderId];
        require(o.status == 0 && o.lp == address(0), "not available");
        require(block.timestamp <= o.deadline, "expired");
        o.lp     = msg.sender;
        o.status = 1; // LP Committed
    }

    /// @notice Step 3: union counts bills, confirms LP delivered cash → locked nIN burned, USDT released to LP.
    /// @dev CS027: burns the nIN that was locked in redeemFarmerNin before releasing USDT to LP.
    function confirmCashDelivery(uint256 orderId) external onlyRole(UNION_ROLE) nonReentrant {
        RedeemOrder storage o = redeemOrders[orderId];
        require(o.status == 1, "not committed");
        require(
            rolesRegistry != address(0) && IRolesRegistry(rolesRegistry).isLeader(o.union, msg.sender),
            "not a leader of this union"
        );
        require(block.timestamp <= o.deadline, "expired");
        o.status = 2; // Confirmed
        uint256 lockedNin = redeemOrderLockedNin[orderId];
        if (lockedNin > 0) {
            redeemOrderLockedNin[orderId] = 0;
            nin.burn(address(this), lockedNin);
            emit FarmerNinBurned(o.union, o.farmer, lockedNin);
        }
        usdt.transfer(o.lp, o.usdtLocked);
        emit RedeemOrderDelivered(orderId);
    }

    /// @notice Union cancels open cash request — locked nIN returned to farmer, USDT stays in pool.
    /// @dev CS027: safe to cancel at any time before LP commits — farmer gets nIN back, no stuck state.
    function cancelRedeemOrder(uint256 orderId) external onlyRole(UNION_ROLE) {
        RedeemOrder storage o = redeemOrders[orderId];
        require(o.status <= 1, "cannot cancel");
        require(
            rolesRegistry != address(0) && IRolesRegistry(rolesRegistry).isLeader(o.union, msg.sender),
            "not a leader of this union"
        );
        o.status = 3; // Cancelled
        uint256 lockedNin = redeemOrderLockedNin[orderId];
        if (lockedNin > 0) {
            redeemOrderLockedNin[orderId] = 0;
            nin.transfer(o.farmer, lockedNin);
            emit FarmerNinUnlocked(o.union, o.farmer, lockedNin);
        }
        // USDT stays in pool — no transfer needed.
        emit RedeemOrderReclaimed(orderId);
    }

    // ─────────────────────────────────────────────────────────────
    // CashOffer order book — union sells ₹ cash for USDT via LP
    // ─────────────────────────────────────────────────────────────

    /// @notice Union posts a CashOffer: "I have ₹ cash, I need USDT — link to existing escrow."
    /// @dev LP fills by depositing USDT (= resolveEscrowUsdt internally) and receives nIN + bonus.
    ///      LP can hold nIN or immediately redeem → USDT via redeemNin in the same tx.
    function postCashOffer(
        address unionAddr,
        uint256 escrowId,
        uint16  feeBP
    ) external onlyRole(UNION_ROLE) returns (uint256 offerId) {
        CashEscrow storage e = escrows[escrowId];
        if (e.union != unionAddr || e.status != 0) revert EscrowNotActive();
        if (block.timestamp > e.deadline) revert EscrowIsExpired();
        offerId = nextCashOfferId++;
        cashOffers[offerId] = CashOffer({
            union: unionAddr,
            escrowId: escrowId,
            ninAmount: e.ninAmount,
            inrValue: e.inrValue,
            feeBP: feeBP,
            lp: address(0),
            deadline: e.deadline,
            status: 0
        });
        emit CashOfferPosted(offerId, unionAddr, escrowId, e.ninAmount, e.inrValue, feeBP);
    }

    /// @notice LP fills a CashOffer: deposits USDT → escrow resolved (ResolvedUsdt).
    /// @dev LP's return is the ₹ cash the union delivers off-chain (+ feeBP bonus in cash).
    ///      No nIN is minted — the deposited USDT stays in this contract as hard-currency
    ///      backing for the existing escrow nIN already held in GenericFundCore.
    ///      Union must then deliver ₹ cash to LP off-chain and call confirmCashOfferDelivered.
    function fillCashOffer(uint256 offerId) external nonReentrant {
        CashOffer storage o = cashOffers[offerId];
        if (o.status != 0 || o.lp != address(0)) revert EscrowNotActive();
        if (block.timestamp > o.deadline) revert EscrowIsExpired();

        CashEscrow storage e = escrows[o.escrowId];
        if (e.status != 0) revert EscrowNotActive();

        // Compute USDT at escrow's locked mint rate (same formula as resolveEscrowUsdt)
        uint256 usdAmount18 = (e.ninAmount * (10 ** oracleDecimals)) / e.mintRate;
        uint256 usdtAmount  = usdAmount18 / (10 ** (18 - usdtDecimals));
        if (usdtAmount == 0) revert UsdtRoundsToZero();

        usdt.transferFrom(msg.sender, address(this), usdtAmount);

        // Resolve escrow: nIN stays in fund, now USDT-backed
        e.status = 2; // ResolvedUsdt
        totalEscrowedNin -= e.ninAmount;
        unionActiveEscrowNin[o.union] -= e.ninAmount;

        o.lp = msg.sender;
        o.status = 1; // Filled — union must deliver ₹ cash to LP

        // Advance FIFO head if this escrow was the oldest
        if (unionOldestEscrow[o.union] == o.escrowId) {
            unionOldestEscrow[o.union] = o.escrowId + 1;
        }

        emit EscrowResolved(o.escrowId, 2);
        emit CashOfferFilled(offerId, msg.sender, usdtAmount);
    }

    /// @notice Junior investor fills a CashOffer with nIN: burns nIN → escrow resolved (ResolvedCash).
    /// @dev Investor must have approved FxPool for the nIN amount (consent).
    ///      nIN is burned — supply shrinks, escrow obligation disappears (no USDT needed).
    ///      Union must still deliver ₹ cash to investor and call confirmCashOfferDelivered.
    function fillCashOfferWithNin(uint256 offerId) external nonReentrant {
        CashOffer storage o = cashOffers[offerId];
        if (o.status != 0 || o.lp != address(0)) revert EscrowNotActive();
        if (block.timestamp > o.deadline) revert EscrowIsExpired();

        CashEscrow storage e = escrows[o.escrowId];
        if (e.status != 0) revert EscrowNotActive();

        // Transfer nIN from investor (consent = their ERC20 approve), then burn
        uint256 amt = e.ninAmount;
        nin.transferFrom(msg.sender, address(this), amt);
        nin.burn(address(this), amt);

        // Escrow resolved — the nIN it tracked is gone, no USDT backing needed
        e.status = 1; // ResolvedCash
        totalEscrowedNin -= amt;
        unionActiveEscrowNin[o.union] -= amt;

        o.lp = msg.sender;
        o.status = 1; // Filled — union must deliver ₹ cash to investor

        if (unionOldestEscrow[o.union] == o.escrowId) {
            unionOldestEscrow[o.union] = o.escrowId + 1;
        }

        emit EscrowResolved(o.escrowId, 1);
        emit CashOfferFilled(offerId, msg.sender, amt);
    }

    /// @notice Union confirms ₹ cash delivered to LP → offer complete.
    function confirmCashOfferDelivered(uint256 offerId) external onlyRole(UNION_ROLE) {
        CashOffer storage o = cashOffers[offerId];
        require(o.union == msg.sender && o.status == 1, "invalid");
        o.status = 2; // Confirmed
        emit CashOfferDelivered(offerId);
    }

    /// @notice LP reclaims USDT if union failed to deliver ₹ cash within deadline.
    function reclaimCashOfferUsdt(uint256 offerId) external nonReentrant {
        CashOffer storage o = cashOffers[offerId];
        require(o.lp == msg.sender && o.status == 1, "invalid");
        require(block.timestamp > o.deadline, "not expired");

        // Return USDT at original locked rate (no nIN was minted so nothing to burn)
        CashEscrow storage e = escrows[o.escrowId];
        uint256 usdAmount18 = (e.ninAmount * (10 ** oracleDecimals)) / e.mintRate;
        uint256 usdtAmount  = usdAmount18 / (10 ** (18 - usdtDecimals));
        usdt.transfer(msg.sender, usdtAmount);

        o.status = 3; // LPReclaimed
        emit CashOfferReclaimed(offerId);
    }

    /// @notice Leader cancels an unfilled CashOffer. No token moves — escrow stays active.
    function cancelCashOffer(uint256 offerId) external onlyRole(UNION_ROLE) {
        CashOffer storage o = cashOffers[offerId];
        require(o.status == 0 && o.lp == address(0), "cannot cancel");
        require(
            rolesRegistry != address(0) && IRolesRegistry(rolesRegistry).isLeader(o.union, msg.sender),
            "not a leader of this union"
        );
        o.status = 4; // Cancelled
        emit CashOfferCancelled(offerId);
    }

    // --- Three-layer reactive accounting (LP obligation system) ---
    mapping(address => uint256) public unionOldestEscrow;  // FIFO head pointer per union
    uint16 public defaultCashOfferFeeBP;                    // auto-post CashOffer fee (can be 0)
    uint256 public constant INSTANT_THRESHOLD = 10_000 * 1e18; // 10k nIN — small loans bypass gate

    /// @notice Admin setter for default CashOffer fee on auto-posted offers.
    function setDefaultCashOfferFeeBP(uint16 feeBP) external onlyRole(ONLY_OWNER) {
        defaultCashOfferFeeBP = feeBP;
    }

    // --- Storage gap for future upgrades ---
    // CS003: 5 slots (nextEscrowId, escrows, totalEscrowedNin, escrowDuration, fundCore)
    // CS004: unionActiveEscrowNin, redeemOrders, nextRedeemOrderId, cashOffers, nextCashOfferId = 5 slots
    // CS026: unionOldestEscrow, defaultCashOfferFeeBP = 2 slots (constant doesn't use storage)
    // CS027: redeemOrderLockedNin = 1 slot
    uint256[26] private __gap;
}

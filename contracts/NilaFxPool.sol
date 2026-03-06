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
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

interface IGenericFundCore {
    function creditEscrowNin(address unionAddr, bytes32 loanType, uint256 amount) external;
    function burnEscrowNin(address unionAddr, bytes32 loanType, uint256 amount) external;
    function getUnionEscrowDuration(address unionAddr) external view returns (uint32);
}

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

        require(answer > 0, "oracle answer <= 0");
        require(answeredInRound >= roundId && updatedAt != 0, "stale round");
        require(block.timestamp - updatedAt <= maxOracleDelay, "oracle too old");

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

        require(answer > 0, "oracle answer <= 0");
        require(answeredInRound >= roundId && updatedAt != 0, "stale round");
        require(block.timestamp - updatedAt <= maxOracleDelay, "oracle too old");

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

    // --- View helpers ---
    function getFxEpoch()
        external
        view
        returns (uint256 epochRate, uint256 epochTimestamp, uint256 epochDurationSec)
    {
        return (lastFxRate, lastEpochTimestamp, epochDuration);
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
            require(diffBps <= maxRawVsTwapDiffBps, "mint rejected as INR/USD is too volatile currently, please try again later.");
        }

        // Pull USDT
        require(usdt.transferFrom(msg.sender, address(this), amountUsdt), "USDT transfer failed");

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
    function _previewRedeem(uint256 ninAmount)
        internal
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
            require(twapdiffBps <= maxRawVsTwapDiffBps, "redeem rejected as USD/INR is too volatile currently, please try again later.");
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
        require(!redeemPaused, "redeem paused");

        (
            uint256 usdtOut,
            uint256 feeUsdt,
            uint256 compUsdt,
            uint256 epochRate,
            uint256 currentRate,
            uint256 diffBps,
            bool userGained
        ) = _previewRedeem(ninAmount);

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
        require(usdt.balanceOf(address(this)) >= usdtOut, "pool USDT too low");
        require(usdt.transfer(msg.sender, usdtOut), "USDT transfer failed");

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

        require(usdt.balanceOf(address(this)) >= amountUsdt, "insufficient USDT");
        require(usdt.transfer(to, amountUsdt), "USDT transfer failed");

        emit SupervisorDrain(to, amountUsdt);
    }

    // ------------------- VIEWER FUNCTIONS -------------------
    /// @notice View-only quote of a redeem: what you'd get and what fees/comp apply
    // ─────────────────────────────────────────────────────────────
    // Cash Scan Escrow — admin setters
    // ─────────────────────────────────────────────────────────────

    function setEscrowDuration(uint256 newDuration) external onlyRole(ONLY_OWNER) {
        require(newDuration >= 1 days && newDuration <= 30 days, "duration out of range");
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

    function setNin(address _nin) external onlyRole(ONLY_OWNER) {
        require(_nin != address(0), "zero address");
        nin = INilaNIN(_nin);
    }

    /// @notice Pull nIN from a farmer and burn it. Called by the union after the farmer
    ///         physically returns cash. The farmer must have signed a permit for FxPool
    ///         (or called approve) at drawLoanWithVoucher time.
    /// @param farmer  Address that holds the nIN to burn.
    /// @param amount  Amount of nIN to burn (must match loan principal).
    function burnFarmerNin(address farmer, uint256 amount)
        external
        onlyRole(UNION_ROLE)
        nonReentrant
    {
        require(farmer != address(0), "zero address");
        require(amount > 0, "zero amount");
        nin.transferFrom(farmer, address(this), amount);
        nin.burn(address(this), amount);
        emit FarmerNinBurned(msg.sender, farmer, amount);
    }

    // ─────────────────────────────────────────────────────────────
    // Cash Scan Escrow — core functions
    // ─────────────────────────────────────────────────────────────

    /// @notice Union scans physical cash. nIN is minted and credited to the specified junior market.
    /// @param loanType The junior market this escrow liquidity belongs to.
    /// @param inrValue Total INR value of scanned cash (human units, e.g. 84000 for ₹84,000)
    /// @param scanHash keccak256 of scan data (serial numbers, image hash, denomination breakdown)
    /// @return escrowId The ID of the created escrow
    function cashScanMint(
        bytes32 loanType,
        uint256 inrValue,
        bytes32 scanHash
    ) external onlyRole(UNION_ROLE) nonReentrant returns (uint256 escrowId) {
        require(inrValue > 0, "zero amount");
        require(fundCore != address(0), "fund core not set");

        (uint256 rate, uint256 twap) = _getOracle();

        // Volatility check (same as mintNin)
        if (twap > 0 && maxRawVsTwapDiffBps > 0) {
            uint256 hi = rate > twap ? rate : twap;
            uint256 lo = rate > twap ? twap   : rate;
            uint256 diffBps = ((hi - lo) * 10_000) / lo;
            require(diffBps <= maxRawVsTwapDiffBps, "mint rejected as INR/USD is too volatile currently, please try again later.");
        }

        // nIN amount = INR value * 1e18 (1:1, both 18 decimals)
        uint256 ninAmount = inrValue * 1e18;

        // Mint nIN to the fund contract, then register it as junior market cash
        nin.mint(fundCore, ninAmount);
        IGenericFundCore(fundCore).creditEscrowNin(msg.sender, loanType, ninAmount);

        // Determine deadline: use per-union config from fund, fall back to global default
        uint32 unionDuration = IGenericFundCore(fundCore).getUnionEscrowDuration(msg.sender);
        uint64 deadline = uint64(block.timestamp + (unionDuration > 0 ? uint256(unionDuration) : escrowDuration));

        // Create escrow record
        escrowId = nextEscrowId++;
        escrows[escrowId] = CashEscrow({
            union: msg.sender,
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

        emit CashScanMint(escrowId, msg.sender, fundCore, ninAmount, inrValue, rate, deadline, scanHash);
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
        require(e.status == 0, "not active");
        require(e.union == msg.sender, "not your escrow");
        require(block.timestamp <= e.deadline, "expired");

        // Compute the USDT amount that backs this nIN:
        //   ninAmount  = inrValue * 1e18                    (18 dec, integer INR)
        //   mintRate   = INR per USD in oracleDecimals
        //   usdAmount18 = ninAmount * 10^oracleDec / mintRate   (18 dec USD)
        //   usdtAmount  = usdAmount18 / 10^(18-usdtDecimals)    (6 dec USDT)
        uint256 usdAmount18 = (e.ninAmount * (10 ** oracleDecimals)) / e.mintRate;
        uint256 usdtAmount  = usdAmount18 / (10 ** (18 - usdtDecimals));
        require(usdtAmount > 0, "usdt amount rounds to zero");

        // Pull USDT from the union into this contract (backs the existing nIN in the system)
        usdt.transferFrom(msg.sender, address(this), usdtAmount);

        e.status = 2; // ResolvedUsdt
        totalEscrowedNin -= e.ninAmount;

        emit EscrowResolved(escrowId, 2);
    }

    /// @notice Called by GenericFundCore when nIN is disbursed to a farmer.
    /// @dev Reduces the escrow by the loan amount. A single cashScanMint may back
    ///      multiple loans drawn at different times. Status moves to ResolvedCash (1)
    ///      only when the full scanned amount is consumed. While partially consumed
    ///      the escrow remains Active (0) so additional draws and the burn/USDT paths
    ///      still work on the remaining amount.
    ///      Only callable by the fund contract registered as fundCore.
    function resolveEscrowCash(uint256 escrowId, uint256 amount) external {
        require(msg.sender == fundCore, "only fund core");
        require(amount > 0, "zero amount");
        CashEscrow storage e = escrows[escrowId];
        require(e.status == 0, "not active");
        require(amount <= e.ninAmount, "amount exceeds escrow");

        e.ninAmount      -= amount;
        totalEscrowedNin -= amount;

        if (e.ninAmount == 0) {
            e.status = 1; // ResolvedCash — fully consumed by loans
        }

        emit EscrowResolved(escrowId, e.status);
    }

    /// @notice Burn nIN for an expired, unresolved escrow. Permissionless.
    function burnExpiredEscrow(uint256 escrowId) external nonReentrant {
        CashEscrow storage e = escrows[escrowId];
        require(e.status == 0, "not active");
        require(block.timestamp > e.deadline, "not expired");

        uint256 amount = e.ninAmount;
        e.status = 3; // Burned
        totalEscrowedNin -= amount;

        // Deduct from junior market, transfer nIN to this contract, then burn
        IGenericFundCore(fundCore).burnEscrowNin(e.union, e.loanType, amount);
        nin.burn(address(this), amount);

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

            IGenericFundCore(fundCore).burnEscrowNin(e.union, e.loanType, amount);
            nin.burn(address(this), amount);

            emit EscrowBurned(escrowIds[i], amount);
        }
    }

    // ─────────────────────────────────────────────────────────────
    // Cash Scan Escrow — view functions
    // ─────────────────────────────────────────────────────────────

    function getEscrow(uint256 escrowId) external view returns (CashEscrow memory) {
        return escrows[escrowId];
    }

    function isEscrowExpired(uint256 escrowId) external view returns (bool) {
        CashEscrow storage e = escrows[escrowId];
        return e.status == 0 && block.timestamp > e.deadline;
    }

    /// if you redeemed `ninAmount` *right now*.
    /// Uses current oracle rate and current fxTreasuryUsdt; may revert if treasury is insufficient.
    function quoteRedeem(uint256 ninAmount)
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
        return _previewRedeem(ninAmount);
    }



    // --- Storage gap for future upgrades ---
    // 5 slots consumed by CS003 escrow state (nextEscrowId, escrows, totalEscrowedNin, escrowDuration, fundCore)
    uint256[35] private __gap;
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

/*
 * GenericFundUpgradeable — v1.3 (core, ERC1155 moved out)
 * - All ERC1155 logic removed.
 * - Adds erc1155Module + mintJuniorFromQuote() callable only by the module.
 * - request/claim in-kind paths call out to the module for validation/redemption.
 */

import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

import "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

// Use your existing math lib name/path
import "./GenericFundMathLib.sol";

contract GenericFundUpgradeable is Initializable,
                                    OwnableUpgradeable,
                                    PausableUpgradeable,
                                    ReentrancyGuardUpgradeable,
                                    UUPSUpgradeable,
                                    EIP712Upgradeable
{
    using SafeERC20 for IERC20Metadata;

    // ───────── constants ─────────
    uint256 private constant RAY  = 1e27;
    uint256 private constant WAD  = 1e18;
    uint256 private constant YEAR = 365 days;
    uint256 private constant CARRYOVER_WINDOW = 22 days; // tolerance
    uint16  private constant TREASURY_FEE_BP = 100; // 1%
    uint256 public constant MIN_UNBONDING = 14 days;

    enum Tranche { JUNIOR, SENIOR }

    // ───────── custom errors ─────────
    error ZeroAmount();
    error UnionInactive();
    error NotOracleOrLeader();
    error MarketEmpty();
    error SeniorEmpty();
    error InsufficientUnlocked();
    error InsufficientLiquidity();
    error NotOwner();
    error NotAvailable();
    error AlreadyClaimed();
    error LoanNotExist();
    error LoanClosed();
    error BadKink();
    error MaxLessThanBase();
    error TreasuryZero();
    error BadOracleSig();
    error RateBelowMin();
    error AmountTooHigh();
    error ParamsMismatch();
    error HardStop();
    error BufferInsufficient();
    error CapZero();
    error CapExceeded();
    error RateBelowModel();
    error InterestNotSettled();
    error NoInterest();
    error NotBorrowerOrAdmin();
    error ERC1155ModuleNotSet();
    error LotMismatch();

    // ───────── access ─────────
    mapping(address => bool) public oracleSigners;      // oracle keys
    mapping(address => address) public unionLeader;     // union ⇒ leader

    modifier onlyOracleOrLeader(address unionAddr) {
        if (!(oracleSigners[msg.sender] || msg.sender == unionLeader[unionAddr])) revert NotOracleOrLeader();
        _;
    }

    // ───────── config ─────────
    address public treasury;

    // NEW: external 1155 module
    address public erc1155Module;
    event ERC1155ModuleSet(address indexed module);

    modifier onlyERC1155Module() {
        if (msg.sender != erc1155Module) revert ERC1155ModuleNotSet();
        _;
    }

    function setERC1155Module(address module_) external onlyOwner {
        erc1155Module = module_;
        emit ERC1155ModuleSet(module_);
    }

    // Senior capacity included in cap per union/token
    mapping(address => mapping(address => uint256)) public seniorCap; // union ⇒ token ⇒ cap

    // Rate model
    struct RateParams {
        uint16 baseRateBP;
        uint16 kinkUtilBP; // 0..10000
        uint16 slope1BP;
        uint16 slope2BP;
        uint16 maxRateBP;
    }
    mapping(address => RateParams) public rateParams; // token ⇒ params

    // ───────── accounting ─────────
    struct Market {
        uint128 supplyIndex;   // RAY (init 1e27)
        uint128 borrowIndex;   // reserved
        uint256 totalShares;
        uint256 totalBorrows;  // junior type-buckets only
        uint256 maxDeposited;  // historical max (for cap)
    }

    struct InvestorInfo {
        uint256 shares;
        uint128 entryIndex;
        uint128 unclaimed;
        uint256 lockedShares;  // in pending unbond requests
    }

    struct Loan {
        address borrower;
        address token;
        uint128 principal;
        uint16  rateBP;
        uint40  drawdownTs;
        uint40  harvestTs;     // unused (storage spacer)
        uint40  maturityTs;
        uint128 repaid;
        uint128 interestPaid;
        bool    liquidated;
        bool    defaulted;
        bytes32 loanType;
        bytes32 paramsHash;
    }

    struct Voucher {
        address borrower;
        address union;
        address token;
        uint256 maxAmount;
        uint16  minRateBP;
        uint256 nonce;
        bytes32 loanType;
        bytes32 paramsHash;
    }

    struct Union {
        string  name;
        bool    active;

        // Junior markets per {token, loanType}
        mapping(address => mapping(bytes32 => Market)) juniorByType;
        mapping(address => mapping(bytes32 => mapping(address => InvestorInfo))) investorsByType;
        mapping(bytes32 => Loan) loans;

        // UI helpers
        mapping(address => bytes32[]) loanTypesByToken; // token ⇒ [types]
        mapping(address => bool) tokenSeen;
    }

    mapping(address => Union) private unions;
    mapping(address => string) public unionLocation;
    mapping(address => bytes32[]) public loansByBorrower;

    // Tokens with junior deposits per union
    mapping(address => address[]) private unionTokens;

    // Aggregated cap base per {union, token}
    mapping(address => mapping(address => uint256)) private unionCapBase;

    // Senior markets
    mapping(address => Market) private seniorMarkets;         // token ⇒ market
    mapping(address => mapping(address => InvestorInfo)) private seniorInvestors; // token ⇒ investor ⇒ info
    address[] private seniorTokenList;

    // ───────── unbonding withdrawals ─────────
    struct WithdrawRequest {
        Tranche tranche;
        address investor;
        address unionAddr; // junior only
        address token;
        bytes32 loanType;  // junior only
        uint256 shares;
        uint256 erc1155LotId; // for in-kind via module
        bool    inKind1155;
        uint40  requestedAt;
        bool    claimed;

        // Liquidity buffer tracking:
        uint256 principalAtRequest;        // fixed at request time (0 if in-kind1155)
        bool    wasEverClaimableAccounted; // set when promoted into claimable counter
    }
    uint256 public nextWithdrawRequestId;
    mapping(uint256 => WithdrawRequest) public withdrawRequests;

    // Per-token liquidity buffer state
    mapping(address => uint16)  public bufferSafetyBP;       // e.g., 1000 = +10% on claimables
    mapping(address => uint256) public bufferSafetyFloor;    // absolute cushion
    mapping(address => uint256) public hardStopClaimable;    // 0 = disabled

    mapping(address => uint256) public pendingPrincipalTotal;      // sum of principalAtRequest for all open requests
    mapping(address => uint256) public pendingPrincipalClaimable;  // subset whose unbonding finished

    mapping(address => uint256[]) private withdrawQueueByToken;    // token ⇒ requestIds (chronological)
    mapping(address => uint256)   private withdrawQueueHead;       // index into queue

    // ───────── EIP-712 type hashes ─────────
    bytes32 private constant VOUCHER_TYPEHASH =
        keccak256("Voucher(address borrower,address union,address token,uint256 maxAmount,uint16 minRateBP,uint256 nonce,bytes32 loanType,bytes32 paramsHash)");
    // (QUOTE1155_TYPEHASH stays internal to core’s recover function; module calls our view.)

    // ───────── events ─────────
    event TreasuryUpdated(address indexed newTreasury);
    event OracleSignerUpdated(address indexed signer, bool allowed);
    event UnionLeaderSet(address indexed unionAddr, address indexed leader);
    event UnionActivated(address indexed unionAddr, string location);
    event UnionDeactivated(address indexed unionAddr);

    // Investments
    event Invested(Tranche tranche, address indexed unionAddr, address indexed investor, address indexed token, bytes32 loanType, uint256 amount, uint256 shares);

    // Unbonding
    event WithdrawRequested(uint256 indexed requestId, Tranche tranche, address indexed investor, address indexed token, address unionAddr, bytes32 loanType, uint256 shares, bool inKind1155, uint256 erc1155LotId, uint40 availableAt, uint256 principalAtRequest);
    event WithdrawClaimed(uint256 indexed requestId, uint256 principalOut, uint256 interestOut, bool inKind1155);

    // Loans
    event LoanClaimed(address indexed unionAddr, bytes32 indexed loanId, address indexed borrower, address token, uint256 principal, uint16 rateBP, bytes32 loanType, bytes32 paramsHash);
    event LoanAcceptedLowRate(address indexed unionAddr, bytes32 indexed loanId, uint16 rateBP);
    event MaturityReported(address indexed unionAddr, bytes32 indexed loanId, uint40 maturityTs);
    event LoanRepaid(address indexed unionAddr, bytes32 indexed loanId, address indexed payer, uint256 amount, uint256 interestPaidNow, uint256 principalPaidNow);
    event LoanDefaulted(address indexed unionAddr, bytes32 indexed loanId, uint256 juniorLossApplied, uint256 seniorLossApplied);
    event LoanRolledOver(address indexed unionAddr, bytes32 indexed loanId, uint16 newRateBP, uint40 newDrawdownTs);
    event LoanTransferred(address indexed unionAddr, bytes32 indexed loanId, address indexed newBorrower, uint16 newRateBP, uint40 newDrawdownTs);
    event LoanParams(bytes32 indexed loanId, bytes params);

    // Admin
    event RateParamsUpdated(address indexed token, uint16 baseRateBP, uint16 kinkUtilBP, uint16 slope1BP, uint16 slope2BP, uint16 maxRateBP);
    event SeniorCapUpdated(address indexed unionAddr, address indexed token, uint256 capAmount);
    event BufferParamsSet(address indexed token, uint16 safetyBP, uint256 safetyFloor);
    event HardStopClaimableSet(address indexed token, uint256 amount);
    event BufferSync(address indexed token, uint256 advanced, uint256 newHead, uint256 claimableNow);

    // ───────── init / upgrade ─────────
    function initialize(address _treasury, address _oracleSigner) public initializer {
        if (_treasury == address(0)) revert TreasuryZero();
        __Ownable_init(_oracleSigner);
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        __EIP712_init("GenericFund", "1.3");

        treasury = _treasury;
        emit TreasuryUpdated(_treasury);
    }

    function _authorizeUpgrade(address /*impl*/) internal override onlyOwner {}

    // ───────── admin / governance ─────────
    function setTreasury(address newTreasury) external onlyOwner {
        if (newTreasury == address(0)) revert TreasuryZero();
        treasury = newTreasury;
        emit TreasuryUpdated(newTreasury);
    }

    function setOracleSigner(address signer, bool allowed) external onlyOwner {
        oracleSigners[signer] = allowed;
        emit OracleSignerUpdated(signer, allowed);
    }

    function setUnionLeader(address unionAddr, address leader) external onlyOwner {
        unionLeader[unionAddr] = leader;
        emit UnionLeaderSet(unionAddr, leader);
    }

    function activateUnion(address unionAddr, string calldata location) external onlyOwner {
        unions[unionAddr].active = true;
        unionLocation[unionAddr] = location;
        emit UnionActivated(unionAddr, location);
    }

    function deactivateUnion(address unionAddr) external onlyOwner {
        unions[unionAddr].active = false;
        emit UnionDeactivated(unionAddr);
    }

    function setSeniorCap(address unionAddr, address token, uint256 capAmount) external onlyOwner {
        seniorCap[unionAddr][token] = capAmount;
        emit SeniorCapUpdated(unionAddr, token, capAmount);
    }

    function setRateParams(
        address token,
        uint16 baseRateBP,
        uint16 kinkUtilBP,
        uint16 slope1BP,
        uint16 slope2BP,
        uint16 maxRateBP
    ) external onlyOwner {
        if (kinkUtilBP == 0 || kinkUtilBP > 10000) revert BadKink();
        if (maxRateBP < baseRateBP) revert MaxLessThanBase();
        rateParams[token] = RateParams(baseRateBP, kinkUtilBP, slope1BP, slope2BP, maxRateBP);
        emit RateParamsUpdated(token, baseRateBP, kinkUtilBP, slope1BP, slope2BP, maxRateBP);
    }

    // ───────── tranche invest / withdraw / claim ─────────

    /// @notice Standard ERC20 invest (unchanged)
    function invest(Tranche tranche, address unionAddr, address token, bytes32 loanType, uint256 amount)
        external whenNotPaused nonReentrant
    {
        if (amount == 0) revert ZeroAmount();
        IERC20Metadata(token).safeTransferFrom(msg.sender, address(this), amount);

        if (tranche == Tranche.JUNIOR) {
            Union storage u = unions[unionAddr];
            if (!u.active) revert UnionInactive();

            Market storage m = u.juniorByType[token][loanType];
            if (m.supplyIndex == 0) {
                m.supplyIndex = uint128(RAY);
                if (!u.tokenSeen[token]) { u.tokenSeen[token] = true; unionTokens[unionAddr].push(token); }
                if (!_hasLoanType(u.loanTypesByToken[token], loanType)) u.loanTypesByToken[token].push(loanType);
            }

            uint256 shares = GenericFundMathLib.toShares(amount, m.supplyIndex);
            m.totalShares += shares;

            uint256 underlyingAfter = GenericFundMathLib.toUnderlying(m.totalShares, m.supplyIndex);
            if (underlyingAfter > m.maxDeposited) {
                uint256 delta = underlyingAfter - m.maxDeposited;
                m.maxDeposited = underlyingAfter;
                unionCapBase[unionAddr][token] += delta;
            }

            InvestorInfo storage info = u.investorsByType[token][loanType][msg.sender];
            _accrueInvestor(info, m.supplyIndex);
            info.shares += shares;

            emit Invested(Tranche.JUNIOR, unionAddr, msg.sender, token, loanType, amount, shares);

        } else {
            Market storage s = seniorMarkets[token];
            if (s.supplyIndex == 0) {
                s.supplyIndex = uint128(RAY);
                seniorTokenList.push(token);
            }

            uint256 shares = GenericFundMathLib.toShares(amount, s.supplyIndex);
            s.totalShares += shares;

            uint256 underlyingAfter = GenericFundMathLib.toUnderlying(s.totalShares, s.supplyIndex);
            if (underlyingAfter > s.maxDeposited) s.maxDeposited = underlyingAfter;

            InvestorInfo storage info = seniorInvestors[token][msg.sender];
            _accrueInvestor(info, s.supplyIndex);
            info.shares += shares;

            emit Invested(Tranche.SENIOR, address(0), msg.sender, token, bytes32(0), amount, shares);
        }
    }

    /// @notice Called by the ERC1155 module after it has escrowed the ERC1155 and verified the oracle quote.
    function mintJuniorFromQuote(
        address unionAddr,
        address token,
        bytes32 loanType,
        address investor,
        uint256 quoteAmount
    ) external whenNotPaused nonReentrant onlyERC1155Module returns (uint256 sharesOut) {
        if (quoteAmount == 0) revert ZeroAmount();

        Union storage u = unions[unionAddr];
        if (!u.active) revert UnionInactive();

        Market storage m = u.juniorByType[token][loanType];
        if (m.supplyIndex == 0) {
            m.supplyIndex = uint128(RAY);
            if (!u.tokenSeen[token]) { u.tokenSeen[token] = true; unionTokens[unionAddr].push(token); }
            if (!_hasLoanType(u.loanTypesByToken[token], loanType)) u.loanTypesByToken[token].push(loanType);
        }

        sharesOut = GenericFundMathLib.toShares(quoteAmount, m.supplyIndex);
        m.totalShares += sharesOut;

        uint256 underlyingAfter = GenericFundMathLib.toUnderlying(m.totalShares, m.supplyIndex);
        if (underlyingAfter > m.maxDeposited) {
            uint256 delta = underlyingAfter - m.maxDeposited;
            m.maxDeposited = underlyingAfter;
            unionCapBase[unionAddr][token] += delta;
        }

        InvestorInfo storage info = u.investorsByType[token][loanType][investor];
        _accrueInvestor(info, m.supplyIndex);
        info.shares += sharesOut;

        emit Invested(Tranche.JUNIOR, unionAddr, investor, token, loanType, quoteAmount, sharesOut);
    }

    // ── Unbonding (request → claim) with buffer tracking ──

    interface IERC1155Module {
        function validateLot(address owner, address unionAddr, address token, bytes32 loanType, uint256 shares, uint256 lotId) external view returns (bool);
        function redeemLot(address to, uint256 lotId, address unionAddr, address token, bytes32 loanType, uint256 shares) external;
    }

    function requestWithdrawJunior(
        address unionAddr,
        address token,
        bytes32 loanType,
        uint256 shares,
        bool inKind1155,
        uint256 erc1155LotId
    ) external whenNotPaused nonReentrant returns (uint256 reqId) {
        if (shares == 0) revert ZeroAmount();
        Union storage u = unions[unionAddr];
        if (!u.active) revert UnionInactive();
        Market storage m = u.juniorByType[token][loanType];
        if (m.supplyIndex == 0) revert MarketEmpty();

        InvestorInfo storage info = u.investorsByType[token][loanType][msg.sender];
        if (shares > info.shares - info.lockedShares) revert InsufficientUnlocked();

        if (inKind1155) {
            if (erc1155Module == address(0)) revert ERC1155ModuleNotSet();
            bool ok = IERC1155Module(erc1155Module).validateLot(msg.sender, unionAddr, token, loanType, shares, erc1155LotId);
            if (!ok) revert LotMismatch();
        } else {
            if (erc1155LotId != 0) revert LotMismatch();
        }

        _accrueInvestor(info, m.supplyIndex);
        info.lockedShares += shares;

        uint256 principalAtReq = inKind1155 ? 0 : GenericFundMathLib.toUnderlying(shares, m.supplyIndex);

        reqId = ++nextWithdrawRequestId;
        withdrawRequests[reqId] = WithdrawRequest({
            tranche: Tranche.JUNIOR,
            investor: msg.sender,
            unionAddr: unionAddr,
            token: token,
            loanType: loanType,
            shares: shares,
            erc1155LotId: erc1155LotId,
            inKind1155: inKind1155,
            requestedAt: uint40(block.timestamp),
            claimed: false,
            principalAtRequest: principalAtReq,
            wasEverClaimableAccounted: false
        });

        if (principalAtReq > 0) {
            pendingPrincipalTotal[token] += principalAtReq;
            withdrawQueueByToken[token].push(reqId);
        }

        emit WithdrawRequested(
            reqId, Tranche.JUNIOR, msg.sender, token, unionAddr, loanType, shares, inKind1155, erc1155LotId,
            uint40(block.timestamp + MIN_UNBONDING), principalAtReq
        );
    }

    function requestWithdrawSenior(address token, uint256 shares)
        external whenNotPaused nonReentrant returns (uint256 reqId)
    {
        if (shares == 0) revert ZeroAmount();
        Market storage s = seniorMarkets[token];
        if (s.supplyIndex == 0) revert SeniorEmpty();

        InvestorInfo storage info = seniorInvestors[token][msg.sender];
        if (shares > info.shares - info.lockedShares) revert InsufficientUnlocked();

        _accrueInvestor(info, s.supplyIndex);
        info.lockedShares += shares;

        uint256 principalAtReq = GenericFundMathLib.toUnderlying(shares, s.supplyIndex);

        reqId = ++nextWithdrawRequestId;
        withdrawRequests[reqId] = WithdrawRequest({
            tranche: Tranche.SENIOR,
            investor: msg.sender,
            unionAddr: address(0),
            token: token,
            loanType: bytes32(0),
            shares: shares,
            erc1155LotId: 0,
            inKind1155: false,
            requestedAt: uint40(block.timestamp),
            claimed: false,
            principalAtRequest: principalAtReq,
            wasEverClaimableAccounted: false
        });

        pendingPrincipalTotal[token] += principalAtReq;
        withdrawQueueByToken[token].push(reqId);

        emit WithdrawRequested(
            reqId, Tranche.SENIOR, msg.sender, token, address(0), bytes32(0), shares, false, 0,
            uint40(block.timestamp + MIN_UNBONDING), principalAtReq
        );
    }

    function claimWithdraw(uint256 requestId) external whenNotPaused nonReentrant {
        WithdrawRequest storage R = withdrawRequests[requestId];
        if (R.claimed) revert AlreadyClaimed();
        if (R.investor != msg.sender) revert NotOwner();
        if (block.timestamp < uint256(R.requestedAt) + MIN_UNBONDING) revert NotAvailable();

        uint256 principalOut = 0;
        uint256 interestOut = 0;

        // Reduce buffer counters (safe regardless of claimable-accounted state)
        if (R.principalAtRequest > 0) {
            pendingPrincipalTotal[R.token] = pendingPrincipalTotal[R.token] >= R.principalAtRequest
                ? pendingPrincipalTotal[R.token] - R.principalAtRequest
                : 0;

            if (R.wasEverClaimableAccounted) {
                pendingPrincipalClaimable[R.token] = pendingPrincipalClaimable[R.token] >= R.principalAtRequest
                    ? pendingPrincipalClaimable[R.token] - R.principalAtRequest
                    : 0;
            }
        }

        if (R.tranche == Tranche.JUNIOR) {
            Union storage u = unions[R.unionAddr];
            Market storage m = u.juniorByType[R.token][R.loanType];
            InvestorInfo storage info = u.investorsByType[R.token][R.loanType][msg.sender];

            _accrueInvestor(info, m.supplyIndex);

            // pro-rata interest payout on redeemed shares
            interestOut = info.shares == 0 ? 0 : (uint256(info.unclaimed) * R.shares) / info.shares;
            if (interestOut > 0) {
                info.unclaimed -= uint128(interestOut);
                IERC20Metadata(R.token).safeTransfer(msg.sender, interestOut);
            }

            if (info.lockedShares < R.shares) revert InsufficientUnlocked();
            info.lockedShares -= R.shares;
            info.shares -= R.shares;

            if (R.inKind1155) {
                if (erc1155Module == address(0)) revert ERC1155ModuleNotSet();
                IERC1155Module(erc1155Module).redeemLot(msg.sender, R.erc1155LotId, R.unionAddr, R.token, R.loanType, R.shares);
            } else {
                principalOut = GenericFundMathLib.toUnderlying(R.shares, m.supplyIndex);
                uint256 bal = IERC20Metadata(R.token).balanceOf(address(this));
                if (bal < principalOut) revert InsufficientLiquidity();
                IERC20Metadata(R.token).safeTransfer(msg.sender, principalOut);
                m.totalShares -= R.shares;
            }

        } else {
            Market storage s = seniorMarkets[R.token];
            InvestorInfo storage info = seniorInvestors[R.token][msg.sender];

            _accrueInvestor(info, s.supplyIndex);

            interestOut = info.shares == 0 ? 0 : (uint256(info.unclaimed) * R.shares) / info.shares;
            if (interestOut > 0) {
                info.unclaimed -= uint128(interestOut);
                IERC20Metadata(R.token).safeTransfer(msg.sender, interestOut);
            }

            if (info.lockedShares < R.shares) revert InsufficientUnlocked();
            info.lockedShares -= R.shares;
            info.shares -= R.shares;

            principalOut = GenericFundMathLib.toUnderlying(R.shares, s.supplyIndex);
            uint256 bal = IERC20Metadata(R.token).balanceOf(address(this));
            if (bal < principalOut) revert InsufficientLiquidity();
            IERC20Metadata(R.token).safeTransfer(msg.sender, principalOut);
            s.totalShares -= R.shares;
        }

        R.claimed = true;
        emit WithdrawClaimed(requestId, principalOut, interestOut, R.inKind1155);
    }

    // ───────── liquidity buffer / loans / internals — unchanged from your trimmed core ─────────
    // (Omitted here for brevity — keep your existing: syncPendingClaimable, getLiquidityBufferState,
    //  claimLoan/_claimLoanInternal, repayLoan, reportMaturity, defaultLoan, transferLoan,
    //  _accrueInvestor, _creditInterestTranches, _applyLossToMarket (remember the uint256→uint128 cast),
    //  aggregateBorrowsForUnionToken, _quoteRateBP, _hasLoanType, and the remaining slim views + getters.)
    //
    // Make sure those still use GenericFundMathLib.*

    // Example applyLoss (with cast fix):
    function _applyLossToMarket(Market storage m, uint256 loss) private returns (uint256 applied) {
        if (loss == 0 || m.supplyIndex == 0 || m.totalShares == 0) return 0;
        uint256 underlying = GenericFundMathLib.toUnderlying(m.totalShares, m.supplyIndex);
        if (underlying == 0) return 0;
        uint256 newIdx256;
        (applied, newIdx256) = GenericFundMathLib.haircutIndex(m.supplyIndex, underlying, loss);
        m.supplyIndex = uint128(newIdx256);
        return applied;
    }

    function _accrueInvestor(InvestorInfo storage info, uint256 currentSupplyIndex) private {
        if (info.shares == 0) { info.entryIndex = uint128(currentSupplyIndex); return; }
        if (currentSupplyIndex <= info.entryIndex) { info.entryIndex = uint128(currentSupplyIndex); return; }
        uint256 deltaIndex = currentSupplyIndex - info.entryIndex; // RAY
        uint256 pending    = (info.shares * deltaIndex) / RAY;
        info.unclaimed    += uint128(pending);
        info.entryIndex    = uint128(currentSupplyIndex);
    }

    // views kept: version, previewRateBP, getLoanTypesForUnionToken, getTokenListJunior/Senior,
    // getLoansByBorrower, isOracleSigner, recoverVoucherSigner, recoverQuote1155Signer,
    // and the Lite getters for the viewer.

    // QUOTE1155 signer recovery for the module/viewer
    bytes32 private constant QUOTE1155_TYPEHASH =
        keccak256("Quote1155(address union,address token,bytes32 loanType,address investor,address collection,uint256 id,uint256 amount1155,uint256 quoteAmount,uint256 nonce,uint40 expiry)");

    function recoverQuote1155Signer(
        address unionAddr,
        address token,
        bytes32 loanType,
        address investor,
        address collection,
        uint256 id,
        uint256 amount1155,
        uint256 quoteAmount,
        uint256 nonce,
        uint40 expiry,
        bytes calldata sig
    ) external view returns (address) {
        bytes32 digest = _hashTypedDataV4(keccak256(abi.encode(
            QUOTE1155_TYPEHASH,
            unionAddr, token, loanType, investor, collection, id, amount1155, quoteAmount, nonce, expiry
        )));
        return ECDSA.recover(digest, sig);
    }

    // ---- Lite structs & getters for viewer (same as before) ----
    struct MarketLite { uint128 supplyIndex; uint256 totalShares; uint256 totalBorrows; uint256 maxDeposited; }
    struct InvestorLite { uint256 shares; uint128 entryIndex; uint128 unclaimed; uint256 lockedShares; }

    function getJuniorMarketLite(address unionAddr, address token, bytes32 loanType)
        external view returns (MarketLite memory)
    {
        Market storage m = unions[unionAddr].juniorByType[token][loanType];
        return MarketLite({ supplyIndex: m.supplyIndex, totalShares: m.totalShares, totalBorrows: m.totalBorrows, maxDeposited: m.maxDeposited });
    }

    function getInvestorJuniorRaw(address unionAddr, address token, bytes32 loanType, address investor)
        external view returns (InvestorLite memory)
    {
        InvestorInfo storage info = unions[unionAddr].investorsByType[token][loanType][investor];
        return InvestorLite({ shares: info.shares, entryIndex: info.entryIndex, unclaimed: info.unclaimed, lockedShares: info.lockedShares });
    }

    function getSeniorMarketLite(address token) external view returns (MarketLite memory) {
        Market storage s = seniorMarkets[token];
        return MarketLite({ supplyIndex: s.supplyIndex, totalShares: s.totalShares, totalBorrows: 0, maxDeposited: s.maxDeposited });
    }

    function getInvestorSeniorRaw(address token, address investor)
        external view returns (InvestorLite memory)
    {
        InvestorInfo storage info = seniorInvestors[token][investor];
        return InvestorLite({ shares: info.shares, entryIndex: info.entryIndex, unclaimed: info.unclaimed, lockedShares: info.lockedShares });
    }

    function getUnionCapBasePublic(address unionAddr, address token) external view returns (uint256) {
        return unionCapBase[unionAddr][token];
    }

    function version() external pure returns (string memory) { return "v1.3"; }
    function isOracleSigner(address a) external view returns (bool) { return oracleSigners[a]; }

    // (Keep your other views like previewRateBP, etc.)
}

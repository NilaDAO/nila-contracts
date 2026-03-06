// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

/*
 * GenericFundUpgradeable — Core v1.3 (split)
 * - ERC1155 flows removed → handled by separate module.
 * - Math moved to GenericFundMathLib (internal only, no linking).
 * - Viewer handles heavy views; Core only exposes slim getters.
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

    // ───────── access ─────────
    mapping(address => bool) public oracleSigners;
    mapping(address => address) public unionLeader;

    modifier onlyOracleOrLeader(address unionAddr) {
        require(oracleSigners[msg.sender] || msg.sender == unionLeader[unionAddr], "not oracle/leader");
        _;
    }

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

    // ───────── config ─────────
    address public treasury;

    mapping(address => mapping(address => uint256)) public seniorCap;

    struct RateParams {
        uint16 baseRateBP;
        uint16 kinkUtilBP;
        uint16 slope1BP;
        uint16 slope2BP;
        uint16 maxRateBP;
    }
    mapping(address => RateParams) public rateParams;

    // ───────── accounting ─────────
    struct Market {
        uint128 supplyIndex; // RAY
        uint128 borrowIndex; // reserved
        uint256 totalShares;
        uint256 totalBorrows;
        uint256 maxDeposited;
    }

    struct InvestorInfo {
        uint256 shares;
        uint128 entryIndex;
        uint128 unclaimed;
        uint256 lockedShares;
    }

    struct Loan {
        address borrower;
        address token;
        uint128 principal;
        uint16  rateBP;
        uint40  drawdownTs;
        uint40  harvestTs; // spacer
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
        uint16 minRateBP;
        uint256 nonce;
        bytes32 loanType;
        bytes32 paramsHash;
    }

    struct Union {
        string  name;
        bool    active;
        mapping(address => mapping(bytes32 => Market)) juniorByType;
        mapping(address => mapping(bytes32 => mapping(address => InvestorInfo))) investorsByType;
        mapping(bytes32 => Loan) loans;
        mapping(address => bytes32[]) loanTypesByToken;
        mapping(address => bool) tokenSeen;
    }

    mapping(address => Union) private unions;
    mapping(address => string) public unionLocation;
    mapping(address => bytes32[]) public loansByBorrower;
    mapping(address => address[]) private unionTokens;
    mapping(address => mapping(address => uint256)) private unionCapBase;

    mapping(address => Market) private seniorMarkets;
    mapping(address => mapping(address => InvestorInfo)) private seniorInvestors;
    address[] private seniorTokenList;

    // ───────── unbonding withdrawals ─────────
    struct WithdrawRequest {
        Tranche tranche;
        address investor;
        address unionAddr;
        address token;
        bytes32 loanType;
        uint256 shares;
        uint256 erc1155LotId; // unused in core
        bool    inKind1155;
        uint40  requestedAt;
        bool    claimed;
        uint256 principalAtRequest;
        bool    wasEverClaimableAccounted;
    }
    uint256 public nextWithdrawRequestId;
    mapping(uint256 => WithdrawRequest) public withdrawRequests;

    mapping(address => uint16)  public bufferSafetyBP;
    mapping(address => uint256) public bufferSafetyFloor;
    mapping(address => uint256) public hardStopClaimable;

    mapping(address => uint256) public pendingPrincipalTotal;
    mapping(address => uint256) public pendingPrincipalClaimable;

    mapping(address => uint256[]) private withdrawQueueByToken;
    mapping(address => uint256)   private withdrawQueueHead;

    // ───────── events ─────────
    event TreasuryUpdated(address indexed newTreasury);
    event OracleSignerUpdated(address indexed signer, bool allowed);
    event UnionLeaderSet(address indexed unionAddr, address indexed leader);
    event UnionActivated(address indexed unionAddr, string location);
    event UnionDeactivated(address indexed unionAddr);

    event Invested(Tranche tranche, address indexed unionAddr, address indexed investor, address indexed token, bytes32 loanType, uint256 amount, uint256 shares);
    event WithdrawRequested(uint256 indexed requestId, Tranche tranche, address indexed investor, address indexed token, address unionAddr, bytes32 loanType, uint256 shares, bool inKind1155, uint256 erc1155LotId, uint40 availableAt, uint256 principalAtRequest);
    event WithdrawClaimed(uint256 indexed requestId, uint256 principalOut, uint256 interestOut, bool inKind1155);

    event LoanClaimed(address indexed unionAddr, bytes32 indexed loanId, address indexed borrower, address token, uint256 principal, uint16 rateBP, bytes32 loanType, bytes32 paramsHash);
    event LoanAcceptedLowRate(address indexed unionAddr, bytes32 indexed loanId, uint16 rateBP);
    event MaturityReported(address indexed unionAddr, bytes32 indexed loanId, uint40 maturityTs);
    event LoanRepaid(address indexed unionAddr, bytes32 indexed loanId, address indexed payer, uint256 amount, uint256 interestPaidNow, uint256 principalPaidNow);
    event LoanDefaulted(address indexed unionAddr, bytes32 indexed loanId, uint256 juniorLossApplied, uint256 seniorLossApplied);
    event LoanRolledOver(address indexed unionAddr, bytes32 indexed loanId, uint16 newRateBP, uint40 newDrawdownTs);
    event LoanTransferred(address indexed unionAddr, bytes32 indexed loanId, address indexed newBorrower, uint16 newRateBP, uint40 newDrawdownTs);
    event LoanParams(bytes32 indexed loanId, bytes params);

    event BufferParamsSet(address indexed token, uint16 safetyBP, uint256 safetyFloor);
    event HardStopClaimableSet(address indexed token, uint256 amount);
    event BufferSync(address indexed token, uint256 advanced, uint256 newHead, uint256 claimableNow);

    // ───────── INIT ─────────
    function initialize(address _treasury, address _oracleSigner) public initializer {
        __Ownable_init(_oracleSigner);
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        __EIP712_init("GenericFund", "1.3");
        treasury = _treasury;
        oracleSigners[_oracleSigner] = true;
        emit TreasuryUpdated(_treasury);
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    // ───────── ADMIN ─────────
    function setTreasury(address newTreasury) external onlyOwner {
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
    }

    function setRateParams(address token,uint16 base,uint16 kink,uint16 slope1,uint16 slope2,uint16 maxR) external onlyOwner {
        rateParams[token] = RateParams(base,kink,slope1,slope2,maxR);
    }

    function setBufferParams(address token,uint16 safetyBP,uint256 safetyFloor) external onlyOwner {
        bufferSafetyBP[token]=safetyBP; bufferSafetyFloor[token]=safetyFloor;
        emit BufferParamsSet(token,safetyBP,safetyFloor);
    }

    function setHardStopClaimable(address token,uint256 amount) external onlyOwner {
        hardStopClaimable[token]=amount; emit HardStopClaimableSet(token,amount);
    }

    // ───────── core functions ─────────
    function invest(
        Tranche tranche,
        address unionAddr,
        address token,
        bytes32 loanType,
        uint256 amount
    ) external whenNotPaused nonReentrant {
        require(amount > 0, "zero amount");
        IERC20Metadata(token).safeTransferFrom(
            msg.sender,
            address(this),
            amount
        );

        if (tranche == Tranche.JUNIOR) {
            Union storage u = unions[unionAddr];
            require(u.active, "union inactive");

            Market storage m = u.juniorByType[token][loanType];
            if (m.supplyIndex == 0) {
                m.supplyIndex = uint128(RAY);
                if (!u.tokenSeen[token]) {
                    u.tokenSeen[token] = true;
                    unionTokens[unionAddr].push(token);
                }
                if (!_hasLoanType(u.loanTypesByToken[token], loanType))
                    u.loanTypesByToken[token].push(loanType);
            }

            uint256 shares = _underlyingToShares(amount, m.supplyIndex);
            m.totalShares += shares;

            uint256 underlyingAfter = _sharesToUnderlying(
                m.totalShares,
                m.supplyIndex
            );
            if (underlyingAfter > m.maxDeposited) {
                uint256 delta = underlyingAfter - m.maxDeposited;
                m.maxDeposited = underlyingAfter;
                unionCapBase[unionAddr][token] += delta;
            }

            InvestorInfo storage info = u.investorsByType[token][loanType][
                msg.sender
            ];
            _accrueInvestor(info, m.supplyIndex);
            info.shares += shares;

            emit Invested(
                Tranche.JUNIOR,
                unionAddr,
                msg.sender,
                token,
                loanType,
                amount,
                shares
            );
        } else {
            Market storage s = seniorMarkets[token];
            if (s.supplyIndex == 0) {
                s.supplyIndex = uint128(RAY);
                seniorTokenList.push(token);
            }

            uint256 shares = _underlyingToShares(amount, s.supplyIndex);
            s.totalShares += shares;

            uint256 underlyingAfter = _sharesToUnderlying(
                s.totalShares,
                s.supplyIndex
            );
            if (underlyingAfter > s.maxDeposited)
                s.maxDeposited = underlyingAfter;

            InvestorInfo storage info = seniorInvestors[token][msg.sender];
            _accrueInvestor(info, s.supplyIndex);
            info.shares += shares;

            emit Invested(
                Tranche.SENIOR,
                address(0),
                msg.sender,
                token,
                bytes32(0),
                amount,
                shares
            );
        }
    }

    /// @notice Invest ERC1155 into a JUNIOR bucket (valued by oracle quote).
    function investJunior1155(
        address unionAddr,
        address token,
        bytes32 loanType,
        address collection,
        uint256 id,
        uint256 amount1155,
        uint256 quoteAmount,
        uint256 nonce,
        uint40 expiry,
        bytes calldata oracleSig
    ) external whenNotPaused nonReentrant {
        require(amount1155 > 0 && quoteAmount > 0, "bad amounts");
        require(unions[unionAddr].active, "union inactive");
        require(
            is1155Allowed[unionAddr][token][loanType][collection][id],
            "1155 not allowed"
        );
        require(block.timestamp <= expiry, "quote expired");
        require(!used1155Nonces[msg.sender][nonce], "nonce used");

        // verify oracle quote
        bytes32 digest = _hashTypedDataV4(
            keccak256(
                abi.encode(
                    QUOTE1155_TYPEHASH,
                    unionAddr,
                    token,
                    loanType,
                    msg.sender,
                    collection,
                    id,
                    amount1155,
                    quoteAmount,
                    nonce,
                    expiry
                )
            )
        );
        address signer = ECDSA.recover(digest, oracleSig);
        require(oracleSigners[signer], "bad oracle sig");
        used1155Nonces[msg.sender][nonce] = true;

        // escrow 1155
        IERC1155(collection).safeTransferFrom(
            msg.sender,
            address(this),
            id,
            amount1155,
            ""
        );

        // credit junior shares
        Union storage u = unions[unionAddr];
        Market storage m = u.juniorByType[token][loanType];
        if (m.supplyIndex == 0) {
            m.supplyIndex = uint128(RAY);
            if (!u.tokenSeen[token]) {
                u.tokenSeen[token] = true;
                unionTokens[unionAddr].push(token);
            }
            if (!_hasLoanType(u.loanTypesByToken[token], loanType))
                u.loanTypesByToken[token].push(loanType);
        }

        uint256 shares = _underlyingToShares(quoteAmount, m.supplyIndex);
        m.totalShares += shares;

        uint256 underlyingAfter = _sharesToUnderlying(
            m.totalShares,
            m.supplyIndex
        );
        if (underlyingAfter > m.maxDeposited) {
            uint256 delta = underlyingAfter - m.maxDeposited;
            m.maxDeposited = underlyingAfter;
            unionCapBase[unionAddr][token] += delta;
        }

        InvestorInfo storage info = u.investorsByType[token][loanType][
            msg.sender
        ];
        _accrueInvestor(info, m.supplyIndex);
        info.shares += shares;

        // lot record for in-kind redemption
        uint256 lotId = ++nextLotId;
        lots[lotId] = ERC1155Lot({
            owner: msg.sender,
            unionAddr: unionAddr,
            token: token,
            loanType: loanType,
            collection: collection,
            id: id,
            amount1155: amount1155,
            sharesMinted: shares,
            active: true
        });

        emit Invested1155(
            unionAddr,
            msg.sender,
            token,
            loanType,
            collection,
            id,
            amount1155,
            quoteAmount,
            shares
        );
        emit Invested(
            Tranche.JUNIOR,
            unionAddr,
            msg.sender,
            token,
            loanType,
            quoteAmount,
            shares
        );
    }

    // ── Unbonding (request → claim) with buffer tracking ──
    function requestWithdrawJunior(
        address unionAddr,
        address token,
        bytes32 loanType,
        uint256 shares,
        bool inKind1155,
        uint256 erc1155LotId
    ) external whenNotPaused nonReentrant returns (uint256 reqId) {
        require(shares > 0, "zero shares");
        Union storage u = unions[unionAddr];
        require(u.active, "union inactive");
        Market storage m = u.juniorByType[token][loanType];
        require(m.supplyIndex != 0, "market empty");

        InvestorInfo storage info = u.investorsByType[token][loanType][
            msg.sender
        ];
        require(
            shares <= info.shares - info.lockedShares,
            "insufficient unlocked"
        );

        if (inKind1155) {
            ERC1155Lot storage L = lots[erc1155LotId];
            require(L.active && L.owner == msg.sender, "bad lot");
            require(
                L.unionAddr == unionAddr &&
                    L.token == token &&
                    L.loanType == loanType,
                "lot mismatch"
            );
            require(shares == L.sharesMinted, "must unbond full lot shares");
        } else {
            require(erc1155LotId == 0, "lotId only for in-kind");
        }

        _accrueInvestor(info, m.supplyIndex);
        info.lockedShares += shares;

        uint256 principalAtReq = inKind1155
            ? 0
            : _sharesToUnderlying(shares, m.supplyIndex);

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

        // buffer bookkeeping
        if (principalAtReq > 0) {
            pendingPrincipalTotal[token] += principalAtReq;
            withdrawQueueByToken[token].push(reqId);
        }

        emit WithdrawRequested(
            reqId,
            Tranche.JUNIOR,
            msg.sender,
            token,
            unionAddr,
            loanType,
            shares,
            inKind1155,
            erc1155LotId,
            uint40(block.timestamp + MIN_UNBONDING),
            principalAtReq
        );
    }

    function requestWithdrawSenior(
        address token,
        uint256 shares
    ) external whenNotPaused nonReentrant returns (uint256 reqId) {
        require(shares > 0, "zero shares");
        Market storage s = seniorMarkets[token];
        require(s.supplyIndex != 0, "senior empty");

        InvestorInfo storage info = seniorInvestors[token][msg.sender];
        require(
            shares <= info.shares - info.lockedShares,
            "insufficient unlocked"
        );

        _accrueInvestor(info, s.supplyIndex);
        info.lockedShares += shares;

        uint256 principalAtReq = _sharesToUnderlying(shares, s.supplyIndex);

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
            reqId,
            Tranche.SENIOR,
            msg.sender,
            token,
            address(0),
            bytes32(0),
            shares,
            false,
            0,
            uint40(block.timestamp + MIN_UNBONDING),
            principalAtReq
        );
    }

    function claimWithdraw(
        uint256 requestId
    ) external whenNotPaused nonReentrant {
        WithdrawRequest storage R = withdrawRequests[requestId];
        require(!R.claimed, "claimed");
        require(R.investor == msg.sender, "not owner");
        require(
            block.timestamp >= uint256(R.requestedAt) + MIN_UNBONDING,
            "not yet available"
        );

        uint256 principalOut = 0;
        uint256 interestOut = 0;

        // Reduce buffer counters (safe regardless of claimable-accounted state)
        if (R.principalAtRequest > 0) {
            pendingPrincipalTotal[R.token] = pendingPrincipalTotal[R.token] >=
                R.principalAtRequest
                ? pendingPrincipalTotal[R.token] - R.principalAtRequest
                : 0;

            if (R.wasEverClaimableAccounted) {
                pendingPrincipalClaimable[R.token] = pendingPrincipalClaimable[
                    R.token
                ] >= R.principalAtRequest
                    ? pendingPrincipalClaimable[R.token] - R.principalAtRequest
                    : 0;
            }
        }

        if (R.tranche == Tranche.JUNIOR) {
            Union storage u = unions[R.unionAddr];
            Market storage m = u.juniorByType[R.token][R.loanType];
            InvestorInfo storage info = u.investorsByType[R.token][R.loanType][
                msg.sender
            ];

            _accrueInvestor(info, m.supplyIndex);

            // pro-rata interest payout on redeemed shares
            interestOut = info.shares == 0
                ? 0
                : (uint256(info.unclaimed) * R.shares) / info.shares;
            if (interestOut > 0) {
                info.unclaimed -= uint128(interestOut);
                IERC20Metadata(R.token).safeTransfer(msg.sender, interestOut);
            }

            require(info.lockedShares >= R.shares, "locked<shares");
            info.lockedShares -= R.shares;
            info.shares -= R.shares;

            if (R.inKind1155) {
                // return the referenced lot, no principal ERC20
                ERC1155Lot storage L = lots[R.erc1155LotId];
                require(L.active && L.owner == msg.sender, "lot invalid");
                require(
                    L.unionAddr == R.unionAddr &&
                        L.token == R.token &&
                        L.loanType == R.loanType,
                    "lot mismatch"
                );
                require(L.sharesMinted == R.shares, "lot shares mismatch");
                IERC1155(L.collection).safeTransferFrom(
                    address(this),
                    msg.sender,
                    L.id,
                    L.amount1155,
                    ""
                );
                L.active = false;
            } else {
                principalOut = _sharesToUnderlying(R.shares, m.supplyIndex);
                uint256 bal = IERC20Metadata(R.token).balanceOf(address(this));
                require(bal >= principalOut, "insufficient liquidity");
                IERC20Metadata(R.token).safeTransfer(msg.sender, principalOut);
                m.totalShares -= R.shares;
            }
        } else {
            Market storage s = seniorMarkets[R.token];
            InvestorInfo storage info = seniorInvestors[R.token][msg.sender];

            _accrueInvestor(info, s.supplyIndex);

            interestOut = info.shares == 0
                ? 0
                : (uint256(info.unclaimed) * R.shares) / info.shares;
            if (interestOut > 0) {
                info.unclaimed -= uint128(interestOut);
                IERC20Metadata(R.token).safeTransfer(msg.sender, interestOut);
            }

            require(info.lockedShares >= R.shares, "locked<shares");
            info.lockedShares -= R.shares;
            info.shares -= R.shares;

            principalOut = _sharesToUnderlying(R.shares, s.supplyIndex);
            uint256 bal = IERC20Metadata(R.token).balanceOf(address(this));
            require(bal >= principalOut, "insufficient liquidity");
            IERC20Metadata(R.token).safeTransfer(msg.sender, principalOut);
            s.totalShares -= R.shares;
        }

        R.claimed = true;
        emit WithdrawClaimed(
            requestId,
            principalOut,
            interestOut,
            R.inKind1155
        );
    }

    // Interest-only claim
    function claimInterest(
        Tranche tranche,
        address unionAddr,
        address token,
        bytes32 loanType
    ) external whenNotPaused nonReentrant {
        if (tranche == Tranche.JUNIOR) {
            Union storage u = unions[unionAddr];
            Market storage m = u.juniorByType[token][loanType];
            require(m.supplyIndex != 0, "market empty");

            InvestorInfo storage info = u.investorsByType[token][loanType][
                msg.sender
            ];
            _accrueInvestor(info, m.supplyIndex);

            uint256 payout = info.unclaimed;
            require(payout > 0, "no interest");
            info.unclaimed = 0;

            IERC20Metadata(token).safeTransfer(msg.sender, payout);
            emit Invested(
                Tranche.JUNIOR,
                unionAddr,
                msg.sender,
                token,
                loanType,
                0,
                0
            ); // (light beacon; optional)
        } else {
            Market storage s = seniorMarkets[token];
            require(s.supplyIndex != 0, "senior empty");
            InvestorInfo storage info = seniorInvestors[token][msg.sender];
            _accrueInvestor(info, s.supplyIndex);

            uint256 payout = info.unclaimed;
            require(payout > 0, "no interest");
            info.unclaimed = 0;

            IERC20Metadata(token).safeTransfer(msg.sender, payout);
        }
    }

    // ───────── liquidity buffer: sync & view ─────────

    /// @notice Promote finished unbond requests (by timestamp) into claimable set; bounded by maxIter.
    function syncPendingClaimable(address token, uint256 maxIter) external {
        _syncPendingClaimable(token, maxIter);
    }

    function _syncPendingClaimable(address token, uint256 maxIter) internal {
        uint256[] storage Q = withdrawQueueByToken[token];
        uint256 head = withdrawQueueHead[token];
        uint256 advanced = 0;

        while (head < Q.length && advanced < maxIter) {
            uint256 reqId = Q[head];
            WithdrawRequest storage R = withdrawRequests[reqId];

            // If already accounted or claimed, advance head and continue
            if (R.wasEverClaimableAccounted || R.claimed) {
                head++;
                advanced++;
                continue;
            }

            uint256 availableAt = uint256(R.requestedAt) + MIN_UNBONDING;
            if (block.timestamp < availableAt) break;

            // promote into claimable
            if (R.principalAtRequest > 0) {
                pendingPrincipalClaimable[token] += R.principalAtRequest;
            }
            R.wasEverClaimableAccounted = true;

            head++;
            advanced++;
        }

        if (advanced > 0) {
            withdrawQueueHead[token] = head;
            emit BufferSync(
                token,
                advanced,
                head,
                pendingPrincipalClaimable[token]
            );
        }
    }

    function getLiquidityBufferState(
        address token
    )
        external
        view
        returns (
            uint16 safetyBP,
            uint256 safetyFloor,
            uint256 claimable,
            uint256 totalPending,
            uint256 hardStop,
            uint256 queueHead,
            uint256 queueLen
        )
    {
        safetyBP = bufferSafetyBP[token];
        safetyFloor = bufferSafetyFloor[token];
        claimable = pendingPrincipalClaimable[token];
        totalPending = pendingPrincipalTotal[token];
        hardStop = hardStopClaimable[token];
        queueHead = withdrawQueueHead[token];
        queueLen = withdrawQueueByToken[token].length;
    }

    // ───────── loan lifecycle ─────────
    function claimLoan(
        Voucher calldata v,
        uint256 chosenAmount,
        uint16 chosenRateBP,
        bytes calldata params,
        bytes calldata sig
    ) external whenNotPaused nonReentrant {
        _claimLoanInternal(
            v,
            chosenAmount,
            chosenRateBP,
            params,
            sig,
            /*bypassMinRate=*/ false,
            /*callerIsAdmin=*/ false
        );
    }

    function acceptLowRateLoan(
        Voucher calldata v,
        uint256 chosenAmount,
        uint16 chosenRateBP,
        bytes calldata params,
        bytes calldata sig
    ) external whenNotPaused nonReentrant onlyOracleOrLeader(v.union) {
        _claimLoanInternal(
            v,
            chosenAmount,
            chosenRateBP,
            params,
            sig,
            /*bypassMinRate=*/ true,
            /*callerIsAdmin=*/ true
        );
        bytes32 loanId = keccak256(abi.encode(v));
        emit LoanAcceptedLowRate(v.union, loanId, chosenRateBP);
    }

    function _claimLoanInternal(
        Voucher calldata v,
        uint256 chosenAmount,
        uint16 chosenRateBP,
        bytes calldata params,
        bytes calldata sig,
        bool bypassMinRate,
        bool callerIsAdmin
    ) internal {
        require(
            msg.sender == v.borrower || callerIsAdmin,
            "not borrower/admin"
        );
        require(
            chosenAmount > 0 && chosenAmount <= v.maxAmount,
            "amount too high"
        );
        if (!bypassMinRate) require(chosenRateBP >= v.minRateBP, "rate<min");
        require(keccak256(params) == v.paramsHash, "params mismatch");

        // oracle signature over voucher
        bytes32 digest = _hashTypedDataV4(
            keccak256(
                abi.encode(
                    VOUCHER_TYPEHASH,
                    v.borrower,
                    v.union,
                    v.token,
                    v.maxAmount,
                    v.minRateBP,
                    v.nonce,
                    v.loanType,
                    v.paramsHash
                )
            )
        );
        address signer = ECDSA.recover(digest, sig);
        require(oracleSigners[signer], "bad oracle sig");

        bytes32 loanId = keccak256(abi.encode(v));
        Union storage u = unions[v.union];
        require(u.active, "union inactive");
        require(u.loans[loanId].drawdownTs == 0, "loan exists");

        // earmarked junior market must exist
        Market storage mJ = u.juniorByType[v.token][v.loanType];
        require(mJ.supplyIndex != 0, "loanType market empty");

        // sync buffer for this token (small bounded step)
        _syncPendingClaimable(v.token, 10);

        // buffer hard stop (optional)
        uint256 hs = hardStopClaimable[v.token];
        if (hs > 0)
            require(
                pendingPrincipalClaimable[v.token] < hs,
                "buffer: hard stop"
            );

        // buffer reserve requirement
        uint256 available = IERC20Metadata(v.token).balanceOf(address(this));
        uint256 requiredReserve = (pendingPrincipalClaimable[v.token] *
            (10000 + bufferSafetyBP[v.token])) /
            10000 +
            bufferSafetyFloor[v.token];

        require(
            available >= chosenAmount + requiredReserve,
            "buffer: insufficient liquidity"
        );

        // borrow cap & rate model checks
        uint256 capBase = unionCapBase[v.union][v.token] +
            seniorCap[v.union][v.token];
        uint256 cap = 2 * capBase;
        require(cap > 0, "cap=0");

        if (!callerIsAdmin) {
            uint16 modelRate = _quoteRateBP(v.union, v.token, chosenAmount);
            require(chosenRateBP >= modelRate, "rate<model");
        }

        // aggregate cap check
        require(
            (aggregateBorrowsForUnionToken(v.union, v.token) + chosenAmount) <=
                cap,
            "cap exceeded"
        );

        // write loan
        u.loans[loanId] = Loan({
            borrower: v.borrower,
            token: v.token,
            principal: uint128(chosenAmount),
            rateBP: chosenRateBP,
            drawdownTs: uint40(block.timestamp),
            harvestTs: 0,
            maturityTs: 0,
            repaid: 0,
            interestPaid: 0,
            liquidated: false,
            defaulted: false,
            loanType: v.loanType,
            paramsHash: v.paramsHash
        });

        loansByBorrower[v.borrower].push(loanId);

        // move funds
        mJ.totalBorrows += chosenAmount;
        IERC20Metadata(v.token).safeTransfer(v.borrower, chosenAmount);

        emit LoanClaimed(
            v.union,
            loanId,
            v.borrower,
            v.token,
            chosenAmount,
            chosenRateBP,
            v.loanType,
            v.paramsHash
        );
        emit LoanParams(loanId, params);
    }

    function repayLoan(
        address unionAddr,
        bytes32 loanId,
        uint256 amount
    ) external whenNotPaused nonReentrant {
        require(amount > 0, "zero amount");
        Union storage u = unions[unionAddr];
        Loan storage ln = u.loans[loanId];
        require(ln.drawdownTs != 0, "loan !exist");
        require(!ln.liquidated && !ln.defaulted, "closed");

        address token = ln.token;
        Market storage mJ = u.juniorByType[token][ln.loanType];

        IERC20Metadata(token).safeTransferFrom(
            msg.sender,
            address(this),
            amount
        );

        uint40 currentTs = uint40(block.timestamp);
        uint40 endTs = ln.maturityTs == 0
            ? currentTs
            : (currentTs < ln.maturityTs ? currentTs : ln.maturityTs);

        uint256 elapsed = uint256(endTs - ln.drawdownTs);
        uint256 totalInterestAccrued = (uint256(ln.principal) *
            ln.rateBP *
            elapsed) / (10_000 * YEAR);

        uint256 unpaidInterest = totalInterestAccrued > ln.interestPaid
            ? (totalInterestAccrued - ln.interestPaid)
            : 0;

        uint256 interestPayment = amount < unpaidInterest
            ? amount
            : unpaidInterest;
        uint256 principalRemaining = uint256(ln.principal) > ln.repaid
            ? (uint256(ln.principal) - ln.repaid)
            : 0;
        uint256 principalPayment = (amount > interestPayment)
            ? (
                amount - interestPayment > principalRemaining
                    ? principalRemaining
                    : (amount - interestPayment)
            )
            : 0;

        if (interestPayment > 0) {
            ln.interestPaid += uint128(interestPayment);
            _creditInterestTranches(
                unionAddr,
                token,
                ln.loanType,
                interestPayment
            );
        }
        if (principalPayment > 0) {
            ln.repaid += uint128(principalPayment);
            mJ.totalBorrows = mJ.totalBorrows >= principalPayment
                ? mJ.totalBorrows - principalPayment
                : 0;
        }

        bool principalCleared = ln.repaid >= ln.principal;
        if (principalCleared && ln.maturityTs != 0) {
            uint256 fullInterestToMaturity = (uint256(ln.principal) *
                ln.rateBP *
                uint256(ln.maturityTs - ln.drawdownTs)) / (10_000 * YEAR);
            if (ln.interestPaid >= fullInterestToMaturity) {
                ln.liquidated = true;
            }
        }

        emit LoanRepaid(
            unionAddr,
            loanId,
            msg.sender,
            amount,
            interestPayment,
            principalPayment
        );
    }

    function reportMaturity(
        address unionAddr,
        bytes32 loanId,
        uint40 maturityTs
    ) external whenNotPaused onlyOracleOrLeader(unionAddr) {
        Loan storage ln = unions[unionAddr].loans[loanId];
        require(ln.drawdownTs != 0, "loan !exist");
        require(ln.maturityTs == 0, "maturity set");
        ln.maturityTs = maturityTs;
        emit MaturityReported(unionAddr, loanId, ln.maturityTs);
    }

    function defaultLoan(
        address unionAddr,
        bytes32 loanId,
        uint256 lossAmount
    ) external whenNotPaused onlyOracleOrLeader(unionAddr) {
        require(lossAmount > 0, "loss=0");
        Union storage u = unions[unionAddr];
        Loan storage ln = u.loans[loanId];
        require(ln.drawdownTs != 0, "loan !exist");
        require(!ln.liquidated && !ln.defaulted, "closed");

        address token = ln.token;
        Market storage mJ = u.juniorByType[token][ln.loanType];

        // principal write-off
        uint256 principalRemaining = uint256(ln.principal) > ln.repaid
            ? (uint256(ln.principal) - ln.repaid)
            : 0;
        uint256 principalWriteoff = principalRemaining > 0
            ? (
                lossAmount > principalRemaining
                    ? principalRemaining
                    : lossAmount
            )
            : 0;
        if (principalWriteoff > 0) {
            mJ.totalBorrows = mJ.totalBorrows >= principalWriteoff
                ? mJ.totalBorrows - principalWriteoff
                : 0;
        }

        // haircut: Junior (matching type) then Senior
        uint256 remainingLoss = lossAmount;
        uint256 juniorApplied = _applyLossToMarket(mJ, remainingLoss);
        remainingLoss -= juniorApplied;

        uint256 seniorApplied = 0;
        if (remainingLoss > 0) {
            Market storage s = seniorMarkets[token];
            seniorApplied = _applyLossToMarket(s, remainingLoss);
            remainingLoss -= seniorApplied;
        }

        ln.defaulted = true;
        ln.liquidated = true;

        emit LoanDefaulted(unionAddr, loanId, juniorApplied, seniorApplied);
    }

    // ------- BOTH TRANSFER AND ROLL-OVER FOLDED INTO ONE
    function transferLoan(
        address unionAddr,
        bytes32 loanId,
        address newBorrower, // = address(0) or same as old → rollover only
        uint16 newRateBP,
        uint40 newMaturityTs,
        bytes calldata newParams
    ) external whenNotPaused onlyOracleOrLeader(unionAddr) {
        Loan storage ln = unions[unionAddr].loans[loanId];
        require(ln.drawdownTs != 0, "loan !exist");
        require(!ln.defaulted && !ln.liquidated, "closed");

        // ---- settle window to 'now' with 3d tolerance on shortfall ----
        uint40 endTs = uint40(block.timestamp);
        uint256 elapsed = uint256(endTs - ln.drawdownTs);
        uint256 accrued = (uint256(ln.principal) * ln.rateBP * elapsed) /
            (10_000 * YEAR);

        if (ln.interestPaid < accrued) {
            uint256 shortfall = accrued - ln.interestPaid;
            uint256 tol = (uint256(ln.principal) *
                ln.rateBP *
                CARRYOVER_WINDOW) / (10_000 * YEAR);
            require(shortfall <= tol, "interest not settled (>3d)");
            // carry over: mark all interest to now as accounted
            ln.interestPaid = uint128(accrued);
        } else {
            // fully settled: reset accrual window
            ln.interestPaid = 0;
        }

        // ---- apply new terms ----
        ln.rateBP = newRateBP;
        ln.drawdownTs = endTs;
        ln.maturityTs = newMaturityTs;

        // ---- optional reassignment (TRANSFER LOAN) ----
        address oldBorrower = ln.borrower;
        bool borrowerChanged = (newBorrower != address(0)) &&
            (newBorrower != oldBorrower);
        if (borrowerChanged) {
            ln.borrower = newBorrower; // update current owner
            loansByBorrower[newBorrower].push(loanId); // keep historical record
        }

        // ---- events ----
        if (borrowerChanged) {
            emit LoanTransferred(
                unionAddr,
                loanId,
                newBorrower,
                newRateBP,
                ln.drawdownTs
            );
        } else {
            emit LoanRolledOver(unionAddr, loanId, newRateBP, ln.drawdownTs);
        }
        if (newParams.length > 0) emit LoanParams(loanId, newParams);
    }

    // ───────── slim getters (added back for tests) ─────────
    function getLoanTypesForUnionToken(address unionAddr,address token) external view returns(bytes32[] memory) {
        return unions[unionAddr].loanTypesByToken[token];
    }
    function getTokenListJunior(address unionAddr) external view returns(address[] memory) {
        return unionTokens[unionAddr];
    }
    function getTokenListSenior() external view returns(address[] memory) {
        return seniorTokenList;
    }
    function getLoansByBorrower(address borrower) external view returns(bytes32[] memory) {
        return loansByBorrower[borrower];
    }
    function previewRateBP(address unionAddr,address token,uint256 amount) external view returns(uint16) {
        return _quoteRateBP(unionAddr,token,amount);
    }
    function getBorrowCap(address unionAddr,address token) external view returns(uint256 cap) {
        cap = 2*(unionCapBase[unionAddr][token]+seniorCap[unionAddr][token]);
    }

    // internal rate model
    function _quoteRateBP(address unionAddr,address token,uint256 amount) internal view returns(uint16) {
        RateParams memory p = rateParams[token];
        if (p.kinkUtilBP==0) return p.maxRateBP>0?p.maxRateBP:10000;
        uint256 capBase=unionCapBase[unionAddr][token]+seniorCap[unionAddr][token];
        uint256 cap=2*capBase; if(cap==0) return p.maxRateBP;
        uint256 util=((aggregateBorrowsForUnionToken(unionAddr,token)+amount)*WAD)/cap;
        if(util>WAD) util=WAD;
        uint256 kink=(uint256(p.kinkUtilBP)*WAD)/10000;
        uint256 rate=uint256(p.baseRateBP);
        if(util<=kink){ rate += (uint256(p.slope1BP)*util)/kink; }
        else { rate+=p.slope1BP; rate += (uint256(p.slope2BP)*(util-kink))/(WAD-kink); }
        if(rate>p.maxRateBP) rate=p.maxRateBP;
        return uint16(rate);
    }

    function aggregateBorrowsForUnionToken(address unionAddr,address token) private view returns(uint256 total) {
        bytes32[] storage types_=unions[unionAddr].loanTypesByToken[token];
        for(uint i=0;i<types_.length;i++){ total+=unions[unionAddr].juniorByType[token][types_[i]].totalBorrows; }
    }
}

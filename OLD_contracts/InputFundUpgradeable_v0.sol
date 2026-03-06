// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/**
 * @title InputFundUpgradeable
 * @notice Multi‑token investment pool (upgradeable, UUPS pattern)
 */
contract InputFundUpgradeable_v0 is Initializable, OwnableUpgradeable, UUPSUpgradeable, EIP712Upgradeable {
    /* ═══════════════════════════════════════════════════════
                                  Storage
       ═════════════════════════════════════════════════════ */
    string public fundName;
    string public fundType;

    uint16 public baseRateBP;            // basis‑points APR baseline
    address public oracleSigner;
    uint256 public creationTime;

    uint256 private constant INDEX_SCALE = 1e18;
    uint256 private constant UTIL_SCALE  = 1e4;

    struct Pool {
        uint256 totalFunds;
        uint256 totalLent;
        uint256 globalIndex;
        uint256 lastUpdate;
        bool    exists;
        uint256 lastAPRDay;
        uint256[] aprDays;
    }
    mapping(address => Pool) public pools;
    address[] public tokenList;

    mapping(address => mapping(uint256 => uint16)) public aprHistory;   // token => day => dailyBP
    mapping(address => mapping(address => uint256)) public investorPrincipal;
    mapping(address => mapping(address => uint256)) public investorIndex;

    /// @dev nonces to prevent replay
    mapping(uint256 => bool) public usedNonce;

    /* ═══════════════════════════════════════════════════════
                        Events (unchanged)
       ═════════════════════════════════════════════════════ */
    event Invest(address indexed investor, address indexed token, uint256 amt);
    event Withdraw(address indexed investor, address indexed token, uint256 amt);
    event InterestClaimed(address indexed investor, address indexed token, uint256 amt);
    event IndexUpdated(address indexed token, uint256 newIndex);
    event APRRecorded(address indexed token, uint256 dayNumber, uint16 dailyRateBP);
    event OracleSignerSet(address indexed newSigner);
    event TokenAllowed(address indexed token);
    event TokenRevoked(address indexed token);
    event LoanFunded(uint256 indexed nonce, address recipient, uint256 amount);

    /* ═══════════════════════════════════════════════════════
                           Initializer
       ═════════════════════════════════════════════════════ */
    function initialize(
        string memory _fundName,
        string memory _fundType,
        address[] memory _tokens,
        address _oracleSigner,
        uint16  _baseRateBP,
        address _unionOwner
    ) external initializer {
        __Ownable_init(_unionOwner);
        __UUPSUpgradeable_init();
        __EIP712_init("InputFundUpgradeable", "1");

        fundName     = _fundName;
        fundType     = _fundType;
        baseRateBP   = _baseRateBP;
        oracleSigner = _oracleSigner;
        creationTime = block.timestamp;

        emit OracleSignerSet(_oracleSigner);

        // bootstrap pools
        for (uint i; i < _tokens.length; ++i) {
            address t = _tokens[i];
            require(t != address(0), "Zero token");
            require(!pools[t].exists, "Duplicate token");
            pools[t] = Pool({
                totalFunds: 0,
                totalLent:  0,
                globalIndex: INDEX_SCALE,
                lastUpdate: block.timestamp,
                exists: true,
                lastAPRDay: block.timestamp / 1 days,
                aprDays: new uint256[](0)
            });
            tokenList.push(t);
            emit TokenAllowed(t);
        }
    }

    /* ═══════════════════════════════════════════════════════
                         UUPS authorization
       ═════════════════════════════════════════════════════ */
    function _authorizeUpgrade(address newImpl) internal override onlyOwner {}

    function version() external pure returns (string memory) { return "2.0.1"; }

    /* ═══════════════════════════════════════════════════════
                       Core logic (same as v1)
       ═════════════════════════════════════════════════════ */

    function setOracleSigner(address _new) external onlyOwner {
        require(_new != address(0), "Zero address");
        oracleSigner = _new;
        emit OracleSignerSet(_new);
    }

    function allowToken(address _token) external onlyOwner {
        require(_token != address(0), "Zero address");
        require(!pools[_token].exists, "Already allowed");
        pools[_token].exists      = true;
        pools[_token].globalIndex = INDEX_SCALE;
        pools[_token].lastUpdate  = block.timestamp;
        pools[_token].lastAPRDay  = block.timestamp / 1 days;
        tokenList.push(_token);
        emit TokenAllowed(_token);
    }
    function revokeToken(address _token) external onlyOwner {
        require(pools[_token].exists, "Not allowed");
        delete pools[_token];
        emit TokenRevoked(_token);
    }

    // internal: record daily APR snapshot
    function _recordDailyAPR(address _token) internal {
        Pool storage p = pools[_token];
        uint256 day = block.timestamp / 1 days;
        if (day == p.lastAPRDay) return;
        uint256 idle   = p.totalFunds - p.totalLent;
        uint256 utilBP = p.totalFunds == 0 ? UTIL_SCALE : idle * UTIL_SCALE / p.totalFunds;
        uint256 aprBP  = uint256(baseRateBP) + uint256(baseRateBP) * (UTIL_SCALE - utilBP) / UTIL_SCALE;
        uint16 dailyBP = uint16(aprBP / 365);
        aprHistory[_token][day] = dailyBP;
        p.aprDays.push(day);
        p.lastAPRDay = day;
        emit APRRecorded(_token, day, dailyBP);
    }

    // internal: sync index for continuous accrual
    function _syncIndex(address _token) internal {
        Pool storage p = pools[_token];
        require(p.exists, "Pool not exists");
        _recordDailyAPR(_token);

        uint256 dt = block.timestamp - p.lastUpdate;
        if (dt == 0 || p.totalFunds == 0) {
            p.lastUpdate = block.timestamp;
            return;
        }
        uint256 idle   = p.totalFunds - p.totalLent;
        uint256 utilBP = idle * UTIL_SCALE / p.totalFunds;
        uint256 aprBP  = uint256(baseRateBP) + uint256(baseRateBP) * (UTIL_SCALE - utilBP) / UTIL_SCALE;
        uint256 delta  = aprBP * dt * INDEX_SCALE / (365 days * UTIL_SCALE);
        p.globalIndex += delta;
        p.lastUpdate   = block.timestamp;
        emit IndexUpdated(_token, p.globalIndex);
    }

    // internal: pay out owed interest
    function _claimInterestInternal(address _token, address _inv) internal {
        Pool storage p = pools[_token];
        uint256 idxDiff = p.globalIndex - investorIndex[_token][_inv];
        uint256 principalAmt = investorPrincipal[_token][_inv];
        if (idxDiff == 0 || principalAmt == 0) return;
        uint256 owed = principalAmt * idxDiff / INDEX_SCALE;
        investorIndex[_token][_inv] = p.globalIndex;
        IERC20(_token).transfer(_inv, owed);
        emit InterestClaimed(_inv, _token, owed);
    }

    /// @notice Invest `amt` of `_token`, claim pending interest first
    function invest(address _token, uint256 amt) external {
        require(pools[_token].exists, "Token not allowed");
        _syncIndex(_token);
        _claimInterestInternal(_token, msg.sender);

        require(IERC20(_token).transferFrom(msg.sender, address(this), amt), "Transfer failed");
        investorPrincipal[_token][msg.sender] += amt;
        pools[_token].totalFunds += amt;
        investorIndex[_token][msg.sender] = pools[_token].globalIndex;
        emit Invest(msg.sender, _token, amt);
    }

    /// @notice Withdraw up to `amt` of principal + pending interest
    function withdraw(address _token, uint256 amt) external {
        require(pools[_token].exists, "Token not allowed");
        _syncIndex(_token);
        _claimInterestInternal(_token, msg.sender);

        uint256 principalAmt = investorPrincipal[_token][msg.sender];
        require(principalAmt >= amt, "Insufficient principal");
        require(pools[_token].totalFunds - pools[_token].totalLent >= amt, "Insufficient liquidity");

        investorPrincipal[_token][msg.sender]   = principalAmt - amt;
        pools[_token].totalFunds                -= amt;
        investorIndex[_token][msg.sender]       = pools[_token].globalIndex;
        IERC20(_token).transfer(msg.sender, amt);
        emit Withdraw(msg.sender, _token, amt);
    }

    /// @notice Claim only your pending interest for `_token`
    function claimInterest(address _token) external {
        require(pools[_token].exists, "Token not allowed");
        _syncIndex(_token);
        _claimInterestInternal(_token, msg.sender);
    }

    /**
     * @notice Redeem a signed loan voucher in one transaction
     * @param recipient who will receive the funds
     * @param token     token to borrow (must be allowed)
     * @param amount    principal amount
     * @param rateBP    agreed rate in basis points
     * @param nonce     unique voucher nonce
     * @param deadline  voucher expiration timestamp
     * @param signature EIP-712 signature from oracleSigner
     */
    function claimLoan(
        address recipient,
        address token,
        uint256 amount,
        uint16  rateBP,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external {
        // expiry & replay
        require(block.timestamp <= deadline, "Voucher expired");
        require(!usedNonce[nonce], "Voucher already used");
        usedNonce[nonce] = true;

        // verify signature
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(
                    "LoanVoucher(address recipient,address token,uint256 amount,uint16 rateBP,uint256 nonce,uint256 deadline)"
                ),
                recipient,
                token,
                amount,
                rateBP,
                nonce,
                deadline
            )
        );
        bytes32 digest = _hashTypedDataV4(structHash);
        address signer = ECDSA.recover(digest, signature);
        require(signer == oracleSigner, "Invalid oracle signature");

        // fund from pool
        Pool storage p = pools[token];
        require(p.exists, "Token not allowed");
        require(p.totalFunds - p.totalLent >= amount, "Insufficient liquidity");
        p.totalLent += amount;
        IERC20(token).transfer(recipient, amount);

        emit LoanFunded(nonce, recipient, amount);
    }


    /// @notice Get principal, pending interest, and dailyRateBP
    function getInvestorInfo(address _token, address _inv)
        external view
        returns (uint256 principalAmt, uint256 pendingInterest, uint16 dailyRateBP)
    {
        Pool storage p = pools[_token];
        require(p.exists, "Token not allowed");
        principalAmt = investorPrincipal[_token][_inv];
        uint256 idxDiff = p.globalIndex - investorIndex[_token][_inv];
        pendingInterest = principalAmt * idxDiff / INDEX_SCALE;

        uint256 idle   = p.totalFunds - p.totalLent;
        uint256 utilBP = p.totalFunds == 0 ? UTIL_SCALE : idle * UTIL_SCALE / p.totalFunds;
        uint256 aprBP  = uint256(baseRateBP) + uint256(baseRateBP) * (UTIL_SCALE - utilBP) / UTIL_SCALE;
        dailyRateBP    = uint16(aprBP / 365);
    }

    /// @notice Get totalFunds & totalLent for `_token`
    function getFundTotals(address _token)
        external view returns (uint256 funds, uint256 lent)
    {
        Pool storage p = pools[_token];
        require(p.exists, "Token not allowed");
        funds = p.totalFunds;
        lent  = p.totalLent;
    }

    /// @notice Current daily return rateBP for `_token`
    function getDailyReturnRateBP(address _token) external view returns (uint16) {
        Pool storage p = pools[_token];
        require(p.exists, "Token not allowed");
        uint256 idle   = p.totalFunds - p.totalLent;
        uint256 utilBP = p.totalFunds == 0 ? UTIL_SCALE : idle * UTIL_SCALE / p.totalFunds;
        uint256 aprBP  = uint256(baseRateBP) + uint256(baseRateBP) * (UTIL_SCALE - utilBP) / UTIL_SCALE;
        return uint16(aprBP / 365);
    }

    /// @notice Get APR history arrays for `_token`
    function getAPRHistory(address _token)
        external view
        returns (
            uint256[] memory _days, 
            uint16[] memory _rates
            )
    {
        Pool storage p = pools[_token];
        require(p.exists, "Token not allowed");
        uint256 len = p.aprDays.length;

        _days  = new uint256[](len);
        _rates = new uint16[](len);

        for (uint256 i = 0; i < len; i++) {
            uint256 d = p.aprDays[i];
            _days[i]  = d;
            _rates[i] = aprHistory[_token][d];
        }
    }

    /// @notice List of all allowed token addresses
    function getTokenList() external view returns (address[] memory) {
        return tokenList;
    }
}

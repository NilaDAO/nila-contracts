// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title InputFund
 * @notice Multi-token investment pool (e.g. fertilizer fund) with continuous interest accrual.
 * - Supports deposits in approved tokens (e.g. NILA & USDC)
 * - Tracks dynamic APR based on pool utilization
 * - Oracle signer address for future borrower integration
 * - Owner (union) controls token whitelist and oracle signer
 * - Holds human-readable fundName & fundType
 */

contract InputFund is Ownable {
    // human metadata
    string public fundName;
    string public fundType;

    // interest parameters
    uint16 public immutable baseRateBP;    // e.g. 700 = 7% APR
    address public oracleSigner;
    uint256 public creationTime;

    uint256 private constant INDEX_SCALE = 1e18;
    uint256 private constant UTIL_SCALE  = 1e4;

    struct Pool {
        uint256 totalFunds;    // all investor principal in this token
        uint256 totalLent;     // reserved for loans (future)
        uint256 globalIndex;   // scaled by INDEX_SCALE
        uint256 lastUpdate;    // timestamp of last index sync
        bool    exists;
        uint256 lastAPRDay;    // for daily snapshots
        uint256[] aprDays;     // recorded days
    }

    // token address => Pool data
    mapping(address => Pool) public pools;
    address[] public tokenList;

    // APR history: token => dayNumber => dailyRateBP
    mapping(address => mapping(uint256 => uint16)) public aprHistory;

    // token => investor => principal & last index
    mapping(address => mapping(address => uint256)) public investorPrincipal;
    mapping(address => mapping(address => uint256)) public investorIndex;

    // --- Events ---
    event Invest(address indexed investor, address indexed token, uint256 amt);
    event Withdraw(address indexed investor, address indexed token, uint256 amt);
    event InterestClaimed(address indexed investor, address indexed token, uint256 amt);
    event IndexUpdated(address indexed token, uint256 newIndex);
    event APRRecorded(address indexed token, uint256 dayNumber, uint16 dailyRateBP);
    event OracleSignerSet(address indexed newSigner);
    event TokenAllowed(address indexed token);
    event TokenRevoked(address indexed token);

    /**
     * @param _fundName      Human‐friendly fund name
     * @param _fundType      Fund type/category (e.g. "Fertilizer")
     * @param _tokens        Initial allowed tokens
     * @param _oracleSigner  Oracle‐signer address
     * @param _baseRateBP    Base APR in bps
     * @param _union         Union address as owner
     */
    constructor(
        string memory _fundName,
        string memory _fundType,
        address[] memory _tokens,
        address _oracleSigner,
        uint16  _baseRateBP,
        address _union
        ) 
        Ownable(_union)
        {    
        fundName     = _fundName;
        fundType     = _fundType;
        baseRateBP   = _baseRateBP;
        oracleSigner = _oracleSigner;
        creationTime = block.timestamp;
        emit OracleSignerSet(_oracleSigner);

        // transfer ownership to union
        transferOwnership(_union);

        // initialize each token pool
        for (uint i = 0; i < _tokens.length; i++) {
            address t = _tokens[i];
            require(t != address(0), "Zero address token");
            require(!pools[t].exists, "Token already allowed");
            pools[t].exists      = true;
            pools[t].globalIndex = INDEX_SCALE;
            pools[t].lastUpdate  = block.timestamp;
            pools[t].lastAPRDay  = block.timestamp / 1 days;
            tokenList.push(t);
            emit TokenAllowed(t);
        }
    }

    // owner‐only controls
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

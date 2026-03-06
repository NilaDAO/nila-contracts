// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "./InputFundUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @notice Tracks both the deployed fund proxy address and its human name
struct FundInfo {
    address fund;
    string  name;
    string  contractname;
}

/**
 * @title FundFactoryUpgradeable
 * @notice Deploys new InputFundUpgradeable instances behind ERC1967 proxies and tracks them per union.
 *         Upgradeable via UUPS. OnlyOwner can create funds.
 */
contract FundFactoryUpgradeable is Initializable, OwnableUpgradeable, UUPSUpgradeable {
    
    /// all fund proxy addresses
    address[] public allFunds;

    /// mapping union => deployed fund proxies + names
    mapping(address => FundInfo[]) public fundsByOwner;

    /// implementation logic addresses
    mapping(bytes32 => address) public fundLogic;   // fundTypeID → impl


    /* -------------------------------------------------------
    EVENTS
    ------------------------------------------------------- */    
    event FundCreated(bytes32 indexed id,address indexed _union, address proxy, address fund, string fundType);
    event FundLogicSet(string id, address impl);
    event FundRemoved(address indexed _union, address indexed fund);

    /// @notice Initialize factory with owner and the fund logic address
    function initialize(address _owner) external initializer {
        __Ownable_init(_owner);
        __UUPSUpgradeable_init();
    }

    /// @dev UUPS authorization
    function _authorizeUpgrade(address) internal override onlyOwner {}

    /**
     * @notice Deploy a new fund behind a proxy and initialize it
     * @param _tokens       Allowed token addresses
     * @param _fundName     Human name
     * @param _fundType     Category/type
     * @param _oracleSigner Oracle signer address
     * @param _baseRateBP   Base APR in bps
     * @param _union        Union (owner) address for the new fund
     * @return proxyAddr    Address of the newly deployed fund proxy
     */

    function createInputFund(
        address[] calldata _tokens,
        string  calldata _fundName,
        string  calldata _fundType,      // e.g. "INPUT"
        address         _oracleSigner,
        uint16          _baseRateBP,
        address         _union
    ) external returns (address proxyAddr) {
        /* -------------------------------------------------------
        1) resolve implementation address for this fund‑type
        ------------------------------------------------------- */
        bytes32 id = keccak256(bytes(_fundType));     // INPUT → 0x…
        address impl = fundLogic[id];
        require(impl != address(0), "fundtype not registered");

        /* -------------------------------------------------------
        2) encode initializer calldata
        ------------------------------------------------------- */
        bytes memory initData = abi.encodeWithSelector(
            InputFundUpgradeable.initialize.selector,
            _fundName,
            _fundType,
            _tokens,
            _oracleSigner,
            _baseRateBP,
            _union
        );

        /* -------------------------------------------------------
        3) deploy proxy pointing to the resolved implementation
        ------------------------------------------------------- */
        ERC1967Proxy proxy = new ERC1967Proxy(impl, initData);
        proxyAddr = address(proxy);

        /* -------------------------------------------------------
        4) bookkeeping & event
        ------------------------------------------------------- */
        allFunds.push(proxyAddr);
        fundsByOwner[_union].push(FundInfo({ fund: proxyAddr, name: _fundName, contractname: 'InputFundUpgradeable' }));
        emit FundCreated(id, _union, proxyAddr, impl, _fundType);
    } 

    /// @notice fund owner has the ability to remove the contract from the mapping
    function removeFund(address fund) external {
        require(fund != address(0), "zero addr");
        
        address fundOwner = OwnableUpgradeable(fund).owner(); 
        require(msg.sender == fundOwner, "caller is not the fund owner");
        
        FundInfo[] storage list = fundsByOwner[fundOwner];
        uint256 len = list.length;
        for (uint256 j; j < len; ++j) {
            if (list[j].fund == fund) {
                list[j] = list[len - 1];
                list.pop();
                break;
            }
        }    
        emit FundRemoved(fundOwner, fund);
    }

    /// @notice owner registers or updates impl for a fund‑type
    function setFundLogic(string calldata _fundType, address impl) external onlyOwner {
        require(impl.code.length > 0, "not a contract");
        fundLogic[keccak256(bytes(_fundType))] = impl;
        emit FundLogicSet(_fundType, impl);
    }

    /// @notice Returns all fund proxies
    function getAllFunds() external view returns (address[] memory) {
        return allFunds;
    }

    /// @notice Returns FundInfo[] for a specific union
    function getFundsByOwner(address _union) external view returns (FundInfo[] memory) {
        return fundsByOwner[_union];
    }
}

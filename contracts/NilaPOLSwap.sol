// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

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

/// @notice Swap nIN (INR) for native POL using USD/INR and POL/USD oracles.
/// nIN is transferred to a subsidy address instead of being burned.
contract NilaPOLSwap is
    Initializable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    bytes32 public constant ONLY_OWNER = keccak256("ONLY_ORACLE");

    IERC20 public nin;
    address public subsidyAddress;

    AggregatorV3Interface public inrUsdOracle;
    uint8 public inrOracleDecimals;

    AggregatorV3Interface public polUsdOracle;
    uint8 public polOracleDecimals;
    bool public polOracleIsUsdPerPol;

    uint256 public maxOracleDelay;

    event InrOracleUpdated(address oracle, uint8 decimals);
    event PolOracleUpdated(address oracle, uint8 decimals, bool usdPerPol);
    event MaxOracleDelayUpdated(uint256 oldValue, uint256 newValue);
    event SubsidyAddressUpdated(address indexed oldAddress, address indexed newAddress);
    event RedeemNinForPol(
        address indexed user,
        uint256 ninIn,
        uint256 polOut,
        uint256 usdAmount18,
        uint256 inrPerUsd,
        uint256 polPerUsd
    );

    function initialize(
        address nin_,
        address inrUsdOracle_,
        address polUsdOracle_,
        bool polOracleIsUsdPerPol_,
        uint256 maxOracleDelay_,
        address subsidyAddress_,
        address admin_
    ) external initializer {
        require(nin_ != address(0), "zero nin");
        require(inrUsdOracle_ != address(0), "zero inr oracle");
        require(polUsdOracle_ != address(0), "zero pol oracle");
        require(subsidyAddress_ != address(0), "zero subsidy");
        require(admin_ != address(0), "zero admin");

        __AccessControl_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        nin = IERC20(nin_);
        subsidyAddress = subsidyAddress_;

        inrUsdOracle = AggregatorV3Interface(inrUsdOracle_);
        inrOracleDecimals = inrUsdOracle.decimals();

        polUsdOracle = AggregatorV3Interface(polUsdOracle_);
        polOracleDecimals = polUsdOracle.decimals();
        polOracleIsUsdPerPol = polOracleIsUsdPerPol_;

        maxOracleDelay = maxOracleDelay_;

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(ONLY_OWNER, admin_);

        emit InrOracleUpdated(inrUsdOracle_, inrOracleDecimals);
        emit PolOracleUpdated(polUsdOracle_, polOracleDecimals, polOracleIsUsdPerPol_);
        emit SubsidyAddressUpdated(address(0), subsidyAddress_);
    }

    function _authorizeUpgrade(address newImplementation)
        internal
        override
        onlyRole(ONLY_OWNER)
    {}

    function setInrOracle(address oracle, uint256 newMaxDelay) external onlyRole(ONLY_OWNER) {
        require(oracle != address(0), "zero inr oracle");
        uint256 oldDelay = maxOracleDelay;
        inrUsdOracle = AggregatorV3Interface(oracle);
        inrOracleDecimals = inrUsdOracle.decimals();
        maxOracleDelay = newMaxDelay;
        emit InrOracleUpdated(oracle, inrOracleDecimals);
        emit MaxOracleDelayUpdated(oldDelay, newMaxDelay);
    }

    function setPolOracle(address oracle, bool usdPerPol) external onlyRole(ONLY_OWNER) {
        require(oracle != address(0), "zero pol oracle");
        polUsdOracle = AggregatorV3Interface(oracle);
        polOracleDecimals = polUsdOracle.decimals();
        polOracleIsUsdPerPol = usdPerPol;
        emit PolOracleUpdated(oracle, polOracleDecimals, usdPerPol);
    }

    function setMaxOracleDelay(uint256 newMaxOracleDelay) external onlyRole(ONLY_OWNER) {
        uint256 old = maxOracleDelay;
        maxOracleDelay = newMaxOracleDelay;
        emit MaxOracleDelayUpdated(old, newMaxOracleDelay);
    }

    function setSubsidyAddress(address newSubsidy) external onlyRole(ONLY_OWNER) {
        require(newSubsidy != address(0), "zero subsidy");
        address old = subsidyAddress;
        subsidyAddress = newSubsidy;
        emit SubsidyAddressUpdated(old, newSubsidy);
    }

    function redeemNinForPol(uint256 ninAmount) external nonReentrant {
        require(ninAmount > 0, "zero amount");

        uint256 inrPerUsd = _getInrPerUsdView();
        uint256 polPerUsd = _getPolPerUsdView();

        // USD value in 18 decimals: USD = INR / (INR per USD)
        uint256 usdAmount18 = (ninAmount * (10 ** inrOracleDecimals)) / inrPerUsd;
        require(usdAmount18 > 0, "too small");

        uint256 polOut = (usdAmount18 * polPerUsd) / (10 ** polOracleDecimals);
        require(polOut > 0, "polOut zero");
        require(address(this).balance >= polOut, "pool POL too low");

        require(nin.transferFrom(msg.sender, subsidyAddress, ninAmount), "nIN transfer failed");

        (bool sent,) = msg.sender.call{value: polOut}("");
        require(sent, "POL transfer failed");

        emit RedeemNinForPol(msg.sender, ninAmount, polOut, usdAmount18, inrPerUsd, polPerUsd);
    }

    function _getInrPerUsdView() internal view returns (uint256 inrPerUsd) {
        (
            uint80 roundId,
            int256 answer,
            ,
            uint256 updatedAt,
            uint80 answeredInRound
        ) = inrUsdOracle.latestRoundData();

        require(answer > 0, "inr oracle answer <= 0");
        require(answeredInRound >= roundId && updatedAt != 0, "inr oracle stale");
        require(block.timestamp - updatedAt <= maxOracleDelay, "inr oracle too old");

        uint256 raw = uint256(answer); // USD per INR
        uint256 scale = 10 ** inrOracleDecimals;
        inrPerUsd = (scale * scale) / raw; // INR per USD
    }

    function _getPolPerUsdView() internal view returns (uint256 polPerUsd) {
        (
            uint80 roundId,
            int256 answer,
            ,
            uint256 updatedAt,
            uint80 answeredInRound
        ) = polUsdOracle.latestRoundData();

        require(answer > 0, "pol oracle answer <= 0");
        require(answeredInRound >= roundId && updatedAt != 0, "pol oracle stale");
        require(block.timestamp - updatedAt <= maxOracleDelay, "pol oracle too old");

        uint256 raw = uint256(answer);
        uint256 scale = 10 ** polOracleDecimals;
        if (polOracleIsUsdPerPol) {
            polPerUsd = (scale * scale) / raw;
        } else {
            polPerUsd = raw;
        }
    }

    receive() external payable {}

    uint256[45] private __gap;
}

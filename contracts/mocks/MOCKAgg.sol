// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

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

contract MockAggregator is AggregatorV3Interface {
    uint8 public override decimals;
    int256 public answer;

    constructor(uint8 _decimals, int256 _answer) {
        decimals = _decimals;
        answer = _answer;
    }

    function latestRoundData() external view override
      returns (uint80, int256, uint256, uint256, uint80)
    {
        return (1, answer, block.timestamp, block.timestamp, 1);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "../NilaNINV2.sol";

/// @dev Mock V3 for testing UUPS upgrade path. Adds a single view function.
/// @custom:oz-upgrades-unsafe-allow missing-initializer
contract MockNilaNINV3 is NilaNINV2 {
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() { _disableInitializers(); }

    function version() external pure returns (string memory) {
        return "V3";
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "@openzeppelin/contracts/access/Ownable.sol";

contract RolesRegistry is Ownable {
    mapping(address => bool)                     public oracles;                           // EOA or helper contracts
    mapping(address => mapping(address => bool)) public leaders;                           // union => leader => allowed
    mapping(address => bool)                     public cores;                             // core proxies allowed to call system hooks
    mapping(address => bool)                     public modules;                           // optional: modules allowed to call core/viewer hooks

    constructor(address initialOwner) Ownable(initialOwner) {}

    // --- Setters (owner-only) ---
    event OracleSet(address indexed acct, bool allowed);
    event LeaderSet(address indexed unionAddr, address indexed acct, bool allowed);
    event CoreSet(address indexed core, bool allowed);
    event ModuleSet(address indexed module, bool allowed);

    function setOracle(address acct, bool allowed) external onlyOwner {
        oracles[acct] = allowed;
        emit OracleSet(acct, allowed);
    }

    function setLeader(address unionAddr, address acct, bool allowed) external onlyOwner {
        leaders[unionAddr][acct] = allowed;
        emit LeaderSet(unionAddr, acct, allowed);
    }

    function removeLeader(address unionAddr, address acct) external onlyOwner {
        leaders[unionAddr][acct] = false;
        emit LeaderSet(unionAddr, acct, false);
    }

    function setCore(address core, bool allowed) external onlyOwner {
        cores[core] = allowed;
        emit CoreSet(core, allowed);
    }

    function setModule(address module, bool allowed) external onlyOwner {
        modules[module] = allowed;
        emit ModuleSet(module, allowed);
    }

    // --- Views (interface compat + helpers) ---
    function isOracle(address acct) external view returns (bool) {
        return oracles[acct];
    }

    function isLeader(address unionAddr, address acct) external view returns (bool) {
        return leaders[unionAddr][acct];
    }

    function isCore(address acct) external view returns (bool) {
        return cores[acct];
    }

    function isModule(address acct) external view returns (bool) {
        return modules[acct];
    }

    function isOracleOrLeader(address unionAddr, address acct) external view returns (bool) {
        return oracles[acct] || leaders[unionAddr][acct];
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @title NilaNINV2
/// @notice UUPS-upgradeable ERC-20 with EIP-2612 permit. Replaces the plain NilaNIN.
///         Role keccak values are identical to the original contract so existing
///         grantRole calls targeting MINTER_ROLE / BURNER_ROLE remain valid.
contract NilaNINV2 is
    Initializable,
    ERC20Upgradeable,
    ERC20PermitUpgradeable,
    AccessControlUpgradeable,
    UUPSUpgradeable
{
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");

    /// @dev Reserved slots for future NilaNINV2-specific state variables.
    ///      All inherited OZ v5 storage is ERC-7201 namespaced (not sequential),
    ///      so this gap covers only variables added directly to this contract.
    uint256[50] private __gap;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address admin_) external initializer {
        __ERC20_init("Nila Note", "nIN");
        __ERC20Permit_init("Nila Note");
        __AccessControl_init();
        __UUPSUpgradeable_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
    }

    /// @notice Mint nIN. Caller must hold MINTER_ROLE.
    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) {
        _mint(to, amount);
    }

    /// @notice Burn nIN from `from`. Caller must hold BURNER_ROLE.
    function burn(address from, uint256 amount) external onlyRole(BURNER_ROLE) {
        _burn(from, amount);
    }

    /// @dev Restricts proxy upgrades to DEFAULT_ADMIN_ROLE (hot key).
    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}

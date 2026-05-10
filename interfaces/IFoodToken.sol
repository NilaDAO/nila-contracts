// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

/// @title IFoodToken
/// @notice Interface consumed by GenericFundCore (drawLoan / Track C).
///         All fields needed to gate and collateralise a loan are readable here.
interface IFoodToken {

    // ----------------------------------------------------------------
    // Structs (mirrored from FoodTokenUpgradeable)
    // ----------------------------------------------------------------

    struct CropToken {
        uint256 collectionId;   // 0 = independent
        uint32  landTitleId;    // immutable after mint
        uint16  cropCode;       // field-specific (intercrop aware)
        uint16  varietyCode;
        uint32  sosDate;        // oracle-signed, immutable
        uint32  harvestDate;    // oracle-updatable estimate
        uint256 committedQtyKg;
        uint8   status;         // 0=claimed 1=verified 2=harvested 3=defaulted
    }

    // ----------------------------------------------------------------
    // Read
    // ----------------------------------------------------------------

    function getToken(uint256 tokenId) external view returns (CropToken memory);

    function balanceOf(address account, uint256 id) external view returns (uint256);

    // ----------------------------------------------------------------
    // Write (oracle-gated on the implementation side)
    // ----------------------------------------------------------------

    /// @notice Called by GenericFundCore on default to mark token as defaulted.
    function updateToken(uint256 tokenId, uint32 harvestDate, uint8 status) external;

    /// @notice ERC1155 transfer — used by GenericFundCore to lock/release collateral.
    function safeTransferFrom(
        address from,
        address to,
        uint256 id,
        uint256 value,
        bytes calldata data
    ) external;
}

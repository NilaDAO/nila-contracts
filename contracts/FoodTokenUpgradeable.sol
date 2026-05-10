// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "@openzeppelin/contracts-upgradeable/token/ERC1155/ERC1155Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "./interfaces/IFoodToken.sol";

/// @title FoodTokenUpgradeable
/// @notice ERC1155 crop passport token.
///
///  Two-level structure
///  ───────────────────
///  Collection  — a crop programme, either:
///    • Standing: union opens "Sugarcane 2025", farmers join indefinitely.
///    • Order:    buyer deposits stablecoins for a fixed qty/date/price.
///               buyer == address(0) → standing.
///
///  Token (CropToken) — one farmer's claim on one field for one crop season.
///    • Oracle signs: landTitleId, cropCode, varietyCode, sosDate, committedQtyKg.
///    • Farmer confirms: harvestDate (estimate — oracle refines later).
///    • ERC1155 quantity: kg / bags (the fungible unit within one token).
///
///  A farmer can hold multiple tokens simultaneously (intercropping, multiple fields).
///
contract FoodTokenUpgradeable is
    ERC1155Upgradeable,
    OwnableUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable,
    EIP712Upgradeable
{
    using ECDSA for bytes32;

    // ================================================================
    //  ORACLE CONDITION BITMASKS
    // ================================================================

    /// @dev Bitmask constants for cultivation requirements — oracle field-selection criteria.
    ///      OR these together to form the `conditions` value for a collection.
    ///      Bit assignment is PERMANENT — never reuse a bit once assigned.
    ///      uint256 supports up to 256 distinct requirements.
    ///
    ///  Bit 0  COND_LAND_TITLE  — field must hold a NilaLandTitle NFT  (always required)
    ///  Bit 1  COND_CROP_TYPE   — field must have a declared crop type  (always required)
    ///  Bits 2-255              — optional, see FIELD_REQUIREMENTS in frontend
    uint256 public constant COND_LAND_TITLE = 1 << 0;
    uint256 public constant COND_CROP_TYPE  = 1 << 1;

    // ================================================================
    //  STRUCTS
    // ================================================================

    /// @notice A crop programme — standing (union) or buyer-backed order.
    ///         buyer == address(0) → standing collection (indefinite, no target).
    struct Collection {
        address union_;          // union organising this crop
        uint16  cropCode;        // crop this collection covers
        bool    active;          // false = archived, no new mints
        // --- cultivation requirements (set at creation, immutable) ---
        uint256 conditions;      // bitmask — see COND_* constants above; 0 = no restrictions
        // --- order fields (zero = standing) ---
        address buyer;           // address(0) = standing
        uint256 targetQtyKg;     // total order size (0 = unlimited)
        uint256 claimedQtyKg;    // running tally of farmer claims
        uint32  deliveryDate;    // unix timestamp (0 = no deadline)
        uint256 pricePerKgUsdt;  // fixed price in USDT wei (0 = not set)
        uint8   status;          // 0=open 1=filled 2=fulfilled 3=cancelled
    }

    /// @notice One farmer's crop claim — one token per crop per field per season.
    struct CropToken {
        uint256 collectionId;    // 0 = independent (no collection)
        uint32  landTitleId;     // immutable after mint
        uint16  cropCode;        // field-specific (may differ from collection for intercrop)
        uint16  varietyCode;     // farmer's specific variety
        uint32  sosDate;         // oracle-signed at mint — immutable
        uint32  harvestDate;     // oracle estimate at mint — updatable
        uint256 committedQtyKg;  // oracle-signed at mint
        uint8   status;          // 0=claimed 1=verified 2=harvested 3=defaulted
    }

    /// @notice Oracle-signed voucher authorising a mint.
    ///         harvestDate is intentionally excluded — farmer confirms that separately.
    struct Voucher {
        address to;
        uint256 collectionId;
        uint32  landTitleId;
        uint16  cropCode;
        uint16  varietyCode;
        uint32  sosDate;
        uint256 committedQtyKg;
    }

    // ================================================================
    //  STORAGE
    // ================================================================

    /// @notice All collections, keyed by sequential ID (1-based).
    mapping(uint256 => Collection) public collections;
    uint256 public nextCollectionId;

    /// @notice All crop tokens, keyed by sequential ID (1-based).
    mapping(uint256 => CropToken) public tokens;
    uint256 public nextTokenId;

    /// @notice Human-readable crop names. cropCode → "Sugarcane"
    mapping(uint16 => string)   public cropName;

    /// @notice Variety lists per crop. cropCode → ["CO86032", "COC 24", ...]
    mapping(uint16 => string[]) public varieties;

    /// @notice Oracle signers authorised to issue vouchers and update tokens.
    mapping(address => bool) public oracleSigners;

    /// @notice Replay protection — digest of each used voucher.
    mapping(bytes32 => bool) public usedVouchers;

    /// @notice All token IDs ever minted for a land title.
    ///         Primary on-chain discovery: bounded at ~30 entries per field lifetime.
    ///         Collection-level discovery (union/buyer) uses off-chain event indexing —
    ///         TokenMinted emits collectionId indexed, sensingNode indexes from there.
    mapping(uint32 => uint256[]) public landTitleTokens;

    // ================================================================
    //  EVENTS
    // ================================================================

    event CollectionCreated(
        uint256 indexed collectionId,
        address indexed union_,
        uint16  cropCode,
        address buyer           // address(0) = standing
    );
    event CollectionArchived(uint256 indexed collectionId);
    event CollectionStatusUpdated(uint256 indexed collectionId, uint8 status);

    event TokenMinted(
        uint256 indexed tokenId,
        address indexed to,
        uint256 indexed collectionId,
        uint32  landTitleId,
        uint16  cropCode,
        uint32  sosDate,
        uint256 committedQtyKg
    );
    event TokenUpdated(uint256 indexed tokenId, uint32 harvestDate, uint8 status);

    event OracleSignerSet(address indexed signer, bool allowed);
    event CropTypeSet(uint16 indexed cropCode, string name);

    // ================================================================
    //  ERRORS
    // ================================================================

    error NotOracle();
    error ZeroAddress();
    error CollectionNotActive();
    error CollectionFilled();
    error VoucherUsed();
    error InvalidSigner();
    error TokenNotFound();
    error NotTokenHolder();

    // ================================================================
    //  MODIFIERS
    // ================================================================

    modifier onlyOracle() {
        if (!oracleSigners[msg.sender]) revert NotOracle();
        _;
    }

    // ================================================================
    //  INITIALISER
    // ================================================================

    /// @param uri_           ERC1155 metadata URI (may use {id} substitution)
    /// @param initialOwner_  Contract owner (admin)
    /// @param initialOracle_ First oracle signer (sensingNode key)
    function initialize(
        string  calldata uri_,
        address initialOwner_,
        address initialOracle_
    ) external initializer {
        __ERC1155_init(uri_);
        __Ownable_init(initialOwner_);
        __Pausable_init();
        __UUPSUpgradeable_init();
        __EIP712_init("FoodToken", "1");

        if (initialOracle_ == address(0)) revert ZeroAddress();
        oracleSigners[initialOracle_] = true;
        emit OracleSignerSet(initialOracle_, true);
    }

    // ================================================================
    //  COLLECTION MANAGEMENT
    // ================================================================

    /// @notice Create a collection.
    ///         Pass buyer = address(0) for a standing collection (indefinite, no order).
    ///         Pass buyer != address(0) for a buyer-backed order collection.
    ///         Standing collections can be promoted to order collections later via setCollectionOrder.
    ///         `conditions` is an immutable bitmask of oracle field-selection requirements —
    ///         OR together the COND_* constants defined above (0 = no restrictions).
    function createCollection(
        address union_,
        uint16  cropCode,
        address buyer,           // address(0) = standing
        uint256 targetQtyKg,     // 0 = standing (no target)
        uint32  deliveryDate,    // 0 = standing (no deadline)
        uint256 pricePerKgUsdt,  // 0 = standing (no price set)
        uint256 conditions       // bitmask — COND_LAND_TITLE | COND_CROP_TYPE | ...
    ) external onlyOwner returns (uint256 collectionId) {
        collectionId = ++nextCollectionId;
        collections[collectionId] = Collection({
            union_:         union_,
            cropCode:       cropCode,
            active:         true,
            conditions:     conditions,
            buyer:          buyer,
            targetQtyKg:    targetQtyKg,
            claimedQtyKg:   0,
            deliveryDate:   deliveryDate,
            pricePerKgUsdt: pricePerKgUsdt,
            status:         0
        });
        emit CollectionCreated(collectionId, union_, cropCode, buyer);
    }

    /// @notice Promote a standing collection to a buyer-backed order, or update order fields.
    ///         Can only be called while collection is still open (status = 0).
    function setCollectionOrder(
        uint256 collectionId,
        address buyer,
        uint256 targetQtyKg,
        uint32  deliveryDate,
        uint256 pricePerKgUsdt
    ) external onlyOwner {
        if (buyer == address(0)) revert ZeroAddress();
        Collection storage col = collections[collectionId];
        if (!col.active || col.status != 0) revert CollectionNotActive();
        col.buyer          = buyer;
        col.targetQtyKg    = targetQtyKg;
        col.deliveryDate   = deliveryDate;
        col.pricePerKgUsdt = pricePerKgUsdt;
        emit CollectionCreated(collectionId, col.union_, col.cropCode, buyer);
    }

    /// @notice Archive a collection — no new mints accepted after this.
    function archiveCollection(uint256 collectionId) external onlyOwner {
        collections[collectionId].active = false;
        emit CollectionArchived(collectionId);
    }

    /// @notice Update collection status (oracle or owner).
    ///         1=filled 2=fulfilled 3=cancelled
    function updateCollectionStatus(
        uint256 collectionId,
        uint8   status
    ) external {
        if (!oracleSigners[msg.sender] && msg.sender != owner()) revert NotOracle();
        collections[collectionId].status = status;
        emit CollectionStatusUpdated(collectionId, status);
    }

    // ================================================================
    //  MINTING
    // ================================================================

    /// @notice Farmer mints a crop claim token using an oracle-signed voucher.
    ///
    /// @param v            Oracle-signed voucher (crop + field + SOS + qty).
    /// @param sig          Oracle's EIP-712 signature over the voucher.
    /// @param harvestDate  Farmer-confirmed harvest estimate — NOT oracle-signed.
    ///                     Oracle will refine this via updateToken as satellite data arrives.
    /// @param quantity     ERC1155 amount (kg or bags — the fungible unit).
    function mintWithVoucher(
        Voucher calldata v,
        bytes   calldata sig,
        uint32  harvestDate,
        uint256 quantity
    ) external whenNotPaused {

        // --- 1. verify oracle signature ---
        bytes32 digest = _voucherDigest(v);
        if (usedVouchers[digest]) revert VoucherUsed();
        address signer = ECDSA.recover(digest, sig);
        if (!oracleSigners[signer]) revert InvalidSigner();
        usedVouchers[digest] = true;

        // --- 2. validate collection (if specified) ---
        if (v.collectionId > 0) {
            Collection storage col = collections[v.collectionId];
            if (!col.active) revert CollectionNotActive();
            // order collections: block mints if already filled/cancelled
            if (col.buyer != address(0) && col.status >= 1) revert CollectionFilled();
        }

        // --- 3. mint ERC1155 ---
        uint256 tokenId = ++nextTokenId;
        _mint(v.to, tokenId, quantity, "");

        // --- 4. store token metadata ---
        tokens[tokenId] = CropToken({
            collectionId:   v.collectionId,
            landTitleId:    v.landTitleId,
            cropCode:       v.cropCode,
            varietyCode:    v.varietyCode,
            sosDate:        v.sosDate,
            harvestDate:    harvestDate,
            committedQtyKg: v.committedQtyKg,
            status:         0  // claimed
        });

        emit TokenMinted(
            tokenId, v.to, v.collectionId,
            v.landTitleId, v.cropCode, v.sosDate, v.committedQtyKg
        );

        // --- 5. index for on-chain farmer discovery ---
        landTitleTokens[v.landTitleId].push(tokenId);

        // --- 6. update order collection claimed tally ---
        if (v.collectionId > 0) {
            Collection storage col = collections[v.collectionId];
            if (col.buyer != address(0) && col.targetQtyKg > 0) {
                col.claimedQtyKg += v.committedQtyKg;
                if (col.claimedQtyKg >= col.targetQtyKg) {
                    col.status = 1; // filled
                    emit CollectionStatusUpdated(v.collectionId, 1);
                }
            }
        }
    }

    // ================================================================
    //  ORACLE UPDATES
    // ================================================================

    /// @notice Oracle refines harvestDate or updates token lifecycle status.
    ///         Cannot modify landTitleId, sosDate, cropCode — those are trust anchors.
    ///
    /// @param tokenId      Token to update.
    /// @param harvestDate  Refined EOS estimate (0 = no change).
    /// @param status       New status (0=claimed 1=verified 2=harvested 3=defaulted).
    function updateToken(
        uint256 tokenId,
        uint32  harvestDate,
        uint8   status
    ) external onlyOracle {
        CropToken storage t = tokens[tokenId];
        if (t.landTitleId == 0) revert TokenNotFound();
        if (harvestDate > 0) t.harvestDate = harvestDate;
        t.status = status;
        emit TokenUpdated(tokenId, t.harvestDate, status);
    }

    // ================================================================
    //  CROP TYPE MANAGEMENT
    // ================================================================

    /// @notice Set or update a crop type name and variety list.
    function setCropType(
        uint16            cropCode,
        string  calldata  name,
        string[] calldata vars
    ) external onlyOwner {
        cropName[cropCode] = name;
        varieties[cropCode] = vars;
        emit CropTypeSet(cropCode, name);
    }

    /// @notice Append a variety to an existing crop type.
    function addVariety(uint16 cropCode, string calldata variety) external onlyOwner {
        varieties[cropCode].push(variety);
    }

    // ================================================================
    //  ORACLE SIGNER MANAGEMENT
    // ================================================================

    function setOracleSigner(address signer, bool allowed) external onlyOwner {
        if (signer == address(0)) revert ZeroAddress();
        oracleSigners[signer] = allowed;
        emit OracleSignerSet(signer, allowed);
    }

    // ================================================================
    //  VIEW FUNCTIONS
    // ================================================================

    /// @notice Full metadata for a token — primary read for drawLoan.
    function getToken(uint256 tokenId) external view returns (CropToken memory) {
        return tokens[tokenId];
    }

    /// @notice Full metadata for a collection.
    function getCollection(uint256 collectionId) external view returns (Collection memory) {
        return collections[collectionId];
    }

    /// @notice Returns the EIP-712 digest for a voucher — used by backend to sign.
    function getVoucherDigest(Voucher calldata v) external view returns (bytes32) {
        return _voucherDigest(v);
    }

    /// @notice All token IDs ever minted for a land title.
    ///         Farmer flow: NilaLandTitle.ownerOf(landTitleId) → getLandTitleTokens()
    ///         → balanceOf(farmer, tokenId) > 0 filters to currently held tokens.
    function getLandTitleTokens(uint32 landTitleId)
        external view returns (uint256[] memory)
    {
        return landTitleTokens[landTitleId];
    }

    /// @notice Convenience: is a collection a standing (non-order) collection?
    function isStanding(uint256 collectionId) external view returns (bool) {
        return collections[collectionId].buyer == address(0);
    }

    // ================================================================
    //  EIP-712 INTERNAL
    // ================================================================

    bytes32 private constant VOUCHER_TYPEHASH = keccak256(
        "Voucher(address to,uint256 collectionId,uint32 landTitleId,uint16 cropCode,"
        "uint16 varietyCode,uint32 sosDate,uint256 committedQtyKg)"
    );

    function _voucherDigest(Voucher calldata v) internal view returns (bytes32) {
        return _hashTypedDataV4(keccak256(abi.encode(
            VOUCHER_TYPEHASH,
            v.to,
            v.collectionId,
            v.landTitleId,
            v.cropCode,
            v.varietyCode,
            v.sosDate,
            v.committedQtyKg
        )));
    }

    // ================================================================
    //  UUPS
    // ================================================================

    /// @dev Only owner can authorise an implementation upgrade.
    function _authorizeUpgrade(address) internal override onlyOwner {}

    // ================================================================
    //  ADMIN
    // ================================================================

    function pause()   external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
}

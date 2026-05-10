// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721EnumerableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721URIStorageUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract NilaLandTitle is
    Initializable,
    ERC721Upgradeable,
    ERC721EnumerableUpgradeable,
    ERC721URIStorageUpgradeable,
    OwnableUpgradeable,
    UUPSUpgradeable
{
    using ECDSA for bytes32;

    uint256 private _tokenIds;

    // Mapping for whitelisted addresses
    mapping(address => bool) private _whitelist;

    // Mapping for title names
    mapping(uint256 => string) private _titleNames;

    // Anti-replay
    mapping(bytes32 => bool) public usedMessages;

    // ─── CS023: Gated property data ───────────────────────────
    // All new storage appended after existing slots (proxy-safe).

    /// @dev Commitment per token: keccak256(abi.encodePacked(recordHash, tokenId, _salt)).
    ///      Public via getCommitment() — safe because it's a one-way derivation.
    mapping(uint256 => bytes32) private _commitment;

    /// @dev Actual record hash per token (SHA-256 of canonical record.json).
    ///      Never exposed via a public getter — only returned through gated getRecordHash().
    mapping(uint256 => bytes32) private _recordHash;

    /// @dev Salt used in commitment derivation.  Rotatable by owner.
    bytes32 private _salt;

    /// @dev nIN token used for view fees.
    IERC20 public ninToken;

    /// @dev Fee in nIN (wei) that public viewers pay to read recordHash.
    uint256 public viewFeeNin;

    /// @dev Accumulated nIN fees claimable by each token owner.
    mapping(address => uint256) public viewFeeBalance;

    /// @dev Discount whitelist — addresses that pay the discounted fee.
    mapping(address => bool) public viewerApproved;

    /// @dev Discounted fee in nIN (wei) for whitelisted viewers.
    ///      Appended after existing slots — proxy-safe.
    uint256 public discountFeeNin;

    // ─── Events ───────────────────────────────────────────────

    event TitleNameSet(uint256 indexed tokenId, string titleName);
    event TitleNameUpdated(uint256 indexed tokenId, string oldTitleName, string newTitleName);
    event RecordHashUpdated(uint256 indexed tokenId, bytes32 commitment);
    event ViewFeePaid(uint256 indexed tokenId, address indexed caller, uint256 amount);
    event ViewFeesClaimed(address indexed owner, uint256 amount);
    event ViewerDiscountChanged(address indexed viewer, bool discounted);
    event ViewFeeChanged(uint256 oldFee, uint256 newFee);
    event SaltRotated();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers(); // protect the implementation contract
    }

    function initialize(address initialOwner) public initializer {
        __ERC721_init("NilaLandTitle", "LAND");
        __ERC721Enumerable_init();
        __ERC721URIStorage_init();
        __Ownable_init(initialOwner);
        __UUPSUpgradeable_init();
    }

    // ----------------- Admin / whitelist -----------------

    function addToWhitelist(address signer) public onlyOwner {
        _whitelist[signer] = true;
    }

    function removeFromWhitelist(address signer) public onlyOwner {
        _whitelist[signer] = false;
    }

    function isWhitelisted(address signer) public view returns (bool) {
        return _whitelist[signer];
    }

    // ----------------- Minting with signed meta -----------------

    function mintAndSend(
        address to,
        string memory metadata,
        string memory titleName,
        bytes memory signature
    ) public {
        require(to != address(0), "Invalid recipient address");

        // Include contract + chain + full payload to prevent replay & tampering
        bytes32 messageHash = keccak256(
            abi.encodePacked(
                address(this),
                block.chainid,
                to,
                metadata,
                titleName
            )
        );

        require(!usedMessages[messageHash], "Signature already used");

        bytes32 ethSignedMessageHash = _getEthSignedMessageHash(messageHash);
        address signer = _recoverSigner(ethSignedMessageHash, signature);
        require(_whitelist[signer], "Signer is not whitelisted");

        usedMessages[messageHash] = true;

        _tokenIds++;
        uint256 tokenId = _tokenIds;
        _titleNames[tokenId] = titleName;

        _safeMint(to, tokenId);
        _setTokenURI(tokenId, metadata);

        emit TitleNameSet(tokenId, titleName);
    }

    // ----------------- Title name helpers -----------------

    function getTitleName(uint256 tokenId) public view returns (string memory) {
        return _titleNames[tokenId];
    }

    function updateTitleName(uint256 tokenId, string memory newTitleName) public onlyOwner {
        string memory oldTitleName = _titleNames[tokenId];
        _titleNames[tokenId] = newTitleName;

        emit TitleNameUpdated(tokenId, oldTitleName, newTitleName);
    }

    // ─────────── CS023: Gated property data ────────────

    /// @notice Update the record hash + commitment for a token.
    ///         Backend computes: commitment = keccak256(abi.encodePacked(hash, tokenId, salt))
    ///         Whitelisted signer signs (contract, chainId, tokenId, recordHash, commitment).
    function setRecordHash(
        uint256 tokenId,
        bytes32 recordHash,
        bytes32 commitment,
        bytes memory signature
    ) external {
        require(_ownerOf(tokenId) != address(0), "token does not exist");

        bytes32 messageHash = keccak256(
            abi.encodePacked(
                address(this),
                block.chainid,
                tokenId,
                recordHash,
                commitment
            )
        );
        require(!usedMessages[messageHash], "signature already used");

        bytes32 ethSignedMessageHash = _getEthSignedMessageHash(messageHash);
        address signer = _recoverSigner(ethSignedMessageHash, signature);
        require(_whitelist[signer], "signer is not whitelisted");

        usedMessages[messageHash] = true;
        _recordHash[tokenId] = recordHash;
        _commitment[tokenId] = commitment;

        emit RecordHashUpdated(tokenId, commitment);
    }

    /// @notice Read the actual record hash.  Fee tiers:
    ///         1. Token owner → free
    ///         2. Whitelisted viewer → discountFeeNin
    ///         3. Everyone else → viewFeeNin
    function getRecordHash(uint256 tokenId) external returns (bytes32) {
        address tokenOwner = _ownerOf(tokenId);
        require(tokenOwner != address(0), "token does not exist");

        if (msg.sender != tokenOwner) {
            uint256 fee = viewerApproved[msg.sender] ? discountFeeNin : viewFeeNin;
            if (fee > 0) {
                require(
                    ninToken.transferFrom(msg.sender, address(this), fee),
                    "nIN fee transfer failed"
                );
                viewFeeBalance[tokenOwner] += fee;
                emit ViewFeePaid(tokenId, msg.sender, fee);
            }
        }

        return _recordHash[tokenId];
    }

    /// @notice Batch version: read record hashes for multiple tokens in one tx.
    ///         Single nIN transferFrom for the total fee. Same tier logic per token.
    function getRecordHashBatch(uint256[] calldata tokenIds) external returns (bytes32[] memory) {
        bytes32[] memory hashes = new bytes32[](tokenIds.length);
        uint256 totalFee = 0;

        for (uint256 i = 0; i < tokenIds.length; i++) {
            address tokenOwner = _ownerOf(tokenIds[i]);
            require(tokenOwner != address(0), "token does not exist");

            if (msg.sender != tokenOwner) {
                uint256 fee = viewerApproved[msg.sender] ? discountFeeNin : viewFeeNin;
                totalFee += fee;
                viewFeeBalance[tokenOwner] += fee;
                emit ViewFeePaid(tokenIds[i], msg.sender, fee);
            }

            hashes[i] = _recordHash[tokenIds[i]];
        }

        if (totalFee > 0) {
            require(
                ninToken.transferFrom(msg.sender, address(this), totalFee),
                "nIN fee transfer failed"
            );
        }

        return hashes;
    }

    /// @notice Public view: returns the commitment (one-way derivation, not the hash).
    ///         Useful for change detection without revealing the actual record hash.
    function getCommitment(uint256 tokenId) external view returns (bytes32) {
        return _commitment[tokenId];
    }

    /// @notice View-only quote: what fee applies for this caller on this token?
    ///         Returns 0 for owner, discountFeeNin for whitelisted, viewFeeNin for everyone else.
    function quoteViewFee(uint256 tokenId, address caller) external view returns (uint256) {
        address tokenOwner = _ownerOf(tokenId);
        require(tokenOwner != address(0), "token does not exist");
        if (caller == tokenOwner) return 0;
        if (viewerApproved[caller]) return discountFeeNin;
        return viewFeeNin;
    }

    /// @notice Token owner claims all accumulated view fees.
    function claimViewFees() external {
        uint256 amount = viewFeeBalance[msg.sender];
        require(amount > 0, "no fees to claim");
        viewFeeBalance[msg.sender] = 0;
        require(ninToken.transfer(msg.sender, amount), "nIN transfer failed");
        emit ViewFeesClaimed(msg.sender, amount);
    }

    // ─────────── CS023: Admin config ─────────────────

    function setViewerDiscount(address viewer, bool discounted) external onlyOwner {
        viewerApproved[viewer] = discounted;
        emit ViewerDiscountChanged(viewer, discounted);
    }

    function setViewerDiscountBatch(address[] calldata viewers, bool discounted) external onlyOwner {
        for (uint256 i = 0; i < viewers.length; i++) {
            viewerApproved[viewers[i]] = discounted;
            emit ViewerDiscountChanged(viewers[i], discounted);
        }
    }

    function setViewFee(uint256 feeWei) external onlyOwner {
        emit ViewFeeChanged(viewFeeNin, feeWei);
        viewFeeNin = feeWei;
    }

    function setDiscountFee(uint256 feeWei) external onlyOwner {
        emit ViewFeeChanged(discountFeeNin, feeWei);
        discountFeeNin = feeWei;
    }

    function setSalt(bytes32 newSalt) external onlyOwner {
        _salt = newSalt;
        emit SaltRotated();
    }

    function getSalt() external view onlyOwner returns (bytes32) {
        return _salt;
    }

    function setNinToken(address token) external onlyOwner {
        require(token != address(0), "zero address");
        ninToken = IERC20(token);
    }

    // ----------------- Signature helpers -----------------

    function _getEthSignedMessageHash(bytes32 messageHash) internal pure returns (bytes32) {
        // Same as eth_sign / personal_sign prefix
        return keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", messageHash));
    }

    function _recoverSigner(bytes32 ethSignedMessageHash, bytes memory signature)
        internal
        pure
        returns (address)
    {
        return ethSignedMessageHash.recover(signature);
    }

    // ----------------- UUPS auth -----------------

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    // ----------------- Required overrides -----------------

    function _increaseBalance(address account, uint128 value)
        internal
        virtual
        override(ERC721Upgradeable, ERC721EnumerableUpgradeable)
    {
        super._increaseBalance(account, value);
    }

    function _update(address to, uint256 tokenId, address auth)
        internal
        virtual
        override(ERC721Upgradeable, ERC721EnumerableUpgradeable)
        returns (address)
    {
        return super._update(to, tokenId, auth);
    }

    function tokenURI(uint256 tokenId)
        public
        view
        virtual
        override(ERC721Upgradeable, ERC721URIStorageUpgradeable)
        returns (string memory)
    {
        return super.tokenURI(tokenId);
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override(ERC721Upgradeable, ERC721EnumerableUpgradeable, ERC721URIStorageUpgradeable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}

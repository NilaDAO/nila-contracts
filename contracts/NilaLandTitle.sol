// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721EnumerableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721URIStorageUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

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

    // Events for title names
    event TitleNameSet(uint256 indexed tokenId, string titleName);
    event TitleNameUpdated(uint256 indexed tokenId, string oldTitleName, string newTitleName);

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

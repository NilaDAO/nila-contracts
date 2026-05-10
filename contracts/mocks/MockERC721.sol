// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract MockERC721 is ERC721, Ownable {
    constructor(address initialOwner)
        ERC721("LandTitle", "LAND")
        Ownable(initialOwner)
    {}

    function mint(address to, uint256 tokenId) external onlyOwner {
        _safeMint(to, tokenId); // ✅ real mint (no transfer-from(0))
    }
}
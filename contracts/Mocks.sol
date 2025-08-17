// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";

// A simple mock ERC20 token for testing
contract MockERC20 is ERC20 {
    constructor() ERC20("Mock Token", "MCK") {
        _mint(msg.sender, 1_000_000 * 10**18); // Give creator a large supply
    }
}

// A simple mock ERC721 (NFT) token for testing
contract MockERC721 is ERC721 {
    constructor() ERC721("Mock NFT", "MNFT") {}

    /**
     * @notice Allows anyone to mint a new NFT. For testing only.
     * @param to The address to receive the new NFT.
     * @param tokenId The ID of the new NFT.
     */
    function mint(address to, uint256 tokenId) public {
        _mint(to, tokenId);
    }
}
// contracts/Mocks.sol
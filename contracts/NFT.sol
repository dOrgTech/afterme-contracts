// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "@openzeppelin/contracts/utils/Base64.sol";

/**
 * @title Curated YouTube NFT Collection
 * @dev An NFT contract with a curated list of videos. Anyone can mint the
 * next available video for a fee. The owner can add new videos to the
 * list at any time, and the total supply is not publicly visible.
 */
contract CuratedYouTubeNFT is ERC721Enumerable, Ownable {
    using Strings for uint256;

    // --- State Variables ---

    uint256 public mintPrice;
    
    // The list of video IDs is PRIVATE to hide the total supply.
    string[] private _videoIds;

    // The minting progress is also PRIVATE.
    uint256 private _nextTokenId;

    // --- Events ---
    event VideoMinted(uint256 indexed tokenId, address indexed minter);
    event VideosAdded(uint256 count);

    // --- Constructor ---

    constructor(address initialOwner, uint256 initialMintPrice)
        ERC721("Curated YouTube Collection", "CYTC")
        Ownable(initialOwner)
    {
        mintPrice = initialMintPrice;
        
        // Populate the initial list of videos
        _videoIds.push("9dHVsd421CQ");
        _videoIds.push("9adTkkn-F-s");
        _videoIds.push("Gqw0Q4j--FI");
        _videoIds.push("eBIW93xvlEA");
        _videoIds.push("lpb-WQ7ijes");
        _videoIds.push("eBIW93xvlEA");
    }

    // --- Minting Function ---

    /**
     * @dev Mints the next available NFT from the curated list.
     * Can be called by anyone who pays the minting fee.
     * Fails if all currently available videos have been minted.
     */
    function mintNext() public payable {
        require(_nextTokenId < _videoIds.length, "No new tokens at this time");
        require(msg.value >= mintPrice, "Not enough funds sent to mint");

        uint256 tokenId = _nextTokenId;
        _safeMint(msg.sender, tokenId);
        _nextTokenId++;
        
        emit VideoMinted(tokenId, msg.sender);
    }

    // --- Metadata Function ---

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        ownerOf(tokenId); // Reverts if token doesn't exist

        string memory videoId = _videoIds[tokenId];
        string memory imageUrl = string(abi.encodePacked("https://img.youtube.com/vi/", videoId, "/hqdefault.jpg"));
        string memory animationUrl = string(abi.encodePacked("https://www.youtube.com/embed/", videoId));

        string memory json = Base64.encode(
            bytes(
                string(
                    abi.encodePacked(
                        '{"name": "Curated YouTube NFT #',
                        tokenId.toString(),
                        '", "description": "A curated, sequentially minted NFT from a growing collection.", "image": "',
                        imageUrl,
                        '", "animation_url": "',
                        animationUrl,
                        '"}'
                    )
                )
            )
        );

        return string(abi.encodePacked("data:application/json;base64,", json));
    }

    // --- Administrative Functions ---

    /**
     * @dev Appends new video IDs to the collection's minting list. Owner-only.
     * @param newVideoIds An array of new YouTube video IDs to add.
     */
    function addVideos(string[] memory newVideoIds) public onlyOwner {
        for (uint i = 0; i < newVideoIds.length; i++) {
            _videoIds.push(newVideoIds[i]);
        }
        emit VideosAdded(newVideoIds.length);
    }

    /**
     * @dev Allows the owner to withdraw the entire contract balance.
     */
    function withdraw() public onlyOwner {
        (bool success, ) = owner().call{value: address(this).balance}("");
        require(success, "Transfer failed.");
    }

    /**
     * @dev Allows the owner to update the minting price.
     */
    function setMintPrice(uint256 newMintPrice) public onlyOwner {
        mintPrice = newMintPrice;
    }
}
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./Will.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";

/**
 * @title Source (Estate Planning Factory)
 * @notice A factory contract for creating individual 'Will' contracts.
 */
 
contract Source is Ownable {
    
    // --- State Variables ---
    mapping(address => address) public userWills;
    uint256 public basePlatformFee;
    uint256 public diaryPlatformFee;

    // --- Events ---
    event WillCreated(address indexed user, address indexed willAddress, bool hasDiary);
    event WillCleared(address indexed user, address indexed willAddress);

    constructor(address _initialOwner) Ownable(_initialOwner) {
        basePlatformFee = 0 ether;
        // The diary fee is now set to 0.3 XTZ (ether is a unit for 10^18 wei)
        diaryPlatformFee = 0.3 ether; 
    }

    receive() external payable {}

    // --- Owner Functions ---
    function setBasePlatformFee(uint256 _newFee) external onlyOwner {
        basePlatformFee = _newFee;
    }
    function setDiaryPlatformFee(uint256 _newFee) external onlyOwner {
        diaryPlatformFee = _newFee;
    }
    function withdrawFees() external onlyOwner {
        uint256 balance = address(this).balance;
        require(balance > 0, "No fees to withdraw.");
        (bool success, ) = owner().call{value: balance}("");
        require(success, "ETH withdrawal failed.");
    }

    // --- Public Functions ---
    function createWill(
        address[] memory heirs,
        uint256[] memory distribution,
        uint256 interval,
        Will.Erc20Distribution[] calldata erc20s,
        Will.NftDistribution[] calldata nfts,
        bool _hasDiary
    ) external payable {
        uint256 requiredFee = _hasDiary ? diaryPlatformFee : basePlatformFee;
        require(msg.value >= requiredFee, "Msg.value must cover the required platform fee.");
        require(userWills[msg.sender] == address(0), "User already has an existing will.");

        uint256 willValue = msg.value - requiredFee;
        
        // 1. Create the Will contract with only the immutable parameters
        Will newWill = new Will{value: willValue}(
            msg.sender,
            interval,
            address(this),
            requiredFee,
            _hasDiary
        );

        userWills[msg.sender] = address(newWill);
        
        // 2. Call the initialize function, passing the structs directly.
        newWill.initialize(
            heirs,
            distribution,
            erc20s,
            nfts
        );

        // 3. Pull approved assets from the user to the new Will contract
        for (uint i = 0; i < erc20s.length; i++) {
            if (erc20s[i].amount > 0) {
                IERC20(erc20s[i].tokenContract).transferFrom(msg.sender, address(newWill), erc20s[i].amount);
            }
        }
        for (uint i = 0; i < nfts.length; i++) {
            IERC721(nfts[i].tokenContract).transferFrom(msg.sender, address(newWill), nfts[i].tokenId);
        }

        emit WillCreated(msg.sender, address(newWill), _hasDiary);
    }

    function clearWillRecord(address _user) external {
        address willAddress = userWills[_user];
        require(willAddress != address(0), "No will found for this user.");
        require(msg.sender == willAddress, "Caller is not the registered will.");
        delete userWills[_user];
        emit WillCleared(_user, willAddress);
    }
}
// contracts/Source.sol
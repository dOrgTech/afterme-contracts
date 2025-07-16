// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./Will.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";

/**
 * @title Source (Estate Planning Factory)
 * @notice A factory contract for creating individual 'Will' contracts.
 * It manages platform settings and fees.
 * @dev This contract should be owned by the dApp administrator. The user must approve
 * this contract to spend their tokens (ERC20, ERC721) BEFORE calling createWill.
 */
 
contract Source is Ownable {
    
    // --- Structs for function arguments ---

    struct Erc20Distribution {
        address tokenContract;
        uint256 amount;
    }

    struct NftDistribution {
        address tokenContract;
        uint256 tokenId;
        address heir;
    }

    // --- State Variables ---

    /// @notice A mapping from a user's address to their created Will contract.
    mapping(address => address) public userWills;
    
    /// @notice The ETH fee charged by the platform to create a will.
    uint256 public platformFee;

    // --- Events ---
    event WillCreated(address indexed user, address indexed willAddress);
    event WillCleared(address indexed user, address indexed willAddress);

    /**
     * @dev Sets the initial owner and default platform fee.
     * @param _initialOwner The address of the contract administrator.
     */
    constructor(address _initialOwner) Ownable(_initialOwner) {
        platformFee = 0.01 ether; // Default 0.01 ETH fee
    }

    // --- Receive Function ---

    /**
     * @notice Allows the contract to receive ETH payments (e.g., from Will contract fees).
     */
    receive() external payable {}

    // --- Owner Functions ---

    /**
     * @notice Updates the platform fee required to create a will.
     * @param _newFee The new fee in wei.
     */
    function setPlatformFee(uint256 _newFee) external onlyOwner {
        platformFee = _newFee;
    }

    /**
     * @notice Allows the owner to withdraw accumulated platform fees.
     */
    function withdrawFees() external onlyOwner {
        uint256 balance = address(this).balance;
        require(balance > 0, "No fees to withdraw.");
        (bool success, ) = owner().call{value: balance}("");
        require(success, "ETH withdrawal failed.");
    }

    // --- Public Functions ---

    /**
     * @notice Creates a new Will contract for the sender.
     * @dev The sender must send ETH equal to the will's value + the platformFee.
     * The sender MUST approve this contract to manage the specified amounts of
     * ERC20s and the specific NFTs before calling this function.
     * @param heirs An array of heir addresses for fungible asset distribution.
     * @param distribution An array of percentages for fungible asset distribution.
     * @param interval The inactivity interval in seconds.
     * @param erc20s A list of ERC20 tokens and the total amount of each to include in the will.
     * @param nfts A list of specific NFTs to include in the will and their designated heirs.
     */
    function createWill(
        address[] memory heirs,
        uint256[] memory distribution,
        uint256 interval,
        Erc20Distribution[] calldata erc20s,
        NftDistribution[] calldata nfts
    ) external payable {
        require(msg.value >= platformFee, "Msg.value must cover the platform fee.");
        require(userWills[msg.sender] == address(0), "User already has an existing will.");

        uint256 willValue = msg.value - platformFee;
        
        // Prepare arrays for the Will constructor to avoid "stack too deep" errors.
        address[] memory erc20Contracts = new address[](erc20s.length);
        for(uint i = 0; i < erc20s.length; i++) {
            erc20Contracts[i] = erc20s[i].tokenContract;
        }

        address[] memory nftContracts = new address[](nfts.length);
        uint256[] memory nftTokenIds = new uint256[](nfts.length);
        address[] memory nftHeirs = new address[](nfts.length);
        for(uint i = 0; i < nfts.length; i++) {
            nftContracts[i] = nfts[i].tokenContract;
            nftTokenIds[i] = nfts[i].tokenId;
            nftHeirs[i] = nfts[i].heir;
        }

        Will newWill = new Will{value: willValue}(
            msg.sender,
            heirs,
            distribution,
            interval,
            erc20Contracts,
            nftContracts,
            nftTokenIds,
            nftHeirs,
            address(this),
            platformFee
        );

        userWills[msg.sender] = address(newWill);

        // Pull approved assets from the user to the new Will contract
        for (uint i = 0; i < erc20s.length; i++) {
            if (erc20s[i].amount > 0) {
                IERC20(erc20s[i].tokenContract).transferFrom(msg.sender, address(newWill), erc20s[i].amount);
            }
        }

        for (uint i = 0; i < nfts.length; i++) {
            IERC721(nfts[i].tokenContract).transferFrom(msg.sender, address(newWill), nfts[i].tokenId);
        }

        emit WillCreated(msg.sender, address(newWill));
    }

    /**
     * @notice Allows a Will contract to clear its record from the factory upon cancellation.
     * @dev This function should only be callable by a Will contract created by this factory.
     * @param _user The owner of the will being cleared.
     */
    function clearWillRecord(address _user) external {
        address willAddress = userWills[_user];
        require(willAddress != address(0), "No will found for this user.");
        require(msg.sender == willAddress, "Caller is not the registered will.");
        delete userWills[_user];
        emit WillCleared(_user, willAddress);
    }
}
// contracts/Source.sol
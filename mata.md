# Folder Structure

- mata/
  - contracts/
    - Mocks.sol
    - Source.sol
    - Will.sol

# File Contents

### `contracts/Mocks.sol`
```sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";

// A simple mock ERC20 token for testing
contract MockERC20 is ERC20 {
    constructor() ERC20("Mock Token", "MCK") {
        _mint(msg.sender, 1000 * 10**18); // Give creator 1000 tokens
    }
}

// A simple mock NFT for testing
contract MockERC721 is ERC721 {
    constructor() ERC721("Mock NFT", "MNFT") {}

    function mint(address to, uint256 tokenId) public {
        _mint(to, tokenId);
    }
}
// contracts/Mocks.sol
```

### `contracts/Source.sol`
```sol
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
```

### `contracts/Will.sol`
```sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

// --- PASTED FROM OPENZEPPELIN - START ---
// This is the code from the missing ReentrancyGuard.sol file.
// By including it here, we no longer need to import it.

/**
 * @dev Contract module that helps prevent reentrant calls to a function.
 *
 * Inheriting from `ReentrancyGuard` will make the {nonReentrant} modifier
 * available, which can be applied to functions to make sure there are no nested
 * (reentrant) calls to them.
 *
 * Note that because there is a single `_status` variable, once a function has
 * been protected by {nonReentrant}, it cannot call another function protected
 * by the same modifier. Transitive calls are not supported.
 *
 * VIEW https://eips.ethereum.org/EIPS/eip-1052
 */
abstract contract ReentrancyGuard {
    // Booleans are more expensive than uint256 or any type that takes up a full
    // word because each write operation emits an extra SLOAD to first read the
    // slot's contents, replace the bits taken up by the boolean, and then write
    // back. This is the compiler's defense against contract upgrades and
    // pointer aliasing, and it cannot be disabled.

    // The values are not arbitrary constants but results of ASCII text like
    // 'REENTRANCY_GUARD' converted to numbers with a small base.
    // See https://etherscan.io/address/0x0000000000000000000000000000000000000001
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;

    uint256 private _status;

    constructor() {
        _status = _NOT_ENTERED;
    }

    /**
     * @dev Prevents a contract from calling itself, directly or indirectly.
     * Calling a `nonReentrant` function from another `nonReentrant`
     * function is not supported. It is possible to prevent this from happening
     * by making the `nonReentrant` function external, and make it call a
     * `private` function that does the actual work.
     */
    modifier nonReentrant() {
        _preReentryCheck();
        _status = _ENTERED;
        _;
        _status = _NOT_ENTERED;
    }

    function _preReentryCheck() private view {
        // On the first call to nonReentrant, _status will be _NOT_ENTERED
        if (_status == _ENTERED) {
            revert ReentrancyGuardReentrantCall();
        }
    }
}

/**
 * @dev This error is returned by the `nonReentrant` modifier from the {ReentrancyGuard} contract.
 */
error ReentrancyGuardReentrantCall();

// --- PASTED FROM OPENZEPPELIN - END ---

/**
 * @notice Interface for the Source contract to avoid circular dependencies.
 */
interface ISource {
    function clearWillRecord(address _user) external;
}

/**
 * @title Will
 * @notice A smart contract for an individual will or estate plan.
 */
contract Will is Ownable, ReentrancyGuard { // Inheritance remains the same
    // --- Structs ---
    struct Erc20Asset {
        IERC20 token;
    }

    struct Erc721Asset {
        IERC721 token;
        uint256 tokenId;
        address heir;
    }

    // --- Constants ---
    uint256 private constant EXECUTOR_WINDOW = 1 days;
    address private constant EXECUTOR_ADDRESS = 0xa9F8F9C0bf3188cEDdb9684ae28655187552bAE9;
    uint256 public constant EXECUTION_FEE_BPS = 50; // 0.5% in basis points (50 / 10,000)

    // --- State Variables ---
    bool public executed;
    uint256 public lastUpdate;
    uint256 public immutable interval;
    address public immutable sourceContract;
    uint256 public immutable terminationFee;

    address[] public heirs;
    uint256[] public distributionPercentages;
    Erc20Asset[] public erc20Assets;
    Erc721Asset[] public erc721Assets;

    // --- Events ---
    event Ping(uint256 newLastUpdate);
    event Executed(address executor, uint256 ethFee, address feeRecipient);
    event Cancelled(uint256 feePaid);

    // --- Modifiers ---
    modifier onlyOwnerWhenActive() {
        require(!executed, "Will has been executed or cancelled.");
        require(owner() == msg.sender, "Only the owner can call this function.");
        _;
    }

    modifier canExecute() {
        require(!executed, "Will has been executed or cancelled.");
        uint256 gracePeriodEnd = lastUpdate + interval;
        require(block.timestamp >= gracePeriodEnd, "Grace period has not ended.");

        uint256 executorPeriodEnd = gracePeriodEnd + EXECUTOR_WINDOW;

        if (block.timestamp < executorPeriodEnd) {
            require(msg.sender == EXECUTOR_ADDRESS, "Only the designated executor can call this now.");
        }
        _;
    }

    // --- Constructor ---
    constructor(
        address initialOwner,
        address[] memory _heirs,
        uint256[] memory _distro,
        uint256 _interval,
        address[] memory _erc20Contracts,
        address[] memory _nftContracts,
        uint256[] memory _nftTokenIds,
        address[] memory _nftHeirs,
        address _sourceContract,
        uint256 _terminationFee
    ) payable Ownable(initialOwner) { // <<< FIX IS HERE
        require(_heirs.length == _distro.length, "Heirs and distributions length mismatch.");
        require(_heirs.length > 0, "Heirs cannot be empty.");
        require(
            _nftContracts.length == _nftTokenIds.length && _nftTokenIds.length == _nftHeirs.length,
            "NFT data array lengths mismatch."
        );

        uint256 totalPercentage = 0;
        for (uint256 i = 0; i < _distro.length; i++) {
            totalPercentage += _distro[i];
        }
        require(totalPercentage == 100, "Distribution percentages must sum to 100.");

        lastUpdate = block.timestamp;
        interval = _interval;
        sourceContract = _sourceContract;
        terminationFee = _terminationFee;
        heirs = _heirs;
        distributionPercentages = _distro;

        for (uint i = 0; i < _erc20Contracts.length; i++) {
            erc20Assets.push(Erc20Asset(IERC20(_erc20Contracts[i])));
        }

        for (uint i = 0; i < _nftContracts.length; i++) {
            erc721Assets.push(Erc721Asset(IERC721(_nftContracts[i]), _nftTokenIds[i], _nftHeirs[i]));
        }

        // The _transferOwnership call is no longer needed as it's handled by Ownable(initialOwner)
    }

    // --- Owner Functions ---
    function ping() external onlyOwnerWhenActive {
        lastUpdate = block.timestamp;
        emit Ping(lastUpdate);
    }

    function cancelAndWithdraw() external onlyOwnerWhenActive nonReentrant {
        executed = true; // Mark as executed to prevent further actions
        address payable _owner = payable(owner());

        // 1. Pay termination fee and clear record from Source contract
        if (terminationFee > 0) {
            require(address(this).balance >= terminationFee, "Insufficient ETH for termination fee.");
            (bool success, ) = sourceContract.call{value: terminationFee}("");
            require(success, "Termination fee transfer failed.");
        }
        ISource(sourceContract).clearWillRecord(_owner);

        // 2. Withdraw all remaining assets to the owner
        for (uint i = 0; i < erc20Assets.length; i++) {
            IERC20 token = erc20Assets[i].token;
            uint256 balance = token.balanceOf(address(this));
            if (balance > 0) {
                token.transfer(_owner, balance);
            }
        }

        for (uint i = 0; i < erc721Assets.length; i++) {
            Erc721Asset memory asset = erc721Assets[i];
            asset.token.safeTransferFrom(address(this), _owner, asset.tokenId);
        }

        uint256 remainingEth = address(this).balance;
        if (remainingEth > 0) {
            (bool success, ) = _owner.call{value: remainingEth}("");
            require(success, "ETH transfer failed.");
        }

        emit Cancelled(terminationFee);
    }

    // --- Executor Functions ---
    function execute() external nonReentrant canExecute {
        executed = true;

        // 1. Determine fee recipient
        uint256 gracePeriodEnd = lastUpdate + interval;
        uint256 executorPeriodEnd = gracePeriodEnd + EXECUTOR_WINDOW;
        address feeRecipient;
        if (block.timestamp < executorPeriodEnd) {
            feeRecipient = sourceContract; // Fee to platform if executed by designated executor
        } else {
            feeRecipient = msg.sender; // Fee to public executor
        }
        
        uint256 totalEthFee = 0;

        // 2. Distribute ETH
        uint256 totalEth = address(this).balance;
        if (totalEth > 0) {
            uint256 ethFee = (totalEth * EXECUTION_FEE_BPS) / 10000;
            totalEthFee = ethFee;
            uint256 distributableEth = totalEth - ethFee;

            if (ethFee > 0) {
                (bool success, ) = payable(feeRecipient).call{value: ethFee}("");
                require(success, "ETH fee transfer failed.");
            }

            for (uint i = 0; i < heirs.length; i++) {
                uint256 share = (distributableEth * distributionPercentages[i]) / 100;
                if (share > 0) {
                    (bool success, ) = payable(heirs[i]).call{value: share}("");
                    require(success, "ETH transfer to heir failed.");
                }
            }
        }

        // 3. Distribute ERC20s
        for (uint i = 0; i < erc20Assets.length; i++) {
            IERC20 token = erc20Assets[i].token;
            uint256 totalTokens = token.balanceOf(address(this));
            if (totalTokens > 0) {
                uint256 tokenFee = (totalTokens * EXECUTION_FEE_BPS) / 10000;
                uint256 distributableTokens = totalTokens - tokenFee;

                if (tokenFee > 0) {
                    token.transfer(feeRecipient, tokenFee);
                }

                for (uint j = 0; j < heirs.length; j++) {
                    uint256 share = (distributableTokens * distributionPercentages[j]) / 100;
                    if (share > 0) {
                        token.transfer(heirs[j], share);
                    }
                }
            }
        }

        // 4. Distribute NFTs
        for (uint i = 0; i < erc721Assets.length; i++) {
            Erc721Asset memory asset = erc721Assets[i];
            asset.token.safeTransferFrom(address(this), asset.heir, asset.tokenId);
        }

        emit Executed(msg.sender, totalEthFee, feeRecipient);
    }
    
    // --- View Functions ---
    function getContractBalance() external view returns (uint256) {
        return address(this).balance;
    }
}
// contracts/Will.sol
```

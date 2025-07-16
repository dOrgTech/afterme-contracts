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

// --- Structs for Public Data Retrieval ---

struct Erc20Detail {
    address tokenContract;
    uint256 balance;
}

struct Erc721Detail {
    address tokenContract;
    uint256 tokenId;
    address heir;
}

struct WillDetails {
    address owner;
    uint256 interval;
    uint256 lastUpdate;
    bool executed;
    uint256 ethBalance;
    address[] heirs;
    uint256[] distributionPercentages;
    Erc20Detail[] erc20Details;
    Erc721Detail[] erc721Details;
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
    ) payable Ownable(initialOwner) {
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

    /**
     * @notice Returns all relevant data for a will in a single call for frontend use.
     */
    function getWillDetails() external view returns (WillDetails memory) {
        // Populate ERC20 details including current balances
        Erc20Detail[] memory _erc20Details = new Erc20Detail[](erc20Assets.length);
        for (uint i = 0; i < erc20Assets.length; i++) {
            IERC20 token = erc20Assets[i].token;
            _erc20Details[i] = Erc20Detail({
                tokenContract: address(token),
                balance: token.balanceOf(address(this))
            });
        }

        // Populate ERC721 details
        Erc721Detail[] memory _erc721Details = new Erc721Detail[](erc721Assets.length);
        for (uint i = 0; i < erc721Assets.length; i++) {
            Erc721Asset memory asset = erc721Assets[i];
            _erc721Details[i] = Erc721Detail({
                tokenContract: address(asset.token),
                tokenId: asset.tokenId,
                heir: asset.heir
            });
        }

        // Return the aggregated struct
        return WillDetails({
            owner: owner(),
            interval: interval,
            lastUpdate: lastUpdate,
            executed: executed,
            ethBalance: address(this).balance,
            heirs: heirs,
            distributionPercentages: distributionPercentages,
            erc20Details: _erc20Details,
            erc721Details: _erc721Details
        });
    }

    function getContractBalance() external view returns (uint256) {
        return address(this).balance;
    }
}
// contracts/Will.sol
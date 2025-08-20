// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

// --- PASTED FROM OPENZEPPELIN - START ---
abstract contract ReentrancyGuard {
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;
    uint256 private _status;
    constructor() { _status = _NOT_ENTERED; }
    modifier nonReentrant() {
        _preReentryCheck();
        _status = _ENTERED;
        _;
        _status = _NOT_ENTERED;
    }
    function _preReentryCheck() private view { if (_status == _ENTERED) { revert ReentrancyGuardReentrantCall(); } }
}
error ReentrancyGuardReentrantCall();
// --- PASTED FROM OPENZEPPELIN - END ---

interface ISource {
    function clearWillRecord(address _user) external;
}

// --- Structs for Public Data Retrieval ---
struct Erc20Detail { address tokenContract; uint256 balance; }
struct Erc721Detail { address tokenContract; uint256 tokenId; address heir; }
struct WillDetails {
    address owner;
    uint256 interval;
    uint256 lastUpdate;
    bool executed;
    bool hasDiary;
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
contract Will is Ownable, ReentrancyGuard {
    // --- Structs ---
    struct Erc20Asset { IERC20 token; }
    struct Erc721Asset { IERC721 token; uint256 tokenId; address heir; }

    // Structs to accept data from the factory
    struct Erc20Distribution { address tokenContract; uint256 amount; }
    struct NftDistribution { address tokenContract; uint256 tokenId; address heir; }
    
    // --- Constants ---
    uint256 private constant EXECUTOR_WINDOW = 1 days;
    uint256 public constant EXECUTION_FEE_BPS = 50;

    // --- State Variables ---
    bool public executed;
    uint256 public lastUpdate;
    uint256 public immutable interval;
    address public immutable sourceContract;
    uint256 public immutable terminationFee;
    bool public immutable hasDiary;
    address public immutable executorAddress; // This will be set on creation
    address[] public heirs;
    uint256[] public distributionPercentages;
    Erc20Asset[] public erc20Assets;
    Erc721Asset[] public erc721Assets;
    bool private _initialized;

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
            require(msg.sender == executorAddress, "Only the designated executor can call this now.");
        }
        _;
    }

    // --- Constructor (Simplified) ---
    constructor(
        address initialOwner,
        uint256 _interval,
        address _sourceContract,
        uint256 _terminationFee,
        bool _hasDiary,
        address _executorAddress
    ) payable Ownable(initialOwner) {
        interval = _interval;
        sourceContract = _sourceContract;
        terminationFee = _terminationFee;
        hasDiary = _hasDiary;
        executorAddress = _executorAddress;
    }

    // --- Initializer Function (Modified) ---
    function initialize(
        address[] memory _heirs,
        uint256[] memory _distro,
        Erc20Distribution[] memory _erc20s,
        NftDistribution[] memory _nfts
    ) external {
        require(!_initialized, "Will: already initialized");
        require(msg.sender == sourceContract, "Will: not called by factory");
        _initialized = true;

        require(_heirs.length == _distro.length, "Heirs and distributions length mismatch.");
        require(_heirs.length > 0, "Heirs cannot be empty.");

        uint256 totalPercentage = 0;
        for (uint256 i = 0; i < _distro.length; i++) {
            totalPercentage += _distro[i];
        }
        require(totalPercentage == 100, "Distribution percentages must sum to 100.");

        lastUpdate = block.timestamp;
        heirs = _heirs;
        distributionPercentages = _distro;

        for (uint i = 0; i < _erc20s.length; i++) {
            erc20Assets.push(Erc20Asset(IERC20(_erc20s[i].tokenContract)));
        }
        for (uint i = 0; i < _nfts.length; i++) {
            erc721Assets.push(Erc721Asset(IERC721(_nfts[i].tokenContract), _nfts[i].tokenId, _nfts[i].heir));
        }
    }

    // --- Owner Functions ---
    function ping() external onlyOwnerWhenActive {
        lastUpdate = block.timestamp;
        emit Ping(lastUpdate);
    }
    function cancelAndWithdraw() external onlyOwnerWhenActive nonReentrant {
        executed = true; 
        address payable _owner = payable(owner());

        if (terminationFee > 0) {
            require(address(this).balance >= terminationFee, "Insufficient ETH for termination fee.");
            (bool success, ) = sourceContract.call{value: terminationFee}("");
            require(success, "Termination fee transfer failed.");
        }
        ISource(sourceContract).clearWillRecord(_owner);

        for (uint i = 0; i < erc20Assets.length; i++) {
            IERC20 token = erc20Assets[i].token;
            uint256 balance = token.balanceOf(address(this));
            if (balance > 0) { token.transfer(_owner, balance); }
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

        uint256 gracePeriodEnd = lastUpdate + interval;
        uint256 executorPeriodEnd = gracePeriodEnd + EXECUTOR_WINDOW;
        address feeRecipient = (block.timestamp < executorPeriodEnd) ? sourceContract : msg.sender;
        
        uint256 totalEthFee = 0;
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

        for (uint i = 0; i < erc20Assets.length; i++) {
            IERC20 token = erc20Assets[i].token;
            uint256 totalTokens = token.balanceOf(address(this));
            if (totalTokens > 0) {
                uint256 tokenFee = (totalTokens * EXECUTION_FEE_BPS) / 10000;
                uint256 distributableTokens = totalTokens - tokenFee;
                if (tokenFee > 0) { token.transfer(feeRecipient, tokenFee); }
                for (uint j = 0; j < heirs.length; j++) {
                    uint256 share = (distributableTokens * distributionPercentages[j]) / 100;
                    if (share > 0) { token.transfer(heirs[j], share); }
                }
            }
        }

        for (uint i = 0; i < erc721Assets.length; i++) {
            Erc721Asset memory asset = erc721Assets[i];
            asset.token.safeTransferFrom(address(this), asset.heir, asset.tokenId);
        }
        emit Executed(msg.sender, totalEthFee, feeRecipient);
    }
    
    // --- View Functions ---
    function getWillDetails() external view returns (WillDetails memory) {
        Erc20Detail[] memory _erc20Details = new Erc20Detail[](erc20Assets.length);
        for (uint i = 0; i < erc20Assets.length; i++) {
            IERC20 token = erc20Assets[i].token;
            _erc20Details[i] = Erc20Detail({
                tokenContract: address(token),
                balance: token.balanceOf(address(this))
            });
        }
        Erc721Detail[] memory _erc721Details = new Erc721Detail[](erc721Assets.length);
        for (uint i = 0; i < erc721Assets.length; i++) {
            Erc721Asset memory asset = erc721Assets[i];
            _erc721Details[i] = Erc721Detail({
                tokenContract: address(asset.token),
                tokenId: asset.tokenId,
                heir: asset.heir
            });
        }
        return WillDetails({
            owner: owner(),
            interval: interval,
            lastUpdate: lastUpdate,
            executed: executed,
            hasDiary: hasDiary,
            ethBalance: address(this).balance,
            heirs: heirs,
            distributionPercentages: distributionPercentages,
            erc20Details: _erc20Details,
            erc721Details: _erc721Details
        });
    }
}
// contracts/Will.sol
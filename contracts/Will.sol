// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./interfaces/ISource.sol";

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

contract Will is Ownable, ReentrancyGuard {
    struct Erc20Asset { IERC20 token; }
    struct Erc721Asset { IERC721 token; uint256 tokenId; address heir; }
    struct Erc20Distribution { address tokenContract; uint256 amount; }
    struct NftDistribution { address tokenContract; uint256 tokenId; address heir; }
    
    enum WillState { Empty, Active, Executed }
    WillState public currentState;

    uint256 private constant EXECUTOR_WINDOW = 1 days;
    uint256 public constant EXECUTION_FEE_BPS = 50;

    uint256 public lastUpdate;
    uint256 public interval; // No longer immutable
    address public immutable sourceContract;
    bool public immutable hasDiary;
    address public immutable executorAddress;
    address[] public heirs;
    uint256[] public distributionPercentages;
    Erc20Asset[] public erc20Assets;
    Erc721Asset[] public erc721Assets;

    event Ping(uint256 newLastUpdate);
    event Executed(address executor, uint256 ethFee, address feeRecipient);
    event Cancelled(); // No longer has feePaid
    event WillConfigured(address indexed owner);
    event WillEmptied(address indexed owner);

    modifier requiresState(WillState _state) {
        require(currentState == _state, "Will: Invalid state for this action");
        _;
    }

    constructor(
        address initialOwner,
        address _sourceContract,
        bool _hasDiary,
        address _executorAddress
    ) payable Ownable(initialOwner) {
        sourceContract = _sourceContract;
        hasDiary = _hasDiary;
        executorAddress = _executorAddress;
        currentState = WillState.Empty;
    }
    
    function initialize(
        uint256 _interval,
        address[] memory _heirs,
        uint256[] memory _distro,
        Erc20Distribution[] calldata _erc20s,
        NftDistribution[] calldata _nfts
    ) external requiresState(WillState.Empty) {
        require(msg.sender == sourceContract, "Will: Not authorized by factory");
        interval = _interval;
        _configure(_heirs, _distro, _erc20s, _nfts);
        currentState = WillState.Active;
        lastUpdate = block.timestamp;
        emit WillConfigured(owner());
    }
    
    function fundAndConfigure(
        uint256 _interval,
        address[] memory _heirs,
        uint256[] memory _distro,
        Erc20Distribution[] calldata _erc20s,
        NftDistribution[] calldata _nfts
    ) external payable onlyOwner requiresState(WillState.Empty) {
        interval = _interval;
        for (uint i = 0; i < _erc20s.length; i++) {
            if (_erc20s[i].amount > 0) {
                IERC20(_erc20s[i].tokenContract).transferFrom(msg.sender, address(this), _erc20s[i].amount);
            }
        }
        for (uint i = 0; i < _nfts.length; i++) {
            IERC721(_nfts[i].tokenContract).transferFrom(msg.sender, address(this), _nfts[i].tokenId);
        }
        _configure(_heirs, _distro, _erc20s, _nfts);
        currentState = WillState.Active;
        lastUpdate = block.timestamp;
        emit WillConfigured(owner());
    }
    
    function emptyWillForEdit() external onlyOwner requiresState(WillState.Active) nonReentrant {
        _returnAllAssets();
        delete heirs;
        delete distributionPercentages;
        delete erc20Assets;
        delete erc721Assets;
        interval = 0; // Reset interval
        currentState = WillState.Empty;
        emit WillEmptied(owner());
    }

    function cancelAndWithdraw() external onlyOwner requiresState(WillState.Active) nonReentrant {
        _returnAllAssets();
        ISource(sourceContract).clearWillRecord(owner());
        currentState = WillState.Executed;
        emit Cancelled();
    }
    
    function ping() external onlyOwner requiresState(WillState.Active) {
        lastUpdate = block.timestamp;
        emit Ping(lastUpdate);
    }

    function execute() external requiresState(WillState.Active) nonReentrant {
        uint256 gracePeriodEnd = lastUpdate + interval;
        require(block.timestamp >= gracePeriodEnd, "Grace period has not ended.");
        uint256 executorPeriodEnd = gracePeriodEnd + EXECUTOR_WINDOW;
        if (block.timestamp < executorPeriodEnd) { require(msg.sender == executorAddress, "Only designated executor can call now"); }
        
        currentState = WillState.Executed;
        address feeRecipient = (block.timestamp < executorPeriodEnd) ? sourceContract : msg.sender;
        uint256 totalEthFee = 0;
        uint256 totalEth = address(this).balance;
        if (totalEth > 0) {
            uint256 ethFee = (totalEth * EXECUTION_FEE_BPS) / 10000;
            totalEthFee = ethFee;
            uint256 distributableEth = totalEth - ethFee;
            if (ethFee > 0) { (bool s, ) = payable(feeRecipient).call{value: ethFee}(""); require(s, "ETH fee transfer failed"); }
            for (uint i = 0; i < heirs.length; i++) {
                uint256 share = (distributableEth * distributionPercentages[i]) / 100;
                if (share > 0) { (bool s, ) = payable(heirs[i]).call{value: share}(""); require(s, "ETH transfer to heir failed"); }
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

    function _configure(
        address[] memory _heirs,
        uint256[] memory _distro,
        Erc20Distribution[] calldata _erc20s,
        NftDistribution[] calldata _nfts
    ) internal {
        require(_heirs.length == _distro.length, "Heirs/distributions mismatch");
        if (_heirs.length > 0) {
            uint256 totalPercentage = 0;
            for (uint256 i = 0; i < _distro.length; i++) { totalPercentage += _distro[i]; }
            require(totalPercentage == 100, "Distribution must sum to 100");
        }
        heirs = _heirs;
        distributionPercentages = _distro;
        for (uint i = 0; i < _erc20s.length; i++) {
            erc20Assets.push(Erc20Asset(IERC20(_erc20s[i].tokenContract)));
        }
        for (uint i = 0; i < _nfts.length; i++) {
            erc721Assets.push(Erc721Asset(IERC721(_nfts[i].tokenContract), _nfts[i].tokenId, _nfts[i].heir));
        }
    }
    
    function _returnAllAssets() internal {
        address payable _owner = payable(owner());
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
    }

    function getWillDetails() external view returns (WillDetails memory) {
        Erc20Detail[] memory _erc20Details = new Erc20Detail[](erc20Assets.length);
        for (uint i = 0; i < erc20Assets.length; i++) {
            IERC20 token = erc20Assets[i].token;
            _erc20Details[i] = Erc20Detail(address(token), token.balanceOf(address(this)));
        }
        Erc721Detail[] memory _erc721Details = new Erc721Detail[](erc721Assets.length);
        for (uint i = 0; i < erc721Assets.length; i++) {
            Erc721Asset memory asset = erc721Assets[i];
            _erc721Details[i] = Erc721Detail(address(asset.token), asset.tokenId, asset.heir);
        }
        return WillDetails(
            owner(), interval, lastUpdate, (currentState == WillState.Executed),
            hasDiary, address(this).balance, heirs, distributionPercentages,
            _erc20Details, _erc721Details
        );
    }
}
// contracts/Will.sol
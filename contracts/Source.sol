// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./Will.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";

/**
 * @title Source (Estate Planning Factory)
 * @notice A factory contract for creating individual 'Will' contracts with co-founder governance.
 */
contract Source {
    
    struct CoFounder { address primary; address secondary; }

    mapping(address => address) public userWills;
    uint256 public constant basePlatformFee = 0;
    uint256 public diaryPlatformFee;
    CoFounder public coFounderOne;
    CoFounder public coFounderTwo;
    address public executorAddress;

    event WillCreated(address indexed user, address indexed willAddress, bool hasDiary);
    event WillCleared(address indexed user, address indexed willAddress);
    event FeesWithdrawn(address indexed caller, uint256 amountForCoFounderOne, uint256 amountForCoFounderTwo);
    event CoFounderAddressesUpdated(uint8 indexed coFounderId, address newPrimary, address newSecondary);
    event ExecutorAddressUpdated(address indexed newExecutor);

    modifier onlyCoFounder() {
        require(
            msg.sender == coFounderOne.primary || msg.sender == coFounderOne.secondary ||
            msg.sender == coFounderTwo.primary || msg.sender == coFounderTwo.secondary,
            "Source: Caller is not a co-founder"
        );
        _;
    }
    modifier onlyCoFounderOne() {
        require(msg.sender == coFounderOne.primary || msg.sender == coFounderOne.secondary, "Source: Caller is not Co-Founder One");
        _;
    }
    modifier onlyCoFounderTwo() {
        require(msg.sender == coFounderTwo.primary || msg.sender == coFounderTwo.secondary, "Source: Caller is not Co-Founder Two");
        _;
    }
    modifier canSetDiaryFee() {
        require(
            msg.sender == coFounderOne.primary || msg.sender == coFounderOne.secondary ||
            msg.sender == coFounderTwo.primary || msg.sender == coFounderTwo.secondary ||
            msg.sender == executorAddress,
            "Source: Caller cannot set diary fee"
        );
        _;
    }

    constructor(
        address _coFounderOnePrimary, address _coFounderOneSecondary,
        address _coFounderTwoPrimary, address _coFounderTwoSecondary,
        address _initialExecutor
    ) {
        require(
            _coFounderOnePrimary != address(0) && _coFounderOneSecondary != address(0) &&
            _coFounderTwoPrimary != address(0) && _coFounderTwoSecondary != address(0),
            "Source: Co-founder addresses cannot be zero"
        );
        coFounderOne = CoFounder({ primary: _coFounderOnePrimary, secondary: _coFounderOneSecondary });
        coFounderTwo = CoFounder({ primary: _coFounderTwoPrimary, secondary: _coFounderTwoSecondary });
        require(_initialExecutor != address(0), "Source: Executor cannot be zero");
        executorAddress = _initialExecutor;
        diaryPlatformFee = 0.3 ether; 
    }

    receive() external payable {}

    function setDiaryPlatformFee(uint256 _newFee) external canSetDiaryFee { diaryPlatformFee = _newFee; }
    function setExecutorAddress(address _newExecutor) external onlyCoFounder {
        require(_newExecutor != address(0), "Source: New executor cannot be zero");
        executorAddress = _newExecutor;
        emit ExecutorAddressUpdated(_newExecutor);
    }
    function withdrawFees() external onlyCoFounder {
        uint256 balance = address(this).balance;
        require(balance > 0, "No fees to withdraw.");
        uint256 shareForOne = (balance * 90) / 100;
        uint256 shareForTwo = balance - shareForOne;
        (bool s1, ) = coFounderOne.primary.call{value: shareForOne}(""); require(s1, "ETH transfer to Co-Founder One failed.");
        (bool s2, ) = coFounderTwo.primary.call{value: shareForTwo}(""); require(s2, "ETH transfer to Co-Founder Two failed.");
        emit FeesWithdrawn(msg.sender, shareForOne, shareForTwo);
    }
    function updateCoFounderOneAddresses(address _newPrimary, address _newSecondary) external onlyCoFounderOne {
        require(_newPrimary != address(0) && _newSecondary != address(0), "Source: New addresses cannot be zero");
        coFounderOne.primary = _newPrimary; coFounderOne.secondary = _newSecondary;
        emit CoFounderAddressesUpdated(1, _newPrimary, _newSecondary);
    }
    function updateCoFounderTwoAddresses(address _newPrimary, address _newSecondary) external onlyCoFounderTwo {
        require(_newPrimary != address(0) && _newSecondary != address(0), "Source: New addresses cannot be zero");
        coFounderTwo.primary = _newPrimary; coFounderTwo.secondary = _newSecondary;
        emit CoFounderAddressesUpdated(2, _newPrimary, _newSecondary);
    }

    function createWill(
        address[] memory heirs,
        uint256[] memory distribution,
        uint256 interval,
        Will.Erc20Distribution[] calldata erc20s,
        Will.NftDistribution[] calldata nfts
    ) external payable {
        require(msg.value >= basePlatformFee, "Msg.value must cover required fee.");
        require(userWills[msg.sender] == address(0), "User already has an existing will.");
        uint256 willValue = msg.value - basePlatformFee;
        
        // Step 1: Deploy the Will contract, forwarding the ETH for the inheritance
        Will newWill = new Will{value: willValue}(
            msg.sender, interval, address(this), basePlatformFee, false, executorAddress
        );
        userWills[msg.sender] = address(newWill);

        // Step 2: Transfer assets from user to the new Will contract
        for (uint i = 0; i < erc20s.length; i++) {
            if (erc20s[i].amount > 0) {
                IERC20(erc20s[i].tokenContract).transferFrom(msg.sender, address(newWill), erc20s[i].amount);
            }
        }
        for (uint i = 0; i < nfts.length; i++) {
            IERC721(nfts[i].tokenContract).transferFrom(msg.sender, address(newWill), nfts[i].tokenId);
        }
        
        // Step 3: Call the initializer on the now-funded Will contract. This call sends no ETH.
        newWill.initialize(heirs, distribution, erc20s, nfts);

        emit WillCreated(msg.sender, address(newWill), false);
    }

    function createWillDiary(uint256 interval) external payable {
        require(msg.value == diaryPlatformFee, "Msg.value must exactly cover the diary fee.");
        require(userWills[msg.sender] == address(0), "User already has an existing will.");
        
        Will newWill = new Will(
            msg.sender, interval, address(this), diaryPlatformFee, true, executorAddress
        );
        userWills[msg.sender] = address(newWill);
        
        emit WillCreated(msg.sender, address(newWill), true);
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
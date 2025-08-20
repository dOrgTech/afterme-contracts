// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title ISource
 * @notice Interface for the Source factory contract.
 * @dev Required by the Will contract to call the clearWillRecord function.
 */
interface ISource {
    function clearWillRecord(address _user) external;
}
// contracts/interfaces/ISource.sol
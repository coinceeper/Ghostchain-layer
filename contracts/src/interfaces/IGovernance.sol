// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IGovernance
/// @notice Interface for governance contract functionality
interface IGovernance {
    /// @notice Checks if an address is a signer
    function isSigner(address signer) external view returns (bool);

    /// @notice Gets the number of signers
    function getSignerCount() external view returns (uint256);

    /// @notice Gets all signers
    function getSigners() external view returns (address[] memory);
}

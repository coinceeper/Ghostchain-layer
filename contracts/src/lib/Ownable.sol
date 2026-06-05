// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Ownable
/// @notice Simple single-owner authorization mixin
abstract contract Ownable {
    address public owner;

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    constructor(address _owner) {
        owner = _owner;
        emit OwnershipTransferred(address(0), _owner);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert InvalidNewOwner();
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    error Unauthorized();
    error InvalidNewOwner();
}

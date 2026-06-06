// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC20 } from "./interfaces/IERC20.sol";

/// @title EphemeralRouter
/// @notice Implementation contract used by ERC-1167 minimal proxies deployed by
///         EphemeralFactory. Reduces deployment cost to ~100k gas per proxy.
///
/// @dev Only the factory can call execute(). When the factory calls a proxy
///      via .call(), msg.sender is the factory address, preventing unauthorized
///      token drains.
contract EphemeralRouter {
    // ───── State ─────

    /// @notice The factory authorized to call `execute()`. Set once by the factory
    ///         constructor. Only the factory can trigger token transfers from proxies.
    address public factory;

    // ───── Modifiers ─────

    modifier onlyFactory() {
        if (msg.sender != factory) revert Unauthorized();
        _;
    }

    // ───── Factory Authorizer ─────

    /// @notice Sets the authorized factory address. Can only be called once.
    /// @param _factory The EphemeralFactory address
    function setFactory(address _factory) external {
        if (_factory == address(0)) revert ZeroAddress();
        if (factory != address(0)) revert FactoryAlreadySet();
        factory = _factory;
    }

    // ───── Execute Function ─────

    /// @notice Executes the swap logic for an ephemeral contract.
    /// @param recipient The address receiving the tokens
    /// @param zkProof The ZK proof (unused at router level; verified by factory)
    /// @param amount The amount of tokens to transfer
    /// @param token The ERC20 token address
    /// @return True on success
    function execute(
        address recipient,
        bytes calldata zkProof,
        uint256 amount,
        address token
    ) external onlyFactory returns (bool) {
        // Transfer tokens from the proxy (address(this) in delegatecall context)
        // to the recipient (solver or creator for refunds)
        bool success = IERC20(token).transfer(recipient, amount);
        if (!success) revert TransferFailed();
        return true;
    }

    // ───── Custom Errors ─────

    error Unauthorized();
    error TransferFailed();
    error ZeroAddress();
    error FactoryAlreadySet();
}

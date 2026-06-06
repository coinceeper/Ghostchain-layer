// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC20 } from "./interfaces/IERC20.sol";

/// @title EphemeralRouter
/// @notice Implementation contract used by ERC-1167 minimal proxies deployed by EphemeralFactory.
///         Each ephemeral proxy delegates calls to this router, which holds the swap execution
///         logic. This reduces deployment cost to ~100k gas per proxy instead of deploying
///         a full contract each time.
///
/// @dev State is stored in the factory's escrow mappings. The router only handles the atomic
///      token transfer logic. The `factory` is set once by the EphemeralFactory constructor.
///
///      Security: The `execute` function checks that `msg.sender == factory`. When the factory
///      calls a proxy (via `fulfillSwap` or `refundSwap`), `msg.sender` is the factory address.
///      This prevents anyone from calling `execute()` directly on a proxy and draining its tokens
///      without passing ZK proof verification in the factory.
///
///      The call flow is:
///      1. Factory constructor deploys or receives router address, sets itself as authorized
///      2. Sender funds the proxy with tokens
///      3. Solver calls factory.fulfillSwap() which verifies ZK proof
///      4. Factory calls the proxy (msg.sender = factory) -> execute() runs via delegatecall
///      5. Tokens are transferred from the proxy's balance to the recipient
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
    ///         Transfers tokens from the proxy to the recipient.
    /// @param recipient The address receiving the tokens
    /// @param zkProof The ZK proof (unused at router level; verified by factory)
    /// @param amount The amount of tokens to transfer
    /// @param token The ERC20 token address
    /// @return True on success
    ///
    /// @dev Only callable by the factory. When the factory calls a proxy via .call(),
    ///      the proxy delegatecalls here with msg.sender == factory.
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

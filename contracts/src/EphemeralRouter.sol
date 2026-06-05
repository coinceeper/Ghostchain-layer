// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC20 } from "./interfaces/IERC20.sol";

/// @title EphemeralRouter
/// @notice Implementation contract used by ERC-1167 minimal proxies deployed by EphemeralFactory.
///         Each ephemeral proxy delegates calls to this router, which holds the swap execution
///         logic. This reduces deployment cost to ~100k gas per proxy instead of deploying
///         a full contract each time.
///
/// @dev This contract MUST NOT be initialized with any state. All state is stored in the
///      factory's escrow mappings. The router only handles the atomic token transfer logic.
///
///      Security note: The `execute` function has no access control because it is only called
///      via delegatecall through ERC-1167 proxies created by the factory. The factory is the
///      only entity that creates proxies, and the only entity that calls them for fulfillment.
///      Calling the router directly has no effect since it holds no token balance.
///
///      The call flow is:
///      1. Factory creates a minimal proxy (ERC-1167) pointing to this router
///      2. Sender funds the proxy with tokens
///      3. Solver fulfills via the factory, which calls the proxy
///      4. Proxy delegatecalls to this router's execute()
///      5. Tokens are transferred from the proxy's balance to the recipient
contract EphemeralRouter {
    // ───── Execute Function ─────

    /// @notice Executes the swap logic for an ephemeral contract.
    ///         Transfers tokens from the proxy to the recipient.
    /// @param recipient The address receiving the tokens
    /// @param zkProof The ZK proof (unused at router level; verified by factory)
    /// @param amount The amount of tokens to transfer
    /// @param token The ERC20 token address
    /// @return True on success
    ///
    /// @dev This function is called via delegatecall from an ERC-1167 proxy.
    ///      In the proxy's context, `address(this)` is the proxy address, so
    ///      the token transfer comes from the proxy's balance.
    function execute(
        address recipient,
        bytes calldata zkProof,
        uint256 amount,
        address token
    ) external returns (bool) {
        // Transfer tokens from the proxy (address(this) in delegatecall context)
        // to the recipient (solver or creator for refunds)
        bool success = IERC20(token).transfer(recipient, amount);
        if (!success) revert TransferFailed();
        return true;
    }

    /// @notice Transfers any remaining ETH from the proxy back to the sender.
    /// @dev Used for gas refunds or cleanup.
    function drainETH(address to) external {
        (bool success, ) = to.call{ value: address(this).balance }("");
        if (!success) revert TransferFailed();
    }

    /// @notice Allows the proxy to receive ETH for gas
    receive() external payable {}

    // ───── Custom Errors ─────

    error TransferFailed();
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC20 } from "./interfaces/IERC20.sol";
import { SafeERC20 } from "./lib/SafeERC20.sol";

/// @title EphemeralRouter
/// @notice Implementation contract used by ERC-1167 minimal proxies deployed by
///         EphemeralFactory. Reduces deployment cost to ~100k gas per proxy.
///
/// @dev Only the factory can call execute(). When the factory calls a proxy
///      via .call(), msg.sender is the factory address, preventing unauthorized
///      token drains.
///
///      GCL-SC-04 FIX: The factory address is embedded in each proxy's storage
///      during the CREATE opcode itself via custom init code that runs
///      CALLER + SSTORE(0) before returning the ERC-1167 runtime code.
///      No external initializeFactory() call exists — front-running is
///      physically impossible because the factory is set atomically within
///      the proxy's creation, not via a subsequent transaction.
contract EphemeralRouter {
    using SafeERC20 for IERC20;

    // ───── State ─────

    /// @notice The factory authorized to call `execute()`. Set once per proxy
    ///         during CREATE by custom init code (CALLER → SSTORE slot 0).
    ///         The implementation contract itself never has factory set (stays
    ///         address(0)) — only each proxy's own storage matters.
    address public factory;

    // ───── Modifiers ─────

    modifier onlyFactory() {
        if (msg.sender != factory) revert Unauthorized();
        _;
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
        IERC20(token).safeTransfer(recipient, amount);
        return true;
    }

    // ───── Emergency Functions ─────

    /// @notice Withdraws accidentally sent ETH from the proxy contract.
    /// @dev    Proxy contracts only handle ERC20 transfers. Any ETH sent
    ///         directly would be stuck without this function.
    ///         Only the factory (which created the proxy) can call this.
    /// @param to The address to receive the ETH
    function withdrawETH(address payable to) external onlyFactory {
        uint256 balance = address(this).balance;
        if (balance == 0) revert NoETHBalance();
        (bool success, ) = to.call{value: balance}("");
        if (!success) revert ETHWithdrawFailed();
    }

    // ───── Custom Errors ─────

    error Unauthorized();
    error TransferFailed();
    error ZeroAddress();
    error NoETHBalance();
    error ETHWithdrawFailed();
}

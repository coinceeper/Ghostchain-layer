// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC20 } from "../interfaces/IERC20.sol";

/// @title SafeERC20
/// @notice Safe ERC20 wrapper for tokens that do not consistently return
///         a bool value from `transfer` / `transferFrom`.
///
/// GCL-SC-07 FIX: Implements post-transfer balance verification to protect
/// against non-standard ERC20 tokens (USDT, USDC, deflationary tokens, etc.)
/// that may return incorrect values or silently fail transfers.
library SafeERC20 {
    error TransferFailed();
    error TransferFromFailed();
    error ApproveFailed();
    error InsufficientBalance();

    /// @notice Safely transfer tokens with balance verification
    /// @dev Checks both return value (for standard tokens) and balance changes (for non-standard)
    /// @param token The ERC20 token to transfer
    /// @param to The recipient address
    /// @param amount The amount to transfer
    function safeTransfer(IERC20 token, address to, uint256 amount) internal {
        if (amount == 0) return;
        if (to == address(0)) revert TransferFailed();

        // Capture balance before transfer
        uint256 balanceBefore = token.balanceOf(address(this));

        // Execute transfer
        (bool success, bytes memory data) = address(token).call(
            abi.encodeWithSelector(token.transfer.selector, to, amount)
        );

        // Check return value (handles standard tokens)
        require(success && (data.length == 0 || abi.decode(data, (bool))), "SafeERC20: transfer failed");

        // Verify balance changed (handles non-standard tokens like USDT)
        uint256 balanceAfter = token.balanceOf(address(this));
        require(balanceAfter == balanceBefore - amount, "SafeERC20: transfer did not execute");
    }

    /// @notice Safely transfer tokens FROM an account with balance verification
    /// @dev Checks both return value and balance changes
    /// @param token The ERC20 token to transfer
    /// @param from The source address
    /// @param to The recipient address
    /// @param amount The amount to transfer
    function safeTransferFrom(IERC20 token, address from, address to, uint256 amount) internal {
        if (amount == 0) return;
        if (to == address(0)) revert TransferFromFailed();

        // Capture balance before transfer
        uint256 balanceBefore = token.balanceOf(to);

        // Execute transferFrom
        (bool success, bytes memory data) = address(token).call(
            abi.encodeWithSelector(token.transferFrom.selector, from, to, amount)
        );

        // Check return value (handles standard tokens)
        require(success && (data.length == 0 || abi.decode(data, (bool))), "SafeERC20: transferFrom failed");

        // Verify recipient balance increased correctly (handles non-standard tokens)
        uint256 balanceAfter = token.balanceOf(to);
        require(balanceAfter == balanceBefore + amount, "SafeERC20: transferFrom did not execute");
    }

    /// @notice Safely approve tokens with return value verification
    /// @param token The ERC20 token to approve
    /// @param spender The spender address
    /// @param amount The amount to approve
    function safeApprove(IERC20 token, address spender, uint256 amount) internal {
        (bool success, bytes memory data) = address(token).call(
            abi.encodeWithSelector(token.approve.selector, spender, amount)
        );
        require(success && (data.length == 0 || abi.decode(data, (bool))), "SafeERC20: approve failed");
    }

    /// @notice Get safe balance with fallback handling
    /// @dev Some tokens may have issues with balanceOf, this provides a fallback
    /// @param token The ERC20 token
    /// @param account The account to check
    /// @return balance The balance of the account
    function safeBalanceOf(IERC20 token, address account) internal view returns (uint256) {
        (bool success, bytes memory data) = address(token).staticcall(
            abi.encodeWithSelector(token.balanceOf.selector, account)
        );
        require(success && data.length >= 32, "SafeERC20: balanceOf failed");
        return abi.decode(data, (uint256));
    }
}

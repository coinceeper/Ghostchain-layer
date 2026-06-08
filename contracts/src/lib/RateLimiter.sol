// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title RateLimiter
/// @notice Library for implementing rate limiting on contract operations
library RateLimiter {
    // ───── Structs ─────

    struct RateLimit {
        uint256 maxRequests;
        uint256 windowSize;
        mapping(address => Request[]) requests;
    }

    struct Request {
        uint256 timestamp;
        uint256 count;
    }

    // ───── Custom Errors ─────

    error RateLimitExceeded();
    error InvalidRateLimit();

    // ───── Functions ─────

    /// @notice Initializes rate limiting (called in constructor)
    /// @param self The rate limit storage struct
    /// @param _maxRequests Maximum requests allowed per window
    /// @param _windowSize Time window in seconds
    function initialize(RateLimit storage self, uint256 _maxRequests, uint256 _windowSize) internal {
        if (_maxRequests == 0 || _windowSize == 0) revert InvalidRateLimit();
        self.maxRequests = _maxRequests;
        self.windowSize = _windowSize;
    }

    /// @notice Checks if an address has exceeded the rate limit
    /// @param self The rate limit storage struct
    /// @param account Address to check
    /// @return True if rate limit is exceeded
    function isRateLimited(RateLimit storage self, address account) internal view returns (bool) {
        Request[] storage accountRequests = self.requests[account];

        if (accountRequests.length == 0) {
            return false;
        }

        // Get the oldest request in the current window
        uint256 cutoffTime = block.timestamp - self.windowSize;
        uint256 totalCount = 0;

        for (uint256 i = accountRequests.length; i > 0; i--) {
            Request storage req = accountRequests[i - 1];

            if (req.timestamp >= cutoffTime) {
                totalCount += req.count;
            } else {
                break;
            }
        }

        return totalCount >= self.maxRequests;
    }

    /// @notice Records a request for rate limiting
    /// @param self The rate limit storage struct
    /// @param account Address making the request
    /// @param count Number of requests being made (default: 1)
    function recordRequest(RateLimit storage self, address account, uint256 count) internal {
        if (count == 0) count = 1;

        if (isRateLimited(self, account)) revert RateLimitExceeded();

        Request[] storage accountRequests = self.requests[account];

        // Check if we can add to the latest request (same timestamp)
        if (accountRequests.length > 0 && accountRequests[accountRequests.length - 1].timestamp == block.timestamp) {
            accountRequests[accountRequests.length - 1].count += count;
        } else {
            accountRequests.push(Request({timestamp: block.timestamp, count: count}));
        }

        // Clean up old requests to save gas
        _cleanup(self, account);
    }

    /// @notice Gets the current request count for an address within the time window
    /// @param self The rate limit storage struct
    /// @param account Address to check
    /// @return Current request count in the active window
    function getRequestCount(RateLimit storage self, address account) internal view returns (uint256) {
        Request[] storage accountRequests = self.requests[account];
        uint256 cutoffTime = block.timestamp - self.windowSize;
        uint256 totalCount = 0;

        for (uint256 i = accountRequests.length; i > 0; i--) {
            Request storage req = accountRequests[i - 1];

            if (req.timestamp >= cutoffTime) {
                totalCount += req.count;
            } else {
                break;
            }
        }

        return totalCount;
    }

    /// @notice Resets rate limit for an address
    /// @param self The rate limit storage struct
    /// @param account Address to reset
    function resetAccount(RateLimit storage self, address account) internal {
        delete self.requests[account];
    }

    /// @notice Cleans up old requests from storage (gas optimization)
    /// @param self The rate limit storage struct
    /// @param account Address to clean up
    function _cleanup(RateLimit storage self, address account) private {
        Request[] storage accountRequests = self.requests[account];
        uint256 cutoffTime = block.timestamp - self.windowSize;

        // Find the first request that's still in the window
        uint256 removeUpTo = 0;
        for (uint256 i = 0; i < accountRequests.length; i++) {
            if (accountRequests[i].timestamp >= cutoffTime) {
                removeUpTo = i;
                break;
            }
        }

        // Remove old requests (only if there are significant old entries)
        if (removeUpTo > 0 && removeUpTo < accountRequests.length) {
            for (uint256 i = 0; i < accountRequests.length - removeUpTo; i++) {
                accountRequests[i] = accountRequests[i + removeUpTo];
            }

            // Pop the removed entries
            for (uint256 i = 0; i < removeUpTo; i++) {
                accountRequests.pop();
            }
        }
    }
}

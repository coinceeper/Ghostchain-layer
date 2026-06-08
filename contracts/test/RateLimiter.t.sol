// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { RateLimiter } from "../src/lib/RateLimiter.sol";

/// @title RateLimiterTest
/// @notice Tests for the RateLimiter library
contract RateLimiterTest is Test {
    using RateLimiter for RateLimiter.RateLimit;

    RateLimiter.RateLimit private rateLimiter;

    address public user1 = makeAddr("user1");
    address public user2 = makeAddr("user2");

    function setUp() public {
        // Initialize with 10 requests per 1 hour
        rateLimiter.initialize(10, 1 hours);
    }

    // ───── Initialization Tests ─────

    function test_Initialize_SetsLimits() public {
        RateLimiter.RateLimit storage rl = rateLimiter;
        assertEq(rl.maxRequests, 10);
        assertEq(rl.windowSize, 1 hours);
    }

    function test_Initialize_RevertWhen_ZeroMaxRequests() public {
        RateLimiter.RateLimit storage rl;
        vm.expectRevert(RateLimiter.InvalidRateLimit.selector);
        rl.initialize(0, 1 hours);
    }

    function test_Initialize_RevertWhen_ZeroWindowSize() public {
        RateLimiter.RateLimit storage rl;
        vm.expectRevert(RateLimiter.InvalidRateLimit.selector);
        rl.initialize(10, 0);
    }

    // ───── Recording Requests Tests ─────

    function test_RecordRequest_SucceedsWithinLimit() public {
        // Record 5 requests for user1
        for (uint256 i = 0; i < 5; i++) {
            rateLimiter.recordRequest(user1, 1);
        }

        assertEq(rateLimiter.getRequestCount(user1), 5);
    }

    function test_RecordRequest_SucceedsAtLimit() public {
        // Record exactly 10 requests
        for (uint256 i = 0; i < 10; i++) {
            rateLimiter.recordRequest(user1, 1);
        }

        assertEq(rateLimiter.getRequestCount(user1), 10);
    }

    function test_RecordRequest_RevertWhen_ExceedsLimit() public {
        // Record 10 requests (at limit)
        for (uint256 i = 0; i < 10; i++) {
            rateLimiter.recordRequest(user1, 1);
        }

        // Try to record 11th request
        vm.expectRevert(RateLimiter.RateLimitExceeded.selector);
        rateLimiter.recordRequest(user1, 1);
    }

    function test_RecordRequest_MultipleCountPerCall() public {
        // Record 7 requests in one call
        rateLimiter.recordRequest(user1, 7);
        assertEq(rateLimiter.getRequestCount(user1), 7);

        // Record 3 more
        rateLimiter.recordRequest(user1, 3);
        assertEq(rateLimiter.getRequestCount(user1), 10);
    }

    function test_RecordRequest_MultipleCountExceedsLimit() public {
        // Record 7 requests
        rateLimiter.recordRequest(user1, 7);

        // Try to record 5 more (would exceed 10)
        vm.expectRevert(RateLimiter.RateLimitExceeded.selector);
        rateLimiter.recordRequest(user1, 5);
    }

    function test_RecordRequest_DefaultCountIsOne() public {
        // Record without specifying count (should default to 1)
        rateLimiter.recordRequest(user1, 0);
        assertEq(rateLimiter.getRequestCount(user1), 1);
    }

    // ───── Window Expiry Tests ─────

    function test_RecordRequest_ResetsAfterWindowExpiry() public {
        // Record 10 requests
        for (uint256 i = 0; i < 10; i++) {
            rateLimiter.recordRequest(user1, 1);
        }

        assertEq(rateLimiter.getRequestCount(user1), 10);

        // Fast forward past the window (1 hour + 1 second)
        vm.warp(block.timestamp + 1 hours + 1);

        // Now should be able to record again
        rateLimiter.recordRequest(user1, 1);
        assertEq(rateLimiter.getRequestCount(user1), 1);
    }

    function test_RecordRequest_PartialWindowExpiry() public {
        // Record 5 requests at time T
        for (uint256 i = 0; i < 5; i++) {
            rateLimiter.recordRequest(user1, 1);
        }

        // Fast forward half window
        vm.warp(block.timestamp + 30 minutes);

        // Record 5 more requests at T + 30 min
        for (uint256 i = 0; i < 5; i++) {
            rateLimiter.recordRequest(user1, 1);
        }

        // Total should be 10
        assertEq(rateLimiter.getRequestCount(user1), 10);

        // Fast forward to T + 1 hour + 1 sec
        // First 5 requests should be expired, second 5 should remain
        vm.warp(block.timestamp + 30 minutes + 1);

        assertEq(rateLimiter.getRequestCount(user1), 5);
    }

    // ───── Independent Users Tests ─────

    function test_RecordRequest_IndependentPerUser() public {
        // User1 records 10 requests
        for (uint256 i = 0; i < 10; i++) {
            rateLimiter.recordRequest(user1, 1);
        }

        // User2 should still be able to record
        rateLimiter.recordRequest(user2, 1);
        assertEq(rateLimiter.getRequestCount(user2), 1);

        // User1 should be rate limited
        vm.expectRevert(RateLimiter.RateLimitExceeded.selector);
        rateLimiter.recordRequest(user1, 1);
    }

    // ───── Batch Recording Tests ─────

    function test_RecordRequest_SameTSSameRequest() public {
        // Record at same timestamp should combine into one entry
        rateLimiter.recordRequest(user1, 3);
        rateLimiter.recordRequest(user1, 2);

        // Both recorded at same timestamp should be combined
        assertEq(rateLimiter.getRequestCount(user1), 5);
    }

    function test_RecordRequest_DifferentTSSeparateRequests() public {
        // Record first batch
        rateLimiter.recordRequest(user1, 5);

        // Fast forward and record another batch
        vm.warp(block.timestamp + 1);
        rateLimiter.recordRequest(user1, 3);

        assertEq(rateLimiter.getRequestCount(user1), 8);
    }

    // ───── Is Rate Limited Tests ─────

    function test_IsRateLimited_FalseWhenUnderLimit() public {
        rateLimiter.recordRequest(user1, 5);
        assertFalse(rateLimiter.isRateLimited(user1));
    }

    function test_IsRateLimited_TrueAtLimit() public {
        for (uint256 i = 0; i < 10; i++) {
            rateLimiter.recordRequest(user1, 1);
        }
        assertTrue(rateLimiter.isRateLimited(user1));
    }

    // ───── Reset Tests ─────

    function test_ResetAccount_ClearsAllRequests() public {
        // Record 10 requests
        for (uint256 i = 0; i < 10; i++) {
            rateLimiter.recordRequest(user1, 1);
        }

        // Reset user1
        rateLimiter.resetAccount(user1);

        // Should now be able to record
        rateLimiter.recordRequest(user1, 1);
        assertEq(rateLimiter.getRequestCount(user1), 1);
    }

    function test_ResetAccount_OnlyAffectsTargetUser() public {
        // Record for both users
        for (uint256 i = 0; i < 10; i++) {
            rateLimiter.recordRequest(user1, 1);
        }
        rateLimiter.recordRequest(user2, 5);

        // Reset only user1
        rateLimiter.resetAccount(user1);

        // User1 should be reset
        assertEq(rateLimiter.getRequestCount(user1), 0);

        // User2 should be unchanged
        assertEq(rateLimiter.getRequestCount(user2), 5);
    }

    // ───── Edge Cases ─────

    function test_RecordRequest_BoundaryCondition() public {
        // Fill to exactly 10
        rateLimiter.recordRequest(user1, 10);
        assertEq(rateLimiter.getRequestCount(user1), 10);

        // One more should fail
        vm.expectRevert(RateLimiter.RateLimitExceeded.selector);
        rateLimiter.recordRequest(user1, 1);
    }

    function test_RecordRequest_VeryLargeCount() public {
        // Try to record more than limit in one call
        vm.expectRevert(RateLimiter.RateLimitExceeded.selector);
        rateLimiter.recordRequest(user1, 15);
    }

    function test_RecordRequest_EmptyAccountHasZeroCount() public {
        assertEq(rateLimiter.getRequestCount(user1), 0);
        assertFalse(rateLimiter.isRateLimited(user1));
    }
}

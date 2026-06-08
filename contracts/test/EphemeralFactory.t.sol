// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { EphemeralFactory } from "../src/EphemeralFactory.sol";
import { EphemeralRouter } from "../src/EphemeralRouter.sol";
import { ZKVerifier } from "../src/ZKVerifier.sol";
import { IZKVerifier } from "../src/interfaces/IZKVerifier.sol";
import { IEphemeralFactory } from "../src/interfaces/IEphemeralFactory.sol";

/// @title EphemeralFactoryTest
/// @notice Tests for the EphemeralFactory contract
contract EphemeralFactoryTest is Test {
    EphemeralFactory public factory;
    EphemeralRouter public router;
    ZKVerifier public verifier;

    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public token;

    uint256 constant CHAIN_ID_ARBITRUM = 42161;
    uint256 constant CHAIN_ID_POLYGON = 137;

    function setUp() public {
        // Deploy ZKVerifier with bootstrap mode
        // Owner = address(this), AuthorizedSigner = address(this) for tests
        uint256[10] memory vkComponents;
        verifier = new ZKVerifier(keccak256(abi.encode(vkComponents)), 0, true, address(this), address(this));

        // Deploy EphemeralRouter (implementation for minimal proxies).
        // GCL-SC-04 FIX: The implementation contract no longer has setFactory()
        // called on it — only each proxy gets factory-initialized during creation.
        router = new EphemeralRouter();

        // Deploy EphemeralFactory with router implementation.
        // GCL-SC-04 FIX: Constructor no longer calls setFactory() on the router.
        // Proxy factory initialization happens atomically in _createMinimalProxy().
        factory = new EphemeralFactory(address(verifier), address(router));

        // Deploy mock USDT token
        token = address(new MockERC20("Mock USDT", "USDT", 6));

        // Fund Alice with tokens
        MockERC20(token).mint(alice, 10000e6);
    }

    // ───── Create Swap Tests (Escrow Mode) ─────

    /// @notice Dummy ghost recipient address used in tests that only verify swap creation.
    ///         Fulfillment tests use their own recipient variables.
    address constant TEST_GHOST_RECIPIENT = address(0x1234);

    function test_CreateEphemeralSwap() public {
        vm.startPrank(alice);

        uint256 amount = 1000e6;
        bytes32 commitment = keccak256("test-commitment");
        uint256 expiry = block.timestamp + 1 hours;

        MockERC20(token).approve(address(factory), amount);

        bytes memory ephemeralKey = abi.encodePacked(hex"02", hex"1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef");
        uint8 viewTag = 42;

        bytes32 swapId = factory.createEphemeralSwap(
            token,
            amount,
            CHAIN_ID_ARBITRUM,
            commitment,
            expiry,
            TEST_GHOST_RECIPIENT,
            ephemeralKey,
            viewTag
        );

        assertTrue(swapId != bytes32(0), "Swap ID should not be zero");

        // Verify recipientGhostAddress is stored correctly (GCL-RL-03 fix)
        IEphemeralFactory.EphemeralSwap memory swap = factory.getSwap(swapId);
        assertEq(swap.creator, alice);
        assertEq(swap.token, token);
        assertEq(swap.amount, amount);
        assertEq(swap.sourceChain, block.chainid);
        assertEq(swap.destinationChain, CHAIN_ID_ARBITRUM);
        assertEq(swap.commitment, commitment);
        assertEq(swap.recipientGhostAddress, TEST_GHOST_RECIPIENT, "recipientGhostAddress should be stored");
        assertFalse(swap.fulfilled);
        assertFalse(swap.refunded);
        assertTrue(swap.createdAt > 0);
        assertEq(swap.expiry, expiry);

        vm.stopPrank();
    }

    function test_RevertWhen_RecipientGhostAddressZero() public {
        vm.startPrank(alice);

        uint256 amount = 1000e6;
        bytes32 commitment = keccak256("zero-ghost-recipient");
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory ephemeralKey = abi.encodePacked(hex"02", hex"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
        uint8 viewTag = 1;

        MockERC20(token).approve(address(factory), amount);

        vm.expectRevert(EphemeralFactory.ZeroAddressNotAllowed.selector);
        factory.createEphemeralSwap(token, amount, CHAIN_ID_ARBITRUM, commitment, expiry, address(0), ephemeralKey, viewTag);

        vm.stopPrank();
    }

    function test_RevertWhen_AmountZero() public {
        vm.startPrank(alice);

        bytes32 commitment = keccak256("test");
        uint256 expiry = block.timestamp + 1 hours;

        MockERC20(token).approve(address(factory), 0);

        bytes memory ephemeralKey = abi.encodePacked(hex"02", hex"1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef");
        uint8 viewTag = 1;

        vm.expectRevert(EphemeralFactory.InvalidAmount.selector);
        factory.createEphemeralSwap(token, 0, CHAIN_ID_ARBITRUM, commitment, expiry, TEST_GHOST_RECIPIENT, ephemeralKey, viewTag);

        vm.stopPrank();
    }

    function test_RevertWhen_ExpiryTooShort() public {
        vm.startPrank(alice);

        uint256 amount = 100e6;
        bytes32 commitment = keccak256("test");
        uint256 expiry = block.timestamp + 1 minutes; // Less than MIN_DURATION (5 min)
        bytes memory ephemeralKey = abi.encodePacked(hex"02", hex"1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef");
        uint8 viewTag = 1;

        MockERC20(token).approve(address(factory), amount);

        vm.expectRevert(EphemeralFactory.ExpiryTooShort.selector);
        factory.createEphemeralSwap(token, amount, CHAIN_ID_ARBITRUM, commitment, expiry, TEST_GHOST_RECIPIENT, ephemeralKey, viewTag);

        vm.stopPrank();
    }

    // ───── Create Ephemeral Contract Tests (Proxy Mode) ─────

    function test_CreateEphemeralContract() public {
        vm.startPrank(alice);

        uint256 amount = 500e6;
        bytes32 commitment = keccak256("proxy-commitment");
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory ephemeralKey = abi.encodePacked(hex"03", hex"abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890");
        uint8 viewTag = 7;

        MockERC20(token).approve(address(factory), amount);

        (bytes32 swapId, address proxy) = factory.createEphemeralContract(
            token,
            amount,
            CHAIN_ID_POLYGON,
            commitment,
            expiry,
            TEST_GHOST_RECIPIENT,
            ephemeralKey,
            viewTag
        );

        assertTrue(swapId != bytes32(0), "Swap ID should not be zero");
        assertTrue(proxy != address(0), "Proxy address should not be zero");
        assertTrue(proxy.code.length > 0, "Proxy should have code");

        // Verify the proxy holds the tokens
        uint256 proxyBalance = MockERC20(token).balanceOf(proxy);
        assertEq(proxyBalance, amount, "Proxy should hold the locked tokens");

        // Verify swap details
        IEphemeralFactory.EphemeralSwap memory swap = factory.getSwap(swapId);
        assertEq(swap.creator, alice);
        assertEq(swap.token, token);
        assertEq(swap.amount, amount);
        assertEq(swap.destinationChain, CHAIN_ID_POLYGON);
        assertEq(swap.commitment, commitment);

        vm.stopPrank();
    }

    function test_TotalContractsCreated() public {
        vm.startPrank(alice);

        uint256 amount = 100e6;
        bytes32 commitment = keccak256("count-test");
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory ephemeralKey = abi.encodePacked(hex"02", hex"1111111111111111111111111111111111111111111111111111111111111111");

        MockERC20(token).approve(address(factory), amount * 3);

        // Create 3 proxy contracts
        for (uint256 i = 0; i < 3; i++) {
            MockERC20(token).approve(address(factory), amount);
            factory.createEphemeralContract(
                token,
                amount,
                CHAIN_ID_ARBITRUM,
                keccak256(abi.encode(i)),
                expiry,
                TEST_GHOST_RECIPIENT,
                ephemeralKey,
                uint8(i)
            );
        }

        assertEq(factory.totalContractsCreated(), 3, "Should have created 3 proxies");

        vm.stopPrank();
    }

    // ───── Refund Tests ─────

    function test_RefundExpiredSwap() public {
        vm.startPrank(alice);

        uint256 balanceBefore = MockERC20(token).balanceOf(alice);

        uint256 amount = 1000e6;
        bytes32 commitment = keccak256("test-commitment");
        uint256 expiry = block.timestamp + 10 minutes;
        bytes memory ephemeralKey = abi.encodePacked(hex"02", hex"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
        uint8 viewTag = 99;

        MockERC20(token).approve(address(factory), amount);
        bytes32 swapId = factory.createEphemeralSwap(
            token, amount, CHAIN_ID_ARBITRUM, commitment, expiry, TEST_GHOST_RECIPIENT, ephemeralKey, viewTag
        );

        // Fast forward past expiry
        vm.warp(block.timestamp + 11 minutes);

        factory.refundSwap(swapId);

        uint256 balanceAfter = MockERC20(token).balanceOf(alice);
        assertEq(balanceAfter, balanceBefore, "Alice should get full refund");

        vm.stopPrank();
    }

    function test_RefundExpiredProxySwap() public {
        vm.startPrank(alice);

        uint256 balanceBefore = MockERC20(token).balanceOf(alice);

        uint256 amount = 500e6;
        bytes32 commitment = keccak256("proxy-refund");
        uint256 expiry = block.timestamp + 10 minutes;
        bytes memory ephemeralKey = abi.encodePacked(hex"03", hex"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb");
        uint8 viewTag = 77;

        MockERC20(token).approve(address(factory), amount);
        (bytes32 swapId, address proxy) = factory.createEphemeralContract(
            token, amount, CHAIN_ID_ARBITRUM, commitment, expiry, TEST_GHOST_RECIPIENT, ephemeralKey, viewTag
        );

        // Verify proxy holds the tokens
        assertEq(MockERC20(token).balanceOf(proxy), amount, "Proxy should hold tokens");

        // Fast forward past expiry
        vm.warp(block.timestamp + 11 minutes);

        // Refund should now work by calling the proxy to sweep tokens back
        factory.refundSwap(swapId);

        // Verify tokens returned to Alice
        uint256 balanceAfter = MockERC20(token).balanceOf(alice);
        assertEq(balanceAfter, balanceBefore, "Alice should get full refund from proxy");

        // Verify proxy is empty
        assertEq(MockERC20(token).balanceOf(proxy), 0, "Proxy should be drained");

        vm.stopPrank();
    }

    function test_RevertWhen_RefundBeforeExpiry() public {
        vm.startPrank(alice);

        uint256 amount = 1000e6;
        bytes32 commitment = keccak256("test-commitment");
        uint256 expiry = block.timestamp + 10 minutes;
        bytes memory ephemeralKey = abi.encodePacked(hex"02", hex"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc");
        uint8 viewTag = 55;

        MockERC20(token).approve(address(factory), amount);
        bytes32 swapId = factory.createEphemeralSwap(
            token, amount, CHAIN_ID_ARBITRUM, commitment, expiry, TEST_GHOST_RECIPIENT, ephemeralKey, viewTag
        );

        vm.expectRevert(EphemeralFactory.SwapNotExpired.selector);
        factory.refundSwap(swapId);

        vm.stopPrank();
    }

    // ───── Fulfill Swap Tests ─────

    function test_FulfillSwap_EscrowMode_TokensGoToRecipient() public {
        // Create a swap in escrow mode
        vm.startPrank(alice);
        uint256 amount = 1000e6;
        bytes32 commitment = keccak256("fulfill-escrow-test");
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory ephemeralKey = abi.encodePacked(
            hex"02", hex"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        );
        uint8 viewTag = 1;

        MockERC20(token).approve(address(factory), amount);
        bytes32 swapId = factory.createEphemeralSwap(
            token, amount, CHAIN_ID_ARBITRUM, commitment, expiry, TEST_GHOST_RECIPIENT, ephemeralKey, viewTag
        );
        vm.stopPrank();

        address recipient = makeAddr("recipient");
        address solver = bob;

        uint256 solverBalanceBefore = MockERC20(token).balanceOf(solver);
        uint256 recipientBalanceBefore = MockERC20(token).balanceOf(recipient);

        // Mock verifier to always return true for verify(uint8,bytes,(bytes32,bytes32,bytes32,address,uint256,uint256,uint256))
        bytes memory dummyProof = hex"0000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000200";
        IZKVerifier.GhostTransferPublicInputs memory pi = IZKVerifier.GhostTransferPublicInputs({
            senderCommitment: commitment,
            recipientCommitment: bytes32(0),
            contractHash: keccak256(abi.encodePacked(swapId, address(factory))),
            token: token,
            amount: amount,
            nonce: uint256(swapId),
            chainId: block.chainid,
            ephemeralPublicKey: ephemeralKey
        });
        vm.mockCall(
            address(verifier),
            abi.encodeWithSelector(IZKVerifier.verify.selector, 0, dummyProof, pi),
            abi.encode(true)
        );

        // Fulfill as solver (bob)
        vm.prank(solver);
        bytes32 contractHash = keccak256(abi.encodePacked(swapId, address(factory)));
        factory.fulfillSwap(swapId, dummyProof, recipient, contractHash, ephemeralKey);

        // CRITICAL CHECK: solver must NOT receive tokens
        assertEq(
            MockERC20(token).balanceOf(solver),
            solverBalanceBefore,
            "[GCL-SC-05 FIXED] Solver should NOT receive tokens in escrow mode"
        );

        // CRITICAL CHECK: recipient MUST receive the tokens
        assertEq(
            MockERC20(token).balanceOf(recipient),
            recipientBalanceBefore + amount,
            "[GCL-SC-05 FIXED] Recipient MUST receive tokens in escrow mode"
        );

        // Verify swap state
        IEphemeralFactory.EphemeralSwap memory swap = factory.getSwap(swapId);
        assertTrue(swap.fulfilled, "Swap should be marked fulfilled");
        assertEq(swap.solver, solver, "Solver address should be recorded");
    }

    function test_FulfillSwap_ProxyMode_TokensGoToRecipient() public {
        // Create a swap in proxy mode
        vm.startPrank(alice);
        uint256 amount = 500e6;
        bytes32 commitment = keccak256("fulfill-proxy-test");
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory ephemeralKey = abi.encodePacked(
            hex"03", hex"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        );
        uint8 viewTag = 2;

        MockERC20(token).approve(address(factory), amount);
        (bytes32 swapId, address proxy) = factory.createEphemeralContract(
            token, amount, CHAIN_ID_POLYGON, commitment, expiry, TEST_GHOST_RECIPIENT, ephemeralKey, viewTag
        );
        vm.stopPrank();

        // Verify proxy holds the tokens
        assertEq(MockERC20(token).balanceOf(proxy), amount, "Proxy should hold locked tokens");

        address recipient = makeAddr("recipient");
        address solver = bob;

        uint256 solverBalanceBefore = MockERC20(token).balanceOf(solver);
        uint256 recipientBalanceBefore = MockERC20(token).balanceOf(recipient);

        // Mock verifier to always return true
        bytes memory dummyProof = hex"0000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000200";
        IZKVerifier.GhostTransferPublicInputs memory pi = IZKVerifier.GhostTransferPublicInputs({
            senderCommitment: commitment,
            recipientCommitment: bytes32(0),
            contractHash: keccak256(abi.encodePacked(swapId, address(factory))),
            token: token,
            amount: amount,
            nonce: uint256(swapId),
            chainId: block.chainid,
            ephemeralPublicKey: ephemeralKey
        });
        vm.mockCall(
            address(verifier),
            abi.encodeWithSelector(IZKVerifier.verify.selector, 0, dummyProof, pi),
            abi.encode(true)
        );

        // Fulfill as solver (bob)
        vm.prank(solver);
        bytes32 contractHash = keccak256(abi.encodePacked(swapId, address(factory)));
        factory.fulfillSwap(swapId, dummyProof, recipient, contractHash, ephemeralKey);

        // CRITICAL CHECK: solver must NOT receive tokens
        assertEq(
            MockERC20(token).balanceOf(solver),
            solverBalanceBefore,
            "[GCL-SC-05 FIXED] Solver should NOT receive tokens in proxy mode"
        );

        // CRITICAL CHECK: recipient MUST receive the tokens
        assertEq(
            MockERC20(token).balanceOf(recipient),
            recipientBalanceBefore + amount,
            "[GCL-SC-05 FIXED] Recipient MUST receive tokens in proxy mode"
        );

        // Verify proxy is drained
        assertEq(MockERC20(token).balanceOf(proxy), 0, "Proxy should be drained after fulfillment");

        // Verify swap state
        IEphemeralFactory.EphemeralSwap memory swap = factory.getSwap(swapId);
        assertTrue(swap.fulfilled, "Swap should be marked fulfilled");
        assertEq(swap.solver, solver, "Solver address should be recorded");
    }

    function test_FulfillSwap_RevertWhen_RecipientZero() public {
        vm.startPrank(alice);
        uint256 amount = 1000e6;
        bytes32 commitment = keccak256("zero-recipient");
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory ephemeralKey = abi.encodePacked(
            hex"02", hex"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
        );
        uint8 viewTag = 3;

        MockERC20(token).approve(address(factory), amount);
        bytes32 swapId = factory.createEphemeralSwap(
            token, amount, CHAIN_ID_ARBITRUM, commitment, expiry, TEST_GHOST_RECIPIENT, ephemeralKey, viewTag
        );
        vm.stopPrank();

        bytes memory dummyProof = hex"0000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000200";
        bytes32 contractHash = keccak256(abi.encodePacked(swapId, address(factory)));

        vm.expectRevert(EphemeralFactory.ZeroAddressNotAllowed.selector);
        vm.prank(bob);
        factory.fulfillSwap(swapId, dummyProof, address(0), contractHash, ephemeralKey);
    }

    function test_FulfillSwap_RevertWhen_AlreadyFulfilled() public {
        vm.startPrank(alice);
        uint256 amount = 1000e6;
        bytes32 commitment = keccak256("double-fulfill");
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory ephemeralKey = abi.encodePacked(
            hex"02", hex"dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
        );
        uint8 viewTag = 4;

        MockERC20(token).approve(address(factory), amount);
        bytes32 swapId = factory.createEphemeralSwap(
            token, amount, CHAIN_ID_ARBITRUM, commitment, expiry, TEST_GHOST_RECIPIENT, ephemeralKey, viewTag
        );
        vm.stopPrank();

        bytes memory dummyProof = hex"0000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000200";
        IZKVerifier.GhostTransferPublicInputs memory pi = IZKVerifier.GhostTransferPublicInputs({
            senderCommitment: commitment,
            recipientCommitment: bytes32(0),
            contractHash: keccak256(abi.encodePacked(swapId, address(factory))),
            token: token,
            amount: amount,
            nonce: uint256(swapId),
            chainId: block.chainid,
            ephemeralPublicKey: ephemeralKey
        });
        vm.mockCall(
            address(verifier),
            abi.encodeWithSelector(IZKVerifier.verify.selector, 0, dummyProof, pi),
            abi.encode(true)
        );

        address recipient = makeAddr("recipient");
        bytes32 contractHash = keccak256(abi.encodePacked(swapId, address(factory)));

        vm.prank(bob);
        factory.fulfillSwap(swapId, dummyProof, recipient, contractHash, ephemeralKey);

        vm.expectRevert(EphemeralFactory.SwapAlreadyFulfilled.selector);
        vm.prank(bob);
        factory.fulfillSwap(swapId, dummyProof, recipient, contractHash, ephemeralKey);
    }

    function test_FulfillSwap_RevertWhen_Expired() public {
        vm.startPrank(alice);
        uint256 amount = 1000e6;
        bytes32 commitment = keccak256("expired-fulfill");
        uint256 expiry = block.timestamp + 10 minutes;
        bytes memory ephemeralKey = abi.encodePacked(
            hex"02", hex"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
        );
        uint8 viewTag = 5;

        MockERC20(token).approve(address(factory), amount);
        bytes32 swapId = factory.createEphemeralSwap(
            token, amount, CHAIN_ID_ARBITRUM, commitment, expiry, TEST_GHOST_RECIPIENT, ephemeralKey, viewTag
        );
        vm.stopPrank();

        // Fast forward past expiry
        vm.warp(block.timestamp + 11 minutes);

        bytes memory dummyProof = hex"0000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000200";
        bytes32 contractHash = keccak256(abi.encodePacked(swapId, address(factory)));

        vm.expectRevert(EphemeralFactory.SwapIsExpired.selector);
        vm.prank(bob);
        factory.fulfillSwap(swapId, dummyProof, makeAddr("recipient"), contractHash, ephemeralKey);
    }

    function test_FulfillSwap_EmitsSwapFulfilled() public {
        vm.startPrank(alice);
        uint256 amount = 1000e6;
        bytes32 commitment = keccak256("event-fulfill");
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory ephemeralKey = abi.encodePacked(
            hex"02", hex"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
        );
        uint8 viewTag = 6;

        MockERC20(token).approve(address(factory), amount);
        bytes32 swapId = factory.createEphemeralSwap(
            token, amount, CHAIN_ID_ARBITRUM, commitment, expiry, TEST_GHOST_RECIPIENT, ephemeralKey, viewTag
        );
        vm.stopPrank();

        bytes memory dummyProof = hex"0000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000200";
        IZKVerifier.GhostTransferPublicInputs memory pi = IZKVerifier.GhostTransferPublicInputs({
            senderCommitment: commitment,
            recipientCommitment: bytes32(0),
            contractHash: keccak256(abi.encodePacked(swapId, address(factory))),
            token: token,
            amount: amount,
            nonce: uint256(swapId),
            chainId: block.chainid,
            ephemeralPublicKey: ephemeralKey
        });
        vm.mockCall(
            address(verifier),
            abi.encodeWithSelector(IZKVerifier.verify.selector, 0, dummyProof, pi),
            abi.encode(true)
        );

        address recipient = makeAddr("event-recipient");
        bytes32 contractHash = keccak256(abi.encodePacked(swapId, address(factory)));
        vm.prank(bob);
        vm.expectEmit(true, true, true, true);
        emit IEphemeralFactory.SwapFulfilled(swapId, bob, recipient);
        factory.fulfillSwap(swapId, dummyProof, recipient, contractHash, ephemeralKey);
    }

    // ───── Nullifier-Based Fulfillment Tests (GCL-ZK-02) ─────

    function test_FulfillSwapWithNullifier_EscrowMode_TokensGoToRecipient() public {
        // Create a swap in escrow mode
        vm.startPrank(alice);
        uint256 amount = 1000e6;
        bytes32 commitment = keccak256("nullifier-escrow");
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory ephemeralKey = abi.encodePacked(
            hex"02", hex"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        );
        uint8 viewTag = 1;

        MockERC20(token).approve(address(factory), amount);
        bytes32 swapId = factory.createEphemeralSwap(
            token, amount, CHAIN_ID_ARBITRUM, commitment, expiry, TEST_GHOST_RECIPIENT, ephemeralKey, viewTag
        );
        vm.stopPrank();

        address recipient = makeAddr("nullifier-recipient");
        address solver = bob;

        bytes32 nullifier = keccak256("unique-nullifier-1");
        bytes32 merkleRoot = keccak256("merkle-root-1");
        bytes memory dummyProof = hex"0000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000200";

        // Mock verifier to return true for verifyNullifierProof
        IZKVerifier.NullifierProofPublicInputs memory pi = IZKVerifier.NullifierProofPublicInputs({
            nullifier: nullifier,
            merkleRoot: merkleRoot,
            recipient: recipient,
            viewTag: viewTag,
            token: token,
            amount: amount,
            chainId: block.chainid,
            ephemeralPublicKey: ephemeralKey
        });
        vm.mockCall(
            address(verifier),
            abi.encodeWithSelector(IZKVerifier.verifyNullifierProof.selector, 0, dummyProof, pi),
            abi.encode(true)
        );

        uint256 recipientBalanceBefore = MockERC20(token).balanceOf(recipient);

        vm.prank(solver);
        factory.fulfillSwapWithNullifier(swapId, dummyProof, recipient, nullifier, merkleRoot, viewTag, ephemeralKey);

        // CRITICAL: recipient receives tokens via nullifier fulfillment
        assertEq(
            MockERC20(token).balanceOf(recipient),
            recipientBalanceBefore + amount,
            "Recipient MUST receive tokens via nullifier fulfillment"
        );

        // Verify swap state
        IEphemeralFactory.EphemeralSwap memory swap = factory.getSwap(swapId);
        assertTrue(swap.fulfilled, "Swap should be marked fulfilled");
        assertEq(swap.solver, solver, "Solver should be recorded");
    }

    function test_FulfillSwapWithNullifier_ProxyMode_TokensGoToRecipient() public {
        vm.startPrank(alice);
        uint256 amount = 500e6;
        bytes32 commitment = keccak256("nullifier-proxy");
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory ephemeralKey = abi.encodePacked(
            hex"03", hex"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        );
        uint8 viewTag = 2;

        MockERC20(token).approve(address(factory), amount);
        (bytes32 swapId, address proxy) = factory.createEphemeralContract(
            token, amount, CHAIN_ID_POLYGON, commitment, expiry, TEST_GHOST_RECIPIENT, ephemeralKey, viewTag
        );
        vm.stopPrank();

        assertEq(MockERC20(token).balanceOf(proxy), amount, "Proxy should hold tokens");

        address recipient = makeAddr("nullifier-proxy-recipient");
        address solver = bob;

        bytes32 nullifier = keccak256("unique-nullifier-2");
        bytes32 merkleRoot = keccak256("merkle-root-2");
        bytes memory dummyProof = hex"0000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000200";

        IZKVerifier.NullifierProofPublicInputs memory pi = IZKVerifier.NullifierProofPublicInputs({
            nullifier: nullifier,
            merkleRoot: merkleRoot,
            recipient: recipient,
            viewTag: viewTag,
            token: token,
            amount: amount,
            chainId: block.chainid,
            ephemeralPublicKey: ephemeralKey
        });
        vm.mockCall(
            address(verifier),
            abi.encodeWithSelector(IZKVerifier.verifyNullifierProof.selector, 0, dummyProof, pi),
            abi.encode(true)
        );

        uint256 recipientBalanceBefore = MockERC20(token).balanceOf(recipient);

        vm.prank(solver);
        factory.fulfillSwapWithNullifier(swapId, dummyProof, recipient, nullifier, merkleRoot, viewTag, ephemeralKey);

        assertEq(
            MockERC20(token).balanceOf(recipient),
            recipientBalanceBefore + amount,
            "Recipient MUST receive tokens via proxy nullifier fulfillment"
        );
        assertEq(MockERC20(token).balanceOf(proxy), 0, "Proxy should be drained");
    }

    function test_RevertWhen_NullifierIsZero() public {
        vm.startPrank(alice);
        uint256 amount = 1000e6;
        bytes32 commitment = keccak256("zero-nullifier");
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory ephemeralKey = abi.encodePacked(
            hex"02", hex"dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
        );
        uint8 viewTag = 4;

        MockERC20(token).approve(address(factory), amount);
        bytes32 swapId = factory.createEphemeralSwap(
            token, amount, CHAIN_ID_ARBITRUM, commitment, expiry, TEST_GHOST_RECIPIENT, ephemeralKey, viewTag
        );
        vm.stopPrank();

        bytes memory dummyProof = hex"00";

        vm.expectRevert(EphemeralFactory.InvalidNullifier.selector);
        vm.prank(bob);
        factory.fulfillSwapWithNullifier(swapId, dummyProof, makeAddr("r"), bytes32(0), keccak256("root"), 5, ephemeralKey);
    }

    function test_FulfillSwapWithNullifier_EmitsCorrectEvent() public {
        vm.startPrank(alice);
        uint256 amount = 1000e6;
        bytes32 commitment = keccak256("nullifier-event");
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory ephemeralKey = abi.encodePacked(
            hex"02", hex"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
        );
        uint8 viewTag = 6;

        MockERC20(token).approve(address(factory), amount);
        bytes32 swapId = factory.createEphemeralSwap(
            token, amount, CHAIN_ID_ARBITRUM, commitment, expiry, TEST_GHOST_RECIPIENT, ephemeralKey, viewTag
        );
        vm.stopPrank();

        address recipient = makeAddr("event-recipient");
        bytes32 nullifier = keccak256("event-nullifier");
        bytes32 merkleRoot = keccak256("event-merkle-root");
        bytes memory dummyProof = hex"0000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000200";

        IZKVerifier.NullifierProofPublicInputs memory pi = IZKVerifier.NullifierProofPublicInputs({
            nullifier: nullifier,
            merkleRoot: merkleRoot,
            recipient: recipient,
            viewTag: viewTag,
            token: token,
            amount: amount,
            chainId: block.chainid,
            ephemeralPublicKey: ephemeralKey
        });
        vm.mockCall(
            address(verifier),
            abi.encodeWithSelector(IZKVerifier.verifyNullifierProof.selector, 0, dummyProof, pi),
            abi.encode(true)
        );

        vm.prank(bob);
        vm.expectEmit(true, true, true, true);
        emit IEphemeralFactory.SwapFulfilledWithNullifier(swapId, bob, recipient, nullifier, merkleRoot);
        factory.fulfillSwapWithNullifier(swapId, dummyProof, recipient, nullifier, merkleRoot, viewTag, ephemeralKey);
    }

    // ───── Direct ZKVerifier Nullifier Tests ─────

    function test_VerifyNullifierProof_PreventsDoubleSpend_Direct() public {
        // Generate a fresh keypair for bootstrap signing
        uint256 signerPrivateKey = 0xB0B;
        address signer = vm.addr(signerPrivateKey);

        // Deploy a separate ZKVerifier in bootstrap mode with this signer
        ZKVerifier nullifierVerifier = new ZKVerifier(
            keccak256("test-vk"),
            0,
            true,
            address(this),
            signer
        );

        // Build nullifier proof public inputs
        bytes32 nullifier = keccak256("double-spend-nullifier");
        bytes32 merkleRoot = keccak256("double-spend-root");
        address recipient = makeAddr("double-spend-recipient");
        uint8 viewTag = 42;

        bytes memory dummyEphemeralKey = abi.encodePacked(hex"02", hex"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");

        IZKVerifier.NullifierProofPublicInputs memory pi = IZKVerifier.NullifierProofPublicInputs({
            nullifier: nullifier,
            merkleRoot: merkleRoot,
            recipient: recipient,
            viewTag: viewTag,
            token: token,
            amount: 1000e6,
            chainId: block.chainid,
            ephemeralPublicKey: dummyEphemeralKey
        });

        // Compute the hash that the bootstrap proof signs over
        bytes32 hash = keccak256(
            abi.encodePacked(
                pi.nullifier,
                pi.merkleRoot,
                pi.recipient,
                pi.viewTag,
                pi.token,
                pi.amount,
                pi.chainId,
                pi.ephemeralPublicKey,
                pi.ephemeralPublicKey.length
            )
        );

        // Sign with the authorized signer's private key
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPrivateKey, hash);
        bytes memory proof = abi.encodePacked(r, s, v - 27);

        // FIRST call: should succeed — nullifier not yet used
        bool result = nullifierVerifier.verifyNullifierProof(0, proof, pi);
        assertTrue(result, "First nullifier verification MUST succeed");

        // Verify the nullifier is now marked as used
        assertTrue(
            nullifierVerifier.isNullifierUsed(nullifier),
            "Nullifier MUST be marked used after first verification"
        );

        // SECOND call with SAME nullifier: MUST revert with NullifierAlreadyUsed
        vm.expectRevert(
            abi.encodeWithSelector(ZKVerifier.NullifierAlreadyUsed.selector, nullifier)
        );
        nullifierVerifier.verifyNullifierProof(0, proof, pi);
    }

    function test_VerifyNullifierProof_DifferentNullifiersAllowed() public {
        uint256 signerPrivateKey = 0xCAFE;
        address signer = vm.addr(signerPrivateKey);

        ZKVerifier nullifierVerifier = new ZKVerifier(
            keccak256("test-vk"),
            0,
            true,
            address(this),
            signer
        );

        bytes32 merkleRoot = keccak256("multi-root");
        uint8 viewTag = 7;

        bytes memory dummyEphemeralKey = abi.encodePacked(hex"02", hex"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb");

        // Build inputs with nullifier A
        bytes32 nullifierA = keccak256("nullifier-A");
        IZKVerifier.NullifierProofPublicInputs memory piA = IZKVerifier.NullifierProofPublicInputs({
            nullifier: nullifierA,
            merkleRoot: merkleRoot,
            recipient: makeAddr("recipient-A"),
            viewTag: viewTag,
            token: token,
            amount: 500e6,
            chainId: block.chainid,
            ephemeralPublicKey: dummyEphemeralKey
        });

        bytes32 hashA = keccak256(
            abi.encodePacked(piA.nullifier, piA.merkleRoot, piA.recipient, piA.viewTag, piA.token, piA.amount, piA.chainId, piA.ephemeralPublicKey, piA.ephemeralPublicKey.length)
        );
        (uint8 vA, bytes32 rA, bytes32 sA) = vm.sign(signerPrivateKey, hashA);
        bytes memory proofA = abi.encodePacked(rA, sA, vA - 27);

        // Build inputs with nullifier B
        bytes32 nullifierB = keccak256("nullifier-B");
        IZKVerifier.NullifierProofPublicInputs memory piB = IZKVerifier.NullifierProofPublicInputs({
            nullifier: nullifierB,
            merkleRoot: merkleRoot,
            recipient: makeAddr("recipient-B"),
            viewTag: viewTag,
            token: token,
            amount: 300e6,
            chainId: block.chainid,
            ephemeralPublicKey: dummyEphemeralKey
        });

        bytes32 hashB = keccak256(
            abi.encodePacked(piB.nullifier, piB.merkleRoot, piB.recipient, piB.viewTag, piB.token, piB.amount, piB.chainId, piB.ephemeralPublicKey, piB.ephemeralPublicKey.length)
        );
        (uint8 vB, bytes32 rB, bytes32 sB) = vm.sign(signerPrivateKey, hashB);
        bytes memory proofB = abi.encodePacked(rB, sB, vB - 27);

        // Use nullifier A
        assertTrue(nullifierVerifier.verifyNullifierProof(0, proofA, piA), "Nullifier A should succeed");
        assertTrue(nullifierVerifier.isNullifierUsed(nullifierA), "Nullifier A should be used");

        // Use different nullifier B — should succeed (different nullifier)
        assertTrue(nullifierVerifier.verifyNullifierProof(0, proofB, piB), "Nullifier B should succeed (different)");
        assertTrue(nullifierVerifier.isNullifierUsed(nullifierB), "Nullifier B should be used");

        // Both should be marked used
        assertTrue(nullifierVerifier.isNullifierUsed(nullifierA), "Nullifier A still used");
        assertTrue(nullifierVerifier.isNullifierUsed(nullifierB), "Nullifier B still used");
    }

    function test_RevertWhen_ZeroVerifier() public {
        vm.expectRevert(EphemeralFactory.ZeroAddressNotAllowed.selector);
        new EphemeralFactory(address(0), address(router));
    }

    function test_RevertWhen_ZeroImplementation() public {
        vm.expectRevert(EphemeralFactory.ZeroAddressNotAllowed.selector);
        new EphemeralFactory(address(verifier), address(0));
    }

    // ───── ZKVerifier Production Mode Tests ─────

    function test_ProductionModeGuard_RevertsBootstrap() public {
        // Deploy a verifier in bootstrap mode
        ZKVerifier prodVerifier = new ZKVerifier(keccak256("test"), 0, true, address(this), address(this));

        // Deploy a mock full verifier that always reverts (simulating a real verifier
        // rejecting an invalid proof) and activate production mode
        MockFullVerifier mockVerifier = new MockFullVerifier();
        vm.prank(address(this));
        prodVerifier.upgradeVerifier(address(mockVerifier));
        prodVerifier.activateProductionMode();

        assertTrue(prodVerifier.productionMode(), "Production mode should be active");

        // Now verify that bootstrap mode reverts with ProofVerificationFailed
        // (the full verifier rejects the garbage proof — bootstrap is never reached)
        bytes memory dummyEphemeralKey = abi.encodePacked(hex"02", hex"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc");

        IZKVerifier.GhostTransferPublicInputs memory inputs = IZKVerifier
            .GhostTransferPublicInputs({
                senderCommitment: bytes32(uint256(1)),
                recipientCommitment: bytes32(uint256(2)),
                contractHash: keccak256("test"),
                token: address(0x1),
                amount: 100,
                nonce: 1,
                chainId: block.chainid,
                ephemeralPublicKey: dummyEphemeralKey
            });

        vm.expectRevert(ZKVerifier.ProofVerificationFailed.selector);
        prodVerifier.verifyGroth16Proof(hex"", inputs);
    }

    function test_ProductionMode_ActivateBeforeUpgrade_Reverts() public {
        // Deploy verifier WITHOUT a full verifier
        ZKVerifier prodVerifier = new ZKVerifier(keccak256("test"), 0, true, address(this), address(this));

        // Attempting to activate production mode without full verifier should revert
        vm.expectRevert(ZKVerifier.NoFullVerifierSet.selector);
        prodVerifier.activateProductionMode();
    }

    function test_RevertWhen_BootstrapDisabledWithoutFullVerifier_Groth16() public {
        ZKVerifier verifier = new ZKVerifier(keccak256("test"), 0, false, address(this), address(0));

        bytes memory dummyEphemeralKey = abi.encodePacked(hex"02", hex"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc");

        IZKVerifier.GhostTransferPublicInputs memory inputs = IZKVerifier.GhostTransferPublicInputs({
            senderCommitment: bytes32(uint256(1)),
            recipientCommitment: bytes32(uint256(2)),
            contractHash: keccak256("test"),
            token: address(0x1),
            amount: 100,
            nonce: 1,
            chainId: block.chainid,
            ephemeralPublicKey: dummyEphemeralKey
        });

        vm.expectRevert(ZKVerifier.BootstrapNotAllowedInProduction.selector);
        verifier.verifyGroth16Proof(hex"", inputs);
    }

    function test_RevertWhen_BootstrapDisabledWithoutFullVerifier_Plonk() public {
        ZKVerifier verifier = new ZKVerifier(keccak256("test"), 1, false, address(this), address(0));

        bytes memory dummyEphemeralKey = abi.encodePacked(hex"02", hex"dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd");

        IZKVerifier.GhostTransferPublicInputs memory inputs = IZKVerifier.GhostTransferPublicInputs({
            senderCommitment: bytes32(uint256(1)),
            recipientCommitment: bytes32(uint256(2)),
            contractHash: keccak256("test"),
            token: address(0x1),
            amount: 100,
            nonce: 1,
            chainId: block.chainid,
            ephemeralPublicKey: dummyEphemeralKey
        });

        vm.expectRevert(ZKVerifier.BootstrapNotAllowedInProduction.selector);
        verifier.verifyPlonkProof(hex"", inputs);
    }

    function test_RevertWhen_BootstrapDisabledWithoutFullVerifier_Nullifier() public {
        ZKVerifier verifier = new ZKVerifier(keccak256("test"), 0, false, address(this), address(0));

        bytes memory dummyEphemeralKey = abi.encodePacked(hex"02", hex"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee");

        IZKVerifier.NullifierProofPublicInputs memory pi = IZKVerifier.NullifierProofPublicInputs({
            nullifier: keccak256("test-nullifier"),
            merkleRoot: keccak256("test-root"),
            recipient: address(0x1),
            viewTag: 1,
            token: address(0x1),
            amount: 100,
            chainId: block.chainid,
            ephemeralPublicKey: dummyEphemeralKey
        });

        vm.expectRevert(ZKVerifier.BootstrapNotAllowedInProduction.selector);
        verifier.verifyNullifierProof(0, hex"", pi);
    }

    function test_ProductionMode_OneWaySwitch() public {
        ZKVerifier prodVerifier = new ZKVerifier(keccak256("test"), 0, true, address(this), address(this));

        address dummyVerifier = address(0xdead);
        vm.prank(address(this));
        prodVerifier.upgradeVerifier(dummyVerifier);

        // First activation should succeed
        prodVerifier.activateProductionMode();
        assertTrue(prodVerifier.productionMode(), "Production mode should be active");

        // Second activation should revert (already in production mode)
        vm.expectRevert(ZKVerifier.AlreadyInProductionMode.selector);
        prodVerifier.activateProductionMode();
    }

    function test_UpgradeVerifier_TwiceReverts() public {
        ZKVerifier prodVerifier = new ZKVerifier(keccak256("test"), 0, true, address(this), address(this));

        vm.prank(address(this));
        prodVerifier.upgradeVerifier(address(0xdead));

        // Second upgrade should revert
        vm.expectRevert(ZKVerifier.AlreadyUpgraded.selector);
        prodVerifier.upgradeVerifier(address(0xbeef));
    }

    function test_ProductionMode_ImmutableAfterActivation() public {
        ZKVerifier prodVerifier = new ZKVerifier(keccak256("test"), 0, true, address(this), address(this));

        address dummyVerifier = address(0xdead);
        vm.prank(address(this));
        prodVerifier.upgradeVerifier(dummyVerifier);
        prodVerifier.activateProductionMode();

        // Verify we cannot downgrade - productionMode has no setter for false
        // (the only way to verify this is that there's no setter function)
        assertTrue(prodVerifier.productionMode(), "Production mode must remain active");
    }

    function test_ProxyDeployment() public {
        vm.startPrank(alice);

        uint256 amount = 500e6;
        bytes32 commitment = keccak256("proxy-test");
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory ephemeralKey = abi.encodePacked(hex"02", hex"dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd");
        uint8 viewTag = 33;

        MockERC20(token).approve(address(factory), amount);

        (bytes32 swapId, address proxy) = factory.createEphemeralContract(
            token,
            amount,
            CHAIN_ID_POLYGON,
            commitment,
            expiry,
            TEST_GHOST_RECIPIENT,
            ephemeralKey,
            viewTag
        );

        assertTrue(swapId != bytes32(0), "Swap ID should not be zero");
        assertTrue(proxy != address(0), "Proxy address should not be zero");
        assertTrue(proxy.code.length > 0, "Proxy should have contract code");

        // Verify the proxy has a swap associated with it via the factory
        IEphemeralFactory.EphemeralSwap memory swap = factory.getSwap(swapId);
        assertEq(swap.proxy, proxy, "Swap should reference the proxy");

        vm.stopPrank();
    }

    // ───── GCL-SC-04 Fix: Factory Set During CREATE (Immutable) ─────

    /// @notice Verifies the implementation router's factory field is never set.
    ///         GCL-SC-04 FIX: No external factory-setter exists on the router.
    ///         The factory is stored per-proxy during the CREATE opcode via custom
    ///         init bytecode that runs CALLER + SSTORE(0) atomically within CREATE.
    function test_GCL_SC_04_ImplementationFactoryIsUnset() public view {
        assertEq(
            router.factory(),
            address(0),
            "[GCL-SC-04] Implementation factory MUST be address(0)"
        );
    }

    /// @notice Verifies each proxy has its factory atomically set during CREATE
    ///         to the EphemeralFactory address. Because the factory is stored
    ///         by the init code within the CREATE opcode (not via a separate
    ///         external call), no front-running is possible — the proxy does not
    ///         exist until CREATE, and the SSTORE happens in the same opcode.
    function test_GCL_SC_04_ProxyFactoryIsSetAndImmutable() public {
        vm.startPrank(alice);

        uint256 amount = 500e6;
        bytes32 commitment = keccak256("gcl-sc-04-test");
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory ephemeralKey = abi.encodePacked(
            hex"02", hex"deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
        );
        uint8 viewTag = 42;

        MockERC20(token).approve(address(factory), amount);

        (bytes32 swapId, address proxy) = factory.createEphemeralContract(
            token, amount, CHAIN_ID_POLYGON, commitment, expiry, TEST_GHOST_RECIPIENT, ephemeralKey, viewTag
        );

        vm.stopPrank();

        // Verify proxy's factory is set to the actual EphemeralFactory (set during CREATE)
        address proxyFactory = EphemeralRouter(proxy).factory();
        assertEq(
            proxyFactory,
            address(factory),
            "[GCL-SC-04] Proxy factory MUST be the EphemeralFactory"
        );

        // No function exists to change the factory — no initializeFactory, no setFactory.
        // The factory stored during CREATE is permanent and immutable.
    }

    /// @notice Verifies the old setFactory() function no longer exists on the router.
    function test_GCL_SC_04_NoPublicSetFactory() public {
        vm.expectRevert();
        address(router).call(abi.encodeWithSignature("setFactory(address)", address(0xdead)));
    }

    /// @notice Verifies an attacker cannot affect any proxy's factory, because
    ///         the factory is set during CREATE (CALLER → SSTORE) and no external
    ///         function exists to overwrite it. Even the implementation contract
    ///         has no factory-setter — its factory stays address(0) forever.
    function test_GCL_SC_04_AttackerCannotAffectProxies() public {
        // The implementation has NO initializeFactory() — it was removed.
        // The factory is set per-proxy during CREATE and is immutable.
        // Verify the implementation's factory is still address(0) (no one could set it)
        assertEq(
            router.factory(),
            address(0),
            "[GCL-SC-04] Implementation factory MUST remain address(0)"
        );

        // Create a proxy — its factory must be the REAL EphemeralFactory,
        // set atomically during CREATE by the custom init code.
        vm.startPrank(alice);
        uint256 amount = 500e6;
        bytes32 commitment = keccak256("gcl-sc-04-attack-test");
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory ephemeralKey = abi.encodePacked(
            hex"03", hex"cafebabecafebabecafebabecafebabecafebabecafebabecafebabecafebabe"
        );
        uint8 viewTag = 7;

        MockERC20(token).approve(address(factory), amount);
        (bytes32 swapId, address proxy) = factory.createEphemeralContract(
            token, amount, CHAIN_ID_ARBITRUM, commitment, expiry, TEST_GHOST_RECIPIENT, ephemeralKey, viewTag
        );
        vm.stopPrank();

        // Proxy's factory is the REAL factory, set immutably during CREATE
        address proxyFactory = EphemeralRouter(proxy).factory();
        assertEq(
            proxyFactory,
            address(factory),
            "[GCL-SC-04] Proxy factory MUST be the real factory, immutable"
        );
    }

    // ───── GCL-SC-07: SafeERC20 Transfer Safety Tests ─────

    /// @notice Tests SafeERC20 with standard ERC20 token (like USDC)
    function test_SafeERC20_StandardToken_Transfer() public {
        address standardToken = address(new MockERC20("USD Coin", "USDC", 6));
        MockERC20(standardToken).mint(alice, 10000e6);

        vm.startPrank(alice);
        MockERC20(standardToken).approve(address(factory), 1000e6);
        
        uint256 amount = 1000e6;
        bytes32 commitment = keccak256("standard-token-test");
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory ephemeralKey = abi.encodePacked(hex"02", hex"1111111111111111111111111111111111111111111111111111111111111111");
        uint8 viewTag = 1;

        bytes32 swapId = factory.createEphemeralSwap(
            standardToken,
            amount,
            CHAIN_ID_ARBITRUM,
            commitment,
            expiry,
            TEST_GHOST_RECIPIENT,
            ephemeralKey,
            viewTag
        );

        assertTrue(swapId != bytes32(0), "Swap should be created with standard token");
        assertEq(MockERC20(standardToken).balanceOf(address(factory)), amount, "Factory should hold tokens");
        vm.stopPrank();
    }

    /// @notice Tests SafeERC20 with USDT-like token (non-returning, non-standard)
    function test_SafeERC20_USDTLikeToken_Transfer() public {
        address usdtToken = address(new MockUSDT());
        MockUSDT(usdtToken).mint(alice, 10000e6);

        vm.startPrank(alice);
        MockUSDT(usdtToken).approve(address(factory), 1000e6);
        
        uint256 amount = 1000e6;
        bytes32 commitment = keccak256("usdt-like-test");
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory ephemeralKey = abi.encodePacked(hex"03", hex"2222222222222222222222222222222222222222222222222222222222222222");
        uint8 viewTag = 2;

        // This should work even though USDT doesn't return bool
        bytes32 swapId = factory.createEphemeralSwap(
            usdtToken,
            amount,
            CHAIN_ID_POLYGON,
            commitment,
            expiry,
            TEST_GHOST_RECIPIENT,
            ephemeralKey,
            viewTag
        );

        assertTrue(swapId != bytes32(0), "[GCL-SC-07] Swap should work with USDT-like token");
        assertEq(MockUSDT(usdtToken).balanceOf(address(factory)), amount, "Factory should hold USDT");
        vm.stopPrank();
    }

    /// @notice Tests SafeERC20 with deflationary token
    function test_SafeERC20_DeflatinaryToken_Rejected() public {
        address deflatToken = address(new MockDeflationary());
        MockDeflationary(deflatToken).mint(alice, 10000e18);

        vm.startPrank(alice);
        MockDeflationary(deflatToken).approve(address(factory), 1000e18);
        
        uint256 amount = 1000e18;
        bytes32 commitment = keccak256("deflat-test");
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory ephemeralKey = abi.encodePacked(hex"02", hex"3333333333333333333333333333333333333333333333333333333333333333");
        uint8 viewTag = 3;

        // Deflationary tokens should be rejected because actual transfer != expected amount
        vm.expectRevert("SafeERC20: transferFrom did not execute");
        factory.createEphemeralSwap(
            deflatToken,
            amount,
            CHAIN_ID_ARBITRUM,
            commitment,
            expiry,
            TEST_GHOST_RECIPIENT,
            ephemeralKey,
            viewTag
        );
        vm.stopPrank();
    }

    /// @notice Tests SafeERC20 rejects broken/malicious token
    function test_SafeERC20_BrokenToken_Rejected() public {
        address brokenToken = address(new MockBrokenERC20());
        MockBrokenERC20(brokenToken).mint(alice, 10000e18);

        vm.startPrank(alice);
        MockBrokenERC20(brokenToken).approve(address(factory), 1000e18);
        
        uint256 amount = 1000e18;
        bytes32 commitment = keccak256("broken-test");
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory ephemeralKey = abi.encodePacked(hex"02", hex"4444444444444444444444444444444444444444444444444444444444444444");
        uint8 viewTag = 4;

        // Broken token should be rejected - returns true but doesn't transfer
        vm.expectRevert("SafeERC20: transferFrom did not execute");
        factory.createEphemeralSwap(
            brokenToken,
            amount,
            CHAIN_ID_ARBITRUM,
            commitment,
            expiry,
            TEST_GHOST_RECIPIENT,
            ephemeralKey,
            viewTag
        );
        vm.stopPrank();
    }

    /// @notice Tests SafeERC20 with proxy mode using USDT-like token
    function test_SafeERC20_USDTLikeToken_ProxyMode() public {
        address usdtToken = address(new MockUSDT());
        MockUSDT(usdtToken).mint(alice, 10000e6);

        vm.startPrank(alice);
        MockUSDT(usdtToken).approve(address(factory), 1000e6);
        
        uint256 amount = 1000e6;
        bytes32 commitment = keccak256("usdt-proxy-test");
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory ephemeralKey = abi.encodePacked(hex"03", hex"5555555555555555555555555555555555555555555555555555555555555555");
        uint8 viewTag = 5;

        // Proxy mode should also work with USDT
        (bytes32 swapId, address proxy) = factory.createEphemeralContract(
            usdtToken,
            amount,
            CHAIN_ID_POLYGON,
            commitment,
            expiry,
            TEST_GHOST_RECIPIENT,
            ephemeralKey,
            viewTag
        );

        assertTrue(swapId != bytes32(0), "[GCL-SC-07] Proxy swap should work with USDT");
        assertTrue(proxy != address(0), "Proxy should be created");
        assertEq(MockUSDT(usdtToken).balanceOf(proxy), amount, "Proxy should hold USDT tokens");
        vm.stopPrank();
    }

    /// @notice Tests SafeERC20 fulfillment with USDT-like token
    function test_SafeERC20_USDTLikeToken_Fulfillment() public {
        address usdtToken = address(new MockUSDT());
        MockUSDT(usdtToken).mint(alice, 10000e6);

        // Create swap with USDT
        vm.startPrank(alice);
        uint256 amount = 1000e6;
        bytes32 commitment = keccak256("usdt-fulfill-test");
        uint256 expiry = block.timestamp + 1 hours;
        bytes memory ephemeralKey = abi.encodePacked(hex"02", hex"6666666666666666666666666666666666666666666666666666666666666666");
        uint8 viewTag = 6;

        MockUSDT(usdtToken).approve(address(factory), amount);
        bytes32 swapId = factory.createEphemeralSwap(
            usdtToken,
            amount,
            CHAIN_ID_ARBITRUM,
            commitment,
            expiry,
            TEST_GHOST_RECIPIENT,
            ephemeralKey,
            viewTag
        );
        vm.stopPrank();

        address recipient = makeAddr("usdt-recipient");
        bytes memory dummyProof = hex"0000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000200";
        IZKVerifier.GhostTransferPublicInputs memory pi = IZKVerifier.GhostTransferPublicInputs({
            senderCommitment: commitment,
            recipientCommitment: bytes32(0),
            contractHash: keccak256(abi.encodePacked(swapId, address(factory))),
            token: usdtToken,
            amount: amount,
            nonce: uint256(swapId),
            chainId: block.chainid,
            ephemeralPublicKey: ephemeralKey
        });
        vm.mockCall(
            address(verifier),
            abi.encodeWithSelector(IZKVerifier.verify.selector, 0, dummyProof, pi),
            abi.encode(true)
        );

        uint256 balanceBefore = MockUSDT(usdtToken).balanceOf(recipient);

        // Fulfill - should transfer USDT correctly even though it doesn't return bool
        vm.prank(bob);
        bytes32 contractHash = keccak256(abi.encodePacked(swapId, address(factory)));
        factory.fulfillSwap(swapId, dummyProof, recipient, contractHash, ephemeralKey);

        uint256 balanceAfter = MockUSDT(usdtToken).balanceOf(recipient);
        assertEq(
            balanceAfter,
            balanceBefore + amount,
            "[GCL-SC-07] Recipient should receive USDT correctly"
        );
    }
}

/// @title MockFullVerifier
/// @notice Minimal Groth16 verifier mock that always reverts
///         Used by ProductionModeGuard test to simulate a real verifier
///         rejecting an invalid proof.
contract MockFullVerifier {
    function verifyProof(bytes calldata, bytes calldata) external pure returns (bool) {
        revert("Proof verification failed");
    }
    function verifyPlonkProof(bytes calldata, bytes calldata) external pure returns (bool) {
        revert("Proof verification failed");
    }
}

/// @title MockERC20
/// @notice Minimal ERC20 mock for tests - Standard compliant token
contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public decimals;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _name, string memory _symbol, uint8 _decimals) {
        name = _name;
        symbol = _symbol;
        decimals = _decimals;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
}

/// @title MockUSDT
/// @notice USDT-like ERC20 mock - Returns nothing instead of bool (non-standard)
/// This simulates the actual USDT token behavior
contract MockUSDT {
    string public name = "Tether USD";
    string public symbol = "USDT";
    uint8 public decimals = 6;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    // USDT doesn't return bool - just returns nothing
    function transfer(address to, uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
    }

    // USDT doesn't return bool
    function transferFrom(address from, address to, uint256 amount) external {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external {
        allowance[msg.sender][spender] = amount;
    }
}

/// @title MockDeflationary
/// @notice Deflationary token that takes a 1% fee on transfers
contract MockDeflationary {
    string public name = "Deflationary Token";
    string public symbol = "DEFLAT";
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public constant FEE_PERCENT = 1; // 1% fee

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        uint256 fee = (amount * FEE_PERCENT) / 100;
        uint256 transferAmount = amount - fee;
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += transferAmount;
        // fee is burned
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 fee = (amount * FEE_PERCENT) / 100;
        uint256 transferAmount = amount - fee;
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += transferAmount;
        // fee is burned
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
}

/// @title MockBrokenERC20
/// @notice Broken token that returns success but doesn't actually transfer
contract MockBrokenERC20 {
    string public name = "Broken Token";
    string public symbol = "BROKEN";
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    // Returns true but doesn't actually transfer (malicious token)
    function transfer(address to, uint256 amount) external returns (bool) {
        // Intentionally doesn't update balances - malicious!
        return true;
    }

    // Returns true but doesn't actually transfer
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        // Intentionally doesn't update balances
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
}

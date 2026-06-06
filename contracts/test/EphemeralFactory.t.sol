// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { EphemeralFactory } from "../src/EphemeralFactory.sol";
import { EphemeralRouter } from "../src/EphemeralRouter.sol";
import { ZKVerifier } from "../src/ZKVerifier.sol";
import { IZKVerifier } from "../src/interfaces/IZKVerifier.sol";
import { IEphemeralFactory } from "../src/interfaces/IEphemeralFactory.sol";

/// @title EphemeralFactoryTest
/// @notice Tests for the EphemeralFactory contract including ERC-1167 proxy creation
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

        // Deploy EphemeralRouter (implementation for minimal proxies)
        // The factory address is set by EphemeralFactory constructor via setFactory()
        router = new EphemeralRouter();

        // Deploy EphemeralFactory with router implementation.
        // The constructor calls router.setFactory(address(this)) to authorize itself.
        factory = new EphemeralFactory(address(verifier), address(router));

        // Deploy mock USDT token
        token = address(new MockERC20("Mock USDT", "USDT", 6));

        // Fund Alice with tokens
        MockERC20(token).mint(alice, 10000e6);
    }

    // ───── Create Swap Tests (Escrow Mode) ─────

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
            ephemeralKey,
            viewTag
        );

        assertTrue(swapId != bytes32(0), "Swap ID should not be zero");

        IEphemeralFactory.EphemeralSwap memory swap = factory.getSwap(swapId);
        assertEq(swap.creator, alice);
        assertEq(swap.token, token);
        assertEq(swap.amount, amount);
        assertEq(swap.sourceChain, block.chainid);
        assertEq(swap.destinationChain, CHAIN_ID_ARBITRUM);
        assertEq(swap.commitment, commitment);
        assertFalse(swap.fulfilled);
        assertFalse(swap.refunded);
        assertTrue(swap.createdAt > 0);
        assertEq(swap.expiry, expiry);

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
        factory.createEphemeralSwap(token, 0, CHAIN_ID_ARBITRUM, commitment, expiry, ephemeralKey, viewTag);

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
        factory.createEphemeralSwap(token, amount, CHAIN_ID_ARBITRUM, commitment, expiry, ephemeralKey, viewTag);

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
            token, amount, CHAIN_ID_ARBITRUM, commitment, expiry, ephemeralKey, viewTag
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
            token, amount, CHAIN_ID_ARBITRUM, commitment, expiry, ephemeralKey, viewTag
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
            token, amount, CHAIN_ID_ARBITRUM, commitment, expiry, ephemeralKey, viewTag
        );

        vm.expectRevert(EphemeralFactory.SwapNotExpired.selector);
        factory.refundSwap(swapId);

        vm.stopPrank();
    }

    // ───── Constructor Tests ─────

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

        // Set a dummy full verifier and activate production mode
        address dummyVerifier = address(0xdead);
        vm.prank(address(this));
        prodVerifier.upgradeVerifier(dummyVerifier);
        prodVerifier.activateProductionMode();

        assertTrue(prodVerifier.productionMode(), "Production mode should be active");

        // Now verify that bootstrap mode reverts (no full verifier properly set)
        IZKVerifier.GhostTransferPublicInputs memory inputs = IZKVerifier
            .GhostTransferPublicInputs({
                senderCommitment: bytes32(uint256(1)),
                recipientCommitment: bytes32(uint256(2)),
                contractHash: keccak256("test"),
                token: address(0x1),
                amount: 100,
                nonce: 1,
                chainId: block.chainid
            });

        vm.expectRevert(ZKVerifier.BootstrapNotAllowedInProduction.selector);
        prodVerifier.verifyGroth16Proof(hex"", inputs);
    }

    function test_ProductionMode_ActivateBeforeUpgrade_Reverts() public {
        // Deploy verifier WITHOUT a full verifier
        ZKVerifier prodVerifier = new ZKVerifier(keccak256("test"), 0, true, address(this), address(this));

        // Attempting to activate production mode without full verifier should revert
        vm.expectRevert(ZKVerifier.NoFullVerifierSet.selector);
        prodVerifier.activateProductionMode();
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
}

/// @title MockERC20
/// @notice Minimal ERC20 mock for testing
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

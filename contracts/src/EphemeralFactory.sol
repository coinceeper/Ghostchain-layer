// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IEphemeralFactory } from "./interfaces/IEphemeralFactory.sol";
import { IZKVerifier } from "./interfaces/IZKVerifier.sol";
import { IERC20 } from "./interfaces/IERC20.sol";
import { EphemeralRouter } from "./EphemeralRouter.sol";

/// @title EphemeralFactory
/// @notice Core factory contract that creates and manages one-time ephemeral swap
///         contracts for private, censorship-resistant USDT transfers. Each swap
///         is backed by ZK proofs for privacy and atomicity.
///
/// @dev This contract supports two modes:
///      1. Direct Escrow (gas-efficient): Tokens are locked directly in this contract.
///         Ideal for L2 networks like Arbitrum and Base.
///      2. ERC-1167 Minimal Proxy: Each swap gets its own lightweight proxy contract
///         (~100k gas) that delegates to EphemeralRouter. More censorship-resistant
///         as each swap is a standalone contract. The proxy address is stored in the
///         swap struct and used during fulfillment to transfer tokens from the proxy.
contract EphemeralFactory is IEphemeralFactory {
    // ───── State ─────

    /// @notice Address of the ZK verifier contract
    address public immutable override verifier;

    /// @notice Address of the EphemeralRouter implementation for minimal proxies
    address public immutable implementation;

    /// @notice Maximum duration a swap can remain open before expiry
    uint256 public constant MAX_DURATION = 24 hours;

    /// @notice Minimum duration for a swap
    uint256 public constant MIN_DURATION = 5 minutes;

    /// @notice Maps swapId to swap details
    mapping(bytes32 => EphemeralSwap) private _swaps;

    /// @notice Tracks active swap IDs for a user
    mapping(address => bytes32[]) private _userSwaps;

    /// @notice Total number of swaps created (used for nonce)
    uint256 private _swapCount;

    /// @notice Total number of minimal proxy contracts created
    uint256 public totalContractsCreated;

    // ───── Events ─────

    /// @notice Emitted when a minimal proxy ephemeral contract is created
    /// @param proxy Address of the deployed minimal proxy
    /// @param creator Address of the user who created it
    /// @param timestamp Block timestamp of creation
    event EphemeralContractCreated(
        address indexed proxy,
        address indexed creator,
        uint256 timestamp
    );

    // ───── Constructor ─────

    constructor(address _verifier, address _implementation) {
        if (_verifier == address(0)) revert ZeroAddressNotAllowed();
        if (_implementation == address(0)) revert ZeroAddressNotAllowed();
        verifier = _verifier;
        implementation = _implementation;
    }

    // ───── External Write Functions ─────

    /// @inheritdoc IEphemeralFactory
    function createEphemeralSwap(
        address token,
        uint256 amount,
        uint256 destinationChain,
        bytes32 commitment,
        uint256 expiry,
        bytes calldata ephemeralPublicKey,
        uint8 viewTag
    ) external returns (bytes32 swapId) {
        if (token == address(0)) revert ZeroAddressNotAllowed();
        if (amount == 0) revert InvalidAmount();
        if (commitment == bytes32(0)) revert InvalidCommitment();
        if (expiry < block.timestamp + MIN_DURATION) revert ExpiryTooShort();
        if (expiry > block.timestamp + MAX_DURATION) revert ExpiryTooLong();
        if (ephemeralPublicKey.length == 0) revert InvalidEphemeralKey();

        // Generate unique swap ID
        swapId = keccak256(
            abi.encodePacked(
                msg.sender,
                token,
                amount,
                destinationChain,
                commitment,
                _swapCount,
                block.chainid
            )
        );

        if (_swaps[swapId].createdAt != 0) revert SwapAlreadyExists();

        // Transfer tokens from user to this contract (escrow mode)
        IERC20(token).transferFrom(msg.sender, address(this), amount);

        // Store swap (no proxy in escrow mode)
        _swaps[swapId] = EphemeralSwap({
            creator: msg.sender,
            token: token,
            amount: amount,
            sourceChain: block.chainid,
            destinationChain: destinationChain,
            commitment: commitment,
            solver: address(0),
            fulfilled: false,
            refunded: false,
            createdAt: block.timestamp,
            expiry: expiry,
            proxy: address(0)
        });

        _userSwaps[msg.sender].push(swapId);
        _swapCount++;

        emit EphemeralSwapCreated(
            swapId,
            msg.sender,
            token,
            amount,
            block.chainid,
            destinationChain,
            commitment,
            ephemeralPublicKey,
            viewTag
        );
    }

    /// @inheritdoc IEphemeralFactory
    function createEphemeralContract(
        address token,
        uint256 amount,
        uint256 destinationChain,
        bytes32 commitment,
        uint256 expiry,
        bytes calldata ephemeralPublicKey,
        uint8 viewTag
    ) external returns (bytes32 swapId, address proxy) {
        if (token == address(0)) revert ZeroAddressNotAllowed();
        if (amount == 0) revert InvalidAmount();
        if (commitment == bytes32(0)) revert InvalidCommitment();
        if (expiry < block.timestamp + MIN_DURATION) revert ExpiryTooShort();
        if (expiry > block.timestamp + MAX_DURATION) revert ExpiryTooLong();
        if (ephemeralPublicKey.length == 0) revert InvalidEphemeralKey();

        // Generate unique swap ID
        swapId = keccak256(
            abi.encodePacked(
                msg.sender,
                token,
                amount,
                destinationChain,
                commitment,
                _swapCount,
                block.chainid,
                "proxy"
            )
        );

        if (_swaps[swapId].createdAt != 0) revert SwapAlreadyExists();

        // Deploy minimal proxy (ERC-1167)
        proxy = _createMinimalProxy(implementation);

        // Transfer tokens from user to the proxy (proxy mode)
        IERC20(token).transferFrom(msg.sender, proxy, amount);

        // Store swap with proxy address
        _swaps[swapId] = EphemeralSwap({
            creator: msg.sender,
            token: token,
            amount: amount,
            sourceChain: block.chainid,
            destinationChain: destinationChain,
            commitment: commitment,
            solver: address(0),
            fulfilled: false,
            refunded: false,
            createdAt: block.timestamp,
            expiry: expiry,
            proxy: proxy
        });

        _userSwaps[msg.sender].push(swapId);
        _swapCount++;
        totalContractsCreated++;

        emit EphemeralSwapCreated(
            swapId,
            msg.sender,
            token,
            amount,
            block.chainid,
            destinationChain,
            commitment,
            ephemeralPublicKey,
            viewTag
        );
        emit EphemeralContractCreated(proxy, msg.sender, block.timestamp);
    }

    /// @inheritdoc IEphemeralFactory
    function fulfillSwap(
        bytes32 swapId,
        bytes calldata proof,
        address recipient
    ) external {
        EphemeralSwap storage swap = _swaps[swapId];

        if (swap.createdAt == 0) revert SwapNotFound();
        if (swap.fulfilled) revert SwapAlreadyFulfilled();
        if (swap.refunded) revert SwapAlreadyRefunded();
        if (block.timestamp > swap.expiry) revert SwapExpired();
        if (recipient == address(0)) revert ZeroAddressNotAllowed();

        // Decode and verify ZK proof
        IZKVerifier.GhostTransferPublicInputs memory publicInputs = IZKVerifier
            .GhostTransferPublicInputs({
                senderCommitment: swap.commitment,
                recipientCommitment: bytes32(0),
                contractHash: keccak256(abi.encodePacked(swapId, address(this))),
                token: swap.token,
                amount: swap.amount,
                nonce: uint256(swapId),
                chainId: block.chainid
            });

        // Verify the proof
        bool verified = IZKVerifier(verifier).verify(0, proof, publicInputs);
        if (!verified) revert ProofVerificationFailed();

        // Mark as fulfilled
        swap.fulfilled = true;
        swap.solver = msg.sender;

        // Determine token source based on swap mode
        if (swap.proxy != address(0)) {
            // Proxy mode: tokens are in the minimal proxy contract.
            // Call the proxy which delegates to EphemeralRouter.execute(),
            // executing in the proxy's context so its token balance is used.
            (bool success, ) = swap.proxy.call(
                abi.encodeWithSelector(
                    EphemeralRouter.execute.selector,
                    msg.sender,
                    proof,
                    swap.amount,
                    swap.token
                )
            );
            if (!success) revert ExecuteFailed();
        } else {
            // Escrow mode: tokens are in this factory contract
            IERC20(swap.token).transfer(msg.sender, swap.amount);
        }

        emit SwapFulfilled(swapId, msg.sender, recipient);
    }

    /// @inheritdoc IEphemeralFactory
    function refundSwap(bytes32 swapId) external {
        EphemeralSwap storage swap = _swaps[swapId];

        if (swap.createdAt == 0) revert SwapNotFound();
        if (swap.fulfilled) revert SwapAlreadyFulfilled();
        if (swap.refunded) revert SwapAlreadyRefunded();
        if (block.timestamp <= swap.expiry) revert SwapNotExpired();
        if (msg.sender != swap.creator) revert NotSwapCreator();

        swap.refunded = true;

        if (swap.proxy != address(0)) {
            // Proxy mode: call the proxy to sweep tokens back to creator
            (bool success, ) = swap.proxy.call(
                abi.encodeWithSelector(
                    EphemeralRouter.execute.selector,
                    swap.creator,
                    abi.encodePacked(swapId),
                    swap.amount,
                    swap.token
                )
            );
            if (!success) revert ExecuteFailed();
        } else {
            // Escrow mode: transfer from factory balance
            IERC20(swap.token).transfer(swap.creator, swap.amount);
        }

        emit SwapExpired(swapId, msg.sender);
    }

    // ───── View Functions ─────

    /// @inheritdoc IEphemeralFactory
    function getSwap(bytes32 swapId) external view returns (EphemeralSwap memory) {
        return _swaps[swapId];
    }

    /// @inheritdoc IEphemeralFactory
    function isSwapActive(bytes32 swapId) external view returns (bool) {
        EphemeralSwap storage swap = _swaps[swapId];
        return swap.createdAt != 0
            && !swap.fulfilled
            && !swap.refunded
            && block.timestamp <= swap.expiry;
    }

    /// @notice Returns all swap IDs for a given user
    /// @param user The address to query
    /// @return Array of swap IDs
    function getUserSwaps(address user) external view returns (bytes32[] memory) {
        return _userSwaps[user];
    }

    /// @notice Returns the total number of swaps created
    function swapCount() external view returns (uint256) {
        return _swapCount;
    }

    // ───── ERC-1167 Minimal Proxy ─────

    /// @notice Creates an ERC-1167 minimal proxy that delegates to the implementation.
    ///         The proxy bytecode is only 45 bytes, costing ~100k gas to deploy.
    /// @param target The implementation contract to delegate to
    /// @return proxy The address of the created proxy
    function _createMinimalProxy(address target) internal returns (address proxy) {
        // ERC-1167 Minimal Proxy bytecode:
        // 3d602d80600a3d3981f3363d3d373d3d3d363d73<address>5af43d82803e903d91602b57fd5bf3
        bytes20 targetBytes = bytes20(target);
        assembly {
            let clone := mload(0x40)
            mstore(clone, 0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000)
            mstore(add(clone, 0x14), targetBytes)
            mstore(add(clone, 0x28), 0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000)
            proxy := create(0, clone, 0x37)
        }
        require(proxy != address(0), "Proxy creation failed");
    }

    // ───── Custom Errors ─────

    error ZeroAddressNotAllowed();
    error InvalidAmount();
    error InvalidCommitment();
    error ExpiryTooShort();
    error ExpiryTooLong();
    error SwapAlreadyExists();
    error SwapNotFound();
    error SwapAlreadyFulfilled();
    error SwapAlreadyRefunded();
    error SwapExpired();
    error SwapNotExpired();
    error ProofVerificationFailed();
    error NotSwapCreator();
    error ExecuteFailed();
    error InvalidEphemeralKey();
}

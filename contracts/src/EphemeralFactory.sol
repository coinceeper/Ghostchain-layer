// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IEphemeralFactory } from "./interfaces/IEphemeralFactory.sol";
import { IZKVerifier } from "./interfaces/IZKVerifier.sol";
import { IERC20 } from "./interfaces/IERC20.sol";
import { EphemeralRouter } from "./EphemeralRouter.sol";
import { Ownable } from "./lib/Ownable.sol";

/// @title EphemeralFactory
/// @notice Creates and manages one-time ephemeral swap contracts for private
///         USDT transfers backed by ZK proofs.
///
/// @dev Two modes: direct escrow (gas-efficient for L2s) and ERC-1167 minimal
///      proxy (more censorship-resistant, ~100k gas per proxy).
///
///      GCL-ZK-01 fix: ephemeralPublicKey is stored on-chain and used in ZK
///      proof verification to constrain sharedSecret derivation.
contract EphemeralFactory is IEphemeralFactory, Ownable {
    // ───── State ─────

    /// @notice Address of the ZK verifier contract
    address public immutable override verifier;

    /// @notice Address of the EphemeralRouter implementation for minimal proxies.
    ///         The factory address is passed to the router for access control.
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

    /// @notice Emitted when a minimal proxy contract is deployed
    /// @param proxy Address of the deployed minimal proxy
    /// @param creator Address of the user who created it
    /// @param timestamp Block timestamp of creation
    event EphemeralContractCreated(
        address indexed proxy,
        address indexed creator,
        uint256 timestamp
    );

    // ───── Constructor ─────

    constructor(address _verifier, address _implementation) Ownable(msg.sender) {
        if (_verifier == address(0)) revert ZeroAddressNotAllowed();
        if (_implementation == address(0)) revert ZeroAddressNotAllowed();
        verifier = _verifier;
        implementation = _implementation;

        // GCL-SC-04 FIX: The implementation contract's factory storage is never
        // evaluated at runtime — only each proxy's own storage matters (set
        // atomically during CREATE via custom init code in _createMinimalProxy).
        // No external initialization function exists on the router, so no
        // front-running window exists at any point in the lifecycle.
    }

    // ───── External Write Functions ─────

    /// @inheritdoc IEphemeralFactory
    function createEphemeralSwap(
        address token,
        uint256 amount,
        uint256 destinationChain,
        bytes32 commitment,
        uint256 expiry,
        address recipientGhostAddress,
        bytes calldata ephemeralPublicKey,
        uint8 viewTag
    ) external returns (bytes32 swapId) {
        if (token == address(0)) revert ZeroAddressNotAllowed();
        if (amount == 0) revert InvalidAmount();
        if (commitment == bytes32(0)) revert InvalidCommitment();
        if (recipientGhostAddress == address(0)) revert ZeroAddressNotAllowed();
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

        // Store swap with recipientGhostAddress and ephemeralPublicKey
        _swaps[swapId] = EphemeralSwap({
            creator: msg.sender,
            token: token,
            amount: amount,
            sourceChain: block.chainid,
            destinationChain: destinationChain,
            commitment: commitment,
            recipientGhostAddress: recipientGhostAddress,
            solver: address(0),
            fulfilled: false,
            refunded: false,
            createdAt: block.timestamp,
            expiry: expiry,
            proxy: address(0),
            ephemeralPublicKey: ephemeralPublicKey
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
            recipientGhostAddress,
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
        address recipientGhostAddress,
        bytes calldata ephemeralPublicKey,
        uint8 viewTag
    ) external returns (bytes32 swapId, address proxy) {
        if (token == address(0)) revert ZeroAddressNotAllowed();
        if (amount == 0) revert InvalidAmount();
        if (commitment == bytes32(0)) revert InvalidCommitment();
        if (recipientGhostAddress == address(0)) revert ZeroAddressNotAllowed();
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

        // Store swap with recipientGhostAddress and ephemeralPublicKey
        _swaps[swapId] = EphemeralSwap({
            creator: msg.sender,
            token: token,
            amount: amount,
            sourceChain: block.chainid,
            destinationChain: destinationChain,
            commitment: commitment,
            recipientGhostAddress: recipientGhostAddress,
            solver: address(0),
            fulfilled: false,
            refunded: false,
            createdAt: block.timestamp,
            expiry: expiry,
            proxy: proxy,
            ephemeralPublicKey: ephemeralPublicKey
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
            recipientGhostAddress,
            ephemeralPublicKey,
            viewTag
        );
        emit EphemeralContractCreated(proxy, msg.sender, block.timestamp);
    }

    /// @inheritdoc IEphemeralFactory
    function fulfillSwap(
        bytes32 swapId,
        bytes calldata proof,
        address recipient,
        bytes32 contractHash,
        bytes calldata ephemeralPublicKey
    ) external {
        EphemeralSwap storage swap = _swaps[swapId];

        if (swap.createdAt == 0) revert SwapNotFound();
        if (swap.fulfilled) revert SwapAlreadyFulfilled();
        if (swap.refunded) revert SwapAlreadyRefunded();
        if (block.timestamp > swap.expiry) revert SwapIsExpired();
        if (recipient == address(0)) revert ZeroAddressNotAllowed();
        if (contractHash == bytes32(0)) revert InvalidContractHash();

        // Validate ephemeralPublicKey matches the stored value (GCL-ZK-01 integrity check)
        if (!_compareBytes(swap.ephemeralPublicKey, ephemeralPublicKey)) {
            revert EphemeralKeyMismatch();
        }

        // FIX GCL-ZK-04: contractHash is provided by the solver (computed off-chain as
        // Poseidon(ghostAddress, token, amount, nonce, chainId)) instead of being computed
        // on-chain as keccak256(swapId, address(this)). This ensures the public input
        // matches the circuit's Poseidon constraint.
        IZKVerifier.GhostTransferPublicInputs memory publicInputs = IZKVerifier
            .GhostTransferPublicInputs({
                senderCommitment: swap.commitment,
                recipientCommitment: bytes32(0),
                contractHash: contractHash,
                token: swap.token,
                amount: swap.amount,
                nonce: uint256(swapId),
                chainId: block.chainid,
                ephemeralPublicKey: ephemeralPublicKey
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
                    recipient,
                    proof,
                    swap.amount,
                    swap.token
                )
            );
            if (!success) revert ExecuteFailed();
        } else {
            // Escrow mode: tokens are in this factory contract
            IERC20(swap.token).transfer(recipient, swap.amount);
        }

        emit SwapFulfilled(swapId, msg.sender, recipient);
    }

    /// @inheritdoc IEphemeralFactory
    function fulfillSwapWithNullifier(
        bytes32 swapId,
        bytes calldata proof,
        address recipient,
        bytes32 nullifier,
        bytes32 merkleRoot,
        uint8 viewTag,
        bytes calldata ephemeralPublicKey
    ) external {
        EphemeralSwap storage swap = _swaps[swapId];

        if (swap.createdAt == 0) revert SwapNotFound();
        if (swap.fulfilled) revert SwapAlreadyFulfilled();
        if (swap.refunded) revert SwapAlreadyRefunded();
        if (block.timestamp > swap.expiry) revert SwapIsExpired();
        if (recipient == address(0)) revert ZeroAddressNotAllowed();
        if (nullifier == bytes32(0)) revert InvalidNullifier();

        // Validate ephemeralPublicKey matches the stored value (GCL-ZK-01 integrity check)
        if (!_compareBytes(swap.ephemeralPublicKey, ephemeralPublicKey)) {
            revert EphemeralKeyMismatch();
        }

        // Construct nullifier proof public inputs
        IZKVerifier.NullifierProofPublicInputs memory publicInputs = IZKVerifier
            .NullifierProofPublicInputs({
                nullifier: nullifier,
                merkleRoot: merkleRoot,
                recipient: recipient,
                viewTag: viewTag,
                token: swap.token,
                amount: swap.amount,
                chainId: block.chainid,
                ephemeralPublicKey: ephemeralPublicKey
            });

        // Verify the nullifier-based ZK proof.
        // The verifier atomically checks that the nullifier is not already used
        // and marks it as consumed upon successful verification.
        bool verified = IZKVerifier(verifier).verifyNullifierProof(0, proof, publicInputs);
        if (!verified) revert ProofVerificationFailed();

        // Mark as fulfilled
        swap.fulfilled = true;
        swap.solver = msg.sender;

        // Determine token source based on swap mode
        if (swap.proxy != address(0)) {
            // Proxy mode: tokens are in the minimal proxy contract.
            (bool success, ) = swap.proxy.call(
                abi.encodeWithSelector(
                    EphemeralRouter.execute.selector,
                    recipient,
                    proof,
                    swap.amount,
                    swap.token
                )
            );
            if (!success) revert ExecuteFailed();
        } else {
            // Escrow mode: tokens are in this factory contract
            IERC20(swap.token).transfer(recipient, swap.amount);
        }

        emit SwapFulfilledWithNullifier(swapId, msg.sender, recipient, nullifier, merkleRoot);
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
    ///         The factory address is stored in the proxy's storage slot 0 DURING the
    ///         CREATE opcode via custom init code (CALLER → SSTORE), making it
    ///         physically impossible for an attacker to front-run.
    ///
    /// @dev    GCL-SC-04 FIX: Unlike the old approach which called initializeFactory()
    ///         as a separate external call after CREATE, this embeds the factory
    ///         initialization IN the CREATE opcode's init code execution. The custom
    ///         proxy bytecode is:
    ///
    ///         Init (14 bytes):  336000553d602d80600e3d3981f3
    ///           - 33        CALLER                    (push factory address)
    ///           - 6000      PUSH1 0                    (storage slot 0)
    ///           - 55        SSTORE                     (store factory in proxy storage)
    ///           - 3d602d     standard ERC-1167 return |
    ///           - 80600e     with adjusted offset (14) |-> copy 45-byte runtime
    ///           - 3d3981f3   and return it             |
    ///         Runtime (45 bytes): 363d3d373d3d3d363d73<impl>5af43d82803e903d91602b57fd5bf3
    ///         Total CREATE size: 59 bytes (vs 55 for standard ERC-1167)
    ///
    /// @param target The implementation contract to delegate to
    /// @return proxy The address of the created proxy
    function _createMinimalProxy(address target) internal returns (address proxy) {
        bytes20 targetBytes = bytes20(target);
        assembly {
            let clone := mload(0x40)
            // Init (14 bytes) + runtime start (10 bytes): CALLER SSTORE + adjusted return
            mstore(clone, 0x336000553d602d80600e3d3981f3363d3d373d3d3d363d7300000000)
            // 20-byte implementation address at offset 24 (0x18)
            mstore(add(clone, 0x18), targetBytes)
            // Remaining runtime code (15 bytes) at offset 44 (0x2c)
            mstore(add(clone, 0x2c), 0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000)
            // CREATE with 59 bytes of init+runtime code
            proxy := create(0, clone, 0x3b)
        }
        require(proxy != address(0), "Proxy creation failed");
        // No external call needed — the factory was set during CREATE by the init code
        // via CALLER → SSTORE(0). This is truly atomic and cannot be front-run.
    }

    // ───── Internal Helpers ─────

    /// @notice Compares two byte arrays for equality.
    /// @param a First byte array
    /// @param b Second byte array
    /// @return True if both arrays are identical
    function _compareBytes(bytes memory a, bytes memory b) internal pure returns (bool) {
        if (a.length != b.length) return false;
        for (uint256 i = 0; i < a.length; i++) {
            if (a[i] != b[i]) return false;
        }
        return true;
    }

    // ───── Emergency Functions ─────

    /// @notice Withdraws accidentally sent ETH from the contract.
    /// @dev    This contract operates with ERC20 tokens only. Any ETH sent
    ///         directly (e.g., via selfdestruct or coinbase) would be stuck
    ///         without this function. Only the owner can call this.
    /// @param to The address to receive the ETH
    function withdrawETH(address payable to) external onlyOwner {
        uint256 balance = address(this).balance;
        if (balance == 0) revert NoETHBalance();
        (bool success, ) = to.call{value: balance}("");
        if (!success) revert ETHWithdrawFailed();
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
    error SwapIsExpired();
    error SwapNotExpired();
    error ProofVerificationFailed();
    error NotSwapCreator();
    error ExecuteFailed();
    error InvalidEphemeralKey();
    error InvalidNullifier();
    error EphemeralKeyMismatch();
    error InvalidContractHash();
    error NoETHBalance();
    error ETHWithdrawFailed();
}

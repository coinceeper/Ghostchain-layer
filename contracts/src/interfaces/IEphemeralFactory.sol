// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IEphemeralFactory
/// @notice Interface for the Ephemeral Factory that creates one-time swap contracts
///         for private USDT transfers. Supports both direct escrow and ERC-1167
///         minimal proxy patterns.
interface IEphemeralFactory {
    // ───── Events ─────

    /// @notice Emitted when a new ephemeral swap contract is created
    /// @param swapId Unique identifier for this swap
    /// @param creator Address of the user creating the swap
    /// @param token The ERC20 token being swapped
    /// @param amount The amount of tokens locked
    /// @param sourceChain Chain identifier where tokens are locked
    /// @param destinationChain Target chain for the output
    /// @param commitment Hash of the ZK proof commitment
    /// @param recipientGhostAddress The ghost (stealth) address receiving funds on destination chain
    /// @param ephemeralPublicKey The ephemeral public key (R) used for stealth address generation
    /// @param viewTag First byte of keccak256(sharedSecret) for fast scanning
    event EphemeralSwapCreated(
        bytes32 indexed swapId,
        address indexed creator,
        address indexed token,
        uint256 amount,
        uint256 sourceChain,
        uint256 destinationChain,
        bytes32 commitment,
        address indexed recipientGhostAddress,
        bytes ephemeralPublicKey,
        uint8 viewTag
    );

    /// @notice Emitted when a solver fills the swap intent on the destination chain
    /// @param swapId The swap identifier
    /// @param solver Address of the solver who filled the intent
    /// @param recipient The ghost address recipient on destination chain
    event SwapFulfilled(
        bytes32 indexed swapId,
        address indexed solver,
        address indexed recipient
    );

    /// @notice Emitted when the swap expires and funds can be reclaimed
    /// @param swapId The swap identifier
    /// @param claimant Address reclaiming the funds
    event SwapExpired(
        bytes32 indexed swapId,
        address indexed claimant
    );

    /// @notice Emitted when a swap is fulfilled using a nullifier-based ZK proof
    /// @param swapId The swap identifier
    /// @param solver Address of the solver who filled the intent
    /// @param recipient The ghost address recipient on destination chain
    /// @param nullifier The nullifier consumed to prevent double-spend
    /// @param merkleRoot Root of the Merkle tree containing the commitment
    event SwapFulfilledWithNullifier(
        bytes32 indexed swapId,
        address indexed solver,
        address indexed recipient,
        bytes32 nullifier,
        bytes32 merkleRoot
    );

    // ───── Structs ─────

    /// @notice Represents a single ephemeral swap
    struct EphemeralSwap {
        address creator;
        address token;
        uint256 amount;
        uint256 sourceChain;
        uint256 destinationChain;
        bytes32 commitment;
        /// @notice Ghost (stealth) address receiving funds on the destination chain.
        ///         Set at creation time so solvers can detect it from on-chain data.
        address recipientGhostAddress;
        address solver;
        bool fulfilled;
        bool refunded;
        uint256 createdAt;
        uint256 expiry;
        /// @notice Address of the ERC-1167 minimal proxy (address(0) in escrow mode)
        address proxy;
        /// @notice Ephemeral public key (R = r*G) used for shared secret derivation.
        ///         Stored to verify ZK proofs that constrain sharedSecret binding (GCL-ZK-01 fix).
        bytes ephemeralPublicKey;
    }

    // ───── Core Functions ─────

    /// @notice Creates a new ephemeral swap, locking tokens into escrow
    /// @param token The ERC20 token address to lock
    /// @param amount The amount of tokens to lock
    /// @param destinationChain The target chain identifier
    /// @param commitment Hash of the ZK proof's public inputs
    /// @param expiry Timestamp after which the swap expires
    /// @param recipientGhostAddress The ghost (stealth) address receiving funds on destination chain
    /// @param ephemeralPublicKey The ephemeral public key (R) for stealth address derivation
    /// @param viewTag First byte of keccak256(sharedSecret) for fast scanning
    /// @return swapId The unique identifier for this swap
    function createEphemeralSwap(
        address token,
        uint256 amount,
        uint256 destinationChain,
        bytes32 commitment,
        uint256 expiry,
        address recipientGhostAddress,
        bytes calldata ephemeralPublicKey,
        uint8 viewTag
    ) external returns (bytes32 swapId);

    /// @notice Creates a new ephemeral swap using an ERC-1167 minimal proxy
    /// @param token The ERC20 token address to lock
    /// @param amount The amount of tokens to lock
    /// @param destinationChain The target chain identifier
    /// @param commitment Hash of the ZK proof's public inputs
    /// @param expiry Timestamp after which the swap expires
    /// @param recipientGhostAddress The ghost (stealth) address receiving funds on destination chain
    /// @param ephemeralPublicKey The ephemeral public key (R) for stealth address derivation
    /// @param viewTag First byte of keccak256(sharedSecret) for fast scanning
    /// @return swapId The unique identifier for this swap
    /// @return proxy The address of the deployed minimal proxy
    function createEphemeralContract(
        address token,
        uint256 amount,
        uint256 destinationChain,
        bytes32 commitment,
        uint256 expiry,
        address recipientGhostAddress,
        bytes calldata ephemeralPublicKey,
        uint8 viewTag
    ) external returns (bytes32 swapId, address proxy);

    /// @notice Fulfills a swap intent on behalf of a recipient.
    ///         The solver provides the ephemeralPublicKey from the swap creation event
    ///         so the verifier can include it in the public input hash (GCL-ZK-01 fix).
    /// @dev    contractHash must equal Poseidon(ghostAddress, token, amount, nonce, chainId)
    ///         as computed by the circuit (fixes GCL-ZK-04).
    /// @param swapId The swap to fulfill
    /// @param proof The ZK proof verifying the solver's right to claim
    /// @param recipient The ghost address receiving the funds
    /// @param contractHash The Poseidon(ghostAddress, token, amount, nonce, chainId) binding hash
    /// @param ephemeralPublicKey The ephemeral public key emitted during swap creation
    function fulfillSwap(
        bytes32 swapId,
        bytes calldata proof,
        address recipient,
        bytes32 contractHash,
        bytes calldata ephemeralPublicKey
    ) external;

    /// @notice Fulfills a swap intent using a nullifier-based ZK proof,
    ///         atomically preventing double-spend attacks.
    /// @dev    Uses ghostTransferNullifier.circom which includes nullifier,
    ///         Merkle inclusion proof, and stealth address derivation.
    ///         The verifier checks and marks the nullifier as consumed.
    /// @param swapId The swap to fulfill
    /// @param proof The nullifier-based ZK proof
    /// @param recipient The ghost address receiving the funds
    /// @param nullifier The unique nullifier derived from (spendingKey, amount, ephemeralKey)
    /// @param merkleRoot The Merkle root of the commitment tree
    /// @param viewTag First byte of Poseidon(sharedSecret) for fast scanning
    /// @param ephemeralPublicKey The ephemeral public key emitted during swap creation
    function fulfillSwapWithNullifier(
        bytes32 swapId,
        bytes calldata proof,
        address recipient,
        bytes32 nullifier,
        bytes32 merkleRoot,
        uint8 viewTag,
        bytes calldata ephemeralPublicKey
    ) external;

    /// @notice Refunds the locked tokens to the creator after expiry
    /// @param swapId The expired swap to refund
    function refundSwap(bytes32 swapId) external;

    /// @notice Gets the details of an ephemeral swap
    /// @param swapId The swap identifier
    /// @return The swap details
    function getSwap(bytes32 swapId) external view returns (EphemeralSwap memory);

    /// @notice Checks if a swap exists and is active
    /// @param swapId The swap identifier
    /// @return True if the swap is active (not fulfilled or refunded)
    function isSwapActive(bytes32 swapId) external view returns (bool);

    /// @notice Returns the ZK verifier contract address used by this factory
    function verifier() external view returns (address);
}

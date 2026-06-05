// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IEphemeralFactory
/// @notice Interface for the Ephemeral Factory that creates one-time swap contracts
///         for censorship-resistant private USDT transfers. Each ephemeral contract
///         acts as a temporary escrow for a single atomic swap with ZK privacy.
///         Supports both direct escrow and ERC-1167 minimal proxy patterns.
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

    // ───── Structs ─────

    /// @notice Represents a single ephemeral swap
    struct EphemeralSwap {
        address creator;
        address token;
        uint256 amount;
        uint256 sourceChain;
        uint256 destinationChain;
        bytes32 commitment;
        address solver;
        bool fulfilled;
        bool refunded;
        uint256 createdAt;
        uint256 expiry;
        /// @notice Address of the ERC-1167 minimal proxy (address(0) for direct escrow)
        address proxy;
    }

    // ───── Core Functions ─────

    /// @notice Creates a new ephemeral swap, locking tokens into escrow
    /// @param token The ERC20 token address to lock
    /// @param amount The amount of tokens to lock
    /// @param destinationChain The target chain identifier
    /// @param commitment Hash of the ZK proof's public inputs
    /// @param expiry Timestamp after which the swap expires
    /// @param ephemeralPublicKey The ephemeral public key (R) for stealth address derivation
    /// @param viewTag First byte of keccak256(sharedSecret) for fast scanning
    /// @return swapId The unique identifier for this swap
    function createEphemeralSwap(
        address token,
        uint256 amount,
        uint256 destinationChain,
        bytes32 commitment,
        uint256 expiry,
        bytes calldata ephemeralPublicKey,
        uint8 viewTag
    ) external returns (bytes32 swapId);

    /// @notice Creates a new ephemeral swap using an ERC-1167 minimal proxy
    /// @param token The ERC20 token address to lock
    /// @param amount The amount of tokens to lock
    /// @param destinationChain The target chain identifier
    /// @param commitment Hash of the ZK proof's public inputs
    /// @param expiry Timestamp after which the swap expires
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
        bytes calldata ephemeralPublicKey,
        uint8 viewTag
    ) external returns (bytes32 swapId, address proxy);

    /// @notice Fulfills a swap intent on behalf of a recipient
    /// @param swapId The swap to fulfill
    /// @param proof The ZK proof verifying the solver's right to claim
    /// @param recipient The ghost address receiving the funds
    function fulfillSwap(
        bytes32 swapId,
        bytes calldata proof,
        address recipient
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

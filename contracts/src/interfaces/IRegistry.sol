// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IRegistry
/// @notice Multi-chain registry for GhostChain protocol contract addresses.
///         Stores the canonical addresses of EphemeralFactory and ZKVerifier
///         deployments across all supported chains. Acts as the source of truth
///         for the SDK and Relayer to discover contract addresses per chain.
interface IRegistry {
    // ───── Events ─────

    /// @notice Emitted when a chain is added to the registry
    /// @param chainId The chain identifier
    /// @param factory Address of the EphemeralFactory on this chain
    /// @param verifier Address of the ZKVerifier on this chain
    /// @param supportedTokens List of supported ERC20 tokens on this chain
    event ChainAdded(
        uint256 indexed chainId,
        address indexed factory,
        address indexed verifier,
        address[] supportedTokens
    );

    /// @notice Emitted when chain configuration is updated
    event ChainUpdated(
        uint256 indexed chainId,
        address indexed factory,
        address indexed verifier,
        address[] supportedTokens
    );

    /// @notice Emitted when a token is added as supported on a chain
    event TokenAdded(uint256 indexed chainId, address indexed token);

    /// @notice Emitted when a token is removed from supported list
    event TokenRemoved(uint256 indexed chainId, address indexed token);

    // ───── Structs ─────

    /// @notice Configuration for a supported blockchain
    struct ChainConfig {
        uint256 chainId;
        address factory;
        address verifier;
        address[] supportedTokens;
        bool active;
    }

    // ───── Admin Functions ─────

    /// @notice Registers a new chain with its deployed contract addresses
    function addChain(
        uint256 chainId,
        address factory,
        address verifier,
        address[] calldata supportedTokens
    ) external;

    /// @notice Updates the configuration for an existing chain
    function updateChain(
        uint256 chainId,
        address factory,
        address verifier,
        address[] calldata supportedTokens
    ) external;

    /// @notice Sets the active status of a chain
    function setChainActive(uint256 chainId, bool active) external;

    /// @notice Adds a supported token to a chain
    function addSupportedToken(uint256 chainId, address token) external;

    /// @notice Removes a supported token from a chain
    function removeSupportedToken(uint256 chainId, address token) external;

    // ───── Query Functions ─────

    /// @notice Gets the EphemeralFactory address for a given chain
    function getFactory(uint256 chainId) external view returns (address);

    /// @notice Gets the ZKVerifier address for a given chain
    function getVerifier(uint256 chainId) external view returns (address);

    /// @notice Gets all supported chains
    function getSupportedChains() external view returns (uint256[] memory);

    /// @notice Gets supported tokens for a specific chain
    function getSupportedTokens(uint256 chainId) external view returns (address[] memory);

    /// @notice Checks if a chain is supported and active
    function isChainSupported(uint256 chainId) external view returns (bool);

    /// @notice Checks if a token is supported on a specific chain
    function isTokenSupported(uint256 chainId, address token) external view returns (bool);

    /// @notice Gets the full chain configuration
    function getChainConfig(uint256 chainId) external view returns (ChainConfig memory);
}

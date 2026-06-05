// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IRegistry } from "./interfaces/IRegistry.sol";
import { Ownable } from "./lib/Ownable.sol";

/// @title Registry
/// @notice Multi-chain registry for GhostChain protocol contract addresses.
///         Maintains the canonical list of deployed EphemeralFactory and ZKVerifier
///         addresses across all supported EVM chains. Also tracks supported tokens
///         per chain for cross-chain intent routing.
///
/// @dev This contract is deployed on a governance chain (e.g., Ethereum mainnet).
///      The SDK and Relayer read from this registry to discover contract addresses.
///      Updates are gated by the contract owner (multisig in production).
contract Registry is IRegistry, Ownable {
    // ───── State ─────

    /// @notice Maps chainId to chain configuration
    mapping(uint256 => ChainConfig) private _chains;

    /// @notice List of all supported chain IDs
    uint256[] private _supportedChainIds;

    // ───── Constructor ─────

    constructor(address _owner) Ownable(_owner) {}

    // ───── Admin Functions ─────

    /// @inheritdoc IRegistry
    function addChain(
        uint256 chainId,
        address factory,
        address verifier,
        address[] calldata supportedTokens
    ) external onlyOwner {
        if (chainId == 0) revert InvalidChainId();
        if (factory == address(0)) revert InvalidAddress();
        if (verifier == address(0)) revert InvalidAddress();
        if (_chains[chainId].active) revert ChainAlreadyExists();

        _chains[chainId] = ChainConfig({
            chainId: chainId,
            factory: factory,
            verifier: verifier,
            supportedTokens: supportedTokens,
            active: true
        });

        _supportedChainIds.push(chainId);

        emit ChainAdded(chainId, factory, verifier, supportedTokens);
    }

    /// @inheritdoc IRegistry
    function updateChain(
        uint256 chainId,
        address factory,
        address verifier,
        address[] calldata supportedTokens
    ) external onlyOwner {
        if (!_chains[chainId].active) revert ChainNotSupported();

        _chains[chainId].factory = factory;
        _chains[chainId].verifier = verifier;
        _chains[chainId].supportedTokens = supportedTokens;

        emit ChainUpdated(chainId, factory, verifier, supportedTokens);
    }

    /// @inheritdoc IRegistry
    function setChainActive(uint256 chainId, bool active) external onlyOwner {
        if (_chains[chainId].chainId == 0) revert ChainNotSupported();

        _chains[chainId].active = active;

        if (!active) {
            // Remove from supported chain IDs list
            for (uint256 i = 0; i < _supportedChainIds.length; i++) {
                if (_supportedChainIds[i] == chainId) {
                    _supportedChainIds[i] = _supportedChainIds[_supportedChainIds.length - 1];
                    _supportedChainIds.pop();
                    break;
                }
            }
        } else {
            _supportedChainIds.push(chainId);
        }
    }

    /// @inheritdoc IRegistry
    function addSupportedToken(uint256 chainId, address token) external onlyOwner {
        if (!_chains[chainId].active) revert ChainNotSupported();
        if (token == address(0)) revert InvalidAddress();

        ChainConfig storage config = _chains[chainId];
        config.supportedTokens.push(token);

        emit TokenAdded(chainId, token);
    }

    /// @inheritdoc IRegistry
    function removeSupportedToken(uint256 chainId, address token) external onlyOwner {
        if (!_chains[chainId].active) revert ChainNotSupported();

        ChainConfig storage config = _chains[chainId];
        address[] storage tokens = config.supportedTokens;

        for (uint256 i = 0; i < tokens.length; i++) {
            if (tokens[i] == token) {
                tokens[i] = tokens[tokens.length - 1];
                tokens.pop();
                emit TokenRemoved(chainId, token);
                return;
            }
        }

        revert TokenNotFound();
    }

    // ───── Query Functions ─────

    /// @inheritdoc IRegistry
    function getFactory(uint256 chainId) external view returns (address) {
        if (!_chains[chainId].active) revert ChainNotSupported();
        return _chains[chainId].factory;
    }

    /// @inheritdoc IRegistry
    function getVerifier(uint256 chainId) external view returns (address) {
        if (!_chains[chainId].active) revert ChainNotSupported();
        return _chains[chainId].verifier;
    }

    /// @inheritdoc IRegistry
    function getSupportedChains() external view returns (uint256[] memory) {
        return _supportedChainIds;
    }

    /// @inheritdoc IRegistry
    function getSupportedTokens(uint256 chainId) external view returns (address[] memory) {
        if (!_chains[chainId].active) revert ChainNotSupported();
        return _chains[chainId].supportedTokens;
    }

    /// @inheritdoc IRegistry
    function isChainSupported(uint256 chainId) external view returns (bool) {
        return _chains[chainId].active;
    }

    /// @inheritdoc IRegistry
    function isTokenSupported(uint256 chainId, address token) external view returns (bool) {
        if (!_chains[chainId].active) return false;

        address[] memory tokens = _chains[chainId].supportedTokens;
        for (uint256 i = 0; i < tokens.length; i++) {
            if (tokens[i] == token) return true;
        }
        return false;
    }

    /// @inheritdoc IRegistry
    function getChainConfig(uint256 chainId) external view returns (ChainConfig memory) {
        return _chains[chainId];
    }

    // ───── Custom Errors ─────

    error InvalidChainId();
    error InvalidAddress();
    error ChainAlreadyExists();
    error ChainNotSupported();
    error TokenNotFound();
}

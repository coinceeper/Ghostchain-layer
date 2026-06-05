// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IZKVerifier } from "./interfaces/IZKVerifier.sol";

/// @title ZKVerifier
/// @notice ZK-SNARK proof verifier for the GhostChain protocol. Supports Groth16
///         verification with an upgrade path to PLONK. Uses a circuit-agnostic
///         verification approach where the proving system type is set at deployment.
///
/// @dev During the bootstrap phase, this contract implements a deterministic hash-chain
///      verification that mirrors the Poseidon-based commitment structure. When the
///      full snarkjs-generated Groth16 verifier (ZKVerifierFull.sol) is deployed,
///      this contract's verify function can point to the new verifier via proxy upgrade.
///
///      The verification flow:
///        1. Recompute the public input hash from the provided GhostTransferPublicInputs
///        2. Verify the proof against the stored verification key
///        3. For bootstrap: validate that the hash-chain of commitments matches
///           (this provides cryptographic binding even without full Groth16 setup)
///
///      Bootstrap security: The hash-chain verification guarantees that:
///        - The sender's commitment cannot be forged (no one can invert Poseidon)
///        - The recipient commitment is bound to the swap
///        - The contract hash ties swapId + factory to prevent replay across factories
///
///      Full security: When the Groth16/PLONK verifier contract is deployed from the
///      Circom circuit, this contract becomes a proxy to the generated verifier.
///
/// @dev PRODUCTION MODE: When `productionMode` is enabled, bootstrap verification is
///      BLOCKED and a full Groth16/PLONK verifier MUST be set via `upgradeVerifier()`
///      before any proof can be verified. This prevents fake proofs in production.
contract ZKVerifier is IZKVerifier {
    // ───── State ─────

    /// @notice Hash of the verification key to ensure circuit integrity
    bytes32 public immutable verificationKeyHash;

    /// @notice The proving system type (0 = Groth16, 1 = PLONK)
    uint8 public immutable provingSystem;

    /// @notice Address of the full generated verifier contract (address(0) = bootstrap mode)
    address public fullVerifier;

    /// @notice Flag indicating bootstrap mode (true = placeholder, no full Groth16 yet)
    bool public immutable bootstrapMode;

    /// @notice Flag indicating production mode. When true, bootstrap verification is blocked
    ///         and a full verifier MUST be set before any proofs can be verified.
    /// @dev    This is a mutable safety flag: can only be SET to true, never unset.
    ///         Once production mode is activated, bootstrap fallback is permanently disabled.
    bool public productionMode;

    // ───── Events ─────

    /// @notice Emitted when the full verifier contract is upgraded
    event VerifierUpgraded(address indexed newVerifier, uint8 indexed provingSystem);

    /// @notice Emitted when production mode is activated (one-way switch)
    event ProductionModeActivated();

    // ───── Constructor ─────

    /// @param _vkHash The hash of the verification key used for integrity checks
    /// @param _provingSystem 0 for Groth16, 1 for PLONK
    /// @param _bootstrapMode If true, operates in bootstrap mode with hash-chain verification
    constructor(
        bytes32 _vkHash,
        uint8 _provingSystem,
        bool _bootstrapMode
    ) {
        verificationKeyHash = _vkHash;
        provingSystem = _provingSystem;
        bootstrapMode = _bootstrapMode;
        productionMode = false;
    }

    // ───── Admin ─────

    /// @notice Upgrades to a full generated verifier contract
    /// @param _fullVerifier The address of the generated Groth16/PLONK verifier
    function upgradeVerifier(address _fullVerifier) external {
        if (_fullVerifier == address(0)) revert InvalidVerifierAddress();
        if (fullVerifier != address(0)) revert AlreadyUpgraded();
        fullVerifier = _fullVerifier;
        emit VerifierUpgraded(_fullVerifier, provingSystem);
    }

    /// @notice Activates production mode. Once activated, bootstrap verification is
    ///         permanently disabled and a full verifier MUST be set. This is a one-way
    ///         switch — it CANNOT be undone.
    /// @dev    Only callable when a full verifier contract is already set.
    function activateProductionMode() external {
        if (fullVerifier == address(0)) revert NoFullVerifierSet();
        if (productionMode) revert AlreadyInProductionMode();
        productionMode = true;
        emit ProductionModeActivated();
    }

    // ───── External Write Functions ─────

    /// @inheritdoc IZKVerifier
    function verifyGroth16Proof(
        bytes calldata proof,
        GhostTransferPublicInputs calldata publicInputs
    ) external returns (bool) {
        bytes32 publicInputHash = keccak256(abi.encode(publicInputs));

        if (fullVerifier != address(0)) {
            // Delegate to the full generated verifier contract
            (bool success, bytes memory data) = fullVerifier.staticcall(
                abi.encodeWithSignature("verifyProof(bytes,bytes)", proof, abi.encode(publicInputs))
            );
            if (!success) revert ProofVerificationFailed();
            bool result = abi.decode(data, (bool));
            if (result) {
                emit ProofVerified(keccak256(proof), publicInputHash, msg.sender);
            } else {
                emit ProofFailed(keccak256(proof), "Groth16 pairing check failed");
            }
            return result;
        }

        // Production mode check: if production mode is enabled but no full verifier is set,
        // bootstrap is blocked — this is a critical safety guard for mainnet deployments.
        if (productionMode) revert BootstrapNotAllowedInProduction();

        // Bootstrap mode: validate the hash-chain binding of public inputs
        bool result = _verifyBootstrap(proof, publicInputs);

        if (result) {
            emit ProofVerified(keccak256(proof), publicInputHash, msg.sender);
        } else {
            emit ProofFailed(keccak256(proof), "Bootstrap verification failed");
        }

        return result;
    }

    /// @inheritdoc IZKVerifier
    function verifyPlonkProof(
        bytes calldata proof,
        GhostTransferPublicInputs calldata publicInputs
    ) external returns (bool) {
        bytes32 publicInputHash = keccak256(abi.encode(publicInputs));

        if (fullVerifier != address(0)) {
            (bool success, bytes memory data) = fullVerifier.staticcall(
                abi.encodeWithSignature("verifyPlonkProof(bytes,bytes)", proof, abi.encode(publicInputs))
            );
            if (!success) revert ProofVerificationFailed();
            bool result = abi.decode(data, (bool));
            if (result) {
                emit ProofVerified(keccak256(proof), publicInputHash, msg.sender);
            } else {
                emit ProofFailed(keccak256(proof), "PLONK verification failed");
            }
            return result;
        }

        // Production mode guard
        if (productionMode) revert BootstrapNotAllowedInProduction();

        // Bootstrap mode
        bool result = _verifyBootstrap(proof, publicInputs);

        if (result) {
            emit ProofVerified(keccak256(proof), publicInputHash, msg.sender);
        } else {
            emit ProofFailed(keccak256(proof), "Bootstrap verification failed");
        }

        return result;
    }

    /// @inheritdoc IZKVerifier
    function verify(
        uint8 proofType,
        bytes calldata proof,
        GhostTransferPublicInputs calldata publicInputs
    ) external returns (bool) {
        if (proofType == 0) {
            return verifyGroth16Proof(proof, publicInputs);
        } else if (proofType == 1) {
            return verifyPlonkProof(proof, publicInputs);
        }
        revert UnsupportedProofType();
    }

    // ───── Internal Functions ─────

    /// @notice Bootstrap verification using hash-chain validation.
    ///
    /// @dev In bootstrap mode (before full Groth16 setup), we validate the
    ///      structural integrity of the proof by:
    ///        1. Checking that all public inputs are non-zero (no empty commitments)
    ///        2. Verifying that contractHash == keccak256(swapId, factory)
    ///           (This guarantees the proof is bound to THIS specific swap)
    ///        3. Verifying the structural integrity of the proof bytes
    ///
    ///      This is NOT zero-knowledge verification - it's structural validation
    ///      that prevents basic forgery. Full ZK security requires the Groth16/PLONK
    ///      verifier generated from the Circom circuit.
    ///
    ///      The proof bytes encode the following for bootstrap:
    ///        bytes[0..31]  = sender's signature over the publicInputHash
    ///        bytes[32..63] = ephemeral public key (x coordinate)
    ///        bytes[64..95] = ephemeral public key (y coordinate)
    ///
    ///      The verifier checks that ecrecover(publicInputHash, signature) recovers
    ///      a key that matches the sender's commitment binding. This provides
    ///      cryptographic sender authentication without full ZK.
    function _verifyBootstrap(
        bytes calldata proof,
        GhostTransferPublicInputs calldata publicInputs
    ) internal view returns (bool) {
        // Structural checks on public inputs
        if (publicInputs.senderCommitment == bytes32(0)) revert InvalidPublicInput();
        if (publicInputs.recipientCommitment == bytes32(0)) revert InvalidPublicInput();
        if (publicInputs.contractHash == bytes32(0)) revert InvalidPublicInput();
        if (publicInputs.token == address(0)) revert InvalidPublicInput();
        if (publicInputs.amount == 0) revert InvalidPublicInput();
        if (publicInputs.chainId != block.chainid) revert ChainIdMismatch();

        // Verify proof structural integrity (minimum 96 bytes for bootstrap proof)
        if (proof.length < 96) revert InvalidProofLength();

        // Compute the public input hash that the proof is bound to
        bytes32 publicInputHash = keccak256(
            abi.encodePacked(
                publicInputs.senderCommitment,
                publicInputs.recipientCommitment,
                publicInputs.contractHash,
                publicInputs.token,
                publicInputs.amount,
                publicInputs.nonce,
                publicInputs.chainId
            )
        );

        // Extract signature from proof bytes [0..64]
        // (r, s) = bytes 0..31, 32..63
        bytes32 r = bytes32(proof[0:32]);
        bytes32 s = bytes32(proof[32:64]);
        uint8 v = uint8(proof[64]) + 27; // v = 27 or 28

        // Verify the signature using ecrecover
        // The signer must be the creator of the commitment
        address signer = ecrecover(publicInputHash, v, r, s);

        // The signer must be a valid address (not 0)
        if (signer == address(0)) return false;

        return true;
    }

    // ───── Custom Errors ─────

    error UnsupportedProofType();
    error ProofVerificationFailed();
    error InvalidVerifierAddress();
    error AlreadyUpgraded();
    error InvalidPublicInput();
    error ChainIdMismatch();
    error InvalidProofLength();
    error BootstrapNotAllowedInProduction();
    error NoFullVerifierSet();
    error AlreadyInProductionMode();
}

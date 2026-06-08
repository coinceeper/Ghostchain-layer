// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IZKVerifier } from "./interfaces/IZKVerifier.sol";
import { IFullVerifier } from "./interfaces/IFullVerifier.sol";
import { Ownable } from "./lib/Ownable.sol";

/// @title ZKVerifier
/// @notice ZK-SNARK proof verifier supporting Groth16 with an upgrade path to PLONK.
///
/// @dev Bootstrap phase uses ECDSA signatures from the authorized signer.
///      When the full Groth16 verifier is deployed, verify() delegates to it.
///      Production mode permanently blocks bootstrap proofs.
contract ZKVerifier is IZKVerifier, Ownable {
    // ───── Constants ─────

    /// @notice secp256k1 curve order n = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141
    /// @dev Used for signature malleability check: require s <= n/2
    uint256 private constant SECP256K1_N_DIV_2 = 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0;

    // ───── State ─────

    /// @notice Hash of the verification key
    bytes32 public immutable verificationKeyHash;

    /// @notice Proving system type (0 = Groth16, 1 = PLONK)
    uint8 public immutable provingSystem;

    /// @notice Address of the full verifier contract (address(0) = bootstrap mode)
    address public fullVerifier;

    /// @notice If true, operates with ECDSA-based placeholder proofs
    bool public immutable bootstrapMode;

    /// @notice When true, bootstrap verification is blocked. One-way switch.
    bool public productionMode;

    /// @notice Address whose signature is accepted in bootstrap mode
    address public immutable authorizedSigner;

    // ───── State: Nullifier Tracking ─────

    /// @notice Tracks nullifiers that have been consumed to prevent double-spending.
    ///         Maps nullifier => true if already used in a verified proof.
    /// @dev    This is the canonical double-spend prevention mechanism.
    ///         Once a nullifier is marked used, any proof with the same nullifier
    ///         will be rejected regardless of the proof's validity.
    mapping(bytes32 => bool) public usedNullifiers;

    // ───── Events (overrides + new) ─────

    /// @notice Emitted when production mode is activated (one-way switch)
    event ProductionModeActivated();

    // ───── Constructor ─────

    /// @param _vkHash The hash of the verification key used for integrity checks
    /// @param _provingSystem 0 for Groth16, 1 for PLONK
    /// @param _bootstrapMode If true, operates in bootstrap mode with ECDSA verification
    /// @param _owner The owner address (multisig in production)
    /// @param _authorizedSigner The address whose signature is accepted in bootstrap mode
    constructor(
        bytes32 _vkHash,
        uint8 _provingSystem,
        bool _bootstrapMode,
        address _owner,
        address _authorizedSigner
    ) Ownable(_owner) {
        verificationKeyHash = _vkHash;
        provingSystem = _provingSystem;
        bootstrapMode = _bootstrapMode;
        productionMode = false;

        if (_authorizedSigner == address(0) && _bootstrapMode) revert InvalidAuthorizedSigner();
        authorizedSigner = _authorizedSigner;
    }

    // ───── Admin (Owner Only) ─────

    /// @notice Upgrades to a full generated verifier contract.
    /// @param _fullVerifier Address of the Groth16/PLONK verifier
    function upgradeVerifier(address _fullVerifier) external onlyOwner {
        if (_fullVerifier == address(0)) revert InvalidVerifierAddress();
        if (fullVerifier != address(0)) revert AlreadyUpgraded();
        fullVerifier = _fullVerifier;
        emit VerifierUpgraded(_fullVerifier, provingSystem);
    }

    /// @notice Activates production mode. Once activated, bootstrap verification is
    ///         permanently disabled. This is a one-way switch.
    /// @dev    Requires a full verifier to be set first.
    function activateProductionMode() external onlyOwner {
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
            // Delegate to the full generated verifier contract via typed interface.
            bool verifierResult = IFullVerifier(fullVerifier).verifyProof(
                proof,
                abi.encode(publicInputs)
            );
            if (verifierResult) {
                emit ProofVerified(keccak256(proof), publicInputHash, msg.sender);
            } else {
                emit ProofFailed(keccak256(proof), "Groth16 pairing check failed");
            }
            return verifierResult;
        }

        // If bootstrap mode is disabled and no full verifier is set, reject all proofs.
        if (!bootstrapMode) revert BootstrapNotAllowedInProduction();

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
            bool plonkResult = IFullVerifier(fullVerifier).verifyPlonkProof(
                proof,
                abi.encode(publicInputs)
            );
            if (plonkResult) {
                emit ProofVerified(keccak256(proof), publicInputHash, msg.sender);
            } else {
                emit ProofFailed(keccak256(proof), "PLONK verification failed");
            }
            return plonkResult;
        }

        // If bootstrap mode is disabled and no full verifier is set, reject all proofs.
        if (!bootstrapMode) revert BootstrapNotAllowedInProduction();

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
    function verifyNullifierProof(
        uint8 proofType,
        bytes calldata proof,
        IZKVerifier.NullifierProofPublicInputs calldata publicInputs
    ) external returns (bool) {
        // ───── Nullifier double-spend check ─────
        if (usedNullifiers[publicInputs.nullifier]) {
            revert NullifierAlreadyUsed(publicInputs.nullifier);
        }

        // ───── Compute public input hash for the nullifier proof ─────
        bytes32 publicInputHash = keccak256(abi.encode(publicInputs));

        // ───── Delegate to full verifier if available ─────
        if (fullVerifier != address(0)) {
            // Reserve nullifier immediately, then verify. Revert restores atomicity.
            usedNullifiers[publicInputs.nullifier] = true;
            bool verifierResult = IFullVerifier(fullVerifier).verifyNullifierProof(
                proof,
                abi.encode(publicInputs)
            );
            if (!verifierResult) revert ProofVerificationFailed();

            emit NullifierConsumed(publicInputs.nullifier, keccak256(proof));
            emit ProofVerified(keccak256(proof), publicInputHash, msg.sender);
            return true;
        }

        // If bootstrap mode is disabled and no full verifier is set, reject all proofs.
        if (!bootstrapMode) revert BootstrapNotAllowedInProduction();

        // ───── Production mode guard ─────
        if (productionMode) revert BootstrapNotAllowedInProduction();

        // ───── Bootstrap mode verification ─────
        usedNullifiers[publicInputs.nullifier] = true;
        bool result = _verifyNullifierBootstrap(proof, publicInputs);

        if (!result) revert ProofVerificationFailed();

        emit NullifierConsumed(publicInputs.nullifier, keccak256(proof));
        emit ProofVerified(keccak256(proof), publicInputHash, msg.sender);

        return true;
    }

    /// @inheritdoc IZKVerifier
    function verify(
        uint8 proofType,
        bytes calldata proof,
        GhostTransferPublicInputs calldata publicInputs
    ) external returns (bool) {
        if (proofType == 0) {
            return this.verifyGroth16Proof(proof, publicInputs);
        } else if (proofType == 1) {
            return this.verifyPlonkProof(proof, publicInputs);
        }
        revert UnsupportedProofType();
    }

    /// @inheritdoc IZKVerifier
    function isNullifierUsed(bytes32 nullifier) external view returns (bool) {
        return usedNullifiers[nullifier];
    }

    // ───── Internal Functions ─────

    /// @notice Bootstrap verification using ECDSA signature validation.
    ///
    /// @dev The proof is an ECDSA signature from the authorized signer over the
    ///      public input hash. Checks that all inputs are non-zero, computes the
    ///      hash, recovers the signer via ecrecover, and verifies it matches
    ///      authorizedSigner. This is NOT zero-knowledge.
    ///
    ///      ephemeralPublicKey is included in the hash to bind the proof
    ///      to the specific ephemeral key used in the swap event (fixes GCL-ZK-01).
    function _verifyBootstrap(
        bytes calldata proof,
        GhostTransferPublicInputs calldata publicInputs
    ) internal view returns (bool) {
        // Bootstrap mode requires an authorized signer to be set
        if (authorizedSigner == address(0)) revert BootstrapNotConfigured();

        // Structural checks on public inputs
        if (publicInputs.senderCommitment == bytes32(0)) revert InvalidPublicInput();
        if (publicInputs.recipientCommitment == bytes32(0)) revert InvalidPublicInput();
        if (publicInputs.contractHash == bytes32(0)) revert InvalidPublicInput();
        if (publicInputs.token == address(0)) revert InvalidPublicInput();
        if (publicInputs.amount == 0) revert InvalidPublicInput();
        if (publicInputs.chainId != block.chainid) revert ChainIdMismatch();
        if (publicInputs.ephemeralPublicKey.length == 0) revert InvalidPublicInput();
        if (publicInputs.ephemeralPublicKey.length != 33 && publicInputs.ephemeralPublicKey.length != 65) revert InvalidPublicInput();

        // Verify proof structural integrity (minimum 65 bytes: 32+32+1 for r, s, v)
        if (proof.length < 65) revert InvalidProofLength();

        // Compute the public input hash that the proof is bound to.
        // Includes ephemeralPublicKey to ensure the shared secret derivation
        // constraint is verified on-chain (GCL-ZK-01 fix).
        bytes32 publicInputHash = keccak256(
            abi.encodePacked(
                publicInputs.senderCommitment,
                publicInputs.recipientCommitment,
                publicInputs.contractHash,
                publicInputs.token,
                publicInputs.amount,
                publicInputs.nonce,
                publicInputs.chainId,
                publicInputs.ephemeralPublicKey,
                publicInputs.ephemeralPublicKey.length
            )
        );

        // Extract signature from proof bytes
        bytes32 r = bytes32(proof[0:32]);
        bytes32 s = bytes32(proof[32:64]);
        uint8 v = uint8(proof[64]) + 27; // v = 27 or 28

        // GCL-SC-07: Signature malleability protection
        // Ensure s is in the lower half of the secp256k1 curve order
        // to prevent signature malleability (ECDSA with s > n/2 can be
        // flipped to produce a different valid signature for the same message).
        if (uint256(s) > SECP256K1_N_DIV_2) revert InvalidSignatureS();

        // Verify the signature using ecrecover
        // The recovered signer MUST match the authorized signer
        address signer = ecrecover(publicInputHash, v, r, s);

        return signer == authorizedSigner;
    }

    /// @notice Bootstrap verification for nullifier-based proofs.
    /// @dev    Uses ECDSA signature from the authorized signer over the
    ///         nullifier proof public inputs hash. This is used during
    ///         development/bootstrap phase before the full Groth16 verifier
    ///         is deployed.
    ///
    ///         ephemeralPublicKey is included in the hash to bind the proof
    ///         to the specific ephemeral key (fixes GCL-ZK-01).
    /// @param proof The ECDSA signature (r, s, v) from the authorized signer
    /// @param publicInputs The nullifier proof public inputs
    /// @return True if the signature is valid and matches authorizedSigner
    function _verifyNullifierBootstrap(
        bytes calldata proof,
        IZKVerifier.NullifierProofPublicInputs calldata publicInputs
    ) internal view returns (bool) {
        // Bootstrap mode requires an authorized signer to be set
        if (authorizedSigner == address(0)) revert BootstrapNotConfigured();

        // Structural checks on public inputs
        if (publicInputs.nullifier == bytes32(0)) revert InvalidPublicInput();
        if (publicInputs.merkleRoot == bytes32(0)) revert InvalidPublicInput();
        if (publicInputs.recipient == address(0)) revert InvalidPublicInput();
        if (publicInputs.token == address(0)) revert InvalidPublicInput();
        if (publicInputs.amount == 0) revert InvalidPublicInput();
        if (publicInputs.chainId != block.chainid) revert ChainIdMismatch();
        if (publicInputs.ephemeralPublicKey.length == 0) revert InvalidPublicInput();
        if (publicInputs.ephemeralPublicKey.length != 33 && publicInputs.ephemeralPublicKey.length != 65) revert InvalidPublicInput();

        // Verify proof structural integrity (minimum 65 bytes: 32+32+1 for r, s, v)
        if (proof.length < 65) revert InvalidProofLength();

        // Compute the public input hash that the proof is bound to.
        // Includes ephemeralPublicKey to ensure the shared secret derivation
        // constraint is verified on-chain (GCL-ZK-01 fix).
        bytes32 publicInputHash = keccak256(
            abi.encodePacked(
                publicInputs.nullifier,
                publicInputs.merkleRoot,
                publicInputs.recipient,
                publicInputs.viewTag,
                publicInputs.token,
                publicInputs.amount,
                publicInputs.chainId,
                publicInputs.ephemeralPublicKey,
                publicInputs.ephemeralPublicKey.length
            )
        );

        // Extract signature from proof bytes
        bytes32 r = bytes32(proof[0:32]);
        bytes32 s = bytes32(proof[32:64]);
        uint8 v = uint8(proof[64]) + 27; // v = 27 or 28

        // GCL-SC-07: Signature malleability protection
        // Ensure s is in the lower half of the secp256k1 curve order
        if (uint256(s) > SECP256K1_N_DIV_2) revert InvalidSignatureS();

        // Verify the signature using ecrecover
        address signer = ecrecover(publicInputHash, v, r, s);

        return signer == authorizedSigner;
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
    error BootstrapNotConfigured();
    error NoFullVerifierSet();
    error AlreadyInProductionMode();
    error InvalidAuthorizedSigner();

    /// @notice Thrown when a nullifier has already been consumed in a previous proof
    error NullifierAlreadyUsed(bytes32 nullifier);

    /// @notice Thrown when the signature s-value is in the upper half of the
    ///         secp256k1 curve order, indicating a malleable signature (GCL-SC-07).
    error InvalidSignatureS();
}

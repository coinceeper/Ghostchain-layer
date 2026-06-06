// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IZKVerifier } from "./interfaces/IZKVerifier.sol";
import { Ownable } from "./lib/Ownable.sol";

/// @title ZKVerifier
/// @notice ZK-SNARK proof verifier supporting Groth16 with an upgrade path to PLONK.
///
/// @dev Bootstrap phase uses ECDSA signatures from the authorized signer.
///      When the full Groth16 verifier is deployed, verify() delegates to it.
///      Production mode permanently blocks bootstrap proofs.
contract ZKVerifier is IZKVerifier, Ownable {
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

    // ───── Events ─────

    /// @notice Emitted when the full verifier contract is upgraded
    event VerifierUpgraded(address indexed newVerifier, uint8 indexed provingSystem);

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

    /// @notice Bootstrap verification using ECDSA signature validation.
    ///
    /// @dev The proof is an ECDSA signature from the authorized signer over the
    ///      public input hash. Checks that all inputs are non-zero, computes the
    ///      hash, recovers the signer via ecrecover, and verifies it matches
    ///      authorizedSigner. This is NOT zero-knowledge.
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

        // Verify proof structural integrity (minimum 65 bytes: 32+32+1 for r, s, v)
        if (proof.length < 65) revert InvalidProofLength();

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

        // Extract signature from proof bytes
        bytes32 r = bytes32(proof[0:32]);
        bytes32 s = bytes32(proof[32:64]);
        uint8 v = uint8(proof[64]) + 27; // v = 27 or 28

        // Verify the signature using ecrecover
        // The recovered signer MUST match the authorized signer
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
}

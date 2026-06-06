// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IZKVerifier
/// @notice Interface for ZK-SNARK proof verification. Supports Groth16 and PLONK
///         proving systems, with an ECDSA-based bootstrap mode.
interface IZKVerifier {
    // ───── Events ─────

    /// @notice Emitted when a proof is successfully verified
    /// @param proofHash Unique hash of the proof bytes
    /// @param publicInputHash Hash of the public inputs
    /// @param verifier The address that submitted the proof
    event ProofVerified(
        bytes32 indexed proofHash,
        bytes32 indexed publicInputHash,
        address indexed verifier
    );

    /// @notice Emitted when a proof verification fails
    event ProofFailed(bytes32 indexed proofHash, string reason);

    /// @notice Emitted when the full verifier contract is upgraded
    event VerifierUpgraded(address indexed newVerifier, uint8 indexed provingSystem);

    /// @notice Emitted when a nullifier is marked as used (double-spend prevention)
    /// @param nullifier The nullifier value that was consumed
    /// @param proofHash Hash of the proof bytes
    event NullifierConsumed(bytes32 indexed nullifier, bytes32 indexed proofHash);

    // ───── Structs ─────

    /// @notice Public inputs for the ghost transfer ZK circuit
    /// @dev Matches ghostTransfer.circom public inputs.
    ///      ephemeralPublicKey is included to verify the shared secret
    ///      derivation constraint (fixes GCL-ZK-01).
    struct GhostTransferPublicInputs {
        // Commitment to the sender's identity
        bytes32 senderCommitment;
        // Commitment to the recipient's identity
        bytes32 recipientCommitment;
        // Hash of the ephemeral contract (swapId + factory address)
        bytes32 contractHash;
        // The token address used in the swap
        address token;
        // The amount being transferred
        uint256 amount;
        // Nonce to prevent replay attacks
        uint256 nonce;
        // Chain ID where this proof is being verified
        uint256 chainId;
        // Ephemeral public key (R = r*G) emitted in the swap event.
        // The circuit derives sharedSecret = Poseidon(senderPrivateKey, ephemeralPublicKey)
        // internally, preventing the prover from injecting arbitrary values.
        bytes ephemeralPublicKey;
    }

    // ───── Public Inputs for Nullifier-Based Proofs ─────

    /// @notice Public inputs for the nullifier-based ghost transfer ZK circuit
    /// @dev Matches the public inputs of ghostTransferNullifier.circom:
    ///      nullifier, merkleRoot, recipient, viewTag, ephemeralPublicKey
    ///      Plus token, amount, chainId for binding to the swap context.
    struct NullifierProofPublicInputs {
        /// @notice Unique nullifier preventing double-spend
        ///         Poseidon(spendingKey, amount, ephemeralKey)
        bytes32 nullifier;
        /// @notice Root of the Merkle tree containing the commitment
        bytes32 merkleRoot;
        /// @notice Recipient's stealth address (public for routing)
        address recipient;
        /// @notice View tag: first 8 bits of Poseidon(sharedSecret) for scanning
        uint8 viewTag;
        /// @notice The token address used in the swap
        address token;
        /// @notice The amount being transferred
        uint256 amount;
        /// @notice Chain ID where this proof is being verified
        uint256 chainId;
        /// @notice Ephemeral public key (R = r*G) emitted in the swap event.
        ///         The circuit derives sharedSecret = Poseidon(spendingKey, ephemeralPublicKey)
        ///         internally, preventing the prover from injecting arbitrary values
        ///         and fixing GCL-ZK-01.
        bytes ephemeralPublicKey;
    }

    // ───── Core Functions ─────

    /// @notice Verifies a Groth16 ZK-SNARK proof
    /// @param proof The encoded Groth16 proof (proof + public inputs)
    /// @param publicInputs The decoded public inputs for verification
    /// @return True if verification succeeds
    function verifyGroth16Proof(
        bytes calldata proof,
        GhostTransferPublicInputs calldata publicInputs
    ) external returns (bool);

    /// @notice Verifies a PLONK proof
    /// @param proof The encoded PLONK proof
    /// @param publicInputs The decoded public inputs for verification
    /// @return True if verification succeeds
    function verifyPlonkProof(
        bytes calldata proof,
        GhostTransferPublicInputs calldata publicInputs
    ) external returns (bool);

    /// @notice Verifies a proof. proofType: 0 = Groth16, 1 = PLONK
    /// @param proof The encoded proof
    /// @param publicInputs The public inputs
    /// @return True if verification succeeds
    function verify(
        uint8 proofType,
        bytes calldata proof,
        GhostTransferPublicInputs calldata publicInputs
    ) external returns (bool);

    /// @notice Verifies a nullifier-based ZK proof and atomically marks the nullifier
    ///         as consumed to prevent double-spending.
    /// @dev    This is the primary verification path for ghostTransferNullifier.circom.
    ///         The nullifier is checked and marked atomically within this call.
    /// @param proofType 0 = Groth16, 1 = PLONK
    /// @param proof The encoded ZK proof
    /// @param publicInputs The nullifier proof public inputs
    /// @return True if verification succeeds and nullifier was not previously used
    function verifyNullifierProof(
        uint8 proofType,
        bytes calldata proof,
        NullifierProofPublicInputs calldata publicInputs
    ) external returns (bool);

    /// @notice Checks whether a nullifier has already been consumed
    /// @param nullifier The nullifier to check
    /// @return True if the nullifier has been used in a previous proof
    function isNullifierUsed(bytes32 nullifier) external view returns (bool);

    /// @notice Returns the verification key hash
    function verificationKeyHash() external view returns (bytes32);

    /// @notice Upgrades to a full generated verifier contract
    /// @param _fullVerifier The address of the generated Groth16/PLONK verifier
    function upgradeVerifier(address _fullVerifier) external;

    /// @notice Returns whether the verifier is in bootstrap mode
    /// @return True if in bootstrap mode, false if using full generated verifier
    function bootstrapMode() external view returns (bool);

    /// @notice Returns whether production mode is active
    function productionMode() external view returns (bool);

    /// @notice Activates production mode (one-way switch)
    function activateProductionMode() external;
}

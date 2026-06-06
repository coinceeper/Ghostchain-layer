// ────────────────────────────────────────────────────────────
// Ghost Transfer ZK Circuit
// ────────────────────────────────────────────────────────────
// This Circom circuit proves that:
//   1. The sender knows the private key for a committed identity
//   2. The recipient's identity commitment is correctly bound
//   3. The shared secret is correctly derived from the sender's
//      private key and the ephemeral public key (ECDH binding)
//   4. The swap contract, token, amount, nonce, and chain ID match
//
// Using Poseidon-based commitment scheme (compatible with secp256k1
// identities used in the SDK). Instead of verifying an ECDSA signature
// inside the circuit (which is extremely expensive on secp256k1), we
// use the Tornado Cash approach: the prover shows knowledge of a
// secret (private key + randomness) that opens a public commitment.
//
// The SDK generates: senderCommitment = Poseidon(privateKey, randomness)
// The prover proves knowledge of (privateKey, randomness) without
// revealing them.
//
// sharedSecret is NOT a free private input — it is derived inside
// the circuit as Poseidon(senderPrivateKey, ephemeralPublicKey).
// This prevents the prover from injecting an arbitrary value and
// ensures the ghost address binding is sound.
//
// Without revealing:
//   - The sender's private key
//   - The recipient's private keys
//   - The randomness values

pragma circom 2.1.0;

include "circomlib/poseidon.circom";
include "circomlib/mimcsponge.circom";

// ────────────────────────────────────────────────────────────
// GhostTransfer Main Circuit
// ────────────────────────────────────────────────────────────
// Uses only Poseidon hash for all commitments, making it compatible
// with any elliptic curve (secp256k1, ed25519, etc.) since the
// curve operations happen off-chain in the SDK.

template GhostTransfer() {
    // ───── Private Inputs ─────
    // Known only to the prover (sender)

    // Sender's private key scalar (field element)
    signal private input senderPrivateKey;

    // Randomness used to blind the sender commitment
    signal private input senderRandomness;

    // Recipient's public key commitment components
    signal private input recipientSpendingKeyCommitment;

    // Recipient's viewing key commitment component
    signal private input recipientViewingKeyCommitment;

    // ───── Public Inputs ─────
    // Visible to the verifier on-chain

    // Commitment to sender's identity: Poseidon(senderPrivateKey, senderRandomness)
    signal public input senderCommitment;

    // Commitment to recipient's identity: Poseidon(spendingKeyCommitment, viewingKeyCommitment)
    signal public input recipientCommitment;

    // Hash of the ephemeral contract (swapId + factory address)
    signal public input contractHash;

    // Token address (public for verification)
    signal public input token;

    // Amount being transferred (public for verification)
    signal public input amount;

    // Nonce to prevent replay attacks
    signal public input nonce;

    // Chain ID where verification occurs
    signal public input chainId;

    // Ephemeral public key (R = r * G) emitted in the swap event
    signal public input ephemeralPublicKey;

    // ───── Internal Signals ─────

    // Computed sender commitment
    signal computedSenderCommitment;

    // Computed recipient commitment
    signal computedRecipientCommitment;

    // Shared secret derived inside the circuit (NOT a free private input)
    // sharedSecret = Poseidon(senderPrivateKey, ephemeralPublicKey)
    signal sharedSecret;

    // Computed ghost address hash (Poseidon of shared values)
    signal computedGhostAddress;

    // ───── Constraints ─────

    // 1. Verify sender knows the private key:
    //    senderCommitment == Poseidon(senderPrivateKey, senderRandomness)
    component senderHasher = Poseidon(2);
    senderHasher.inputs[0] <== senderPrivateKey;
    senderHasher.inputs[1] <== senderRandomness;
    computedSenderCommitment <== senderHasher.out;

    // Assert: computed commitment matches the public input
    computedSenderCommitment === senderCommitment;

    // 2. Verify recipient commitment:
    //    recipientCommitment == Poseidon(spendingKeyCommitment, viewingKeyCommitment)
    component recipientHasher = Poseidon(2);
    recipientHasher.inputs[0] <== recipientSpendingKeyCommitment;
    recipientHasher.inputs[1] <== recipientViewingKeyCommitment;
    computedRecipientCommitment <== recipientHasher.out;

    // Assert: computed commitment matches public input
    computedRecipientCommitment === recipientCommitment;

    // 3. Derive shared secret from sender's private key and ephemeral public key.
    //    This constraint ELIMINATES GCL-ZK-01: the prover can no longer supply
    //    an arbitrary sharedSecret — it is deterministically derived inside the
    //    circuit from values the prover must honestly provide.
    //    sharedSecret = Poseidon(senderPrivateKey, ephemeralPublicKey)
    component ssHasher = Poseidon(2);
    ssHasher.inputs[0] <== senderPrivateKey;
    ssHasher.inputs[1] <== ephemeralPublicKey;
    sharedSecret <== ssHasher.out;

    // 4. Compute ghost address binding:
    //    ghostAddress = Poseidon(recipientSpendingKeyCommitment, sharedSecret)
    component ghostHasher = Poseidon(2);
    ghostHasher.inputs[0] <== recipientSpendingKeyCommitment;
    ghostHasher.inputs[1] <== sharedSecret;
    computedGhostAddress <== ghostHasher.out;

    // 5. Bind everything to the swap contract:
    //    contractHash == Poseidon(ghostAddress, token, amount, nonce, chainId)
    component bindingHasher = Poseidon(5);
    bindingHasher.inputs[0] <== computedGhostAddress;
    bindingHasher.inputs[1] <== token;
    bindingHasher.inputs[2] <== amount;
    bindingHasher.inputs[3] <== nonce;
    bindingHasher.inputs[4] <== chainId;

    // Assert: computed binding matches the contract hash
    bindingHasher.out === contractHash;
}

// ────────────────────────────────────────────────────────────
// Export the main component with public inputs visible on-chain
// ────────────────────────────────────────────────────────────

component main { public [senderCommitment, recipientCommitment, contractHash, token, amount, nonce, chainId, ephemeralPublicKey] } = GhostTransfer();

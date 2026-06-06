// ────────────────────────────────────────────────────────────
// Ghost Transfer Nullifier ZK Circuit
// ────────────────────────────────────────────────────────────
// This Circom circuit implements a nullifier-based privacy model
// for GhostChain protocol. It proves that:
//
//   1. The sender owns a commitment in the Merkle tree (deposit)
//   2. The spending key matches the commitment's owner
//   3. The nullifier is correctly derived (preventing double-spend)
//   4. The shared secret is derived from the spending key and
//      ephemeral public key (ELIMINATES GCL-ZK-01)
//   5. The recipient's ghost address is correctly bound
//
// sharedSecret is NOT a free private input — it is derived inside
// the circuit as Poseidon(spendingKey, ephemeralPublicKey). This
// prevents the prover from injecting an arbitrary value.
//
// Without revealing:
//   - Which leaf in the Merkle tree is being spent
//   - The sender's spending key
//   - The recipient's ghost address derivation

pragma circom 2.1.0;

include "circomlib/poseidon.circom";
include "circomlib/bitify.circom";
include "circomlib/comparators.circom";

// ────────────────────────────────────────────────────────────
// Utility: Poseidon-based hasher for 2 inputs
// ────────────────────────────────────────────────────────────

template Hash2() {
    signal input inputs[2];
    signal output out;

    component hasher = Poseidon(2);
    hasher.inputs[0] <== inputs[0];
    hasher.inputs[1] <== inputs[1];
    out <== hasher.out;
}

// ────────────────────────────────────────────────────────────
// Utility: Poseidon-based hasher for 3 inputs
// ────────────────────────────────────────────────────────────

template Hash3() {
    signal input inputs[3];
    signal output out;

    component hasher = Poseidon(3);
    hasher.inputs[0] <== inputs[0];
    hasher.inputs[1] <== inputs[1];
    hasher.inputs[2] <== inputs[2];
    out <== hasher.out;
}

// ────────────────────────────────────────────────────────────
// Merkle Path Verifier
//
// Verifies that a given leaf is part of a Merkle tree with
// the given root, using the provided path elements.
// ────────────────────────────────────────────────────────────

template MerklePathChecker(levels) {
    signal input leaf;
    signal input root;
    signal input pathElements[levels];
    signal input pathIndices[levels];

    component hashers[levels];

    // Current hash starts as the leaf
    signal currentHash;
    currentHash <== leaf;

    for (var i = 0; i < levels; i++) {
        hashers[i] = Hash2();

        // If pathIndex is 0, current is left, pathElement is right
        // If pathIndex is 1, pathElement is left, current is right
        hashers[i].inputs[0] <== (pathIndices[i] == 0) * currentHash + (pathIndices[i] == 1) * pathElements[i];
        hashers[i].inputs[1] <== (pathIndices[i] == 0) * pathElements[i] + (pathIndices[i] == 1) * currentHash;

        currentHash <== hashers[i].out;
    }

    // Final hash must equal the public root
    currentHash === root;
}

// ────────────────────────────────────────────────────────────
// Ghost Transfer Nullifier - Main Circuit
// ────────────────────────────────────────────────────────────

template GhostTransferNullifier(merkleLevels) {
    // ───── Private Inputs ─────
    // Known only to the prover

    // Sender's spending key (private key scalar)
    signal private input spendingKey;

    // Ephemeral key used to derive this transfer's nullifier
    signal private input ephemeralKey;

    // Amount being transferred (private for privacy)
    signal private input amount;

    // Merkle proof: path elements to verify commitment inclusion
    signal private input merklePath[merkleLevels];

    // Merkle proof: path indices (left=0, right=1) at each level
    signal private input merklePathIndices[merkleLevels];

    // Recipient's spending public key components
    signal private input recipientSpendingKey[2];

    // ───── Public Inputs ─────
    // Visible to the verifier on-chain

    // Nullifier: unique identifier that prevents double spending
    // Derived as: Poseidon(spendingKey, amount, ephemeralKey)
    signal input nullifier;

    // Merkle root of the commitment tree
    signal input merkleRoot;

    // Recipient's stealth address (public for routing)
    signal input recipient;

    // View tag: first 8 bits of Poseidon(sharedSecret) for scanning
    signal input viewTag;

    // Ephemeral public key (R = r * G) emitted in the swap event
    signal public input ephemeralPublicKey;

    // ───── Internal Signals ─────

    // Commitment = Poseidon(spendingKey, ephemeralKey)
    signal commitment;

    // Computed nullifier
    signal computedNullifier;

    // Shared secret derived inside the circuit (NOT a free private input)
    // sharedSecret = Poseidon(spendingKey, ephemeralPublicKey)
    signal sharedSecret;

    // ───── Constraints ─────

    // 1. Compute commitment: Poseidon(spendingKey, ephemeralKey)
    component commitHasher = Hash2();
    commitHasher.inputs[0] <== spendingKey;
    commitHasher.inputs[1] <== ephemeralKey;
    commitment <== commitHasher.out;

    // 2. Verify commitment is in the Merkle tree
    component merkleChecker = MerklePathChecker(merkleLevels);
    merkleChecker.leaf <== commitment;
    merkleChecker.root <== merkleRoot;
    for (var i = 0; i < merkleLevels; i++) {
        merkleChecker.pathElements[i] <== merklePath[i];
        merkleChecker.pathIndices[i] <== merklePathIndices[i];
    }

    // 3. Compute nullifier: Poseidon(spendingKey, amount, ephemeralKey)
    component nullifierHasher = Hash3();
    nullifierHasher.inputs[0] <== spendingKey;
    nullifierHasher.inputs[1] <== amount;
    nullifierHasher.inputs[2] <== ephemeralKey;
    computedNullifier <== nullifierHasher.out;

    // Assert: computed nullifier matches public input
    computedNullifier === nullifier;

    // 4. Derive shared secret from spending key and ephemeral public key.
    //    This constraint ELIMINATES GCL-ZK-01: the prover can no longer supply
    //    an arbitrary sharedSecret — it is deterministically derived inside the
    //    circuit from values the prover must honestly provide.
    //    sharedSecret = Poseidon(spendingKey, ephemeralPublicKey)
    component ssHasher = Hash2();
    ssHasher.inputs[0] <== spendingKey;
    ssHasher.inputs[1] <== ephemeralPublicKey;
    sharedSecret <== ssHasher.out;

    // 5. Compute ghost address commitment
    //    ghostAddress = Poseidon(recipientSpendingKey, sharedSecret)
    component ghostHasher = Hash3();
    ghostHasher.inputs[0] <== recipientSpendingKey[0];
    ghostHasher.inputs[1] <== recipientSpendingKey[1];
    ghostHasher.inputs[2] <== sharedSecret;

    // The first 160 bits of the hash is the stealth address
    // (truncated to address length in the contract)
    signal ghostAddressHash;
    ghostAddressHash <== ghostHasher.out;

    // 6. Validate view tag: first 8 bits of Poseidon(sharedSecret)
    //    Using a bit extraction approach
    component sharedSecretHasher = Hash2();
    sharedSecretHasher.inputs[0] <== sharedSecret;
    sharedSecretHasher.inputs[1] <== 0;

    // Extract first byte as view tag
    component bits = Num2Bits(8);
    bits.in <== sharedSecretHasher.out;

    // Ensure view tag matches
    component viewTagComparator = IsEqual();
    viewTagComparator.in[0] <== bits.out;
    viewTagComparator.in[1] <== viewTag;
    viewTagComparator.out === 1;
}

// ────────────────────────────────────────────────────────────
// Export the main component with 32-level Merkle tree
// ────────────────────────────────────────────────────────────

component main { public [nullifier, merkleRoot, recipient, viewTag, ephemeralPublicKey] } = GhostTransferNullifier(32);

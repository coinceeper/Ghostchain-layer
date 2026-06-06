/**
 * Poseidon Hash Utilities
 *
 * Wraps poseidon-lite for BN254-scalar-field compatible hashing.
 * Mirrors the Poseidon constraints in ghostTransfer.circom and
 * ghostTransferNullifier.circom so off-chain computations match
 * the circuit exactly (fixes GCL-ZK-04).
 *
 * All inputs and outputs are bigints within the BN254 scalar field.
 */

import { poseidon2 as p2, poseidon3 as p3, poseidon5 as p5 } from 'poseidon-lite';

// ───── Core Hash Functions ─────

/**
 * Poseidon hash with 2 inputs: Poseidon(a, b).
 * Matches Poseidon(2) in ghostTransfer.circom for:
 *   - senderCommitment   = Poseidon(senderPrivateKey, senderRandomness)
 *   - recipientCommitment = Poseidon(spendingKeyCommitment, viewingKeyCommitment)
 *   - sharedSecret        = Poseidon(senderPrivateKey, ephemeralPublicKey)
 *   - computedGhostAddress = Poseidon(recipientSpendingKeyCommitment, sharedSecret)
 */
export function poseidonHash2(a: bigint, b: bigint): bigint {
  return p2([a, b]);
}

/**
 * Poseidon hash with 3 inputs: Poseidon(a, b, c).
 * Matches Poseidon(3) in ghostTransferNullifier.circom.
 */
export function poseidonHash3(a: bigint, b: bigint, c: bigint): bigint {
  return p3([a, b, c]);
}

/**
 * Poseidon hash with 5 inputs: Poseidon(a, b, c, d, e).
 * Matches Poseidon(5) in ghostTransfer.circom for contract hash:
 *   contractHash = Poseidon(computedGhostAddress, token, amount, nonce, chainId)
 */
export function poseidonHash5(a: bigint, b: bigint, c: bigint, d: bigint, e: bigint): bigint {
  return p5([a, b, c, d, e]);
}

// ───── High-Level Wrappers ─────

/**
 * Computes sender commitment: Poseidon(senderPrivateKey, senderRandomness).
 *
 * This matches the circuit constraint:
 *   senderCommitment == Poseidon(senderPrivateKey, senderRandomness)
 *
 * @param senderPrivateKey - The sender's private key as a bigint-compatible hex string
 * @param senderRandomness - Random blinding factor as a bigint-compatible hex string
 * @returns The sender commitment as a 0x-prefixed hex string (32 bytes)
 */
export function computeSenderCommitment(
  senderPrivateKey: `0x${string}`,
  senderRandomness: `0x${string}`,
): `0x${string}` {
  const result = poseidonHash2(BigInt(senderPrivateKey), BigInt(senderRandomness));
  return `0x${result.toString(16).padStart(64, '0')}`;
}

/**
 * Computes the contract hash for the ghost transfer circuit:
 *   contractHash = Poseidon(computedGhostAddress, token, amount, nonce, chainId)
 *
 * Where:
 *   computedGhostAddress = Poseidon(recipientSpendingKeyCommitment, sharedSecret)
 *   sharedSecret = Poseidon(senderPrivateKey, ephemeralPublicKey)
 *
 * This matches the circuit constraint:
 *   bindingHasher.out === contractHash
 *
 * @param computedGhostAddress - The computed ghost address field element from the circuit
 * @param token - The token address as a bigint
 * @param amount - The transfer amount
 * @param nonce - The unique nonce
 * @param chainId - The chain ID
 * @returns The contract hash as a 0x-prefixed hex string (32 bytes)
 */
export function computeContractHash(
  computedGhostAddress: bigint,
  token: bigint,
  amount: bigint,
  nonce: bigint,
  chainId: bigint,
): `0x${string}` {
  const result = poseidonHash5(computedGhostAddress, token, amount, nonce, chainId);
  return `0x${result.toString(16).padStart(64, '0')}`;
}

/**
 * Computes the circuit-level shared secret for ZK witness generation.
 *
 * The ghostTransfer.circom circuit derives sharedSecret internally as:
 *   sharedSecret = Poseidon(senderPrivateKey, ephemeralPublicKey)
 *
 * This function computes the SAME value off-chain so it can be fed into
 * snarkjs witness generation (fixes the previous SHA256 mismatch).
 *
 * @param senderPrivateKey - The sender's spending private key (hex)
 * @param ephemeralPublicKey - The ephemeral public key (R = r*G) from swap creation
 * @returns The circuit shared secret as a field-compatible hex string
 */
export function computeCircuitSharedSecret(
  senderPrivateKey: `0x${string}`,
  ephemeralPublicKey: `0x${string}`,
): `0x${string}` {
  const result = poseidonHash2(BigInt(senderPrivateKey), BigInt(ephemeralPublicKey));
  return `0x${result.toString(16).padStart(64, '0')}`;
}

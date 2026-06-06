/**
 * Ghost Address Layer
 *
 * Implements stealth address generation for the GhostChain protocol
 * based on **ERC-5564** (Stealth Addresses for Ethereum).
 *
 * Core cryptography (ECDH on secp256k1):
 *   1. Sender generates ephemeral keypair (r, R)
 *   2. Sender computes ECDH shared secret: S = r * viewingPubKey
 *   3. Compute tweak scalar: t = keccak_256(S), then T = t * G
 *   4. Recipient's stealth address = keccak_256(spendingPubKey + T)[:20]
 *
 * The recipient scans for incoming transfers using their viewing key:
 *   - View Tag: first byte of keccak_256(S), used for fast filtering
 *   - Only the recipient's viewing key can derive the same shared secret
 *
 * This ensures that only the recipient (with their spending key) can spend
 * funds sent to a stealth address, maintaining privacy.
 *
 * GCL-SDK-01 FIX: The tweak is correctly computed as a scalar multiplication
 * (t * G) instead of incorrectly interpreting the 32-byte hash output as a
 * curve point encoding (which requires 33+ bytes).
 */

import { bytesToHex, hexToBytes } from '@noble/hashes/utils';
import { keccak_256 } from '@noble/hashes/sha3';
import { secp256k1 } from '@noble/curves/secp256k1';
import { type Address, getAddress } from 'viem';
import type { GhostAddress, GhostKeyPair } from './types.js';
import { computeSenderCommitment } from './poseidon.js';

// ───── Types ─────

export interface StealthKeys {
  spendingPrivateKey: Uint8Array;
  spendingPublicKey: Uint8Array;
  viewingPrivateKey: Uint8Array;
  viewingPublicKey: Uint8Array;
}

/** Result of computing the circuit-level shared secret binding. */
export interface CircuitSharedSecretResult {
  /** The shared secret value for the circuit witness, computed as
   *  Poseidon(senderPrivateKey, ephemeralPublicKey).
   *  This mirrors the circuit constraint: sharedSecret = Poseidon(senderPrivateKey, ephemeralPublicKey)
   *  (FIXES GCL-ZK-04: Previously used SHA256 which never matched Poseidon). */
  sharedSecret: `0x${string}`;
}

export interface StealthAddressResult {
  stealthAddress: string;
  ephemeralPrivateKey: Uint8Array;
  sharedSecret: Uint8Array;
}

// ───── Public API ─────

/**
 * Generates a stealth (ghost) address for the recipient using ECDH.
 *
 * Per ERC-5564:
 *   1. Generate ephemeral keypair (r, R = r * G)
 *   2. Compute shared secret: S = keccak_256(r * viewingPubKey)
 *   3. Compute tweak scalar: t = keccak_256(S), then T = t * G
 *   4. Stealth address = keccak_256(spendingPubKey + T)[:20]
 *
 * GCL-SDK-01 FIX: The tweak is derived as t*G (scalar multiplication) rather
 * than interpreting the raw 32-byte keccak_256 output as a curve point encoding.
 *
 * @param recipientViewingKey - Recipient's viewing public key (for scanning)
 * @param recipientSpendingKey - Recipient's spending public key (for spending)
 * @returns The stealth address and associated metadata
 */
export function generateStealthAddress(
  recipientViewingKey: Uint8Array,
  recipientSpendingKey: Uint8Array,
): StealthAddressResult {
  // 1. Generate ephemeral keypair
  const ephemeralPrivateKey = secp256k1.utils.randomPrivateKey();
  const ephemeralPublicKey = secp256k1.getPublicKey(ephemeralPrivateKey, false);

  // 2. ECDH shared secret using the VIEWING key (for scanning privacy)
  const sharedSecret = secp256k1.getSharedSecret(
    ephemeralPrivateKey,
    recipientViewingKey,
    true, // compact form
  );

  // 3. Compute tweak = keccak_256(sharedSecret) as a scalar, then T = tweak * G
  //    GCL-SDK-01 FIX: keccak_256 outputs 32 bytes, which is NOT a valid curve
  //    point encoding (expects 33+ bytes). Multiply the generator by the scalar
  //    to produce a valid curve point, then add to the spending public key.
  const tweakScalar = keccak_256(sharedSecret);
  const spendingPoint = secp256k1.ProjectivePoint.fromHex(recipientSpendingKey);
  const tweakPoint = secp256k1.ProjectivePoint.BASE.multiply(tweakScalar);
  const stealthPoint = spendingPoint.add(tweakPoint);
  const tweakedPublicKey = stealthPoint.toRawBytes(false);

  // 4. Convert to address: keccak_256(pubkey[1:])[-20:]
  const addressBytes = keccak_256(tweakedPublicKey.slice(1)).slice(-20);
  const stealthAddress = '0x' + bytesToHex(addressBytes);

  return {
    stealthAddress,
    ephemeralPrivateKey,
    sharedSecret,
  };
}

/**
 * Generates a ghost (stealth) address for the recipient.
 * High-level wrapper that takes GhostKeyPair styled inputs.
 *
 * @param senderIdentity - The sender's keypair
 * @param recipientSpendingPubKey - The recipient's public spending key (hex)
 * @param recipientViewingPubKey - The recipient's public viewing key (hex)
 * @returns The generated ghost address and associated metadata
 */
export function generateGhostAddress(
  senderIdentity: GhostKeyPair,
  recipientSpendingPubKey: `0x${string}`,
  recipientViewingPubKey: `0x${string}`,
): GhostAddress {
  // Convert hex keys to bytes for the stealth engine
  const viewingKeyBytes = hexToBytes(recipientViewingPubKey.slice(2));
  const spendingKeyBytes = hexToBytes(recipientSpendingPubKey.slice(2));

  // Generate stealth address (ECDH with viewing key, tweak with spending key)
  const result = generateStealthAddress(viewingKeyBytes, spendingKeyBytes);

  // Generate ephemeral public key for the event log
  const ephemeralPubKey = secp256k1.getPublicKey(result.ephemeralPrivateKey, true);

  // View tag: first byte of keccak_256(sharedSecret) for fast scanning
  const viewTag = keccak_256(result.sharedSecret)[0];

  return {
    address: getAddress(result.stealthAddress as `0x${string}`),
    ephemeralPublicKey: `0x${bytesToHex(ephemeralPubKey)}`,
    viewTag,
  };
}

/**
 * Scans for ghost addresses belonging to the recipient using their viewing key.
 * The recipient checks each potential ghost address by recomputing
 * the shared secret from their viewing private key and the ephemeral public key.
 *
 * GCL-SDK-01 FIX: The tweak is correctly computed as t*G (scalar multiplication)
 * matching the generation side, producing a valid curve point addition.
 *
 * @param recipientIdentity - The recipient's keypair
 * @param ephemeralPublicKey - The ephemeral public key from the transaction
 * @param viewTag - The view tag to filter (first byte of keccak_256(sharedSecret))
 * @returns The derived ghost address if the view tag matches, null otherwise
 */
export function scanGhostAddress(
  recipientIdentity: GhostKeyPair,
  ephemeralPublicKey: `0x${string}`,
  viewTag: number,
): Address | null {
  // Recompute shared secret using viewing private key
  const viewingPrivKey = hexToBytes(recipientIdentity.viewingPrivateKey.slice(2));
  const sharedSecret = secp256k1.getSharedSecret(
    viewingPrivKey,
    hexToBytes(ephemeralPublicKey.slice(2)),
    true,
  );

  // Fast filter: check view tag first (first byte of keccak_256(sharedSecret))
  const sharedHash = keccak_256(sharedSecret);
  if (sharedHash[0] !== viewTag) {
    return null;
  }

  // Compute tweak = keccak_256(sharedSecret) as a scalar, then T = tweak * G
  // GCL-SDK-01 FIX: keccak_256 outputs 32 bytes, which is NOT a valid curve
  // point encoding. Multiply the generator by the scalar to get a valid point.
  const spendingKeyBytes = hexToBytes(recipientIdentity.spendingPublicKey.slice(2));
  const tweakScalar = sharedHash;
  const spendingPoint = secp256k1.ProjectivePoint.fromHex(spendingKeyBytes);
  const tweakPoint = secp256k1.ProjectivePoint.BASE.multiply(tweakScalar);
  const stealthPoint = spendingPoint.add(tweakPoint);
  const tweakedPublicKey = stealthPoint.toRawBytes(false);

  const addressBytes = keccak_256(tweakedPublicKey.slice(1)).slice(-20);

  return getAddress(`0x${bytesToHex(addressBytes)}`);
}

/**
 * Computes the sender commitment for the ghost transfer ZK proof.
 *
 * The commitment is Poseidon(senderPrivateKey, senderRandomness) which matches
 * the circuit constraint in ghostTransfer.circom:
 *   senderCommitment == Poseidon(senderPrivateKey, senderRandomness)
 *
 * This is stored on-chain when creating the swap and used as the senderCommitment
 * public input during proof verification.
 *
 * FIXES GCL-ZK-04: Previously used keccak256 which never matched the circuit's
 * Poseidon hash. Now uses Poseidon(2) identical to the circuit.
 *
 * @param senderPrivateKey - The sender's private key (hex)
 * @param senderRandomness - Random blinding factor (hex)
 * @returns The sender commitment as a 0x-prefixed hex string (32 bytes)
 */
export function computeGhostTransferCommitment(
  senderPrivateKey: `0x${string}`,
  senderRandomness: `0x${string}`,
): `0x${string}` {
  // FIX GCL-ZK-04: Use Poseidon(2) matching ghostTransfer.circom constraint:
  //   senderCommitment == Poseidon(senderPrivateKey, senderRandomness)
  return computeSenderCommitment(senderPrivateKey, senderRandomness);
}

/**
 * Computes the circuit-level shared secret for ZK witness generation.
 *
 * FIXES GCL-ZK-04: Previously used SHA-256 which never matched the circuit's
 * Poseidon. Now delegates to the Poseidon(2) implementation from poseidon.ts.
 *
 * @param senderPrivateKey - The sender's spending private key (hex)
 * @param ephemeralPublicKey - The ephemeral public key (R = r*G) from swap creation
 * @returns The circuit shared secret as a field-compatible hex string
 */
export { computeCircuitSharedSecret } from './poseidon.js';
export {
  poseidonHash2,
  poseidonHash3,
  poseidonHash5,
  computeSenderCommitment,
  computeContractHash,
} from './poseidon.js';

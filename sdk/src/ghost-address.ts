/**
 * Ghost Address Layer
 *
 * Implements stealth address generation for the GhostChain protocol
 * based on **ERC-5564** (Stealth Addresses for Ethereum).
 *
 * Core cryptography (ECDH on secp256k1):
 *   1. Sender generates ephemeral keypair (r, R)
 *   2. Sender computes ECDH shared secret: S = r * viewingPubKey
 *   3. Compute tweak: t = keccak_256(S)
 *   4. Recipient's stealth address = keccak_256(spendingPubKey + t)[:20]
 *
 * The recipient scans for incoming transfers using their viewing key:
 *   - View Tag: first byte of keccak_256(S), used for fast filtering
 *   - Only the recipient's viewing key can derive the same shared secret
 *
 * This ensures that only the recipient (with their spending key) can spend
 * funds sent to a stealth address, maintaining privacy.
 */

import { bytesToHex, hexToBytes, concatBytes } from '@noble/hashes/utils';
import { keccak_256 } from '@noble/hashes/sha3';
import { secp256k1 } from '@noble/curves/secp256k1';
import { type Address, getAddress } from 'viem';
import type { GhostAddress, GhostKeyPair } from './types.js';

// ───── Types ─────

export interface StealthKeys {
  spendingPrivateKey: Uint8Array;
  spendingPublicKey: Uint8Array;
  viewingPrivateKey: Uint8Array;
  viewingPublicKey: Uint8Array;
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
 *   3. Compute tweak: t = keccak_256(S) as a curve point
 *   4. Stealth address = keccak_256(spendingPubKey + t)[:20]
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

  // 3. Compute tweak = keccak_256(sharedSecret), interpret as scalar on curve
  const tweak = keccak_256(sharedSecret);
  const tweakedPublicKey = secp256k1.ProjectivePoint
    .fromHex(recipientSpendingKey)
    .add(secp256k1.ProjectivePoint.fromHex(tweak))
    .toRawBytes(false);

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

  // Compute tweak = keccak_256(sharedSecret)
  const tweak = sharedHash;
  const spendingKeyBytes = hexToBytes(recipientIdentity.spendingPublicKey.slice(2));

  // Derive the stealth address by tweaking the spending public key
  const tweakedPublicKey = secp256k1.ProjectivePoint
    .fromHex(spendingKeyBytes)
    .add(secp256k1.ProjectivePoint.fromHex(tweak))
    .toRawBytes(false);

  const addressBytes = keccak_256(tweakedPublicKey.slice(1)).slice(-20);

  return getAddress(`0x${bytesToHex(addressBytes)}`);
}

/**
 * Computes the commitment hash for the ghost transfer ZK proof.
 * This binds the ghost address, token, amount, nonce, and chain ID together.
 *
 * @param ghostAddress - The ghost address
 * @param token - The token address
 * @param amount - The transfer amount
 * @param nonce - A unique nonce to prevent replay
 * @param chainId - The chain ID where this proof will be verified
 * @returns The commitment hash
 */
export function computeGhostTransferCommitment(
  ghostAddress: Address,
  token: Address,
  amount: bigint,
  nonce: bigint,
  chainId: bigint,
): `0x${string}` {
  const hash = keccak_256(
    concatBytes(
      hexToBytes(ghostAddress.slice(2)),
      hexToBytes(token.slice(2)),
      hexToBytes(amount.toString(16).padStart(64, '0')),
      hexToBytes(nonce.toString(16).padStart(64, '0')),
      hexToBytes(chainId.toString(16).padStart(64, '0')),
    ),
  );

  return `0x${bytesToHex(hash)}`;
}

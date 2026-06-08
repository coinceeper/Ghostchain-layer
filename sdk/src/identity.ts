/**
 * Identity Layer
 *
 * BIP-44 key derivation for GhostChain protocol.
 * Derives Spending and Viewing keypairs from a single mnemonic seed.
 *
 * Key derivation structure (BIP-44):
 *   m/44'/<coin_type>'/<account>'/<change>/<index>
 *
 * For GhostChain:
 *   Spending key:  m/44'/60'/0'/0/0
 *   Viewing key:   m/44'/60'/0'/0/1
 *
 * Assets:
 * - Spending key: Used to authorize transfers and sign intents
 * - Viewing key:  Used to scan for incoming ghost transfers (shared with relayers)
 */

import { HDKey } from '@scure/bip32';
import { bytesToHex, hexToBytes } from '@noble/hashes/utils';
import { keccak_256 } from '@noble/hashes/sha3';
import { secp256k1 } from '@noble/curves/secp256k1';
import { type Address, getAddress } from 'viem';
import type { GhostKeyPair } from './types.js';

// ───── Constants ─────

const COIN_TYPE_ETH = 60;     // Ethereum (and EVM chains)
const ACCOUNT = 0;

// ───── Public API ─────

/**
 * Derives a GhostChain identity (Spending + Viewing keys) from a mnemonic seed.
 *
 * @param seed - The BIP-39 seed buffer from the mnemonic
 * @param coinType - The BIP-44 coin type (default: 60 for EVM chains)
 * @param accountIndex - The account index (default: 0)
 * @returns GhostKeyPair with derived keys
 */
export function deriveIdentity(
  seed: Uint8Array,
  coinType: number = COIN_TYPE_ETH,
  accountIndex: number = ACCOUNT,
): GhostKeyPair {
  const masterKey = HDKey.fromMasterSeed(seed);

  // Spending key: m/44'/coin_type'/account'/0/0
  const spendingPath = `m/44'/${coinType}'/${accountIndex}'/0/0`;
  const spendingNode = masterKey.derive(spendingPath);
  if (!spendingNode.privateKey) throw new Error('Failed to derive spending key');

  const spendingPrivKey = bytesToHex(spendingNode.privateKey);
  const spendingPubKey = getCompressedPubKey(spendingNode.privateKey);

  // Viewing key: m/44'/coin_type'/account'/1/0
  const viewingPath = `m/44'/${coinType}'/${accountIndex}'/1/0`;
  const viewingNode = masterKey.derive(viewingPath);
  if (!viewingNode.privateKey) throw new Error('Failed to derive viewing key');

  const viewingPrivKey = bytesToHex(viewingNode.privateKey);
  const viewingPubKey = getCompressedPubKey(viewingNode.privateKey);

  // Derive Ethereum address from spending public key
  const address = publicKeyToAddress(spendingPubKey);

  return {
    derivationPath: `m/44'/${coinType}'/${accountIndex}'`,
    spendingPrivateKey: toHex(spendingPrivKey),
    spendingPublicKey: toHex(spendingPubKey),
    viewingPrivateKey: toHex(viewingPrivKey),
    viewingPublicKey: toHex(viewingPubKey),
    address,
  };
}

/**
 * Signs a message with the spending key.
 *
 * @param privateKey - The spending private key
 * @param message - The message hash to sign
 * @returns The signature as hex
 */
export function signWithSpendingKey(
  privateKey: `0x${string}`,
  message: `0x${string}`,
): `0x${string}` {
  const sig = secp256k1.sign(
    hexToBytes(message.slice(2)),
    hexToBytes(privateKey.slice(2)),
  );

  return toHex(sig.toCompactHex());
}

/**
 * Recovers the public key from a signature.
 *
 * @param message - The signed message hash
 * @param signature - The signature
 * @returns The recovered uncompressed public key
 */
export function recoverPublicKey(
  message: `0x${string}`,
  signature: `0x${string}`,
): `0x${string}` {
  const sig = secp256k1.Signature.fromCompact(signature.slice(2));
  const point = sig.recoverPublicKey(hexToBytes(message.slice(2)));
  return toHex(point.toRawBytes(false));
}

// ───── Internal Helpers ─────

/**
 * Gets the compressed public key from a private key.
 */
function getCompressedPubKey(privateKey: Uint8Array): Uint8Array {
  const publicKey = secp256k1.getPublicKey(privateKey, true);
  return publicKey;
}

/**
 * Converts a public key to an Ethereum address (last 20 bytes of keccak256 hash).
 */
function publicKeyToAddress(publicKey: Uint8Array): Address {
  // Decompress the public key if necessary and compute the Ethereum address.
  const point = secp256k1.ProjectivePoint.fromHex(publicKey);
  const uncompressed = point.toRawBytes(false);
  const hash = keccak_256(uncompressed.slice(1));
  const addressHex = bytesToHex(hash.slice(-20));
  return getAddress(`0x${addressHex}`);
}

/**
 * Converts a hex string or bytes to a typed hex literal.
 */
function toHex(value: string | Uint8Array): `0x${string}` {
  if (typeof value === 'string') {
    return value.startsWith('0x') ? (value as `0x${string}`) : `0x${value}`;
  }
  return `0x${bytesToHex(value)}`;
}

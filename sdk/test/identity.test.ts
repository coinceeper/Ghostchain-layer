import { describe, it, expect } from 'vitest';
import { deriveIdentity, signWithSpendingKey, recoverPublicKey } from '../src/identity.js';
import { generateGhostAddress, scanGhostAddress, computeGhostTransferCommitment } from '../src/ghost-address.js';
import { generateMnemonic, mnemonicToSeedSync } from '@noble/hashes/utils';

// Use a fixed seed for reproducible tests
const TEST_SEED = new Uint8Array(32).fill(0x42);

describe('Identity Layer', () => {
  it('should derive spending and viewing keys from seed', () => {
    const identity = deriveIdentity(TEST_SEED);

    expect(identity.derivationPath).toBe("m/44'/60'/0'");
    expect(identity.spendingPrivateKey).toBeTruthy();
    expect(identity.spendingPublicKey).toBeTruthy();
    expect(identity.viewingPrivateKey).toBeTruthy();
    expect(identity.viewingPublicKey).toBeTruthy();
    expect(identity.address).toMatch(/^0x[a-fA-F0-9]{40}$/);

    // Spending and viewing keys should be different
    expect(identity.spendingPrivateKey).not.toBe(identity.viewingPrivateKey);
    expect(identity.spendingPublicKey).not.toBe(identity.viewingPublicKey);
  });

  it('should derive different keys for different accounts', () => {
    const identity0 = deriveIdentity(TEST_SEED, 60, 0);
    const identity1 = deriveIdentity(TEST_SEED, 60, 1);

    expect(identity0.address).not.toBe(identity1.address);
    expect(identity0.spendingPrivateKey).not.toBe(identity1.spendingPrivateKey);
  });

  it('should derive different keys for different coin types', () => {
    const evmIdentity = deriveIdentity(TEST_SEED, 60, 0);   // Ethereum
    const tronIdentity = deriveIdentity(TEST_SEED, 195, 0);  // Tron

    expect(evmIdentity.address).not.toBe(tronIdentity.address);
    expect(evmIdentity.derivationPath).not.toBe(tronIdentity.derivationPath);
  });

  it('should sign and recover messages', () => {
    const identity = deriveIdentity(TEST_SEED);
    const message = '0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef';

    const signature = signWithSpendingKey(identity.spendingPrivateKey, message);
    expect(signature).toBeTruthy();

    const recovered = recoverPublicKey(message, signature);
    expect(recovered).toBeTruthy();
  });
});

describe('Ghost Address Layer', () => {
  it('should generate a valid ghost address', () => {
    const sender = deriveIdentity(TEST_SEED);
    const recipient = deriveIdentity(new Uint8Array(32).fill(0x99));

    const ghostAddress = generateGhostAddress(
      sender,
      recipient.spendingPublicKey,
      recipient.viewingPublicKey,
    );

    expect(ghostAddress.address).toMatch(/^0x[a-fA-F0-9]{40}$/);
    expect(ghostAddress.ephemeralPublicKey).toBeTruthy();
    expect(ghostAddress.viewTag).toEqual(expect.any(Number));
  });

  it('should allow recipient to scan and detect ghost address', () => {
    const sender = deriveIdentity(TEST_SEED);
    const recipient = deriveIdentity(new Uint8Array(32).fill(0x99));

    const ghostAddress = generateGhostAddress(
      sender,
      recipient.spendingPublicKey,
      recipient.viewingPublicKey,
    );

    const scanned = scanGhostAddress(
      recipient,
      ghostAddress.ephemeralPublicKey,
      ghostAddress.viewTag,
    );

    expect(scanned).toBe(ghostAddress.address);
  });

  it('should not detect ghost addresses for wrong recipient', () => {
    const sender = deriveIdentity(TEST_SEED);
    const recipient = deriveIdentity(new Uint8Array(32).fill(0x99));
    const wrongRecipient = deriveIdentity(new Uint8Array(32).fill(0xAA));

    const ghostAddress = generateGhostAddress(
      sender,
      recipient.spendingPublicKey,
      recipient.viewingPublicKey,
    );

    const scanned = scanGhostAddress(
      wrongRecipient,
      ghostAddress.ephemeralPublicKey,
      ghostAddress.viewTag,
    );

    expect(scanned).toBeNull();
  });

  it('should compute a deterministic sender commitment using Poseidon', () => {
    const senderPrivKey = '0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef' as `0x${string}`;
    const randomness = '0xdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef' as `0x${string}`;

    const commitment1 = computeGhostTransferCommitment(
      senderPrivKey,
      randomness,
    );

    const commitment2 = computeGhostTransferCommitment(
      senderPrivKey,
      randomness,
    );

    // Same inputs should produce same commitment (deterministic)
    expect(commitment1).toBe(commitment2);

    // Different randomness should produce different commitment
    const differentRandomness = '0x0000000000000000000000000000000000000000000000000000000000000001' as `0x${string}`;
    const commitment3 = computeGhostTransferCommitment(
      senderPrivKey,
      differentRandomness,
    );
    expect(commitment1).not.toBe(commitment3);
  });
});

describe('Cross-Chain Addressing', () => {
  it('should derive identities usable on multiple EVM chains', () => {
    // EVM chains share the same coin type (60)
    const identity = deriveIdentity(TEST_SEED, 60, 0);

    // The same identity should be usable on all EVM chains
    expect(identity.address).toBeTruthy();
    expect(identity.spendingPublicKey).toBeTruthy();

    // EVM address format validation
    expect(identity.address.length).toBe(42); // 0x + 40 hex chars
  });
});

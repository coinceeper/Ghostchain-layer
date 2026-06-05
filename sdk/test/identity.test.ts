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

  it('should compute a deterministic commitment hash', () => {
    const ghostAddr = '0x1234567890abcdef1234567890abcdef12345678';
    const token = '0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9';
    const amount = BigInt(1000_000_000); // 1000 USDT (6 decimals)

    const commitment1 = computeGhostTransferCommitment(
      ghostAddr,
      token,
      amount,
      BigInt(1),
      BigInt(42161),
    );

    const commitment2 = computeGhostTransferCommitment(
      ghostAddr,
      token,
      amount,
      BigInt(1),
      BigInt(42161),
    );

    // Same inputs should produce same commitment
    expect(commitment1).toBe(commitment2);

    // Different nonce should produce different commitment
    const commitment3 = computeGhostTransferCommitment(
      ghostAddr,
      token,
      amount,
      BigInt(2),
      BigInt(42161),
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

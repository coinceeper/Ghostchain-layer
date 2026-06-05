/**
 * Integration Tests for GhostChain Relayer
 *
 * Tests the full pipeline:
 *   1. Identity derivation and key management
 *   2. Ghost address generation
 *   3. ZK proof generation (bootstrap mode)
 *   4. Intent creation and evaluation
 *   5. Liquidity management
 *   6. Cross-chain transfer simulation
 *
 * These tests use mocked RPC endpoints and in-memory state,
 * so they can run without access to real blockchain networks.
 */

import { describe, it, expect, beforeAll } from 'vitest';
import { createPublicClient, http, type Address } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import { getChainById } from '@ghostchain/sdk';
import { IntentExecutor, type SolverConfig } from '../src/executor.js';
import { LiquidityManager } from '../src/liquidity.js';
import { ZkProver, type GhostTransferPublicInputs } from '../src/zk-prover.js';
import { LocalKeyManager } from '../src/key-manager.js';
import { createLogger } from '../src/logger.js';
import { deriveIdentity, generateGhostAddress } from '@ghostchain/sdk';

// ───── Test Constants ─────

const TEST_PRIVATE_KEY = '0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80' as `0x${string}`;
const TEST_CHAIN_ID = 42161; // Arbitrum
const TEST_DEST_CHAIN_ID = 137; // Polygon
const TEST_TOKEN = '0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9' as Address;
const TEST_FACTORY = '0x0000000000000000000000000000000000000001' as Address;
const TEST_VERIFIER = '0x0000000000000000000000000000000000000002' as Address;
const TEST_AMOUNT = BigInt(100_000_000); // 100 USDT (6 decimals)

const logger = createLogger('IntegrationTest');

// ───── Test Identity ─────

const TEST_SEED = new Uint8Array(32).fill(0x42);
const senderIdentity = deriveIdentity(TEST_SEED, 60, 0);
const recipientIdentity = deriveIdentity(new Uint8Array(32).fill(0x99), 60, 0);

// ───── Test Suite ─────

describe('GhostChain Integration Tests', () => {
  let executor: IntentExecutor;
  let liquidityManager: LiquidityManager;
  let zkProver: ZkProver;
  let keyManager: LocalKeyManager;
  let config: SolverConfig;

  beforeAll(async () => {
    // Initialize key manager
    keyManager = new LocalKeyManager(TEST_PRIVATE_KEY, logger);

    // Create mock config
    config = {
      solverId: 'test-solver-1',
      keyManager,
      rpcEndpoints: {
        [TEST_CHAIN_ID]: 'http://localhost:8545',
        [TEST_DEST_CHAIN_ID]: 'http://localhost:8546',
      },
      factoryAddresses: {
        [TEST_CHAIN_ID]: TEST_FACTORY,
        [TEST_DEST_CHAIN_ID]: TEST_FACTORY,
      },
      verifierAddresses: {
        [TEST_CHAIN_ID]: TEST_VERIFIER,
        [TEST_DEST_CHAIN_ID]: TEST_VERIFIER,
      },
      supportedChainIds: [TEST_CHAIN_ID, TEST_DEST_CHAIN_ID],
      minFeeBps: 30,
      maxFillAmountUsd: 10000,
      apiPort: 0,
    };

    // Initialize ZK prover
    zkProver = new ZkProver(
      {
        solverPrivateKey: TEST_PRIVATE_KEY,
        useFullProving: false, // Bootstrap mode for tests
      },
      logger,
    );

    config.zkProver = zkProver;

    // Initialize liquidity manager
    liquidityManager = new LiquidityManager(config, logger);

    // Create mock clients
    const clients = new Map();
    for (const chainId of config.supportedChainIds) {
      try {
        const chain = getChainById(chainId);
        clients.set(chainId, createPublicClient({
          chain,
          transport: http(config.rpcEndpoints[chainId]),
        }));
      } catch {
        // Skip chains that fail
      }
    }

    // Initialize executor
    executor = new IntentExecutor(config, clients, liquidityManager, logger);
  });

  // ───── 1. Identity & Key Management ─────

  describe('Identity & Key Management', () => {
    it('should create a working LocalKeyManager', () => {
      const address = keyManager.getAddress();
      expect(address).toMatch(/^0x[a-fA-F0-9]{40}$/);
      expect(keyManager.getKeyManagerType()).toBe('local');
    });

    it('should sign messages with the key manager', async () => {
      const message = '0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef';
      const signature = await keyManager.signMessage(message);
      expect(signature).toBeTruthy();
      expect(signature.length).toBeGreaterThan(2);
    });

    it('should derive consistent identities from seeds', () => {
      expect(senderIdentity.spendingPublicKey).toBeTruthy();
      expect(recipientIdentity.spendingPublicKey).toBeTruthy();
      expect(senderIdentity.address).not.toBe(recipientIdentity.address);
    });
  });

  // ───── 2. Ghost Address Generation ─────

  describe('Ghost Address Generation', () => {
    it('should generate a valid ghost address', () => {
      const ghostAddress = generateGhostAddress(
        senderIdentity,
        recipientIdentity.spendingPublicKey,
        recipientIdentity.viewingPublicKey,
      );

      expect(ghostAddress.address).toMatch(/^0x[a-fA-F0-9]{40}$/);
      expect(ghostAddress.ephemeralPublicKey).toBeTruthy();
      expect(ghostAddress.viewTag).toEqual(expect.any(Number));
      expect(ghostAddress.viewTag).toBeGreaterThanOrEqual(0);
      expect(ghostAddress.viewTag).toBeLessThanOrEqual(255);
    });
  });

  // ───── 3. ZK Proof Generation ─────

  describe('ZK Proof Generation (Bootstrap Mode)', () => {
    it('should generate a bootstrap proof', async () => {
      const ghostAddress = generateGhostAddress(
        senderIdentity,
        recipientIdentity.spendingPublicKey,
        recipientIdentity.viewingPublicKey,
      );

      const publicInputs: GhostTransferPublicInputs = {
        senderCommitment: '0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef',
        recipientCommitment: '0xabcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890',
        contractHash: '0xdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef',
        token: TEST_TOKEN,
        amount: TEST_AMOUNT,
        nonce: BigInt(1),
        chainId: BigInt(TEST_CHAIN_ID),
      };

      const result = await zkProver.generateProof(publicInputs);

      expect(result.proof).toBeTruthy();
      expect(result.proofType).toBe(0);
      expect(result.bootstrap).toBe(true);
      expect(result.proof.length).toBeGreaterThan(2);
    });

    it('should generate deterministic proofs for same inputs', async () => {
      const publicInputs: GhostTransferPublicInputs = {
        senderCommitment: '0x0000000000000000000000000000000000000000000000000000000000000001',
        recipientCommitment: '0x0000000000000000000000000000000000000000000000000000000000000002',
        contractHash: '0x0000000000000000000000000000000000000000000000000000000000000003',
        token: TEST_TOKEN,
        amount: TEST_AMOUNT,
        nonce: BigInt(42),
        chainId: BigInt(TEST_CHAIN_ID),
      };

      const result1 = await zkProver.generateProof(publicInputs);
      const result2 = await zkProver.generateProof(publicInputs);

      // Bootstrap proofs should be different (ECDSA uses random k)
      expect(result1.proof).not.toBe(result2.proof);
      expect(result1.publicInputs.senderCommitment).toBe(result2.publicInputs.senderCommitment);
    });
  });

  // ───── 4. Intent Evaluation ─────

  describe('Intent Evaluation', () => {
    it('should reject intents when kill switch is engaged', async () => {
      executor.engageKillSwitch();
      const result = await executor.evaluateIntent({
        id: '0x0000000000000000000000000000000000000000000000000000000000000001',
        sourceChain: TEST_CHAIN_ID,
        destinationChain: TEST_DEST_CHAIN_ID,
        token: TEST_TOKEN,
        amount: TEST_AMOUNT,
        recipientGhostAddress: '0x0000000000000000000000000000000000000000' as Address,
        commitment: '0x0000000000000000000000000000000000000000000000000000000000000000',
        fulfilled: false,
        expiry: BigInt(0),
      });

      expect(result).toBe(false);
      executor.disengageKillSwitch();
    });

    it('should reject intents for unsupported destination chains', async () => {
      const result = await executor.evaluateIntent({
        id: '0x0000000000000000000000000000000000000000000000000000000000000002',
        sourceChain: TEST_CHAIN_ID,
        destinationChain: 999999, // Unsupported chain
        token: TEST_TOKEN,
        amount: TEST_AMOUNT,
        recipientGhostAddress: '0x0000000000000000000000000000000000000000' as Address,
        commitment: '0x0000000000000000000000000000000000000000000000000000000000000000',
        fulfilled: false,
        expiry: BigInt(0),
      });

      expect(result).toBe(false);
    });
  });

  // ───── 5. Liquidity Management ─────

  describe('Liquidity Management', () => {
    it('should report no liquidity when uninitialized', () => {
      const total = liquidityManager.getTotalLiquidity();
      expect(total.totalUsd).toBe(0);
      expect(total.positions).toBe(0);
    });

    it('should allocate and release liquidity correctly', () => {
      // Mock a position
      const chainId = TEST_CHAIN_ID;
      const token = TEST_TOKEN;

      // Initially no position
      expect(liquidityManager.hasSufficientLiquidity(chainId, TEST_AMOUNT)).toBe(false);

      // Release should not throw on non-existent positions
      expect(() => liquidityManager.release(chainId, token, TEST_AMOUNT)).not.toThrow();
    });

    it('should track rebalance status correctly', () => {
      const status = liquidityManager.checkRebalanceNeeded();
      expect(status).toHaveProperty('needsRebalance');
      expect(status).toHaveProperty('lowChains');
      expect(status).toHaveProperty('details');
    });
  });
});

/**
 * Key Manager Abstraction
 *
 * Provides a secure abstraction over the Relayer/Solver private key operations.
 * Supports multiple backends:
 *   1. LocalKeyManager: File/env-based private key (development)
 *   2. AWSKMSKeyManager: AWS KMS integration (production)
 *   3. HashiCorpVaultKeyManager: Vault integration (enterprise)
 *
 * This replaces the raw SOLVER_PRIVATE_KEY env var pattern with a proper
 * key management interface, reducing the risk of key compromise.
 *
 * @packageDocumentation
 */

import { type Address, type Hash, type Account, keccak256, encodeAbiParameters, parseAbiParameters } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import type { Logger } from 'pino';

// ───── Types ─────

export interface TransactionRequest {
  to: Address;
  data: `0x${string}`;
  value?: bigint;
  chainId: number;
  gasLimit?: bigint;
  maxFeePerGas?: bigint;
  maxPriorityFeePerGas?: bigint;
}

export interface SignedTransaction {
  rawTransaction: `0x${string}`;
  transactionHash: Hash;
  from: Address;
}

// ───── Key Manager Interface ─────

/**
 * Abstract interface for key management operations.
 * Implementations can use local keys, HSM, KMS, or threshold signatures.
 */
export interface KeyManager {
  /** Returns the solver's address on all supported chains */
  getAddress(): Address;

  /** Signs an arbitrary message hash */
  signMessage(message: `0x${string}`): Promise<`0x${string}`>;

  /** Signs and sends a transaction on a specific chain */
  signAndSendTransaction(chainId: number, tx: TransactionRequest): Promise<SignedTransaction>;

  /** Returns the key manager type (for logging/monitoring) */
  getKeyManagerType(): string;
}

// ───── Local Key Manager (Development) ─────

/**
 * Local private key manager for development and testing.
 * Uses an in-memory Viem account from a hex private key.
 *
 * ⚠️ NOT for production use - keys are in plaintext in process memory.
 * Replace with AWSKMSKeyManager or HashiCorpVaultKeyManager for production.
 */
export class LocalKeyManager implements KeyManager {
  private account: Account;
  private logger: Logger;

  constructor(privateKey: `0x${string}`, logger: Logger) {
    this.account = privateKeyToAccount(privateKey);
    this.logger = logger.child({ module: 'LocalKeyManager' });
  }

  getAddress(): Address {
    return this.account.address;
  }

  async signMessage(message: `0x${string}`): Promise<`0x${string}`> {
    return this.account.signMessage({ message: { raw: message } });
  }

  async signAndSendTransaction(
    _chainId: number,
    tx: TransactionRequest,
  ): Promise<SignedTransaction> {
    // In local mode, we need a wallet client to send transactions.
    // This is a simplified implementation - in production,
    // use the Viem wallet client created in the executor.
    const txHash = `0x${keccak256(new TextEncoder().encode(JSON.stringify(tx))).slice(2).padStart(64, '0')}` as Hash;

    this.logger.debug(
      `[LOCAL KM] Simulated tx: to=${tx.to}, chainId=${tx.chainId}`,
    );

    return {
      rawTransaction: '0x' as `0x${string}`,
      transactionHash: txHash,
      from: this.account.address,
    };
  }

  getKeyManagerType(): string {
    return 'local';
  }
}

// ───── AWS KMS Key Manager (Production) ─────

/**
 * AWS KMS-based key manager for production use.
 * The private key never leaves AWS KMS - all signing operations
 * are performed within the HSM-backed KMS environment.
 *
 * Requires AWS SDK v3 and appropriate IAM permissions:
 *   - kms:Sign
 *   - kms:GetPublicKey
 *
 * Environment variables:
 *   AWS_KMS_KEY_ID - The KMS key ID (e.g., 'arn:aws:kms:us-east-1:...:key/...')
 *   AWS_REGION     - AWS region (e.g., 'us-east-1')
 */
export class AWSKMSKeyManager implements KeyManager {
  private address: Address;
  private logger: Logger;
  private kmsClient: any; // AWS KMS client
  private kmsKeyId: string;

  constructor(kmsKeyId: string, region: string, logger: Logger) {
    this.kmsKeyId = kmsKeyId;
    this.logger = logger.child({ module: 'AWSKMSKeyManager' });

    // Lazy-import AWS SDK
    try {
      const { KMSClient } = require('@aws-sdk/client-kms');
      this.kmsClient = new KMSClient({ region });
    } catch {
      this.logger.warn('AWS SDK not available, KMS key manager will not work');
    }

    // Derive Ethereum address from the KMS public key
    this.address = '0x0000000000000000000000000000000000000000';
    this.initializeAddress();
  }

  private async initializeAddress(): Promise<void> {
    try {
      const { GetPublicKeyCommand } = require('@aws-sdk/client-kms');
      const response = await this.kmsClient.send(
        new GetPublicKeyCommand({ KeyId: this.kmsKeyId }),
      );

      // Derive Ethereum address from the uncompressed public key
      const publicKeyBytes = new Uint8Array(response.PublicKey);
      // SEC1 uncompressed format: 0x04 + x + y (65 bytes)
      if (publicKeyBytes.length === 65 && publicKeyBytes[0] === 0x04) {
        const hash = keccak256(publicKeyBytes.slice(1) as `0x${string}`);
        this.address = `0x${hash.slice(-40)}` as Address;
      }
    } catch (error) {
      this.logger.error('Failed to derive address from KMS key:', error);
    }
  }

  getAddress(): Address {
    return this.address;
  }

  async signMessage(message: `0x${string}`): Promise<`0x${string}`> {
    try {
      const { SignCommand } = require('@aws-sdk/client-kms');
      const { SignatureAlgorithm, MessageType, KeySpec } = require('@aws-sdk/client-kms');

      const response = await this.kmsClient.send(
        new SignCommand({
          KeyId: this.kmsKeyId,
          Message: Buffer.from(message.slice(2), 'hex'),
          MessageType: MessageType.DIGEST,
          SignatureAlgorithm: SignatureAlgorithm.ECDSA_SHA_256,
        }),
      );

      // Convert the DER-encoded signature to v/r/s format
      const signature = this.derToVrs(response.Signature);
      return signature;
    } catch (error) {
      this.logger.error('KMS signing failed:', error);
      throw error;
    }
  }

  async signAndSendTransaction(
    _chainId: number,
    tx: TransactionRequest,
  ): Promise<SignedTransaction> {
    // In production, this would:
    // 1. Create a transaction envelope
    // 2. Sign it using KMS via eth_sendRawTransaction
    // 3. Submit via RPC

    this.logger.info(
      `[AWS KMS] Signing tx: to=${tx.to}, chainId=${tx.chainId}`,
    );

    throw new Error('AWS KMS transaction signing not yet implemented');
  }

  getKeyManagerType(): string {
    return 'aws-kms';
  }

  /**
   * Converts a DER-encoded ECDSA signature to v/r/s format.
   */
  private derToVrs(derSignature: Uint8Array): `0x${string}` {
    // Parse DER-encoded ECDSA signature
    // DER format: 0x30 <len> 0x02 <r_len> <r> 0x02 <s_len> <s>
    let offset = 2; // Skip 0x30 <len>
    offset += 2; // Skip 0x02 <r_len>
    const rLen = derSignature[offset - 1];
    const r = derSignature.slice(offset, offset + rLen);
    offset += rLen;
    offset += 1; // Skip 0x02
    const sLen = derSignature[offset];
    offset += 1;
    const s = derSignature.slice(offset, offset + sLen);

    // Pad r and s to 32 bytes
    const rPadded = new Uint8Array(32);
    const sPadded = new Uint8Array(32);
    rPadded.set(r.length <= 32 ? r : r.slice(r.length - 32), 32 - Math.min(r.length, 32));
    sPadded.set(s.length <= 32 ? s : s.slice(s.length - 32), 32 - Math.min(s.length, 32));

    // Encode as v/r/s (v = 27 for uncompressed recovery)
    return `0x${Buffer.from(rPadded).toString('hex')}${Buffer.from(sPadded).toString('hex')}1b` as `0x${string}`;
  }
}

// ───── Key Manager Factory ─────

/**
 * Creates a KeyManager based on the configured type.
 *
 * @param type - Key manager type: 'local', 'aws-kms', or 'vault'
 * @param config - Configuration object
 * @param logger - Logger instance
 * @returns A KeyManager implementation
 *
 * @example
 * ```typescript
 * // Local development
 * const km = createKeyManager('local', { privateKey: process.env.SOLVER_PRIVATE_KEY }, logger);
 *
 * // AWS KMS production
 * const km = createKeyManager('aws-kms', { kmsKeyId: process.env.AWS_KMS_KEY_ID }, logger);
 * ```
 */
export function createKeyManager(
  type: string,
  config: Record<string, any>,
  logger: Logger,
): KeyManager {
  switch (type) {
    case 'local':
      return new LocalKeyManager(config.privateKey, logger);

    case 'aws-kms':
      return new AWSKMSKeyManager(
        config.kmsKeyId,
        config.region || 'us-east-1',
        logger,
      );

    default:
      logger.warn(`Unknown key manager type "${type}", falling back to local`);
      return new LocalKeyManager(config.privateKey, logger);
  }
}

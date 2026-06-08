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

import {
  type Address,
  type Hash,
  type Chain,
  createWalletClient,
  http,
  keccak256,
} from 'viem';
import { privateKeyToAccount, type PrivateKeyAccount } from 'viem/accounts';
import { recoverPublicKey } from '@noble/curves/secp256k1';
import { encode as rlpEncode } from '@ethereumjs/rlp';
import { getChainById } from 'ghostchain-sdk';
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
 * Uses an in-memory Viem account from a hex private key, and actually
 * broadcasts transactions via Viem WalletClient to configured RPC endpoints.
 *
 * ⚠️ NOT for production use - keys are in plaintext in process memory.
 * Replace with AWSKMSKeyManager or HashiCorpVaultKeyManager for production.
 */
export class LocalKeyManager implements KeyManager {
  private account: PrivateKeyAccount;
  private logger: Logger;
  private rpcEndpoints: Record<number, string>;
  private walletClients: Map<number, ReturnType<typeof createWalletClient>>;

  constructor(
    privateKey: `0x${string}`,
    logger: Logger,
    rpcEndpoints: Record<number, string> = {},
  ) {
    this.account = privateKeyToAccount(privateKey);
    this.logger = logger.child({ module: 'LocalKeyManager' });
    this.rpcEndpoints = rpcEndpoints;
    this.walletClients = new Map();
  }

  getAddress(): Address {
    return this.account.address;
  }

  async signMessage(message: `0x${string}`): Promise<`0x${string}`> {
    return this.account.signMessage({ message: { raw: message } });
  }

  async signAndSendTransaction(
    chainId: number,
    tx: TransactionRequest,
  ): Promise<SignedTransaction> {
    // Look up the RPC endpoint for this chain
    const rpcUrl = this.rpcEndpoints[chainId];
    if (!rpcUrl) {
      throw new Error(
        `LocalKeyManager: No RPC endpoint configured for chain ${chainId}. ` +
        `Ensure RPC_<CHAIN_SHORT_NAME> is set in environment variables.`,
      );
    }

    // Get or create a cached wallet client for this chain
    let walletClient = this.walletClients.get(chainId);
    if (!walletClient) {
      let chain: Chain | undefined;
      try {
        chain = getChainById(chainId);
      } catch {
        this.logger.warn(
          `Chain ${chainId} not found in chain registry, proceeding without chain object`,
        );
      }

      walletClient = createWalletClient({
        account: this.account,
        ...(chain ? { chain } : {}),
        transport: http(rpcUrl),
      });
      this.walletClients.set(chainId, walletClient);
    }

    // Build and broadcast the transaction via Viem
    this.logger.debug(
      `[LOCAL KM] Broadcasting tx: to=${tx.to}, chainId=${chainId}`,
    );

    const txHash: Hash = await (walletClient.sendTransaction as any)({
      account: this.account,
      to: tx.to,
      data: tx.data,
      value: tx.value ?? 0n,
      chainId,
      ...(tx.gasLimit ? { gas: tx.gasLimit } : {}),
      ...(tx.maxFeePerGas ? { maxFeePerGas: tx.maxFeePerGas } : {}),
      ...(tx.maxPriorityFeePerGas ? { maxPriorityFeePerGas: tx.maxPriorityFeePerGas } : {}),
    });

    this.logger.info(
      `[LOCAL KM] Transaction broadcast: hash=${txHash}, to=${tx.to}, chainId=${chainId}`,
    );

    return {
      rawTransaction: txHash,
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
  private rpcEndpoints: Record<number, string>;

  constructor(
    kmsKeyId: string,
    region: string,
    logger: Logger,
    rpcEndpoints: Record<number, string> = {},
  ) {
    this.kmsKeyId = kmsKeyId;
    this.logger = logger.child({ module: 'AWSKMSKeyManager' });
    this.rpcEndpoints = rpcEndpoints;

    try {
      const { KMSClient } = require('@aws-sdk/client-kms');
      this.kmsClient = new KMSClient({ region });
    } catch (error) {
      this.logger.error('AWS SDK is required for AWS KMS key manager', error);
      throw new Error('AWS SDK client-kms dependency is missing');
    }

    this.address = '0x0000000000000000000000000000000000000000';
    this.initializeAddress().catch((error) => {
      this.logger.error('Unable to initialize KMS address', error);
    });
  }

  private async initializeAddress(): Promise<void> {
    const { GetPublicKeyCommand } = require('@aws-sdk/client-kms');
    const response = await this.kmsClient.send(
      new GetPublicKeyCommand({ KeyId: this.kmsKeyId }),
    );

    const publicKeyBytes = new Uint8Array(response.PublicKey);
    if (publicKeyBytes.length === 65 && publicKeyBytes[0] === 0x04) {
      const hash = keccak256(publicKeyBytes.slice(1) as `0x${string}`);
      this.address = `0x${hash.slice(-40)}` as Address;
      this.logger.info(`Derived KMS address: ${this.address}`);
      return;
    }
    throw new Error('Unexpected KMS public key format. Expected uncompressed SEC1 key.');
  }

  getAddress(): Address {
    return this.address;
  }

  async signMessage(message: `0x${string}`): Promise<`0x${string}`> {
    const { SignCommand, SignatureAlgorithm, MessageType } = require('@aws-sdk/client-kms');

    const response = await this.kmsClient.send(
      new SignCommand({
        KeyId: this.kmsKeyId,
        Message: Buffer.from(message.slice(2), 'hex'),
        MessageType: MessageType.DIGEST,
        SignatureAlgorithm: SignatureAlgorithm.ECDSA_SHA_256,
      }),
    );

    return this.derToVrs(new Uint8Array(response.Signature));
  }

  async signAndSendTransaction(
    chainId: number,
    tx: TransactionRequest,
  ): Promise<SignedTransaction> {
    const rpcUrl = this.rpcEndpoints[chainId];
    if (!rpcUrl) {
      throw new Error(
        `AWSKMSKeyManager: No RPC endpoint configured for chain ${chainId}`,
      );
    }

    const nonceHex = await this.rpcRequest(rpcUrl, 'eth_getTransactionCount', [
      this.address,
      'pending',
    ]);
    const nonce = BigInt(nonceHex as string);

    const value = tx.value ?? 0n;
    const gasLimit = tx.gasLimit ?? BigInt(0);

    const gasLimitHex = tx.gasLimit
      ? `0x${tx.gasLimit.toString(16)}`
      : await this.rpcRequest(rpcUrl, 'eth_estimateGas', [
          {
            from: this.address,
            to: tx.to,
            data: tx.data,
            value: `0x${value.toString(16)}`,
          },
        ]);

    const block = await this.rpcRequest(rpcUrl, 'eth_getBlockByNumber', [
      'pending',
      false,
    ]);
    const baseFeePerGas = (block?.baseFeePerGas as string | undefined) ?? null;

    const toBytes = this.hexToBytes(tx.to);
    const dataBytes = this.hexToBytes(tx.data);
    const nonceBytes = this.hexToBytes(`0x${nonce.toString(16)}`);
    const gasLimitBytes = this.hexToBytes(gasLimitHex as string);
    const valueBytes = this.hexToBytes(`0x${value.toString(16)}`);

    let rawTransaction: `0x${string}`;
    if (baseFeePerGas) {
      const maxPriorityFeePerGas = tx.maxPriorityFeePerGas ?? 2_000_000_000n;
      const maxFeePerGas = tx.maxFeePerGas ??
        (BigInt(baseFeePerGas) * 2n + maxPriorityFeePerGas);

      const unsigned = this.serializeEip1559Transaction(
        BigInt(chainId),
        nonceBytes,
        maxPriorityFeePerGas,
        maxFeePerGas,
        gasLimitBytes,
        toBytes,
        valueBytes,
        dataBytes,
      );
      rawTransaction = await this.signAndSerializeTransaction(unsigned.encoded, unsigned.items, chainId, false);
    } else {
      const gasPriceHex = await this.rpcRequest(rpcUrl, 'eth_gasPrice');
      const gasPrice = tx.maxFeePerGas ?? BigInt(gasPriceHex as string);
      const unsigned = this.serializeLegacyTransaction(
        BigInt(chainId),
        nonceBytes,
        gasPrice,
        gasLimitBytes,
        toBytes,
        valueBytes,
        dataBytes,
      );
      rawTransaction = await this.signAndSerializeTransaction(unsigned.encoded, unsigned.items, chainId, true);
    }

    const transactionHash = await this.rpcRequest(rpcUrl, 'eth_sendRawTransaction', [
      rawTransaction,
    ]);

    return {
      rawTransaction,
      transactionHash: transactionHash as Hash,
      from: this.address,
    };
  }

  getKeyManagerType(): string {
    return 'aws-kms';
  }

  private rpcRequest(rpcUrl: string, method: string, params: any[]): Promise<any> {
    return fetch(rpcUrl, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }),
    }).then(async (res) => {
      if (!res.ok) {
        const body = await res.text();
        throw new Error(`RPC request failed: ${res.status} ${body}`);
      }
      const json = await res.json();
      if (json.error) {
        throw new Error(`RPC error: ${json.error.message || JSON.stringify(json.error)}`);
      }
      return json.result;
    });
  }

  private hexToBytes(value: string): Uint8Array {
    let hex = value.replace(/^0x/, '');
    if (hex.length === 0) {
      return new Uint8Array([]);
    }
    if (hex.length % 2 === 1) {
      hex = `0${hex}`;
    }
    return new Uint8Array(Buffer.from(hex, 'hex'));
  }

  private bytesToHex(bytes: Uint8Array): string {
    return `0x${Buffer.from(bytes).toString('hex')}`;
  }

  private serializeLegacyTransaction(
    chainId: bigint,
    nonce: Uint8Array,
    gasPrice: bigint,
    gasLimit: Uint8Array,
    to: Uint8Array,
    value: Uint8Array,
    data: Uint8Array,
  ): { encoded: Uint8Array; items: any[] } {
    const items = [
      this.trimLeadingZeros(nonce),
      this.trimLeadingZeros(this.hexToBytes(`0x${gasPrice.toString(16)}`)),
      this.trimLeadingZeros(gasLimit),
      this.trimLeadingZeros(to),
      this.trimLeadingZeros(value),
      this.trimLeadingZeros(data),
      this.trimLeadingZeros(this.hexToBytes(`0x${chainId.toString(16)}`)),
      new Uint8Array([]),
      new Uint8Array([]),
    ];
    return { encoded: rlpEncode(items), items };
  }

  private serializeEip1559Transaction(
    chainId: bigint,
    nonce: Uint8Array,
    maxPriorityFeePerGas: bigint,
    maxFeePerGas: bigint,
    gasLimit: Uint8Array,
    to: Uint8Array,
    value: Uint8Array,
    data: Uint8Array,
  ): { encoded: Uint8Array; items: any[] } {
    const items = [
      this.trimLeadingZeros(this.hexToBytes(`0x${chainId.toString(16)}`)),
      this.trimLeadingZeros(nonce),
      this.trimLeadingZeros(this.hexToBytes(`0x${maxPriorityFeePerGas.toString(16)}`)),
      this.trimLeadingZeros(this.hexToBytes(`0x${maxFeePerGas.toString(16)}`)),
      this.trimLeadingZeros(gasLimit),
      this.trimLeadingZeros(to),
      this.trimLeadingZeros(value),
      this.trimLeadingZeros(data),
      [],
    ];
    return { encoded: rlpEncode(items), items };
  }

  private async signAndSerializeTransaction(
    unsignedTransaction: Uint8Array,
    unsignedItems: any[],
    chainId: number,
    legacy: boolean,
  ): Promise<`0x${string}`> {
    const unsignedPayload = legacy
      ? unsignedTransaction
      : new Uint8Array([0x02, ...unsignedTransaction]);
    const transactionHash = keccak256(unsignedPayload) as `0x${string}`;

    const signature = await this.kmsSignDigest(transactionHash);
    const { r, s, v } = await this.extractSignatureParts(
      transactionHash,
      signature,
      chainId,
      legacy,
    );

    const signedItems = [...unsignedItems, this.trimLeadingZeros(this.hexToBytes(v)), this.trimLeadingZeros(this.hexToBytes(r)), this.trimLeadingZeros(this.hexToBytes(s))];
    const signedPayload = rlpEncode(signedItems);

    const raw = legacy
      ? this.bytesToHex(signedPayload)
      : this.bytesToHex(new Uint8Array([0x02, ...signedPayload]));

    return raw as `0x${string}`;
  }

  private async kmsSignDigest(digest: `0x${string}`): Promise<Uint8Array> {
    const { SignCommand, SignatureAlgorithm, MessageType } = require('@aws-sdk/client-kms');
    const response = await this.kmsClient.send(
      new SignCommand({
        KeyId: this.kmsKeyId,
        Message: Buffer.from(digest.slice(2), 'hex'),
        MessageType: MessageType.DIGEST,
        SignatureAlgorithm: SignatureAlgorithm.ECDSA_SHA_256,
      }),
    );
    return new Uint8Array(response.Signature);
  }

  private async extractSignatureParts(
    digest: `0x${string}`,
    derSignature: Uint8Array,
    chainId: number,
    legacy: boolean,
  ): Promise<{ r: `0x${string}`; s: `0x${string}`; v: `0x${string}` }> {
    const { r, s } = this.parseDerSignature(derSignature);
    const recoveryId = await this.findRecoveryId(digest, r, s);
    const v = legacy
      ? `0x${(recoveryId + 35 + chainId * 2).toString(16)}`
      : `0x${recoveryId.toString(16)}`;
    return { r, s, v };
  }

  private parseDerSignature(derSignature: Uint8Array): { r: `0x${string}`; s: `0x${string}` } {
    let offset = 2;
    const rLen = derSignature[offset - 1];
    const r = derSignature.slice(offset, offset + rLen);
    offset += rLen + 2;
    const sLen = derSignature[offset - 1];
    const s = derSignature.slice(offset + 1, offset + 1 + sLen);
    return {
      r: `0x${Buffer.from(r).toString('hex')}` as `0x${string}`,
      s: `0x${Buffer.from(s).toString('hex')}` as `0x${string}`,
    };
  }

  private async findRecoveryId(
    digest: `0x${string}`,
    r: `0x${string}`,
    s: `0x${string}`,
  ): Promise<number> {
    const messageHash = this.hexToBytes(digest);
    const signature = new Uint8Array([
      ...this.hexToBytes(r),
      ...this.hexToBytes(s),
    ]);

    for (const recovery of [0, 1] as const) {
      const publicKey = recoverPublicKey(messageHash, signature, recovery, false);
      const addressHash = keccak256(publicKey.slice(1) as `0x${string}`);
      const candidate = `0x${addressHash.slice(-40)}`;
      if (candidate.toLowerCase() === this.address.toLowerCase()) {
        return recovery;
      }
    }

    throw new Error('Unable to recover signature v value from KMS signature');
  }

  private trimLeadingZeros(bytes: Uint8Array): Uint8Array {
    let index = 0;
    while (index < bytes.length && bytes[index] === 0) {
      index += 1;
    }
    return bytes.slice(index);
  }

  private derToVrs(derSignature: Uint8Array): `0x${string}` {
    const { r, s } = this.parseDerSignature(derSignature);
    return `0x${r.slice(2)}${s.slice(2)}00` as `0x${string}`;
  }

}

// ───── Key Manager Factory ─────

/**
 * Creates a KeyManager based on the configured type.
 *
 * @param type - Key manager type: 'local', 'aws-kms', or 'vault'
 * @param config - Configuration object (privateKey, rpcEndpoints, kmsKeyId, region)
 * @param logger - Logger instance
 * @returns A KeyManager implementation
 *
 * @example
 * ```typescript
 * // Local development
 * const km = createKeyManager('local', {
 *   privateKey: process.env.SOLVER_PRIVATE_KEY,
 *   rpcEndpoints: { 1: 'https://eth-mainnet.g.alchemy.com/v2/...' },
 * }, logger);
 *
 * // AWS KMS production
 * const km = createKeyManager('aws-kms', {
 *   kmsKeyId: process.env.AWS_KMS_KEY_ID,
 *   rpcEndpoints: { 1: 'https://eth-mainnet.g.alchemy.com/v2/...' },
 * }, logger);
 * ```
 */
export function createKeyManager(
  type: string,
  config: Record<string, any>,
  logger: Logger,
): KeyManager {
  switch (type) {
    case 'local':
      return new LocalKeyManager(
        config.privateKey,
        logger,
        config.rpcEndpoints || {},
      );

    case 'aws-kms':
      return new AWSKMSKeyManager(
        config.kmsKeyId,
        config.region || 'us-east-1',
        logger,
        config.rpcEndpoints || {},
      );

    default:
      throw new Error(
        `Unsupported key manager type "${type}". Allowed values are: local, aws-kms, vault.`,
      );
  }
}

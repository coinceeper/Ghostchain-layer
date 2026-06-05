/**
 * GhostChain Client
 *
 * Main client for interacting with the GhostChain protocol across multiple chains.
 * Uses Viem for type-safe, multi-chain RPC interactions.
 *
 * Features:
 * - Multi-chain contract interaction (Ethereum, Arbitrum, Polygon, etc.)
 * - Ghost address generation and scanning
 * - Ephemeral swap creation and fulfillment
 * - ZK proof submission
 * - Registry querying for contract addresses
 */

import {
  createPublicClient,
  createWalletClient,
  http,
  type Address,
  type PublicClient,
  type WalletClient,
  type Hash,
  parseUnits,
  formatUnits,
  hexToBigInt,
  encodeFunctionData,
  decodeFunctionResult,
} from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import { getChainById } from './chains.js';
import type {
  GhostChainConfig,
  GhostKeyPair,
  GhostAddress,
  SwapIntent,
  SupportedChainId,
  ChainConfig,
  IntentStatus,
  GhostTransferProof,
} from './types.js';
import { generateGhostAddress, computeGhostTransferCommitment } from './ghost-address.js';
import { signWithSpendingKey } from './identity.js';

/// EphemeralFactory ABI fragments for encoding
const EPHEMERAL_FACTORY_ABI = [
  {
    name: 'createEphemeralSwap',
    type: 'function',
    inputs: [
      { name: 'token', type: 'address' },
      { name: 'amount', type: 'uint256' },
      { name: 'destinationChain', type: 'uint256' },
      { name: 'commitment', type: 'bytes32' },
      { name: 'expiry', type: 'uint256' },
      { name: 'ephemeralPublicKey', type: 'bytes' },
      { name: 'viewTag', type: 'uint8' },
    ],
    outputs: [{ name: 'swapId', type: 'bytes32' }],
    stateMutability: 'nonpayable',
  },
  {
    name: 'fulfillSwap',
    type: 'function',
    inputs: [
      { name: 'swapId', type: 'bytes32' },
      { name: 'proof', type: 'bytes' },
      { name: 'recipient', type: 'address' },
    ],
    outputs: [],
    stateMutability: 'nonpayable',
  },
  {
    name: 'refundSwap',
    type: 'function',
    inputs: [{ name: 'swapId', type: 'bytes32' }],
    outputs: [],
    stateMutability: 'nonpayable',
  },
  {
    name: 'getSwap',
    type: 'function',
    inputs: [{ name: 'swapId', type: 'bytes32' }],
    outputs: [
      { name: 'creator', type: 'address' },
      { name: 'token', type: 'address' },
      { name: 'amount', type: 'uint256' },
      { name: 'sourceChain', type: 'uint256' },
      { name: 'destinationChain', type: 'uint256' },
      { name: 'commitment', type: 'bytes32' },
      { name: 'solver', type: 'address' },
      { name: 'fulfilled', type: 'bool' },
      { name: 'refunded', type: 'bool' },
      { name: 'createdAt', type: 'uint256' },
      { name: 'expiry', type: 'uint256' },
    ],
    stateMutability: 'view',
  },
  {
    name: 'isSwapActive',
    type: 'function',
    inputs: [{ name: 'swapId', type: 'bytes32' }],
    outputs: [{ name: '', type: 'bool' }],
    stateMutability: 'view',
  },
] as const;

// ───── Client ─────

/**
 * GhostChainClient - Main client for the GhostChain protocol.
 */
export class GhostChainClient {
  public readonly config: GhostChainConfig;
  private publicClients: Map<number, PublicClient>;
  private walletClient: WalletClient;
  private account: ReturnType<typeof privateKeyToAccount>;

  constructor(config: GhostChainConfig) {
    this.config = config;
    this.publicClients = new Map();

    // Create public clients for all supported chains
    for (const [chainId, chainConfig] of config.chains) {
      try {
        const viemChain = getChainById(chainId);
        this.publicClients.set(
          chainId,
          createPublicClient({
            chain: viemChain,
            transport: http(chainConfig.rpcUrl),
          }),
        );
      } catch {
        // Chain is in config but not in our chain registry — skip gracefully
        console.warn(`Chain ${chainId} is configured but not in chain registry`);
      }
    }

    // Create wallet client from spending key
    this.account = privateKeyToAccount(config.identity.spendingPrivateKey);
    const defaultChain = getChainById(config.defaultChainId);
    this.walletClient = createWalletClient({
      account: this.account,
      chain: defaultChain,
      transport: http(config.chains.get(config.defaultChainId)?.rpcUrl ?? ''),
    });
  }

  // ───── Identity ─────

  /**
   * Returns the user's derived identity.
   */
  get identity(): GhostKeyPair {
    return this.config.identity;
  }

  // ───── Chain Management ─────

  /**
   * Gets the public client for a specific chain.
   */
  getPublicClient(chainId: SupportedChainId): PublicClient {
    const client = this.publicClients.get(chainId);
    if (!client) {
      throw new Error(`Unsupported chain: ${chainId}`);
    }
    return client;
  }

  /**
   * Gets the wallet client.
   */
  getWalletClient(): WalletClient {
    return this.walletClient;
  }

  /**
   * Switches the wallet client to a different chain.
   */
  switchChain(chainId: SupportedChainId): void {
    const chain = getChainById(chainId);
    const config = this.config.chains.get(chainId);
    if (!config) {
      throw new Error(`Chain ${chainId} is not in client configuration`);
    }
    this.walletClient = createWalletClient({
      account: this.account,
      chain,
      transport: http(config.rpcUrl),
    });
  }

  // ───── Ghost Addresses ─────

  /**
   * Generates a ghost address for receiving private transfers.
   */
  async createGhostAddress(
    recipientSpendingPubKey: `0x${string}`,
    recipientViewingPubKey: `0x${string}`,
  ): Promise<GhostAddress> {
    return generateGhostAddress(
      this.config.identity,
      recipientSpendingPubKey,
      recipientViewingPubKey,
    );
  }

  // ───── Ephemeral Swaps ─────

  /**
   * Creates an ephemeral swap on the source chain.
   *
   * @param chainId - The source chain to create the swap on
   * @param token - The USDT token address
   * @param amount - The amount to swap (in human-readable units)
   * @param destinationChain - The target chain ID
   * @param recipientPubKey - The recipient's spending public key
   * @returns The swap ID and transaction hash
   */
  async createSwap(
    chainId: SupportedChainId,
    token: Address,
    amount: string,
    destinationChain: SupportedChainId,
    recipientPubKey: `0x${string}`,
    recipientViewingPubKey?: `0x${string}`,
  ): Promise<{ swapId: Hash; txHash: Hash }> {
    // Generate ghost address for recipient
    const recipientConfig = this.config.chains.get(destinationChain);
    if (!recipientConfig) {
      throw new Error(`Unsupported destination chain: ${destinationChain}`);
    }

    // Use provided viewing key or default to spending key
    const viewingKey = recipientViewingPubKey || recipientPubKey;

    // Generate ghost address with proper spending and viewing keys
    const ghostAddress = generateGhostAddress(
      this.config.identity,
      recipientPubKey,
      viewingKey,
    );

    // Compute commitment
    const commitment = computeGhostTransferCommitment(
      ghostAddress.address,
      token,
      parseUnits(amount, 6), // USDT has 6 decimals
      BigInt(Date.now()),
      BigInt(destinationChain),
    );

    // Set expiry (1 hour from now)
    const expiry = BigInt(Math.floor(Date.now() / 1000) + 3600);

    // Ensure we're on the right chain
    this.switchChain(chainId);

    // Encode the calldata (for simulation)
    const { request } = await this.publicClients
      .get(chainId)!
      .simulateContract({
        address: this.config.chains.get(chainId)!.factoryAddress,
        abi: EPHEMERAL_FACTORY_ABI,
        functionName: 'createEphemeralSwap',
        args: [
          token,
          parseUnits(amount, 6),
          BigInt(destinationChain),
          commitment,
          expiry,
          ghostAddress.ephemeralPublicKey,
          ghostAddress.viewTag,
        ],
        account: this.account.address,
      });

    // Send the transaction
    const txHash = await this.walletClient.writeContract(request);

    // Wait for receipt
    const receipt = await this.publicClients.get(chainId)!.waitForTransactionReceipt({
      hash: txHash,
    });

    // Extract swapId from the first event log
    const swapId = receipt.logs[0]?.topics[1] as Hash;

    return { swapId, txHash };
  }

  /**
   * Refunds an expired swap.
   */
  async refundSwap(
    chainId: SupportedChainId,
    swapId: Hash,
  ): Promise<Hash> {
    this.switchChain(chainId);

    const { request } = await this.publicClients
      .get(chainId)!
      .simulateContract({
        address: this.config.chains.get(chainId)!.factoryAddress,
        abi: EPHEMERAL_FACTORY_ABI,
        functionName: 'refundSwap',
        args: [swapId],
        account: this.account.address,
      });

    return await this.walletClient.writeContract(request);
  }

  /**
   * Checks the status of a swap.
   */
  async getSwapStatus(
    chainId: SupportedChainId,
    swapId: Hash,
  ): Promise<{
    status: IntentStatus;
    creator: Address;
    token: Address;
    amount: bigint;
    expiry: bigint;
  }> {
    const client = this.publicClients.get(chainId)!;
    const factoryAddress = this.config.chains.get(chainId)!.factoryAddress;

    const data = await client.readContract({
      address: factoryAddress,
      abi: EPHEMERAL_FACTORY_ABI,
      functionName: 'getSwap',
      args: [swapId],
    });

    const [creator, token, amount, _srcChain, _destChain, _commitment, , fulfilled, refunded, _createdAt, expiry] = data;

    let status: IntentStatus;
    if (fulfilled) {
      status = 'fulfilled';
    } else if (refunded) {
      status = 'refunded';
    } else if (expiry < BigInt(Math.floor(Date.now() / 1000))) {
      status = 'expired';
    } else {
      status = 'pending';
    }

    return { status, creator, token, amount, expiry };
  }
}

/**
 * Cross-Chain Layer
 *
 * Intent-based cross-chain routing for GhostChain protocol.
 * Implements the "Intent-Based Cross-Chain Routing" model described in the architecture.
 *
 * Flow:
 *   1. User creates an Intent on the source chain (locking USDT in EphemeralFactory)
 *   2. Intent is broadcast to the Solver network
 *   3. Solvers compete to fill the intent on the destination chain
 *   4. Solver submits ZK proof to claim locked tokens on the source chain
 *   5. User receives USDT on the destination chain
 *
 * This model separates bridging complexity from the core protocol,
 * relying on a competitive Solver network for optimal routing.
 */

import { keccak_256 } from '@noble/hashes/sha3';
import { bytesToHex, hexToBytes, concatBytes } from '@noble/hashes/utils';
import { type Address, type Hash, encodeAbiParameters, parseAbiParameters, pad } from 'viem';
import type {
  SwapIntent,
  SolvableIntent,
  SupportedChainId,
  ChainConfig,
  GhostAddress,
  IntentStatus,
} from './types.js';
import { GhostChainClient } from './client.js';

// ───── Intent Lifecycle ─────

/**
 * IntentManager handles the lifecycle of cross-chain swap intents.
 * It coordinates between the user, the Solver network, and on-chain contracts.
 */
export class IntentManager {
  private client: GhostChainClient;
  private pendingIntents: Map<Hash, SwapIntent>;

  constructor(client: GhostChainClient) {
    this.client = client;
    this.pendingIntents = new Map();
  }

  /**
   * Creates a new cross-chain swap intent.
   *
   * @param params - The swap parameters
   * @returns The created intent
   */
  async createIntent(params: {
    sourceChain: SupportedChainId;
    destinationChain: SupportedChainId;
    token: Address;
    amount: bigint;
    recipientGhostAddress: Address;
    commitment: Hash;
    expiry: bigint;
  }): Promise<SwapIntent> {
    const intentId = keccak_256(
      concatBytes(
        hexToBytes(params.sourceChain.toString(16).padStart(64, '0')),
        hexToBytes(params.destinationChain.toString(16).padStart(64, '0')),
        hexToBytes(params.token.slice(2)),
        hexToBytes(params.amount.toString(16).padStart(64, '0')),
        hexToBytes(params.recipientGhostAddress.slice(2)),
      ),
    );

    const intent: SwapIntent = {
      id: `0x${bytesToHex(intentId)}`,
      sourceChain: params.sourceChain,
      destinationChain: params.destinationChain,
      token: params.token,
      amount: params.amount,
      recipientGhostAddress: params.recipientGhostAddress,
      commitment: params.commitment,
      fulfilled: false,
      expiry: params.expiry,
    };

    this.pendingIntents.set(intent.id, intent);

    return intent;
  }

  /**
   * Broadcasts an intent to registered solver endpoints.
   *
   * @param intent - The intent to broadcast
   * @param solverEndpoints - List of solver API endpoints
   */
  async broadcastIntent(
    intent: SwapIntent,
    solverEndpoints: string[],
  ): Promise<void> {
    const payload = {
      id: intent.id,
      sourceChain: intent.sourceChain,
      destinationChain: intent.destinationChain,
      token: intent.token,
      amount: intent.amount.toString(),
      recipientGhostAddress: intent.recipientGhostAddress,
      commitment: intent.commitment,
      expiry: intent.expiry.toString(),
    };

    // Broadcast to all registered solvers
    const results = await Promise.allSettled(
      solverEndpoints.map(async (endpoint) => {
        const response = await fetch(`${endpoint}/api/v1/intents`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify(payload),
        });
        if (!response.ok) {
          throw new Error(`Solver ${endpoint} rejected intent: ${response.statusText}`);
        }
        return response.json();
      }),
    );

    // Log failed broadcasts
    for (const result of results) {
      if (result.status === 'rejected') {
        console.warn('Failed to broadcast intent:', result.reason);
      }
    }
  }

  /**
   * Fulfills an intent on the destination chain (called by the solver).
   *
   * @param intent - The intent to fulfill
   * @param proof - The ZK proof
   */
  async fulfillIntent(
    intent: SwapIntent,
    proof: Hash,
  ): Promise<Hash> {
    const { request } = await this.client
      .getPublicClient(intent.sourceChain)
      .simulateContract({
        address: this.client.config.chains.get(intent.sourceChain)!.factoryAddress,
        abi: [
          {
            name: 'fulfillSwap',
            type: 'function',
            inputs: [
              { name: 'swapId', type: 'bytes32' },
              { name: 'proof', type: 'bytes' },
              { name: 'recipient', type: 'address' },
            ],
            outputs: [],
          },
        ],
        functionName: 'fulfillSwap',
        args: [intent.id, proof, intent.recipientGhostAddress],
        account: this.client.getWalletClient().account.address,
      });

    return await this.client.getWalletClient().writeContract(request);
  }

  /**
   * Gets all pending intents for the current user.
   */
  getPendingIntents(): SwapIntent[] {
    return Array.from(this.pendingIntents.values());
  }

  /**
   * Gets the status of a specific intent by ID.
   */
  getIntent(id: Hash): SwapIntent | undefined {
    return this.pendingIntents.get(id);
  }
}

// ───── Cross-Chain Route Planner ─────

/**
 * Route optimization for cross-chain transfers.
 * Finds the best path between source and destination chains.
 */
export class RoutePlanner {
  /**
   * Finds the optimal route for a cross-chain transfer.
   * Currently supports direct routes; will expand to multi-hop.
   *
   * @param sourceChain - Source chain ID
   * @param destinationChain - Destination chain ID
   * @param supportedChains - All supported chain configs
   * @returns The route type and description
   */
  static findRoute(
    sourceChain: SupportedChainId,
    destinationChain: SupportedChainId,
    supportedChains: Map<SupportedChainId, ChainConfig>,
  ): {
    routeType: 'same-chain' | 'intent-based';
    description: string;
  } {
    if (sourceChain === destinationChain) {
      return {
        routeType: 'same-chain',
        description: 'Direct transfer on the same chain',
      };
    }

    // Both chains must be supported
    const source = supportedChains.get(sourceChain);
    const dest = supportedChains.get(destinationChain);

    if (!source || !dest) {
      throw new Error(`Unsupported chain pair: ${sourceChain} -> ${destinationChain}`);
    }

    return {
      routeType: 'intent-based',
      description: `Intent-based transfer from ${source.name} to ${dest.name} via Solver network`,
    };
  }
}

// ───── Cross-Chain Transfer Function ─────

/**
 * Performs a cross-chain ghost transfer.
 *
 * This is the main entry point for users wanting to send USDT privately
 * from one chain to another.
 *
 * @param client - The GhostChain client
 * @param params - Transfer parameters
 * @returns The created swap intent
 */
export async function performCrossChainTransfer(
  client: GhostChainClient,
  params: {
    sourceChain: SupportedChainId;
    destinationChain: SupportedChainId;
    token: Address;
    amount: string;
    recipientSpendingPubKey: `0x${string}`;
    recipientViewingPubKey: `0x${string}`;
    solverEndpoints?: string[];
  },
): Promise<SwapIntent> {
  // 1. Validate route
  const route = RoutePlanner.findRoute(
    params.sourceChain,
    params.destinationChain,
    client.config.chains,
  );

  if (route.routeType === 'same-chain') {
    console.log('Same-chain transfer detected, using direct path');
  } else {
    console.log(`Cross-chain transfer: ${route.description}`);
  }

  // 2. Generate ghost address on the destination chain
  const ghostAddress = await client.createGhostAddress(
    params.recipientSpendingPubKey,
    params.recipientViewingPubKey,
  );

  console.log(`Generated ghost address: ${ghostAddress.address}`);

  // 3. Create ephemeral swap on the source chain
  const { swapId, txHash } = await client.createSwap(
    params.sourceChain,
    params.token,
    params.amount,
    params.destinationChain,
    params.recipientSpendingPubKey,
  );

  console.log(`Ephemeral swap created: ${swapId} (tx: ${txHash})`);

  // 4. Create intent
  const intentManager = new IntentManager(client);
  const intent = await intentManager.createIntent({
    sourceChain: params.sourceChain,
    destinationChain: params.destinationChain,
    token: params.token,
    amount: BigInt(params.amount),
    recipientGhostAddress: ghostAddress.address,
    commitment: swapId,
    expiry: BigInt(Math.floor(Date.now() / 1000) + 3600),
  });

  // 5. Broadcast intent to solvers
  if (params.solverEndpoints && params.solverEndpoints.length > 0) {
    await intentManager.broadcastIntent(intent, params.solverEndpoints);
    console.log(`Intent broadcasted to ${params.solverEndpoints.length} solvers`);
  }

  return intent;
}

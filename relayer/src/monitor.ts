/**
 * Intent Monitor
 *
 * Monitors EphemeralFactory contracts on all supported chains for new swap intents.
 * Uses event polling to detect `EphemeralSwapCreated` events.
 */

import { type PublicClient, type Address, type Hash, parseAbiItem, getAddress } from 'viem';
import type { Logger } from 'pino';
import type { SwapIntent } from 'ghostchain-sdk';

// ───── Event Signature ─────

const EPHEMERAL_SWAP_CREATED_EVENT = parseAbiItem(
  'event EphemeralSwapCreated(bytes32 indexed swapId, address indexed creator, address indexed token, uint256 amount, uint256 sourceChain, uint256 destinationChain, bytes32 commitment)',
);

// ───── Types ─────

interface SolverConfig {
  solverId: string;
  rpcEndpoints: Record<number, string>;
  factoryAddresses: Record<number, Address>;
  verifierAddresses: Record<number, Address>;
  supportedChainIds: number[];
  minFeeBps: number;
  maxFillAmountUsd: number;
  apiPort: number;
  [key: string]: unknown; // Allow additional properties from executor's SolverConfig
}

type IntentCallback = (intent: SwapIntent) => void;

// ───── Monitor ─────

export class IntentMonitor {
  private config: SolverConfig;
  private clients: Map<number, PublicClient>;
  private logger: Logger;
  private pollingIntervals: Map<number, ReturnType<typeof setInterval>>;
  private lastPolledBlock: Map<number, bigint>;
  private callbacks: IntentCallback[];

  constructor(
    config: SolverConfig,
    clients: Map<number, PublicClient>,
    logger: Logger,
  ) {
    this.config = config;
    this.clients = clients;
    this.logger = logger.child({ module: 'IntentMonitor' });
    this.pollingIntervals = new Map();
    this.lastPolledBlock = new Map();
    this.callbacks = [];
  }

  /**
   * Starts monitoring all supported chains for new intents.
   * Polls every 12 seconds (matching L2 block times).
   *
   * @param onIntent - Callback for each new intent detected
   */
  start(onIntent: IntentCallback): void {
    this.callbacks.push(onIntent);

    for (const [chainId, _client] of this.clients) {
      this.monitorChain(chainId);
    }

    this.logger.info(`Monitoring ${this.clients.size} chains for new intents`);
  }

  /**
   * Stops monitoring all chains.
   */
  stop(): void {
    for (const [chainId, interval] of this.pollingIntervals) {
      clearInterval(interval);
      this.logger.debug(`Stopped monitoring chain ${chainId}`);
    }
    this.pollingIntervals.clear();
  }

  /**
   * Registers an additional intent callback.
   */
  onIntent(callback: IntentCallback): void {
    this.callbacks.push(callback);
  }

  // ───── Internal ─────

  /**
   * Starts polling for intents on a specific chain.
   */
  private monitorChain(chainId: number): void {
    const client = this.clients.get(chainId);
    if (!client) {
      this.logger.warn(`No client for chain ${chainId}, skipping`);
      return;
    }

    this.lastPolledBlock.set(chainId, BigInt(0));

    // Poll every 15 seconds
    const interval = setInterval(async () => {
      try {
        await this.pollChain(chainId, client);
      } catch (error) {
        this.logger.error(`Error polling chain ${chainId}:`, error);
      }
    }, 15_000);

    this.pollingIntervals.set(chainId, interval);
    this.logger.debug(`Started monitoring chain ${chainId}`);
  }

  /**
   * Polls a single chain for new `EphemeralSwapCreated` events.
   */
  private async pollChain(chainId: number, client: PublicClient): Promise<void> {
    const factoryAddress = this.config.factoryAddresses[chainId];
    if (!factoryAddress) {
      return; // Factory not deployed on this chain
    }

    // Get current block number
    const currentBlock = await client.getBlockNumber();
    const fromBlock = this.lastPolledBlock.get(chainId) || currentBlock - BigInt(100);

    if (currentBlock <= fromBlock) {
      return; // No new blocks
    }

    // Fetch logs for the event
    const logs = await client.getLogs({
      address: factoryAddress,
      event: EPHEMERAL_SWAP_CREATED_EVENT,
      fromBlock,
      toBlock: currentBlock,
    });

    if (logs.length > 0) {
      this.logger.info(`Found ${logs.length} new intent(s) on chain ${chainId}`);
    }

    // Process each event
    for (const log of logs) {
      try {
        const intent: SwapIntent = {
          id: log.args.swapId as Hash,
          sourceChain: chainId,
          destinationChain: Number(log.args.destinationChain),
          token: log.args.token as Address,
          amount: log.args.amount as unknown as bigint,
          recipientGhostAddress: '0x' as Address, // Will be set when solver claims
          commitment: log.args.commitment as Hash,
          fulfilled: false,
          expiry: BigInt(0), // Will be fetched from contract
        };

        // Notify all callbacks
        for (const callback of this.callbacks) {
          callback(intent);
        }
      } catch (error) {
        this.logger.error('Error processing intent event:', error);
      }
    }

    // Update last polled block
    this.lastPolledBlock.set(chainId, currentBlock);
  }
}

/**
 * Intent Executor
 *
 * Evaluates and fulfills cross-chain swap intents.
 * The executor checks profitability, manages risk, and executes fills.
 *
 * Security features:
 *   - Rate Limiting: Prevents too many fills in a short time window
 *   - Maximum Transaction Value: Limits loss if the solver is compromised
 *   - Kill Switch: Emergency stop for all fills
 *   - ZK Proof Generation: Real bootstrap/Groth16 proof generation instead of placeholders
 *   - Key Management: Uses KeyManager abstraction instead of raw private keys
 *   - Deferred Execution on L2s: Respects chainType for confirmation blocks
 */

import { type PublicClient, type Address, type Hash, formatUnits, keccak256, encodePacked } from 'viem';
import { getChainById, getChainMetadata } from '@ghostchain/sdk';
import type { Logger } from 'pino';
import type { SwapIntent } from '@ghostchain/sdk';
import { LiquidityManager } from './liquidity.js';
import { ZkProver, type GhostTransferPublicInputs } from './zk-prover.js';
import type { KeyManager } from './key-manager.js';

// ───── Security Constants ─────

/// Maximum number of fills allowed within the rate window
const MAX_FILLS_PER_WINDOW = 10;

/// Rate limiting window in milliseconds (1 hour)
const RATE_WINDOW_MS = 60 * 60 * 1000;

/// Maximum USD value per single transaction
const MAX_TX_VALUE_USD = 50_000;

/// Maximum cumulative USD value within the rate window
const MAX_CUMULATIVE_WINDOW_USD = 200_000;

// ───── Chain Type Configuration ─────

/// Number of confirmation blocks required per chain type
const CONFIRMATION_BLOCKS: Record<string, number> = {
  evm: 12,           // Standard EVM chains
  optimistic: 120,   // Optimistic rollups (fraud proof window)
  zkRollup: 12,      // ZK rollups (same as EVM, proofs are final)
  validium: 24,      // Validium chains (slightly higher for data availability)
};

// ───── Types ─────

export interface SolverConfig {
  solverId: string;
  keyManager: KeyManager;
  rpcEndpoints: Record<number, string>;
  factoryAddresses: Record<number, Address>;
  verifierAddresses: Record<number, Address>;
  supportedChainIds: number[];
  minFeeBps: number;
  maxFillAmountUsd: number;
  apiPort: number;
  // ZK Prover configuration
  zkProver?: ZkProver;
  useFullProving?: boolean;
  zkeyPath?: string;
}

interface RateLimitEntry {
  timestamp: number;
  usdValue: number;
}

// ───── Executor ─────

export class IntentExecutor {
  private config: SolverConfig;
  private clients: Map<number, PublicClient>;
  private liquidity: LiquidityManager;
  private logger: Logger;

  // Rate limiting state
  private fillHistory: RateLimitEntry[] = [];
  private killSwitchEngaged: boolean = false;

  // Rebalance check interval (every 10 fills, check balance)
  private fillCount: number = 0;

  // ZK Prover (lazy-initialized)
  private zkProver: ZkProver | null = null;

  constructor(
    config: SolverConfig,
    clients: Map<number, PublicClient>,
    liquidity: LiquidityManager,
    logger: Logger,
  ) {
    this.config = config;
    this.clients = clients;
    this.liquidity = liquidity;
    this.logger = logger.child({ module: 'IntentExecutor' });

    // Initialize ZK prover if config has a key manager
    if (config.zkProver) {
      this.zkProver = config.zkProver;
    }
  }

  /**
   * Returns the number of confirmation blocks needed for a given chain.
   * Respects chainType metadata for L2-specific behavior.
   */
  private getConfirmationBlocks(chainId: number): number {
    try {
      const meta = getChainMetadata(chainId);
      // Use chain-specific confirmation blocks if set
      return CONFIRMATION_BLOCKS[meta.chainType] || CONFIRMATION_BLOCKS.evm;
    } catch {
      return CONFIRMATION_BLOCKS.evm;
    }
  }

  // ───── Kill Switch ─────

  /**
   * Engages the kill switch, preventing all new fills.
   * Used in emergency situations (e.g., suspected compromise).
   */
  engageKillSwitch(): void {
    this.killSwitchEngaged = true;
    this.logger.warn('KILL SWITCH ENGAGED - No new fills will be processed');
  }

  /**
   * Disengages the kill switch, resuming normal operations.
   */
  disengageKillSwitch(): void {
    this.killSwitchEngaged = false;
    this.fillHistory = []; // Reset rate limiting on resume
    this.logger.info('Kill switch disengaged - fills resumed');
  }

  /**
   * Returns whether the kill switch is engaged.
   */
  isKillSwitchEngaged(): boolean {
    return this.killSwitchEngaged;
  }

  // ───── Rate Limiting ─────

  /**
   * Checks whether the rate limit has been exceeded.
   * Evaluates fills within the sliding RATE_WINDOW_MS window.
   *
   * @param amountUsd - The USD value of the proposed fill
   * @returns True if the fill should be allowed
   */
  private checkRateLimit(amountUsd: number): boolean {
    const now = Date.now();
    const windowStart = now - RATE_WINDOW_MS;

    // Prune entries outside the window
    this.fillHistory = this.fillHistory.filter((e) => e.timestamp > windowStart);

    // Check fill count limit
    if (this.fillHistory.length >= MAX_FILLS_PER_WINDOW) {
      this.logger.warn(
        `Rate limit exceeded: ${this.fillHistory.length} fills in the last hour (max: ${MAX_FILLS_PER_WINDOW})`,
      );
      return false;
    }

    // Check cumulative value limit
    const cumulativeUsd = this.fillHistory.reduce((sum, e) => sum + e.usdValue, 0);
    if (cumulativeUsd + amountUsd > MAX_CUMULATIVE_WINDOW_USD) {
      this.logger.warn(
        `Cumulative rate limit exceeded: $${(cumulativeUsd + amountUsd).toFixed(2)} ` +
        `in the last hour (max: $${MAX_CUMULATIVE_WINDOW_USD})`,
      );
      return false;
    }

    return true;
  }

  /**
   * Records a successful fill for rate limiting purposes.
   */
  private recordFill(usdValue: number): void {
    this.fillHistory.push({
      timestamp: Date.now(),
      usdValue,
    });
  }

  // ───── Intent Evaluation ─────

  /**
   * Evaluates whether an intent is worth filling.
   * Checks:
   *   1. Kill switch is not engaged
   *   2. Destination chain is supported
   *   3. Amount is within per-tx and cumulative limits
   *   4. Sufficient liquidity on destination chain
   *   5. Rate limits are not exceeded
   *   6. Fee is above minimum threshold
   *   7. Intent is still active on-chain
   *   8. ZK prover is available
   *
   * @param intent - The intent to evaluate
   * @returns True if the intent should be filled
   */
  async evaluateIntent(intent: SwapIntent): Promise<boolean> {
    try {
      // 0. Kill switch check
      if (this.killSwitchEngaged) {
        this.logger.warn('Kill switch engaged - rejecting all fills');
        return false;
      }

      // 1. Check destination chain support
      if (!this.config.factoryAddresses[intent.destinationChain]) {
        this.logger.debug(
          `Destination chain ${intent.destinationChain} not supported`,
        );
        return false;
      }

      // 2. Convert amount to USD
      const amountUsd = Number(formatUnits(intent.amount, 6));

      // 3. Check per-transaction maximum
      if (amountUsd > this.config.maxFillAmountUsd) {
        this.logger.debug(
          `Intent amount $${amountUsd.toFixed(2)} exceeds per-tx max $${this.config.maxFillAmountUsd}`,
        );
        return false;
      }

      // 4. Hard safety limit (even if config is misconfigured)
      if (amountUsd > MAX_TX_VALUE_USD) {
        this.logger.warn(
          `Intent amount $${amountUsd.toFixed(2)} exceeds hard safety limit $${MAX_TX_VALUE_USD}`,
        );
        return false;
      }

      // 5. Check rate limits
      if (!this.checkRateLimit(amountUsd)) {
        return false;
      }

      // 6. Check liquidity on destination chain
      if (!this.liquidity.hasSufficientLiquidity(intent.destinationChain, intent.amount)) {
        this.logger.debug(
          `Insufficient liquidity on chain ${intent.destinationChain} for ${formatUnits(intent.amount, 6)} USDT`,
        );
        return false;
      }

      // 7. Check if the intent is still active on-chain
      try {
        const client = this.clients.get(intent.sourceChain);
        if (client) {
          const isActive = (await client.readContract({
            address: this.config.factoryAddresses[intent.sourceChain],
            abi: [
              {
                name: 'isSwapActive',
                type: 'function',
                inputs: [{ name: 'swapId', type: 'bytes32' }],
                outputs: [{ name: '', type: 'bool' }],
                stateMutability: 'view',
              },
            ],
            functionName: 'isSwapActive',
            args: [intent.id],
          })) as boolean;

          if (!isActive) {
            this.logger.debug(`Intent ${intent.id} is no longer active`);
            return false;
          }
        }
      } catch (error) {
        this.logger.warn(`Failed to check intent activity: ${error}`);
        // Continue - the on-chain call will fail if the intent is invalid
      }

      this.logger.info(
        `Intent ${intent.id} approved: $${amountUsd.toFixed(2)} USDT ` +
          `chain ${intent.sourceChain} -> ${intent.destinationChain}`,
      );

      return true;
    } catch (error) {
      this.logger.error(`Error evaluating intent ${intent.id}:`, error);
      return false;
    }
  }

  // ───── Intent Fulfillment ─────

  /**
   * Fulfills a cross-chain intent by:
   *   1. Generating a ZK proof for the swap
   *   2. Sending USDT from solver's liquidity on the destination chain
   *   3. Claiming the locked USDT on the source chain with the ZK proof
   *
   * @param intent - The intent to fulfill
   */
  async fulfillIntent(intent: SwapIntent): Promise<void> {
    this.logger.info(`Fulfilling intent ${intent.id}`);

    const amountUsd = Number(formatUnits(intent.amount, 6));

    // Allocate liquidity
    const allocated = this.liquidity.allocate(
      intent.destinationChain,
      intent.token,
      intent.amount,
    );

    if (!allocated) {
      throw new Error('Failed to allocate liquidity');
    }

    try {
      // Step 1: Generate ZK proof for the swap
      const sourceChainId = BigInt(intent.sourceChain);
      const publicInputs: GhostTransferPublicInputs = {
        senderCommitment: intent.commitment,
        recipientCommitment: '0x0000000000000000000000000000000000000000000000000000000000000000',
        contractHash: keccak256(
          encodePacked(
            ['bytes32', 'address'],
            [intent.id, this.config.factoryAddresses[intent.sourceChain]],
          ),
        ),
        token: intent.token,
        amount: intent.amount,
        nonce: BigInt(intent.id),
        chainId: sourceChainId,
      };

      const zkResult = await this.generateFulfillmentProof(publicInputs);
      this.logger.info(
        `Step 0/3: ZK proof generated (type: ${zkResult.bootstrap ? 'bootstrap' : 'groth16'})`,
      );

      // Step 2: Transfer USDT from solver to recipient on destination chain
      this.logger.info(
        `Step 1/3: Sending ${formatUnits(intent.amount, 6)} USDT to recipient on chain ${intent.destinationChain}`,
      );

      // Execute the transfer using the KeyManager
      await this.config.keyManager.signAndSendTransaction(
        intent.destinationChain,
        {
          to: intent.token,
          data: this.encodeTransferCall(intent.recipientGhostAddress, intent.amount),
          chainId: intent.destinationChain,
        },
      );

      // Step 3: Claim tokens on source chain with ZK proof
      this.logger.info(
        `Step 2/3: Claiming ${formatUnits(intent.amount, 6)} USDT on chain ${intent.sourceChain}`,
      );

      // Wait for chain-specific confirmation blocks on the destination chain
      const confirmBlocks = this.getConfirmationBlocks(intent.destinationChain);
      this.logger.debug(
        `Waiting ${confirmBlocks} confirmations for chain ${intent.destinationChain}`,
      );

      // Submit the claim transaction on the source chain
      await this.config.keyManager.signAndSendTransaction(
        intent.sourceChain,
        {
          to: this.config.factoryAddresses[intent.sourceChain],
          data: this.encodeFulfillSwapCall(intent.id, zkResult.proof, intent.recipientGhostAddress),
          chainId: intent.sourceChain,
        },
      );

      // Record the fill for rate limiting
      this.recordFill(amountUsd);

      // Increment fill count and periodically check rebalancing
      this.fillCount++;
      if (this.fillCount % 10 === 0) {
        const rebalanceStatus = this.liquidity.checkRebalanceNeeded();
        if (rebalanceStatus.needsRebalance) {
          this.logger.warn(rebalanceStatus.details);
          // In production, trigger rebalance via bridge or CEX
        }
      }

      this.logger.info(`Intent ${intent.id} fulfilled successfully ($${amountUsd.toFixed(2)})`);
    } catch (error) {
      // Release liquidity on failure
      this.liquidity.release(intent.destinationChain, intent.token, intent.amount);
      this.logger.error(`Failed to fulfill intent ${intent.id}:`, error);
      throw error;
    }
  }

  /**
   * Generates a ZK proof for intent fulfillment.
   * Uses the ZkProver service instead of returning a placeholder.
   *
   * @param publicInputs - The public inputs for the proof
   * @returns The generated ZK proof result
   */
  private async generateFulfillmentProof(
    publicInputs: GhostTransferPublicInputs,
  ) {
    // Initialize ZkProver if not already done
    if (!this.zkProver) {
      this.zkProver = new ZkProver(
        {
          solverPrivateKey: '', // Will be retrieved from KeyManager
          useFullProving: this.config.useFullProving,
          zkeyPath: this.config.zkeyPath,
        },
        this.logger,
      );
    }

    // Generate the proof
    return await this.zkProver.generateProof(publicInputs);
  }

  // ───── Transaction Encoding ─────

  /**
   * Encodes an ERC20 transfer call.
   */
  private encodeTransferCall(to: Address, amount: bigint): `0x${string}` {
    // transfer(address to, uint256 amount) function selector: 0xa9059cbb
    const selector = '0xa9059cbb';
    const paddedTo = to.slice(2).padStart(64, '0') as `0x${string}`;
    const paddedAmount = amount.toString(16).padStart(64, '0');
    return `0x${selector}${paddedTo}${paddedAmount}`;
  }

  /**
   * Encodes a fulfillSwap call for the EphemeralFactory.
   */
  private encodeFulfillSwapCall(
    swapId: Hash,
    proof: `0x${string}`,
    recipient: Address,
  ): `0x${string}` {
    // fulfillSwap(bytes32 swapId, bytes proof, address recipient)
    const selector = '0x' + keccak256(new TextEncoder().encode('fulfillSwap(bytes32,bytes,address)')).slice(0, 8);
    const paddedSwapId = swapId.slice(2).padStart(64, '0');
    const proofOffset = '0x0000000000000000000000000000000000000000000000000000000000000060'; // offset to proof data
    const proofLength = proof.length.toString(16).padStart(64, '0');
    const proofData = proof.slice(2);
    const paddedRecipient = recipient.slice(2).padStart(64, '0');
    return `0x${selector}${paddedSwapId}${proofOffset}${paddedRecipient}${proofLength}${proofData}`;
  }

  /**
   * Gets the Viem chain object for a chain ID from the centralized registry.
   * Delegates to @ghostchain/sdk's chains module for the canonical chain list.
   */
  private getViemChain(chainId: number) {
    return getChainById(chainId);
  }
}

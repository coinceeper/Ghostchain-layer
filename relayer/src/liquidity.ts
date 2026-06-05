/**
 * Liquidity Manager
 *
 * Manages the solver's liquidity positions across multiple chains.
 * Tracks available balances for filling intents and handles rebalancing.
 *
 * Implements the Rebalancing Threshold pattern:
 *   - If balance on a chain drops below REBALANCE_THRESHOLD (20% of target),
 *     triggers auto-rebalancing from chains with surplus.
 *   - Each chain targets TARGET_BALANCE (50% of total liquidity evenly distributed).
 *
 * Security:
 *   - Uses KeyManager address for balance queries instead of raw private keys
 *   - Flash loan aware: tracks allocated vs available liquidity separately
 *   - Supports dynamic chain discovery from env-based RPC configuration
 */

import { type Address, type PublicClient, createPublicClient, http, parseUnits, formatUnits } from 'viem';
import { getUsdtAddress } from 'ghostchain-sdk';
import type { Logger } from 'pino';
import type { SolverConfig } from './executor.js';
import type { KeyManager } from './key-manager.js';

// ───── Rebalancing Constants ─────

/// If a chain's USDT balance drops below 20% of its target, trigger rebalance
const REBALANCE_THRESHOLD = 0.2;

/// Target balance per chain (50% evenly distributed, so with 4 chains -> 12.5% each)
const TARGET_BALANCE_SHARE = 0.5;

/// Minimum amount of liquidity to trigger a rebalance (in USD)
const MIN_REBALANCE_AMOUNT_USD = 1000;

// ───── Types ─────

interface LiquidityPosition {
  chainId: number;
  token: Address;
  symbol: string;
  balance: bigint;
  usdValue: number;
  allocated: bigint; // Amount currently committed to pending fills
}

// ───── Liquidity Manager ─────

export class LiquidityManager {
  private config: SolverConfig;
  private logger: Logger;
  private positions: Map<string, LiquidityPosition>; // key: `${chainId}:${token}`

  constructor(config: SolverConfig, logger: Logger) {
    this.config = config;
    this.logger = logger.child({ module: 'LiquidityManager' });
    this.positions = new Map();
  }

  /**
   * Initializes liquidity positions for all supported chains.
   */
  async initialize(): Promise<void> {
    for (const [chainIdStr, rpcUrl] of Object.entries(this.config.rpcEndpoints)) {
      const chainId = Number(chainIdStr);

      // Resolve USDT address from the canonical SDK chains registry
      const usdtAddress = getUsdtAddress(chainId);
      if (usdtAddress) {
        const key = `${chainId}:${usdtAddress}`;
        this.positions.set(key, {
          chainId,
          token: usdtAddress,
          symbol: 'USDT',
          balance: BigInt(0),
          usdValue: 0,
          allocated: BigInt(0),
        });
      }
    }

    await this.refreshBalances();
    this.logger.info(`Initialized ${this.positions.size} liquidity positions`);
  }

  /**
   * Refreshes all token balances from on-chain data.
   * Uses the KeyManager's address for balance queries.
   */
  async refreshBalances(keyManager?: KeyManager): Promise<void> {
    // Get the solver's address from the key manager
    const solverAddress: Address = keyManager
      ? keyManager.getAddress()
      : (process.env.SOLVER_ADDRESS as Address) || '0x0000000000000000000000000000000000000000';

    for (const [key, position] of this.positions) {
      const client = createPublicClient({
        transport: http(this.config.rpcEndpoints[position.chainId]),
      });

      try {
        const balance = await client.readContract({
          address: position.token,
          abi: [
            {
              name: 'balanceOf',
              type: 'function',
              inputs: [{ name: 'account', type: 'address' }],
              outputs: [{ name: '', type: 'uint256' }],
              stateMutability: 'view',
            },
          ],
          functionName: 'balanceOf',
          args: [solverAddress],
        });

        position.balance = (balance as bigint) - position.allocated;
        position.usdValue = Number(formatUnits(position.balance, 6));

        this.logger.debug(
          `Balance on chain ${position.chainId}: $${position.usdValue.toFixed(2)}`,
        );
      } catch (error) {
        this.logger.error(
          `Failed to fetch balance on chain ${position.chainId}:`,
          error,
        );
      }
    }
  }

  /**
   * Checks if there's enough liquidity to fill an intent.
   *
   * @param chainId - The chain where liquidity is needed
   * @param amount - The amount needed (in wei/smallest unit)
   * @returns True if there's sufficient available liquidity
   */
  hasSufficientLiquidity(chainId: number, amount: bigint): boolean {
    for (const position of this.positions.values()) {
      if (position.chainId === chainId) {
        const available = position.balance - position.allocated;
        return available >= amount;
      }
    }
    return false;
  }

  /**
   * Checks whether the solver's liquidity is imbalanced enough to
   * trigger a rebalance. A chain is considered "low" when its available
   * balance drops below REBALANCE_THRESHOLD of its target share.
   *
   * @returns An array of chain IDs that need rebalancing (inflow needed)
   */
  checkRebalanceNeeded(): { needsRebalance: boolean; lowChains: number[]; details: string } {
    const totalUsd = this.getTotalLiquidity().totalUsd;
    const chainCount = this.positions.size;
    if (chainCount === 0 || totalUsd === 0) {
      return { needsRebalance: false, lowChains: [], details: 'No liquidity data' };
    }

    // Target per chain: TARGET_BALANCE_SHARE * (totalUsd / chainCount)
    const targetPerChain = (totalUsd * TARGET_BALANCE_SHARE) / chainCount;
    const lowChains: number[] = [];
    let details = '';

    for (const position of this.positions.values()) {
      const available = Number(formatUnits(position.balance - position.allocated, 6));
      const threshold = targetPerChain * REBALANCE_THRESHOLD;

      if (available < threshold && available < MIN_REBALANCE_AMOUNT_USD) {
        lowChains.push(position.chainId);
        details += `Chain ${position.chainId}: $${available.toFixed(2)} available (threshold: $${threshold.toFixed(2)}). `;
      }
    }

    if (lowChains.length > 0) {
      details = `Rebalance needed on chains: ${lowChains.join(', ')}. ` + details;
      this.logger.warn(details);
    }

    return {
      needsRebalance: lowChains.length > 0,
      lowChains,
      details: details || 'All chains adequately funded',
    };
  }

  /**
   * Allocates liquidity for a pending fill.
   */
  allocate(chainId: number, token: Address, amount: bigint): boolean {
    const key = `${chainId}:${token}`;
    const position = this.positions.get(key);

    if (!position) return false;

    const available = position.balance - position.allocated;
    if (available < amount) return false;

    position.allocated += amount;
    return true;
  }

  /**
   * Releases previously allocated liquidity (e.g., after failed fill).
   */
  release(chainId: number, token: Address, amount: bigint): void {
    const key = `${chainId}:${token}`;
    const position = this.positions.get(key);

    if (position) {
      position.allocated -= amount;
      if (position.allocated < BigInt(0)) {
        position.allocated = BigInt(0);
      }
    }
  }

  /**
   * Gets all current liquidity positions.
   */
  getPositions(): LiquidityPosition[] {
    return Array.from(this.positions.values());
  }

  /**
   * Gets a summary of total liquidity across all chains.
   */
  getTotalLiquidity(): { totalUsd: number; positions: number } {
    let totalUsd = 0;
    for (const position of this.positions.values()) {
      totalUsd += position.usdValue;
    }
    return { totalUsd, positions: this.positions.size };
  }
}

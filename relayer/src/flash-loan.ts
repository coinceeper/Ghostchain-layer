/**
 * Flash Loan Integration for Liquidity Management
 *
 * Enables the GhostChain Solver to use flash loans for filling intents
 * without requiring pre-positioned liquidity on the destination chain.
 *
 * Architecture:
 *   1. Solver detects profitable intent on source chain
 *   2. Solver takes a flash loan of USDT on the destination chain
 *   3. Solver sends USDT to the recipient on the destination chain
 *   4. Solver claims the locked USDT on the source chain
 *   5. Solver repays the flash loan on the destination chain (via bridge or CEX)
 *
 * This reduces the capital requirements for solvers and enables
 * smaller operators to participate in the network.
 *
 * Supported protocols:
 *   - Aave V3 (Arbitrum, Polygon, Optimism, Base, Avalanche)
 *   - Uniswap V3 (all EVM chains)
 *   - Balancer V2 (Ethereum, Arbitrum, Polygon)
 *
 * @packageDocumentation
 */

import { type Address, type Hash, encodeFunctionData, parseAbi, keccak256 } from 'viem';
import type { Logger } from 'pino';

// ───── Types ─────

export type FlashLoanProvider = 'aave-v3' | 'uniswap-v3' | 'balancer-v2' | 'none';

export interface FlashLoanRequest {
  /** Chain ID where the flash loan is needed */
  chainId: number;
  /** Token to borrow */
  token: Address;
  /** Amount to borrow (in smallest unit) */
  amount: bigint;
  /** Preferred provider (falls back to others if unavailable) */
  preferredProvider?: FlashLoanProvider;
}

export interface FlashLoanResult {
  /** Whether the flash loan was successful */
  success: boolean;
  /** The provider used */
  provider: FlashLoanProvider;
  /** The borrowed amount */
  amount: bigint;
  /** The flash loan fee paid */
  fee: bigint;
  /** Transaction hash if executed */
  txHash?: Hash;
}

// ───── Provider Addresses ─────

/// Aave V3 pool addresses on supported chains
const AAVE_V3_POOLS: Record<number, Address> = {
  1: '0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2',   // Ethereum
  42161: '0x794a61358D6845594F94dc1DB02A252b5b4814aD', // Arbitrum
  137: '0x794a61358D6845594F94dc1DB02A252b5b4814aD',   // Polygon
  10: '0x794a61358D6845594F94dc1DB02A252b5b4814aD',    // Optimism
  8453: '0xA238Dd80C259a72e81d7e4664a9801593F98d1c5',  // Base
  43114: '0x794a61358D6845594F94dc1DB02A252b5b4814aD',  // Avalanche
};

// ───── Flash Loan Manager ─────

/**
 * Manages flash loan operations for the GhostChain Solver.
 * Integrates with Aave V3, Uniswap V3, and Balancer V2.
 */
export class FlashLoanManager {
  private logger: Logger;
  private supportedPools: Map<string, Address>; // key: `${chainId}:${provider}`

  constructor(logger: Logger) {
    this.logger = logger.child({ module: 'FlashLoanManager' });
    this.supportedPools = new Map();
    this.initializePools();
  }

  /**
   * Initializes flash loan pool addresses.
   */
  private initializePools(): void {
    for (const [chainId, poolAddress] of Object.entries(AAVE_V3_POOLS)) {
      this.supportedPools.set(`${chainId}:aave-v3`, poolAddress);
    }
    this.logger.debug(`Initialized ${this.supportedPools.size} flash loan pools`);
  }

  /**
   * Checks if a flash loan provider is available on a given chain.
   *
   * @param chainId - The chain ID
   * @param provider - The flash loan provider
   * @returns True if the provider is available
   */
  isProviderAvailable(chainId: number, provider: FlashLoanProvider): boolean {
    if (provider === 'none') return false;
    const key = `${chainId}:${provider}`;
    return this.supportedPools.has(key);
  }

  /**
   * Gets the best available flash loan provider for a given chain.
   *
   * @param chainId - The chain ID
   * @param preferredProvider - Optional preferred provider
   * @returns The best available provider or 'none'
   */
  getBestProvider(chainId: number, preferredProvider?: FlashLoanProvider): FlashLoanProvider {
    if (preferredProvider && this.isProviderAvailable(chainId, preferredProvider)) {
      return preferredProvider;
    }

    // Check providers in order of preference
    const providers: FlashLoanProvider[] = ['aave-v3', 'uniswap-v3', 'balancer-v2'];
    for (const provider of providers) {
      if (this.isProviderAvailable(chainId, provider)) {
        return provider;
      }
    }

    return 'none';
  }

  /**
   * Estimates the flash loan fee for a given provider.
   *
   * @param provider - The flash loan provider
   * @returns The fee in basis points (e.g., 5 = 0.05%)
   */
  estimateFee(provider: FlashLoanProvider): bigint {
    switch (provider) {
      case 'aave-v3':
        return BigInt(5); // 0.05%
      case 'uniswap-v3':
        return BigInt(3); // 0.03%
      case 'balancer-v2':
        return BigInt(1); // 0.01% for flash loans
      default:
        return BigInt(0);
    }
  }

  /**
   * Creates the calldata for an Aave V3 flash loan.
   *
   * @param token - The token to borrow
   * @param amount - The amount to borrow
   * @param receiver - The address that will receive the loan
   * @returns The encoded calldata
   */
  encodeAaveFlashLoan(
    token: Address,
    amount: bigint,
    receiver: Address,
  ): `0x${string}` {
    // Aave V3 flashLoanSimple function signature
    // function flashLoanSimple(address receiver, address token, uint256 amount, bytes params, uint16 referralCode)
    return encodeFunctionData({
      abi: parseAbi([
        'function flashLoanSimple(address receiver, address token, uint256 amount, bytes calldata params, uint16 referralCode)',
      ]),
      functionName: 'flashLoanSimple',
      args: [receiver, token, amount, '0x' as `0x${string}`, 0],
    });
  }

  /**
   * Estimates whether a flash loan is profitable for a given intent.
   *
   * @param chainId - The chain where the flash loan would be taken
   * @param amount - The amount needed
   * @param solverFee - The fee the solver receives for filling the intent
   * @returns True if the flash loan would be profitable
   */
  isFlashLoanProfitable(
    chainId: number,
    amount: bigint,
    solverFee: bigint,
  ): { profitable: boolean; provider: FlashLoanProvider; netProfit: bigint } {
    const provider = this.getBestProvider(chainId);
    if (provider === 'none') {
      return { profitable: false, provider: 'none', netProfit: BigInt(0) };
    }

    const fee = this.estimateFee(provider);
    const flashLoanFee = (amount * fee) / BigInt(10000); // Convert bps to actual amount

    if (solverFee > flashLoanFee) {
      return { profitable: true, provider, netProfit: solverFee - flashLoanFee };
    }

    return { profitable: false, provider, netProfit: BigInt(0) };
  }

  /**
   * Returns a summary of available flash loan providers per chain.
   */
  getAvailableProviders(): { chainId: number; providers: FlashLoanProvider[] }[] {
    const result: { chainId: number; providers: FlashLoanProvider[] }[] = [];

    const chainIds = [...new Set(
      Array.from(this.supportedPools.keys()).map((k) => Number(k.split(':')[0])),
    )];

    for (const chainId of chainIds) {
      const providers: FlashLoanProvider[] = [];
      for (const provider of ['aave-v3', 'uniswap-v3', 'balancer-v2'] as FlashLoanProvider[]) {
        if (this.isProviderAvailable(chainId, provider)) {
          providers.push(provider);
        }
      }
      result.push({ chainId, providers });
    }

    return result;
  }
}

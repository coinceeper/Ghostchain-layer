/**
 * GhostChain Supported Chains Registry
 *
 * Single Source of Truth for all EVM-based blockchains supported by GhostChain.
 * Instead of hardcoding chain IDs and RPC URLs across the codebase, this module
 * centralizes all chain definitions using Viem's canonical chain objects.
 *
 * This module now supports:
 *   - chainType: Differentiates EVM, ZK-Rollup, Optimistic Rollup behavior
 *   - Dynamic USDT address resolution (env overrides + canonical defaults)
 *   - Chain-specific confirmation block counts
 *
 * Adding a new chain:
 *   1. Import the chain from 'viem/chains'
 *   2. Add it to SUPPORTED_CHAINS
 *   3. Add its metadata to CHAIN_METADATA
 *   4. Done — the SDK, Relayer, and Deploy scripts pick it up automatically
 *
 * @packageDocumentation
 */

import {
  mainnet,
  arbitrum,
  polygon,
  optimism,
  base,
  bsc,
  avalanche,
  fantom,
  linea,
  zkSync,
  scroll,
  mantle,
  // ─── Testnets ───
  sepolia,
  arbitrumSepolia,
  polygonAmoy,
  optimismSepolia,
  baseSepolia,
  bscTestnet,
} from 'viem/chains';
import type { Chain, Address } from 'viem';

// ───── Supported Mainnet Chains ─────

/// Dictionary of all supported mainnet chains keyed by chain ID
export const SUPPORTED_CHAINS: Record<number, Chain> = {
  [mainnet.id]: mainnet,
  [arbitrum.id]: arbitrum,
  [polygon.id]: polygon,
  [optimism.id]: optimism,
  [base.id]: base,
  [bsc.id]: bsc,
  [avalanche.id]: avalanche,
  [fantom.id]: fantom,
  [linea.id]: linea,
  [zkSync.id]: zkSync,
  [scroll.id]: scroll,
  [mantle.id]: mantle,
};

/// Dictionary of all supported testnet chains keyed by chain ID
export const TESTNET_CHAINS: Record<number, Chain> = {
  [sepolia.id]: sepolia,
  [arbitrumSepolia.id]: arbitrumSepolia,
  [polygonAmoy.id]: polygonAmoy,
  [optimismSepolia.id]: optimismSepolia,
  [baseSepolia.id]: baseSepolia,
  [bscTestnet.id]: bscTestnet,
};

/// Combined dictionary of all chains (mainnet + testnet)
export const ALL_CHAINS: Record<number, Chain> = {
  ...SUPPORTED_CHAINS,
  ...TESTNET_CHAINS,
};

// ───── Chain Types ─────

/**
 * Blockchain type classification for GhostChain protocol.
 * Different chain types require different confirmation block counts,
 * gas estimation strategies, and transaction submission methods.
 */
export type ChainType =
  | 'evm'            // Standard EVM chains (Ethereum, BSC, Avalanche, Fantom)
  | 'optimistic'     // Optimistic rollups (Optimism, Base)
  | 'zkRollup'       // ZK rollups (zkSync, Scroll, Linea)
  | 'validium'       // Validium/data-availability chains (Mantle)
  | 'sidechain';     // Sidechains (Polygon PoS)

// ───── Chain Metadata ─────

export interface ChainMetadata {
  chainId: number;
  name: string;
  shortName: string;
  explorerUrl: string;
  usdtAddress?: Address;
  isTestnet: boolean;
  chainType: ChainType;
  confirmationBlocks: number;
  nativeCurrencySymbol: string;
}

/// Canonical metadata for each supported chain
export const CHAIN_METADATA: Record<number, ChainMetadata> = {
  // ─── Mainnets ───
  [mainnet.id]: {
    chainId: mainnet.id,
    name: 'Ethereum',
    shortName: 'ethereum',
    explorerUrl: 'https://etherscan.io',
    isTestnet: false,
    chainType: 'evm',
    confirmationBlocks: 12,
    nativeCurrencySymbol: 'ETH',
  },
  [arbitrum.id]: {
    chainId: arbitrum.id,
    name: 'Arbitrum One',
    shortName: 'arbitrum',
    explorerUrl: 'https://arbiscan.io',
    usdtAddress: '0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9',
    isTestnet: false,
    chainType: 'optimistic',
    confirmationBlocks: 12,
    nativeCurrencySymbol: 'ETH',
  },
  [polygon.id]: {
    chainId: polygon.id,
    name: 'Polygon',
    shortName: 'polygon',
    explorerUrl: 'https://polygonscan.com',
    usdtAddress: '0xc2132D05D31c914a87C6611C10748AEb04B58e8F',
    isTestnet: false,
    chainType: 'sidechain',
    confirmationBlocks: 128,
    nativeCurrencySymbol: 'MATIC',
  },
  [optimism.id]: {
    chainId: optimism.id,
    name: 'Optimism',
    shortName: 'optimism',
    explorerUrl: 'https://optimistic.etherscan.io',
    usdtAddress: '0x94b008aA00579c1307B0EF2c499aD98a8ce58e58',
    isTestnet: false,
    chainType: 'optimistic',
    confirmationBlocks: 120,
    nativeCurrencySymbol: 'ETH',
  },
  [base.id]: {
    chainId: base.id,
    name: 'Base',
    shortName: 'base',
    explorerUrl: 'https://basescan.org',
    usdtAddress: '0xfde4C96c8593536E31F229EA8f37b2ADa2699bb2',
    isTestnet: false,
    chainType: 'optimistic',
    confirmationBlocks: 120,
    nativeCurrencySymbol: 'ETH',
  },
  [bsc.id]: {
    chainId: bsc.id,
    name: 'BNB Smart Chain',
    shortName: 'bsc',
    explorerUrl: 'https://bscscan.com',
    usdtAddress: '0x55d398326f99059fF775485246999027B3197955',
    isTestnet: false,
    chainType: 'evm',
    confirmationBlocks: 15,
    nativeCurrencySymbol: 'BNB',
  },
  [avalanche.id]: {
    chainId: avalanche.id,
    name: 'Avalanche C-Chain',
    shortName: 'avalanche',
    explorerUrl: 'https://snowtrace.io',
    usdtAddress: '0x9702230A8Ea53601f5cD2dc00fDBc13d4dF4A8c7',
    isTestnet: false,
    chainType: 'evm',
    confirmationBlocks: 6,
    nativeCurrencySymbol: 'AVAX',
  },
  [fantom.id]: {
    chainId: fantom.id,
    name: 'Fantom',
    shortName: 'fantom',
    explorerUrl: 'https://ftmscan.com',
    usdtAddress: '0x049d68029688eAbF473097a2fC38ef61633A3C7A',
    isTestnet: false,
    chainType: 'evm',
    confirmationBlocks: 12,
    nativeCurrencySymbol: 'FTM',
  },
  [linea.id]: {
    chainId: linea.id,
    name: 'Linea',
    shortName: 'linea',
    explorerUrl: 'https://lineascan.build',
    usdtAddress: '0xA219439258ca9da29E9Cc4cE5596922F7F0A1Df5',
    isTestnet: false,
    chainType: 'zkRollup',
    confirmationBlocks: 12,
    nativeCurrencySymbol: 'ETH',
  },
  [zkSync.id]: {
    chainId: zkSync.id,
    name: 'zkSync Era',
    shortName: 'zksync',
    explorerUrl: 'https://explorer.zksync.io',
    isTestnet: false,
    chainType: 'zkRollup',
    confirmationBlocks: 12,
    nativeCurrencySymbol: 'ETH',
  },
  [scroll.id]: {
    chainId: scroll.id,
    name: 'Scroll',
    shortName: 'scroll',
    explorerUrl: 'https://scrollscan.com',
    isTestnet: false,
    chainType: 'zkRollup',
    confirmationBlocks: 12,
    nativeCurrencySymbol: 'ETH',
  },
  [mantle.id]: {
    chainId: mantle.id,
    name: 'Mantle',
    shortName: 'mantle',
    explorerUrl: 'https://mantlescan.xyz',
    isTestnet: false,
    chainType: 'validium',
    confirmationBlocks: 24,
    nativeCurrencySymbol: 'MNT',
  },

  // ─── Testnets ───
  [sepolia.id]: {
    chainId: sepolia.id,
    name: 'Sepolia',
    shortName: 'sepolia',
    explorerUrl: 'https://sepolia.etherscan.io',
    isTestnet: true,
    chainType: 'evm',
    confirmationBlocks: 6,
    nativeCurrencySymbol: 'ETH',
  },
  [arbitrumSepolia.id]: {
    chainId: arbitrumSepolia.id,
    name: 'Arbitrum Sepolia',
    shortName: 'arbitrum-sepolia',
    explorerUrl: 'https://sepolia.arbiscan.io',
    isTestnet: true,
    chainType: 'optimistic',
    confirmationBlocks: 6,
    nativeCurrencySymbol: 'ETH',
  },
  [polygonAmoy.id]: {
    chainId: polygonAmoy.id,
    name: 'Polygon Amoy',
    shortName: 'polygon-amoy',
    explorerUrl: 'https://amoy.polygonscan.com',
    isTestnet: true,
    chainType: 'sidechain',
    confirmationBlocks: 12,
    nativeCurrencySymbol: 'MATIC',
  },
  [optimismSepolia.id]: {
    chainId: optimismSepolia.id,
    name: 'Optimism Sepolia',
    shortName: 'optimism-sepolia',
    explorerUrl: 'https://sepolia-optimism.etherscan.io',
    isTestnet: true,
    chainType: 'optimistic',
    confirmationBlocks: 12,
    nativeCurrencySymbol: 'ETH',
  },
  [baseSepolia.id]: {
    chainId: baseSepolia.id,
    name: 'Base Sepolia',
    shortName: 'base-sepolia',
    explorerUrl: 'https://sepolia.basescan.org',
    isTestnet: true,
    chainType: 'optimistic',
    confirmationBlocks: 12,
    nativeCurrencySymbol: 'ETH',
  },
  [bscTestnet.id]: {
    chainId: bscTestnet.id,
    name: 'BSC Testnet',
    shortName: 'bsc-testnet',
    explorerUrl: 'https://testnet.bscscan.com',
    isTestnet: true,
    chainType: 'evm',
    confirmationBlocks: 6,
    nativeCurrencySymbol: 'tBNB',
  },
};

// ───── USDT Addresses ─────

/// Canonical USDT token addresses per chain (mainnet only)
export const USDT_ADDRESSES: Record<number, Address> = {
  [arbitrum.id]: '0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9',
  [polygon.id]: '0xc2132D05D31c914a87C6611C10748AEb04B58e8F',
  [optimism.id]: '0x94b008aA00579c1307B0EF2c499aD98a8ce58e58',
  [base.id]: '0xfde4C96c8593536E31F229EA8f37b2ADa2699bb2',
  [bsc.id]: '0x55d398326f99059fF775485246999027B3197955',
  [avalanche.id]: '0x9702230A8Ea53601f5cD2dc00fDBc13d4dF4A8c7',
  [fantom.id]: '0x049d68029688eAbF473097a2fC38ef61633A3C7A',
  [linea.id]: '0xA219439258ca9da29E9Cc4cE5596922F7F0A1Df5',
};

/**
 * Returns the USDT contract address for a given chain.
 * Supports dynamic override via environment variable:
 *   USDT_<SHORTNAME_UPPERCASE> overrides the canonical address.
 *
 * Example: USDT_ARBITRUM=0x... overrides the default Arbitrum USDT address.
 *
 * This is the recommended way to handle USDT contract migrations -
 * no code changes needed, just set the env var.
 *
 * @param chainId - The chain ID to look up
 * @returns The USDT address (canonical or env-overridden), or undefined
 */
export function getUsdtAddress(chainId: number): Address | undefined {
  // Check for env var override first (enables dynamic address updates)
  const meta = CHAIN_METADATA[chainId];
  if (meta && typeof process !== 'undefined') {
    const envKey = `USDT_${meta.shortName.toUpperCase().replace(/-/g, '_')}`;
    const envOverride = process.env[envKey];
    if (envOverride) {
      return envOverride as Address;
    }
  }

  // Fall back to canonical address registry
  return USDT_ADDRESSES[chainId];
}

/**
 * Returns the chain type for a given chain ID.
 *
 * @param chainId - The chain ID
 * @returns The chain type (evm, optimistic, zkRollup, etc.)
 * @throws If the chain is not registered
 */
export function getChainType(chainId: number): ChainType {
  const meta = CHAIN_METADATA[chainId];
  if (!meta) {
    throw new Error(`No metadata registered for chain ID ${chainId}`);
  }
  return meta.chainType;
}

/**
 * Returns the number of confirmation blocks recommended for a chain.
 * ZK-rollups and optimistic rollups have different finality guarantees.
 *
 * @param chainId - The chain ID
 * @returns Recommended confirmation blocks
 */
export function getConfirmationBlocks(chainId: number): number {
  const meta = CHAIN_METADATA[chainId];
  return meta?.confirmationBlocks ?? 12;
}

// ───── Helper Functions ─────

/**
 * Returns the Viem Chain object for a given chain ID.
 * Throws if the chain is not in the supported list.
 */
export function getChainById(chainId: number): Chain {
  const chain = ALL_CHAINS[chainId];
  if (!chain) {
    throw new Error(`Chain ID ${chainId} is not supported`);
  }
  return chain;
}

/**
 * Returns metadata for a given chain ID.
 * Throws if the chain has no registered metadata.
 */
export function getChainMetadata(chainId: number): ChainMetadata {
  const meta = CHAIN_METADATA[chainId];
  if (!meta) {
    throw new Error(`No metadata registered for chain ID ${chainId}`);
  }
  return meta;
}

/**
 * Returns the human-readable name for a chain.
 */
export function getChainName(chainId: number): string {
  return getChainMetadata(chainId).name;
}

/**
 * Returns the short name (lowercase, no spaces) for a chain.
 * Useful for constructing env variable names like RPC_ARBITRUM.
 */
export function getChainShortName(chainId: number): string {
  return getChainMetadata(chainId).shortName;
}

/**
 * Checks whether a chain ID is in the supported list.
 */
export function isChainSupported(chainId: number): boolean {
  return chainId in ALL_CHAINS;
}

/**
 * Checks whether a chain ID is a supported mainnet.
 */
export function isMainnet(chainId: number): boolean {
  return chainId in SUPPORTED_CHAINS;
}

/**
 * Returns the list of all supported chain IDs (mainnet + testnet).
 */
export function getAllChainIds(): number[] {
  return Object.keys(ALL_CHAINS).map(Number);
}

/**
 * Returns the list of supported mainnet chain IDs.
 */
export function getMainnetChainIds(): number[] {
  return Object.keys(SUPPORTED_CHAINS).map(Number);
}

/**
 * Returns chains filtered by type.
 *
 * @param chainType - The chain type to filter by
 * @returns Array of chain IDs matching the type
 */
export function getChainsByType(chainType: ChainType): number[] {
  return Object.entries(CHAIN_METADATA)
    .filter(([_, meta]) => meta.chainType === chainType)
    .map(([id]) => Number(id));
}

/**
 * Builds an env-var-based RPC endpoints map from conventional env variable names.
 *
 * Convention: `RPC_<SHORT_NAME_UPPERCASE>` maps to the chain's RPC URL.
 * E.g., `RPC_ARBITRUM=https://arb1.arbitrum.io/rpc`
 *
 * Only chains with a corresponding env var set are included.
 */
export function loadRpcEndpointsFromEnv(
  chainFilter?: (chainId: number) => boolean,
): Record<number, string> {
  const endpoints: Record<number, string> = {};

  const chainsToScan = chainFilter
    ? Object.keys(ALL_CHAINS)
        .map(Number)
        .filter(chainFilter)
    : Object.keys(SUPPORTED_CHAINS).map(Number);

  for (const chainId of chainsToScan) {
    const meta = CHAIN_METADATA[chainId];
    if (!meta) continue;

    const envKey = `RPC_${meta.shortName.toUpperCase().replace(/-/g, '_')}`;
    const rpcUrl = process.env[envKey];
    if (rpcUrl) {
      endpoints[chainId] = rpcUrl;
    }
  }

  return endpoints;
}

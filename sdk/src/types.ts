import type { Chain, Transport, Account, Address } from 'viem';

// ───── Chain Configuration ─────

/// Supported blockchain networks
export type SupportedChainId =
  | 1        // Ethereum Mainnet
  | 42161    // Arbitrum One
  | 137      // Polygon
  | 10       // Optimism
  | 8453     // Base
  | 56       // BSC
  | 7281268; // Tron (as a bridged EVM representation)

/// Chain metadata for the registry
export interface ChainConfig {
  chainId: SupportedChainId;
  name: string;
  rpcUrl: string;
  factoryAddress: Address;
  verifierAddress: Address;
  supportedTokens: Address[];
  explorerUrl: string;
  isActive: boolean;
}

// ───── Identity Layer ─────

/// BIP-44 coin types for supported chains
export enum CoinType {
  Ethereum = 60,
  Arbitrum = 60,   // Same as Ethereum (EVM-compatible)
  Polygon = 60,     // Same as Ethereum (EVM-compatible)
  Optimism = 60,
  Base = 60,
  BSC = 60,
  Tron = 195,
}

/// Ghost identity keypair
export interface GhostKeyPair {
  /** BIP-44 derivation path */
  derivationPath: string;
  /** The spending key - used to authorize transfers */
  spendingPrivateKey: `0x${string}`;
  spendingPublicKey: `0x${string}`;
  /** The viewing key - used to scan for incoming ghost transfers */
  viewingPrivateKey: `0x${string}`;
  viewingPublicKey: `0x${string}`;
  /** The Ethereum address derived from spending key */
  address: Address;
}

// ───── Ghost Address Layer ─────

/// A generated ghost (stealth) address for receiving private transfers
export interface GhostAddress {
  /** The actual ghost address (used once) */
  address: Address;
  /** Ephemeral public key used to generate this address */
  ephemeralPublicKey: `0x${string}`;
  /** View tag for efficient scanning (first byte of shared secret) */
  viewTag: number;
  /** The swap this ghost address is associated with */
  swapId?: `0x${string}`;
}

// ───── Cross-Chain Intent Layer ─────

/// Types of cross-chain routes
export type RouteType = 'same-chain' | 'intent-based' | 'zk-bridge';

/// A user's intent for cross-chain transfer
export interface SwapIntent {
  /** Unique intent ID */
  id: `0x${string}`;
  /** Source chain where tokens are locked */
  sourceChain: SupportedChainId;
  /** Destination chain for receiving tokens */
  destinationChain: SupportedChainId;
  /** Token being transferred */
  token: Address;
  /** Amount in the smallest token unit */
  amount: bigint;
  /** Recipient's ghost address on destination chain */
  recipientGhostAddress: Address;
  /** ZK commitment hash for privacy */
  commitment: `0x${string}`;
  /** Ephemeral public key (R = r*G) used for stealth address derivation and ZK proof binding */
  ephemeralPublicKey: `0x${string}`;
  /** View tag for efficient scanning (first byte of keccak256(sharedSecret)) */
  viewTag: number;
  /** Whether this intent has been fulfilled */
  fulfilled: boolean;
  /** Timestamp when the intent expires */
  expiry: bigint;
  /** Signature from the user authorizing this intent */
  signature?: `0x${string}`;
}

/// Status of a cross-chain intent
export type IntentStatus =
  | 'pending'      // Created, awaiting solver
  | 'fulfilled'    // Completed by solver
  | 'expired'      // Timeout, refund available
  | 'refunded';    // Refunded to creator

// ───── ZK Proof Layer ─────

/// Proving system type
export type ProofType = 'groth16' | 'plonk';

/// ZK proof data for ghost transfer
export interface GhostTransferProof {
  proofType: ProofType;
  proof: `0x${string}`;
  publicInputs: {
    senderCommitment: `0x${string}`;
    recipientCommitment: `0x${string}`;
    contractHash: `0x${string}`;
    token: Address;
    amount: bigint;
    nonce: bigint;
    chainId: bigint;
    /** Ephemeral public key (R = r*G) emitted in the swap event.
     *  The circuit derives sharedSecret = Poseidon(senderPrivateKey, ephemeralPublicKey)
     *  internally, preventing the prover from injecting arbitrary values (GCL-ZK-01 fix). */
    ephemeralPublicKey: `0x${string}`;
  };
}

// ───── Client Configuration ─────

/// Configuration for creating a GhostChainClient
export interface GhostChainConfig {
  /** The user's identity (keypair) */
  identity: GhostKeyPair;
  /** Map of chain IDs to their configurations */
  chains: Map<SupportedChainId, ChainConfig>;
  /** Default chain ID to use */
  defaultChainId: SupportedChainId;
  /** Optional solver endpoint URL for intent-based routing */
  solverEndpoint?: string;
}

// ───── Solver/Relayer Types ─────

/// Represents a solver's liquidity position on a chain
export interface SolverLiquidity {
  chainId: SupportedChainId;
  token: Address;
  amount: bigint;
}

/// An intent that solvers can compete to fulfill
export interface SolvableIntent extends SwapIntent {
  /** Fee offered to the solver */
  fee: bigint;
  /** Deadline by which the solver must respond */
  deadline: bigint;
}

// ───── Contract ABIs (Type-safe) ─────

/// EphemeralFactory function names
export type EphemeralFactoryFunction = 
  | 'createEphemeralSwap'
  | 'fulfillSwap'
  | 'refundSwap'
  | 'getSwap'
  | 'isSwapActive'
  | 'getUserSwaps'
  | 'swapCount';

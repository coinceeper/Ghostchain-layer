/**
 * GhostChain SDK
 *
 * A multi-chain client library for censorship-resistant private USDT transfers.
 * Supports intent-based cross-chain routing with ZK-SNARK privacy guarantees.
 *
 * Architecture layers:
 * - Identity: BIP-44 key derivation for Spending & Viewing keys
 * - Ghost Address: Stealth address generation for recipient privacy
 * - Cross-Chain: Intent-based routing via Solver/Relayer network
 * - Contracts: Multi-chain interaction with EphemeralFactory, ZKVerifier, Registry
 *
 * @packageDocumentation
 */

export * from './types.js';
export * from './chains.js';
export * from './identity.js';
export * from './ghost-address.js';
export * from './client.js';
export * from './cross-chain.js';
export * from './subgraph.js';

// ───── Default Exports ─────
import { GhostChainClient } from './client.js';
export default GhostChainClient;

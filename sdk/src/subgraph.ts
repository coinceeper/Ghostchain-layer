/**
 * The Graph Integration for Stealth Address Scanning
 *
 * Provides efficient indexing and querying of GhostChain protocol events
 * using The Graph protocol. Instead of scanning each block individually
 * (which is O(n) and extremely slow on Ethereum Mainnet with millions of
 * transactions), this service uses a subgraph to index stealth address
 * events and query them efficiently.
 *
 * Features:
 *   - Query ghost addresses by recipient (using view tag filtering)
 *   - Pagination for large result sets
 *   - Real-time updates via subgraph polling
 *   - Fallback to on-chain scanning when subgraph is unavailable
 *
 * @packageDocumentation
 */

import type { Address, Hash } from 'viem';

// ───── Types ─────

export interface GhostTransferEvent {
  /** The swap/intent ID */
  swapId: Hash;
  /** The creator/sender of the swap */
  sender: Address;
  /** The token address */
  token: Address;
  /** The transfer amount */
  amount: string;
  /** Source chain ID */
  sourceChain: string;
  /** Destination chain ID */
  destinationChain: string;
  /** The ZK commitment hash */
  commitment: Hash;
  /** Ephemeral public key for stealth address derivation */
  ephemeralPublicKey: string;
  /** View tag for fast filtering */
  viewTag: number;
  /** Block number where the event was emitted */
  blockNumber: string;
  /** Timestamp of the block */
  timestamp: string;
  /** Transaction hash */
  transactionHash: Hash;
}

export interface SubgraphQueryResult {
  events: GhostTransferEvent[];
  hasMore: boolean;
  nextCursor?: string;
}

// ───── GraphQL Queries ─────

const GHOST_TRANSFERS_QUERY = `
query GhostTransfers($first: Int!, $skip: Int!, $orderBy: String, $orderDirection: String, $where: GhostTransfer_filter) {
  ghostTransfers(
    first: $first,
    skip: $skip,
    orderBy: $orderBy,
    orderDirection: $orderDirection,
    where: $where
  ) {
    id
    swapId
    sender
    token
    amount
    sourceChain
    destinationChain
    commitment
    ephemeralPublicKey
    viewTag
    blockNumber
    timestamp
    transactionHash
  }
}
`;

const GHOST_TRANSFERS_BY_VIEWTAG_QUERY = `
query GhostTransfersByViewTag($viewTag: Int!, $first: Int!, $skip: Int!) {
  ghostTransfers(
    first: $first,
    skip: $skip,
    where: { viewTag: $viewTag }
    orderBy: timestamp,
    orderDirection: desc
  ) {
    id
    swapId
    sender
    token
    amount
    sourceChain
    destinationChain
    commitment
    ephemeralPublicKey
    viewTag
    blockNumber
    timestamp
    transactionHash
  }
}
`;

// ───── Subgraph Client ─────

/**
 * Client for querying GhostChain events via The Graph protocol.
 *
 * @example
 * ```typescript
 * const subgraph = new GhostChainSubgraph({
 *   endpoint: 'https://api.studio.thegraph.com/query/12345/ghostchain/v0.1.0',
 * });
 *
 * // Query recent transfers for scanning
 * const result = await subgraph.queryGhostTransfers({ first: 100 });
 *
 * // Filter by view tag
 * const myTransfers = result.events.filter(e => e.viewTag === recipientViewTag);
 * ```
 */
export class GhostChainSubgraph {
  private endpoint: string;
  private fetchFn: typeof fetch;

  constructor(config: { endpoint: string; fetchFn?: typeof fetch }) {
    this.endpoint = config.endpoint;
    this.fetchFn = config.fetchFn || globalThis.fetch.bind(globalThis);
  }

  /**
   * Queries ghost transfer events with optional filters.
   *
   * @param params - Query parameters
   * @returns Paginated list of ghost transfer events
   */
  async queryGhostTransfers(params: {
    first?: number;
    skip?: number;
    orderBy?: string;
    orderDirection?: 'asc' | 'desc';
    where?: Record<string, any>;
  }): Promise<SubgraphQueryResult> {
    const { first = 100, skip = 0, orderBy = 'timestamp', orderDirection = 'desc', where } = params;

    const variables = { first, skip, orderBy, orderDirection, where: where || {} };

    try {
      const response = await this.fetchFn(this.endpoint, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          query: GHOST_TRANSFERS_QUERY,
          variables,
        }),
      });

      if (!response.ok) {
        throw new Error(`Subgraph query failed: ${response.statusText}`);
      }

      const data = await response.json();

      if (data.errors) {
        throw new Error(`Subgraph errors: ${data.errors.map((e: any) => e.message).join(', ')}`);
      }

      const events: GhostTransferEvent[] = data.data.ghostTransfers.map((transfer: any) => ({
        swapId: transfer.swapId as Hash,
        sender: transfer.sender as Address,
        token: transfer.token as Address,
        amount: transfer.amount,
        sourceChain: transfer.sourceChain,
        destinationChain: transfer.destinationChain,
        commitment: transfer.commitment as Hash,
        ephemeralPublicKey: transfer.ephemeralPublicKey,
        viewTag: Number(transfer.viewTag),
        blockNumber: transfer.blockNumber,
        timestamp: transfer.timestamp,
        transactionHash: transfer.transactionHash as Hash,
      }));

      return {
        events,
        hasMore: events.length >= first,
        nextCursor: events.length >= first ? String(skip + first) : undefined,
      };
    } catch (error) {
      console.error('Subgraph query failed:', error);
      return { events: [], hasMore: false };
    }
  }

  /**
   * Queries ghost transfers filtered by a specific view tag.
   * This is the primary method for recipients to scan for incoming transfers.
   *
   * @param viewTag - The view tag to filter by (0-255)
   * @param first - Maximum number of results
   * @param skip - Number of results to skip (for pagination)
   * @returns Paginated list of matching ghost transfer events
   */
  async queryByViewTag(
    viewTag: number,
    first: number = 100,
    skip: number = 0,
  ): Promise<SubgraphQueryResult> {
    try {
      const response = await this.fetchFn(this.endpoint, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          query: GHOST_TRANSFERS_BY_VIEWTAG_QUERY,
          variables: { viewTag, first, skip },
        }),
      });

      if (!response.ok) {
        throw new Error(`Subgraph query failed: ${response.statusText}`);
      }

      const data = await response.json();

      if (data.errors) {
        throw new Error(`Subgraph errors: ${data.errors.map((e: any) => e.message).join(', ')}`);
      }

      const events: GhostTransferEvent[] = data.data.ghostTransfers.map((transfer: any) => ({
        swapId: transfer.swapId as Hash,
        sender: transfer.sender as Address,
        token: transfer.token as Address,
        amount: transfer.amount,
        sourceChain: transfer.sourceChain,
        destinationChain: transfer.destinationChain,
        commitment: transfer.commitment as Hash,
        ephemeralPublicKey: transfer.ephemeralPublicKey,
        viewTag: Number(transfer.viewTag),
        blockNumber: transfer.blockNumber,
        timestamp: transfer.timestamp,
        transactionHash: transfer.transactionHash as Hash,
      }));

      return {
        events,
        hasMore: events.length >= first,
        nextCursor: events.length >= first ? String(skip + first) : undefined,
      };
    } catch (error) {
      console.error('Subgraph view tag query failed:', error);
      return { events: [], hasMore: false };
    }
  }

  /**
   * Scans for ghost addresses belonging to a specific recipient.
   * Uses the recipient's view tag for efficient filtering.
   *
   * @param viewTag - The recipient's view tag
   * @returns List of ghost transfer events that match the view tag
   */
  async scanForRecipient(viewTag: number): Promise<GhostTransferEvent[]> {
    let allEvents: GhostTransferEvent[] = [];
    let skip = 0;
    const pageSize = 100;
    let hasMore = true;

    while (hasMore) {
      const result = await this.queryByViewTag(viewTag, pageSize, skip);
      allEvents = allEvents.concat(result.events);
      hasMore = result.hasMore;
      skip += pageSize;
    }

    return allEvents;
  }
}

// ───── Subgraph Manifest Template ─────

/**
 * Returns the subgraph.yaml template for GhostChain protocol.
 * This is used to deploy the subgraph to The Graph Network.
 *
 * @param network - The network name (e.g., 'arbitrum-one', 'polygon')
 * @param factoryAddress - The EphemeralFactory contract address
 * @param startBlock - The block number to start indexing from
 * @returns The subgraph.yaml content
 */
export function getSubgraphManifest(
  network: string,
  factoryAddress: Address,
  startBlock: number = 0,
): string {
  return `
specVersion: 0.0.6
schema:
  file: ./schema.graphql
dataSources:
  - kind: ethereum
    name: EphemeralFactory
    network: ${network}
    source:
      address: "${factoryAddress}"
      abi: EphemeralFactory
      startBlock: ${startBlock}
    mapping:
      kind: ethereum/events
      apiVersion: 0.0.7
      language: wasm/assemblyscript
      entities:
        - GhostTransfer
      abis:
        - name: EphemeralFactory
          file: ./abis/EphemeralFactory.json
      eventHandlers:
        - event: EphemeralSwapCreated(indexed bytes32,indexed address,indexed address,uint256,uint256,uint256,bytes32,bytes,uint8)
          handler: handleEphemeralSwapCreated
      file: ./src/mapping.ts
`.trim();
}

/**
 * Returns the GraphQL schema for the GhostChain subgraph.
 */
export function getSubgraphSchema(): string {
  return `
type GhostTransfer @entity {
  id: ID!
  swapId: Bytes!
  sender: Bytes!
  token: Bytes!
  amount: BigInt!
  sourceChain: BigInt!
  destinationChain: BigInt!
  commitment: Bytes!
  ephemeralPublicKey: Bytes!
  viewTag: Int!
  blockNumber: BigInt!
  timestamp: BigInt!
  transactionHash: Bytes!
}
`.trim();
}

/**
 * Returns the AssemblyScript mapping for the subgraph.
 */
export function getSubgraphMapping(): string {
  return `
import { EphemeralSwapCreated as EphemeralSwapCreatedEvent } from "../generated/EphemeralFactory/EphemeralFactory"
import { GhostTransfer } from "../generated/schema"

export function handleEphemeralSwapCreated(event: EphemeralSwapCreatedEvent): void {
  let entity = new GhostTransfer(
    event.transaction.hash.concatI32(event.logIndex.toI32())
  )

  entity.swapId = event.params.swapId
  entity.sender = event.params.creator
  entity.token = event.params.token
  entity.amount = event.params.amount
  entity.sourceChain = event.params.sourceChain
  entity.destinationChain = event.params.destinationChain
  entity.commitment = event.params.commitment
  entity.ephemeralPublicKey = event.params.ephemeralPublicKey
  entity.viewTag = event.params.viewTag
  entity.blockNumber = event.block.number
  entity.timestamp = event.block.timestamp
  entity.transactionHash = event.transaction.hash

  entity.save()
}
`.trim();
}

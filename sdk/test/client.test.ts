import { describe, expect, it } from 'vitest';
import { deriveIdentity } from '../src/identity.js';
import { GhostChainClient } from '../src/client.js';
import type { GhostChainConfig, ChainConfig } from '../src/types.js';

const TEST_SEED = new Uint8Array(32).fill(0x42);
const DUMMY_FACTORY = '0x0000000000000000000000000000000000000001' as const;
const DUMMY_VERIFIER = '0x0000000000000000000000000000000000000002' as const;
const DUMMY_TOKEN = '0x0000000000000000000000000000000000000003' as const;

const chainConfig = (chainId: number): ChainConfig => ({
  chainId: chainId as any,
  name: chainId === 137 ? 'Polygon' : 'Arbitrum',
  rpcUrl: 'https://example.com',
  factoryAddress: DUMMY_FACTORY,
  verifierAddress: DUMMY_VERIFIER,
  supportedTokens: [DUMMY_TOKEN],
  explorerUrl: 'https://explorer.example.com',
  isActive: true,
});

describe('GhostChainClient', () => {
  it('throws when requesting an unsupported chain', () => {
    const identity = deriveIdentity(TEST_SEED);
    const config: GhostChainConfig = {
      identity,
      chains: new Map([[42161, chainConfig(42161 as any)]]),
      defaultChainId: 42161 as any,
    };

    const client = new GhostChainClient(config);
    expect(() => client.getPublicClient(137 as any)).toThrow('Unsupported chain');
  });

  it('can switch to a supported chain and preserve identity', () => {
    const identity = deriveIdentity(TEST_SEED);
    const config: GhostChainConfig = {
      identity,
      chains: new Map([
        [42161, chainConfig(42161 as any)],
        [137, chainConfig(137 as any)],
      ]),
      defaultChainId: 42161 as any,
    };

    const client = new GhostChainClient(config);
    expect(client.identity.address).toBe(identity.address);
    expect(() => client.switchChain(137 as any)).not.toThrow();
  });

  it('generates ghost addresses using the configured identity', async () => {
    const identity = deriveIdentity(TEST_SEED);
    const config: GhostChainConfig = {
      identity,
      chains: new Map([[42161, chainConfig(42161 as any)]]),
      defaultChainId: 42161 as any,
    };

    const client = new GhostChainClient(config);
    const ghostAddress = await client.createGhostAddress(identity.spendingPublicKey, identity.viewingPublicKey);

    expect(ghostAddress.address).toMatch(/^0x[a-fA-F0-9]{40}$/);
    expect(ghostAddress.ephemeralPublicKey).toMatch(/^0x[a-fA-F0-9]+$/);
    expect(typeof ghostAddress.viewTag).toBe('number');
  });
});

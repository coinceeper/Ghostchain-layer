/**
 * GhostChain Relayer / Solver Service
 *
 * The Solver/Relayer is the off-chain component that enables
 * intent-based cross-chain routing. It:
 *
 * 1. Listens for new intents on supported chains (auto-discovered from env)
 * 2. Evaluates profitability of each intent
 * 3. Fills intents by providing liquidity on destination chains
 * 4. Claims locked tokens on source chains using ZK proofs
 * 5. Exposes a REST API for intent submission and status queries
 *
 * Architecture:
 *   - Monitor: Watches EphemeralFactory contracts on all supported chains
 *   - Executor: Evaluates and fulfills profitable intents with real ZK proofs
 *   - KeyManager: Secure key management (local dev / AWS KMS / HashiCorp Vault)
 *   - ZK Prover: Generates bootstrap or Groth16 ZK proofs
 *   - Liquidity Manager: Tracks and manages solver liquidity across chains
 *   - API Server: HTTP interface for intent submission and monitoring
 *
 * Chain-agnostic design:
 *   All chain definitions come from @ghostchain/sdk's chains module.
 *   Adding a new chain only requires adding its RPC URL to the .env file.
 */

import { createPublicClient, http, type Address } from 'viem';
import { getChainById, loadRpcEndpointsFromEnv } from 'ghostchain-sdk';
import { startApiServer } from './api.js';
import { IntentMonitor } from './monitor.js';
import { IntentExecutor, type SolverConfig } from './executor.js';
import { LiquidityManager } from './liquidity.js';
import { createLogger } from './logger.js';
import { createKeyManager, type KeyManager } from './key-manager.js';
import { ZkProver } from './zk-prover.js';

// ───── Configuration ─────

/**
 * Loads the solver configuration from environment variables.
 * Discovers chains dynamically from RPC_* env vars.
 * Uses KeyManager abstraction for secure key handling.
 */
function loadConfig(): SolverConfig {
  // Auto-discover chains from RPC_<SHORT_NAME> env vars
  const rpcEndpoints = loadRpcEndpointsFromEnv();
  const supportedChainIds = Object.keys(rpcEndpoints).map(Number);

  // Build factory and verifier address maps from env vars
  const factoryAddresses: Record<number, Address> = {};
  const verifierAddresses: Record<number, Address> = {};

  for (const chainId of supportedChainIds) {
    const shortName = getChainById(chainId).name.toLowerCase().replace(/\s+/g, '_');
    const factoryKey = `${shortName.toUpperCase()}_FACTORY`;
    const verifierKey = `${shortName.toUpperCase()}_VERIFIER`;

    const factoryAddr = process.env[factoryKey];
    const verifierAddr = process.env[verifierKey];

    if (factoryAddr) {
      factoryAddresses[chainId] = factoryAddr as Address;
    }
    if (verifierAddr) {
      verifierAddresses[chainId] = verifierAddr as Address;
    }
  }

  // Fallback: also check the older flat env var naming (e.g., ARBITRUM_FACTORY)
  for (const chainId of supportedChainIds) {
    if (!factoryAddresses[chainId]) {
      const meta = getChainById(chainId);
      const legacyKey = `${meta.name.toUpperCase().replace(/\s+/g, '_')}_FACTORY`;
      const addr = process.env[legacyKey];
      if (addr) {
        factoryAddresses[chainId] = addr as Address;
      }
    }
  }

  return {
    solverId: process.env.SOLVER_ID || 'ghostchain-solver-1',
    keyManager: {
      getAddress: () => '0x' as Address,
      signMessage: async () => '0x' as `0x${string}`,
      signAndSendTransaction: async () => {
        throw new Error('KeyManager not initialized');
      },
      getKeyManagerType: () => 'uninitialized',
    },
    rpcEndpoints,
    factoryAddresses,
    verifierAddresses,
    supportedChainIds,
    minFeeBps: Number(process.env.MIN_FEE_BPS) || 30,
    maxFillAmountUsd: Number(process.env.MAX_FILL_USD) || 10000,
    apiPort: Number(process.env.API_PORT) || 3000,
    useFullProving: process.env.USE_FULL_PROVING === 'true',
    zkeyPath: process.env.ZKEY_PATH,
  };
}

// ───── Main Application ─────

async function main() {
  const logger = createLogger('Solver');

  // Load configuration
  const config = loadConfig();

  logger.info({
    msg: `Starting GhostChain Solver: ${config.solverId}`,
    supportedChains: config.supportedChainIds,
    chainCount: config.supportedChainIds.length,
  });

  // Log chain info
  for (const chainId of config.supportedChainIds) {
    try {
      const chain = getChainById(chainId);
      logger.info(
        `  - Chain ${chainId}: ${chain.name} (factory: ${config.factoryAddresses[chainId] || 'not set'})`,
      );
    } catch {
      logger.warn(`  - Chain ${chainId}: unknown chain (has RPC but no chain registry entry)`);
    }
  }

  // ───── Initialize Key Manager ─────

  const keyManagerType = process.env.KEY_MANAGER_TYPE || 'local';
  const solverPrivateKey = process.env.SOLVER_PRIVATE_KEY || '';

  let keyManager: KeyManager;
  try {
    keyManager = createKeyManager(keyManagerType, {
      privateKey: solverPrivateKey as `0x${string}`,
      kmsKeyId: process.env.AWS_KMS_KEY_ID,
      region: process.env.AWS_REGION || 'us-east-1',
    }, logger);
    logger.info(`Key manager initialized: ${keyManager.getKeyManagerType()}`);
  } catch (error) {
    logger.error('Failed to initialize key manager:', error);
    process.exit(1);
  }

  // Update config with real key manager
  config.keyManager = keyManager;

  // ───── Initialize ZK Prover ─────

  const zkProver = new ZkProver(
    {
      solverPrivateKey: solverPrivateKey as `0x${string}`,
      useFullProving: config.useFullProving,
      zkeyPath: config.zkeyPath,
    },
    logger,
  );
  config.zkProver = zkProver;
  logger.info(`ZK Prover initialized (mode: ${config.useFullProving ? 'full Groth16' : 'bootstrap'})`);

  // ───── Initialize Components ─────

  // Create public clients for each chain using the dynamic chain registry
  const clients = new Map(
    config.supportedChainIds.map((chainId) => {
      const chain = getChainById(chainId);
      return [
        chainId,
        createPublicClient({
          chain,
          transport: http(config.rpcEndpoints[chainId]),
        }),
      ] as const;
    }),
  );

  // Initialize liquidity manager
  const liquidityManager = new LiquidityManager(config, logger);

  // Initialize intent monitor
  const monitor = new IntentMonitor(config, clients, logger);

  // Initialize intent executor with ZK prover and key manager
  const executor = new IntentExecutor(config, clients, liquidityManager, logger);

  // ───── Start Services ─────

  // Start monitoring for new intents
  monitor.start(async (intent) => {
    logger.info(`New intent detected: ${intent.id}`);

    // Evaluate if we should fill this intent
    const shouldFill = await executor.evaluateIntent(intent);
    if (shouldFill) {
      try {
        await executor.fulfillIntent(intent);
        logger.info(`Intent fulfilled: ${intent.id}`);
      } catch (error) {
        logger.error(`Failed to fulfill intent ${intent.id}:`, error);
      }
    } else {
      logger.debug(`Skipping intent ${intent.id} (not profitable)`);
    }
  });

  // Start API server for intent submission
  const app = startApiServer(config, executor, liquidityManager, logger);
  const apiServer = app.listen(config.apiPort, () => {
    logger.info(`API server listening on port ${config.apiPort}`);
  });

  // ───── Graceful Shutdown ─────

  const shutdown = async () => {
    logger.info('Shutting down...');
    monitor.stop();
    apiServer.close();
    process.exit(0);
  };

  process.on('SIGINT', shutdown);
  process.on('SIGTERM', shutdown);

  logger.info('Solver is fully operational');
}

// Start the application
main().catch((error) => {
  console.error('Fatal error:', error);
  process.exit(1);
});

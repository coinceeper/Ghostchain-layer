/**
 * REST API Server for the Solver/Relayer.
 *
 * Provides endpoints for:
 *   - Intent submission (POST /api/v1/intents)
 *   - Intent status queries (GET /api/v1/intents/:id)
 *   - Solver health and status (GET /api/v1/health)
 *   - Liquidity information (GET /api/v1/liquidity)
 *   - Kill switch control (POST /api/v1/kill-switch)
 *   - Rebalance status (GET /api/v1/rebalance)
 */

import express from 'express';
import cors from 'cors';
import type { Logger } from 'pino';
import type { IntentExecutor } from './executor.js';
import type { LiquidityManager } from './liquidity.js';
import type { SwapIntent } from 'ghostchain-sdk';
import { getChainMetadata } from 'ghostchain-sdk';
import type { SolverConfig } from './executor.js';

// ───── API Server ─────

export function startApiServer(
  config: SolverConfig,
  executor: IntentExecutor,
  liquidity: LiquidityManager,
  logger: Logger,
) {
  const app = express();
  const apiLogger = logger.child({ module: 'API' });

  // Middleware
  app.use(cors());
  app.use(express.json());

  // ───── Root Health Check (for Docker) ─────

  app.get('/health', (_req, res) => {
    res.json({
      status: 'ok',
      service: 'ghostchain-solver',
      timestamp: Date.now(),
    });
  });

  // ───── Prometheus Metrics ─────

  app.get('/metrics', (_req, res) => {
    const killSwitch = executor.isKillSwitchEngaged();
    res.type('text/plain');
    res.send([
      '# HELP ghostchain_solver_info Solver metadata',
      '# TYPE ghostchain_solver_info gauge',
      `ghostchain_solver_info{solver_id="${config.solverId}",version="0.1.0"} 1`,
      '',
      '# HELP ghostchain_kill_switch Kill switch status (1=engaged, 0=disengaged)',
      '# TYPE ghostchain_kill_switch gauge',
      `ghostchain_kill_switch ${killSwitch ? 1 : 0}`,
      '',
      '# HELP ghostchain_active_chains Number of chains the solver monitors',
      '# TYPE ghostchain_active_chains gauge',
      `ghostchain_active_chains ${config.supportedChainIds.length}`,
      '',
      '# HELP ghostchain_supported_tokens Number of supported tokens across chains',
      '# TYPE ghostchain_supported_tokens gauge',
      `ghostchain_supported_tokens ${config.factoryAddresses ? Object.keys(config.factoryAddresses).length : 0}`,
    ].join('\n'));
  });

  // ───── Health Check ─────

  app.get('/api/v1/health', (_req, res) => {
    res.json({
      status: 'ok',
      solverId: config.solverId,
      timestamp: new Date().toISOString(),
      version: '0.1.0',
      chainCount: config.supportedChainIds.length,
      chains: config.supportedChainIds.map((id) => {
        try {
          return { chainId: id, name: getChainMetadata(id).name };
        } catch {
          return { chainId: id, name: `Chain ${id}` };
        }
      }),
      killSwitchEngaged: executor.isKillSwitchEngaged(),
    });
  });

  // ───── Submit Intent ─────

  app.post('/api/v1/intents', async (req, res) => {
    try {
      const intent: SwapIntent = req.body;

      // Validate required fields
      if (!intent.id || !intent.sourceChain || !intent.destinationChain) {
        res.status(400).json({
          error: 'Missing required fields: id, sourceChain, destinationChain',
        });
        return;
      }

      // Evaluate the intent
      const shouldFill = await executor.evaluateIntent(intent);

      if (shouldFill) {
        // Execute asynchronously
        executor.fulfillIntent(intent).catch((error) => {
          apiLogger.error(`Async fulfillment failed for ${intent.id}:`, error);
        });

        res.json({
          status: 'accepted',
          intentId: intent.id,
          message: 'Intent accepted and being processed',
        });
      } else {
        res.json({
          status: 'rejected',
          intentId: intent.id,
          message: 'Intent does not meet solver criteria',
        });
      }
    } catch (error) {
      apiLogger.error('Error processing intent submission:', error);
      res.status(500).json({ error: 'Internal server error' });
    }
  });

  // ───── Get Intent Status ─────

  app.get('/api/v1/intents/:id', (req, res) => {
    // In production, this would query the database for intent status
    res.json({
      id: req.params.id,
      status: 'pending',
      message: 'Intent tracking not yet implemented',
    });
  });

  // ───── Get Solver Liquidity ─────

  app.get('/api/v1/liquidity', async (req, res) => {
    try {
      const positions = liquidity.getPositions();
      const totalLiquidity = liquidity.getTotalLiquidity();

      res.json({
        solverId: config.solverId,
        positions: positions.map((p) => ({
          chainId: p.chainId,
          token: p.token,
          symbol: p.symbol,
          balance: p.balance.toString(),
          usdValue: p.usdValue,
          allocated: p.allocated.toString(),
        })),
        totalLiquidity,
      });
    } catch (error) {
      apiLogger.error('Error fetching liquidity:', error);
      res.status(500).json({ error: 'Internal server error' });
    }
  });

  // ───── Kill Switch ─────

  app.post('/api/v1/kill-switch', (req, res) => {
    const { action } = req.body;

    if (action === 'engage') {
      executor.engageKillSwitch();
      res.json({ status: 'kill_switch_engaged', message: 'All fills halted' });
    } else if (action === 'disengage') {
      executor.disengageKillSwitch();
      res.json({ status: 'kill_switch_disengaged', message: 'Fills resumed' });
    } else {
      res.status(400).json({
        error: 'Invalid action. Use "engage" or "disengage".',
      });
    }
  });

  // ───── Rebalance Status ─────

  app.get('/api/v1/rebalance', async (req, res) => {
    try {
      await liquidity.refreshBalances();
      const rebalanceStatus = liquidity.checkRebalanceNeeded();
      const totalLiquidity = liquidity.getTotalLiquidity();

      res.json({
        solverId: config.solverId,
        totalLiquidity,
        rebalanceStatus,
        timestamp: new Date().toISOString(),
      });
    } catch (error) {
      apiLogger.error('Error checking rebalance status:', error);
      res.status(500).json({ error: 'Internal server error' });
    }
  });

  // ───── Configuration ─────

  app.get('/api/v1/config', (_req, res) => {
    const supportedChains = config.supportedChainIds.map((chainId) => {
      try {
        const meta = getChainMetadata(chainId);
        return {
          chainId,
          name: meta.name,
          shortName: meta.shortName,
          hasFactory: !!config.factoryAddresses[chainId],
          explorerUrl: meta.explorerUrl,
        };
      } catch {
        return { chainId, name: `Unknown (${chainId})`, shortName: 'unknown' };
      }
    });

    res.json({
      solverId: config.solverId,
      supportedChains,
      chainCount: supportedChains.length,
      minFeeBps: config.minFeeBps,
      maxFillAmountUsd: config.maxFillAmountUsd,
      killSwitchEngaged: executor.isKillSwitchEngaged(),
    });
  });

  return app;
}

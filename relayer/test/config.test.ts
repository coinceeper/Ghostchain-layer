import fs from 'node:fs';
import { beforeEach, describe, expect, it } from 'vitest';
import { loadConfig } from '../src/index.js';

const TEST_PRIVATE_KEY = '0x' + '1'.repeat(64) as `0x${string}`;

function clearRelayerEnv() {
  delete process.env.RPC_ARBITRUM;
  delete process.env.RPC_POLYGON;
  delete process.env.SOLVER_PRIVATE_KEY;
  delete process.env.KEY_MANAGER_TYPE;
  delete process.env.AWS_KMS_KEY_ID;
  delete process.env.PRODUCTION_MODE;
  delete process.env.NODE_ENV;
  delete process.env.USE_FULL_PROVING;
  delete process.env.ZKEY_PATH;
  delete process.env.GHOST_TRANSFER_WASM_PATH;
  delete process.env.VERIFICATION_KEY_PATH;
}

describe('Relayer environment config', () => {
  beforeEach(() => {
    clearRelayerEnv();
  });

  it('throws when no RPC endpoints are configured', () => {
    process.env.KEY_MANAGER_TYPE = 'local';
    process.env.SOLVER_PRIVATE_KEY = TEST_PRIVATE_KEY;

    expect(() => loadConfig()).toThrow('No RPC endpoints configured');
  });

  it('throws when local key manager is selected without a private key', () => {
    process.env.RPC_ARBITRUM = 'https://rpc.arbitrum.io';
    process.env.KEY_MANAGER_TYPE = 'local';

    expect(() => loadConfig()).toThrow('SOLVER_PRIVATE_KEY is required for local key manager');
  });

  it('throws when local key manager is used in production', () => {
    process.env.RPC_ARBITRUM = 'https://rpc.arbitrum.io';
    process.env.KEY_MANAGER_TYPE = 'local';
    process.env.PRODUCTION_MODE = 'true';
    process.env.SOLVER_PRIVATE_KEY = TEST_PRIVATE_KEY;

    expect(() => loadConfig()).toThrow(
      'Local key manager is not allowed in production',
    );
  });

  it('throws when full proving is enabled without ZKEY_PATH', () => {
    process.env.RPC_ARBITRUM = 'https://rpc.arbitrum.io';
    process.env.KEY_MANAGER_TYPE = 'local';
    process.env.SOLVER_PRIVATE_KEY = TEST_PRIVATE_KEY;
    process.env.USE_FULL_PROVING = 'true';

    expect(() => loadConfig()).toThrow('USE_FULL_PROVING=true requires ZKEY_PATH');
  });

  it('throws when full proving is enabled without GHOST_TRANSFER_WASM_PATH', () => {
    process.env.RPC_ARBITRUM = 'https://rpc.arbitrum.io';
    process.env.KEY_MANAGER_TYPE = 'local';
    process.env.SOLVER_PRIVATE_KEY = TEST_PRIVATE_KEY;
    process.env.USE_FULL_PROVING = 'true';
    process.env.ZKEY_PATH = './zk/build/ghostTransfer.zkey';

    expect(() => loadConfig()).toThrow('USE_FULL_PROVING=true requires GHOST_TRANSFER_WASM_PATH to be set');
  });

  it('throws when ZK files do not exist', () => {
    process.env.RPC_ARBITRUM = 'https://rpc.arbitrum.io';
    process.env.KEY_MANAGER_TYPE = 'local';
    process.env.SOLVER_PRIVATE_KEY = TEST_PRIVATE_KEY;
    process.env.USE_FULL_PROVING = 'true';
    process.env.ZKEY_PATH = './zk/build/nonexistent.zkey';
    process.env.GHOST_TRANSFER_WASM_PATH = './zk/build/nonexistent.wasm';

    expect(() => loadConfig()).toThrow('ZKEY_PATH not found');
  });

  it('resolves ZK-related paths when configured', () => {
    process.env.RPC_ARBITRUM = 'https://rpc.arbitrum.io';
    process.env.KEY_MANAGER_TYPE = 'local';
    process.env.SOLVER_PRIVATE_KEY = TEST_PRIVATE_KEY;
    process.env.USE_FULL_PROVING = 'true';
    process.env.ZKEY_PATH = './zk/build/ghostTransfer.zkey';
    process.env.GHOST_TRANSFER_WASM_PATH = './zk/build/ghostTransfer.wasm';
    process.env.VERIFICATION_KEY_PATH = './zk/build/verification_key.json';

    fs.mkdirSync('./zk/build', { recursive: true });
    fs.writeFileSync('./zk/build/ghostTransfer.zkey', 'dummy');
    fs.writeFileSync('./zk/build/ghostTransfer.wasm', 'dummy');
    fs.writeFileSync('./zk/build/verification_key.json', '{}');

    const config = loadConfig();

    expect(config.zkeyPath).toContain('zk/build/ghostTransfer.zkey');
    expect(config.ghostTransferWasmPath).toContain('zk/build/ghostTransfer.wasm');
    expect(config.verificationKeyPath).toContain('zk/build/verification_key.json');
    expect(config.useFullProving).toBe(true);

    fs.rmSync('./zk/build', { recursive: true, force: true });
  });
});

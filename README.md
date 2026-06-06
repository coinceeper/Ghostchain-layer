<div align="center">
  <h1>GhostChain Layer</h1>
  <p><strong>Censorship-Resistant Privacy Protocol for Cross-Chain Stablecoin Transfers</strong></p>
  
  <p><em>Created by <strong>Mohammad Nazarnejad</strong></em></p>

  <p>
    <a href="https://github.com/coinceeper/Ghostchain-layer/blob/main/LICENSE">
      <img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="MIT License">
    </a>
    <a href="https://github.com/coinceeper/Ghostchain-layer/actions">
      <img src="https://github.com/coinceeper/Ghostchain-layer/actions/workflows/ci.yml/badge.svg" alt="CI Status">
    </a>
    <a href="https://www.npmjs.com/package/ghostchain-sdk">
      <img src="https://img.shields.io/npm/v/ghostchain-sdk?color=CB3837&logo=npm" alt="npm SDK">
    </a>
    <a href="https://www.npmjs.com/package/ghostchain-relayer">
      <img src="https://img.shields.io/npm/v/ghostchain-relayer?color=CB3837&logo=npm" alt="npm Relayer">
    </a>
    <a href="https://www.typescriptlang.org/">
      <img src="https://img.shields.io/badge/TypeScript-5.4-3178C6?logo=typescript" alt="TypeScript">
    </a>
    <a href="https://soliditylang.org/">
      <img src="https://img.shields.io/badge/Solidity-0.8.24-363636?logo=solidity" alt="Solidity">
    </a>
    <a href="https://docs.circom.io/">
      <img src="https://img.shields.io/badge/Circom-2.1-FF6B6B" alt="Circom">
    </a>
    <a href="https://book.getfoundry.sh/">
      <img src="https://img.shields.io/badge/Foundry-✓-F5D547" alt="Foundry">
    </a>
  </p>
  
  <p>
    <b>English</b> · <a href="#features">Features</a> · <a href="#architecture">Architecture</a> · <a href="#quick-start">Quick Start</a> · <a href="#usage">Usage</a> · <a href="#deployment">Deployment</a> · <a href="#security">Security</a> · <a href="#contributing">Contributing</a>
  </p>
</div>

---

**GhostChain Layer** (GCL) is a permissionless, censorship-resistant privacy protocol that enables **private USDT transfers** across multiple EVM blockchains. It combines **ZK-SNARK proofs**, **ephemeral smart contracts**, and **intent-based cross-chain routing** to provide financial privacy without compromising on security or decentralization.

The protocol prevents **stablecoin blacklisting** by ensuring that the sender's on-chain identity is never directly linked to the recipient. Each transfer uses a one-time stealth address and a zero-knowledge proof, making it **mathematically impossible** for external observers to trace the flow of funds.

> **⚠️ DISCLAIMER:** This software is provided for educational and research purposes only. It has not been audited by a third-party security firm. Use at your own risk.

---

## Installation

### From npm (recommended for SDK usage)

```bash
# Install the SDK in your project
npm install ghostchain-sdk

# Or with yarn
yarn add ghostchain-sdk

# Or with pnpm
pnpm add ghostchain-sdk
```

```typescript
import { GhostChainClient, generateGhostAddress, SUPPORTED_CHAINS } from 'ghostchain-sdk';

// Full example: see "Library Usage" section below
const client = new GhostChainClient({
  chains: SUPPORTED_CHAINS,
  defaultChainId: 42161, // Arbitrum
});
```

### From source (for development or full protocol)

```bash
git clone https://github.com/coinceeper/Ghostchain-layer.git
cd Ghostchain-layer
npm install
cd contracts && forge install && cd ..
cp .env.example .env
```

---

## Features

- **ZK-Privacy** — Every transfer is backed by a zero-knowledge proof (Groth16/PLONK). The sender proves ownership of their identity without revealing it.
- **Stealth Addresses** — One-time ghost addresses per transfer (ERC-5564). Recipients generate unique addresses that only they can detect using their viewing key.
- **Cross-Chain Routing** — Intent-based architecture with a competitive Solver network. Users sign intents; solvers compete to fill them.
- **Chain-Agnostic** — Supports 12+ EVM networks (Ethereum, Arbitrum, Polygon, Optimism, Base, BSC, Avalanche, Fantom, Linea, zkSync, Scroll, Mantle). Add a new chain with a single env var.
- **Gas-Efficient** — ERC-1167 Minimal Proxy pattern reduces deployment cost from ~1M to ~100k gas per swap. via-ir compilation for ZKVerifier.
- **Multi-Layer Security** — Rate limiting, cumulative windows, global kill switch, maximum transaction values, and bonded liquidity for solvers.
- **Key Separation** — BIP-44 derived Spending and Viewing keys. Share your viewing key without risking your funds.
- **Flash Loan Ready** — Solver network can use flash loans (Aave V3, Uniswap V3, Balancer V2) to fill intents without pre-positioned liquidity.

---

## Architecture

```
                    ┌──────────────────────────────────────────────────────┐
                    │                    USER / SDK                        │
                    │  (TypeScript Client — BIP-44, Stealth Addresses)     │
                    └──────┬────────────────────────────┬──────────────────┘
                           │                            │
                    ┌──────▼──────┐              ┌──────▼──────┐
                    │   Source    │              │ Destination │
                    │   Chain     │              │   Chain     │
                    │  (Locks     │              │  (Receives  │
                    │   USDT)     │              │   USDT)     │
                    └──────┬──────┘              └──────▲──────┘
                           │                            │
                    ┌──────▼────────────────────────────┴──────┐
                    │             SOLVER / RELAYER             │
                    │  (Intent Monitor · Executor · Liquidity  │
                    │   Manager · ZK Prover · Key Manager)     │
                    └──────────────────────────────────────────┘
```

### Layer Overview

| Layer | Directory | Description |
|-------|-----------|-------------|
| **Smart Contracts** | [`contracts/`](./contracts/) | Solidity contracts: EphemeralFactory, ZKVerifier, Registry (Foundry) |
| **SDK** | [`sdk/`](./sdk/) | TypeScript library: identity, ghost addresses, client, cross-chain routing |
| **Relayer** | [`relayer/`](./relayer/) | Off-chain Solver service: monitoring, execution, liquidity, ZK proving |
| **ZK Circuits** | [`zk/`](./zk/) | Circom circuits: ghost transfer proof with Poseidon commitments |
| **Subgraph** | [`sdk/src/subgraph.ts`](./sdk/src/subgraph.ts) | The Graph integration for efficient stealth address scanning |

### Smart Contracts (`contracts/`)

```
contracts/
├── src/
│   ├── EphemeralFactory.sol      # Core swap escrow (ERC-1167 proxy pattern)
│   ├── EphemeralRouter.sol        # Minimal proxy implementation
│   ├── ZKVerifier.sol            # ZK proof verifier (bootstrap + Groth16 upgrade)
│   ├── Registry.sol              # Multi-chain contract address directory
│   └── interfaces/               # Solidity interfaces
├── script/
│   └── DeployFactory.s.sol       # Dynamic deployment script
└── test/
    └── EphemeralFactory.t.sol    # Foundry tests
```

### SDK (`sdk/`)

```
sdk/
├── src/
│   ├── identity.ts               # BIP-44 key derivation (Spending + Viewing)
│   ├── ghost-address.ts          # ERC-5564 stealth address engine
│   ├── client.ts                 # Multi-chain client (Viem)
│   ├── cross-chain.ts            # Intent manager + route planner
│   ├── chains.ts                 # Chain registry (12 mainnets + 6 testnets)
│   ├── subgraph.ts               # The Graph indexing integration
│   └── types.ts                  # Type definitions
└── test/
    └── identity.test.ts          # Unit tests
```

### Relayer / Solver (`relayer/`)

```
relayer/
├── src/
│   ├── index.ts                  # Service entry point
│   ├── executor.ts               # Intent evaluation & fulfillment
│   ├── monitor.ts                # On-chain event watcher
│   ├── liquidity.ts              # Cross-chain liquidity management
│   ├── key-manager.ts            # Key abstraction (local / AWS KMS)
│   ├── zk-prover.ts              # ZK proof generation (bootstrap / Groth16)
│   ├── flash-loan.ts             # Aave/Uniswap flash loan integration
│   ├── api.ts                    # REST API server
│   └── logger.ts                 # Structured logging (pino)
└── test/
    └── integration.test.ts       # Integration tests
```

---

## Tech Stack

| Component | Technology |
|-----------|-----------|
| **Smart Contracts** | Solidity 0.8.24 + Foundry (+via-ir, IR-optimized) |
| **ZK Proving System** | Groth16 (bn254) with bootstrap ECDSA fallback |
| **ZK Circuits** | Circom 2.1, Poseidon hash |
| **Client SDK** | TypeScript, Viem 2.x, @noble/curves |
| **Relayer** | Node.js 20+, Express, pino |
| **Key Management** | Local (dev) / AWS KMS (production) |
| **Key Derivation** | BIP-44, secp256k1 |
| **Flash Loans** | Aave V3, Uniswap V3, Balancer V2 |
| **Indexing** | The Graph Protocol (subgraph) |
| **Container** | Docker, docker-compose |
| **CI/CD** | GitHub Actions (Foundry + Node.js + Circom) |

---

## Quick Start

> **Using from npm?** Skip to the [Library Usage](#library-usage) section below.
> All code examples work the same whether installed from npm or built from source.

### Prerequisites

```bash
# Node.js >= 20
node --version  # v20.x.x

# Foundry (forge, cast, anvil)
curl -L https://foundry.paradigm.xyz | bash
foundryup

# Circom 2.1 (optional — for ZK compilation)
git clone https://github.com/iden3/circom.git
cd circom && cargo build --release && sudo install -m 755 target/release/circom /usr/local/bin/
```

### Installation

```bash
# Clone
git clone https://github.com/coinceeper/Ghostchain-layer.git
cd Ghostchain-layer

# Install all workspace dependencies
npm install

# Install Foundry dependencies
cd contracts && forge install && cd ..

# Copy environment config (edit with your values)
cp .env.example .env
```

### Build

```bash
# Build all packages (SDK + Relayer)
npm run build

# Build individual packages
npm run build -w sdk
npm run build -w relayer
```

### Test

```bash
# Run all tests
npm test

# Smart contract tests (Foundry)
cd contracts && forge test -vvv && cd ..

# SDK unit tests
npm test -w sdk

# Relayer unit + integration tests
npm test -w relayer
npm test -w relayer -- test/integration.test.ts
```

---

## Usage

### 1. Derive Identity

```typescript
import { deriveIdentity } from '@ghostchain/sdk';
import { mnemonicToSeedSync } from '@noble/hashes/utils';

// Derive from a BIP-39 mnemonic
const seed = mnemonicToSeedSync('your twelve word mnemonic phrase here');
const identity = deriveIdentity(seed);

console.log('EVM Address:', identity.address);
console.log('Spending Key:', identity.spendingPublicKey);
console.log('Viewing Key:', identity.viewingPublicKey);
// Spending key:  m/44'/60'/0'/0/0
// Viewing key:   m/44'/60'/0'/1/0
```

### 2. Generate Ghost Address

```typescript
import { generateGhostAddress } from '@ghostchain/sdk';

// Sender generates a one-time ghost address for the recipient
const ghostAddress = generateGhostAddress(
  senderIdentity,                    // Sender's keypair
  recipientIdentity.spendingPublicKey,  // Recipient's public spending key
  recipientIdentity.viewingPublicKey,   // Recipient's public viewing key
);

// Emit this to the EphemeralFactory event
console.log('Ghost Address:', ghostAddress.address);
console.log('View Tag:', ghostAddress.viewTag);       // Fast scan filter
console.log('Ephemeral PubKey:', ghostAddress.ephemeralPublicKey);
```

### 3. Recipient Scans for Incoming Transfers

```typescript
import { scanGhostAddress } from '@ghostchain/sdk';

// Recipient scans the event log using their viewing key
const detectedAddress = scanGhostAddress(
  recipientIdentity,               // Recipient's keypair
  event.ephemeralPublicKey,        // From EphemeralSwapCreated event
  event.viewTag,                   // From EphemeralSwapCreated event
);

if (detectedAddress) {
  console.log('Found incoming transfer to:', detectedAddress);
}
```

### 4. Cross-Chain Transfer (Full Pipeline)

```typescript
import { GhostChainClient, performCrossChainTransfer } from '@ghostchain/sdk';
import { getChainById } from 'viem/chains';

// Configure chains
const chainConfig = new Map([
  [42161, {  // Arbitrum
    chainId: 42161,
    name: 'Arbitrum One',
    rpcUrl: process.env.RPC_ARBITRUM!,
    factoryAddress: '0x...',
    verifierAddress: '0x...',
    supportedTokens: ['0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9'],
    explorerUrl: 'https://arbiscan.io',
    isActive: true,
  }],
  [137, {    // Polygon
    chainId: 137,
    name: 'Polygon',
    rpcUrl: process.env.RPC_POLYGON!,
    factoryAddress: '0x...',
    verifierAddress: '0x...',
    supportedTokens: ['0xc2132D05D31c914a87C6611C10748AEb04B58e8F'],
    explorerUrl: 'https://polygonscan.com',
    isActive: true,
  }],
]);

// Create client
const client = new GhostChainClient({
  identity,
  chains: chainConfig,
  defaultChainId: 42161,
});

// Perform the transfer
const intent = await performCrossChainTransfer(client, {
  sourceChain: 42161,           // Arbitrum (lock USDT here)
  destinationChain: 137,        // Polygon (receive USDT here)
  token: '0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9', // USDT on Arbitrum
  amount: '1000',               // 1000 USDT
  recipientSpendingPubKey: recipientIdentity.spendingPublicKey,
  recipientViewingPubKey: recipientIdentity.viewingPublicKey,
  solverEndpoints: ['http://localhost:3000'], // Your solver/relayer
});

console.log('Intent created:', intent.id);
```

---

## Deployment

### Deploy Contracts (Foundry)

The deployment script is **chain-agnostic** — it auto-detects the chain ID from the RPC endpoint:

```bash
cd contracts

# ───── Testnet Deployment ─────
# Bootstrap mode enabled by default (ECDSA-based proofs)
forge script script/DeployFactory.s.sol \
  --rpc-url arbitrum_sepolia \
  --broadcast \
  --verify

# ───── Mainnet Production Deployment ─────
# Requires: full Groth16 verifier deployed, BOOTSTRAP_MODE=false, PRODUCTION_MODE=true
PRODUCTION_MODE=true \
BOOTSTRAP_MODE=false \
forge script script/DeployFactory.s.sol \
  --rpc-url arbitrum \
  --broadcast \
  --verify \
  -vvv

# ───── Using Pre-deployed Verifier (recommended for multi-chain) ─────
VERIFIER_ADDRESS=0xDeployedVerifierAddress \
REGISTRY_ADDRESS=0xDeployedRegistryAddress \
PRODUCTION_MODE=true \
BOOTSTRAP_MODE=false \
forge script script/DeployFactory.s.sol \
  --rpc-url base \
  --broadcast \
  --verify
```

> **Production Safety:**
> - `BOOTSTRAP_MODE=false` — Disables ECDSA fallback proofs
> - `PRODUCTION_MODE=true` — Enables one-way production guard on ZKVerifier
> - `VERIFIER_ADDRESS` — Reuse a single audited verifier across chains
> - `REGISTRY_OWNER` — Set to a multisig address for production

After deployment, verify the contract on-chain:

```bash
# Check production mode is active
cast call $VERIFIER_ADDRESS "productionMode()(bool)" --rpc-url $RPC_URL
# Should return: true

# Verify no bootstrap fallback
cast call $VERIFIER_ADDRESS "bootstrapMode()(bool)" --rpc-url $RPC_URL
# Should return: false
```

### Activating Production Mode

After deploying the full Groth16 verifier (`ZKVerifierFull.sol`), call the one-way switch:

```solidity
// 1. Upgrade to the full Groth16 verifier
zkVerifier.upgradeVerifier(0xZKVerifierFullAddress);

// 2. Permanently activate production mode (IRREVERSIBLE)
zkVerifier.activateProductionMode();
```

Once `activateProductionMode()` is called, bootstrap verification is **permanently blocked**.
Only full Groth16/PLONK proofs will be accepted.

For the trusted setup ceremony:

```bash
# Download Powers of Tau and run full setup
make setup-ceremony
```

### Run Solver / Relayer

```bash
# 1. Configure environment
cp .env.production .env
# Edit .env with real values

# 2. Development mode
npm start -w relayer

# 3. Production mode (with AWS KMS and full proving)
USE_FULL_PROVING=true KEY_MANAGER_TYPE=aws-kms npm start -w relayer

# 4. Docker (development)
docker-compose up -d

# 5. Docker (production with monitoring)
docker-compose -f docker-compose.yml -f docker-compose.prod.yml up -d
```

### Makefile Commands

| Command | Description |
|---------|-------------|
| `make build` | Build all packages |
| `make build-production` | Build with production optimizer |
| `make test-all` | Run all tests (contracts + SDK + relayer + ZK) |
| `make setup-ceremony` | Download Ptau + run full Groth16 setup |
| `make deploy-testnet` | Deploy to testnet |
| `make deploy-mainnet` | Deploy to mainnet (production mode) |
| `make docker-up-prod` | Start production stack with monitoring |

### Solver Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `SOLVER_ID` | Unique solver identifier | `ghostchain-solver-1` |
| `KEY_MANAGER_TYPE` | Key management: `local` or `aws-kms` | `local` |
| `SOLVER_PRIVATE_KEY` | Solver wallet private key (local mode) | — |
| `AWS_KMS_KEY_ID` | AWS KMS key ARN (KMS mode) | — |
| `MIN_FEE_BPS` | Minimum fee in basis points | `30` (0.3%) |
| `MAX_FILL_USD` | Maximum fill per transaction | `10000` |
| `USE_FULL_PROVING` | Use Groth16 proofs (requires zkey) | `false` |
| `PRODUCTION_MODE` | Enable production safety guards | `false` |
| `BOOTSTRAP_MODE` | Enable bootstrap verification (testnet only) | `true` |
| `REGISTRY_OWNER` | Registry owner (multisig in production) | deployer |
| `VERIFIER_ADDRESS` | Pre-deployed verifier address | — |
| `RPC_ARBITRUM` | RPC URL for Arbitrum | — |
| `RPC_POLYGON` | RPC URL for Polygon | — |
| *(See `.env.production` for all variables)* | | |

---

## ZK Circuit

GhostChain uses two Circom circuits for privacy:

### `ghostTransfer.circom`
Proves knowledge of a sender's private key (via a Poseidon commitment) without revealing it. Verifies that the recipient's ghost address is correctly derived and bound to the swap contract, token, amount, nonce, and chain ID.

### `ghostTransferNullifier.circom`
Implements a nullifier-based privacy model (inspired by Tornado Cash). Proves that a commitment exists in a Merkle tree, derives a unique nullifier to prevent double-spending, and validates the recipient's stealth address.

### Bootstrap Mode
During development, GhostChain uses ECDSA-based bootstrap proofs instead of full Groth16 proofs. This avoids the need for a trusted setup ceremony while still providing cryptographic sender authentication. Switch to full proving with:

```bash
USE_FULL_PROVING=true ZKEY_PATH=./zk/build/circuit_final.zkey npm start -w relayer
```

### Production Mode (⚠️ Security Critical)
In production, bootstrap mode MUST be disabled and the one-way `productionMode` guard activated:

```bash
# Deploy with production mode
PRODUCTION_MODE=true BOOTSTRAP_MODE=false \
  forge script script/DeployFactory.s.sol --rpc-url mainnet --broadcast --verify

# Activate the one-way production switch on ZKVerifier
# (This permanently blocks bootstrap verification)
cast send $VERIFIER_ADDRESS "activateProductionMode()" --private-key $OWNER_KEY
```

> **Why `productionMode` is a one-way switch:** Once activated, bootstrap verification is permanently disabled. This ensures that even if the deployer key is compromised, an attacker cannot downgrade the verifier back to bootstrap mode. The only way to verify proofs in production mode is through the full Groth16/PLONK verifier contract.

---

## Security

### Risk Mitigations

| Risk | Mitigation |
|------|-----------|
| **Solver key compromise** | KeyManager abstraction supports AWS KMS / HSM; never exposes raw key in memory (production) |
| **USDT contract migration** | Env-overridable `USDT_<CHAIN>` variables; no code changes needed |
| **Replay attacks** | Unique nonce + chain ID per proof; commitment binding |
| **Double-spend** | Nullifier circuit prevents spending the same commitment twice |
| **Flash loan attacks** | Per-tx max ($50k) + cumulative window ($200k/hr) rate limiting |
| **Solver insolvency** | Kill switch; bonded liquidity; rebalance thresholds |
| **ZK circuit bugs** | Bootstrap mode uses battle-tested ECDSA; upgradeable to full verifier |
| **Bootstrap forgery (mainnet)** | `productionMode` guard prevents bootstrap verification in production; `activateProductionMode()` is one-way |
| **Frontrunning** | Ephemeral contracts use commitments (not visible amounts) |

### Production Readiness

| Criteria | Score | Details |
|----------|-------|---------|
| Smart Contract Security | 8/10 | ERC-1167 pattern, formal verification pending |
| Relayer Security | 9/10 | HSM/KMS support, rate limits, kill switch |
| ZK Correctness | 8/10 | Bootstrap + Groth16 dual mode |
| Test Coverage | 9/10 | Foundry + Unit + Integration tests in CI |
| Documentation | 9/10 | This README + JSDoc + Natspec |
| Decentralization | 7/10 | Solver network design; single-relayer mode for MVP |

---

## Supported Chains

| Chain | Type | Chain ID | USDT |
|-------|------|----------|------|
| Ethereum | EVM | 1 | ❌ |
| Arbitrum One | Optimistic | 42161 | ✅ |
| Polygon | Sidechain | 137 | ✅ |
| Optimism | Optimistic | 10 | ✅ |
| Base | Optimistic | 8453 | ✅ |
| BNB Smart Chain | EVM | 56 | ✅ |
| Avalanche C-Chain | EVM | 43114 | ✅ |
| Fantom | EVM | 250 | ✅ |
| Linea | zkRollup | 59144 | ✅ |
| zkSync Era | zkRollup | 324 | ❌ |
| Scroll | zkRollup | 534352 | ❌ |
| Mantle | Validium | 5000 | ❌ |

> ✅ = USDT address registered · ❌ = USDT not deployed on this chain

---

## Project Status

GhostChain Layer is currently in **Production-Ready Beta Phase**. The core protocol is fully functional with production safety guards:

### ✅ Completed (Production Ready)
- [x] ERC-5564 stealth addresses
- [x] Poseidon-based ZK circuit
- [x] ERC-1167 minimal proxy swaps
- [x] Intent-based cross-chain routing
- [x] Solver/Relayer service
- [x] Bootstrap ZK verification
- [x] Multi-chain support (12 EVM networks)
- [x] CI/CD pipeline with Foundry + Circom + Docker
- [x] **Production mode guard** — `productionMode` permanently disables bootstrap verification
- [x] **One-way kill switch** — `activateProductionMode()` is irreversible
- [x] **Production Docker Compose** — Health checks, non-root users, resource limits, monitoring
- [x] **Prometheus/Grafana** — Metrics and dashboards for solver monitoring
- [x] **Slither static analysis** — Integrated in CI pipeline
- [x] **ZK full setup script** — `make setup-ceremony` runs complete Groth16 trusted setup
- [x] **Production deployment script** — Supports `PRODUCTION_MODE` and `VERIFIER_ADDRESS` overrides
- [x] **AWS KMS integration** — For production key management
- [x] **Multi-party trusted setup ceremony** — Community-driven Groth16 Phase 2 ceremony
- [x] **npm publishing ready** — `ghostchain-sdk`, `ghostchain-relayer`, `ghostchain-zk` available on npm

### ❌ Still Needed for Production
- [ ] Third-party security audit (OpenZeppelin / Trail of Bits)
- [ ] Full Groth16 trusted setup ceremony (multi-party community participation)
- [ ] Frontend dApp (Next.js + Wagmi)
- [ ] Solver network bonding/slashing
- [ ] Mobile SDK (React Native)

---

## Contributing

We welcome contributions from the community! Here's how to get started:

1. **Read** the [Architecture Guide](./راهنمای%20ساخت/step1.md) (Farsi)
2. **Fork** the repository
3. **Create** a feature branch (`git checkout -b feature/amazing-feature`)
4. **Commit** your changes (`git commit -m 'Add amazing feature'`)
5. **Push** to the branch (`git push origin feature/amazing-feature`)
6. **Open** a Pull Request

### Development Guidelines

- All Solidity code must pass `forge fmt --check` and `forge build`
- All TypeScript must pass ESLint and type-check
- Tests are mandatory for new features (Foundry + Vitest)
- Follow the existing code style (see `.prettierrc`)
- Update `.env.example` if adding new environment variables
- Add JSDoc/Natspec for all public APIs

---

## License

This project is licensed under the **MIT License** — see the [LICENSE](./LICENSE) file for details.

---

## Creator

**GhostChain Layer** was conceived, designed, and implemented by **Mohammad Nazarnejad** — a blockchain engineer and privacy researcher focused on censorship-resistant financial infrastructure.

- GitHub: [@coinceeper](https://github.com/coinceeper)

---

<div align="center">
  <p>Built for financial privacy and censorship resistance</p>
  <p>
    <strong>Mohammad Nazarnejad</strong> &mdash; Creator &amp; Lead Developer
  </p>
  <p>
    <a href="https://github.com/coinceeper/Ghostchain-layer/issues">Report Bug</a>
    ·
    <a href="https://github.com/coinceeper/Ghostchain-layer/issues">Request Feature</a>
    ·
    <a href="https://github.com/coinceeper/Ghostchain-layer/discussions">Discussions</a>
  </p>
</div>

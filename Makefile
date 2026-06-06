# ────────────────────────────────────
# GhostChain Layer - Makefile
# ────────────────────────────────────
# Common development and production commands.
#
# Usage:
#   make build          # Build all packages
#   make test           # Run all tests
#   make deploy-testnet # Deploy to testnet
#   make deploy-mainnet # Deploy to mainnet (production mode)

.PHONY: help build test clean install \
        build-contracts build-sdk build-relayer build-zk build-docker \
        test-contracts test-sdk test-relayer test-zk test-all \
        deploy-testnet deploy-mainnet \
        docker-up docker-up-prod docker-down \
        setup-ptau setup-ceremony \
        ceremony-init ceremony-contribute ceremony-status \
        ceremony-verify ceremony-verify-contribution \
        ceremony-beacon ceremony-export ceremony-hash ceremony-full

# ───── Help ─────
help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

# ───── Install ─────
install: ## Install all dependencies
	npm install
	cd contracts && forge install

# ───── Build ─────
build: ## Build all packages (development)
	npm run build

build-production: ## Build all packages (production optimization)
	npm run build:production

build-contracts: ## Build smart contracts
	cd contracts && forge build

build-contracts-production: ## Build smart contracts (production optimizer)
	cd contracts && FOUNDRY_PROFILE=production forge build

build-sdk: ## Build SDK
	npm run build -w sdk

build-relayer: ## Build relayer
	npm run build -w relayer

build-zk: ## Build ZK circuits
	cd zk && npm run build:all

build-zk-full: ## Full ZK setup (circuit + Groth16 + verifier export)
	cd zk && npm run full:setup

build-docker: ## Build all Docker images
	docker build -t ghostchain-solver -f relayer/Dockerfile relayer/
	docker build -t ghostchain-zk-prover -f zk/Dockerfile zk/

# ───── Test ─────
test: ## Run all tests
	npm test

test-contracts: ## Run smart contract tests
	cd contracts && forge test -vvv

test-contracts-gas: ## Run smart contract tests with gas report
	cd contracts && forge test --gas-report

test-sdk: ## Run SDK tests
	npm test -w sdk

test-relayer: ## Run relayer tests
	npm test -w relayer

test-relayer-integration: ## Run relayer integration tests
	npm test -w relayer -- test/integration.test.ts

test-zk: ## Run ZK circuit tests
	cd zk && npm test

test-all: ## Run all tests (contracts + SDK + relayer + ZK)
	cd contracts && forge test -vvv
	npm test
	cd zk && npm test

# ───── Lint ─────
lint: ## Lint all code
	npm run lint
	cd contracts && forge fmt --check

lint-fix: ## Fix lint issues
	cd contracts && forge fmt

format: ## Format all code
	npm run format
	cd contracts && forge fmt

# ───── Deploy ─────
deploy-testnet: ## Deploy to testnet (set RPC_URL and PRIVATE_KEY)
	cd contracts && forge script script/DeployFactory.s.sol \
		--rpc-url $(RPC_URL) \
		--broadcast \
		--verify \
		-vvv

deploy-testnet-arbitrum-sepolia: ## Deploy to Arbitrum Sepolia testnet
	cd contracts && forge script script/DeployFactory.s.sol \
		--rpc-url arbitrum_sepolia \
		--broadcast \
		--verify \
		-vvv

deploy-testnet-base-sepolia: ## Deploy to Base Sepolia testnet
	cd contracts && forge script script/DeployFactory.s.sol \
		--rpc-url base_sepolia \
		--broadcast \
		--verify \
		-vvv

deploy-mainnet: ## Deploy to mainnet (PRODUCTION mode, requires full Groth16 verifier)
	cd contracts && PRODUCTION_MODE=true BOOTSTRAP_MODE=false \
		forge script script/DeployFactory.s.sol \
		--rpc-url $(RPC_URL) \
		--broadcast \
		--verify \
		-vvv

frontend: ## Start frontend demo server
	cd frontend && python3 -m http.server 5173

# ───── Docker ─────
docker-up: ## Start services (development)
	docker-compose up -d

docker-up-prod: ## Start services (production)
	docker-compose -f docker-compose.yml -f docker-compose.prod.yml up -d

docker-down: ## Stop all services
	docker-compose down

docker-logs: ## View logs
	docker-compose logs -f

# ───── Clean ─────
clean: ## Clean all build artifacts
	npm run clean
	cd contracts && forge clean
	cd zk && rm -rf build ptau

# ───── ZK Trusted Setup ─────
setup-ptau: ## Download Powers of Tau ceremony file
	mkdir -p zk/ptau
	curl -L https://hermez.s3.amazonaws.com/powersOfTau28_hez_final_16.ptau -o zk/ptau/powersOfTau28_hez_final_16.ptau

setup-ceremony: setup-ptau ## Run full trusted setup ceremony (single-party, dev only)
	cd zk && npm run full:setup

# ───── Multi-Party Trusted Setup Ceremony ─────
ceremony-init: ## Initialize multi-party ceremony for all circuits
	cd zk && node scripts/ceremony.js init

ceremony-contribute: ## Contribute to the ceremony (usage: make ceremony-contribute NAME="Your Name")
	cd zk && node scripts/ceremony.js contribute "$(NAME)"

ceremony-status: ## Show ceremony status
	cd zk && node scripts/ceremony.js status

ceremony-verify: ## Verify the entire ceremony
	cd zk && node scripts/ceremony.js verify

ceremony-verify-contribution: ## Verify a specific contribution (usage: make ceremony-verify-contribution NAME="Alice")
	cd zk && node scripts/ceremony.js verify-contribution "$(NAME)"

ceremony-beacon: ## Apply random beacon to finalize ceremony (usage: make ceremony-beacon ENTROPY=<64-char-hex>)
	cd zk && node scripts/ceremony.js beacon "$(ENTROPY)"

ceremony-export: ## Export verifier contracts and verification keys
	cd zk && node scripts/ceremony.js export

ceremony-hash: ## Print all contribution hashes
	cd zk && node scripts/ceremony.js hash

ceremony-full: setup-ptau ceremony-init ## Full ceremony: init with all circuits ready for contributions
	@echo ""
	@echo "  Ceremony initialized. Next steps:"
	@echo "    1. make ceremony-contribute NAME=\"Alice\""
	@echo "    2. make ceremony-contribute NAME=\"Bob\""
	@echo "    3. ... (repeat for all participants)"
	@echo "    4. make ceremony-beacon ENTROPY=<block-hash>"
	@echo "    5. make ceremony-export"
	@echo ""

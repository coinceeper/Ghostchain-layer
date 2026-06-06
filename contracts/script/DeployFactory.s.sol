// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script } from "forge-std/Script.sol";
import { EphemeralFactory } from "../src/EphemeralFactory.sol";
import { EphemeralRouter } from "../src/EphemeralRouter.sol";
import { ZKVerifier } from "../src/ZKVerifier.sol";
import { Registry } from "../src/Registry.sol";

/// @title DeployFactory
/// @notice Chain-agnostic deployment script for protocol contracts.
///         Works on any EVM chain without code changes.
///
/// @dev forge script script/DeployFactory.s.sol --rpc-url <chain> --broadcast [--verify]
///
///      Environment variables:
///        PRIVATE_KEY           - Deployer private key
///        USDT_ADDRESS          - (Optional) USDT address on this chain
///        BOOTSTRAP_MODE        - (Optional, default: true) Use bootstrap verification
///        PRODUCTION_MODE       - (Optional, default: false) Production safety mode
///        VERIFIER_ADDRESS      - (Optional) Pre-deployed ZKVerifier to reuse
///        REGISTRY_ADDRESS      - (Optional) Existing Registry for multi-chain
///        REGISTRY_OWNER        - (Optional, default: deployer) Registry owner
contract DeployFactory is Script {
    // ───── Configuration ─────

    /// @notice The deployer private key (set via PRIVATE_KEY env var)
    address private deployer;

    /// @notice The owner of the Registry (multisig in production)
    address private registryOwner;

    /// @notice Bootstrap mode: true for development, false when Groth16 verifier is ready
    bool private bootstrapMode;

    /// @notice Production mode: when true, the verifier rejects bootstrap proofs
    bool private productionMode;

    /// @notice Pre-deployed verifier address (optional, for multi-chain reuse)
    address private verifierAddress;

    /// @notice Pre-deployed registry address (optional, for multi-chain setup)
    address private registryAddress;

    // ───── Run ─────

    function run() external {
        // Read deployer from environment
        deployer = vm.rememberKey(vm.envUint("PRIVATE_KEY"));
        registryOwner = vm.envOr("REGISTRY_OWNER", deployer);
        bootstrapMode = vm.envOr("BOOTSTRAP_MODE", true);
        productionMode = vm.envOr("PRODUCTION_MODE", false);
        verifierAddress = vm.envOr("VERIFIER_ADDRESS", address(0));
        registryAddress = vm.envOr("REGISTRY_ADDRESS", address(0));

        // ───── Production Safety Checks ─────
        if (productionMode) {
            // In production mode, bootstrap MUST be disabled
            if (bootstrapMode) {
                console.log("ERROR: Production mode requires BOOTSTRAP_MODE=false");
                console.log("  Set BOOTSTRAP_MODE=false in your environment");
                revert("Production mode with bootstrap enabled is not allowed");
            }

            // In production mode, a pre-deployed verifier is strongly recommended
            if (verifierAddress == address(0)) {
                console.log("WARNING: Production mode without a pre-deployed VERIFIER_ADDRESS");
                console.log("  A new ZKVerifier will be deployed. For security, use a pre-audited verifier.");
            }

            console.log("Deploying in PRODUCTION mode");
            console.log("  Registry owner:", registryOwner);
        } else {
            console.log("Deploying in DEVELOPMENT mode (bootstrap:", bootstrapMode, ")");
        }

        vm.startBroadcast(deployer);

        // Step 1: Deploy EphemeralRouter (implementation for minimal proxies)
        // The factory will call router.setFactory() during its constructor
        EphemeralRouter router = new EphemeralRouter();
        console.log("EphemeralRouter deployed at:", address(router));

        // Step 2: Deploy or reuse ZKVerifier
        ZKVerifier verifier;
        if (verifierAddress != address(0)) {
            // Use pre-deployed verifier (important for multi-chain setup)
            verifier = ZKVerifier(verifierAddress);
            console.log("Using existing ZKVerifier at:", verifierAddress);
        } else {
            // Compute bootstrap verification key hash
            bytes32 vkHash = keccak256(abi.encodePacked("ghostchain-bootstrap-v1"));

            // In bootstrap mode, the authorized signer is the deployer (solver key).
            // In production mode, the authorized signer is unused (bootstrap is blocked).
            address authorizedSigner = deployer;

            // Deploy new ZKVerifier with owner and authorized signer
            verifier = new ZKVerifier(
                vkHash,              // vkHash
                0,                   // provingSystem (0 = Groth16)
                bootstrapMode,       // bootstrapMode
                registryOwner,       // owner (multisig in production)
                authorizedSigner     // authorizedSigner (solver for bootstrap)
            );
            console.log("ZKVerifier deployed at:", address(verifier));
            console.log("  Bootstrap mode:", bootstrapMode);
            console.log("  Owner:", registryOwner);
            console.log("  Authorized signer:", authorizedSigner);

            // If production mode and we deployed a new verifier,
            // we need the full verifier to be set before activation.
            if (productionMode) {
                console.log("  NOTE: Production mode requires calling upgradeVerifier()");
                console.log("  with the Groth16 verifier address, then activateProductionMode().");
            }
        }

        // Step 3: Deploy EphemeralFactory with Verifier and Router addresses
        EphemeralFactory factory = new EphemeralFactory(
            address(verifier),
            address(router)
        );
        console.log("EphemeralFactory deployed at:", address(factory));

        // Step 4: Deploy or reuse Registry
        Registry registry;
        if (registryAddress != address(0)) {
            registry = Registry(registryAddress);
            console.log("Using existing Registry at:", registryAddress);
        } else {
            registry = new Registry(registryOwner);
            console.log("Registry deployed at:", address(registry));
        }

        // Step 5: Register this chain dynamically using block.chainid
        address[] memory tokens = new address[](1);
        tokens[0] = vm.envOr("USDT_ADDRESS", address(0)); // USDT address for this chain

        registry.addChain(
            block.chainid,
            address(factory),
            address(verifier),
            tokens
        );
        console.log("Chain", block.chainid, "registered in Registry");

        vm.stopBroadcast();

        // ───── Post-deployment Summary ─────
        console.log("");
        console.log("═══════════════════════════════════════");
        console.log("  Deployment Summary");
        console.log("═══════════════════════════════════════");
        console.log("  Chain ID:   ", block.chainid);
        console.log("  Environment:", productionMode ? "PRODUCTION" : "DEVELOPMENT");
        console.log("  Bootstrap:  ", bootstrapMode);
        console.log("  Factory:    ", address(factory));
        console.log("  Verifier:   ", address(verifier));
        console.log("  Router:     ", address(router));
        console.log("  Registry:   ", address(registry));
        console.log("═══════════════════════════════════════");
    }
}

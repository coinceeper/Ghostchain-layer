// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script } from "forge-std/Script.sol";
import { EphemeralFactory } from "../src/EphemeralFactory.sol";
import { EphemeralRouter } from "../src/EphemeralRouter.sol";
import { ZKVerifier } from "../src/ZKVerifier.sol";
import { Registry } from "../src/Registry.sol";

/// @title DeployFactory
/// @notice Dynamic deployment script for the GhostChain protocol contracts.
///         Chain-agnostic: works on ANY EVM chain without modifying code.
///
/// @dev Usage (any EVM chain):
///      forge script script/DeployFactory.s.sol --rpc-url <chain_alias> --broadcast
///
///      Examples:
///        forge script script/DeployFactory.s.sol --rpc-url arbitrum --broadcast
///        forge script script/DeployFactory.s.sol --rpc-url base --broadcast
///        forge script script/DeployFactory.s.sol --rpc-url bsc --broadcast
///
///      To verify on Etherscan-like explorers:
///        forge script script/DeployFactory.s.sol --rpc-url arbitrum --broadcast --verify
///
///      RPC aliases are defined in foundry.toml under [rpc_endpoints].
///      Add a new chain there and deploy with zero code changes.
///
/// @notice Environment variables needed:
///         PRIVATE_KEY  - Deployer private key
///         USDT_ADDRESS - (Optional) USDT address on this chain
contract DeployFactory is Script {
    // ───── Configuration ─────

    /// @notice The deployer private key (set via PRIVATE_KEY env var)
    address private deployer;

    /// @notice The owner of the Registry (multisig in production)
    address private registryOwner;

    /// @notice Bootstrap mode: true for development, false when Groth16 verifier is ready
    bool private bootstrapMode;

    // ───── Run ─────

    function run() external {
        // Read deployer from environment
        deployer = vm.rememberKey(vm.envUint("PRIVATE_KEY"));
        registryOwner = deployer; // TODO: Set to multisig in production
        bootstrapMode = vm.envOr("BOOTSTRAP_MODE", true);

        vm.startBroadcast(deployer);

        // Step 1: Deploy EphemeralRouter (stateless implementation for minimal proxies)
        EphemeralRouter router = new EphemeralRouter();
        console.log("EphemeralRouter deployed at:", address(router));

        // Step 2: Compute bootstrap verification key hash
        bytes32 vkHash = keccak256(abi.encodePacked("ghostchain-bootstrap-v1"));

        // Step 3: Deploy ZKVerifier with bootstrap mode
        // In bootstrap mode, verification uses ECDSA signature checking
        // When the full Groth16 verifier is generated from the Circom circuit,
        // call upgradeVerifier() on the ZKVerifier contract
        ZKVerifier verifier = new ZKVerifier(
            vkHash,          // vkHash
            0,                // provingSystem (0 = Groth16)
            bootstrapMode     // bootstrapMode
        );
        console.log("ZKVerifier deployed at:", address(verifier));
        console.log("  Bootstrap mode:", bootstrapMode);

        // Step 4: Deploy EphemeralFactory with Verifier and Router addresses
        EphemeralFactory factory = new EphemeralFactory(
            address(verifier),
            address(router)
        );
        console.log("EphemeralFactory deployed at:", address(factory));

        // Step 5: Deploy Registry (only on governance chain)
        Registry registry = new Registry(registryOwner);
        console.log("Registry deployed at:", address(registry));

        // Step 6: Register this chain dynamically using block.chainid
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
    }
}

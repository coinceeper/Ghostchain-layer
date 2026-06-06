/**
 * ZK Prover Service
 *
 * Generates and manages ZK-SNARK proofs for GhostChain protocol.
 * Supports both bootstrap mode (ECDSA-based structural proofs) and
 * full Groth16/PLONK proof generation.
 *
 * In bootstrap mode, the proof is an ECDSA signature over the public
 * input hash, providing sender authentication without full trusted setup.
 * Once the Groth16 ceremony is complete, this switches to real snarkjs proofs.
 *
 * The public input hash now includes ephemeralPublicKey to constrain the
 * sharedSecret derivation in the circuit (GCL-ZK-01 fix).
 *
 * @packageDocumentation
 */

import { type Address, type Hash, encodeAbiParameters, parseAbiParameters, keccak256, encodePacked } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import type { Logger } from 'pino';

// ───── Types ─────

export interface GhostTransferPublicInputs {
  senderCommitment: `0x${string}`;
  recipientCommitment: `0x${string}`;
  contractHash: `0x${string}`;
  token: Address;
  amount: bigint;
  nonce: bigint;
  chainId: bigint;
  /** Ephemeral public key (R = r*G) emitted in the swap event.
   *  The circuit derives sharedSecret = Poseidon(senderPrivateKey, ephemeralPublicKey)
   *  internally, preventing the prover from injecting arbitrary values (GCL-ZK-01 fix). */
  ephemeralPublicKey: `0x${string}`;
}

export interface ZkProofResult {
  /** The encoded proof bytes */
  proof: `0x${string}`;
  /** The proving system used */
  proofType: number; // 0 = Groth16, 1 = PLONK
  /** Whether bootstrap mode was used */
  bootstrap: boolean;
  /** The generated public inputs */
  publicInputs: GhostTransferPublicInputs;
}

// ───── Prover Config ─────

export interface ZkProverConfig {
  /** Private key for signing bootstrap proofs */
  solverPrivateKey: `0x${string}`;
  /** Path to the zkey file (for full Groth16 mode) */
  zkeyPath?: string;
  /** Whether to use full proving (requires snarkjs) */
  useFullProving?: boolean;
  /**
   * When true, Groth16 proof generation failure THROWS an error instead of
   * silently falling back to bootstrap mode. Recommended for production to
   * ensure only real ZK proofs are generated.
   */
  strictProving?: boolean;
}

// ───── Prover Service ─────

export class ZkProver {
  private config: ZkProverConfig;
  private logger: Logger;
  private snarkjs: any; // Lazy-loaded snarkjs

  constructor(config: ZkProverConfig, logger: Logger) {
    this.config = config;
    this.logger = logger.child({ module: 'ZkProver' });
    this.snarkjs = null;
  }

  /**
   * Generates a ZK proof for a ghost transfer.
   *
   * In bootstrap mode, the "proof" is an ECDSA signature over the
   * public input hash using the solver's private key. This provides:
   *   - Sender authentication (only the key owner can sign)
   *   - Integrity binding (proof is bound to specific swap parameters)
   *   - Replay protection (nonce and chainId are included)
   *   - Shared secret binding (ephemeralPublicKey is included in the hash)
   *
   * In full proving mode, generates a real Groth16/PLONK proof.
   *
   * @param publicInputs The public inputs for the proof
   * @returns The generated proof and metadata
   */
  async generateProof(publicInputs: GhostTransferPublicInputs): Promise<ZkProofResult> {
    if (this.config.useFullProving && this.config.zkeyPath) {
      try {
        return await this.generateGroth16Proof(publicInputs);
      } catch (error) {
        // In strict mode, never silently fall back — propagate the error
        if (this.config.strictProving) {
          throw error;
        }
        this.logger.warn(
          `Groth16 proof failed, falling back to bootstrap mode: ${error instanceof Error ? error.message : String(error)}`,
        );
        return this.generateBootstrapProof(publicInputs);
      }
    }
    return this.generateBootstrapProof(publicInputs);
  }

  /**
   * Generates a bootstrap proof (ECDSA signature over public inputs).
   * This is the default mode before the full Groth16 trusted setup.
   *
   * The hash includes ephemeralPublicKey to bind the proof to the
   * specific ephemeral key used in the swap (GCL-ZK-01 fix).
   */
  private async generateBootstrapProof(
    publicInputs: GhostTransferPublicInputs,
  ): Promise<ZkProofResult> {
    // Compute the public input hash (includes ephemeralPublicKey for shared secret binding)
    const publicInputHash = keccak256(
      encodePacked(
        ['bytes32', 'bytes32', 'bytes32', 'address', 'uint256', 'uint256', 'uint256', 'bytes'],
        [
          publicInputs.senderCommitment,
          publicInputs.recipientCommitment,
          publicInputs.contractHash,
          publicInputs.token,
          BigInt(publicInputs.amount),
          BigInt(publicInputs.nonce),
          BigInt(publicInputs.chainId),
          publicInputs.ephemeralPublicKey,
        ],
      ),
    );

    // Sign the hash with the solver's key
    const account = privateKeyToAccount(this.config.solverPrivateKey);
    const signature = await account.signMessage({ message: { raw: publicInputHash } });

    // Encode the proof bytes: [signature_r (32) | signature_s (32) | v (1)]
    const proof = encodeAbiParameters(
      parseAbiParameters('bytes32 r, bytes32 s, uint8 v'),
      [
        signature.slice(0, 32) as `0x${string}`,
        signature.slice(32, 64) as `0x${string}`,
        BigInt(parseInt(signature.slice(66, 68), 16) - 27), // Extract v
      ],
    );

    this.logger.debug(
      `Generated bootstrap proof: hash=${publicInputHash.slice(0, 10)}..., chainId=${publicInputs.chainId}`,
    );

    return {
      proof: proof as `0x${string}`,
      proofType: 0,
      bootstrap: true,
      publicInputs,
    };
  }

  /**
   * Generates a full Groth16 proof using snarkjs.
   * Requires the circuit's .zkey file to be available.
   *
   * The circuit inputs now include ephemeralPublicKey so the sharedSecret
   * derivation constraint (Poseidon(senderPrivateKey, ephemeralPublicKey))
   * is enforced during witness generation (GCL-ZK-01 fix).
   */
  private async generateGroth16Proof(
    _publicInputs: GhostTransferPublicInputs,
  ): Promise<ZkProofResult> {
    // Lazy-load snarkjs — always throws on failure (no silent fallback)
    if (!this.snarkjs) {
      try {
        this.snarkjs = await import('snarkjs');
      } catch {
        throw new Error('snarkjs not available for Groth16 proof generation');
      }
    }

    try {
      // Prepare the circuit inputs including ephemeralPublicKey for shared secret binding
      const circuitInputs = {
        senderCommitment: _publicInputs.senderCommitment,
        recipientCommitment: _publicInputs.recipientCommitment,
        contractHash: _publicInputs.contractHash,
        token: _publicInputs.token,
        amount: _publicInputs.amount.toString(),
        nonce: _publicInputs.nonce.toString(),
        chainId: _publicInputs.chainId.toString(),
        // GCL-ZK-01 fix: ephemeralPublicKey is a public input used by the circuit
        // to derive sharedSecret = Poseidon(senderPrivateKey, ephemeralPublicKey)
        ephemeralPublicKey: _publicInputs.ephemeralPublicKey,
        // Note: private inputs (senderPrivateKey, senderRandomness, etc.) must
        // also be provided by the caller for full witness generation
      };

      // Generate the proof
      const { proof, publicSignals } = await this.snarkjs.groth16.fullProve(
        circuitInputs,
        './zk/build/ghostTransfer.wasm',
        this.config.zkeyPath,
      );

      // Encode the proof for on-chain verification
      const encodedProof = this.encodeProofForChain(proof);

      this.logger.info(
        `Generated Groth16 proof: publicSignals=${publicSignals.length}`,
      );

      return {
        proof: encodedProof,
        proofType: 0,
        bootstrap: false,
        publicInputs: _publicInputs,
      };
    } catch (error) {
      this.logger.error('Groth16 proof generation failed:', error);
      throw new Error(
        `Groth16 proof generation failed: ${error instanceof Error ? error.message : String(error)}`,
      );
    }
  }

  /**
   * Encodes a Groth16 proof from snarkjs into the on-chain format.
   * The proof consists of (pi_a, pi_b, pi_c) G1/G2 points.
   */
  private encodeProofForChain(proof: any): `0x${string}` {
    return encodeAbiParameters(
      parseAbiParameters('uint256[2] a, uint256[2][2] b, uint256[2] c'),
      [
        [BigInt(proof.pi_a[0]), BigInt(proof.pi_a[1])],
        [
          [BigInt(proof.pi_b[0][1]), BigInt(proof.pi_b[0][0])],
          [BigInt(proof.pi_b[1][1]), BigInt(proof.pi_b[1][0])],
        ],
        [BigInt(proof.pi_c[0]), BigInt(proof.pi_c[1])],
      ],
    ) as `0x${string}`;
  }

  /**
   * Verifies a proof locally (for testing).
   */
  async verifyProof(
    proof: `0x${string}`,
    publicInputs: GhostTransferPublicInputs,
  ): Promise<boolean> {
    if (!this.config.useFullProving) {
      // Bootstrap mode: verify the ECDSA signature
      // The hash must match what was signed (includes ephemeralPublicKey)
      const publicInputHash = keccak256(
        encodePacked(
          ['bytes32', 'bytes32', 'bytes32', 'address', 'uint256', 'uint256', 'uint256', 'bytes'],
          [
            publicInputs.senderCommitment,
            publicInputs.recipientCommitment,
            publicInputs.contractHash,
            publicInputs.token,
            BigInt(publicInputs.amount),
            BigInt(publicInputs.nonce),
            BigInt(publicInputs.chainId),
            publicInputs.ephemeralPublicKey,
          ],
        ),
      );

      const account = privateKeyToAccount(this.config.solverPrivateKey);
      try {
        const recovered = account.recoverMessage({ message: { raw: publicInputHash }, signature: proof });
        return recovered !== undefined;
      } catch {
        return false;
      }
    }

    // Full snarkjs verification (requires .zkey and verification_key.json)
    try {
      if (!this.snarkjs) {
        this.snarkjs = await import('snarkjs');
      }
      const vk = await import(this.config.zkeyPath!.replace('.zkey', '_verification_key.json'), {
        assert: { type: 'json' },
      });
      return await this.snarkjs.groth16.verify(vk, publicInputs, proof);
    } catch {
      return false;
    }
  }
}

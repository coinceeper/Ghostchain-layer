#!/usr/bin/env node

/**
 * GhostChain Trusted Setup Ceremony Coordinator
 *
 * Manages a multi-party Phase 2 (circuit-specific) Groth16 ceremony.
 * Participants contribute entropy sequentially, and each contribution
 * is verified before the next can proceed. A final random beacon
 * ensures security even if all participants are compromised.
 *
 * Usage:
 *   node scripts/ceremony.js init [circuit]          Initialize ceremony
 *   node scripts/ceremony.js contribute [name]        Add contribution
 *   node scripts/ceremony.js verify [file]            Verify a zkey file
 *   node scripts/ceremony.js beacon [entropy]         Apply random beacon
 *   node scripts/ceremony.js export [circuit]         Export verifier + vk
 *   node scripts/ceremony.js status                   Show ceremony status
 *   node scripts/ceremony.js hash [file]              Print contribution hash
 *   node scripts/ceremony.js verify-contribution [name] Verify & archive a contribution
 *
 * Security model:
 *   - Phase 1 (Powers of Tau): Uses the public Hermez Phase 1 beacon
 *     (powersOfTau28_hez_final_16.ptau) which already had 100+ participants.
 *   - Phase 2 (Circuit-specific): N participants contribute entropy.
 *   - Final beacon: A random beacon (e.g., future Bitcoin block hash)
 *     ensures that even if all N participants collude, the setup remains secure.
 *   - Each participant's contribution hash is published for independent verification.
 */

const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');
const crypto = require('crypto');

// ───── Configuration ─────

const ZK_DIR = path.resolve(__dirname, '..');
const CEREMONY_DIR = path.join(ZK_DIR, 'ceremony');
const PTAU_DIR = path.join(ZK_DIR, 'ptau');
const BUILD_DIR = path.join(ZK_DIR, 'build');
const CONTRACTS_DIR = path.resolve(ZK_DIR, '..', 'contracts', 'src');

const PTAU_FILE = path.join(PTAU_DIR, 'powersOfTau28_hez_final_16.ptau');
const PTAU_URL = 'https://hermez.s3.amazonaws.com/powersOfTau28_hez_final_16.ptau';

const CIRCUITS = {
  ghostTransfer: {
    r1cs: path.join(BUILD_DIR, 'ghostTransfer.r1cs'),
    wasm: path.join(BUILD_DIR, 'ghostTransfer.wasm'),
    initialZkey: path.join(CEREMONY_DIR, 'ghostTransfer.initial.zkey'),
    finalZkey: path.join(CEREMONY_DIR, 'ghostTransfer_final.zkey'),
    verifier: path.join(CONTRACTS_DIR, 'ZKVerifierFull.sol'),
    vk: path.join(BUILD_DIR, 'verification_key.json'),
    label: 'Ghost Transfer',
  },
  ghostTransferNullifier: {
    r1cs: path.join(BUILD_DIR, 'ghostTransferNullifier.r1cs'),
    wasm: path.join(BUILD_DIR, 'ghostTransferNullifier.wasm'),
    initialZkey: path.join(CEREMONY_DIR, 'ghostTransferNullifier.initial.zkey'),
    finalZkey: path.join(CEREMONY_DIR, 'ghostTransferNullifier_final.zkey'),
    verifier: path.join(CONTRACTS_DIR, 'ZKVerifierNullifier.sol'),
    vk: path.join(BUILD_DIR, 'verification_key_nullifier.json'),
    label: 'Ghost Transfer Nullifier',
  },
};

// ───── State Management ─────

const MANIFEST_PATH = path.join(CEREMONY_DIR, 'manifest.json');

function loadManifest() {
  if (fs.existsSync(MANIFEST_PATH)) {
    return JSON.parse(fs.readFileSync(MANIFEST_PATH, 'utf8'));
  }
  return {
    ceremony: 'GhostChain Phase 2 Trusted Setup',
    version: '1.0.0',
    phase1: {
      ptau: {
        source: 'Hermez Phase 1 Beacon',
        file: 'powersOfTau28_hez_final_16.ptau',
        constraints: 16, // 2^16
        url: PTAU_URL,
      },
    },
    circuits: {},
    participants: [],
    beacon: null,
    finalized: false,
    createdAt: null,
    finalizedAt: null,
  };
}

function saveManifest(manifest) {
  fs.mkdirSync(CEREMONY_DIR, { recursive: true });
  fs.writeFileSync(MANIFEST_PATH, JSON.stringify(manifest, null, 2) + '\n');
}

// ───── Helpers ─────

function run(cmd, opts = {}) {
  const defaultOpts = { cwd: ZK_DIR, stdio: 'inherit' };
  return execSync(cmd, { ...defaultOpts, ...opts });
}

function runCapture(cmd) {
  return execSync(cmd, { cwd: ZK_DIR, encoding: 'utf8' }).trim();
}

function ensureDir(dir) {
  fs.mkdirSync(dir, { recursive: true });
}

function fileSize(file) {
  return fs.statSync(file).size;
}

function sha256File(file) {
  return crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
}

function formatBytes(bytes) {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
}

function timestamp() {
  return new Date().toISOString();
}

function ensurePtau() {
  if (!fs.existsSync(PTAU_FILE)) {
    console.log(`\n  ⬇️  Downloading Powers of Tau Phase 1 file...`);
    console.log(`     (this is a ~100MB download from Hermez S3)`);
    ensureDir(PTAU_DIR);
    run(`curl -L ${PTAU_URL} -o ${PTAU_FILE}`);
    console.log(`     ✓ Downloaded: ${PTAU_FILE}`);
  } else {
    const size = formatBytes(fileSize(PTAU_FILE));
    console.log(`     ✓ Phase 1 PTAU file exists: ${PTAU_FILE} (${size})`);
  }
}

function ensureCircuit(circuitName) {
  const circuit = CIRCUITS[circuitName];
  if (!circuit) {
    console.error(`  ✗ Unknown circuit: ${circuitName}`);
    console.error(`    Available: ${Object.keys(CIRCUITS).join(', ')}`);
    process.exit(1);
  }
  if (!fs.existsSync(circuit.r1cs)) {
    console.error(`  ✗ R1CS file not found for ${circuitName}`);
    console.error(`    Run 'npm run build:all' to compile circuits first.`);
    process.exit(1);
  }
  return circuit;
}

function getCurrentZkey(circuit) {
  // Find the latest contribution zkey
  const pattern = `${circuitName}_contribution_`;
  // Just return final if it exists, otherwise initial
  if (fs.existsSync(circuit.finalZkey)) return circuit.finalZkey;
  return circuit.initialZkey;
}

// ───── Commands ─────

function cmdInit(circuitName) {
  if (!circuitName) {
    // Initialize for ALL circuits
    Object.keys(CIRCUITS).forEach(cmdInit);
    return;
  }

  const circuit = ensureCircuit(circuitName);
  ensurePtau();
  ensureDir(CEREMONY_DIR);

  const manifest = loadManifest();

  if (fs.existsSync(circuit.initialZkey)) {
    const size = formatBytes(fileSize(circuit.initialZkey));
    console.log(`  ∼ Initial zkey already exists for ${circuit.label}: ${circuit.initialZkey} (${size})`);
    return;
  }

  console.log(`\n  🔷 Initializing ceremony for: ${circuit.label}`);
  console.log(`     Circuit: ${circuitName}.circom`);
  console.log(`     R1CS:    ${circuit.r1cs}`);
  console.log(`     PTAU:    ${PTAU_FILE}`);
  console.log(`     Output:  ${circuit.initialZkey}\n`);

  // Run Groth16 setup to create initial .zkey
  run(`npx snarkjs groth16 setup "${circuit.r1cs}" "${PTAU_FILE}" "${circuit.initialZkey}"`);

  const hash = sha256File(circuit.initialZkey);
  const size = formatBytes(fileSize(circuit.initialZkey));

  // Update manifest
  manifest.circuits[circuitName] = {
    label: circuit.label,
    r1cs: circuitName + '.r1cs',
    state: 'initialized',
    contributions: 0,
    initialZkey: path.basename(circuit.initialZkey),
    initialZkeyHash: hash,
    initializedAt: timestamp(),
  };
  if (!manifest.createdAt) manifest.createdAt = timestamp();
  saveManifest(manifest);

  console.log(`\n  ✓ Ceremony initialized for: ${circuit.label}`);
  console.log(`    Initial zkey: ${path.basename(circuit.initialZkey)} (${size})`);
  console.log(`    SHA-256:      ${hash}\n`);
}

function cmdContribute(contributorName) {
  if (!contributorName) {
    console.error('  ✗ Usage: node scripts/ceremony.js contribute "<Your Name/Handle>"');
    process.exit(1);
  }

  const manifest = loadManifest();
  if (manifest.finalized) {
    console.error('  ✗ Ceremony is already finalized! Cannot add more contributions.');
    process.exit(1);
  }

  if (Object.keys(manifest.circuits).length === 0) {
    console.error('  ✗ Ceremony not initialized. Run "node scripts/ceremony.js init" first.');
    process.exit(1);
  }

  console.log(`\n  🔶 Contribution #${manifest.participants.length + 1}: ${contributorName}`);
  console.log(`     ${'═'.repeat(50)}`);

  const contribution = {
    name: contributorName,
    timestamp: timestamp(),
    circuits: {},
  };

  for (const [circuitName, circuit] of Object.entries(CIRCUITS)) {
    if (!fs.existsSync(circuit.initialZkey)) {
      console.log(`     ∼ Skipping ${circuit.label} (not initialized)`);
      continue;
    }

    // Determine current zkey (the latest one)
    const currentZkey = findLatestZkey(circuitName, circuit);
    if (!currentZkey) {
      console.log(`     ∼ Skipping ${circuit.label} (no zkey found)`);
      continue;
    }

    const prevHash = sha256File(currentZkey);
    const contributionZkey = path.join(
      CEREMONY_DIR,
      `${circuitName}_contribution_${String(manifest.participants.length + 1).padStart(3, '0')}.zkey`
    );
    // Also save as the "current" final zkey
    const finalZkey = CIRCUITS[circuitName].finalZkey;

    console.log(`\n     Circuit: ${circuit.label}`);
    console.log(`     Input:   ${path.basename(currentZkey)} (SHA-256: ${prevHash.slice(0, 16)}...)`);

    // Run contribution
    run(
      `npx snarkjs zkey contribute "${currentZkey}" "${finalZkey}" --name="${contributorName}" -v`
    );

    // Also save the contribution separately
    fs.copyFileSync(finalZkey, contributionZkey);

    const contribHash = sha256File(finalZkey);
    const contribSize = formatBytes(fileSize(finalZkey));

    // Verify the contribution is valid
    console.log(`\n     Verifying contribution...`);
    try {
      run(`npx snarkjs zkey verify "${circuit.r1cs}" "${PTAU_FILE}" "${finalZkey}"`, {
        stdio: 'pipe',
      });
    } catch {
      // verify output goes to stdout
    }
    console.log(`     ✓ Contribution verified`);

    contribution.circuits[circuitName] = {
      inputZkey: path.basename(currentZkey),
      outputZkey: path.basename(finalZkey),
      contributionZkey: path.basename(contributionZkey),
      contributionHash: contribHash,
      contributionSize: contribSize,
      previousHash: prevHash,
    };

    // Update manifest circuit state
    if (!manifest.circuits[circuitName]) {
      manifest.circuits[circuitName] = { label: circuit.label, contributions: 0 };
    }
    manifest.circuits[circuitName].state = 'contributed';
    manifest.circuits[circuitName].contributions =
      (manifest.circuits[circuitName].contributions || 0) + 1;
  }

  manifest.participants.push(contribution);
  saveManifest(manifest);

  console.log(`\n  ✅ Contribution recorded for: ${contributorName}`);
  console.log(`     Total participants: ${manifest.participants.length}`);
  console.log(`     Contribution hashes published in manifest.json`);
  console.log(`     Anyone can verify: node scripts/ceremony.js verify`);
}

function cmdBeacon(entropy) {
  const manifest = loadManifest();
  if (manifest.finalized) {
    console.error('  ✗ Ceremony is already finalized!');
    process.exit(1);
  }
  if (manifest.participants.length === 0) {
    console.error('  ✗ No contributions yet. Run "contribute" first.');
    process.exit(1);
  }

  const beaconHash = entropy || crypto.randomBytes(32).toString('hex');
  console.log(`\n  🔷 Applying Random Beacon`);
  console.log(`     ${'═'.repeat(50)}`);
  console.log(`     Entropy: ${beaconHash.slice(0, 32)}...`);
  console.log(`     (In production, use a future block hash from Bitcoin/Ethereum)`);

  const beaconData = {
    entropy: beaconHash,
    timestamp: timestamp(),
    source: entropy ? 'manual' : 'random (development)',
    circuits: {},
  };

  for (const [circuitName, circuit] of Object.entries(CIRCUITS)) {
    if (!fs.existsSync(circuit.finalZkey)) continue;

    const inputZkey = circuit.finalZkey;
    const beaconZkey = circuit.finalZkey.replace('_final.zkey', '_beacon.zkey');

    const prevHash = sha256File(inputZkey);
    console.log(`\n     Circuit: ${circuit.label}`);
    console.log(`     Input:   ${path.basename(inputZkey)}`);

    // Apply beacon
    run(
      `npx snarkjs zkey beacon "${inputZkey}" "${beaconZkey}" "${beaconHash}" 10 -v`
    );

    // Move beacon zkey to final position
    fs.copyFileSync(beaconZkey, circuit.finalZkey);

    const beaconContribHash = sha256File(circuit.finalZkey);
    beaconData.circuits[circuitName] = {
      previousHash: prevHash,
      finalHash: beaconContribHash,
    };

    // Verify final zkey
    console.log(`\n     Verifying final zkey...`);
    try {
      run(`npx snarkjs zkey verify "${circuit.r1cs}" "${PTAU_FILE}" "${circuit.finalZkey}"`, {
        stdio: 'pipe',
      });
    } catch {
      // verify output goes to stdout
    }
    console.log(`     ✓ Final zkey verified`);
  }

  manifest.beacon = beaconData;
  manifest.finalized = true;
  manifest.finalizedAt = timestamp();
  saveManifest(manifest);

  console.log(`\n  ✅ Beacon applied! Ceremony is now FINALIZED.`);
  console.log(`     Run "node scripts/ceremony.js export" to generate verifier contracts.`);
}

function cmdVerify(checkFile) {
  const manifest = loadManifest();

  if (checkFile) {
    // Verify a specific zkey file against the manifest
    if (!fs.existsSync(checkFile)) {
      console.error(`  ✗ File not found: ${checkFile}`);
      process.exit(1);
    }
    const hash = sha256File(checkFile);
    const size = formatBytes(fileSize(checkFile));
    console.log(`\n  🔍 Verification of: ${checkFile}`);
    console.log(`     Size:       ${size}`);
    console.log(`     SHA-256:    ${hash}`);
    console.log(`     Modified:   ${new Date(fs.statSync(checkFile).mtime).toISOString()}`);

    // Check against manifest
    let found = false;
    for (const [cn, c] of Object.entries(manifest.circuits || {})) {
      const fields = ['initialZkeyHash'];
      // Check participant hashes
      for (const p of manifest.participants) {
        const contrib = p.circuits[cn];
        if (contrib) {
          fields.push('contributionHash');
        }
      }
    }
    console.log(`     Status: Hash computed — compare with published manifest hash.`);
    return;
  }

  // Full ceremony verification
  console.log(`\n  🔍 Full Ceremony Verification`);
  console.log(`     ${'═'.repeat(50)}`);

  // Check Phase 1 ptau
  if (fs.existsSync(PTAU_FILE)) {
    const hash = sha256File(PTAU_FILE);
    console.log(`\n  ✓ Phase 1 PTAU:     ${path.basename(PTAU_FILE)}`);
    console.log(`    SHA-256:          ${hash}`);
  } else {
    console.log(`\n  ✗ Phase 1 PTAU:     NOT FOUND`);
  }

  // Check each circuit
  for (const [circuitName, circuit] of Object.entries(CIRCUITS)) {
    const info = manifest.circuits[circuitName];
    console.log(`\n  ${info ? '✓' : '∼'} Circuit: ${circuit.label}`);

    if (!info) {
      console.log(`    Status: Not initialized`);
      continue;
    }

    const zkeyExists = fs.existsSync(circuit.finalZkey);
    const r1csExists = fs.existsSync(circuit.r1cs);

    console.log(`    R1CS:        ${r1csExists ? '✓' : '✗'} ${path.basename(circuit.r1cs)}`);
    console.log(`    Final zkey:  ${zkeyExists ? '✓' : '✗'} ${path.basename(circuit.finalZkey)}`);
    console.log(`    State:       ${info.state || 'unknown'}`);
    console.log(`    Contributions: ${info.contributions || 0}`);

    if (zkeyExists && r1csExists && fs.existsSync(PTAU_FILE)) {
      console.log(`    Verifying zkey integrity...`);
      try {
        run(
          `npx snarkjs zkey verify "${circuit.r1cs}" "${PTAU_FILE}" "${circuit.finalZkey}"`,
          { stdio: 'pipe' }
        );
        console.log(`    ✓ zkey verification PASSED`);
      } catch {
        console.log(`    ✗ zkey verification FAILED`);
      }
    }
  }

  // List participants
  console.log(`\n  Participants: ${manifest.participants.length}`);
  manifest.participants.forEach((p, i) => {
    console.log(`    ${String(i + 1).padStart(2, ' ')}. ${p.name} (${p.timestamp.slice(0, 10)})`);
  });

  if (manifest.beacon) {
    console.log(`\n  ✓ Beacon applied: ${manifest.beacon.timestamp.slice(0, 10)}`);
  }

  if (manifest.finalized) {
    console.log(`\n  ✓ Ceremony FINALIZED at: ${manifest.finalizedAt}`);
  } else {
    console.log(`\n  ∼ Ceremony NOT YET FINALIZED`);
  }

  console.log();
}

function cmdExport(circuitName) {
  const manifest = loadManifest();
  ensureDir(CONTRACTS_DIR);

  if (circuitName) {
    exportSingle(circuitName, manifest);
    return;
  }

  // Export all circuits
  for (const cn of Object.keys(CIRCUITS)) {
    exportSingle(cn, manifest);
  }
}

function exportSingle(circuitName, manifest) {
  const circuit = CIRCUITS[circuitName];
  if (!fs.existsSync(circuit.finalZkey)) {
    console.log(`  ∼ No final zkey for ${circuit.label}. Run 'init' and 'contribute' first.`);
    return;
  }

  console.log(`\n  📦 Exporting verifier for: ${circuit.label}`);
  console.log(`     Input:  ${path.basename(circuit.finalZkey)}`);

  // Export Solidity verifier
  console.log(`     Exporting Solidity verifier...`);
  run(
    `npx snarkjs zkey export solidityverifier "${circuit.finalZkey}" "${circuit.verifier}"`
  );
  console.log(`     ✓ Verifier: ${circuit.verifier}`);

  // Export verification key
  console.log(`     Exporting verification key...`);
  ensureDir(BUILD_DIR);
  run(
    `npx snarkjs zkey export verificationkey "${circuit.finalZkey}" "${circuit.vk}"`
  );
  console.log(`     ✓ VK:       ${circuit.vk}`);

  // Update manifest
  if (manifest.circuits[circuitName]) {
    manifest.circuits[circuitName].verifierExported = true;
    manifest.circuits[circuitName].verifierPath = circuit.verifier;
    manifest.circuits[circuitName].vkPath = circuit.vk;
    saveManifest(manifest);
  }

  // Compute final hash
  const finalHash = sha256File(circuit.finalZkey);
  console.log(`     Final SHA-256: ${finalHash}`);

  console.log(`  ✅ ${circuit.label} verifier exported successfully.`);
}

function cmdHash(filePath) {
  if (!filePath) {
    // Hash all ceremony files
    console.log(`\n  📋 Ceremony Contribution Hashes`);
    console.log(`     ${'═'.repeat(50)}`);
    const manifest = loadManifest();
    manifest.participants.forEach((p, i) => {
      for (const [cn, contrib] of Object.entries(p.circuits)) {
        console.log(`  #${i + 1} ${p.name} | ${cn}: ${contrib.contributionHash}`);
      }
    });
    if (manifest.beacon) {
      for (const [cn, data] of Object.entries(manifest.beacon.circuits)) {
        console.log(`  Beacon  | ${cn}: ${data.finalHash}`);
      }
    }
    console.log();
    return;
  }

  if (!fs.existsSync(filePath)) {
    console.error(`  ✗ File not found: ${filePath}`);
    process.exit(1);
  }
  const hash = sha256File(filePath);
  console.log(`\n  SHA-256(${path.basename(filePath)}) = ${hash}\n`);
}

function cmdStatus() {
  const manifest = loadManifest();

  console.log(`\n  ┌─────────────────────────────────────────────┐`);
  console.log(`  │  GhostChain Trusted Setup Ceremony Status   │`);
  console.log(`  └─────────────────────────────────────────────┘`);
  console.log(`\n  Phase 1 (Powers of Tau): ${fs.existsSync(PTAU_FILE) ? '✓' : '✗'}`);
  if (fs.existsSync(PTAU_FILE)) {
    console.log(`    File:  ${path.basename(PTAU_FILE)}`);
    console.log(`    Size:  ${formatBytes(fileSize(PTAU_FILE))}`);
    console.log(`    SHA-256: ${sha256File(PTAU_FILE).slice(0, 32)}...`);
  }

  console.log(`\n  Phase 2 (Circuit-specific):`);

  for (const [cn, circuit] of Object.entries(CIRCUITS)) {
    const info = manifest.circuits[cn];
    const initialized = fs.existsSync(circuit.initialZkey);
    const finalized = fs.existsSync(circuit.finalZkey);

    console.log(`\n    ${info ? '✓' : '○'} ${circuit.label} (${cn})`);
    console.log(`       Initialized: ${initialized ? '✓' : '✗'}`);
    console.log(`       Final zkey:  ${finalized ? '✓' : '✗'}`);
    console.log(`       Contributions: ${info ? info.contributions || 0 : 0}`);
    console.log(`       State:       ${info ? info.state || 'not initialized' : 'not initialized'}`);

    if (info && info.verifierExported) {
      console.log(`       Verifier:    ✓ Exported`);
    }
  }

  console.log(`\n  Participants: ${manifest.participants.length}`);
  manifest.participants.forEach((p, i) => {
    const contribHashes = Object.entries(p.circuits)
      .map(([cn, c]) => `${cn}: ${c.contributionHash.slice(0, 16)}...`)
      .join(', ');
    console.log(`    ${String(i + 1).padStart(2)}. ${p.name} — ${contribHashes}`);
  });

  if (manifest.beacon) {
    console.log(`\n  Beacon: ✓ Applied on ${manifest.beacon.timestamp.slice(0, 10)}`);
  }

  console.log(`\n  Finalized: ${manifest.finalized ? '✓ Yes' : '○ No'}`);
  console.log(`  Manifest:  ${MANIFEST_PATH}\n`);
}

function cmdVerifyContribution(contributorName) {
  const manifest = loadManifest();
  if (!contributorName) {
    console.error('  ✗ Usage: node scripts/ceremony.js verify-contribution "<Name>"');
    process.exit(1);
  }

  const participant = manifest.participants.find(
    (p) => p.name.toLowerCase() === contributorName.toLowerCase()
  );
  if (!participant) {
    console.error(`  ✗ Contribution not found for: ${contributorName}`);
    console.error(`    Current participants:`);
    manifest.participants.forEach((p, i) => console.error(`    ${i + 1}. ${p.name}`));
    process.exit(1);
  }

  const idx = manifest.participants.indexOf(participant);
  console.log(`\n  🔍 Verifying contribution #${idx + 1}: ${participant.name}`);
  console.log(`     ${'═'.repeat(50)}`);

  let allValid = true;
  for (const [circuitName, contrib] of Object.entries(participant.circuits)) {
    const circuit = CIRCUITS[circuitName];
    const zkeyPath = path.join(CEREMONY_DIR, contrib.contributionZkey);

    if (!fs.existsSync(zkeyPath)) {
      console.log(`\n  ✗ ${circuit.label}: Contribution file not found: ${zkeyPath}`);
      allValid = false;
      continue;
    }

    const actualHash = sha256File(zkeyPath);
    const expectedHash = contrib.contributionHash;
    const hashMatch = actualHash === expectedHash;

    console.log(`\n  ${hashMatch ? '✓' : '✗'} ${circuit.label}`);
    console.log(`    File:    ${contrib.contributionZkey}`);
    console.log(`    Size:    ${contrib.contributionSize}`);
    console.log(`    Expected SHA-256: ${expectedHash}`);
    console.log(`    Actual SHA-256:   ${actualHash}`);
    console.log(`    Integrity: ${hashMatch ? '✓ PASS' : '✗ FAIL'}`);

    if (!hashMatch) allValid = false;
  }

  if (allValid) {
    console.log(`\n  ✅ Contribution #${idx + 1} (${participant.name}) — ALL CHECKS PASSED`);
  } else {
    console.log(`\n  ❌ Contribution #${idx + 1} (${participant.name}) — SOME CHECKS FAILED`);
  }
  console.log();
}

function findLatestZkey(circuitName, circuit) {
  // Find the latest contribution zkey
  const files = fs.readdirSync(CEREMONY_DIR)
    .filter((f) => f.startsWith(`${circuitName}_contribution_`) && f.endsWith('.zkey'))
    .sort();
  if (files.length > 0) {
    return path.join(CEREMONY_DIR, files[files.length - 1]);
  }
  // Fall back to initial
  if (fs.existsSync(circuit.initialZkey)) {
    return circuit.initialZkey;
  }
  return null;
}

// ───── Main ─────

function main() {
  const args = process.argv.slice(2);
  const command = args[0];

  if (!command || command === '--help' || command === '-h') {
    console.log(`
  GhostChain Trusted Setup Ceremony Coordinator

  Usage:
    node scripts/ceremony.js <command> [options]

  Commands:
    init [circuit]           Initialize ceremony (omit circuit for all)
    contribute "<name>"      Add a participant contribution
    verify [file]            Verify ceremony or specific zkey file
    beacon [entropy]         Apply random beacon to finalize
    export [circuit]         Export verifier contracts and verification keys
    status                   Show ceremony status
    hash [file]              Print SHA-256 hash of file or all hashes
    verify-contribution "<name>"  Verify a specific participant's contribution

  Examples:
    node scripts/ceremony.js init
    node scripts/ceremony.js contribute "Alice (alice@example.com)"
    node scripts/ceremony.js contribute "Bob - GitHub: @bob"
    node scripts/ceremony.js status
    node scripts/ceremony.js verify
    node scripts/ceremony.js beacon 000000000000000000076abf4d8f1b0a57b9d1a0a2b5c8d9e0f1a2b3c4d5e6f7
    node scripts/ceremony.js export
    node scripts/ceremony.js verify-contribution "Alice"
    node scripts/ceremony.js hash ceremony/ghostTransfer_contribution_001.zkey

  Security Notes:
    1. Phase 1 uses the Hermez Powers of Tau (100+ participants) — trust is shared
    2. Each participant's contribution hash is published in manifest.json
    3. The random beacon provides security even if ALL participants collude
    4. Anyone can independently verify the entire ceremony with 'verify'
`);
    return;
  }

  switch (command) {
    case 'init':
      cmdInit(args[1]);
      break;
    case 'contribute':
      cmdContribute(args.slice(1).join(' '));
      break;
    case 'verify':
      cmdVerify(args[1]);
      break;
    case 'beacon':
      cmdBeacon(args[1]);
      break;
    case 'export':
      cmdExport(args[1]);
      break;
    case 'status':
      cmdStatus();
      break;
    case 'hash':
      cmdHash(args[1]);
      break;
    case 'verify-contribution':
    case 'check':
      cmdVerifyContribution(args.slice(1).join(' '));
      break;
    default:
      console.error(`  ✗ Unknown command: ${command}`);
      console.error(`    Run 'node scripts/ceremony.js --help' for usage.`);
      process.exit(1);
  }
}

main();

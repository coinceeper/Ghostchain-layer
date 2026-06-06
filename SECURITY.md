# Security Policy

## Reporting a Vulnerability

If you discover a security vulnerability in GhostChain Layer, please report it privately. **Do not** open a public GitHub issue for security vulnerabilities.

### How to Report

- Open a [GitHub Security Advisory](https://github.com/coinceeper/Ghostchain-layer/security/advisories/new)
- Or email the maintainer directly

You should receive a response within 48 hours. If you don't, please follow up.

## What to Include

- A clear description of the vulnerability
- Steps to reproduce (PoC preferred)
- Affected components (contracts, SDK, relayer, ZK circuits)
- Potential impact

## Scope

| Component | Location | Priority |
|-----------|----------|----------|
| Smart Contracts | `contracts/src/` | Critical |
| ZK Circuits | `zk/circuits/` | High |
| Relayer/Solver | `relayer/src/` | High |
| SDK | `sdk/src/` | Medium |
| CI/CD & Infrastructure | `.github/`, `docker-compose*.yml` | Medium |

## Bug Bounty

This project does not currently offer a bug bounty program. Security researchers who report valid vulnerabilities will be credited in release notes.

## Safe Harbor

Any security research conducted in good faith on this project is considered authorized. You will not face legal action for testing and reporting vulnerabilities through the channels above.

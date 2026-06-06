# Commit Guidelines

This repository values clear, technical, and human-readable commit history.

## What to include in every commit message

- A concise summary line describing the change.
- The affected layer or package (e.g. `contracts`, `frontend`, `sdk`, `relayer`, `zk`).
- A short body explaining why the change was made and what problem it solves.
- Any important protocol safety decisions or trade-offs.

## Example commit message structure

```
frontend: add browser demo for EphemeralFactory contract inspection

Add a static HTML/JS frontend that connects to MetaMask, reads a deployed
EphemeralFactory contract, and fetches swap state from Arbitrum Sepolia / Base Sepolia.

This demo reduces friction for testnet validation and keeps UI scope limited
to inspection and read-only contract verification.
```

## Good practices

- Prefer human-written descriptions over AI-generated summaries.
- Reference the exact module or feature area.
- Include any deployment or environment assumptions.
- Mention insecure defaults only when they must be used for development.

## What to avoid

- Vague messages like `update code` or `fix stuff`.
- Long lines without clear technical context.
- Overly broad commits that mix unrelated work.

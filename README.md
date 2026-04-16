# Arc Hackathon - AI Agent Commerce

## Project: AI-Validated Escrow with x402 Payments

Built for Circle's Arc Hackathon — combining:
- **Circle Arc Escrow** — AI-validated escrow contracts
- **x402 Protocol** — Nanopayments for agent-to-agent commerce
- **Dexter x402 SDK v3.0** — Cross-bazaar search engine for agents

## Tech Stack

- Solidity (smart contracts)
- Foundry (development framework)
- x402 SDK (agent payments)
- Circle Arc (escrow infrastructure)

## Structure

```
arc-hackathon/
├── arc-escrow/          # Circle's escrow contracts (fork)
├── src/                 # Our custom contracts
├── test/                # Foundry tests
├── scripts/             # Deployment scripts
└── package.json         # x402 SDK dependency
```

## Key Protocols

- **x402**: HTTP 402 Payment Required — nanopayment standard
- **ERC-8004**: Agent registration
- **ERC-8183**: Agent jobs marketplace

## Getting Started

```bash
# Install dependencies
npm install

# Run Foundry tests
forge test

# Deploy
forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast
```

## Resources

- [Circle Arc Escrow](https://github.com/circlefin/arc-escrow)
- [Dexter x402 SDK](https://www.npmjs.com/package/@dexterai/x402)
- [x402 Protocol](https://x402.org)
- [Circle Developer Docs](https://developers.circle.com)

## Team

Gentech Labs — Registered for Arc Hackathon

# 🚀 Arc Hackathon — AI-Validated Escrow with x402 Payments

**GitHub:** https://github.com/ProtoJay4789/arc-hackathon
**Status:** Active Development
**Team:** Gentech Labs

---

## 🎯 What We're Building

An **AI-validated escrow system** that combines:
- **x402 Protocol** — Nanopayments for agent-to-agent commerce
- **Circle Arc** — Battle-tested escrow infrastructure
- **AI Validators** — Like Cygent, but for payment validation
- **USDC** — Stable payments (no volatile ETH)

**The Flow:**
1. Agent requests service → Creates escrow with USDC
2. Service provider completes work
3. AI validator checks quality (like Cygent)
4. If approved → Funds release automatically
5. If rejected → Refund to agent

---

## ✨ Features

### ✅ Implemented
- [x] USDC payments (ERC20)
- [x] EIP712 signature verification
- [x] AI validator pattern
- [x] Replay attack protection
- [x] Comprehensive test suite
- [x] Multi-escrow support per user
- [x] Owner controls (refund, withdraw, validator update)

### 🔜 Next
- [ ] x402 payment integration
- [ ] Off-chain validation service
- [ ] Frontend dashboard
- [ ] Testnet deployment
- [ ] Demo video

---

## 🛠️ Tech Stack

- **Solidity 0.8.20** — Smart contracts
- **Foundry** — Development framework
- **OpenZeppelin** — Security libraries (ERC20, EIP712, ECDSA)
- **x402 SDK v3.0** — Dexter AI payment protocol
- **USDC** — Stablecoin payments
- **Avalanche** — Target blockchain

---

## 📦 Installation

### Prerequisites
- [Foundry](https://book.getfoundry.sh/getting-started/installation) installed
- Node.js 18+ (for x402 SDK)
- Git

### Quick Start

```bash
# Clone the repo
git clone https://github.com/ProtoJay4789/arc-hackathon.git
cd arc-hackathon

# Run setup script
chmod +x setup.sh
./setup.sh

# Or manually:
forge install
forge build
forge test
```

### Environment Setup

Create `.env` file:

```bash
# Solana (for x402)
SOLANA_PRIVATE_KEY=your_solana_private_key

# EVM (Avalanche/Base)
EVM_PRIVATE_KEY=your_evm_private_key

# API Keys
CIRCLE_API_KEY=your_circle_api_key
COINBASE_API_KEY=your_coinbase_api_key

# RPC URLs
AVALANCHE_FUJI_RPC=https://api.avax-test.network/ext/bc/C/rpc
BASE_SEPOLIA_RPC=https://sepolia.base.org
```

---

## 🧪 Testing

```bash
# Run all tests
forge test

# Run with verbose output
forge test -vv

# Run specific test
forge test --match-test testCreateEscrow

# Gas snapshots
forge snapshot
```

---

## 🚀 Deployment

### Avalanche Fuji Testnet

```bash
# Deploy contracts
forge script script/Deploy.s.sol \
  --rpc-url avalanche_fuji \
  --broadcast \
  --verify

# Check deployment
cast <contract_address> --rpc-url avalanche_fuji
```

### Get Testnet Tokens

1. **AVAX:** https://faucet.avax.network
2. **USDC:** https://faucet.circle.com

---

## 📖 Contract Usage

### Create Escrow

```solidity
// Buyer approves USDC spending
usdc.approve(address(escrow), amount);

// Create escrow
uint256 escrowId = escrow.createEscrow(seller, amount);
```

### Validate Work (Direct)

```solidity
// Only validator can call
escrow.validateWork(escrowId);
```

### Validate with Signature (Off-chain)

```solidity
// Validator signs hash off-chain
bytes32 hash = escrow.hashValidation(escrowId, timestamp);
(uint8 v, bytes32 r, bytes32 s) = sign(validatorKey, hash);

// Anyone can submit validation
escrow.validateWithSignature(escrowId, timestamp, abi.encodePacked(r, s, v));
```

### Release Funds

```solidity
// Buyer releases funds to seller
escrow.releaseFunds(escrowId);
```

### Refund

```solidity
// Owner refunds buyer
escrow.refundBuyer(escrowId);
```

---

## 🔐 Security Features

- **EIP712** — Typed structured data signing
- **ECDSA** — Signature verification
- **Replay Protection** — Signatures can't be reused
- **Access Control** — Only validator/owner can perform critical actions
- **Checks-Effects-Interactions** — Safe state updates
- **Custom Errors** — Gas-efficient error handling

---

## 🎓 Learning Resources

- [x402 Protocol Docs](https://docs.x402.org)
- [Circle Arc Escrow](https://github.com/circlefin/arc-escrow)
- [Dexter x402 SDK](https://www.npmjs.com/package/@dexterai/x402)
- [Cyfrin Cygent](https://www.cyfrin.io/blog/announcing-cygent)
- [OpenZeppelin Contracts](https://docs.openzeppelin.com/contracts/5.x/)

---

## 📊 Contract Addresses

### Avalanche Fuji Testnet
- **AgentEscrow:** `TBD` (deploy soon)
- **USDC:** `0x5425890298aed601595a70AB815c96711a31Bc65`

---

## 🗺️ Roadmap

### Week 1: Foundation ✅
- [x] Contract development
- [x] USDC integration
- [x] EIP712 signatures
- [x] Test suite

### Week 2: Integration (Current)
- [ ] x402 payment flow
- [ ] Off-chain validator service
- [ ] Local testing

### Week 3: Deployment
- [ ] Testnet deployment
- [ ] Frontend dashboard
- [ ] End-to-end demo

### Week 4: Polish
- [ ] Security audit
- [ ] Documentation
- [ ] Hackathon submission

---

## 🤝 Contributing

This project is part of the Arc Hackathon. Feel free to:
- Open issues for bugs
- Submit PRs for improvements
- Fork and experiment

---

## 📄 License

MIT License - see LICENSE file

---

## 🙏 Acknowledgments

- **Circle** — For Arc escrow patterns
- **Dexter AI** — For x402 SDK
- **Cyfrin** — For Cygent inspiration
- **Coinbase** — For x402 protocol

---

**Built with ❤️ by Gentech Labs**
**For Arc Hackathon 2026**

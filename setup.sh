#!/bin/bash

# Arc Hackathon Setup Script
# Run this after cloning the repo

set -e

echo "🚀 Setting up Arc Hackathon project..."

# Check if forge is installed
if ! command -v forge &> /dev/null; then
    echo "❌ Foundry not found. Installing..."
    curl -L https://foundry.paradigm.xyz | bash
    source ~/.bashrc
    foundryup
fi

echo "✅ Foundry installed"

# Install OpenZeppelin contracts
echo "📦 Installing OpenZeppelin contracts..."
forge install OpenZeppelin/openzeppelin-contracts --no-commit

echo "✅ Dependencies installed"

# Create .env file if it doesn't exist
if [ ! -f .env ]; then
    echo "📝 Creating .env file..."
    cat > .env << 'EOF'
# Solana (for x402)
SOLANA_PRIVATE_KEY=your_solana_private_key_here

# EVM (Avalanche/Base)
EVM_PRIVATE_KEY=your_evm_private_key_here

# API Keys
CIRCLE_API_KEY=your_circle_api_key_here
COINBASE_API_KEY=your_coinbase_api_key_here

# RPC URLs
AVALANCHE_FUJI_RPC=https://api.avax-test.network/ext/bc/C/rpc
BASE_SEPOLIA_RPC=https://sepolia.base.org

# Deployer Address
DEPLOYER_ADDRESS=your_wallet_address_here
EOF
    echo "⚠️  Please edit .env with your actual keys"
fi

# Build the project
echo "🔨 Building contracts..."
forge build

echo "🧪 Running tests..."
forge test

echo ""
echo "✅ Setup complete!"
echo ""
echo "📋 Next steps:"
echo "1. Edit .env with your private keys"
echo "2. Get testnet tokens:"
echo "   - AVAX: https://faucet.avax.network"
echo "   - USDC: https://faucet.circle.com"
echo "3. Deploy to testnet:"
echo "   forge script script/Deploy.s.sol --rpc-url avalanche_fuji --broadcast"
echo ""
echo "🚀 Ready to hack!"

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/AgentEscrow.sol";
import "../src/X402PaymentHandler.sol";
import "../src/DisputeResolver.sol";

/**
 * @title Deploy Full Stack to Arc Testnet
 * @notice Deploys AgentEscrow + X402PaymentHandler + DisputeResolver
 *         for the "Agentic Economy on Arc" hackathon
 *
 * Usage:
 *   forge script script/Deploy.s.sol --rpc-url arc_testnet --broadcast
 */
contract DeployArcHackathon is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("EVM_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        // Arc Testnet USDC (native gas token with ERC-20 interface)
        // Docs: https://docs.arc.network/arc/references/contract-addresses
        address usdcAddress = 0x3600000000000000000000000000000000000000;

        // Configuration
        address aiValidator = deployer;       // AI validator (deployer for testing)
        address facilitator = deployer;       // x402 facilitator (deployer for testing)
        uint256 platformFeeBps = 250;         // 2.5% platform fee
        uint256 evidenceWindow = 1 hours;     // 1 hour to submit evidence
        uint256 disputeDeadline = 24 hours;   // 24 hour dispute window

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy AgentEscrow (core escrow)
        AgentEscrow escrow = new AgentEscrow(aiValidator, usdcAddress);

        // 2. Deploy X402PaymentHandler (x402 settlement + service registry)
        X402PaymentHandler paymentHandler = new X402PaymentHandler(
            usdcAddress,
            facilitator,
            address(escrow),
            platformFeeBps
        );

        // 3. Deploy DisputeResolver (arbitration layer)
        DisputeResolver disputeResolver = new DisputeResolver(
            address(escrow),
            usdcAddress,
            evidenceWindow,
            disputeDeadline
        );

        vm.stopBroadcast();

        // === Deployment Summary ===
        console.log("========================================");
        console.log("  Arc Hackathon - Full Stack Deployment  ");
        console.log("========================================");
        console.log("");
        console.log("AgentEscrow:        ", address(escrow));
        console.log("X402PaymentHandler: ", address(paymentHandler));
        console.log("DisputeResolver:    ", address(disputeResolver));
        console.log("");
        console.log("--- Configuration ---");
        console.log("USDC:               ", usdcAddress);
        console.log("AI Validator:       ", aiValidator);
        console.log("Facilitator:        ", facilitator);
        console.log("Platform Fee:       ", platformFeeBps, "bps (2.5%)");
        console.log("Evidence Window:    ", evidenceWindow, "seconds");
        console.log("Dispute Deadline:   ", disputeDeadline, "seconds");
        console.log("Owner:              ", deployer);
        console.log("Chain ID:           ", uint256(5042002));
        console.log("");
        console.log("--- Explorer Links ---");
        console.log("AgentEscrow:        https://testnet.arcscan.app/address/", address(escrow));
        console.log("PaymentHandler:     https://testnet.arcscan.app/address/", address(paymentHandler));
        console.log("DisputeResolver:    https://testnet.arcscan.app/address/", address(disputeResolver));
        console.log("========================================");
    }
}

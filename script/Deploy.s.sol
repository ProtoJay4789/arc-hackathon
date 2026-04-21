// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/AgentEscrow.sol";
import "../src/X402PaymentHandler.sol";
import "../src/HumanDisputeResolver.sol";
import "../src/GenLayerOracleResolver.sol";
import "../src/interfaces/IResolver.sol";

/**
 * @title Deploy Full Stack to Arc Testnet
 * @notice Deploys AgentEscrow + X402PaymentHandler + HumanDisputeResolver + GenLayerOracleResolver
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

        // 1. Deploy HumanDisputeResolver (Tier 1 — human arbitration)
        HumanDisputeResolver humanResolver = new HumanDisputeResolver(
            evidenceWindow,
            disputeDeadline
        );

        // 2. Deploy GenLayerOracleResolver (Tier 2 — AI oracle, stub for demo)
        GenLayerOracleResolver oracleResolver = new GenLayerOracleResolver();

        // 3. Deploy AgentEscrow with human resolver as default
        AgentEscrow escrow = new AgentEscrow(aiValidator, usdcAddress, address(humanResolver));

        // 4. Deploy X402PaymentHandler (x402 settlement + service registry)
        X402PaymentHandler paymentHandler = new X402PaymentHandler(
            usdcAddress,
            facilitator,
            address(escrow),
            platformFeeBps
        );

        vm.stopBroadcast();

        // === Deployment Summary ===
        console.log("========================================");
        console.log("  Arc Hackathon - Full Stack Deployment  ");
        console.log("========================================");
        console.log("");
        console.log("AgentEscrow:             ", address(escrow));
        console.log("X402PaymentHandler:      ", address(paymentHandler));
        console.log("HumanDisputeResolver:    ", address(humanResolver));
        console.log("GenLayerOracleResolver:  ", address(oracleResolver));
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
        console.log("--- Two-Tier Architecture ---");
        console.log("Tier 1: Human arbitration (default)");
        console.log("Tier 2: GenLayer AI oracle (opt-in escalation)");
        console.log("Both implement IResolver -- escrow doesn't care which.");
        console.log("");
        console.log("--- Explorer Links ---");
        console.log("AgentEscrow:        https://testnet.arcscan.app/address/", address(escrow));
        console.log("PaymentHandler:     https://testnet.arcscan.app/address/", address(paymentHandler));
        console.log("HumanResolver:      https://testnet.arcscan.app/address/", address(humanResolver));
        console.log("GenLayerResolver:   https://testnet.arcscan.app/address/", address(oracleResolver));
        console.log("========================================");
    }
}

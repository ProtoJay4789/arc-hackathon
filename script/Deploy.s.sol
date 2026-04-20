// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/AgentEscrow.sol";

/**
 * @title Deploy AgentEscrow to Arc Testnet
 * @notice Deployment script for ARC Hackathon
 */
contract DeployAgentEscrow is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("EVM_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        
        // Arc Testnet USDC (native gas token, ERC-20 interface)
        // Docs: https://docs.arc.network/arc/references/contract-addresses
        address usdcAddress = 0x3600000000000000000000000000000000000000;
        
        // AI Validator address (deployer for testing)
        address aiValidator = deployer;
        
        vm.startBroadcast(deployerPrivateKey);
        
        AgentEscrow escrow = new AgentEscrow(aiValidator, usdcAddress);
        
        vm.stopBroadcast();
        
        console.log("=== Arc Testnet Deployment ===");
        console.log("AgentEscrow deployed at:", address(escrow));
        console.log("AI Validator:", aiValidator);
        console.log("USDC (ERC-20):", usdcAddress);
        console.log("Owner:", deployer);
        console.log("Chain ID: 5042002");
        console.log("Explorer: https://testnet.arcscan.app/address/", address(escrow));
    }
}

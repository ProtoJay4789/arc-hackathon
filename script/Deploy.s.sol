// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/AgentEscrow.sol";

/**
 * @title Deploy AgentEscrow
 * @notice Deployment script for AgentEscrow contract
 */
contract DeployAgentEscrow is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("EVM_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        
        // USDC addresses by network
        // Avalanche Fuji: 0x5425890298aed601595a70AB815c96711a31Bc65
        // Base Sepolia: 0x036CbD53842c5426634e7929541eC2318f3dCF7e
        // Mainnet (Base): 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
        
        // For testing, use Avalanche Fuji
        address usdcAddress = 0x5425890298aed601595a70AB815c96711a31Bc65;
        
        // AI Validator address (your address for testing)
        address aiValidator = deployer;
        
        vm.startBroadcast(deployerPrivateKey);
        
        AgentEscrow escrow = new AgentEscrow(aiValidator, usdcAddress);
        
        vm.stopBroadcast();
        
        console.log("AgentEscrow deployed at:", address(escrow));
        console.log("AI Validator:", aiValidator);
        console.log("USDC:", usdcAddress);
        console.log("Owner:", deployer);
    }
}

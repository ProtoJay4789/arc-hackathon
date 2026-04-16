// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/AgentEscrow.sol";
import "./MockUSDC.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

contract AgentEscrowTest is Test {
    using ECDSA for bytes32;

    AgentEscrow public escrow;
    MockUSDC public usdc;
    
    address public owner = makeAddr("owner");
    address public validator = makeAddr("validator");
    address public buyer = makeAddr("buyer");
    address public seller = makeAddr("seller");
    
    uint256 constant ESCROW_AMOUNT = 100 * 10**6; // 100 USDC (6 decimals)
    uint256 constant USDC_DECIMALS = 6;
    
    function setUp() public {
        // Deploy mock USDC
        vm.startPrank(owner);
        usdc = new MockUSDC();
        
        // Deploy escrow contract
        escrow = new AgentEscrow(address(validator), address(usdc));
        
        // Transfer USDC to buyer for testing
        usdc.transfer(buyer, 10000 * 10**6); // 10K USDC
        
        // Approve escrow contract to spend buyer's USDC
        vm.stopPrank();
        vm.startPrank(buyer);
        usdc.approve(address(escrow), type(uint256).max);
        vm.stopPrank();
    }
    
    function testCreateEscrow() public {
        uint256 buyerBalanceBefore = usdc.balanceOf(buyer);
        
        vm.startPrank(buyer);
        uint256 escrowId = escrow.createEscrow(seller, ESCROW_AMOUNT);
        
        assertEq(escrowId, 1);
        assertEq(usdc.balanceOf(address(escrow)), ESCROW_AMOUNT);
        assertEq(usdc.balanceOf(buyer), buyerBalanceBefore - ESCROW_AMOUNT);
        
        AgentEscrow.Escrow memory e = escrow.getEscrow(escrowId);
        assertEq(e.buyer, buyer);
        assertEq(e.seller, seller);
        assertEq(e.amount, ESCROW_AMOUNT);
        assertEq(uint8(e.status), uint8(AgentEscrow.EscrowStatus.Created));
        assertFalse(e.validated);
        
        vm.stopPrank();
    }
    
    function testValidateWork() public {
        vm.startPrank(buyer);
        uint256 escrowId = escrow.createEscrow(seller, ESCROW_AMOUNT);
        vm.stopPrank();
        
        // Validator validates the work
        vm.startPrank(validator);
        escrow.validateWork(escrowId);
        
        AgentEscrow.Escrow memory e = escrow.getEscrow(escrowId);
        assertTrue(e.validated);
        assertEq(uint8(e.status), uint8(AgentEscrow.EscrowStatus.Validated));
        assertTrue(e.validatedAt > 0);
        
        vm.stopPrank();
    }
    
    function testValidateWithSignature() public {
        vm.startPrank(buyer);
        uint256 escrowId = escrow.createEscrow(seller, ESCROW_AMOUNT);
        vm.stopPrank();
        
        // Create EIP712 signature
        uint256 timestamp = block.timestamp;
        bytes32 hash = escrow.hashValidation(escrowId, timestamp);
        
        // Sign with validator's private key
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(validator, hash);
        bytes memory signature = abi.encodePacked(r, s, v);
        
        // Validate with signature
        escrow.validateWithSignature(escrowId, timestamp, signature);
        
        AgentEscrow.Escrow memory e = escrow.getEscrow(escrowId);
        assertTrue(e.validated);
        assertEq(uint8(e.status), uint8(AgentEscrow.EscrowStatus.Validated));
    }
    
    function testReleaseFunds() public {
        vm.startPrank(buyer);
        uint256 escrowId = escrow.createEscrow(seller, ESCROW_AMOUNT);
        vm.stopPrank();
        
        // Validate
        vm.prank(validator);
        escrow.validateWork(escrowId);
        
        uint256 sellerBalanceBefore = usdc.balanceOf(seller);
        
        // Release funds
        vm.prank(buyer);
        escrow.releaseFunds(escrowId);
        
        assertEq(usdc.balanceOf(seller), sellerBalanceBefore + ESCROW_AMOUNT);
        assertEq(usdc.balanceOf(address(escrow)), 0);
        
        AgentEscrow.Escrow memory e = escrow.getEscrow(escrowId);
        assertEq(uint8(e.status), uint8(AgentEscrow.EscrowStatus.Released));
    }
    
    function testRefundBuyer() public {
        vm.startPrank(buyer);
        uint256 escrowId = escrow.createEscrow(seller, ESCROW_AMOUNT);
        vm.stopPrank();
        
        uint256 buyerBalanceBefore = usdc.balanceOf(buyer);
        
        // Owner refunds buyer
        vm.prank(owner);
        escrow.refundBuyer(escrowId);
        
        assertEq(usdc.balanceOf(buyer), buyerBalanceBefore + ESCROW_AMOUNT);
        assertEq(usdc.balanceOf(address(escrow)), 0);
        
        AgentEscrow.Escrow memory e = escrow.getEscrow(escrowId);
        assertEq(uint8(e.status), uint8(AgentEscrow.EscrowStatus.Refunded));
    }
    
    function testCannotReleaseWithoutValidation() public {
        vm.startPrank(buyer);
        uint256 escrowId = escrow.createEscrow(seller, ESCROW_AMOUNT);
        
        // Try to release without validation - should fail
        vm.expectRevert(AgentEscrow.ValidationRequired.selector);
        escrow.releaseFunds(escrowId);
        
        vm.stopPrank();
    }
    
    function testOnlyValidatorCanValidate() public {
        vm.startPrank(buyer);
        uint256 escrowId = escrow.createEscrow(seller, ESCROW_AMOUNT);
        vm.stopPrank();
        
        // Random user tries to validate - should fail
        vm.startPrank(seller);
        vm.expectRevert(AgentEscrow.NotAuthorized.selector);
        escrow.validateWork(escrowId);
        
        vm.stopPrank();
    }
    
    function testCannotValidateTwice() public {
        vm.startPrank(buyer);
        uint256 escrowId = escrow.createEscrow(seller, ESCROW_AMOUNT);
        vm.stopPrank();
        
        // First validation
        vm.prank(validator);
        escrow.validateWork(escrowId);
        
        // Try to validate again - should fail
        vm.prank(validator);
        vm.expectRevert(AgentEscrow.EscrowAlreadyValidated.selector);
        escrow.validateWork(escrowId);
    }
    
    function testUpdateValidator() public {
        address newValidator = makeAddr("newValidator");
        
        vm.prank(owner);
        escrow.setValidator(newValidator);
        
        assertEq(escrow.aiValidator(), newValidator);
    }
    
    function testDepositAndWithdraw() public {
        uint256 depositAmount = 500 * 10**6; // 500 USDC
        
        // Owner deposits funds
        vm.startPrank(owner);
        usdc.approve(address(escrow), depositAmount);
        escrow.depositFunds(depositAmount);
        vm.stopPrank();
        
        assertEq(usdc.balanceOf(address(escrow)), depositAmount);
        
        // Owner withdraws funds
        vm.prank(owner);
        escrow.withdrawFunds(depositAmount);
        
        assertEq(usdc.balanceOf(address(escrow)), 0);
    }
    
    function testTransferOwnership() public {
        address newOwner = makeAddr("newOwner");
        
        vm.prank(owner);
        escrow.transferOwnership(newOwner);
        
        assertEq(escrow.owner(), newOwner);
    }
    
    function testSignatureReplayProtection() public {
        vm.startPrank(buyer);
        uint256 escrowId = escrow.createEscrow(seller, ESCROW_AMOUNT);
        vm.stopPrank();
        
        // Create signature
        uint256 timestamp = block.timestamp;
        bytes32 hash = escrow.hashValidation(escrowId, timestamp);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(validator, hash);
        bytes memory signature = abi.encodePacked(r, s, v);
        
        // First use succeeds
        escrow.validateWithSignature(escrowId, timestamp, signature);
        
        // Second use fails (replay protection)
        vm.expectRevert(AgentEscrow.InvalidSignature.selector);
        escrow.validateWithSignature(escrowId, timestamp, signature);
    }
    
    function testInvalidSignatureFails() public {
        vm.startPrank(buyer);
        uint256 escrowId = escrow.createEscrow(seller, ESCROW_AMOUNT);
        vm.stopPrank();
        
        // Sign with wrong key (buyer instead of validator)
        uint256 timestamp = block.timestamp;
        bytes32 hash = escrow.hashValidation(escrowId, timestamp);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(buyer, hash);
        bytes memory signature = abi.encodePacked(r, s, v);
        
        // Should fail
        vm.expectRevert(AgentEscrow.InvalidSignature.selector);
        escrow.validateWithSignature(escrowId, timestamp, signature);
    }
    
    function testMultipleEscrows() public {
        // Create first escrow
        vm.startPrank(buyer);
        uint256 escrowId1 = escrow.createEscrow(seller, ESCROW_AMOUNT);
        vm.stopPrank();
        
        // Create second escrow with different seller
        address seller2 = makeAddr("seller2");
        vm.startPrank(buyer);
        uint256 escrowId2 = escrow.createEscrow(seller2, ESCROW_AMOUNT * 2);
        vm.stopPrank();
        
        // Check user escrows
        uint256[] memory buyerEscrows = escrow.getUserEscrows(buyer);
        assertEq(buyerEscrows.length, 2);
        assertEq(buyerEscrows[0], escrowId1);
        assertEq(buyerEscrows[1], escrowId2);
        
        uint256[] memory sellerEscrows = escrow.getUserEscrows(seller);
        assertEq(sellerEscrows.length, 1);
        assertEq(sellerEscrows[0], escrowId1);
    }
}

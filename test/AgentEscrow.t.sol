// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/AgentEscrow.sol";

contract AgentEscrowTest is Test {
    AgentEscrow public escrow;
    
    address public owner = makeAddr("owner");
    address public validator = makeAddr("validator");
    address public buyer = makeAddr("buyer");
    address public seller = makeAddr("seller");
    
    uint256 constant ESCROW_AMOUNT = 1 ether;
    
    function setUp() public {
        vm.startPrank(owner);
        escrow = new AgentEscrow(validator);
        vm.stopPrank();
    }
    
    function testCreateEscrow() public {
        vm.startPrank(buyer);
        uint256 escrowId = escrow.createEscrow{value: ESCROW_AMOUNT}(seller);
        
        assertEq(escrowId, 1);
        
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
        uint256 escrowId = escrow.createEscrow{value: ESCROW_AMOUNT}(seller);
        vm.stopPrank();
        
        // Validator validates the work
        vm.startPrank(validator);
        escrow.validateWork(escrowId);
        
        AgentEscrow.Escrow memory e = escrow.getEscrow(escrowId);
        assertTrue(e.validated);
        assertEq(uint8(e.status), uint8(AgentEscrow.EscrowStatus.Validated));
        
        vm.stopPrank();
    }
    
    function testReleaseFunds() public {
        vm.startPrank(buyer);
        uint256 escrowId = escrow.createEscrow{value: ESCROW_AMOUNT}(seller);
        vm.stopPrank();
        
        // Validate
        vm.prank(validator);
        escrow.validateWork(escrowId);
        
        uint256 sellerBalanceBefore = seller.balance;
        
        // Release funds
        vm.prank(buyer);
        escrow.releaseFunds(escrowId);
        
        assertEq(seller.balance, sellerBalanceBefore + ESCROW_AMOUNT);
        
        AgentEscrow.Escrow memory e = escrow.getEscrow(escrowId);
        assertEq(uint8(e.status), uint8(AgentEscrow.EscrowStatus.Released));
    }
    
    function testRefundBuyer() public {
        vm.startPrank(buyer);
        uint256 escrowId = escrow.createEscrow{value: ESCROW_AMOUNT}(seller);
        vm.stopPrank();
        
        uint256 buyerBalanceBefore = buyer.balance;
        
        // Owner refunds buyer
        vm.prank(owner);
        escrow.refundBuyer(escrowId);
        
        assertEq(buyer.balance, buyerBalanceBefore + ESCROW_AMOUNT);
        
        AgentEscrow.Escrow memory e = escrow.getEscrow(escrowId);
        assertEq(uint8(e.status), uint8(AgentEscrow.EscrowStatus.Refunded));
    }
    
    function testCannotReleaseWithoutValidation() public {
        vm.startPrank(buyer);
        uint256 escrowId = escrow.createEscrow{value: ESCROW_AMOUNT}(seller);
        
        // Try to release without validation - should fail
        vm.expectRevert(AgentEscrow.ValidationRequired.selector);
        escrow.releaseFunds(escrowId);
        
        vm.stopPrank();
    }
    
    function testOnlyValidatorCanValidate() public {
        vm.startPrank(buyer);
        uint256 escrowId = escrow.createEscrow{value: ESCROW_AMOUNT}(seller);
        vm.stopPrank();
        
        // Random user tries to validate - should fail
        vm.startPrank(seller);
        vm.expectRevert(AgentEscrow.NotAuthorized.selector);
        escrow.validateWork(escrowId);
        
        vm.stopPrank();
    }
    
    function testUpdateValidator() public {
        address newValidator = makeAddr("newValidator");
        
        vm.prank(owner);
        escrow.setValidator(newValidator);
        
        assertEq(escrow.aiValidator(), newValidator);
    }
    
    function testTransferOwnership() public {
        address newOwner = makeAddr("newOwner");
        
        vm.prank(owner);
        escrow.transferOwnership(newOwner);
        
        assertEq(escrow.owner(), newOwner);
    }
}

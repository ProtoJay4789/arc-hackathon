// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {AgentEscrow} from "../src/AgentEscrow.sol";
import {DisputeResolver} from "../src/DisputeResolver.sol";

contract MockUSDC2 is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract DisputeResolverTest is Test {
    MockUSDC2 usdc;
    AgentEscrow escrow;
    DisputeResolver resolver;

    address owner = makeAddr("owner");
    address buyer = makeAddr("buyer");
    address seller = makeAddr("seller");
    address validator = makeAddr("validator");
    address arbitrator = makeAddr("arbitrator");

    uint256 constant ONE_USDC = 1e6;
    uint256 constant EVIDENCE_WINDOW = 1 hours;
    uint256 constant DISPUTE_DEADLINE = 24 hours;

    function setUp() public {
        vm.startPrank(owner);

        usdc = new MockUSDC2();
        escrow = new AgentEscrow(address(validator), address(usdc));
        resolver = new DisputeResolver(
            address(escrow),
            address(usdc),
            EVIDENCE_WINDOW,
            DISPUTE_DEADLINE
        );

        // Add arbitrator
        resolver.addArbitrator(arbitrator);

        // Fund buyer + create escrow
        usdc.mint(buyer, 10 * ONE_USDC);
        vm.stopPrank();

        vm.prank(buyer);
        usdc.approve(address(escrow), type(uint256).max);

        vm.prank(buyer);
        escrow.createEscrow(seller, 5 * ONE_USDC);
    }

    function testOpenDispute() public {
        vm.prank(buyer);
        uint256 disputeId = resolver.openDispute(1, "Work not delivered");

        DisputeResolver.Dispute memory d = resolver.getDispute(disputeId);
        assertEq(d.escrowId, 1);
        assertEq(d.initiator, buyer);
        assertEq(d.buyer, buyer);
        assertEq(d.seller, seller);
        assertEq(d.amount, 5 * ONE_USDC);
        assertEq(uint8(d.status), uint8(DisputeResolver.DisputeStatus.Open));
    }

    function testSubmitEvidence() public {
        vm.prank(buyer);
        uint256 disputeId = resolver.openDispute(1, "Quality issue");

        vm.prank(seller);
        resolver.submitEvidence(disputeId, "ipfs://QmEvidenceHash123");

        assertEq(resolver.getEvidenceCount(disputeId), 1);

        DisputeResolver.Evidence[] memory evidence = resolver.getEvidence(disputeId);
        assertEq(evidence[0].submitter, seller);
        assertEq(evidence[0].content, "ipfs://QmEvidenceHash123");
    }

    function testResolveDisputeBuyerWins() public {
        vm.prank(buyer);
        uint256 disputeId = resolver.openDispute(1, "No work delivered");

        vm.prank(arbitrator);
        resolver.resolveDispute(disputeId, DisputeResolver.Resolution.BuyerWins, "No evidence of work");

        DisputeResolver.Dispute memory d = resolver.getDispute(disputeId);
        assertEq(uint8(d.resolution), uint8(DisputeResolver.Resolution.BuyerWins));
        assertEq(uint8(d.status), uint8(DisputeResolver.DisputeStatus.Resolved));
        assertEq(d.resolvedBy, arbitrator);
    }

    function testResolveDisputeSplit() public {
        vm.prank(buyer);
        uint256 disputeId = resolver.openDispute(1, "Partial delivery");

        vm.prank(arbitrator);
        resolver.resolveDispute(disputeId, DisputeResolver.Resolution.Split, "50% complete");

        DisputeResolver.Dispute memory d = resolver.getDispute(disputeId);
        assertEq(uint8(d.resolution), uint8(DisputeResolver.Resolution.Split));
    }

    function testCancelDispute() public {
        vm.prank(buyer);
        uint256 disputeId = resolver.openDispute(1, "Changed my mind");

        vm.prank(buyer);
        resolver.cancelDispute(disputeId);

        DisputeResolver.Dispute memory d = resolver.getDispute(disputeId);
        assertEq(uint8(d.status), uint8(DisputeResolver.DisputeStatus.Cancelled));
    }

    function testOnlyArbitratorCanResolve() public {
        vm.prank(buyer);
        uint256 disputeId = resolver.openDispute(1, "Test");

        vm.prank(buyer);
        vm.expectRevert(DisputeResolver.NotArbitrator.selector);
        resolver.resolveDispute(disputeId, DisputeResolver.Resolution.BuyerWins, "self-resolve");
    }

    function testOnlyPartyCanOpenDispute() public {
        address rando = makeAddr("rando");
        vm.prank(rando);
        vm.expectRevert(DisputeResolver.NotPartyToDispute.selector);
        resolver.openDispute(1, "I'm not involved");
    }

    function testCannotResolveTwice() public {
        vm.prank(buyer);
        uint256 disputeId = resolver.openDispute(1, "Test");

        vm.prank(arbitrator);
        resolver.resolveDispute(disputeId, DisputeResolver.Resolution.BuyerWins, "first");

        vm.prank(arbitrator);
        vm.expectRevert(DisputeResolver.DisputeAlreadyResolved.selector);
        resolver.resolveDispute(disputeId, DisputeResolver.Resolution.SellerWins, "second");
    }

    function testEvidenceWindowClosed() public {
        vm.prank(buyer);
        uint256 disputeId = resolver.openDispute(1, "Test");

        // Warp past evidence window
        vm.warp(block.timestamp + EVIDENCE_WINDOW + 1);

        vm.prank(buyer);
        vm.expectRevert(DisputeResolver.EvidenceWindowClosed.selector);
        resolver.submitEvidence(disputeId, "too late");
    }
}

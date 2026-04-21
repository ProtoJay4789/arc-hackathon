// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {AgentEscrow} from "../src/AgentEscrow.sol";
import {HumanDisputeResolver} from "../src/HumanDisputeResolver.sol";
import {IResolver} from "../src/interfaces/IResolver.sol";

contract MockUSDC2 is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract HumanDisputeResolverTest is Test {
    MockUSDC2 usdc;
    AgentEscrow escrow;
    HumanDisputeResolver resolver;

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

        // Deploy resolver first (no dependencies)
        resolver = new HumanDisputeResolver(EVIDENCE_WINDOW, DISPUTE_DEADLINE);
        resolver.addArbitrator(arbitrator);

        // Deploy escrow with resolver
        usdc = new MockUSDC2();
        escrow = new AgentEscrow(address(validator), address(usdc), address(resolver));

        // Fund buyer + create escrow
        usdc.mint(buyer, 10 * ONE_USDC);
        vm.stopPrank();

        vm.prank(buyer);
        usdc.approve(address(escrow), type(uint256).max);

        vm.prank(buyer);
        escrow.createEscrow(seller, 5 * ONE_USDC);
    }

    // ============ IResolver: fileDispute ============

    function testFileDispute() public {
        vm.prank(buyer);
        uint256 disputeId = resolver.fileDispute(IResolver.DisputeContext({
            escrowId: 1,
            buyer: buyer,
            seller: seller,
            token: address(usdc),
            amount: 5 * ONE_USDC,
            serviceDescription: "Work not delivered",
            metadata: ""
        }));

        assertEq(disputeId, 1);

        HumanDisputeResolver.Dispute memory d = resolver.getDispute(disputeId);
        assertEq(d.escrowId, 1);
        assertEq(d.initiator, buyer);
        assertEq(d.buyer, buyer);
        assertEq(d.seller, seller);
        assertEq(d.amount, 5 * ONE_USDC);
        assertEq(uint8(d.verdict), uint8(IResolver.Verdict.Pending));
        assertEq(uint8(d.status), uint8(HumanDisputeResolver.DisputeStatus.Open));
    }

    function testFileDisputeViaEscrow() public {
        // Use the escrow's openDispute() wrapper
        vm.prank(buyer);
        uint256 disputeId = escrow.openDispute(1, "Work not delivered");

        assertEq(disputeId, 1);

        AgentEscrow.Escrow memory e = escrow.getEscrow(1);
        assertEq(uint8(e.status), uint8(AgentEscrow.EscrowStatus.Disputed));
    }

    function testCannotFileDisputeTwice() public {
        vm.prank(buyer);
        resolver.fileDispute(IResolver.DisputeContext({
            escrowId: 1,
            buyer: buyer,
            seller: seller,
            token: address(usdc),
            amount: 5 * ONE_USDC,
            serviceDescription: "First dispute",
            metadata: ""
        }));

        vm.prank(seller);
        vm.expectRevert(HumanDisputeResolver.EscrowAlreadyHasDispute.selector);
        resolver.fileDispute(IResolver.DisputeContext({
            escrowId: 1,
            buyer: buyer,
            seller: seller,
            token: address(usdc),
            amount: 5 * ONE_USDC,
            serviceDescription: "Second dispute",
            metadata: ""
        }));
    }

    // ============ Escrow guards party check ============

    function testOnlyPartyCanOpenDisputeViaEscrow() public {
        address rando = makeAddr("rando");
        vm.prank(rando);
        vm.expectRevert(AgentEscrow.NotAuthorized.selector);
        escrow.openDispute(1, "I'm not involved");
    }

    // ============ IResolver: submitEvidence ============

    function testSubmitEvidence() public {
        vm.prank(buyer);
        uint256 disputeId = resolver.fileDispute(IResolver.DisputeContext({
            escrowId: 1,
            buyer: buyer,
            seller: seller,
            token: address(usdc),
            amount: 5 * ONE_USDC,
            serviceDescription: "Quality issue",
            metadata: ""
        }));

        vm.prank(seller);
        resolver.submitEvidence(disputeId, "ipfs://QmEvidenceHash123");

        assertEq(resolver.getEvidenceCount(disputeId), 1);

        HumanDisputeResolver.Evidence[] memory evidence = resolver.getEvidence(disputeId);
        assertEq(evidence[0].submitter, seller);
        assertEq(evidence[0].content, "ipfs://QmEvidenceHash123");
    }

    function testEvidenceWindowClosed() public {
        vm.prank(buyer);
        uint256 disputeId = resolver.fileDispute(IResolver.DisputeContext({
            escrowId: 1,
            buyer: buyer,
            seller: seller,
            token: address(usdc),
            amount: 5 * ONE_USDC,
            serviceDescription: "Test",
            metadata: ""
        }));

        vm.warp(block.timestamp + EVIDENCE_WINDOW + 1);

        vm.prank(buyer);
        vm.expectRevert(HumanDisputeResolver.EvidenceWindowClosed.selector);
        resolver.submitEvidence(disputeId, "too late");
    }

    // ============ Human Resolver: resolveDispute ============

    function testResolveDisputeBuyerWins() public {
        vm.prank(buyer);
        uint256 disputeId = resolver.fileDispute(IResolver.DisputeContext({
            escrowId: 1,
            buyer: buyer,
            seller: seller,
            token: address(usdc),
            amount: 5 * ONE_USDC,
            serviceDescription: "No work delivered",
            metadata: ""
        }));

        vm.prank(arbitrator);
        resolver.resolveDispute(disputeId, IResolver.Verdict.BuyerWins, "No evidence of work");

        HumanDisputeResolver.Dispute memory d = resolver.getDispute(disputeId);
        assertEq(uint8(d.verdict), uint8(IResolver.Verdict.BuyerWins));
        assertEq(uint8(d.status), uint8(HumanDisputeResolver.DisputeStatus.Resolved));
        assertEq(d.resolvedBy, arbitrator);

        // Check isReady
        assertTrue(resolver.isReady(disputeId));
    }

    function testResolveDisputeSplit() public {
        vm.prank(buyer);
        uint256 disputeId = resolver.fileDispute(IResolver.DisputeContext({
            escrowId: 1,
            buyer: buyer,
            seller: seller,
            token: address(usdc),
            amount: 5 * ONE_USDC,
            serviceDescription: "Partial delivery",
            metadata: ""
        }));

        vm.prank(arbitrator);
        resolver.resolveDispute(disputeId, IResolver.Verdict.Split, "50% complete");

        HumanDisputeResolver.Dispute memory d = resolver.getDispute(disputeId);
        assertEq(uint8(d.verdict), uint8(IResolver.Verdict.Split));
    }

    function testOnlyArbitratorCanResolve() public {
        vm.prank(buyer);
        uint256 disputeId = resolver.fileDispute(IResolver.DisputeContext({
            escrowId: 1,
            buyer: buyer,
            seller: seller,
            token: address(usdc),
            amount: 5 * ONE_USDC,
            serviceDescription: "Test",
            metadata: ""
        }));

        vm.prank(buyer);
        vm.expectRevert(HumanDisputeResolver.NotArbitrator.selector);
        resolver.resolveDispute(disputeId, IResolver.Verdict.BuyerWins, "self-resolve");
    }

    function testCannotResolveTwice() public {
        vm.prank(buyer);
        uint256 disputeId = resolver.fileDispute(IResolver.DisputeContext({
            escrowId: 1,
            buyer: buyer,
            seller: seller,
            token: address(usdc),
            amount: 5 * ONE_USDC,
            serviceDescription: "Test",
            metadata: ""
        }));

        vm.prank(arbitrator);
        resolver.resolveDispute(disputeId, IResolver.Verdict.BuyerWins, "first");

        vm.prank(arbitrator);
        vm.expectRevert(HumanDisputeResolver.DisputeAlreadyResolved.selector);
        resolver.resolveDispute(disputeId, IResolver.Verdict.SellerWins, "second");
    }

    // ============ IResolver: getVerdict ============

    function testGetVerdictBuyerWins() public {
        vm.prank(buyer);
        uint256 disputeId = resolver.fileDispute(IResolver.DisputeContext({
            escrowId: 1,
            buyer: buyer,
            seller: seller,
            token: address(usdc),
            amount: 5 * ONE_USDC,
            serviceDescription: "No delivery",
            metadata: ""
        }));

        vm.prank(arbitrator);
        resolver.resolveDispute(disputeId, IResolver.Verdict.BuyerWins, "Clear refund");

        (IResolver.Verdict verdict, string memory reasoning, uint256 buyerPayout, uint256 sellerPayout) =
            resolver.getVerdict(disputeId);

        assertEq(uint8(verdict), uint8(IResolver.Verdict.BuyerWins));
        assertEq(reasoning, "Clear refund");
        assertEq(buyerPayout, 5 * ONE_USDC);
        assertEq(sellerPayout, 0);
    }

    function testGetVerdictSplit() public {
        vm.prank(buyer);
        uint256 disputeId = resolver.fileDispute(IResolver.DisputeContext({
            escrowId: 1,
            buyer: buyer,
            seller: seller,
            token: address(usdc),
            amount: 5 * ONE_USDC,
            serviceDescription: "Partial work",
            metadata: ""
        }));

        vm.prank(arbitrator);
        resolver.resolveDispute(disputeId, IResolver.Verdict.Split, "50/50");

        (, , uint256 buyerPayout, uint256 sellerPayout) = resolver.getVerdict(disputeId);

        assertEq(buyerPayout, 2.5e6); // 2.5 USDC
        assertEq(sellerPayout, 2.5e6);
    }

    // ============ IResolver: executeVerdict ============

    function testExecuteVerdictBuyerWins() public {
        vm.prank(buyer);
        uint256 disputeId = resolver.fileDispute(IResolver.DisputeContext({
            escrowId: 1,
            buyer: buyer,
            seller: seller,
            token: address(usdc),
            amount: 5 * ONE_USDC,
            serviceDescription: "No delivery",
            metadata: ""
        }));

        vm.prank(arbitrator);
        resolver.resolveDispute(disputeId, IResolver.Verdict.BuyerWins, "Refund");

        (uint256 buyerPayout, uint256 sellerPayout) = resolver.executeVerdict(disputeId);
        assertEq(buyerPayout, 5 * ONE_USDC);
        assertEq(sellerPayout, 0);
    }

    function testCannotExecutePending() public {
        vm.prank(buyer);
        uint256 disputeId = resolver.fileDispute(IResolver.DisputeContext({
            escrowId: 1,
            buyer: buyer,
            seller: seller,
            token: address(usdc),
            amount: 5 * ONE_USDC,
            serviceDescription: "Test",
            metadata: ""
        }));

        vm.expectRevert(HumanDisputeResolver.DisputeNotResolved.selector);
        resolver.executeVerdict(disputeId);
    }

    function testCannotExecuteTwice() public {
        vm.prank(buyer);
        uint256 disputeId = resolver.fileDispute(IResolver.DisputeContext({
            escrowId: 1,
            buyer: buyer,
            seller: seller,
            token: address(usdc),
            amount: 5 * ONE_USDC,
            serviceDescription: "Test",
            metadata: ""
        }));

        vm.prank(arbitrator);
        resolver.resolveDispute(disputeId, IResolver.Verdict.BuyerWins, "done");
        resolver.executeVerdict(disputeId);

        // Status is now Executed, so it hits DisputeNotResolved before DisputeAlreadyExecuted
        vm.expectRevert(HumanDisputeResolver.DisputeNotResolved.selector);
        resolver.executeVerdict(disputeId);
    }

    // ============ IResolver: cancelDispute ============

    function testCancelDispute() public {
        vm.prank(buyer);
        uint256 disputeId = resolver.fileDispute(IResolver.DisputeContext({
            escrowId: 1,
            buyer: buyer,
            seller: seller,
            token: address(usdc),
            amount: 5 * ONE_USDC,
            serviceDescription: "Changed my mind",
            metadata: ""
        }));

        vm.prank(buyer);
        resolver.cancelDispute(disputeId);

        HumanDisputeResolver.Dispute memory d = resolver.getDispute(disputeId);
        assertEq(uint8(d.status), uint8(HumanDisputeResolver.DisputeStatus.Cancelled));
    }

    // ============ End-to-End: Escrow + Resolver ============

    function testEndToEndBuyerWins() public {
        // 1. Open dispute via escrow
        vm.prank(buyer);
        uint256 disputeId = escrow.openDispute(1, "Agent didn't deliver");
        assertEq(disputeId, 1);

        // 2. Seller submits evidence
        vm.prank(seller);
        resolver.submitEvidence(disputeId, "ipfs://QmProofOfWork");

        // 3. Arbitrator resolves
        vm.prank(arbitrator);
        resolver.resolveDispute(disputeId, IResolver.Verdict.BuyerWins, "No delivery proof");

        // 4. Execute via escrow (escrow handles fund transfer)
        uint256 buyerBefore = usdc.balanceOf(buyer);
        vm.prank(buyer);
        escrow.resolveDispute(1);

        // Buyer gets refund
        assertEq(usdc.balanceOf(buyer), buyerBefore + 5 * ONE_USDC);
        assertEq(usdc.balanceOf(address(escrow)), 0);
    }

    function testEndToEndSplit() public {
        vm.prank(buyer);
        uint256 disputeId = escrow.openDispute(1, "Partial delivery");

        vm.prank(arbitrator);
        resolver.resolveDispute(disputeId, IResolver.Verdict.Split, "50% complete");

        uint256 buyerBefore = usdc.balanceOf(buyer);
        uint256 sellerBefore = usdc.balanceOf(seller);

        vm.prank(buyer);
        escrow.resolveDispute(1);

        assertEq(usdc.balanceOf(buyer), buyerBefore + 2.5e6);
        assertEq(usdc.balanceOf(seller), sellerBefore + 2.5e6);
    }

    function testCannotReleaseDisputedEscrow() public {
        // First validate, then dispute
        vm.prank(validator);
        escrow.validateWork(1);

        vm.prank(buyer);
        escrow.openDispute(1, "Dispute");

        // Now try to release — should fail because it's disputed
        vm.prank(buyer);
        vm.expectRevert(AgentEscrow.EscrowInDispute.selector);
        escrow.releaseFunds(1);
    }

    // ============ Admin ============

    function testUpdateEvidenceWindow() public {
        uint256 newWindow = 2 hours;
        vm.prank(owner);
        resolver.setEvidenceWindow(newWindow);
        assertEq(resolver.evidenceWindow(), newWindow);
    }

    function testAddRemoveArbitrator() public {
        address newArb = makeAddr("newArb");
        vm.prank(owner);
        resolver.addArbitrator(newArb);
        assertTrue(resolver.arbitrators(newArb));

        vm.prank(owner);
        resolver.removeArbitrator(newArb);
        assertFalse(resolver.arbitrators(newArb));
    }
}

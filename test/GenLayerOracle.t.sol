// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {AgentEscrow} from "../src/AgentEscrow.sol";
import {DisputeResolver} from "../src/DisputeResolver.sol";
import {GenLayerOracle} from "../src/GenLayerOracle.sol";
import {IAdjudicationOracle} from "../src/interfaces/IAdjudicationOracle.sol";

contract MockUSDC3 is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract GenLayerOracleTest is Test {
    MockUSDC3 usdc;
    AgentEscrow escrow;
    DisputeResolver resolver;
    GenLayerOracle oracle;

    address owner = makeAddr("owner");
    address buyer = makeAddr("buyer");
    address seller = makeAddr("seller");
    address validator = makeAddr("validator");
    address relayer = makeAddr("relayer");

    uint256 constant ONE_USDC = 1e6;
    uint256 constant EVIDENCE_WINDOW = 1 hours;
    uint256 constant DISPUTE_DEADLINE = 24 hours;

    function setUp() public {
        vm.startPrank(owner);

        usdc = new MockUSDC3();
        escrow = new AgentEscrow(address(validator), address(usdc));
        resolver = new DisputeResolver(
            address(escrow),
            address(usdc),
            EVIDENCE_WINDOW,
            DISPUTE_DEADLINE
        );

        // Deploy oracle with resolver as the caller
        oracle = new GenLayerOracle(address(resolver), address(0));

        // Wire oracle into resolver
        resolver.setOracleAdapter(address(oracle));

        // Authorize relayer to submit GenLayer verdicts
        oracle.authorizeSubmitter(relayer);

        // Fund buyer + create escrow
        usdc.mint(buyer, 10 * ONE_USDC);
        vm.stopPrank();

        vm.prank(buyer);
        usdc.approve(address(escrow), type(uint256).max);

        vm.prank(buyer);
        escrow.createEscrow(seller, 5 * ONE_USDC);
    }

    // ============ Oracle Request Flow ============

    function testRequestOracleAdjudication() public {
        vm.prank(buyer);
        uint256 disputeId = resolver.openDispute(1, "SLA not met");

        vm.prank(buyer);
        uint256 oracleRequestId = resolver.requestOracleAdjudication(disputeId);

        assertEq(oracleRequestId, 1);
        assertTrue(resolver.oracleRequested(disputeId));

        // Verify oracle stored the request
        IAdjudicationOracle.OracleRequest memory req = oracle.getRequest(oracleRequestId);
        assertEq(req.disputeId, disputeId);
        assertEq(req.buyer, buyer);
        assertEq(req.seller, seller);
        assertEq(req.amount, 5 * ONE_USDC);
        assertFalse(req.fulfilled);
    }

    function testRequestOracleWithEvidence() public {
        vm.prank(buyer);
        uint256 disputeId = resolver.openDispute(1, "Wrong output");

        // Submit evidence first
        vm.prank(buyer);
        resolver.submitEvidence(disputeId, "ipfs://QmProof1");
        vm.prank(seller);
        resolver.submitEvidence(disputeId, "ipfs://QmCounterProof");

        // Now request oracle — evidence should be forwarded
        vm.prank(seller);
        uint256 oracleRequestId = resolver.requestOracleAdjudication(disputeId);

        IAdjudicationOracle.OracleRequest memory req = oracle.getRequest(oracleRequestId);
        assertEq(req.evidence.length, 2);
        assertEq(req.evidence[0], "ipfs://QmProof1");
        assertEq(req.evidence[1], "ipfs://QmCounterProof");
    }

    function testSellerCanRequestOracle() public {
        vm.prank(buyer);
        uint256 disputeId = resolver.openDispute(1, "SLA not met");

        vm.prank(seller);
        uint256 oracleRequestId = resolver.requestOracleAdjudication(disputeId);
        assertGt(oracleRequestId, 0);
    }

    // ============ Verdict Submission ============

    function testSubmitVerdictBuyerWins() public {
        vm.prank(buyer);
        uint256 disputeId = resolver.openDispute(1, "No delivery");
        vm.prank(buyer);
        resolver.requestOracleAdjudication(disputeId);

        // Relayer submits GenLayer verdict
        vm.prank(relayer);
        oracle.submitVerdict(
            1,
            IAdjudicationOracle.Verdict.BuyerWins,
            "AI verified: no work product delivered within SLA window"
        );

        assertTrue(oracle.isFulfilled(1));

        (IAdjudicationOracle.Verdict verdict, string memory reasoning) = oracle.getVerdict(1);
        assertEq(uint8(verdict), uint8(IAdjudicationOracle.Verdict.BuyerWins));
        assertEq(reasoning, "AI verified: no work product delivered within SLA window");
    }

    function testResolveViaOracleBuyerWins() public {
        vm.prank(buyer);
        uint256 disputeId = resolver.openDispute(1, "No delivery");
        vm.prank(buyer);
        resolver.requestOracleAdjudication(disputeId);

        // Relayer submits verdict — auto-resolves in DisputeResolver
        vm.prank(relayer);
        oracle.submitVerdict(1, IAdjudicationOracle.Verdict.BuyerWins, "Buyer proven right");

        DisputeResolver.Dispute memory d = resolver.getDispute(disputeId);
        assertEq(uint8(d.resolution), uint8(DisputeResolver.Resolution.BuyerWins));
        assertEq(uint8(d.status), uint8(DisputeResolver.DisputeStatus.Resolved));
    }

    function testResolveViaOracleSplit() public {
        vm.prank(buyer);
        uint256 disputeId = resolver.openDispute(1, "Partial work");
        vm.prank(buyer);
        resolver.requestOracleAdjudication(disputeId);

        vm.prank(relayer);
        oracle.submitVerdict(1, IAdjudicationOracle.Verdict.Split, "50% of SLA met");

        DisputeResolver.Dispute memory d = resolver.getDispute(disputeId);
        assertEq(uint8(d.resolution), uint8(DisputeResolver.Resolution.Split));
    }

    function testOwnerCanSubmitVerdictFallback() public {
        vm.prank(buyer);
        uint256 disputeId = resolver.openDispute(1, "Dispute");
        vm.prank(buyer);
        resolver.requestOracleAdjudication(disputeId);

        // Owner acts as fallback relayer
        vm.prank(owner);
        oracle.submitVerdict(1, IAdjudicationOracle.Verdict.SellerWins, "Owner fallback");

        assertTrue(oracle.isFulfilled(1));
    }

    // ============ Edge Cases ============

    function testCannotRequestOracleTwice() public {
        vm.prank(buyer);
        uint256 disputeId = resolver.openDispute(1, "Test");
        vm.prank(buyer);
        resolver.requestOracleAdjudication(disputeId);

        vm.prank(seller);
        vm.expectRevert(DisputeResolver.OracleAlreadyRequested.selector);
        resolver.requestOracleAdjudication(disputeId);
    }

    function testCannotRequestOracleWithoutAdapter() public {
        // Deploy fresh resolver without oracle
        vm.startPrank(owner);
        DisputeResolver freshResolver = new DisputeResolver(
            address(escrow),
            address(usdc),
            EVIDENCE_WINDOW,
            DISPUTE_DEADLINE
        );
        vm.stopPrank();

        vm.prank(buyer);
        freshResolver.openDispute(1, "Test");

        vm.prank(buyer);
        vm.expectRevert(DisputeResolver.OracleNotSet.selector);
        freshResolver.requestOracleAdjudication(1);
    }

    function testCannotSubmitVerdictTwice() public {
        vm.prank(buyer);
        uint256 disputeId = resolver.openDispute(1, "Test");
        vm.prank(buyer);
        resolver.requestOracleAdjudication(disputeId);

        vm.prank(relayer);
        oracle.submitVerdict(1, IAdjudicationOracle.Verdict.BuyerWins, "First");

        vm.prank(relayer);
        vm.expectRevert(GenLayerOracle.RequestAlreadyFulfilled.selector);
        oracle.submitVerdict(1, IAdjudicationOracle.Verdict.SellerWins, "Second");
    }

    function testOnlyAuthorizedCanSubmitVerdict() public {
        vm.prank(buyer);
        uint256 disputeId = resolver.openDispute(1, "Test");
        vm.prank(buyer);
        resolver.requestOracleAdjudication(disputeId);

        address rando = makeAddr("rando");
        vm.prank(rando);
        vm.expectRevert(GenLayerOracle.NotAuthorized.selector);
        oracle.submitVerdict(1, IAdjudicationOracle.Verdict.BuyerWins, "Hacked");
    }

    function testOnlyResolverCanRequestOracle() public {
        address rando = makeAddr("rando");
        string[] memory emptyEvidence = new string[](0);

        vm.prank(rando);
        vm.expectRevert(GenLayerOracle.NotAuthorized.selector);
        oracle.requestAdjudication(1, address(escrow), 1, buyer, seller, 5 * ONE_USDC, "test", emptyEvidence);
    }

    function testCannotSubmitVerdictWithoutRequest() public {
        vm.prank(relayer);
        vm.expectRevert(GenLayerOracle.RequestNotFound.selector);
        oracle.submitVerdict(999, IAdjudicationOracle.Verdict.BuyerWins, "No request");
    }

    // ============ Human Arbiter Still Works ============

    function testHumanArbiterStillWorksAfterOracleEnabled() public {
        vm.prank(buyer);
        uint256 disputeId = resolver.openDispute(1, "Test");

        // Don't request oracle — just resolve human way
        vm.prank(owner); // owner is arbitrator
        resolver.resolveDispute(disputeId, DisputeResolver.Resolution.BuyerWins, "Human decided");

        DisputeResolver.Dispute memory d = resolver.getDispute(disputeId);
        assertEq(uint8(d.resolution), uint8(DisputeResolver.Resolution.BuyerWins));
        assertEq(uint8(d.status), uint8(DisputeResolver.DisputeStatus.Resolved));
    }

    // ============ Admin ============

    function testSetOracleAdapter() public {
        GenLayerOracle newOracle = new GenLayerOracle(address(resolver), address(0));

        vm.prank(owner);
        resolver.setOracleAdapter(address(newOracle));

        assertEq(address(resolver.oracleAdapter()), address(newOracle));
    }

    function testAuthorizeRevokeSubmitter() public {
        address newSubmitter = makeAddr("newSubmitter");

        vm.prank(owner);
        oracle.authorizeSubmitter(newSubmitter);
        assertTrue(oracle.authorizedSubmitters(newSubmitter));

        vm.prank(owner);
        oracle.revokeSubmitter(newSubmitter);
        assertFalse(oracle.authorizedSubmitters(newSubmitter));
    }

    function testOnlyOwnerCanSetOracleAdapter() public {
        vm.prank(buyer);
        vm.expectRevert();
        resolver.setOracleAdapter(address(oracle));
    }

    function testMappingLookup() public {
        vm.prank(buyer);
        uint256 disputeId = resolver.openDispute(1, "Test");
        vm.prank(buyer);
        resolver.requestOracleAdjudication(disputeId);

        assertEq(oracle.getRequestIdForDispute(disputeId), 1);
    }
}

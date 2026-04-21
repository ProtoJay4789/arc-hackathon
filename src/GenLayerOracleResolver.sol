// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";

import {IResolver} from "./interfaces/IResolver.sol";

/**
 * @title GenLayerOracleResolver
 * @notice Stub implementation of IResolver using GenLayer's AI oracle
 * @dev For hackathon demo — shows swap-ability with HumanDisputeResolver.
 *      In production, fileDispute() would post to GenLayer's Intelligent Contract,
 *      and getVerdict() would read from GenLayer's Optimistic Democracy consensus.
 *
 *      Current stub: owner acts as the "AI oracle" and sets verdicts manually.
 *      This proves the IResolver interface works — escrow doesn't care which
 *      resolver it uses.
 */
contract GenLayerOracleResolver is IResolver, Ownable {

    // ============ Types ============

    struct OracleDispute {
        IResolver.DisputeContext context;
        Verdict verdict;
        string reasoning;
        uint256 openedAt;
        uint256 resolvedAt;
        bool executed;
    }

    // ============ State ============

    uint256 private _nextDisputeId = 1;
    mapping(uint256 => OracleDispute) public oracleDisputes;
    mapping(uint256 => bytes[]) public disputeEvidence;

    // ============ Constructor ============

    constructor() Ownable(msg.sender) {}

    // ============ IResolver Implementation ============

    /// @inheritdoc IResolver
    function fileDispute(DisputeContext calldata ctx)
        external
        returns (uint256 disputeId)
    {
        // In production: post to GenLayer Intelligent Contract
        // For now: store locally, owner (simulating GenLayer) resolves

        disputeId = _nextDisputeId++;
        oracleDisputes[disputeId] = OracleDispute({
            context: ctx,
            verdict: Verdict.Pending,
            reasoning: "",
            openedAt: block.timestamp,
            resolvedAt: 0,
            executed: false
        });

        emit DisputeOpened(disputeId, ctx.escrowId, msg.sender);
    }

    /// @inheritdoc IResolver
    function submitEvidence(uint256 disputeId, bytes calldata evidence)
        external
    {
        OracleDispute storage d = oracleDisputes[disputeId];
        require(d.openedAt != 0, "Dispute not found");
        require(d.verdict == Verdict.Pending, "Already resolved");

        disputeEvidence[disputeId].push(evidence);
        emit EvidenceSubmitted(disputeId, msg.sender);
    }

    /// @inheritdoc IResolver
    function getVerdict(uint256 disputeId)
        external
        view
        returns (
            Verdict verdict,
            string memory reasoning,
            uint256 buyerPayout,
            uint256 sellerPayout
        )
    {
        OracleDispute storage d = oracleDisputes[disputeId];
        require(d.openedAt != 0, "Dispute not found");

        verdict = d.verdict;
        reasoning = d.reasoning;

        if (verdict == Verdict.BuyerWins) {
            buyerPayout = d.context.amount;
            sellerPayout = 0;
        } else if (verdict == Verdict.SellerWins) {
            buyerPayout = 0;
            sellerPayout = d.context.amount;
        } else if (verdict == Verdict.Split) {
            buyerPayout = d.context.amount / 2;
            sellerPayout = d.context.amount - buyerPayout;
        }
    }

    /// @inheritdoc IResolver
    function executeVerdict(uint256 disputeId)
        external
        returns (uint256 buyerPayout, uint256 sellerPayout)
    {
        OracleDispute storage d = oracleDisputes[disputeId];
        require(d.openedAt != 0, "Dispute not found");
        require(d.verdict != Verdict.Pending && d.verdict != Verdict.Escalated, "Not resolved");
        require(!d.executed, "Already executed");

        d.executed = true;

        if (d.verdict == Verdict.BuyerWins) {
            buyerPayout = d.context.amount;
        } else if (d.verdict == Verdict.SellerWins) {
            sellerPayout = d.context.amount;
        } else {
            buyerPayout = d.context.amount / 2;
            sellerPayout = d.context.amount - buyerPayout;
        }

        emit VerdictExecuted(disputeId, buyerPayout, sellerPayout);
    }

    /// @inheritdoc IResolver
    function isReady(uint256 disputeId) external view returns (bool ready) {
        OracleDispute storage d = oracleDisputes[disputeId];
        require(d.openedAt != 0, "Dispute not found");
        ready = d.verdict != Verdict.Pending && d.verdict != Verdict.Escalated && !d.executed;
    }

    /// @inheritdoc IResolver
    function cancelDispute(uint256 disputeId) external {
        OracleDispute storage d = oracleDisputes[disputeId];
        require(d.openedAt != 0, "Dispute not found");
        require(d.verdict == Verdict.Pending, "Already resolved");

        d.verdict = Verdict.Escalated; // Mark as cancelled (reuse enum)
        emit DisputeCancelled(disputeId);
    }

    // ============ Oracle Functions (Owner simulates GenLayer) ============

    /**
     * @notice Set verdict for a dispute (simulates GenLayer consensus)
     * @dev In production, this would be called by GenLayer's callback
     */
    function setVerdict(
        uint256 disputeId,
        Verdict verdict,
        string calldata reasoning
    ) external onlyOwner {
        require(verdict != Verdict.Pending && verdict != Verdict.Escalated, "Invalid verdict");
        OracleDispute storage d = oracleDisputes[disputeId];
        require(d.openedAt != 0, "Dispute not found");
        require(d.verdict == Verdict.Pending, "Already resolved");

        d.verdict = verdict;
        d.reasoning = reasoning;
        d.resolvedAt = block.timestamp;

        emit VerdictSet(disputeId, verdict);
    }

    /**
     * @notice Get evidence submitted for a dispute
     */
    function getEvidence(uint256 disputeId) external view returns (bytes[] memory) {
        return disputeEvidence[disputeId];
    }
}

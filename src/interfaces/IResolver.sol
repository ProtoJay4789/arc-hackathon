// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IResolver
 * @notice Standard interface for dispute resolution in agent escrow
 * @dev Implementations: HumanDisputeResolver, GenLayerOracleResolver
 *
 *      Design principles:
 *      - Resolver does NOT handle fund transfers — returns amounts, escrow executes
 *      - Escrow passes context in (DisputeContext), resolver doesn't import escrow
 *      - Metadata field is opaque bytes — each implementation encodes what it needs
 *      - isReady() handles async resolution (e.g., GenLayer consensus finality)
 */
interface IResolver {

    // ============ Types ============

    enum Verdict {
        Pending,        // Not yet decided
        BuyerWins,      // Full refund to buyer
        SellerWins,     // Full payout to seller
        Split,          // 50/50 default
        Escalated       // Routed to higher-tier resolver
    }

    struct DisputeContext {
        uint256 escrowId;
        address buyer;
        address seller;
        address token;
        uint256 amount;
        string serviceDescription;
        bytes metadata;
    }

    // ============ Events ============

    event DisputeOpened(uint256 indexed disputeId, uint256 indexed escrowId, address indexed initiator);
    event EvidenceSubmitted(uint256 indexed disputeId, address indexed submitter);
    event VerdictSet(uint256 indexed disputeId, Verdict verdict);
    event VerdictExecuted(uint256 indexed disputeId, uint256 buyerPayout, uint256 sellerPayout);
    event DisputeCancelled(uint256 indexed disputeId);

    // ============ Core ============

    /**
     * @notice File a dispute — resolver takes ownership of resolution
     * @param ctx The dispute context (who, what, how much)
     * @return disputeId Unique ID within this resolver
     */
    function fileDispute(DisputeContext calldata ctx)
        external
        returns (uint256 disputeId);

    /**
     * @notice Submit evidence for an open dispute
     * @param disputeId Resolver-internal dispute ID
     * @param evidence Encoded evidence (IPFS CID, URL, raw bytes)
     */
    function submitEvidence(uint256 disputeId, bytes calldata evidence)
        external;

    /**
     * @notice Get the current verdict for a dispute
     * @param disputeId Resolver-internal dispute ID
     * @return verdict Current verdict state
     * @return reasoning Human/AI-readable explanation
     * @return buyerPayout Amount to return to buyer
     * @return sellerPayout Amount to release to seller
     */
    function getVerdict(uint256 disputeId)
        external
        view
        returns (
            Verdict verdict,
            string memory reasoning,
            uint256 buyerPayout,
            uint256 sellerPayout
        );

    /**
     * @notice Finalize and execute — called by escrow after verdict is non-Pending
     * @param disputeId Resolver-internal dispute ID
     * @return buyerPayout Confirmed amount to buyer
     * @return sellerPayout Confirmed amount to seller
     */
    function executeVerdict(uint256 disputeId)
        external
        returns (uint256 buyerPayout, uint256 sellerPayout);

    // ============ Lifecycle ============

    /**
     * @notice Check if a dispute is ready for execution
     * @param disputeId Resolver-internal dispute ID
     * @return ready True if verdict is final and can be executed
     */
    function isReady(uint256 disputeId) external view returns (bool ready);

    /**
     * @notice Cancel a dispute (initiator or admin only, before verdict)
     * @param disputeId Resolver-internal dispute ID
     */
    function cancelDispute(uint256 disputeId) external;
}

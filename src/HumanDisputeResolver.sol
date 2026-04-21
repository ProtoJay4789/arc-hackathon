// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

import {IResolver} from "./interfaces/IResolver.sol";

/**
 * @title HumanDisputeResolver
 * @notice Human-arbitrated dispute resolver implementing IResolver
 * @dev Decoupled from AgentEscrow — takes DisputeContext, returns payout amounts.
 *      Escrow contract handles fund transfers based on executeVerdict() return values.
 *      This resolver manages: arbitrators, evidence windows, EIP-712 signatures.
 */
contract HumanDisputeResolver is IResolver, EIP712, ReentrancyGuard, Ownable {
    using ECDSA for bytes32;

    // ============ Events ============
    event ArbitratorAdded(address indexed arbitrator);
    event ArbitratorRemoved(address indexed arbitrator);
    event EvidenceWindowUpdated(uint256 oldWindow, uint256 newWindow);
    event DisputeResolved(
        uint256 indexed disputeId,
        address indexed arbitrator,
        Verdict verdict,
        string reasoning
    );

    // ============ Errors ============
    error DisputeNotFound();
    error DisputeAlreadyResolved();
    error DisputeNotResolved();
    error DisputeAlreadyExecuted();
    error NotArbitrator();
    error NotPartyToDispute();
    error EvidenceWindowClosed();
    error InvalidAddress();
    error InvalidVerdict();
    error EscrowAlreadyHasDispute();

    // ============ Types ============

    enum DisputeStatus {
        Open,
        Resolved,
        Executed,
        Cancelled
    }

    struct Dispute {
        uint256 id;
        uint256 escrowId;
        address initiator;
        address buyer;
        address seller;
        uint256 amount;
        string reason;
        Verdict verdict;
        DisputeStatus status;
        address resolvedBy;
        string reasoning;
        uint256 openedAt;
        uint256 resolvedAt;
        uint256 executedAt;
    }

    struct Evidence {
        address submitter;
        string content;
        uint256 timestamp;
    }

    // ============ State ============

    uint256 private _nextDisputeId = 1;
    mapping(uint256 => Dispute) public disputes;
    mapping(uint256 => Evidence[]) public disputeEvidence;
    mapping(address => bool) public arbitrators;
    mapping(uint256 => bool) public escrowHasDispute;

    uint256 public evidenceWindow;
    uint256 public disputeDeadline;

    // ============ Constructor ============

    constructor(
        uint256 _evidenceWindow,
        uint256 _disputeDeadline
    ) EIP712("HumanDisputeResolver", "1") Ownable(msg.sender) {
        evidenceWindow = _evidenceWindow;
        disputeDeadline = _disputeDeadline;

        // Deployer is initial arbitrator
        arbitrators[msg.sender] = true;
    }

    // ============ Modifiers ============

    modifier onlyArbitrator() {
        if (!arbitrators[msg.sender] && msg.sender != owner()) revert NotArbitrator();
        _;
    }

    modifier onlyParty(uint256 _disputeId) {
        Dispute storage d = disputes[_disputeId];
        if (d.id == 0) revert DisputeNotFound();
        if (msg.sender != d.buyer && msg.sender != d.seller && msg.sender != owner()) {
            revert NotPartyToDispute();
        }
        _;
    }

    // ============ IResolver Implementation ============

    /// @inheritdoc IResolver
    function fileDispute(DisputeContext calldata ctx)
        external
        nonReentrant
        returns (uint256 disputeId)
    {
        if (escrowHasDispute[ctx.escrowId]) revert EscrowAlreadyHasDispute();

        disputeId = _nextDisputeId++;
        escrowHasDispute[ctx.escrowId] = true;

        disputes[disputeId] = Dispute({
            id: disputeId,
            escrowId: ctx.escrowId,
            initiator: msg.sender,
            buyer: ctx.buyer,
            seller: ctx.seller,
            amount: ctx.amount,
            reason: ctx.serviceDescription,
            verdict: Verdict.Pending,
            status: DisputeStatus.Open,
            resolvedBy: address(0),
            reasoning: "",
            openedAt: block.timestamp,
            resolvedAt: 0,
            executedAt: 0
        });

        emit DisputeOpened(disputeId, ctx.escrowId, msg.sender);
    }

    /// @inheritdoc IResolver
    function submitEvidence(uint256 disputeId, bytes calldata evidence)
        external
        onlyParty(disputeId)
    {
        Dispute storage d = disputes[disputeId];
        if (d.status != DisputeStatus.Open) revert DisputeAlreadyResolved();
        if (block.timestamp > d.openedAt + evidenceWindow) revert EvidenceWindowClosed();

        disputeEvidence[disputeId].push(Evidence({
            submitter: msg.sender,
            content: string(evidence),
            timestamp: block.timestamp
        }));

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
        Dispute storage d = disputes[disputeId];
        if (d.id == 0) revert DisputeNotFound();

        verdict = d.verdict;
        reasoning = d.reasoning;

        if (verdict == Verdict.BuyerWins) {
            buyerPayout = d.amount;
            sellerPayout = 0;
        } else if (verdict == Verdict.SellerWins) {
            buyerPayout = 0;
            sellerPayout = d.amount;
        } else if (verdict == Verdict.Split) {
            buyerPayout = d.amount / 2;
            sellerPayout = d.amount - buyerPayout;
        }
        // Pending/Escalated: payouts = 0
    }

    /// @inheritdoc IResolver
    function executeVerdict(uint256 disputeId)
        external
        nonReentrant
        returns (uint256 buyerPayout, uint256 sellerPayout)
    {
        Dispute storage d = disputes[disputeId];
        if (d.id == 0) revert DisputeNotFound();
        if (d.status != DisputeStatus.Resolved) revert DisputeNotResolved();
        if (d.executedAt != 0) revert DisputeAlreadyExecuted();
        if (d.verdict == Verdict.Pending || d.verdict == Verdict.Escalated) revert InvalidVerdict();

        d.executedAt = block.timestamp;
        d.status = DisputeStatus.Executed;

        if (d.verdict == Verdict.BuyerWins) {
            buyerPayout = d.amount;
            sellerPayout = 0;
        } else if (d.verdict == Verdict.SellerWins) {
            buyerPayout = 0;
            sellerPayout = d.amount;
        } else {
            // Split
            buyerPayout = d.amount / 2;
            sellerPayout = d.amount - buyerPayout;
        }

        emit VerdictExecuted(disputeId, buyerPayout, sellerPayout);
    }

    /// @inheritdoc IResolver
    function isReady(uint256 disputeId) external view returns (bool ready) {
        Dispute storage d = disputes[disputeId];
        if (d.id == 0) revert DisputeNotFound();
        ready = d.status == DisputeStatus.Resolved
            && d.verdict != Verdict.Pending
            && d.verdict != Verdict.Escalated;
    }

    /// @inheritdoc IResolver
    function cancelDispute(uint256 disputeId) external {
        Dispute storage d = disputes[disputeId];
        if (d.id == 0) revert DisputeNotFound();
        if (d.status != DisputeStatus.Open) revert DisputeAlreadyResolved();
        if (msg.sender != d.initiator && msg.sender != owner()) revert NotPartyToDispute();

        d.status = DisputeStatus.Cancelled;
        escrowHasDispute[d.escrowId] = false;

        emit DisputeCancelled(disputeId);
    }

    // ============ Human Arbitrator Functions ============

    /**
     * @notice Resolve a dispute (arbitrator only)
     * @param _disputeId Dispute to resolve
     * @param _verdict Who wins: BuyerWins, SellerWins, or Split
     * @param _reasoning Arbitrator's reasoning
     */
    function resolveDispute(
        uint256 _disputeId,
        Verdict _verdict,
        string calldata _reasoning
    ) external onlyArbitrator {
        Dispute storage d = disputes[_disputeId];
        if (d.id == 0) revert DisputeNotFound();
        if (d.status != DisputeStatus.Open) revert DisputeAlreadyResolved();
        if (_verdict == Verdict.Pending || _verdict == Verdict.Escalated) revert InvalidVerdict();

        d.verdict = _verdict;
        d.status = DisputeStatus.Resolved;
        d.resolvedBy = msg.sender;
        d.reasoning = _reasoning;
        d.resolvedAt = block.timestamp;

        emit VerdictSet(_disputeId, _verdict);
        emit DisputeResolved(_disputeId, msg.sender, _verdict, _reasoning);
    }

    // ============ View ============

    function getDispute(uint256 _disputeId) external view returns (Dispute memory) {
        if (disputes[_disputeId].id == 0) revert DisputeNotFound();
        return disputes[_disputeId];
    }

    function getEvidence(uint256 _disputeId) external view returns (Evidence[] memory) {
        return disputeEvidence[_disputeId];
    }

    function getEvidenceCount(uint256 _disputeId) external view returns (uint256) {
        return disputeEvidence[_disputeId].length;
    }

    // ============ Admin ============

    function addArbitrator(address _arbitrator) external onlyOwner {
        if (_arbitrator == address(0)) revert InvalidAddress();
        arbitrators[_arbitrator] = true;
        emit ArbitratorAdded(_arbitrator);
    }

    function removeArbitrator(address _arbitrator) external onlyOwner {
        arbitrators[_arbitrator] = false;
        emit ArbitratorRemoved(_arbitrator);
    }

    function setEvidenceWindow(uint256 _window) external onlyOwner {
        uint256 old = evidenceWindow;
        evidenceWindow = _window;
        emit EvidenceWindowUpdated(old, _window);
    }

    function setDisputeDeadline(uint256 _deadline) external onlyOwner {
        disputeDeadline = _deadline;
    }
}

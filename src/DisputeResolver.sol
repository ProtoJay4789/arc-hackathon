// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

import {AgentEscrow} from "./AgentEscrow.sol";

/**
 * @title DisputeResolver
 * @notice Arbitration layer for contested AgentEscrow transactions
 * @dev Provides dispute lifecycle: open → evidence → resolve → execute.
 *      Supports configurable arbitrators (human, AI, or multi-sig).
 *      Designed for x402 agent commerce where trustless dispute resolution
 *      is critical for the agentic economy.
 */
contract DisputeResolver is EIP712, ReentrancyGuard, Ownable {
    using ECDSA for bytes32;

    // ============ Events ============
    event DisputeOpened(
        uint256 indexed disputeId,
        uint256 indexed escrowId,
        address indexed initiator,
        string reason
    );
    event EvidenceSubmitted(
        uint256 indexed disputeId,
        address indexed submitter,
        string evidence
    );
    event DisputeResolved(
        uint256 indexed disputeId,
        address indexed arbitrator,
        Resolution resolution,
        string reasoning
    );
    event DisputeExecuted(
        uint256 indexed disputeId,
        address buyerRefund,
        address sellerPayout
    );
    event DisputeCancelled(uint256 indexed disputeId);
    event ArbitratorAdded(address indexed arbitrator);
    event ArbitratorRemoved(address indexed arbitrator);
    event DisputeWindowUpdated(uint256 oldWindow, uint256 newWindow);

    // ============ Errors ============
    error DisputeNotFound();
    error DisputeAlreadyResolved();
    error DisputeNotResolved();
    error DisputeAlreadyExecuted();
    error NotAuthorized();
    error NotPartyToDispute();
    error NotArbitrator();
    error EscrowNotInDisputableState();
    error EvidenceWindowClosed();
    error DisputeWindowNotExpired();
    error TransferFailed();
    error InvalidAddress();
    error ZeroAmount();

    // ============ Types ============
    enum Resolution {
        Pending,       // Not yet resolved
        BuyerWins,     // Full refund to buyer
        SellerWins,    // Full payout to seller
        Split          // 50/50 split
    }

    enum DisputeStatus {
        Open,          // Evidence collection phase
        Resolved,      // Arbitrator has decided
        Executed,      // Funds distributed per resolution
        Cancelled      // Dispute withdrawn
    }

    struct Dispute {
        uint256 id;
        uint256 escrowId;
        address initiator;     // Who opened the dispute (buyer or seller)
        address buyer;
        address seller;
        uint256 amount;
        string reason;
        Resolution resolution;
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
    AgentEscrow public escrowContract;
    IERC20 public usdc;

    uint256 private _nextDisputeId = 1;
    mapping(uint256 => Dispute) public disputes;
    mapping(uint256 => Evidence[]) public disputeEvidence;
    mapping(address => bool) public arbitrators;
    mapping(uint256 => bool) public escrowHasDispute;

    uint256 public evidenceWindow; // seconds to submit evidence before resolution allowed
    uint256 public disputeDeadline; // seconds after opening before auto-resolve eligible

    // ============ Constructor ============
    constructor(
        address _escrowContract,
        address _usdc,
        uint256 _evidenceWindow,
        uint256 _disputeDeadline
    ) EIP712("DisputeResolver", "1") Ownable(msg.sender) {
        if (_escrowContract == address(0)) revert InvalidAddress();
        if (_usdc == address(0)) revert InvalidAddress();

        escrowContract = AgentEscrow(_escrowContract);
        usdc = IERC20(_usdc);
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

    // ============ Core Functions ============

    /**
     * @notice Open a dispute against an escrow
     * @dev Only buyer or seller of the escrow can open disputes.
     *      Escrow must be in Created or Validated state (not Released/Refunded).
     * @param _escrowId The escrow to dispute
     * @param _reason Human-readable reason for the dispute
     * @return disputeId The dispute ID
     */
    function openDispute(
        uint256 _escrowId,
        string calldata _reason
    ) external nonReentrant returns (uint256 disputeId) {
        // Check escrow exists and is in disputable state
        AgentEscrow.Escrow memory escrow = escrowContract.getEscrow(_escrowId);

        if (escrow.status == AgentEscrow.EscrowStatus.Released ||
            escrow.status == AgentEscrow.EscrowStatus.Refunded) {
            revert EscrowNotInDisputableState();
        }

        if (escrowHasDispute[_escrowId]) revert DisputeAlreadyResolved();

        // Only buyer or seller can open
        if (msg.sender != escrow.buyer && msg.sender != escrow.seller) {
            revert NotPartyToDispute();
        }

        disputeId = _nextDisputeId++;
        escrowHasDispute[_escrowId] = true;

        disputes[disputeId] = Dispute({
            id: disputeId,
            escrowId: _escrowId,
            initiator: msg.sender,
            buyer: escrow.buyer,
            seller: escrow.seller,
            amount: escrow.amount,
            reason: _reason,
            resolution: Resolution.Pending,
            status: DisputeStatus.Open,
            resolvedBy: address(0),
            reasoning: "",
            openedAt: block.timestamp,
            resolvedAt: 0,
            executedAt: 0
        });

        emit DisputeOpened(disputeId, _escrowId, msg.sender, _reason);
    }

    /**
     * @notice Submit evidence for a dispute
     * @param _disputeId Dispute to submit evidence for
     * @param _evidence Evidence string (IPFS hash, description, etc.)
     */
    function submitEvidence(
        uint256 _disputeId,
        string calldata _evidence
    ) external onlyParty(_disputeId) {
        Dispute storage d = disputes[_disputeId];
        if (d.status != DisputeStatus.Open) revert DisputeAlreadyResolved();
        if (block.timestamp > d.openedAt + evidenceWindow) revert EvidenceWindowClosed();

        disputeEvidence[_disputeId].push(Evidence({
            submitter: msg.sender,
            content: _evidence,
            timestamp: block.timestamp
        }));

        emit EvidenceSubmitted(_disputeId, msg.sender, _evidence);
    }

    /**
     * @notice Resolve a dispute (arbitrator only)
     * @param _disputeId Dispute to resolve
     * @param _resolution Who wins: BuyerWins, SellerWins, or Split
     * @param _reasoning Arbitrator's reasoning
     */
    function resolveDispute(
        uint256 _disputeId,
        Resolution _resolution,
        string calldata _reasoning
    ) external onlyArbitrator {
        Dispute storage d = disputes[_disputeId];
        if (d.id == 0) revert DisputeNotFound();
        if (d.status != DisputeStatus.Open) revert DisputeAlreadyResolved();
        if (_resolution == Resolution.Pending) revert InvalidAddress();

        d.resolution = _resolution;
        d.status = DisputeStatus.Resolved;
        d.resolvedBy = msg.sender;
        d.reasoning = _reasoning;
        d.resolvedAt = block.timestamp;

        emit DisputeResolved(_disputeId, msg.sender, _resolution, _reasoning);
    }

    /**
     * @notice Execute a resolved dispute — distribute funds per resolution
     * @param _disputeId Dispute to execute
     */
    function executeDispute(uint256 _disputeId) external nonReentrant {
        Dispute storage d = disputes[_disputeId];
        if (d.id == 0) revert DisputeNotFound();
        if (d.status != DisputeStatus.Resolved) revert DisputeNotResolved();
        if (d.executedAt != 0) revert DisputeAlreadyExecuted();

        d.executedAt = block.timestamp;
        d.status = DisputeStatus.Executed;

        uint256 amount = d.amount;
        uint256 buyerRefund;
        uint256 sellerPayout;

        if (d.resolution == Resolution.BuyerWins) {
            buyerRefund = amount;
            sellerPayout = 0;
        } else if (d.resolution == Resolution.SellerWins) {
            buyerRefund = 0;
            sellerPayout = amount;
        } else {
            // Split 50/50
            buyerRefund = amount / 2;
            sellerPayout = amount - buyerRefund;
        }

        // Transfer from escrow contract to this contract first
        // (Requires escrow contract to have refund/release hooks,
        //  or we pull funds directly if we have approval)
        if (buyerRefund > 0) {
            bool success = usdc.transfer(d.buyer, buyerRefund);
            if (!success) revert TransferFailed();
        }
        if (sellerPayout > 0) {
            bool success = usdc.transfer(d.seller, sellerPayout);
            if (!success) revert TransferFailed();
        }

        emit DisputeExecuted(_disputeId, d.buyer, d.seller);
    }

    /**
     * @notice Cancel a dispute (initiator only, before resolution)
     * @param _disputeId Dispute to cancel
     */
    function cancelDispute(uint256 _disputeId) external {
        Dispute storage d = disputes[_disputeId];
        if (d.id == 0) revert DisputeNotFound();
        if (d.status != DisputeStatus.Open) revert DisputeAlreadyResolved();
        if (msg.sender != d.initiator && msg.sender != owner()) revert NotAuthorized();

        d.status = DisputeStatus.Cancelled;
        escrowHasDispute[d.escrowId] = false;

        emit DisputeCancelled(_disputeId);
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
        emit DisputeWindowUpdated(old, _window);
    }

    function setDisputeDeadline(uint256 _deadline) external onlyOwner {
        disputeDeadline = _deadline;
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import {IAdjudicationOracle} from "./interfaces/IAdjudicationOracle.sol";
import {DisputeResolver} from "./DisputeResolver.sol";

/**
 * @title GenLayerOracle
 * @notice Adapter that bridges DisputeResolver to GenLayer's AI adjudication.
 * @dev For the hackathon MVP, this acts as a **trusted oracle** — the owner
 *      (or a backend relayer) submits GenLayer's verdict onchain after the
 *      GenLayer Intelligent Contract resolves the dispute offchain.
 *
 *      Post-hackathon upgrade path:
 *      1. Replace submitVerdict() with GenLayer callback via their onchain gateway
 *      2. Add Optimistic Democracy validator consensus checks
 *      3. Add slashing for dishonest oracle submissions
 *
 *      Flow:
 *      DisputeResolver.openDispute()
 *        → DisputeResolver.requestOracleAdjudication()
 *          → GenLayerOracle.requestAdjudication() [stores request, emits event]
 *        → [Offchain: relayer reads event, submits to GenLayer VM]
 *        → [Offchain: GenLayer AI evaluates evidence + SLA]
 *        → GenLayerOracle.submitVerdict() [relayer posts result onchain]
 *        → DisputeResolver.executeDispute() [funds distributed]
 */
contract GenLayerOracle is IAdjudicationOracle, ReentrancyGuard, Ownable {
    // ============ State ============
    address public override disputeResolver;
    address public genLayerGateway; // GenLayer onchain gateway (future use)

    uint256 private _nextRequestId = 1;
    mapping(uint256 => OracleRequest) public requests;
    mapping(uint256 => Verdict) public verdicts;
    mapping(uint256 => string) public verdictReasoning;

    // DisputeResolver -> request mapping for quick lookup
    mapping(uint256 => uint256) public disputeToRequest;

    // Oracle permissions — who can submit GenLayer verdicts
    // Initially: owner only (trusted relayer). Upgrade to GenLayer gateway later.
    mapping(address => bool) public authorizedSubmitters;

    // Minimum confirmations before verdict is accepted (anti-frontrun for GenLayer)
    uint256 public minConfidenceThreshold; // 0 = no threshold (MVP)

    // ============ Errors ============
    error RequestNotFound();
    error RequestAlreadyFulfilled();
    error NotAuthorized();
    error VerdictAlreadyDelivered();
    error InvalidDisputeResolver();
    error InvalidVerdict();

    // ============ Events ============
    event SubmitterAuthorized(address indexed submitter);
    event SubmitterRevoked(address indexed submitter);
    event GatewayUpdated(address indexed oldGateway, address indexed newGateway);

    // ============ Constructor ============
    constructor(
        address _disputeResolver,
        address _genLayerGateway
    ) Ownable(msg.sender) {
        if (_disputeResolver == address(0)) revert InvalidDisputeResolver();
        disputeResolver = _disputeResolver;
        genLayerGateway = _genLayerGateway;

        // Owner is initial authorized submitter (trusted relayer)
        authorizedSubmitters[msg.sender] = true;
    }

    // ============ Core Functions ============

    /**
     * @notice Request GenLayer adjudication for a dispute
     * @dev Called by DisputeResolver when a dispute opts into AI arbitration.
     *      Emits an event that offchain relayers pick up and submit to GenLayer VM.
     */
    function requestAdjudication(
        uint256 _disputeId,
        address _escrowContract,
        uint256 _escrowId,
        address _buyer,
        address _seller,
        uint256 _amount,
        string calldata _reason,
        string[] calldata _evidence
    ) external override nonReentrant returns (uint256 requestId) {
        // Only the registered DisputeResolver can request
        if (msg.sender != disputeResolver) revert NotAuthorized();

        if (disputeToRequest[_disputeId] != 0) revert VerdictAlreadyDelivered();

        requestId = _nextRequestId++;
        disputeToRequest[_disputeId] = requestId;

        requests[requestId] = OracleRequest({
            disputeId: _disputeId,
            escrowContract: _escrowContract,
            escrowId: _escrowId,
            buyer: _buyer,
            seller: _seller,
            amount: _amount,
            reason: _reason,
            evidence: _evidence,
            requestedAt: block.timestamp,
            fulfilled: false
        });

        emit AdjudicationRequested(requestId, _disputeId, msg.sender);
    }

    /**
     * @notice Submit GenLayer's verdict and resolve the dispute in one call
     * @dev Convenience function that submits verdict + calls DisputeResolver.resolveDisputeFromOracle
     *      Only callable by authorized relayer.
     * @param _requestId The oracle request ID
     * @param _verdict GenLayer's decision
     * @param _reasoning The AI's reasoning (from GenLayer LLM output)
     */
    function submitVerdict(
        uint256 _requestId,
        Verdict _verdict,
        string calldata _reasoning
    ) external nonReentrant {
        if (!authorizedSubmitters[msg.sender]) revert NotAuthorized();

        OracleRequest storage req = requests[_requestId];
        if (req.disputeId == 0) revert RequestNotFound();
        if (req.fulfilled) revert RequestAlreadyFulfilled();

        req.fulfilled = true;
        verdicts[_requestId] = _verdict;
        verdictReasoning[_requestId] = _reasoning;

        emit VerdictDelivered(_requestId, req.disputeId, _verdict, _reasoning);

        // Auto-resolve in DisputeResolver if it's set
        if (disputeResolver != address(0)) {
            DisputeResolver(disputeResolver).resolveDisputeFromOracle(
                req.disputeId,
                _verdict,
                _reasoning
            );
        }
    }

    // ============ View ============

    function isFulfilled(uint256 _requestId) external view override returns (bool) {
        return requests[_requestId].fulfilled;
    }

    function getVerdict(
        uint256 _requestId
    ) external view override returns (Verdict, string memory reasoning) {
        if (!requests[_requestId].fulfilled) revert RequestNotFound();
        return (verdicts[_requestId], verdictReasoning[_requestId]);
    }

    function getRequest(uint256 _requestId) external view returns (OracleRequest memory) {
        return requests[_requestId];
    }

    function getRequestIdForDispute(uint256 _disputeId) external view returns (uint256) {
        return disputeToRequest[_disputeId];
    }

    // ============ Admin ============

    function authorizeSubmitter(address _submitter) external onlyOwner {
        authorizedSubmitters[_submitter] = true;
        emit SubmitterAuthorized(_submitter);
    }

    function revokeSubmitter(address _submitter) external onlyOwner {
        authorizedSubmitters[_submitter] = false;
        emit SubmitterRevoked(_submitter);
    }

    function setDisputeResolver(address _resolver) external onlyOwner {
        if (_resolver == address(0)) revert InvalidDisputeResolver();
        address old = disputeResolver;
        disputeResolver = _resolver;
    }

    function setGenLayerGateway(address _gateway) external onlyOwner {
        address old = genLayerGateway;
        genLayerGateway = _gateway;
        emit GatewayUpdated(old, _gateway);
    }
}

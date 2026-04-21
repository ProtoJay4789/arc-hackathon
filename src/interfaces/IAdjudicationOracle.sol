// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IAdjudicationOracle
 * @notice Interface for external dispute adjudication oracles.
 * @dev Any oracle (GenLayer, Chainlink Functions, custom AI) can implement this.
 *      DisputeResolver calls requestAdjudication() and expects a callback to
 *      deliverVerdict() once the oracle resolves.
 */
interface IAdjudicationOracle {
    enum Verdict {
        BuyerWins,
        SellerWins,
        Split
    }

    struct OracleRequest {
        uint256 disputeId;
        address escrowContract;
        uint256 escrowId;
        address buyer;
        address seller;
        uint256 amount;
        string reason;
        string[] evidence;
        uint256 requestedAt;
        bool fulfilled;
    }

    /// @notice Emitted when a new adjudication is requested
    event AdjudicationRequested(
        uint256 indexed requestId,
        uint256 indexed disputeId,
        address indexed caller
    );

    /// @notice Emitted when the oracle delivers its verdict
    event VerdictDelivered(
        uint256 indexed requestId,
        uint256 indexed disputeId,
        Verdict verdict,
        string reasoning
    );

    /// @notice Request adjudication for a dispute
    /// @param _disputeId The dispute ID in DisputeResolver
    /// @param _escrowContract The escrow contract address
    /// @param _escrowId The escrow ID
    /// @param _buyer Buyer address
    /// @param _seller Seller address
    /// @param _amount Disputed amount
    /// @param _reason Dispute reason
    /// @param _evidence Array of evidence strings
    /// @return requestId The oracle request ID
    function requestAdjudication(
        uint256 _disputeId,
        address _escrowContract,
        uint256 _escrowId,
        address _buyer,
        address _seller,
        uint256 _amount,
        string calldata _reason,
        string[] calldata _evidence
    ) external returns (uint256 requestId);

    /// @notice Check if a request has been fulfilled
    function isFulfilled(uint256 _requestId) external view returns (bool);

    /// @notice Get the verdict for a fulfilled request
    function getVerdict(uint256 _requestId) external view returns (Verdict, string memory reasoning);

    /// @notice Get the DisputeResolver address that receives callbacks
    function disputeResolver() external view returns (address);
}

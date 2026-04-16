// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title AgentEscrow
 * @notice AI-validated escrow contract with x402 payment support
 * @dev Combines Circle Arc escrow patterns with x402 nanopayments
 */
contract AgentEscrow {
    // ============ Events ============
    event EscrowCreated(uint256 indexed escrowId, address indexed buyer, address indexed seller, uint256 amount);
    event EscrowValidated(uint256 indexed escrowId, address indexed validator);
    event EscrowReleased(uint256 indexed escrowId, address indexed seller);
    event EscrowRefunded(uint256 indexed escrowId, address indexed buyer);
    event PaymentProcessed(uint256 indexed escrowId, uint256 amount, bytes32 paymentHash);

    // ============ Errors ============
    error EscrowNotFound();
    error NotAuthorized();
    error EscrowAlreadyCompleted();
    error InsufficientBalance();
    error ValidationRequired();

    // ============ Types ============
    enum EscrowStatus {
        Created,
        Validated,
        Released,
        Refunded
    }

    struct Escrow {
        uint256 id;
        address buyer;
        address seller;
        uint256 amount;
        EscrowStatus status;
        bool validated;
        uint256 createdAt;
    }

    // ============ State ============
    uint256 private _nextEscrowId = 1;
    mapping(uint256 => Escrow) public escrows;
    mapping(address => uint256[]) public userEscrows;
    
    address public owner;
    address public aiValidator; // AI agent that validates work

    // ============ Modifiers ============
    modifier onlyOwner() {
        if (msg.sender != owner) revert NotAuthorized();
        _;
    }

    modifier onlyValidator() {
        if (msg.sender != aiValidator && msg.sender != owner) revert NotAuthorized();
        _;
    }

    // ============ Constructor ============
    constructor(address _aiValidator) {
        owner = msg.sender;
        aiValidator = _aiValidator;
    }

    // ============ Core Functions ============

    /**
     * @notice Create a new escrow for agent services
     * @param _seller Address of the service provider (agent)
     */
    function createEscrow(address _seller) external payable returns (uint256) {
        if (msg.value == 0) revert InsufficientBalance();
        
        uint256 escrowId = _nextEscrowId++;
        
        escrows[escrowId] = Escrow({
            id: escrowId,
            buyer: msg.sender,
            seller: _seller,
            amount: msg.value,
            status: EscrowStatus.Created,
            validated: false,
            createdAt: block.timestamp
        });
        
        userEscrows[msg.sender].push(escrowId);
        userEscrows[_seller].push(escrowId);
        
        emit EscrowCreated(escrowId, msg.sender, _seller, msg.value);
        
        return escrowId;
    }

    /**
     * @notice AI validator confirms work was completed satisfactorily
     * @param _escrowId ID of the escrow to validate
     */
    function validateWork(uint256 _escrowId) external onlyValidator {
        Escrow storage escrow = escrows[_escrowId];
        
        if (escrow.id == 0) revert EscrowNotFound();
        if (escrow.status != EscrowStatus.Created) revert EscrowAlreadyCompleted();
        
        escrow.validated = true;
        escrow.status = EscrowStatus.Validated;
        
        emit EscrowValidated(_escrowId, msg.sender);
    }

    /**
     * @notice Release funds to seller after validation
     * @param _escrowId ID of the escrow to release
     */
    function releaseFunds(uint256 _escrowId) external {
        Escrow storage escrow = escrows[_escrowId];
        
        if (escrow.id == 0) revert EscrowNotFound();
        if (escrow.status != EscrowStatus.Validated) revert ValidationRequired();
        if (msg.sender != escrow.buyer && msg.sender != owner) revert NotAuthorized();
        
        escrow.status = EscrowStatus.Released;
        
        // Transfer funds to seller
        (bool success, ) = escrow.seller.call{value: escrow.amount}("");
        require(success, "Transfer failed");
        
        emit EscrowReleased(_escrowId, escrow.seller);
    }

    /**
     * @notice Refund buyer if validation fails or times out
     * @param _escrowId ID of the escrow to refund
     */
    function refundBuyer(uint256 _escrowId) external onlyOwner {
        Escrow storage escrow = escrows[_escrowId];
        
        if (escrow.id == 0) revert EscrowNotFound();
        if (escrow.status == EscrowStatus.Released) revert EscrowAlreadyCompleted();
        
        escrow.status = EscrowStatus.Refunded;
        
        // Refund to buyer
        (bool success, ) = escrow.buyer.call{value: escrow.amount}("");
        require(success, "Refund failed");
        
        emit EscrowRefunded(_escrowId, escrow.buyer);
    }

    // ============ View Functions ============

    /**
     * @notice Get escrow details
     * @param _escrowId ID of the escrow
     */
    function getEscrow(uint256 _escrowId) external view returns (Escrow memory) {
        if (escrows[_escrowId].id == 0) revert EscrowNotFound();
        return escrows[_escrowId];
    }

    /**
     * @notice Get all escrows for a user
     * @param _user Address of the user
     */
    function getUserEscrows(address _user) external view returns (uint256[] memory) {
        return userEscrows[_user];
    }

    /**
     * @notice Get contract balance
     */
    function getBalance() external view returns (uint256) {
        return address(this).balance;
    }

    // ============ Admin Functions ============

    /**
     * @notice Update the AI validator address
     * @param _newValidator New validator address
     */
    function setValidator(address _newValidator) external onlyOwner {
        aiValidator = _newValidator;
    }

    /**
     * @notice Transfer ownership
     * @param _newOwner New owner address
     */
    function transferOwnership(address _newOwner) external onlyOwner {
        owner = _newOwner;
    }

    /**
     * @notice Withdraw stuck funds (emergency only)
     */
    function emergencyWithdraw() external onlyOwner {
        (bool success, ) = owner.call{value: address(this).balance}("");
        require(success, "Withdrawal failed");
    }
}

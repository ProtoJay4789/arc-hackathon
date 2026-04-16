// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/**
 * @title AgentEscrow
 * @notice AI-validated escrow contract with x402 payment support and USDC
 * @dev Combines Circle Arc escrow patterns with x402 nanopayments
 */
contract AgentEscrow is EIP712 {
    using ECDSA for bytes32;

    // ============ Events ============
    event EscrowCreated(uint256 indexed escrowId, address indexed buyer, address indexed seller, uint256 amount);
    event EscrowValidated(uint256 indexed escrowId, address indexed validator);
    event EscrowReleased(uint256 indexed escrowId, address indexed seller, uint256 amount);
    event EscrowRefunded(uint256 indexed escrowId, address indexed buyer, uint256 amount);
    event ValidatorUpdated(address indexed oldValidator, address indexed newValidator);
    event FundsDeposited(address indexed depositor, uint256 amount);
    event FundsWithdrawn(address indexed recipient, uint256 amount);

    // ============ Errors ============
    error EscrowNotFound();
    error NotAuthorized();
    error EscrowAlreadyCompleted();
    error InsufficientBalance();
    error ValidationRequired();
    error InvalidSignature();
    error EscrowAlreadyValidated();
    error ZeroAmount();
    error TransferFailed();

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
        uint256 validatedAt;
    }

    // ============ EIP712 Types ============
    bytes32 private constant VALIDATION_TYPEHASH = keccak256(
        "Validation(uint256 escrowId,address validator,uint256 timestamp)"
    );

    // ============ State ============
    uint256 private _nextEscrowId = 1;
    mapping(uint256 => Escrow) public escrows;
    mapping(address => uint256[]) public userEscrows;
    mapping(bytes32 => bool) public usedSignatures;
    
    address public owner;
    address public aiValidator;
    IERC20 public usdc;

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
    constructor(
        address _aiValidator,
        address _usdc
    ) EIP712("AgentEscrow", "1") {
        owner = msg.sender;
        aiValidator = _aiValidator;
        usdc = IERC20(_usdc);
    }

    // ============ Core Functions ============

    /**
     * @notice Create a new escrow for agent services using USDC
     * @param _seller Address of the service provider (agent)
     * @param _amount Amount of USDC to escrow
     * @return escrowId The ID of the created escrow
     */
    function createEscrow(address _seller, uint256 _amount) external returns (uint256) {
        if (_amount == 0) revert ZeroAmount();
        
        // Transfer USDC from buyer to contract
        usdc.transferFrom(msg.sender, address(this), _amount);
        
        uint256 escrowId = _nextEscrowId++;
        
        escrows[escrowId] = Escrow({
            id: escrowId,
            buyer: msg.sender,
            seller: _seller,
            amount: _amount,
            status: EscrowStatus.Created,
            validated: false,
            createdAt: block.timestamp,
            validatedAt: 0
        });
        
        userEscrows[msg.sender].push(escrowId);
        userEscrows[_seller].push(escrowId);
        
        emit EscrowCreated(escrowId, msg.sender, _seller, _amount);
        
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
        if (escrow.validated) revert EscrowAlreadyValidated();
        
        escrow.validated = true;
        escrow.status = EscrowStatus.Validated;
        escrow.validatedAt = block.timestamp;
        
        emit EscrowValidated(_escrowId, msg.sender);
    }

    /**
     * @notice Validate work using EIP712 signature (for off-chain validation)
     * @param _escrowId ID of the escrow to validate
     * @param _timestamp Timestamp of the signature
     * @param _signature EIP712 signature from validator
     */
    function validateWithSignature(
        uint256 _escrowId,
        uint256 _timestamp,
        bytes calldata _signature
    ) external {
        Escrow storage escrow = escrows[_escrowId];
        
        if (escrow.id == 0) revert EscrowNotFound();
        if (escrow.status != EscrowStatus.Created) revert EscrowAlreadyCompleted();
        if (escrow.validated) revert EscrowAlreadyValidated();
        
        // Reconstruct the digest
        bytes32 structHash = keccak256(
            abi.encode(
                VALIDATION_TYPEHASH,
                _escrowId,
                aiValidator,
                _timestamp
            )
        );
        bytes32 digest = _hashTypedDataV4(structHash);
        
        // Recover signer
        address signer = digest.recover(_signature);
        if (signer != aiValidator) revert InvalidSignature();
        
        // Prevent signature reuse
        bytes32 signatureHash = keccak256(_signature);
        if (usedSignatures[signatureHash]) revert InvalidSignature();
        usedSignatures[signatureHash] = true;
        
        // Validate the escrow
        escrow.validated = true;
        escrow.status = EscrowStatus.Validated;
        escrow.validatedAt = block.timestamp;
        
        emit EscrowValidated(_escrowId, aiValidator);
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
        
        // Transfer USDC to seller
        bool success = usdc.transfer(escrow.seller, escrow.amount);
        if (!success) revert TransferFailed();
        
        emit EscrowReleased(_escrowId, escrow.seller, escrow.amount);
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
        
        // Refund USDC to buyer
        bool success = usdc.transfer(escrow.buyer, escrow.amount);
        if (!success) revert TransferFailed();
        
        emit EscrowRefunded(_escrowId, escrow.buyer, escrow.amount);
    }

    // ============ View Functions ============

    /**
     * @notice Get escrow details
     * @param _escrowId ID of the escrow
     * @return The escrow struct
     */
    function getEscrow(uint256 _escrowId) external view returns (Escrow memory) {
        if (escrows[_escrowId].id == 0) revert EscrowNotFound();
        return escrows[_escrowId];
    }

    /**
     * @notice Get all escrows for a user
     * @param _user Address of the user
     * @return Array of escrow IDs
     */
    function getUserEscrows(address _user) external view returns (uint256[] memory) {
        return userEscrows[_user];
    }

    /**
     * @notice Get contract's USDC balance
     * @return USDC balance
     */
    function getBalance() external view returns (uint256) {
        return usdc.balanceOf(address(this));
    }

    /**
     * @notice Hash validation info for EIP712 signature verification
     * @param _escrowId ID of the escrow
     * @param _timestamp Timestamp of validation
     * @return The hash to sign
     */
    function hashValidation(
        uint256 _escrowId,
        uint256 _timestamp
    ) external view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                VALIDATION_TYPEHASH,
                _escrowId,
                aiValidator,
                _timestamp
            )
        );
        return _hashTypedDataV4(structHash);
    }

    // ============ Admin Functions ============

    /**
     * @notice Update the AI validator address
     * @param _newValidator New validator address
     */
    function setValidator(address _newValidator) external onlyOwner {
        if (_newValidator == address(0)) revert InvalidSignature();
        address oldValidator = aiValidator;
        aiValidator = _newValidator;
        emit ValidatorUpdated(oldValidator, _newValidator);
    }

    /**
     * @notice Deposit additional USDC to the contract
     * @param _amount Amount to deposit
     */
    function depositFunds(uint256 _amount) external onlyOwner {
        usdc.transferFrom(msg.sender, address(this), _amount);
        emit FundsDeposited(msg.sender, _amount);
    }

    /**
     * @notice Withdraw USDC from the contract (emergency only)
     * @param _amount Amount to withdraw
     */
    function withdrawFunds(uint256 _amount) external onlyOwner {
        bool success = usdc.transfer(owner, _amount);
        if (!success) revert TransferFailed();
        emit FundsWithdrawn(owner, _amount);
    }

    /**
     * @notice Transfer ownership
     * @param _newOwner New owner address
     */
    function transferOwnership(address _newOwner) external onlyOwner {
        if (_newOwner == address(0)) revert InvalidSignature();
        owner = _newOwner;
    }
}

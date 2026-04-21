// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

import {AgentEscrow} from "./AgentEscrow.sol";

/**
 * @title X402PaymentHandler
 * @notice x402 protocol payment settlement for agent-to-agent commerce on Arc
 * @dev Handles HTTP 402 "Payment Required" nanopayment flow with USDC settlement.
 *      Supports two modes:
 *      1. Direct payment — instant settlement (x402 pay-per-query)
 *      2. Escrow payment — create escrow from x402 payment (trust layer)
 *
 *      Uses EIP-3009 transferWithAuthorization for gasless USDC transfers,
 *      which is Circle's native settlement mechanism on Arc.
 */
contract X402PaymentHandler is EIP712, ReentrancyGuard, Ownable {
    using ECDSA for bytes32;

    // ============ Events ============
    event PaymentSettled(
        bytes32 indexed paymentId,
        address indexed payer,
        address indexed recipient,
        uint256 amount
    );
    event EscrowCreatedFromPayment(
        bytes32 indexed paymentId,
        uint256 indexed escrowId,
        address indexed payer,
        address recipient,
        uint256 amount
    );
    event PaymentRefunded(
        bytes32 indexed paymentId,
        address indexed payer,
        uint256 amount
    );
    event FacilitatorUpdated(address indexed oldFacilitator, address indexed newFacilitator);
    event EscrowContractUpdated(address indexed oldEscrow, address indexed newEscrow);
    event ServiceRegistered(bytes32 indexed serviceId, address indexed provider, uint256 price);
    event ServiceDeactivated(bytes32 indexed serviceId);
    event FeeUpdated(uint256 oldFee, uint256 newFee);

    // ============ Errors ============
    error InvalidPayment();
    error PaymentAlreadySettled();
    error InsufficientPayment();
    error TransferFailed();
    error NotAuthorized();
    error ServiceNotFound();
    error ServiceInactive();
    error InvalidSignature();
    error ExcessiveFee();
    error ZeroAmount();
    error EscrowNotSet();
    error RecipientMismatch();

    // ============ Types ============
    enum PaymentStatus {
        Pending,
        Settled,
        Refunded,
        Escrowed
    }

    struct Payment {
        bytes32 id;
        address payer;
        address recipient;
        uint256 amount;
        bytes32 serviceId;
        PaymentStatus status;
        uint256 settledAt;
    }

    struct Service {
        bytes32 id;
        address provider;
        uint256 price; // USDC (6 decimals)
        bool active;
        string metadata; // service description, endpoint, etc.
    }

    // EIP-3009 Authorization typehash for USDC transferWithAuthorization
    bytes32 private constant AUTHORIZATION_TYPEHASH = keccak256(
        "TransferWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    );

    // ============ State ============
    IERC20 public usdc;
    address public facilitator;
    AgentEscrow public escrowContract;

    uint256 public platformFeeBps; // basis points (100 = 1%)
    uint256 private constant MAX_FEE_BPS = 1000; // 10% max

    mapping(bytes32 => Payment) public payments;
    mapping(bytes32 => Service) public services;
    mapping(bytes32 => bool) public usedNonces; // EIP-3009 nonce tracking

    // ============ Constructor ============
    constructor(
        address _usdc,
        address _facilitator,
        address _escrowContract,
        uint256 _platformFeeBps
    ) EIP712("X402PaymentHandler", "1") Ownable(msg.sender) {
        if (_usdc == address(0)) revert InvalidPayment();
        if (_facilitator == address(0)) revert InvalidPayment();
        if (_platformFeeBps > MAX_FEE_BPS) revert ExcessiveFee();

        usdc = IERC20(_usdc);
        facilitator = _facilitator;
        escrowContract = AgentEscrow(_escrowContract);
        platformFeeBps = _platformFeeBps;
    }

    // ============ Core: x402 Payment Settlement ============

    /**
     * @notice Settle an x402 payment using EIP-3009 transferWithAuthorization
     * @dev Called by the facilitator after verifying the X-PAYMENT header
     * @param from Payer address (from X-PAYMENT payload)
     * @param to Recipient/service provider
     * @param amount USDC amount (6 decimals)
     * @param validAfter Authorization valid after this timestamp
     * @param validBefore Authorization valid before this timestamp
     * @param nonce Unique nonce for replay protection
     * @param signature EIP-712 signature from payer authorizing the transfer
     * @return paymentId Unique identifier for this payment
     */
    function settlePayment(
        address from,
        address to,
        uint256 amount,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes calldata signature
    ) external nonReentrant returns (bytes32) {
        _verifyAndSettle(from, to, amount, validAfter, validBefore, nonce, signature);

        // Record payment
        bytes32 id = keccak256(abi.encodePacked(from, to, amount, nonce));
        payments[id] = Payment({
            id: id,
            payer: from,
            recipient: to,
            amount: amount,
            serviceId: bytes32(0),
            status: PaymentStatus.Settled,
            settledAt: block.timestamp
        });

        emit PaymentSettled(id, from, to, amount);
        return id;
    }

    /**
     * @dev Internal: verify EIP-3009 auth + transfer USDC (reduces stack depth)
     */
    function _verifyAndSettle(
        address from,
        address to,
        uint256 amount,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes calldata signature
    ) internal {
        if (to == address(0)) revert InvalidPayment();
        if (amount == 0) revert ZeroAmount();
        if (block.timestamp < validAfter || block.timestamp > validBefore) revert InvalidPayment();
        if (usedNonces[nonce]) revert PaymentAlreadySettled();

        // Verify EIP-3009 authorization signature
        _verifyAuthorization(from, to, amount, validAfter, validBefore, nonce, signature);
        usedNonces[nonce] = true;

        // Calculate fees and transfer
        uint256 fee = (amount * platformFeeBps) / 10_000;
        uint256 netAmount = amount - fee;

        bool success = usdc.transferFrom(from, to, netAmount);
        if (!success) revert TransferFailed();

        if (fee > 0) {
            success = usdc.transferFrom(from, owner(), fee);
            if (!success) revert TransferFailed();
        }
    }

    /**
     * @dev Internal: verify EIP-3009 authorization signature
     */
    function _verifyAuthorization(
        address from,
        address to,
        uint256 amount,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes calldata signature
    ) internal view {
        bytes32 structHash = keccak256(
            abi.encode(AUTHORIZATION_TYPEHASH, from, to, amount, validAfter, validBefore, nonce)
        );
        bytes32 digest = _hashTypedDataV4(structHash);
        address signer = digest.recover(signature);
        if (signer != from) revert InvalidSignature();
    }

    // ============ Core: x402 → Escrow Flow ============

    /**
     * @notice Create an escrow directly from an x402 payment
     * @dev One atomic transaction: verify payment + create escrow
     * @param seller Service provider address
     * @param amount USDC amount to escrow
     * @param validAfter EIP-3009 authorization start
     * @param validBefore EIP-3009 authorization end
     * @param nonce Unique nonce
     * @param signature Payer's EIP-3009 authorization signature
     * @return paymentId Payment record ID
     * @return escrowId Escrow record ID
     */
    function payAndEscrow(
        address seller,
        uint256 amount,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes calldata signature
    ) external nonReentrant returns (bytes32, uint256) {
        if (address(escrowContract) == address(0)) revert EscrowNotSet();
        if (seller == address(0)) revert InvalidPayment();
        if (amount == 0) revert ZeroAmount();
        if (block.timestamp < validAfter || block.timestamp > validBefore) revert InvalidPayment();
        if (usedNonces[nonce]) revert PaymentAlreadySettled();

        // Verify EIP-3009 authorization
        _verifyAuthorization(msg.sender, address(this), amount, validAfter, validBefore, nonce, signature);
        usedNonces[nonce] = true;

        // Pull USDC from payer
        bool success = usdc.transferFrom(msg.sender, address(this), amount);
        if (!success) revert TransferFailed();

        // Approve escrow contract to spend
        success = usdc.approve(address(escrowContract), amount);
        if (!success) revert TransferFailed();

        // Create escrow
        uint256 eId = escrowContract.createEscrow(seller, amount);

        // Record payment
        bytes32 pId = keccak256(abi.encodePacked(msg.sender, address(this), amount, nonce));
        payments[pId] = Payment({
            id: pId,
            payer: msg.sender,
            recipient: seller,
            amount: amount,
            serviceId: bytes32(0),
            status: PaymentStatus.Escrowed,
            settledAt: block.timestamp
        });

        emit EscrowCreatedFromPayment(pId, eId, msg.sender, seller, amount);
        return (pId, eId);
    }

    // ============ Service Registry ============

    /**
     * @notice Register a service for x402 discovery
     * @param serviceId Unique service identifier
     * @param price USDC price per query (6 decimals)
     * @param metadata Service description / endpoint URL
     */
    function registerService(
        bytes32 serviceId,
        uint256 price,
        string calldata metadata
    ) external {
        services[serviceId] = Service({
            id: serviceId,
            provider: msg.sender,
            price: price,
            active: true,
            metadata: metadata
        });
        emit ServiceRegistered(serviceId, msg.sender, price);
    }

    /**
     * @notice Deactivate a service
     * @param serviceId Service to deactivate
     */
    function deactivateService(bytes32 serviceId) external {
        Service storage service = services[serviceId];
        if (service.provider != msg.sender && msg.sender != owner()) revert NotAuthorized();
        service.active = false;
        emit ServiceDeactivated(serviceId);
    }

    /**
     * @notice Get service details (for x402 402 response generation)
     * @param serviceId Service to query
     * @return provider Service provider address
     * @return price USDC price
     * @return active Whether service is active
     * @return metadata Service description
     */
    function getService(
        bytes32 serviceId
    ) external view returns (address provider, uint256 price, bool active, string memory metadata) {
        Service storage service = services[serviceId];
        if (!service.active) revert ServiceInactive();
        return (service.provider, service.price, service.active, service.metadata);
    }

    // ============ Admin ============

    function setFacilitator(address _facilitator) external onlyOwner {
        if (_facilitator == address(0)) revert InvalidPayment();
        address old = facilitator;
        facilitator = _facilitator;
        emit FacilitatorUpdated(old, _facilitator);
    }

    function setEscrowContract(address _escrowContract) external onlyOwner {
        if (_escrowContract == address(0)) revert InvalidPayment();
        address old = address(escrowContract);
        escrowContract = AgentEscrow(_escrowContract);
        emit EscrowContractUpdated(old, _escrowContract);
    }

    function setPlatformFee(uint256 _feeBps) external onlyOwner {
        if (_feeBps > MAX_FEE_BPS) revert ExcessiveFee();
        uint256 old = platformFeeBps;
        platformFeeBps = _feeBps;
        emit FeeUpdated(old, _feeBps);
    }

    // ============ View ============

    function getPayment(bytes32 paymentId) external view returns (Payment memory) {
        return payments[paymentId];
    }

    function isNonceUsed(bytes32 nonce) external view returns (bool) {
        return usedNonces[nonce];
    }
}

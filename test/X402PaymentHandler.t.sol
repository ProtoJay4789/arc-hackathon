// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {AgentEscrow} from "../src/AgentEscrow.sol";
import {X402PaymentHandler} from "../src/X402PaymentHandler.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

/**
 * @title MockUSDC
 * @notice Minimal ERC20 for testing -- matches USDC's 6 decimals
 */
contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/**
 * @title HandlerHarness
 * @notice Exposes internal EIP712 functions for test signing
 */
contract HandlerHarness is X402PaymentHandler {
    constructor(
        address _usdc,
        address _facilitator,
        address _escrowContract,
        uint256 _platformFeeBps
    ) X402PaymentHandler(_usdc, _facilitator, _escrowContract, _platformFeeBps) {}

    function getDomainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    function hashTypedData(bytes32 structHash) external view returns (bytes32) {
        return _hashTypedDataV4(structHash);
    }
}

contract X402PaymentHandlerTest is Test {
    MockUSDC usdc;
    AgentEscrow escrow;
    HandlerHarness handler;

    address owner = makeAddr("owner");
    address seller = makeAddr("seller");
    address validator = makeAddr("validator");
    address facilitator = makeAddr("facilitator");

    address buyer;
    uint256 buyerKey;

    uint256 constant ONE_USDC = 1e6;
    uint256 constant PLATFORM_FEE_BPS = 250; // 2.5%

    // EIP-3009 TransferWithAuthorization typehash
    bytes32 constant AUTH_TYPEHASH = keccak256(
        "TransferWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    );

    function setUp() public {
        // Generate buyer key
        (buyer, buyerKey) = makeAddrAndKey("buyer");

        vm.startPrank(owner);

        usdc = new MockUSDC();
        escrow = new AgentEscrow(address(validator), address(usdc), address(0));
        handler = new HandlerHarness(
            address(usdc),
            address(facilitator),
            address(escrow),
            PLATFORM_FEE_BPS
        );

        // Fund buyer and approve
        usdc.mint(buyer, 100 * ONE_USDC);
        vm.stopPrank();

        vm.prank(buyer);
        usdc.approve(address(handler), type(uint256).max);
    }

    /**
     * Helper: Build a valid EIP-3009 authorization signature from the buyer
     */
    function _signAuthorization(
        address to,
        uint256 amount,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce
    ) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(AUTH_TYPEHASH, buyer, to, amount, validAfter, validBefore, nonce)
        );
        bytes32 digest = handler.hashTypedData(structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(buyerKey, digest);
        return abi.encodePacked(r, s, v);
    }

    // ============ Direct Payment Tests ============

    function testFuzz_SettlePayment(uint256 amount) public {
        // Bound amount to reasonable range
        amount = bound(amount, 1, 50 * ONE_USDC);

        uint256 validAfter = block.timestamp;
        uint256 validBefore = block.timestamp + 1 hours;
        bytes32 nonce = keccak256(abi.encode("nonce", amount));

        bytes memory signature = _signAuthorization(seller, amount, validAfter, validBefore, nonce);

        uint256 buyerBefore = usdc.balanceOf(buyer);
        uint256 sellerBefore = usdc.balanceOf(seller);

        vm.prank(facilitator);
        bytes32 paymentId = handler.settlePayment(
            buyer, seller, amount, validAfter, validBefore, nonce, signature
        );

        // Verify payment recorded
        X402PaymentHandler.Payment memory payment = handler.getPayment(paymentId);
        assertEq(payment.payer, buyer);
        assertEq(payment.recipient, seller);
        assertEq(payment.amount, amount);
        assertEq(uint8(payment.status), uint8(X402PaymentHandler.PaymentStatus.Settled));

        // Verify USDC moved (net of fee)
        uint256 fee = (amount * PLATFORM_FEE_BPS) / 10_000;
        uint256 netAmount = amount - fee;
        assertEq(usdc.balanceOf(seller), sellerBefore + netAmount);
        assertEq(usdc.balanceOf(buyer), buyerBefore - amount);
    }

    function testCannotSettleTwice() public {
        uint256 amount = 1 * ONE_USDC;
        uint256 validAfter = block.timestamp;
        uint256 validBefore = block.timestamp + 1 hours;
        bytes32 nonce = keccak256("duplicate-nonce");

        bytes memory sig = _signAuthorization(seller, amount, validAfter, validBefore, nonce);

        vm.prank(facilitator);
        handler.settlePayment(buyer, seller, amount, validAfter, validBefore, nonce, sig);

        vm.prank(facilitator);
        vm.expectRevert(X402PaymentHandler.PaymentAlreadySettled.selector);
        handler.settlePayment(buyer, seller, amount, validAfter, validBefore, nonce, sig);
    }

    function testCannotSettleExpiredAuthorization() public {
        vm.warp(1 days); // avoid underflow with default timestamp
        uint256 amount = 1 * ONE_USDC;
        uint256 validAfter = block.timestamp - 2 hours;
        uint256 validBefore = block.timestamp - 1 hours; // expired
        bytes32 nonce = keccak256("expired-nonce");

        bytes memory sig = _signAuthorization(seller, amount, validAfter, validBefore, nonce);

        vm.prank(facilitator);
        vm.expectRevert(X402PaymentHandler.InvalidPayment.selector);
        handler.settlePayment(buyer, seller, amount, validAfter, validBefore, nonce, sig);
    }

    function testInvalidSignatureRejected() public {
        uint256 amount = 1 * ONE_USDC;
        uint256 validAfter = block.timestamp;
        uint256 validBefore = block.timestamp + 1 hours;
        bytes32 nonce = keccak256("bad-sig-nonce");

        // Sign with wrong key
        (, uint256 wrongKey) = makeAddrAndKey("wrong");
        bytes32 structHash = keccak256(
            abi.encode(AUTH_TYPEHASH, buyer, seller, amount, validAfter, validBefore, nonce)
        );
        bytes32 digest = handler.hashTypedData(structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wrongKey, digest);
        bytes memory badSig = abi.encodePacked(r, s, v);

        vm.prank(facilitator);
        vm.expectRevert(X402PaymentHandler.InvalidSignature.selector);
        handler.settlePayment(buyer, seller, amount, validAfter, validBefore, nonce, badSig);
    }

    // ============ Service Registry Tests ============

    function testRegisterAndQueryService() public {
        bytes32 serviceId = keccak256("data-api");
        uint256 price = 5000; // $0.005 USDC

        handler.registerService(serviceId, price, "https://api.example.com/data");

        (address provider, uint256 servicePrice, bool active, string memory meta) = handler.getService(serviceId);
        assertEq(provider, address(this));
        assertEq(servicePrice, price);
        assertTrue(active);
        assertEq(meta, "https://api.example.com/data");
    }

    function testDeactivateService() public {
        bytes32 serviceId = keccak256("temp-service");
        handler.registerService(serviceId, 1000, "temporary");

        handler.deactivateService(serviceId);

        vm.expectRevert(X402PaymentHandler.ServiceInactive.selector);
        handler.getService(serviceId);
    }

    // ============ Admin Tests ============

    function testOnlyOwnerCanSetFee() public {
        vm.prank(seller);
        vm.expectRevert();
        handler.setPlatformFee(500);
    }

    function testCannotSetExcessiveFee() public {
        vm.prank(owner);
        vm.expectRevert(X402PaymentHandler.ExcessiveFee.selector);
        handler.setPlatformFee(1001); // >10%
    }

    function testSetFacilitator() public {
        address newFac = makeAddr("new-facilitator");
        vm.prank(owner);
        handler.setFacilitator(newFac);
        assertEq(handler.facilitator(), newFac);
    }

    function testSetEscrowContract() public {
        address newEscrow = makeAddr("new-escrow");
        vm.prank(owner);
        handler.setEscrowContract(newEscrow);
        assertEq(address(handler.escrowContract()), newEscrow);
    }
}

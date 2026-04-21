// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {AgentEscrow} from "../src/AgentEscrow.sol";
import {HumanDisputeResolver} from "../src/HumanDisputeResolver.sol";
import {GenLayerOracleResolver} from "../src/GenLayerOracleResolver.sol";
import {IResolver} from "../src/interfaces/IResolver.sol";

contract MockUSDC3 is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

/**
 * @notice Tests for GenLayerOracleResolver (IResolver-based GenLayer stub)
 * @dev Proves both HumanDisputeResolver and GenLayerOracleResolver implement
 *      the same IResolver interface — escrow doesn't care which one it uses.
 */
contract GenLayerResolverTest is Test {
    MockUSDC3 usdc;
    AgentEscrow escrowHuman;
    AgentEscrow escrowOracle;
    HumanDisputeResolver humanResolver;
    GenLayerOracleResolver oracleResolver;

    address owner = makeAddr("owner");
    address buyer = makeAddr("buyer");
    address seller = makeAddr("seller");
    address validator = makeAddr("validator");

    uint256 constant ONE_USDC = 1e6;

    function setUp() public {
        vm.startPrank(owner);

        // Deploy both resolver types
        humanResolver = new HumanDisputeResolver(1 hours, 24 hours);
        oracleResolver = new GenLayerOracleResolver();

        // Deploy two escrows — one with each resolver
        usdc = new MockUSDC3();
        escrowHuman = new AgentEscrow(address(validator), address(usdc), address(humanResolver));
        escrowOracle = new AgentEscrow(address(validator), address(usdc), address(oracleResolver));

        // Fund buyer
        usdc.mint(buyer, 20 * ONE_USDC);
        vm.stopPrank();

        vm.prank(buyer);
        usdc.approve(address(escrowHuman), type(uint256).max);

        vm.prank(buyer);
        usdc.approve(address(escrowOracle), type(uint256).max);

        // Create escrows
        vm.prank(buyer);
        escrowHuman.createEscrow(seller, 5 * ONE_USDC);

        vm.prank(buyer);
        escrowOracle.createEscrow(seller, 5 * ONE_USDC);
    }

    // ============ Interface Compliance Proof ============

    function testBothResolversImplementIResolver() public {
        // Both are castable to IResolver
        IResolver human = IResolver(address(humanResolver));
        IResolver oracle = IResolver(address(oracleResolver));

        // Both have the same function selectors
        // fileDispute, submitEvidence, getVerdict, executeVerdict, isReady, cancelDispute
        assertTrue(address(human) != address(0));
        assertTrue(address(oracle) != address(0));
    }

    // ============ GenLayerOracleResolver Flow ============

    function testOracleResolverFullFlow() public {
        // 1. Open dispute via escrow
        vm.prank(buyer);
        uint256 disputeId = escrowOracle.openDispute(1, "Agent didn't deliver");

        // 2. Submit evidence
        vm.prank(seller);
        oracleResolver.submitEvidence(disputeId, "ipfs://QmProofOfWork");

        // 3. Owner (simulating GenLayer) sets verdict
        vm.prank(owner);
        oracleResolver.setVerdict(disputeId, IResolver.Verdict.BuyerWins, "AI: No delivery evidence");

        // 4. Check isReady
        assertTrue(oracleResolver.isReady(disputeId));

        // 5. Execute via escrow
        uint256 buyerBefore = usdc.balanceOf(buyer);
        vm.prank(buyer);
        escrowOracle.resolveDispute(1);

        assertEq(usdc.balanceOf(buyer), buyerBefore + 5 * ONE_USDC);
    }

    function testOracleResolverSplit() public {
        vm.prank(buyer);
        uint256 disputeId = escrowOracle.openDispute(1, "Partial delivery");

        vm.prank(owner);
        oracleResolver.setVerdict(disputeId, IResolver.Verdict.Split, "AI: 50% complete");

        uint256 buyerBefore = usdc.balanceOf(buyer);
        uint256 sellerBefore = usdc.balanceOf(seller);

        vm.prank(buyer);
        escrowOracle.resolveDispute(1);

        assertEq(usdc.balanceOf(buyer), buyerBefore + 2.5e6);
        assertEq(usdc.balanceOf(seller), sellerBefore + 2.5e6);
    }

    function testOracleResolverSellerWins() public {
        vm.prank(buyer);
        uint256 disputeId = escrowOracle.openDispute(1, "Not satisfied");

        vm.prank(owner);
        oracleResolver.setVerdict(disputeId, IResolver.Verdict.SellerWins, "AI: Work was delivered correctly");

        uint256 sellerBefore = usdc.balanceOf(seller);

        vm.prank(buyer);
        escrowOracle.resolveDispute(1);

        assertEq(usdc.balanceOf(seller), sellerBefore + 5 * ONE_USDC);
    }

    function testOracleResolverNotReadyPending() public {
        vm.prank(buyer);
        uint256 disputeId = escrowOracle.openDispute(1, "Test");

        // Not ready yet — no verdict set
        assertFalse(oracleResolver.isReady(disputeId));

        // Escrow can't resolve
        vm.expectRevert(AgentEscrow.VerdictNotReady.selector);
        vm.prank(buyer);
        escrowOracle.resolveDispute(1);
    }

    // ============ Cross-Resolver Consistency ============

    function testBothResolversReturnSamePayouts() public {
        // File disputes in both
        vm.prank(buyer);
        uint256 humanId = escrowHuman.openDispute(1, "Test");
        vm.prank(buyer);
        uint256 oracleId = escrowOracle.openDispute(1, "Test");

        // Resolve both with Split
        vm.prank(owner);
        humanResolver.addArbitrator(owner);
        vm.prank(owner);
        humanResolver.resolveDispute(humanId, IResolver.Verdict.Split, "50/50");

        vm.prank(owner);
        oracleResolver.setVerdict(oracleId, IResolver.Verdict.Split, "50/50");

        // Both should return same payouts
        (, , uint256 humanBuyerPayout, uint256 humanSellerPayout) = humanResolver.getVerdict(humanId);
        (, , uint256 oracleBuyerPayout, uint256 oracleSellerPayout) = oracleResolver.getVerdict(oracleId);

        assertEq(humanBuyerPayout, oracleBuyerPayout);
        assertEq(humanSellerPayout, oracleSellerPayout);
    }

    // ============ Oracle Admin ============

    function testOnlyOwnerCanSetVerdict() public {
        vm.prank(buyer);
        uint256 disputeId = escrowOracle.openDispute(1, "Test");

        address rando = makeAddr("rando");
        vm.prank(rando);
        vm.expectRevert();
        oracleResolver.setVerdict(disputeId, IResolver.Verdict.BuyerWins, "unauthorized");
    }

    function testCannotSetVerdictTwice() public {
        vm.prank(buyer);
        uint256 disputeId = escrowOracle.openDispute(1, "Test");

        vm.prank(owner);
        oracleResolver.setVerdict(disputeId, IResolver.Verdict.BuyerWins, "first");

        vm.prank(owner);
        vm.expectRevert("Already resolved");
        oracleResolver.setVerdict(disputeId, IResolver.Verdict.SellerWins, "second");
    }
}

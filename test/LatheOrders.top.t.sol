// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {WiredBase} from "./WiredBase.sol";
import {LatheOrders} from "../src/LatheOrders.sol";
import {Piece} from "../src/FormulaLib.sol";
import {Wire} from "../src/NetlistLib.sol";
import {RefProcessor} from "./mocks/RefProcessor.sol";

/// @notice V3b (Task 12): one top circuit made of references (REF records) to tested pieces.
///
/// Money rules, each with a test here:
/// - The buyer picks the kind at create, for good: needsTop false = "Lathe joins" (pays when the last piece passes),
///   needsTop true = "needs a top circuit" (pays only at deliverTop). Nothing switches it.
/// - deliverTop: only on a needs-top order, only once every piece has passed and is re-verified unchanged, only
///   by the named builder who owns the top, only when the top's netlist bytes equal expectedTopNetlist and its
///   circuitInfo shape is (nIn, nOut, no memory). Pays once, one receipt naming the top; ruleOf and run use the top.
/// - Window: deliverTop until deadline + GRACE (pieces delivered in time may finish their check in the grace too).
///   Refund rules are the pieced ones, unchanged: after the deadline if some piece was never delivered, else after
///   deadline + GRACE. So all pieces passed but no top: the buyer refunds after deadline + GRACE.
/// - No case-by-case check of the top: equal bytes + equal shape + every piece fully checked means the top computes
///   the joined rule by construction (argument in LatheOrders.deliverTop). test_top_matchesJoin_everyInput runs a
///   real REF-evaluating mock top against the joined pieces on every input; test/fork/RefTopFork.t.sol does it on
///   live TapeOut circuits.
contract LatheOrdersTopTest is WiredBase {
    uint256 constant OR = 1; // proc ids, 2 inputs, 1 output, 4 gates
    uint256 constant NAND = 2;
    uint256 constant AND = 3;
    uint256 constant OR_BIG = 4; // same OR, 500 gates: checked in batches
    uint256 constant ANDNOT = 5; // out = in0 AND NOT in1
    uint256 constant ADD22 = 1; // fproc: Add(2, 2), 4 gates

    function setUp() public override {
        super.setUp();
        setCircuitFromTable(OR, builder, 2, 1, hex"0e", SMALL);
        setCircuitFromTable(NAND, builder, 2, 1, hex"07", SMALL);
        setCircuitFromTable(AND, builder, 2, 1, hex"08", SMALL);
        setCircuitFromTable(OR_BIG, builder, 2, 1, hex"0e", BATCHED_GATES);
        setCircuitFromTable(ANDNOT, builder, 2, 1, hex"02", SMALL);
        fproc.setCircuit(ADD22, builder, true, 2, 2, SMALL);
    }

    // ---- fixtures ----

    /// XOR made of three parts, the recipe of the live circuit Cerebr id 5: OR(A, B), NAND(A, B), then AND of the two.
    function xorParts() internal pure returns (Piece[] memory ps, bytes[] memory ts, Wire[] memory ws) {
        ps = new Piece[](3);
        ps[0] = tablePiece(2, 1);
        ps[1] = tablePiece(2, 1);
        ps[2] = tablePiece(2, 1);
        ts = new bytes[](3);
        ts[0] = hex"0e";
        ts[1] = hex"07";
        ts[2] = hex"08";
        ws = new Wire[](7);
        ws[0] = w(TOP, 0, 0, 0);
        ws[1] = w(TOP, 1, 0, 1);
        ws[2] = w(TOP, 0, 1, 0);
        ws[3] = w(TOP, 1, 1, 1);
        ws[4] = w(0, 0, 2, 0);
        ws[5] = w(1, 0, 2, 1);
        ws[6] = w(2, 0, TOP, 0);
    }

    function createXorParts(bool top) internal returns (uint256) {
        (Piece[] memory ps, bytes[] memory ts, Wire[] memory ws) = xorParts();
        return createWired(ps, ts, ws, top);
    }

    function deliverXorParts(uint256 id) internal {
        deliverP(id, 0, address(proc), OR);
        deliverP(id, 1, address(proc), NAND);
        deliverP(id, 2, address(proc), AND);
    }

    function deliverTop(uint256 id, address p, uint256 cid) internal {
        vm.prank(builder);
        lathe.deliverTop(id, p, cid);
    }

    // ---- the plan's tests ----

    function test_deliverTop_paysAndPointsRuleAtTop() public {
        uint256 id = createXorParts(true);
        assertTrue(lathe.needsTop(id));
        deliverXorParts(id);
        // Every piece passed, but a needs-top order does not pay on the last piece.
        assertEq(uint8(status(id)), uint8(LatheOrders.Status.Open));
        assertEq(usdt.balanceOf(builder), 0);
        uint256 top = mintTop(id, builder);
        bytes32 h = lathe.piecedHash(id);
        vm.roll(4242);
        vm.expectEmit(true, false, false, true);
        emit LatheOrders.Receipt(id, address(rproc), top, h);
        vm.expectEmit(true, true, false, true);
        emit LatheOrders.Paid(id, builder, address(rproc), top);
        deliverTop(id, address(rproc), top);
        assertEq(uint8(status(id)), uint8(LatheOrders.Status.Paid));
        uint256 fee = uint256(AMOUNT) * FEE_BPS / 10_000;
        assertEq(usdt.balanceOf(builder), AMOUNT - fee);
        assertEq(lathe.feesOwed(), fee);
        (address rp, uint256 rc, bytes32 rh, uint64 bn) = lathe.receipts(id);
        assertEq(rp, address(rproc));
        assertEq(rc, top);
        assertEq(rh, h);
        assertEq(bn, 4242);
        (address p, uint256 c) = lathe.ruleOf(id);
        assertEq(p, address(rproc));
        assertEq(c, top);
        _checkTopRecord(id, top);
        // run evaluates the top circuit itself: exactly one eval of the top per call.
        for (uint8 x = 0; x < 4; ++x) {
            vm.expectCall(address(rproc), abi.encodeCall(RefProcessor.eval, (top, abi.encodePacked(x))), 1);
            assertEq(lathe.run(id, abi.encodePacked(x)), abi.encodePacked((x & 1) ^ (x >> 1)));
        }
        // Paid once: a second top, or the same one again, is refused.
        vm.prank(builder);
        vm.expectRevert(LatheOrders.NotOpen.selector);
        lathe.deliverTop(id, address(rproc), top);
    }

    function _checkTopRecord(uint256 id, uint256 top) internal view {
        (address dp, uint256 dc, address db, uint32 dg, bytes32 dh,) = lathe.deliveries(id);
        assertEq(dp, address(rproc));
        assertEq(dc, top);
        assertEq(db, builder);
        assertEq(dg, 3 * SMALL); // the top's own gate count includes the referenced gates
        assertEq(dh, keccak256(lathe.expectedTopNetlist(id)));
    }

    function test_deliverTop_wrongWiring_reverts() public {
        uint256 id = createXorParts(true);
        deliverXorParts(id);
        bytes memory good = lathe.expectedTopNetlist(id);
        // AND fed from (NAND, OR) instead of (OR, NAND): the same function here, but not the wiring ordered.
        (Piece[] memory ps, bytes[] memory ts, Wire[] memory ws) = xorParts();
        ws[4] = w(1, 0, 2, 0);
        ws[5] = w(0, 0, 2, 1);
        uint256 other = createWired(ps, ts, ws, true);
        deliverXorParts(other);
        bytes memory swapped = lathe.expectedTopNetlist(other);
        assertTrue(keccak256(swapped) != keccak256(good));
        uint256 wrongTop = rproc.mint(swapped, 2, 1, builder);
        vm.prank(builder);
        vm.expectRevert(LatheOrders.WrongTopCircuit.selector);
        lathe.deliverTop(id, address(rproc), wrongTop);
        // Right bytes, wrong shape: netlist() does not hold nIn or nOut, so circuitInfo is checked too.
        uint256 threeIn = rproc.mint(good, 3, 1, builder);
        vm.prank(builder);
        vm.expectRevert(LatheOrders.ShapeMismatch.selector);
        lathe.deliverTop(id, address(rproc), threeIn);
        uint256 twoOut = rproc.mint(good, 2, 2, builder);
        vm.prank(builder);
        vm.expectRevert(LatheOrders.ShapeMismatch.selector);
        lathe.deliverTop(id, address(rproc), twoOut);
        // A piece circuit in place of the top: right shape, wrong bytes.
        vm.prank(builder);
        vm.expectRevert(LatheOrders.WrongTopCircuit.selector);
        lathe.deliverTop(id, address(proc), AND);
        assertEq(uint8(status(id)), uint8(LatheOrders.Status.Open));
        // The right one pays.
        deliverTop(id, address(rproc), rproc.mint(good, 2, 1, builder));
        assertEq(uint8(status(id)), uint8(LatheOrders.Status.Paid));
    }

    function test_deliverTop_beforePiecesPass_reverts() public {
        uint256 id = createXorParts(true);
        uint256 early = rproc.mint(hex"00", 2, 1, builder);
        vm.prank(builder);
        vm.expectRevert(LatheOrders.PiecesNotPassed.selector);
        lathe.deliverTop(id, address(rproc), early);
        vm.expectRevert(LatheOrders.PiecesNotPassed.selector);
        lathe.expectedTopNetlist(id); // the bytes name every piece's circuit, so they are not fixed yet
        deliverP(id, 1, address(proc), NAND);
        deliverP(id, 2, address(proc), AND);
        // Piece 0 delivered but still being checked (500 gates: batched).
        deliverP(id, 0, address(proc), OR_BIG);
        uint256 top = mintTop(id, builder);
        vm.prank(builder);
        vm.expectRevert(LatheOrders.PiecesNotPassed.selector);
        lathe.deliverTop(id, address(rproc), top);
        lathe.checkPiece(id, 0, 2);
        vm.prank(builder);
        vm.expectRevert(LatheOrders.PiecesNotPassed.selector);
        lathe.deliverTop(id, address(rproc), top);
        (bool done, bool passed) = lathe.checkPiece(id, 0, 2);
        assertTrue(done && passed);
        assertEq(uint8(status(id)), uint8(LatheOrders.Status.Open)); // still waits for the top
        deliverTop(id, address(rproc), top);
        assertEq(uint8(status(id)), uint8(LatheOrders.Status.Paid));
    }

    // ---- guards reused from deliver ----

    function test_deliverTop_guards() public {
        uint256 id = createXorParts(true);
        deliverXorParts(id);
        bytes memory good = lathe.expectedTopNetlist(id);
        uint256 top = rproc.mint(good, 2, 1, builder);
        vm.prank(stranger);
        vm.expectRevert(LatheOrders.NotBuilder.selector);
        lathe.deliverTop(id, address(rproc), top);
        // The builder delivering a copy someone else owns.
        uint256 theirs = rproc.mint(good, 2, 1, stranger);
        vm.prank(builder);
        vm.expectRevert(LatheOrders.NotCircuitOwner.selector);
        lathe.deliverTop(id, address(rproc), theirs);
        vm.prank(builder);
        vm.expectRevert(LatheOrders.NotCircuitOwner.selector);
        lathe.deliverTop(id, address(rproc), 999); // no such circuit
        // A processor the factory never registered.
        RefProcessor rogue = new RefProcessor();
        uint256 r = rogue.mint(good, 2, 1, builder);
        vm.prank(builder);
        vm.expectRevert(LatheOrders.NotProcessor.selector);
        lathe.deliverTop(id, address(rogue), r);
        // A passed piece changed after it passed.
        proc.setNetlist(NAND, hex"beef");
        vm.prank(builder);
        vm.expectRevert(LatheOrders.CircuitChanged.selector);
        lathe.deliverTop(id, address(rproc), top);
    }

    function test_deliverTop_wrongKind_reverts() public {
        uint256 joins = createXorParts(false);
        assertFalse(lathe.needsTop(joins));
        uint256 top = rproc.mint(hex"00", 2, 1, builder);
        vm.prank(builder);
        vm.expectRevert(LatheOrders.WrongOrderKind.selector);
        lathe.deliverTop(joins, address(rproc), top);
        uint256 v0 = createXor();
        vm.prank(builder);
        vm.expectRevert(LatheOrders.WrongOrderKind.selector);
        lathe.deliverTop(v0, address(rproc), top);
        vm.prank(builder);
        vm.expectRevert(LatheOrders.WrongOrderKind.selector);
        lathe.deliverTop(999, address(rproc), top);
    }

    // ---- the two kinds ----

    /// "Lathe joins" pays on the last piece and has no top; the same pieces and wires as "needs a top" do not.
    function test_kind_latheJoins_paysOnLastPiece() public {
        uint256 id = createXorParts(false);
        deliverXorParts(id);
        assertEq(uint8(status(id)), uint8(LatheOrders.Status.Paid));
        (address rp, uint256 rc,,) = lathe.receipts(id);
        assertEq(rp, address(0));
        assertEq(rc, 0);
        vm.expectRevert(LatheOrders.NoSingleCircuit.selector);
        lathe.ruleOf(id);
        (address dp,,,,,) = lathe.deliveries(id);
        assertEq(dp, address(0));
        for (uint8 x = 0; x < 4; ++x) {
            assertEq(lathe.run(id, abi.encodePacked(x)), abi.encodePacked((x & 1) ^ (x >> 1)));
        }
    }

    /// The kind is part of the create call and stored once. No function takes it as an argument afterwards, so a
    /// needs-top order can never be paid by the pieces alone, and a joined order never by a top.
    function test_kind_fixedAtCreate() public {
        uint256 a = createXorParts(true);
        uint256 b = createXorParts(false);
        deliverXorParts(a);
        deliverXorParts(b);
        assertTrue(lathe.needsTop(a));
        assertFalse(lathe.needsTop(b));
        assertEq(uint8(status(a)), uint8(LatheOrders.Status.Open));
        assertEq(uint8(status(b)), uint8(LatheOrders.Status.Paid));
        // Orders created without wires are always "Lathe joins".
        Piece[] memory ps = new Piece[](1);
        ps[0] = tablePiece(2, 1);
        bytes[] memory ts = new bytes[](1);
        ts[0] = hex"0e";
        vm.prank(buyer);
        uint256 c = lathe.createPiecedOrder(ps, ts, AMOUNT, deadline, builder, new uint32[](1), new bytes32[](0));
        assertFalse(lathe.needsTop(c));
    }

    function test_create_needsTop_outputsMustBeLast() public {
        (Piece[] memory ps, bytes[] memory ts, Wire[] memory ws) = xorParts();
        // The order answers OR(A, B) and AND is a dangling last piece: fine joined, impossible as one REF-only top.
        ws[6] = w(0, 0, TOP, 0);
        expectCreateRevert(spec(ps, ts, ws, true), LatheOrders.TopNeedsLastOutputs.selector);
        uint256 id = createWired(ps, ts, ws, false);
        deliverXorParts(id);
        assertEq(lathe.run(id, hex"02"), hex"01");
        assertEq(lathe.run(id, hex"00"), hex"00");
    }

    // ---- deadline, grace, refund ----

    function test_needsTop_noTop_refundsAfterGrace() public {
        uint256 id = createXorParts(true);
        deliverXorParts(id);
        uint256 top = mintTop(id, builder);
        vm.warp(uint256(deadline) + 1);
        vm.prank(buyer);
        vm.expectRevert(LatheOrders.RefundNotAllowed.selector); // every piece was delivered: grace applies
        lathe.refund(id);
        vm.warp(uint256(deadline) + lathe.GRACE() + 1);
        vm.prank(builder);
        vm.expectRevert(LatheOrders.GraceOver.selector);
        lathe.deliverTop(id, address(rproc), top);
        uint256 before = usdt.balanceOf(buyer);
        vm.prank(buyer);
        lathe.refund(id);
        assertEq(usdt.balanceOf(buyer), before + AMOUNT);
        assertEq(uint8(status(id)), uint8(LatheOrders.Status.Refunded));
        vm.prank(builder);
        vm.expectRevert(LatheOrders.NotOpen.selector);
        lathe.deliverTop(id, address(rproc), top);
    }

    function test_needsTop_topDuringGrace_pays() public {
        uint256 id = createXorParts(true);
        deliverXorParts(id);
        uint256 top = mintTop(id, builder);
        vm.warp(uint256(deadline) + lathe.GRACE()); // last second of grace
        deliverTop(id, address(rproc), top);
        assertEq(uint8(status(id)), uint8(LatheOrders.Status.Paid));
        vm.prank(buyer);
        vm.expectRevert(LatheOrders.RefundNotAllowed.selector);
        lathe.refund(id);
    }

    function test_needsTop_pieceNeverDelivered_refundsAtDeadline() public {
        uint256 id = createXorParts(true);
        deliverP(id, 0, address(proc), OR);
        deliverP(id, 1, address(proc), NAND);
        vm.warp(uint256(deadline) + 1);
        vm.prank(buyer);
        lathe.refund(id);
        assertEq(uint8(status(id)), uint8(LatheOrders.Status.Refunded));
        (address p0,,,,,) = lathe.pieceOf(id, 0);
        assertEq(p0, address(0));
    }

    // ---- the top computes the joined rule ----

    /// 5 inputs: piece 0 = Add(2, 2) on x0..x3 makes a 3-bit sum s; piece 1 = AND-NOT on (s1, x4).
    /// The order's 2 outputs are the last two piece-output bits: s2 (piece 0's last output) then piece 1's answer.
    /// So outputs span two pieces, x4 is a later input, and s1 feeds a later piece.
    function spanParts() internal pure returns (Piece[] memory ps, bytes[] memory ts, Wire[] memory ws) {
        ps = new Piece[](2);
        ps[0] = add(2, 2);
        ps[1] = tablePiece(2, 1);
        ts = new bytes[](2);
        ts[1] = hex"02";
        ws = new Wire[](8);
        ws[0] = w(TOP, 4, 1, 1); // any order in the list: stored sorted
        ws[1] = w(TOP, 0, 0, 0);
        ws[2] = w(TOP, 1, 0, 1);
        ws[3] = w(1, 0, TOP, 1);
        ws[4] = w(TOP, 2, 0, 2);
        ws[5] = w(TOP, 3, 0, 3);
        ws[6] = w(0, 1, 1, 0);
        ws[7] = w(0, 2, TOP, 0);
    }

    function test_top_matchesJoin_everyInput() public {
        (Piece[] memory ps, bytes[] memory ts, Wire[] memory ws) = spanParts();
        uint256 t = createWired(ps, ts, ws, true);
        uint256 j = createWired(ps, ts, ws, false);
        deliverP(t, 0, address(fproc), ADD22);
        deliverP(t, 1, address(proc), ANDNOT);
        deliverP(j, 0, address(fproc), ADD22);
        deliverP(j, 1, address(proc), ANDNOT);
        uint256 top = mintTop(t, builder);
        deliverTop(t, address(rproc), top);
        assertEq(uint8(status(t)), uint8(LatheOrders.Status.Paid));
        assertEq(uint8(status(j)), uint8(LatheOrders.Status.Paid));
        (uint8 nIn, uint8 nOut) = shape(t);
        assertEq(nIn, 5);
        assertEq(nOut, 2);
        for (uint256 x = 0; x < 32; ++x) {
            uint256 s = (x & 3) + ((x >> 2) & 3);
            uint256 y = ((s >> 2) & 1) | ((((s >> 1) & 1) == 1 && ((x >> 4) & 1) == 0 ? 1 : 0) << 1);
            bytes memory inp = abi.encodePacked(uint8(x));
            bytes memory viaTop = lathe.run(t, inp);
            assertEq(viaTop, abi.encodePacked(uint8(y)), "top");
            assertEq(lathe.run(j, inp), viaTop, "join");
            assertEq(rproc.eval(top, inp), viaTop, "eval");
        }
    }

    // ---- after payment ----

    function test_run_top_circuitChanged_reverts() public {
        uint256 id = createXorParts(true);
        deliverXorParts(id);
        uint256 top = mintTop(id, builder);
        deliverTop(id, address(rproc), top);
        assertEq(lathe.run(id, hex"01"), hex"01");
        // A piece changes: the top's own bytes still match, but it would run a different circuit.
        proc.setNetlist(OR, hex"01");
        vm.expectRevert(LatheOrders.CircuitChanged.selector);
        lathe.run(id, hex"01");
        proc.setNetlist(OR, abi.encodePacked("netlist", OR, SMALL));
        assertEq(lathe.run(id, hex"01"), hex"01");
        // The top changes.
        rproc.setNetlist(top, hex"00");
        vm.expectRevert(LatheOrders.CircuitChanged.selector);
        lathe.run(id, hex"01");
    }

    function test_receipt_top_fingerprintCoversWires() public {
        uint256 id = createXorParts(true);
        (Piece[] memory ps, bytes[] memory ts, Wire[] memory ws) = xorParts();
        assertEq(lathe.piecedHash(id), keccak256(abi.encode(ps, ts, ws)));
        Wire[] memory got = lathe.wiresOf(id);
        assertEq(keccak256(abi.encode(got)), keccak256(abi.encode(ws)));
        deliverXorParts(id);
        deliverTop(id, address(rproc), mintTop(id, builder));
        (,, bytes32 rh,) = lathe.receipts(id);
        assertEq(rh, keccak256(abi.encode(ps, ts, ws)));
    }
}

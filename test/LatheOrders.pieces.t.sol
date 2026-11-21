// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {LatheBase} from "./LatheBase.sol";
import {LatheOrders} from "../src/LatheOrders.sol";
import {Piece, PieceKind} from "../src/FormulaLib.sol";
import {FormulaProcessor} from "./mocks/FormulaProcessor.sol";

/// @notice V3a (Task 9): pieced orders. An order is a list of 1 or 2 pieces; each piece is delivered and checked
/// like a V0 delivery (own processor, circuit id, cursor); the order pays once every piece has passed.
///
/// Bit layout, LSB first everywhere:
/// - A piece's case c is the circuit input whose bit k is bit k of c.
/// - Formula pieces: a = input bits 0 .. widthA-1, b = input bits widthA .. widthA+widthB-1 (each LSB first).
///   GreaterOrEqual answers 1 bit (a >= b); Add answers widthA + 1 bits (a + b).
/// - Two-piece join: the order's top-level input x has nIn = A.nIn + B.nIn - A.nOut bits. A gets the first A.nIn
///   bits of x (bits 0 .. A.nIn-1). B's input is outA in its low A.nOut bits, then the remaining bits of x
///   (x >> A.nIn) above them: B.in = outA | ((x >> A.nIn) << A.nOut). The order's outputs are B's outputs.
/// - Two of three (the target rule): x bits 0..7 = amount, 8..15 = threshold, 16..18 = three approvals.
///   A = GreaterOrEqual(8, 8) (amount >= threshold); B = 4-input table, B input 0 = A's answer, inputs 1..3 = the
///   approvals; B answers 1 when A said yes and at least two approved.
///
/// Money rules (each has a test below):
/// - Pays only when every piece has passed; one rejected piece reopens only that piece.
/// - A passed piece cannot be delivered again (PieceAlreadyPassed); a piece being checked cannot either (NotOpen).
/// - Deadline: deliverPiece needs now <= deadline; checkPiece runs until deadline + GRACE. The buyer may refund
///   after the deadline when the order can no longer pay (some piece has no delivery), and in any case after
///   deadline + GRACE. So a piece mid-check at the deadline gets the same grace as a V0 delivery.
/// - At payout every piece's gate count and netlist hash are checked again; a change reverts CircuitChanged.
/// - Receipt: a 1-piece order's receipt names its circuit (ruleOf works). A 2-piece order has no single circuit:
///   its receipt has processor 0 and circuit id 0, ruleOf reverts NoSingleCircuit, piecesOf / pieceOf name the
///   pieces, and run joins them.
contract LatheOrdersPiecesTest is LatheBase {
    FormulaProcessor fproc;

    uint256 constant GE88 = 1; // fproc: GreaterOrEqual(8, 8), 70 gates: 65,536 cases, checked in batches
    uint256 constant GE22 = 2; // fproc: GreaterOrEqual(2, 2), 500 gates: 16 cases, batched
    uint256 constant GE22_WRONG = 3; // same, wrong at case 9
    uint256 constant GE22_SMALL = 4; // same, 4 gates: checked inside deliverPiece
    uint256 constant TWO_OF_THREE = 10; // proc: 4-input table
    uint256 constant ANDNOT = 11; // proc: 2-input table, out = in0 AND NOT in1
    uint256 constant ANDNOT_WRONG = 12;
    uint32 constant SMALL = 4;

    uint64 deadline;

    function setUp() public override {
        super.setUp();
        fproc = new FormulaProcessor();
        factory.setCPU(address(fproc), true);
        fproc.setCircuit(GE88, builder, false, 8, 8, 70);
        fproc.setCircuit(GE22, builder, false, 2, 2, BATCHED_GATES);
        fproc.setCircuit(GE22_WRONG, builder, false, 2, 2, BATCHED_GATES);
        fproc.setWrongAt(GE22_WRONG, 9);
        fproc.setCircuit(GE22_SMALL, builder, false, 2, 2, SMALL);
        setCircuitFromTable(TWO_OF_THREE, builder, 4, 1, twoOfThreeTable(), SMALL);
        setCircuitFromTable(ANDNOT, builder, 2, 1, hex"02", SMALL);
        setCircuitFromTable(ANDNOT_WRONG, builder, 2, 1, hex"03", SMALL); // wrong at case 0
        deadline = uint64(block.timestamp + 1 days);
    }

    // ---- fixtures ----

    function ge(uint8 wa, uint8 wb) internal pure returns (Piece memory) {
        return Piece(PieceKind.GreaterOrEqual, wa + wb, 1, wa, wb);
    }

    function tablePiece(uint8 nIn, uint8 nOut) internal pure returns (Piece memory) {
        return Piece(PieceKind.Table, nIn, nOut, 0, 0);
    }

    /// B input 0 = A's answer, inputs 1..3 = approvals. 1 when input 0 is 1 and at least two approvals are 1.
    function twoOfThreeTable() internal pure returns (bytes memory t) {
        t = new bytes(2);
        for (uint256 c = 0; c < 16; ++c) {
            uint256 votes = ((c >> 1) & 1) + ((c >> 2) & 1) + ((c >> 3) & 1);
            if (c & 1 == 1 && votes >= 2) t[c / 8] = bytes1(uint8(t[c / 8]) | uint8(1 << (c % 8)));
        }
    }

    function create(Piece[] memory ps, bytes[] memory ts, bytes32[] memory labels) internal returns (uint256 id) {
        uint32[] memory mg = new uint32[](ps.length);
        vm.prank(buyer);
        id = lathe.createPiecedOrder(ps, ts, AMOUNT, deadline, builder, mg, labels);
    }

    function two(Piece memory a, bytes memory ta, Piece memory b, bytes memory tb) internal returns (uint256) {
        Piece[] memory ps = new Piece[](2);
        ps[0] = a;
        ps[1] = b;
        bytes[] memory ts = new bytes[](2);
        ts[0] = ta;
        ts[1] = tb;
        return create(ps, ts, new bytes32[](0));
    }

    /// 5 inputs: A = GreaterOrEqual(2, 2) on x bits 0..3, B = AND-NOT table on (outA, x bit 4).
    /// The order answers 1 exactly when a >= b and x4 == 0. B is not symmetric, so a join that put outA anywhere
    /// but B's input 0 would fail the brute-force run test.
    function createSmall() internal returns (uint256) {
        return two(ge(2, 2), "", tablePiece(2, 1), hex"02");
    }

    function createTwoOfThree() internal returns (uint256) {
        return two(ge(8, 8), "", tablePiece(4, 1), twoOfThreeTable());
    }

    function deliverP(uint256 id, uint256 i, address p, uint256 cid) internal {
        vm.prank(builder);
        lathe.deliverPiece(id, i, p, cid);
    }

    function status(uint256 id) internal view returns (LatheOrders.Status s) {
        (,,,,,,,, s) = lathe.orders(id);
    }

    function nextOf(uint256 id, uint256 i) internal view returns (uint32 n) {
        (,,,,, n) = lathe.pieceOf(id, i);
    }

    function procOf(uint256 id, uint256 i) internal view returns (address p) {
        (p,,,,,) = lathe.pieceOf(id, i);
    }

    function paidTwoOfThree() internal returns (uint256 id) {
        id = createTwoOfThree();
        deliverP(id, 0, address(fproc), GE88);
        bool done;
        bool passed;
        for (uint256 k = 0; k < 4; ++k) {
            (done, passed) = lathe.checkPiece(id, 0, 16_384);
        }
        assertTrue(done && passed);
        assertEq(uint8(status(id)), uint8(LatheOrders.Status.Open)); // B not delivered: no pay yet
        deliverP(id, 1, address(proc), TWO_OF_THREE); // 16 cases x 4 gates: checked inside deliverPiece
        assertEq(uint8(status(id)), uint8(LatheOrders.Status.Paid));
    }

    // ---- the plan's tests ----

    function test_twoOfThree_paysWhenBothPass() public {
        uint256 id = paidTwoOfThree();
        uint256 fee = uint256(AMOUNT) * FEE_BPS / 10_000;
        assertEq(usdt.balanceOf(builder), AMOUNT - fee);
        assertEq(lathe.feesOwed(), fee);
        assertEq(nextOf(id, 0), 65_536);
        assertEq(nextOf(id, 1), 16);
        (, uint8 nIn, uint8 nOut) = shape(id);
        assertEq(nIn, 19);
        assertEq(nOut, 1);
    }

    function shape(uint256 id) internal view returns (uint8 nState, uint8 nIn, uint8 nOut) {
        (,,,,, nIn, nOut, nState,) = lathe.orders(id);
    }

    function test_onePieceFails_noPay() public {
        uint256 id = createSmall();
        deliverP(id, 1, address(proc), ANDNOT); // B passes inside deliverPiece; A not delivered, so no pay
        assertEq(nextOf(id, 1), 4);
        deliverP(id, 0, address(fproc), GE22_WRONG);
        vm.expectEmit(true, true, false, true);
        emit LatheOrders.PieceRejected(id, 0, 9);
        (bool done, bool passed) = lathe.checkPiece(id, 0, 100);
        assertTrue(done);
        assertFalse(passed);
        assertEq(uint8(status(id)), uint8(LatheOrders.Status.Open));
        assertEq(usdt.balanceOf(builder), 0);
        // Only A reopened; B is still passed.
        assertEq(procOf(id, 0), address(0));
        assertEq(procOf(id, 1), address(proc));
        assertEq(nextOf(id, 1), 4);
        // The builder fixes A and the order pays.
        deliverP(id, 0, address(fproc), GE22);
        (done, passed) = lathe.checkPiece(id, 0, 100);
        assertTrue(done && passed);
        assertEq(uint8(status(id)), uint8(LatheOrders.Status.Paid));
    }

    function test_run_twoPiece_joins() public {
        uint256 id = createSmall();
        deliverP(id, 0, address(fproc), GE22_SMALL); // inline
        deliverP(id, 1, address(proc), ANDNOT);
        assertEq(uint8(status(id)), uint8(LatheOrders.Status.Paid));
        for (uint256 x = 0; x < 32; ++x) {
            uint256 a = x & 3;
            uint256 b = (x >> 2) & 3;
            uint256 want = (a >= b && (x >> 4) & 1 == 0) ? 1 : 0;
            assertEq(lathe.run(id, abi.encodePacked(uint8(x))), abi.encodePacked(uint8(want)), "join");
        }
    }

    function test_run_twoOfThree_bitOrder() public {
        uint256 id = paidTwoOfThree();
        // amount 5, threshold 4, approvals 1,1,0 -> yes. Input bytes: amount, threshold, approvals.
        assertEq(lathe.run(id, hex"050403"), hex"01");
        assertEq(lathe.run(id, hex"040503"), hex"00"); // amount < threshold
        assertEq(lathe.run(id, hex"050401"), hex"00"); // one approval
        assertEq(lathe.run(id, hex"050406"), hex"01"); // approvals 2 and 3
        assertEq(lathe.run(id, hex"ffff07"), hex"01"); // equal counts as at least
        vm.expectRevert(LatheOrders.BadInputs.selector);
        lathe.run(id, hex"050408"); // bit 19 set: above nIn
        vm.expectRevert(LatheOrders.BadInputs.selector);
        lathe.run(id, hex"0504");
    }

    function test_legacySinglePiece_stillWorks() public {
        uint256 id = createXor();
        setCircuitFromTable(20, builder, 2, 1, xorTable(), SMALL);
        vm.prank(builder);
        lathe.deliver(id, address(proc), 20);
        assertEq(uint8(status(id)), uint8(LatheOrders.Status.Paid));
        (address p, uint256 cid,,,, uint32 next) = lathe.deliveries(id);
        assertEq(p, address(proc));
        assertEq(cid, 20);
        assertEq(next, 4);
        (address rp, uint256 rid) = lathe.ruleOf(id);
        assertEq(rp, address(proc));
        assertEq(rid, 20);
        assertEq(lathe.run(id, hex"01"), hex"01");
        assertEq(lathe.piecesOf(id).length, 0);
        // Legacy orders reject the pieced functions.
        vm.expectRevert(LatheOrders.WrongOrderKind.selector);
        lathe.checkPiece(id, 0, 1);
    }

    // ---- order kind separation ----

    /// A pieced order has no table in tableOf; the V0 path must never check it (an all-zero circuit would match).
    function test_legacyDeliver_onPiecedOrder_reverts() public {
        uint256 id = createSmall();
        vm.prank(builder);
        vm.expectRevert(LatheOrders.WrongOrderKind.selector);
        lathe.deliver(id, address(proc), ANDNOT);
        vm.expectRevert(LatheOrders.NotChecking.selector);
        lathe.check(id, 10);
    }

    function test_deliverPiece_onLegacyOrder_reverts() public {
        uint256 id = createXor();
        vm.prank(builder);
        vm.expectRevert(LatheOrders.WrongOrderKind.selector);
        lathe.deliverPiece(id, 0, address(proc), ANDNOT);
    }

    function test_deliverPiece_noSuchPiece_reverts() public {
        uint256 id = createSmall();
        vm.prank(builder);
        vm.expectRevert(LatheOrders.NoSuchPiece.selector);
        lathe.deliverPiece(id, 2, address(proc), ANDNOT);
        vm.expectRevert(LatheOrders.NoSuchPiece.selector);
        lathe.checkPiece(id, 2, 1);
        vm.prank(builder);
        vm.expectRevert(LatheOrders.NoSuchOrder.selector);
        lathe.deliverPiece(999, 0, address(proc), ANDNOT);
    }

    // ---- redelivery ----

    function test_piece_cannotRedeliverAfterPass() public {
        uint256 id = createSmall();
        deliverP(id, 1, address(proc), ANDNOT);
        vm.prank(builder);
        vm.expectRevert(LatheOrders.PieceAlreadyPassed.selector);
        lathe.deliverPiece(id, 1, address(proc), ANDNOT);
    }

    function test_piece_cannotRedeliverWhileChecking() public {
        uint256 id = createSmall();
        deliverP(id, 0, address(fproc), GE22);
        lathe.checkPiece(id, 0, 3);
        vm.prank(builder);
        vm.expectRevert(LatheOrders.NotOpen.selector);
        lathe.deliverPiece(id, 0, address(fproc), GE22_SMALL);
    }

    function test_checkPiece_notDelivered_or_passed_reverts() public {
        uint256 id = createSmall();
        vm.expectRevert(LatheOrders.NotChecking.selector);
        lathe.checkPiece(id, 0, 1);
        deliverP(id, 1, address(proc), ANDNOT);
        vm.expectRevert(LatheOrders.NotChecking.selector);
        lathe.checkPiece(id, 1, 1);
    }

    function test_deliverPiece_inlineWrong_reverts() public {
        uint256 id = createSmall();
        vm.prank(builder);
        vm.expectRevert(abi.encodeWithSelector(LatheOrders.WrongAnswer.selector, 0));
        lathe.deliverPiece(id, 1, address(proc), ANDNOT_WRONG);
        assertEq(procOf(id, 1), address(0));
    }

    // ---- delivery guards reused from V0 ----

    function test_deliverPiece_guards() public {
        uint256 id = createSmall();
        vm.prank(stranger);
        vm.expectRevert(LatheOrders.NotBuilder.selector);
        lathe.deliverPiece(id, 1, address(proc), ANDNOT);

        setCircuitFromTable(30, stranger, 2, 1, hex"02", SMALL);
        vm.prank(builder);
        vm.expectRevert(LatheOrders.NotCircuitOwner.selector);
        lathe.deliverPiece(id, 1, address(proc), 30);

        vm.prank(builder);
        vm.expectRevert(LatheOrders.ShapeMismatch.selector);
        lathe.deliverPiece(id, 1, address(fproc), GE22); // 4 inputs, piece 1 has 2

        vm.prank(builder);
        vm.expectRevert(LatheOrders.NotProcessor.selector);
        lathe.deliverPiece(id, 1, address(usdt), 1);
    }

    function test_deliverPiece_maxGates_perPiece() public {
        Piece[] memory ps = new Piece[](2);
        ps[0] = ge(2, 2);
        ps[1] = tablePiece(2, 1);
        bytes[] memory ts = new bytes[](2);
        ts[1] = hex"02";
        uint32[] memory mg = new uint32[](2);
        mg[0] = 100; // GE22 has 500 gates
        vm.prank(buyer);
        uint256 id = lathe.createPiecedOrder(ps, ts, AMOUNT, deadline, builder, mg, new bytes32[](0));
        assertEq(lathe.pieceMaxGatesOf(id, 0), 100);
        vm.prank(builder);
        vm.expectRevert(LatheOrders.TooManyGates.selector);
        lathe.deliverPiece(id, 0, address(fproc), GE22);
        deliverP(id, 0, address(fproc), GE22_SMALL); // 4 gates: fine
    }

    // ---- griefing ----

    /// Anyone may call checkPiece. Too little gas must revert the call, never mark an honest piece wrong.
    function test_checkPiece_lowGas_reverts_notRejected() public {
        uint256 id = createSmall();
        deliverP(id, 0, address(fproc), GE22); // budget 7.6M per case
        vm.expectRevert(LatheOrders.InsufficientGasForCase.selector);
        lathe.checkPiece{gas: 2_000_000}(id, 0, 16);
        assertEq(procOf(id, 0), address(fproc));
        assertEq(nextOf(id, 0), 0);
        (bool done, bool passed) = lathe.checkPiece(id, 0, 16);
        assertTrue(done && passed);
    }

    // ---- deadline, grace, refund ----

    function test_pieced_midCheckAtDeadline_getsGrace() public {
        uint256 id = createSmall();
        deliverP(id, 1, address(proc), ANDNOT);
        deliverP(id, 0, address(fproc), GE22);
        lathe.checkPiece(id, 0, 5);
        vm.warp(uint256(deadline) + 1);
        vm.prank(buyer);
        vm.expectRevert(LatheOrders.RefundNotAllowed.selector);
        lathe.refund(id);
        vm.warp(uint256(deadline) + lathe.GRACE()); // last second of grace
        vm.prank(buyer);
        vm.expectRevert(LatheOrders.RefundNotAllowed.selector);
        lathe.refund(id);
        (bool done, bool passed) = lathe.checkPiece(id, 0, 100);
        assertTrue(done && passed);
        assertEq(uint8(status(id)), uint8(LatheOrders.Status.Paid));
    }

    function test_pieced_afterGrace_refunds() public {
        uint256 id = createSmall();
        deliverP(id, 1, address(proc), ANDNOT);
        deliverP(id, 0, address(fproc), GE22);
        lathe.checkPiece(id, 0, 5);
        vm.warp(uint256(deadline) + lathe.GRACE() + 1);
        vm.expectRevert(LatheOrders.GraceOver.selector);
        lathe.checkPiece(id, 0, 100);
        uint256 before = usdt.balanceOf(buyer);
        vm.prank(buyer);
        lathe.refund(id);
        assertEq(usdt.balanceOf(buyer), before + AMOUNT);
        assertEq(uint8(status(id)), uint8(LatheOrders.Status.Refunded));
        assertEq(procOf(id, 0), address(0));
        vm.expectRevert(LatheOrders.NotChecking.selector);
        lathe.checkPiece(id, 0, 100);
    }

    /// A piece with no delivery at the deadline can never be delivered, so the order can never pay: the buyer need
    /// not wait out the grace of the other piece.
    function test_pieced_undeliveredPieceAtDeadline_refundsAtOnce() public {
        uint256 id = createSmall();
        deliverP(id, 0, address(fproc), GE22);
        lathe.checkPiece(id, 0, 5);
        vm.warp(uint256(deadline) + 1);
        vm.prank(builder);
        vm.expectRevert(LatheOrders.DeadlinePassed.selector);
        lathe.deliverPiece(id, 1, address(proc), ANDNOT);
        vm.prank(buyer);
        lathe.refund(id);
        assertEq(uint8(status(id)), uint8(LatheOrders.Status.Refunded));
    }

    function test_pieced_refund_rules() public {
        uint256 id = createSmall();
        vm.prank(buyer);
        vm.expectRevert(LatheOrders.RefundNotAllowed.selector);
        lathe.refund(id); // before the deadline
        vm.warp(uint256(deadline) + 1);
        vm.prank(stranger);
        vm.expectRevert(LatheOrders.NotBuyer.selector);
        lathe.refund(id);
        vm.prank(buyer);
        lathe.refund(id);
        vm.prank(buyer);
        vm.expectRevert(LatheOrders.RefundNotAllowed.selector);
        lathe.refund(id); // twice
    }

    function test_pieced_paid_cannotRefund() public {
        uint256 id = createSmall();
        deliverP(id, 0, address(fproc), GE22_SMALL);
        deliverP(id, 1, address(proc), ANDNOT);
        vm.warp(uint256(deadline) + lathe.GRACE() + 1);
        vm.prank(buyer);
        vm.expectRevert(LatheOrders.RefundNotAllowed.selector);
        lathe.refund(id);
    }

    // ---- circuit changes after a piece passed ----

    /// A passed, then its netlist changes before B passes: paying would pay for a circuit nobody checked.
    function test_pay_reverifiesPassedPieces_inline() public {
        uint256 id = createSmall();
        deliverP(id, 0, address(fproc), GE22);
        lathe.checkPiece(id, 0, 100);
        fproc.setNetlist(GE22, hex"beef");
        vm.prank(builder);
        vm.expectRevert(LatheOrders.CircuitChanged.selector);
        lathe.deliverPiece(id, 1, address(proc), ANDNOT);
    }

    function test_pay_reverifiesPassedPieces_viaCheck() public {
        uint256 id = createSmall();
        deliverP(id, 1, address(proc), ANDNOT);
        deliverP(id, 0, address(fproc), GE22);
        lathe.checkPiece(id, 0, 10);
        proc.setGateCount(ANDNOT, 5); // B's gate count changes after B passed
        vm.expectRevert(LatheOrders.CircuitChanged.selector);
        lathe.checkPiece(id, 0, 10);
        // The order cannot pay; the buyer refunds after the grace.
        vm.warp(uint256(deadline) + lathe.GRACE() + 1);
        vm.prank(buyer);
        lathe.refund(id);
        assertEq(uint8(status(id)), uint8(LatheOrders.Status.Refunded));
    }

    function test_checkPiece_circuitChanged_reverts() public {
        uint256 id = createSmall();
        deliverP(id, 0, address(fproc), GE22);
        fproc.setGateCount(GE22, 501);
        vm.expectRevert(LatheOrders.CircuitChanged.selector);
        lathe.checkPiece(id, 0, 10);
    }

    function test_run_twoPiece_circuitChanged_reverts() public {
        uint256 id = createSmall();
        deliverP(id, 0, address(fproc), GE22_SMALL);
        deliverP(id, 1, address(proc), ANDNOT);
        proc.setNetlist(ANDNOT, hex"01");
        vm.expectRevert(LatheOrders.CircuitChanged.selector);
        lathe.run(id, hex"00");
    }

    // ---- receipts and lookups ----

    function test_receipt_twoPiece() public {
        uint256 id = createSmall();
        deliverP(id, 0, address(fproc), GE22_SMALL);
        Piece[] memory ps = new Piece[](2);
        ps[0] = ge(2, 2);
        ps[1] = tablePiece(2, 1);
        bytes[] memory ts = new bytes[](2);
        ts[1] = hex"02";
        bytes32 h = keccak256(abi.encode(ps, ts));
        assertEq(lathe.piecedHash(id), h);
        vm.roll(777);
        vm.expectEmit(true, false, false, true);
        emit LatheOrders.Receipt(id, address(0), 0, h);
        vm.expectEmit(true, true, false, true);
        emit LatheOrders.Paid(id, builder, address(0), 0);
        deliverP(id, 1, address(proc), ANDNOT);
        (address rp, uint256 rid, bytes32 rh, uint64 bn) = lathe.receipts(id);
        assertEq(rp, address(0));
        assertEq(rid, 0);
        assertEq(rh, h);
        assertEq(bn, 777);
        vm.expectRevert(LatheOrders.NoSingleCircuit.selector);
        lathe.ruleOf(id);
        Piece[] memory got = lathe.piecesOf(id);
        assertEq(got.length, 2);
        assertEq(uint8(got[0].kind), uint8(PieceKind.GreaterOrEqual));
        assertEq(got[0].widthA, 2);
        assertEq(got[1].nIn, 2);
        assertEq(lathe.pieceTableOf(id, 1), hex"02");
        assertEq(lathe.pieceTableOf(id, 0), "");
        (address p0, uint256 c0,,,,) = lathe.pieceOf(id, 0);
        assertEq(p0, address(fproc));
        assertEq(c0, GE22_SMALL);
    }

    function test_singleFormulaPiece_ruleOfAndRun() public {
        Piece[] memory ps = new Piece[](1);
        ps[0] = ge(2, 2);
        bytes[] memory ts = new bytes[](1);
        uint256 id = create(ps, ts, new bytes32[](0));
        vm.expectRevert(LatheOrders.NotPaid.selector);
        lathe.ruleOf(id);
        deliverP(id, 0, address(fproc), GE22_SMALL);
        assertEq(uint8(status(id)), uint8(LatheOrders.Status.Paid));
        (address rp, uint256 rid) = lathe.ruleOf(id);
        assertEq(rp, address(fproc));
        assertEq(rid, GE22_SMALL);
        (,, bytes32 rh,) = lathe.receipts(id);
        assertEq(rh, keccak256(abi.encode(ps, ts)));
        assertEq(lathe.run(id, hex"06"), hex"01"); // 0b0110: a = 2 (bits 0-1), b = 1 (bits 2-3), 2 >= 1
        assertEq(lathe.run(id, hex"09"), hex"00"); // 0b1001: a = 1, b = 2
    }

    function test_run_pieced_unpaid_reverts() public {
        uint256 id = createSmall();
        vm.expectRevert(LatheOrders.NotPaid.selector);
        lathe.run(id, hex"00");
        deliverP(id, 0, address(fproc), GE22_SMALL);
        deliverP(id, 1, address(proc), ANDNOT);
        vm.expectRevert(LatheOrders.BadInputs.selector);
        lathe.runStep(id, hex"00", hex"00"); // pieced orders have no memory
    }

    // ---- create validation ----

    function expectCreateRevert(Piece[] memory ps, bytes[] memory ts, bytes4 sel) internal {
        uint32[] memory mg = new uint32[](ps.length);
        vm.prank(buyer);
        vm.expectRevert(sel);
        lathe.createPiecedOrder(ps, ts, AMOUNT, deadline, builder, mg, new bytes32[](0));
    }

    function one(Piece memory p, bytes memory t) internal pure returns (Piece[] memory ps, bytes[] memory ts) {
        ps = new Piece[](1);
        ps[0] = p;
        ts = new bytes[](1);
        ts[0] = t;
    }

    function test_create_validation() public {
        Piece[] memory ps;
        bytes[] memory ts;
        // Add needs widthA >= widthB and nOut = widthA + 1.
        (ps, ts) = one(Piece(PieceKind.Add, 9, 5, 4, 5), "");
        expectCreateRevert(ps, ts, LatheOrders.BadPiece.selector);
        (ps, ts) = one(Piece(PieceKind.Add, 16, 8, 8, 8), "");
        expectCreateRevert(ps, ts, LatheOrders.BadPiece.selector);
        // GreaterOrEqual has 1 output; nIn must equal widthA + widthB; widths must be at least 1.
        (ps, ts) = one(Piece(PieceKind.GreaterOrEqual, 16, 2, 8, 8), "");
        expectCreateRevert(ps, ts, LatheOrders.BadPiece.selector);
        (ps, ts) = one(Piece(PieceKind.GreaterOrEqual, 15, 1, 8, 8), "");
        expectCreateRevert(ps, ts, LatheOrders.BadPiece.selector);
        (ps, ts) = one(Piece(PieceKind.GreaterOrEqual, 8, 1, 8, 0), "");
        expectCreateRevert(ps, ts, LatheOrders.BadPiece.selector);
        // At most 17 inputs.
        (ps, ts) = one(Piece(PieceKind.GreaterOrEqual, 18, 1, 9, 9), "");
        expectCreateRevert(ps, ts, LatheOrders.TooManyCases.selector);
        // Formula pieces carry no table.
        (ps, ts) = one(ge(2, 2), hex"00");
        expectCreateRevert(ps, ts, LatheOrders.WrongTableLength.selector);
        // Table pieces: V0 rules (6 inputs, length, zero padding), no widths.
        (ps, ts) = one(tablePiece(7, 1), new bytes(16));
        expectCreateRevert(ps, ts, LatheOrders.TooManyCases.selector);
        (ps, ts) = one(tablePiece(2, 1), hex"0600");
        expectCreateRevert(ps, ts, LatheOrders.WrongTableLength.selector);
        (ps, ts) = one(tablePiece(2, 1), hex"16");
        expectCreateRevert(ps, ts, LatheOrders.TablePaddingNotZero.selector);
        (ps, ts) = one(Piece(PieceKind.Table, 2, 1, 1, 1), hex"06");
        expectCreateRevert(ps, ts, LatheOrders.BadPiece.selector);
        (ps, ts) = one(tablePiece(2, 0), "");
        expectCreateRevert(ps, ts, LatheOrders.TooManyOutputs.selector);
    }

    function test_create_counts_and_join() public {
        // 0 pieces, 3 pieces, mismatched lengths.
        expectCreateRevert(new Piece[](0), new bytes[](0), LatheOrders.BadPieceCount.selector);
        Piece[] memory ps = new Piece[](3);
        ps[0] = ge(2, 2);
        ps[1] = ge(2, 2);
        ps[2] = ge(2, 2);
        expectCreateRevert(ps, new bytes[](3), LatheOrders.BadPieceCount.selector);
        Piece[] memory p2 = new Piece[](2);
        p2[0] = ge(2, 2);
        p2[1] = tablePiece(2, 1);
        expectCreateRevert(p2, new bytes[](1), LatheOrders.BadPieceCount.selector);
        uint32[] memory mg = new uint32[](1);
        bytes[] memory t2 = new bytes[](2);
        t2[1] = hex"02";
        vm.prank(buyer);
        vm.expectRevert(LatheOrders.BadPieceCount.selector);
        lathe.createPiecedOrder(p2, t2, AMOUNT, deadline, builder, mg, new bytes32[](0));
        // B must take at least A's outputs: Add(2,2) has 3 outputs, B has 2 inputs.
        p2[0] = Piece(PieceKind.Add, 4, 3, 2, 2);
        expectCreateRevert(p2, t2, LatheOrders.BadPiece.selector);
        // V0 terms still apply.
        p2[0] = ge(2, 2);
        mg = new uint32[](2);
        vm.prank(buyer);
        vm.expectRevert(LatheOrders.BuilderRequired.selector);
        lathe.createPiecedOrder(p2, t2, AMOUNT, deadline, address(0), mg, new bytes32[](0));
        vm.prank(buyer);
        vm.expectRevert(LatheOrders.ZeroAmount.selector);
        lathe.createPiecedOrder(p2, t2, 0, deadline, builder, mg, new bytes32[](0));
        vm.prank(buyer);
        vm.expectRevert(LatheOrders.DeadlinePassed.selector);
        lathe.createPiecedOrder(p2, t2, AMOUNT, uint64(block.timestamp), builder, mg, new bytes32[](0));
    }

    function test_create_locksMoney_andShape() public {
        uint256 before = usdt.balanceOf(buyer);
        uint256 id = createTwoOfThree();
        assertEq(usdt.balanceOf(buyer), before - AMOUNT);
        assertEq(usdt.balanceOf(address(lathe)), AMOUNT);
        (address b, address bl, uint96 amt,,,,,, LatheOrders.Status s) = lathe.orders(id);
        assertEq(b, buyer);
        assertEq(bl, builder);
        assertEq(amt, AMOUNT);
        assertEq(uint8(s), uint8(LatheOrders.Status.Open));
        (uint8 nState, uint8 nIn, uint8 nOut) = shape(id);
        assertEq(nIn, 19); // 16 + 4 - 1
        assertEq(nOut, 1);
        assertEq(nState, 0);
        assertEq(lathe.tableOf(id), "");
    }

    function test_pieced_labels() public {
        Piece[] memory ps = new Piece[](2);
        ps[0] = ge(2, 2);
        ps[1] = tablePiece(2, 1);
        bytes[] memory ts = new bytes[](2);
        ts[1] = hex"02";
        bytes32[] memory bad = new bytes32[](4);
        uint32[] memory mg = new uint32[](2);
        vm.prank(buyer);
        vm.expectRevert(LatheOrders.WrongLabelCount.selector);
        lathe.createPiecedOrder(ps, ts, AMOUNT, deadline, builder, mg, bad);
        bytes32[] memory good = new bytes32[](5);
        good[0] = "a0";
        good[4] = "veto";
        uint256 id = create(ps, ts, good);
        bytes32[] memory got = lathe.labelsOf(id);
        assertEq(got.length, 5);
        assertEq(got[4], bytes32("veto"));
    }
}

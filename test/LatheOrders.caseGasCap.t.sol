// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {WiredBase} from "./WiredBase.sol";
import {LatheOrders} from "../src/LatheOrders.sol";
import {Piece} from "../src/FormulaLib.sol";
import {Wire} from "../src/NetlistLib.sol";

/// @notice A buyer's gate cap keeps its old promise when the builder declares a per-case gas.
///
/// Before the declared per-case gas existed, an order whose gate cap keeps cases x evalBudget(cap) <= 30M
/// (INLINE_CHECK_MAX_GAS) was always checked inside deliver: a wrong circuit reverted and could never hold the
/// order. The review of e31f19f found that a declared value (for example 100M) pushed such an order into batched
/// checks, so a junk circuit wrong only at its last case sat in Checking and the buyer could not refund until
/// deadline + GRACE unless someone paid for 64 large check transactions (repro: ReviewGrief.t.sol). Now deliver
/// and deliverPiece refuse that declared value (CaseGasTooHigh). Uncapped orders, and capped orders whose formula
/// budget already needs batched checks, accept a declared value as before.
contract LatheOrdersCaseGasCapTest is WiredBase {
    uint256 constant GOOD = 80; // 6 inputs, parity, 24 gates
    uint256 constant JUNK = 81; // the same, wrong only at case 63
    uint256 constant BIG = 82; // 6 inputs, parity, 500 gates (formula 7.6M: 64 cases need batches)
    uint256 constant MEM = 83; // memory toggle, 1 input + 1 memory bit, 400 gates
    uint32 constant CAP = 24; // 64 x evalBudget(24) = 64 x 460,000 = 29.44M: inline at the formula budget
    uint32 constant LIMIT = 468_750; // 30M / 64: the most a 64-case capped order accepts

    function setUp() public override {
        super.setUp();
        bytes memory par = parityTable();
        setCircuitFromTable(GOOD, builder, 6, 1, par, CAP);
        setCircuitFromTable(JUNK, builder, 6, 1, par, CAP);
        proc.setOut(JUNK, 63, hex"01"); // parity(63) = 0; answer 1
        setCircuitFromTable(BIG, builder, 6, 1, par, 500);
        setStatefulCircuitFromTable(MEM, builder, 1, 1, 1, hex"3c", 400);
    }

    function _st(uint256 o) internal view returns (uint8) {
        return uint8(status(o));
    }

    function _capped(uint32 cap) internal returns (uint256) {
        vm.prank(buyer);
        return lathe.createOrder(6, 1, parityTable(), AMOUNT, uint64(block.timestamp + 1 days), builder, cap);
    }

    function _deliver(uint256 o, uint256 id, uint32 g) internal {
        vm.prank(builder);
        lathe.deliver(o, address(proc), id, g);
    }

    /// The reviewer's grief repro in its fixed form. Before this fix the 100M delivery was recorded (Checking) and
    /// the buyer's refund at deadline + 1 s reverted RefundNotAllowed.
    function test_gateCap_griefRepro_declaredRefused() public {
        uint256 o = _capped(CAP);
        vm.prank(builder);
        vm.expectRevert(abi.encodeWithSelector(LatheOrders.WrongAnswer.selector, 63));
        lathe.deliver(o, address(proc), JUNK);

        vm.prank(builder);
        vm.expectRevert(LatheOrders.CaseGasTooHigh.selector);
        lathe.deliver(o, address(proc), JUNK, 100_000_000);
        assertEq(_st(o), 0, "still Open");

        // One gas above the share: refused. At the share: checked inline, so junk still reverts.
        vm.prank(builder);
        vm.expectRevert(LatheOrders.CaseGasTooHigh.selector);
        lathe.deliver(o, address(proc), JUNK, LIMIT + 1);
        vm.prank(builder);
        vm.expectRevert(abi.encodeWithSelector(LatheOrders.WrongAnswer.selector, 63));
        lathe.deliver(o, address(proc), JUNK, LIMIT);

        // The buyer refunds right after the deadline, as before the declared gas existed.
        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(buyer);
        lathe.refund(o);
        assertEq(_st(o), 3, "refunded");
    }

    /// An honest circuit on a capped order can still declare up to its share and is paid inline.
    function test_gateCap_declaredAtShare_paysInline() public {
        uint256 o = _capped(CAP);
        _deliver(o, GOOD, LIMIT);
        assertEq(_st(o), 2, "paid inside deliver");
        assertEq(lathe.caseGasOf(o), LIMIT);
    }

    /// No gate cap: no promise, so a declared value that forces batches is accepted (unchanged behaviour).
    function test_gateCap_uncapped_acceptsDeclared() public {
        uint256 o = _capped(0);
        _deliver(o, JUNK, 100_000_000);
        assertEq(_st(o), 1, "Checking");
        assertEq(lathe.caseGasOf(o), 100_000_000);
    }

    /// A cap whose formula budget already needs batched checks promised no inline check: a declared value is
    /// accepted.
    function test_gateCap_formulaAlreadyBatched_acceptsDeclared() public {
        uint256 o = _capped(500); // 64 x 7.6M > 30M
        _deliver(o, BIG, 10_000_000);
        assertEq(_st(o), 1, "Checking");
        assertEq(lathe.caseGasOf(o), 10_000_000);
        // The cap counts, not the circuit's gates: GOOD (24 gates) on a 500-gate cap is batched too.
        uint256 p = _capped(500);
        _deliver(p, GOOD, 1_000_000);
        assertEq(_st(p), 1, "Checking");
    }

    // ---- memory orders: cases = 2^(nIn + nState) ----

    function _mem(uint32 cap) internal returns (uint256) {
        vm.prank(buyer);
        return lathe.createStatefulOrder(1, 1, 1, hex"3c", AMOUNT, uint64(block.timestamp + 1 days), builder, cap);
    }

    function test_gateCap_memory() public {
        // cap 400: 4 x 6.1M = 24.4M, inline. Share 7.5M.
        uint256 o = _mem(400);
        vm.prank(builder);
        vm.expectRevert(LatheOrders.CaseGasTooHigh.selector);
        lathe.deliver(o, address(proc), MEM, 7_500_001);
        _deliver(o, MEM, 7_500_000);
        assertEq(_st(o), 2, "paid inline");
        // cap 500: 4 x 7.6M > 30M, batched already: accepted.
        uint256 p = _mem(500);
        _deliver(p, MEM, 9_000_000);
        assertEq(_st(p), 1, "Checking");
    }

    // ---- pieces: cases = 2^piece.nIn, cap = pieceMaxGatesOf ----

    function _pieced(uint32 cap) internal returns (uint256) {
        Piece[] memory ps = new Piece[](1);
        ps[0] = tablePiece(6, 1);
        bytes[] memory ts = new bytes[](1);
        ts[0] = parityTable();
        Wire[] memory ws = new Wire[](7);
        for (uint8 j = 0; j < 6; ++j) {
            ws[j] = w(TOP, j, 0, j);
        }
        ws[6] = w(0, 0, TOP, 0);
        LatheOrders.PiecedSpec memory s = spec(ps, ts, ws, false);
        s.maxGates[0] = cap;
        vm.prank(buyer);
        return lathe.createPiecedOrder(s, AMOUNT, deadline, builder);
    }

    function test_gateCap_piece() public {
        uint256 o = _pieced(CAP);
        vm.prank(builder);
        vm.expectRevert(LatheOrders.CaseGasTooHigh.selector);
        lathe.deliverPiece(o, 0, address(proc), JUNK, 100_000_000);
        vm.prank(builder);
        vm.expectRevert(abi.encodeWithSelector(LatheOrders.WrongAnswer.selector, 63));
        lathe.deliverPiece(o, 0, address(proc), JUNK, LIMIT);
        vm.prank(builder);
        lathe.deliverPiece(o, 0, address(proc), GOOD, LIMIT);
        assertEq(_st(o), 2, "paid inline");

        uint256 u = _pieced(0);
        vm.prank(builder);
        lathe.deliverPiece(u, 0, address(proc), JUNK, 100_000_000);
        (address p,,,,,) = lathe.pieceOf(u, 0);
        assertEq(p, address(proc), "uncapped piece: recorded for batched checks");

        uint256 b = _pieced(500);
        vm.prank(builder);
        lathe.deliverPiece(b, 0, address(proc), BIG, 10_000_000);
        assertEq(lathe.pieceCaseGasOf(b, 0), 10_000_000, "formula already batched: accepted");
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {WiredBase} from "./WiredBase.sol";
import {LatheOrders} from "../src/LatheOrders.sol";
import {Piece} from "../src/FormulaLib.sol";
import {Wire} from "../src/NetlistLib.sol";
import {IProcessor} from "../src/ITapeOut.sol";

/// @notice The builder-declared per-case gas (deliver / deliverPiece with caseGas), and the bug it fixes.
///
/// The bug (final review, 2026-11-21; real-TapeOut reproduction in test/fork/CaseGasSplit.fork.t.sol): each case
/// gets a fixed gas budget, and the first case of every transaction costs more because the circuits it calls are
/// cold (EIP-2929). Anyone chooses where a check transaction starts. So a circuit close to its budget could be paid
/// when checked in one transaction and rejected when a stranger moved the cursor to an expensive case and then
/// checked that case alone.
///
/// The mock here behaves like that: circuit COLD reads 50 storage slots nothing else touches on every call (about
/// 105,000 gas when cold, 5,000 when warm) and burns 420,000 gas, except case 0, which burns 280,000. Its formula
/// budget is 475,000 (25 gates). So case 0 fits even cold, every case fits warm, and any case but 0 run first in a
/// transaction does not fit. This repo's forge runs with isolate = true (each external call from a test is its
/// own transaction, so starts cold); vm.cool(proc) in _newTx makes that explicit and keeps the tests right under
/// --isolate false as well.
contract LatheOrdersCaseGasTest is WiredBase {
    uint256 constant COLD = 50; // 6 inputs, parity, 25 gates (formula 475,000), cold-sensitive
    uint256 constant COLD_WRONG = 51; // the same, wrong in case 40
    uint256 constant COLD_MEM = 52; // memory toggle (1 input, 1 memory bit), 500 gates, cold-sensitive
    uint256 constant HEAVY = 53; // 6 inputs, parity, 25 gates, burns 780,000 on every case
    uint32 constant COLD_GATES = 25;
    uint32 constant DECLARED = 600_000;
    uint32 constant DECLARED_MEM = 8_000_000;
    uint256 constant BIG_GAS = 200_000_000;
    uint256 constant MAX = 100_000_000; // LatheOrders.MAX_CASE_GAS (a constant here: a call would eat vm.prank)

    GasMeter meter;

    function setUp() public override {
        super.setUp();
        meter = new GasMeter();
        bytes memory par = parityTable();
        setCircuitFromTable(COLD, builder, 6, 1, par, COLD_GATES);
        _makeCold(COLD, 50, 420_000, 280_000);
        setCircuitFromTable(COLD_WRONG, builder, 6, 1, par, COLD_GATES);
        proc.setOut(COLD_WRONG, 40, hex"01"); // parity(40) = 0b101000 -> 0; answer 1 instead
        _makeCold(COLD_WRONG, 50, 420_000, 280_000);
        setStatefulCircuitFromTable(COLD_MEM, builder, 1, 1, 1, hex"3c", BATCHED_GATES);
        _makeCold(COLD_MEM, 100, 7_500_000, 7_300_000);
        setCircuitFromTable(HEAVY, builder, 6, 1, par, COLD_GATES);
        proc.setEvalGasCost(HEAVY, 780_000);
    }

    function _makeCold(uint256 id, uint256 slots, uint256 cost, uint256 case0) internal {
        proc.setColdSlots(id, slots);
        proc.setEvalGasCost(id, cost);
        proc.setCaseGasCost(id, 0, case0);
    }

    /// A new transaction, as far as warm and cold storage go.
    function _newTx() internal {
        vm.cool(address(proc));
        vm.cool(address(lathe));
    }

    function _order() internal returns (uint256) {
        return createParity();
    }

    function _deliver(uint256 o, uint256 id, uint32 caseGas) internal {
        vm.prank(builder);
        if (caseGas == 0) lathe.deliver(o, address(proc), id);
        else lathe.deliver(o, address(proc), id, caseGas);
    }

    /// One check transaction, from a stranger, from a cold start.
    function _check(uint256 o, uint256 n) internal returns (bool done, bool passed) {
        _newTx();
        vm.prank(stranger);
        return lathe.check{gas: BIG_GAS}(o, n);
    }

    function _checkPiece(uint256 o, uint256 i, uint256 n) internal returns (bool done, bool passed) {
        _newTx();
        vm.prank(stranger);
        return lathe.checkPiece{gas: BIG_GAS}(o, i, n);
    }

    function _evalGas(uint256 id, uint256 c) internal returns (uint256 used, bool ok) {
        (used, ok,) = meter.twice(address(proc), id, c);
    }

    /// The fixture really behaves as described: cold case 7 above the formula, warm case 7 and cold case 0 below.
    function test_fixture_coldFirstCaseCostsMore() public {
        uint256 budget = lathe.evalBudget(COLD_GATES);
        assertEq(budget, 475_000);
        _newTx();
        (uint256 cold7,, uint256 warm7) = meter.twice(address(proc), COLD, 7);
        _newTx();
        (uint256 cold0,,) = meter.twice(address(proc), COLD, 0);
        emit log_named_uint("cold case 7", cold7);
        emit log_named_uint("warm case 7", warm7);
        emit log_named_uint("cold case 0", cold0);
        assertGt(cold7, budget, "cold case 7 needs more than the formula");
        assertLt(warm7 + 20_000, budget, "warm case 7 fits with room");
        assertLt(cold0 + 20_000, budget, "cold case 0 fits with room");
        assertLt(cold7 * 64 / 63 + 20_000, DECLARED, "the declared gas covers the cold case with a margin");
    }

    // ---- the bug, and the fix ----

    /// The bug, kept as a regression: with the formula budget the verdict depends on where a transaction starts.
    /// check(64) in one transaction pays; a stranger's check(7) then check(1) rejects the same honest circuit.
    function test_formulaBudget_verdictDependsOnSplit() public {
        uint256 a = _order();
        _deliver(a, COLD, 0);
        assertEq(uint8(status(a)), 1, "batched, not inline");
        (bool done, bool passed) = _check(a, 64);
        assertTrue(done && passed, "one transaction: paid");

        uint256 b = _order();
        _deliver(b, COLD, 0);
        (done,) = _check(b, 7);
        assertFalse(done, "cases 0..6 pass");
        uint256 before = usdt.balanceOf(builder);
        vm.expectEmit(true, false, false, true, address(lathe));
        emit LatheOrders.Rejected(b, 7);
        (done, passed) = _check(b, 1);
        assertTrue(done && !passed, "case 7 alone: rejected");
        assertEq(uint8(status(b)), 0, "order back to Open");
        assertEq(usdt.balanceOf(builder), before, "builder not paid");
        assertEq(usdt.balanceOf(address(lathe)), AMOUNT + lathe.feesOwed(), "buyer's money still held");
    }

    /// The fix: with a declared per-case gas, every split pays, whoever starts each transaction.
    function test_declared_everySplitPays() public {
        uint256[5] memory splits = [uint256(7), 1, 13, 2, 41];
        uint256 b = _order();
        _deliver(b, COLD, DECLARED);
        assertEq(lathe.caseGasOf(b), DECLARED);
        assertEq(uint8(status(b)), 1, "64 x 600,000 > 30M: batched");
        bool done;
        bool passed;
        for (uint256 k = 0; k < splits.length; ++k) {
            (done, passed) = _check(b, splits[k]);
        }
        assertTrue(done && passed, "paid");
        assertEq(uint8(status(b)), 2);
        assertEq(usdt.balanceOf(builder), AMOUNT - AMOUNT / 100);
    }

    /// Every single-case start: each case run first in its own transaction passes with the declared gas.
    function test_declared_eachCaseAloneInItsTransaction() public {
        uint256 b = _order();
        _deliver(b, COLD, DECLARED);
        bool done;
        bool passed;
        for (uint256 c = 0; c < 64; ++c) {
            (done, passed) = _check(b, 1);
            assertTrue(c == 63 ? (done && passed) : !done, "no case rejected");
        }
        assertEq(uint8(status(b)), 2);
    }

    // ---- what the new knob can and cannot do (item 3 of the fix brief) ----

    /// caseGas below the formula, or 0, gives the formula: the old three-argument deliver is caseGas 0.
    function test_caseGas_belowFormula_isFormula() public {
        uint256 a = _order();
        _deliver(a, COLD, 0);
        assertEq(lathe.caseGasOf(a), lathe.evalBudget(COLD_GATES));
        uint256 b = _order();
        _deliver(b, COLD, 1);
        assertEq(lathe.caseGasOf(b), lathe.evalBudget(COLD_GATES));
        assertEq(lathe.caseGasOf(999), 0, "no delivery: 0");
    }

    /// Above MAX_CASE_GAS: CaseGasTooHigh. Exactly MAX_CASE_GAS is accepted, and one case of it still fits one
    /// transaction: a checker sends about 101.6M gas for check(id, 1), under the X Layer block limit of 210M.
    function test_caseGas_capBoundsATransaction() public {
        uint256 o = _order();
        vm.prank(builder);
        vm.expectRevert(LatheOrders.CaseGasTooHigh.selector);
        lathe.deliver(o, address(proc), COLD, uint32(MAX + 1));
        vm.prank(builder);
        vm.expectRevert(LatheOrders.CaseGasTooHigh.selector);
        lathe.deliver(o, address(proc), COLD, type(uint32).max);

        vm.prank(builder);
        lathe.deliver(o, address(proc), COLD, uint32(MAX));
        assertEq(lathe.caseGasOf(o), 100_000_000);
        // Less than the hold for one case: the call reverts, nothing changes, no case is judged.
        _newTx();
        vm.prank(stranger);
        (bool ok, bytes memory ret) =
            address(lathe).call{gas: 100_000_000}(abi.encodeCall(lathe.check, (o, 1)));
        assertFalse(ok);
        assertEq(bytes4(ret), LatheOrders.InsufficientGasForCase.selector);
        (,,,,, uint32 next) = lathe.deliveries(o);
        assertEq(next, 0, "cursor unchanged");
        // One case per transaction with 110M gas works.
        _newTx();
        vm.prank(stranger);
        lathe.check{gas: 110_000_000}(o, 1);
        (,,,,, next) = lathe.deliveries(o);
        assertEq(next, 1);
    }

    /// A huge caseGas cannot harm the buyer: the money stays locked for the order, a checker with too little gas
    /// changes nothing, and if nobody finishes the check the buyer refunds after deadline + GRACE as before.
    function test_hugeCaseGas_buyerRefundsAsBefore() public {
        uint256 o = _order();
        vm.prank(builder);
        lathe.deliver(o, address(proc), COLD, uint32(MAX));
        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(buyer);
        vm.expectRevert(LatheOrders.RefundNotAllowed.selector);
        lathe.refund(o); // in the grace period, as for any delivery being checked
        vm.warp(block.timestamp + 1 days);
        uint256 y0 = usdt.balanceOf(buyer);
        vm.prank(buyer);
        lathe.refund(o);
        assertEq(usdt.balanceOf(buyer) - y0, AMOUNT);
        assertEq(lathe.caseGasOf(o), 0, "cleared");
    }

    /// A huge caseGas cannot make a wrong circuit pass: the answers are compared as before.
    function test_hugeCaseGas_wrongCircuitStillRejected() public {
        uint256 o = _order();
        _deliver(o, COLD_WRONG, uint32(MAX));
        bool done;
        bool passed;
        for (uint256 k = 0; k < 64 && !done; ++k) {
            _newTx();
            vm.prank(stranger);
            (done, passed) = lathe.check{gas: 110_000_000}(o, 1);
        }
        assertTrue(done && !passed, "rejected");
        (,,,,, uint32 next) = lathe.deliveries(o);
        assertEq(next, 0, "delivery cleared");
        assertEq(uint8(status(o)), 0);
    }

    /// The same for an inline check: a wrong circuit with a declared caseGas that still fits inline reverts.
    function test_declared_inline_wrongReverts_rightPays() public {
        vm.prank(buyer);
        uint256 o = lathe.createOrder(2, 1, xorTable(), AMOUNT, uint64(block.timestamp + 1 days), builder, 0);
        setCircuitFromTable(60, builder, 2, 1, hex"07", 4); // NAND: wrong at case 0
        setCircuitFromTable(61, builder, 2, 1, xorTable(), 4);
        vm.prank(builder);
        vm.expectRevert(abi.encodeWithSelector(LatheOrders.WrongAnswer.selector, uint256(0)));
        lathe.deliver(o, address(proc), 60, 7_000_000); // 4 x 7M = 28M: inline
        vm.prank(builder);
        lathe.deliver(o, address(proc), 61, 7_000_000);
        assertEq(uint8(status(o)), 2, "paid inline");
        // 4 x 7.6M > 30M: recorded and checked with check instead.
        vm.prank(buyer);
        uint256 o2 = lathe.createOrder(2, 1, xorTable(), AMOUNT, uint64(block.timestamp + 1 days), builder, 0);
        vm.prank(builder);
        lathe.deliver(o2, address(proc), 61, 7_600_000);
        assertEq(uint8(status(o2)), 1, "batched");
    }

    /// A rejected delivery clears the stored per-case gas, so the redelivery chooses a new one.
    function test_rejected_clearsCaseGas_redeliveryChoosesNew() public {
        uint256 o = _order();
        _deliver(o, COLD, 0);
        _check(o, 7);
        (bool done, bool passed) = _check(o, 1);
        assertTrue(done && !passed);
        assertEq(lathe.caseGasOf(o), 0, "cleared with the delivery");
        _deliver(o, COLD, DECLARED);
        assertEq(lathe.caseGasOf(o), DECLARED);
        _check(o, 7);
        (done, passed) = _check(o, 57);
        assertTrue(done && passed);
    }

    /// The changed-circuit check does not depend on caseGas: a change after delivery is still CircuitChanged.
    function test_caseGas_circuitChangedStillRefused() public {
        uint256 o = _order();
        _deliver(o, COLD, DECLARED);
        proc.setNetlist(COLD, hex"deadbeef");
        _newTx();
        vm.expectRevert(LatheOrders.CircuitChanged.selector);
        lathe.check{gas: BIG_GAS}(o, 1);
    }

    /// The receipt does not depend on caseGas: the same rule paid with two different declared values has the same
    /// receipt fingerprint and names the same circuit.
    function test_caseGas_receiptUnchanged() public {
        uint256 a = _order();
        _deliver(a, COLD, DECLARED);
        _check(a, 64);
        uint256 b = _order();
        _deliver(b, COLD, 2 * DECLARED);
        _check(b, 64);
        (address pa, uint256 ia, bytes32 ha,) = lathe.receipts(a);
        (address pb, uint256 ib, bytes32 hb,) = lathe.receipts(b);
        assertEq(pa, pb);
        assertEq(ia, ib);
        assertEq(ha, hb);
        assertTrue(ha != bytes32(0));
    }

    /// deliveries(id) keeps its six fields; the per-case gas is read separately.
    function test_getters_shapeUnchanged() public {
        uint256 o = _order();
        _deliver(o, COLD, DECLARED);
        (address p, uint256 id, address who, uint32 gates, bytes32 h, uint32 next) = lathe.deliveries(o);
        assertEq(p, address(proc));
        assertEq(id, COLD);
        assertEq(who, builder);
        assertEq(gates, COLD_GATES);
        assertEq(h, keccak256(proc.netlist(COLD)));
        assertEq(next, 0);
        (bool ok, bytes memory ret) = address(lathe).staticcall(abi.encodeWithSignature("deliveries(uint256)", o));
        assertTrue(ok);
        assertEq(ret.length, 6 * 32, "six words, as before");
    }

    /// run on a paid order gives the circuit the declared per-case gas, not the formula.
    function test_run_usesDeclaredGas() public {
        uint256 o = _order();
        _deliver(o, HEAVY, 900_000);
        _check(o, 64);
        assertEq(uint8(status(o)), 2);
        for (uint256 c = 0; c < 64; c += 9) {
            bytes memory out = lathe.run{gas: 5_000_000}(o, abi.encodePacked(uint8(c)));
            assertEq(uint8(out[0]), uint8(parityTable()[c / 8]) >> (c % 8) & 1);
        }
        // Gas for the formula's hold but not the declared one: refused, never an answer.
        (bool ok, bytes memory ret) =
            address(lathe).staticcall{gas: 700_000}(abi.encodeCall(lathe.run, (o, hex"07")));
        assertFalse(ok);
        assertEq(bytes4(ret), LatheOrders.InsufficientGasForCase.selector);
    }

    // ---- memory orders (step) ----

    function _memOrder() internal returns (uint256) {
        vm.prank(buyer);
        return lathe.createStatefulOrder(1, 1, 1, hex"3c", AMOUNT, uint64(block.timestamp + 1 days), builder, 0);
    }

    function test_memory_formulaSplitRejects_declaredPays() public {
        uint256 a = _memOrder();
        _deliver(a, COLD_MEM, 0);
        (bool done, bool passed) = _check(a, 4);
        assertTrue(done && passed, "one transaction: paid");

        uint256 b = _memOrder();
        _deliver(b, COLD_MEM, 0);
        _check(b, 2);
        (done, passed) = _check(b, 1);
        assertTrue(done && !passed, "case 2 alone: rejected");

        uint256 c = _memOrder();
        _deliver(c, COLD_MEM, DECLARED_MEM);
        assertEq(lathe.caseGasOf(c), DECLARED_MEM);
        _check(c, 2);
        _check(c, 1);
        (done, passed) = _check(c, 1);
        assertTrue(done && passed, "declared: paid");
        (bytes memory s, bytes memory out) = lathe.runStep{gas: 20_000_000}(c, hex"01", hex"01");
        assertEq(uint8(s[0]), 0);
        assertEq(uint8(out[0]), 0);
        (bool ok, bytes memory ret) =
            address(lathe).staticcall{gas: 8_000_000}(abi.encodeCall(lathe.runStep, (c, hex"01", hex"01")));
        assertFalse(ok, "under the declared hold: refused");
        assertEq(bytes4(ret), LatheOrders.InsufficientGasForCase.selector);
    }

    // ---- pieces ----

    function _pieceOrder(bool top) internal returns (uint256) {
        Piece[] memory ps = new Piece[](1);
        ps[0] = tablePiece(6, 1);
        bytes[] memory ts = new bytes[](1);
        ts[0] = parityTable();
        Wire[] memory ws = new Wire[](7);
        for (uint8 j = 0; j < 6; ++j) {
            ws[j] = w(TOP, j, 0, j);
        }
        ws[6] = w(0, 0, TOP, 0);
        return createWired(ps, ts, ws, top);
    }

    function test_piece_formulaSplitRejects_declaredPays() public {
        uint256 a = _pieceOrder(false);
        deliverP(a, 0, address(proc), COLD);
        assertEq(lathe.pieceCaseGasOf(a, 0), lathe.evalBudget(COLD_GATES));
        _checkPiece(a, 0, 7);
        (bool done, bool passed) = _checkPiece(a, 0, 1);
        assertTrue(done && !passed, "formula: rejected at the split");
        assertEq(lathe.pieceCaseGasOf(a, 0), 0, "cleared");

        vm.prank(builder);
        lathe.deliverPiece(a, 0, address(proc), COLD, DECLARED);
        assertEq(lathe.pieceCaseGasOf(a, 0), DECLARED);
        _checkPiece(a, 0, 7);
        _checkPiece(a, 0, 1);
        _checkPiece(a, 0, 13);
        (done, passed) = _checkPiece(a, 0, 64);
        assertTrue(done && passed);
        assertEq(uint8(status(a)), 2, "paid");
        bytes memory out = lathe.run{gas: 5_000_000}(a, hex"07");
        assertEq(uint8(out[0]), 1);
    }

    function test_piece_caseGasTooHigh() public {
        uint256 a = _pieceOrder(false);
        vm.prank(builder);
        vm.expectRevert(LatheOrders.CaseGasTooHigh.selector);
        lathe.deliverPiece(a, 0, address(proc), COLD, 100_000_001);
    }

    /// A top circuit's run budget covers its pieces' declared per-case gas. HEAVY burns 780,000 on every case,
    /// above both its own formula (475,000) and the top's formula (100,000 + 15,000 x 25 + 150,000 = 625,000), so
    /// it is delivered with caseGas 900,000 and the top gets 625,000 + (900,000 - 475,000) = 1,050,000.
    function test_top_runBudgetCoversPiecesDeclaredGas() public {
        (uint256 heavy,) = _evalGas(HEAVY, 7);
        uint256 topFormula = lathe.evalBudget(COLD_GATES) + lathe.EVAL_GAS_PER_REF();
        assertGt(heavy, topFormula, "the top's formula alone would be too small");

        uint256 o = _pieceOrder(true);
        vm.prank(builder);
        lathe.deliverPiece(o, 0, address(proc), HEAVY, 900_000);
        for (uint256 k = 0; k < 64; k += 16) {
            _checkPiece(o, 0, 16);
        }
        uint256 top = mintTop(o, builder);
        vm.prank(builder);
        lathe.deliverTop(o, address(rproc), top);
        assertEq(uint8(status(o)), 2);
        assertEq(lathe.caseGasOf(o), 0, "a top has no per-case gas");
        for (uint256 c = 0; c < 64; c += 7) {
            bytes memory out = lathe.run{gas: 5_000_000}(o, abi.encodePacked(uint8(c)));
            assertEq(uint8(out[0]), uint8(parityTable()[c / 8]) >> (c % 8) & 1, "right answer");
        }
        // Enough for the top's formula hold, not for the raised one: refused.
        (bool ok, bytes memory ret) =
            address(lathe).staticcall{gas: 900_000}(abi.encodeCall(lathe.run, (o, hex"07")));
        assertFalse(ok);
        assertEq(bytes4(ret), LatheOrders.InsufficientGasForCase.selector);
    }

    /// With no declared gas, a top's run budget is exactly what it was before (the formula): the existing top
    /// tests and web/gas.js runTopGasLimit still describe it.
    function test_top_noDeclared_budgetUnchanged() public {
        uint256 o = _pieceOrder(true);
        setCircuitFromTable(70, builder, 6, 1, parityTable(), 4);
        deliverP(o, 0, address(proc), 70);
        uint256 top = mintTop(o, builder);
        vm.prank(builder);
        lathe.deliverTop(o, address(rproc), top);
        assertEq(lathe.pieceCaseGasOf(o, 0), lathe.evalBudget(4));
        bytes memory out = lathe.run{gas: 2_000_000}(o, hex"07");
        assertEq(uint8(out[0]), 1);
    }
}

/// Gas one eval uses, run twice in one call: the first finds the circuit's storage cold, the second warm.
contract GasMeter {
    function twice(address p, uint256 id, uint256 c) external view returns (uint256 first, bool ok, uint256 second) {
        bytes memory cd = abi.encodeCall(IProcessor.eval, (id, abi.encodePacked(uint8(c))));
        uint256 g0 = gasleft();
        (ok,) = p.staticcall{gas: 5_000_000}(cd);
        first = g0 - gasleft();
        g0 = gasleft();
        p.staticcall{gas: 5_000_000}(cd);
        second = g0 - gasleft();
    }
}

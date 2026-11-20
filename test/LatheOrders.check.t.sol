// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {LatheBase} from "./LatheBase.sol";
import {LatheOrders} from "../src/LatheOrders.sol";
import {MockProcessor} from "./mocks/MockProcessor.sol";

contract LatheOrdersCheckTest is LatheBase {
    uint256 constant XOR_ID = 1;
    uint256 constant PAR_ID = 2;

    function setUp() public override {
        super.setUp();
        setCircuitFromTable(XOR_ID, builder, 2, 1, xorTable(), 4);
        setCircuitFromTable(PAR_ID, builder, 6, 1, parityTable(), 20);
    }

    function status(uint256 id) internal view returns (LatheOrders.Status s) {
        (,,,,,,,, s) = lathe.orders(id);
    }

    function deliverXor(uint256 id) internal {
        vm.prank(builder);
        lathe.deliver(id, address(proc), XOR_ID);
    }

    // ---- deliver ----

    /// Review Focus 1: someone else submits the honest builder's passing circuit to take the pay.
    function test_deliver_requiresOwner() public {
        uint256 id = createXor();
        vm.prank(stranger);
        vm.expectRevert(LatheOrders.NotCircuitOwner.selector);
        lathe.deliver(id, address(proc), XOR_ID);
    }

    /// Hole: ownerOf reverts for an id that does not exist; deliver must fail cleanly, not bubble junk.
    function test_deliver_nonexistentCircuit_reverts() public {
        uint256 id = createXor();
        vm.prank(builder);
        vm.expectRevert(LatheOrders.NotCircuitOwner.selector);
        lathe.deliver(id, address(proc), 999);
    }

    function test_deliver_rejectsFakeProcessor() public {
        uint256 id = createXor();
        MockProcessor fake = new MockProcessor();
        fake.setCircuit(XOR_ID, builder, 2, 1, 0, 4);
        vm.prank(builder);
        vm.expectRevert(LatheOrders.NotProcessor.selector);
        lathe.deliver(id, address(fake), XOR_ID);
    }

    function test_deliver_rejectsShapeMismatch() public {
        uint256 id = createXor();
        proc.setCircuit(7, builder, 3, 1, 0, 4); // wrong nIn
        proc.setCircuit(8, builder, 2, 2, 0, 4); // wrong nOut
        proc.setCircuit(9, builder, 2, 1, 1, 4); // has memory
        vm.startPrank(builder);
        vm.expectRevert(LatheOrders.ShapeMismatch.selector);
        lathe.deliver(id, address(proc), 7);
        vm.expectRevert(LatheOrders.ShapeMismatch.selector);
        lathe.deliver(id, address(proc), 8);
        vm.expectRevert(LatheOrders.ShapeMismatch.selector);
        lathe.deliver(id, address(proc), 9);
        vm.stopPrank();
    }

    function test_deliver_rejectsOverMaxGates() public {
        vm.prank(buyer);
        uint256 id = lathe.createOrder(2, 1, xorTable(), AMOUNT, uint64(block.timestamp + 1 days), address(0), 3);
        vm.prank(builder);
        vm.expectRevert(LatheOrders.TooManyGates.selector);
        lathe.deliver(id, address(proc), XOR_ID); // 4 gates > 3
        // exactly at the cap is fine
        proc.setGateCount(XOR_ID, 3);
        vm.prank(builder);
        lathe.deliver(id, address(proc), XOR_ID);
        assertEq(uint8(status(id)), uint8(LatheOrders.Status.Checking));
    }

    function test_deliver_whileChecking_reverts() public {
        uint256 id = createXor();
        deliverXor(id);
        vm.prank(builder);
        vm.expectRevert(LatheOrders.NotOpen.selector);
        lathe.deliver(id, address(proc), XOR_ID);
    }

    function test_deliver_namedBuilderOnly() public {
        vm.prank(buyer);
        uint256 id = lathe.createOrder(2, 1, xorTable(), AMOUNT, uint64(block.timestamp + 1 days), builder, 0);
        proc.setCircuit(5, stranger, 2, 1, 0, 4);
        vm.prank(stranger);
        vm.expectRevert(LatheOrders.NotBuilder.selector);
        lathe.deliver(id, address(proc), 5);
        deliverXor(id);
    }

    /// Hole: an order id that was never created reads as status Open (enum default). It must not accept a delivery.
    function test_deliver_nonexistentOrder_reverts() public {
        vm.prank(builder);
        vm.expectRevert(LatheOrders.NoSuchOrder.selector);
        lathe.deliver(42, address(proc), XOR_ID);
    }

    function test_deliver_afterDeadline_reverts() public {
        uint256 id = createXor();
        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(builder);
        vm.expectRevert(LatheOrders.DeadlinePassed.selector);
        lathe.deliver(id, address(proc), XOR_ID);
    }

    function test_deliver_recordsCircuit() public {
        uint256 id = createXor();
        deliverXor(id);
        (address p, uint256 cid, address b, uint32 g, bytes32 h, uint32 next) = lathe.deliveries(id);
        assertEq(p, address(proc));
        assertEq(cid, XOR_ID);
        assertEq(b, builder);
        assertEq(g, 4);
        assertEq(h, keccak256(proc.netlist(XOR_ID)));
        assertEq(next, 0);
    }

    // ---- check ----

    function test_check_paysOnAllMatch() public {
        uint256 id = createXor();
        deliverXor(id);
        vm.expectEmit(true, true, false, true);
        emit LatheOrders.Paid(id, builder, address(proc), XOR_ID);
        vm.prank(stranger); // anyone can run the check
        (bool done, bool passed) = lathe.check(id, 64);
        assertTrue(done);
        assertTrue(passed);
        assertEq(uint8(status(id)), uint8(LatheOrders.Status.Paid));
        uint256 toBuilder = uint256(AMOUNT) * (10_000 - FEE_BPS) / 10_000;
        assertEq(usdt.balanceOf(builder), toBuilder);
        // FIX 2: the fee is owed, not pushed; claimFees moves it.
        assertEq(lathe.feesOwed(), AMOUNT - toBuilder);
        assertEq(usdt.balanceOf(address(lathe)), AMOUNT - toBuilder);
        lathe.claimFees();
        assertEq(usdt.balanceOf(feeTo), AMOUNT - toBuilder);
        assertEq(usdt.balanceOf(address(lathe)), 0);
    }

    function test_claimFees_anyoneCalls_paysFixedRecipient_once() public {
        uint256 id = createXor();
        deliverXor(id);
        lathe.check(id, 4);
        uint256 fee = uint256(AMOUNT) * FEE_BPS / 10_000;
        vm.expectEmit(true, false, false, true);
        emit LatheOrders.FeesClaimed(feeTo, fee);
        vm.prank(stranger);
        lathe.claimFees();
        assertEq(usdt.balanceOf(feeTo), fee);
        assertEq(usdt.balanceOf(stranger), 0);
        // nothing left: a second claim moves nothing
        lathe.claimFees();
        assertEq(usdt.balanceOf(feeTo), fee);
    }

    /// Owed fees never touch money locked for an open order.
    function test_claimFees_leavesOtherOrdersMoney() public {
        uint256 a = createXor();
        createXor();
        deliverXor(a);
        lathe.check(a, 4);
        lathe.claimFees();
        assertEq(usdt.balanceOf(address(lathe)), AMOUNT);
    }

    /// Review Focus 4: a junk delivery is rejected on the first wrong case and the order reopens in the same call.
    function test_check_rejectsOnFirstMismatch_andReopens() public {
        uint256 id = createParity();
        vm.prank(builder);
        lathe.deliver(id, address(proc), PAR_ID);
        // break case 13 (parity of 13 = 1); flip it to 0
        proc.setOut(PAR_ID, 13, hex"00");
        vm.expectEmit(true, false, false, true);
        emit LatheOrders.Rejected(id, 13);
        (bool done, bool passed) = lathe.check(id, 64);
        assertTrue(done);
        assertFalse(passed);
        assertEq(uint8(status(id)), uint8(LatheOrders.Status.Open));
        (address p,,,,,) = lathe.deliveries(id);
        assertEq(p, address(0));
        assertEq(usdt.balanceOf(address(lathe)), AMOUNT);
        // the order can take a new (fixed) delivery
        proc.setOut(PAR_ID, 13, hex"01");
        vm.prank(builder);
        lathe.deliver(id, address(proc), PAR_ID);
        (done, passed) = lathe.check(id, 64);
        assertTrue(passed);
    }

    function test_check_resumesAcrossCalls() public {
        uint256 id = createParity();
        vm.prank(builder);
        lathe.deliver(id, address(proc), PAR_ID);
        (bool done, bool passed) = lathe.check(id, 10);
        assertFalse(done);
        assertFalse(passed);
        (,,,,, uint32 next) = lathe.deliveries(id);
        assertEq(next, 10);
        assertEq(uint8(status(id)), uint8(LatheOrders.Status.Checking));
        (done, passed) = lathe.check(id, 54);
        assertTrue(done);
        assertTrue(passed);
        assertEq(uint8(status(id)), uint8(LatheOrders.Status.Paid));
    }

    /// maxCases larger than what is left only runs what is left.
    function test_check_maxCasesBeyondEnd() public {
        uint256 id = createParity();
        vm.prank(builder);
        lathe.deliver(id, address(proc), PAR_ID);
        lathe.check(id, 60);
        (bool done, bool passed) = lathe.check(id, type(uint256).max);
        assertTrue(done && passed);
    }

    /// Review Focus 2: eval returns whole bytes; with nOut = 1 the top 7 bits are padding and must be ignored.
    function test_check_ignoresOutputPadding() public {
        uint256 id = createXor();
        bytes[] memory o = new bytes[](4);
        o[0] = hex"fe"; // low bit 0 -> 0
        o[1] = hex"ff"; // low bit 1 -> 1
        o[2] = hex"ff";
        o[3] = hex"fe";
        proc.setOuts(XOR_ID, o);
        deliverXor(id);
        (, bool passed) = lathe.check(id, 4);
        assertTrue(passed);
    }

    /// Hole: an output shorter than ceil(nOut/8) bytes would read as zeros and could "pass" zero answers.
    function test_check_shortOutput_rejects() public {
        uint256 id = createXor();
        proc.setOut(XOR_ID, 0, ""); // expected 0, but no bytes at all
        deliverXor(id);
        vm.expectEmit(true, false, false, true);
        emit LatheOrders.Rejected(id, 0);
        (, bool passed) = lathe.check(id, 4);
        assertFalse(passed);
    }

    /// Review Focus 5: the processor's circuit changes under the order between delivery and check.
    function test_check_revertsIfNetlistChanged() public {
        uint256 id = createXor();
        deliverXor(id);
        proc.setNetlist(XOR_ID, hex"deadbeef");
        vm.expectRevert(LatheOrders.CircuitChanged.selector);
        lathe.check(id, 4);
    }

    function test_check_revertsIfGateCountChanged() public {
        uint256 id = createXor();
        deliverXor(id);
        proc.setGateCount(XOR_ID, 5);
        vm.expectRevert(LatheOrders.CircuitChanged.selector);
        lathe.check(id, 4);
    }

    function test_check_afterPaid_reverts() public {
        uint256 id = createXor();
        deliverXor(id);
        lathe.check(id, 4);
        vm.expectRevert(LatheOrders.NotChecking.selector);
        lathe.check(id, 4);
    }

    function test_check_open_reverts() public {
        uint256 id = createXor();
        vm.expectRevert(LatheOrders.NotChecking.selector);
        lathe.check(id, 4);
    }

    /// Hole (Review Focus 4 variant): a delivered circuit whose eval reverts must not lock the order.
    function test_check_evalRevert_rejects() public {
        uint256 id = createXor();
        deliverXor(id);
        proc.setRevertEval(XOR_ID, true);
        (bool done, bool passed) = lathe.check(id, 4);
        assertTrue(done);
        assertFalse(passed);
        assertEq(uint8(status(id)), uint8(LatheOrders.Status.Open));
    }

    // ---- per-case gas budget (FIX 1) ----

    function test_evalBudget_formula() public view {
        assertEq(lathe.evalBudget(0), lathe.EVAL_BASE_GAS());
        assertEq(lathe.evalBudget(652), lathe.EVAL_BASE_GAS() + 652 * lathe.EVAL_GAS_PER_GATE());
    }

    /// A circuit that burns all gas it is given (a gas bomb) is rejected, the same way whatever gas the caller
    /// sends, because each case gets exactly its budget. (Before FIX 1 this reverted with EvalOutOfGas; the
    /// rule changed on purpose: the budget is fixed, so running out of it is the circuit's own fault.)
    function test_check_gasBomb_rejectedWhateverGasIsSent() public {
        uint256 id = createXor();
        deliverXor(id);
        proc.setBurnGasEval(XOR_ID, true);
        uint256 need = lathe.evalBudget(4) * 64 / 63 + lathe.GAS_RESERVE() + 200_000;
        uint256[3] memory gases = [need, 5 * need, 50 * need];
        uint256 snap = vm.snapshotState();
        for (uint256 i = 0; i < 3; ++i) {
            vm.revertToState(snap);
            vm.expectEmit(true, false, false, true);
            emit LatheOrders.Rejected(id, 0);
            (bool done, bool passed) = lathe.check{gas: gases[i]}(id, 4);
            assertTrue(done);
            assertFalse(passed);
            assertEq(uint8(status(id)), uint8(LatheOrders.Status.Open));
        }
    }

    /// Too little gas for one case's budget reverts the whole call: nothing is recorded.
    function test_check_tooLittleGasForBudget_reverts() public {
        uint256 id = createParity();
        vm.prank(builder);
        lathe.deliver(id, address(proc), PAR_ID);
        uint256 budget = lathe.evalBudget(20);
        vm.expectRevert(LatheOrders.InsufficientGasForCase.selector);
        lathe.check{gas: budget}(id, 64); // the budget alone, without the 64/63 headroom
        assertEq(uint8(status(id)), uint8(LatheOrders.Status.Checking));
        (,,,,, uint32 next) = lathe.deliveries(id);
        assertEq(next, 0);
    }

    /// eval gets exactly its budget: a circuit costing a bit under it passes, a bit over it fails, and sending
    /// far more gas does not change the outcome.
    function test_check_budgetIsTheLimit_notCallerGas() public {
        uint256 budget = lathe.evalBudget(4);
        uint256 id = createXor();
        deliverXor(id);
        proc.setEvalGasCost(XOR_ID, budget * 9 / 10);
        (, bool passed) = lathe.check{gas: 50 * budget}(id, 4);
        assertTrue(passed, "under budget passes");

        id = createXor();
        deliverXor(id);
        proc.setEvalGasCost(XOR_ID, budget * 11 / 10);
        (bool done, bool passed2) = lathe.check{gas: 50 * budget}(id, 4);
        assertTrue(done);
        assertFalse(passed2, "over budget is a wrong answer even with plenty of gas");
    }

    /// A circuit whose one-case budget could not fit in a transaction could never be checked, and would hold
    /// the order until deadline + grace. deliver refuses it.
    function test_deliver_rejectsCircuitTooBigToCheck() public {
        uint256 maxGates = (lathe.MAX_CASE_GAS() - lathe.EVAL_BASE_GAS()) / lathe.EVAL_GAS_PER_GATE();
        uint256 id = createXor();
        proc.setGateCount(XOR_ID, uint32(maxGates + 1));
        vm.prank(builder);
        vm.expectRevert(LatheOrders.CircuitTooBigToCheck.selector);
        lathe.deliver(id, address(proc), XOR_ID);
        proc.setGateCount(XOR_ID, uint32(maxGates));
        deliverXor(id);
    }

    /// The same honest circuit, called with too little gas by a griefer, stays in Checking and later pays.
    function test_check_lowGasGriefing_cannotReject() public {
        uint256 id = createParity();
        vm.prank(builder);
        lathe.deliver(id, address(proc), PAR_ID);
        for (uint256 g = 60_000; g < 200_000; g += 7_000) {
            try lathe.check{gas: g}(id, 64) {} catch {}
            assertTrue(uint8(status(id)) != uint8(LatheOrders.Status.Open), "griefer rejected an honest delivery");
        }
        if (status(id) == LatheOrders.Status.Checking) lathe.check(id, 64);
        assertEq(uint8(status(id)), uint8(LatheOrders.Status.Paid));
    }

    /// Hole: the builder sells the circuit NFT mid-check. Pay goes to whoever delivered (fixed at delivery),
    /// and the new owner cannot hijack the order with a second delivery.
    function test_check_circuitTransferredMidCheck_paysDeliverer() public {
        uint256 id = createParity();
        vm.prank(builder);
        lathe.deliver(id, address(proc), PAR_ID);
        lathe.check(id, 10);
        proc.setOwner(PAR_ID, stranger);
        vm.prank(stranger);
        vm.expectRevert(LatheOrders.NotOpen.selector);
        lathe.deliver(id, address(proc), PAR_ID);
        lathe.check(id, 64);
        assertEq(usdt.balanceOf(stranger), 0);
        assertGt(usdt.balanceOf(builder), 0);
    }

    /// Fee rounds down (in the builder's favour); a zero fee adds nothing to feesOwed.
    function test_check_feeRoundsDown() public {
        vm.prank(buyer);
        uint256 id = lathe.createOrder(2, 1, xorTable(), 199, uint64(block.timestamp + 1 days), address(0), 0);
        deliverXor(id);
        lathe.check(id, 4);
        assertEq(lathe.feesOwed(), 1); // 199 * 100 / 10000 = 1.99 -> 1
        assertEq(usdt.balanceOf(builder), 198);

        vm.prank(buyer);
        id = lathe.createOrder(2, 1, xorTable(), 99, uint64(block.timestamp + 1 days), address(0), 0);
        deliverXor(id);
        lathe.check(id, 4);
        assertEq(lathe.feesOwed(), 1); // fee 0 this time
        assertEq(usdt.balanceOf(builder), 198 + 99);
    }

    /// Two orders share one contract balance; paying one never touches the other's money.
    function test_check_twoOrdersKeepSeparateMoney() public {
        uint256 a = createXor();
        uint256 b = createXor();
        deliverXor(a);
        lathe.check(a, 4);
        // FIX 2: the contract also holds the fee owed until claimFees
        assertEq(usdt.balanceOf(address(lathe)), AMOUNT + lathe.feesOwed());
        deliverXor(b);
        lathe.check(b, 4);
        assertEq(usdt.balanceOf(address(lathe)), lathe.feesOwed());
    }

    function test_check_wideOutputs() public {
        // 2 inputs, 3 outputs: answers 5,2,7,0 -> bits 101 010 111 000 -> 0x1D5 -> d5 01
        vm.prank(buyer);
        uint256 id = lathe.createOrder(2, 3, hex"d501", AMOUNT, uint64(block.timestamp + 1 days), address(0), 0);
        setCircuitFromTable(11, builder, 2, 3, hex"d501", 9);
        vm.prank(builder);
        lathe.deliver(id, address(proc), 11);
        (, bool passed) = lathe.check(id, 4);
        assertTrue(passed);
    }
}

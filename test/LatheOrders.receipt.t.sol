// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {LatheBase} from "./LatheBase.sol";
import {LatheOrders} from "../src/LatheOrders.sol";
import {MockProcessor} from "./mocks/MockProcessor.sol";

/// @notice V2 (Task 8): a receipt stored at payout, ruleOf, run / runStep on a paid order, input labels.
/// run(orderId, inputs) calls eval; runStep(orderId, state, inputs) calls step and returns (newState, outputs),
/// the same order as TapeOut's step. Inputs are ceil(nIn/8) bytes LSB first, state ceil(nState/8) bytes; bits
/// above nIn (or nState) must be zero. Returned bytes keep only the low nOut (or nState) bits, padding zeroed,
/// so run answers exactly what check compared.
contract LatheOrdersReceiptTest is LatheBase {
    uint256 constant XOR_ID = 1; // 4 gates: paid inside deliver
    uint256 constant BIG_XOR = 2; // batched
    uint256 constant TOGGLE = 3; // 1 input, 1 output, 1 memory bit
    uint32 constant SMALL_GATES = 4;

    /// Toggle: case c = x0 + 2s; new memory = s XOR x0; output = new memory. Answers 0,3,3,0 = table 0x3c.
    bytes constant TOGGLE_TABLE = hex"3c";

    function setUp() public override {
        super.setUp();
        setCircuitFromTable(XOR_ID, builder, 2, 1, xorTable(), SMALL_GATES);
        setCircuitFromTable(BIG_XOR, builder, 2, 1, xorTable(), BATCHED_GATES);
        setStatefulCircuitFromTable(TOGGLE, builder, 1, 1, 1, TOGGLE_TABLE, SMALL_GATES);
    }

    function status(uint256 id) internal view returns (LatheOrders.Status s) {
        (,,,,,,,, s) = lathe.orders(id);
    }

    function paidXor() internal returns (uint256 id) {
        id = createXor();
        vm.prank(builder);
        lathe.deliver(id, address(proc), XOR_ID);
        assertEq(uint8(status(id)), uint8(LatheOrders.Status.Paid));
    }

    function createToggle() internal returns (uint256 id) {
        vm.prank(buyer);
        id = lathe.createStatefulOrder(1, 1, 1, TOGGLE_TABLE, AMOUNT, uint64(block.timestamp + 1 days), builder, 0);
    }

    function paidToggle() internal returns (uint256 id) {
        id = createToggle();
        vm.prank(builder);
        lathe.deliver(id, address(proc), TOGGLE);
        assertEq(uint8(status(id)), uint8(LatheOrders.Status.Paid));
    }

    // ---- receipt ----

    function test_receipt_storedOnPay() public {
        uint256 id = createXor();
        vm.roll(1234);
        vm.expectEmit(true, false, false, true);
        emit LatheOrders.Receipt(id, address(proc), XOR_ID, keccak256(abi.encodePacked(uint8(2), uint8(1), uint8(0), xorTable())));
        vm.prank(builder);
        lathe.deliver(id, address(proc), XOR_ID);
        (address p, uint256 c, bytes32 h, uint64 b) = lathe.receipts(id);
        assertEq(p, address(proc));
        assertEq(c, XOR_ID);
        assertEq(h, keccak256(abi.encodePacked(uint8(2), uint8(1), uint8(0), xorTable())), "shape, then table");
        assertEq(b, 1234);
    }

    /// The same table bytes under a different shape are a different rule, so they get a different fingerprint.
    /// 0x06 is XOR for 2 inputs / 1 output, and answers 2,1,0,0 for 2 inputs / 2 outputs.
    function test_receipt_fingerprintCoversShape() public {
        uint256 a = paidXor();
        setCircuitFromTable(7, builder, 2, 2, hex"06", SMALL_GATES);
        vm.prank(buyer);
        uint256 b = lathe.createOrder(2, 2, hex"06", AMOUNT, uint64(block.timestamp + 1 days), builder, 0);
        vm.prank(builder);
        lathe.deliver(b, address(proc), 7);
        assertEq(uint8(status(b)), uint8(LatheOrders.Status.Paid));
        assertEq(keccak256(lathe.tableOf(a)), keccak256(lathe.tableOf(b)), "same table bytes");
        (,, bytes32 ha,) = lathe.receipts(a);
        (,, bytes32 hb,) = lathe.receipts(b);
        assertTrue(ha != hb, "different shapes, different fingerprints");
        assertEq(hb, keccak256(abi.encodePacked(uint8(2), uint8(2), uint8(0), hex"06")));
    }

    function test_receipt_storedOnBatchedPay() public {
        uint256 id = createXor();
        vm.prank(builder);
        lathe.deliver(id, address(proc), BIG_XOR);
        (address p,,,) = lathe.receipts(id);
        assertEq(p, address(0), "no receipt while checking");
        vm.roll(777);
        lathe.check(id, 4);
        (address p2, uint256 c,, uint64 b) = lathe.receipts(id);
        assertEq(p2, address(proc));
        assertEq(c, BIG_XOR);
        assertEq(b, 777);
    }

    /// A rejected delivery leaves no receipt; the honest one that follows gets it.
    function test_receipt_notOnReject() public {
        uint256 id = createXor();
        proc.setOut(BIG_XOR, 1, hex"00");
        vm.prank(builder);
        lathe.deliver(id, address(proc), BIG_XOR);
        lathe.check(id, 4);
        (address p,,,) = lathe.receipts(id);
        assertEq(p, address(0));
        vm.prank(builder);
        lathe.deliver(id, address(proc), XOR_ID);
        (address p2, uint256 c,,) = lathe.receipts(id);
        assertEq(p2, address(proc));
        assertEq(c, XOR_ID);
    }

    // ---- ruleOf ----

    function test_ruleOf_beforePaid_reverts() public {
        uint256 id = createXor();
        vm.expectRevert(LatheOrders.NotPaid.selector);
        lathe.ruleOf(id); // Open
        vm.prank(builder);
        lathe.deliver(id, address(proc), BIG_XOR);
        vm.expectRevert(LatheOrders.NotPaid.selector);
        lathe.ruleOf(id); // Checking
        vm.expectRevert(LatheOrders.NotPaid.selector);
        lathe.ruleOf(999); // no such order
        uint256 r = createXor();
        vm.warp(block.timestamp + 2 days);
        vm.prank(buyer);
        lathe.refund(r);
        vm.expectRevert(LatheOrders.NotPaid.selector);
        lathe.ruleOf(r); // Refunded
    }

    function test_ruleOf_afterPaid() public {
        uint256 id = paidXor();
        (address p, uint256 c) = lathe.ruleOf(id);
        assertEq(p, address(proc));
        assertEq(c, XOR_ID);
    }

    // ---- run ----

    function test_run_beforePaid_reverts() public {
        uint256 id = createXor();
        vm.expectRevert(LatheOrders.NotPaid.selector);
        lathe.run(id, hex"01");
        uint256 t = createToggle();
        vm.expectRevert(LatheOrders.NotPaid.selector);
        lathe.runStep(t, hex"00", hex"01");
        vm.expectRevert(LatheOrders.NotPaid.selector);
        lathe.run(999, hex"01");
    }

    function test_run_matchesTable() public {
        uint256 id = paidXor();
        assertEq(lathe.run(id, hex"00"), hex"00");
        assertEq(lathe.run(id, hex"01"), hex"01");
        assertEq(lathe.run(id, hex"02"), hex"01");
        assertEq(lathe.run(id, hex"03"), hex"00");
    }

    /// Padding bits the circuit returns above nOut are zeroed, so run says what check compared.
    function test_run_masksOutputPadding() public {
        uint256 id = paidXor();
        proc.setOut(XOR_ID, 1, hex"ff");
        assertEq(lathe.run(id, hex"01"), hex"01");
    }

    /// Inputs must be exactly ceil(nIn/8) bytes with bits above nIn zero; anything else is refused, not guessed.
    function test_run_badInputs_reverts() public {
        uint256 id = paidXor();
        vm.expectRevert(LatheOrders.BadInputs.selector);
        lathe.run(id, hex"");
        vm.expectRevert(LatheOrders.BadInputs.selector);
        lathe.run(id, hex"0100");
        vm.expectRevert(LatheOrders.BadInputs.selector);
        lathe.run(id, hex"05"); // bit 2 set, but nIn = 2
    }

    /// run is for orders without memory, runStep for orders with it.
    function test_run_wrongKind_reverts() public {
        uint256 x = paidXor();
        uint256 t = paidToggle();
        vm.expectRevert(LatheOrders.BadInputs.selector);
        lathe.run(t, hex"01");
        vm.expectRevert(LatheOrders.BadInputs.selector);
        lathe.runStep(x, hex"", hex"01");
    }

    /// The Review Focus 5 guard covers run: a circuit changed after payment is refused, never answered.
    function test_run_circuitChanged_reverts() public {
        uint256 id = paidXor();
        proc.setNetlist(XOR_ID, hex"beef");
        vm.expectRevert(LatheOrders.CircuitChanged.selector);
        lathe.run(id, hex"01");
        proc.setNetlist(XOR_ID, abi.encodePacked("netlist", XOR_ID, uint32(SMALL_GATES)));
        assertEq(lathe.run(id, hex"01"), hex"01", "same netlist again: answers");
        proc.setGateCount(XOR_ID, SMALL_GATES + 1);
        vm.expectRevert(LatheOrders.CircuitChanged.selector);
        lathe.run(id, hex"01");
    }

    /// The per-case gas guard covers run: too little gas reverts, so a capped eth_call cannot return a wrong answer.
    function test_run_tooLittleGas_reverts() public {
        uint256 id = paidXor();
        vm.expectRevert(LatheOrders.InsufficientGasForCase.selector);
        lathe.run{gas: 150_000}(id, hex"01");
    }

    /// A circuit that runs out of its budget inside run reverts the call (no try/catch, no made-up answer).
    function test_run_outOfBudget_reverts() public {
        uint256 id = paidXor();
        proc.setBurnGasEval(XOR_ID, true);
        vm.expectRevert();
        lathe.run{gas: 10_000_000}(id, hex"01");
    }

    function test_run_shortOutput_reverts() public {
        uint256 id = paidXor();
        proc.setOut(XOR_ID, 1, hex"");
        vm.expectRevert(LatheOrders.ShortOutput.selector);
        lathe.run(id, hex"01");
    }

    // ---- runStep ----

    function test_runStep_matchesStep() public {
        uint256 id = paidToggle();
        for (uint256 c = 0; c < 4; ++c) {
            bytes memory inp = abi.encodePacked(uint8(c & 1));
            bytes memory st = abi.encodePacked(uint8(c >> 1));
            (bytes memory ns, bytes memory out) = lathe.runStep(id, st, inp);
            (bytes memory pns, bytes memory pout) = proc.step(TOGGLE, st, inp);
            assertEq(ns, pns, "new state = step's new state");
            assertEq(out, pout, "outputs = step's outputs");
        }
        (bytes memory n3, bytes memory o3) = lathe.runStep(id, hex"01", hex"01");
        assertEq(n3, hex"00", "x0 = 1 flips memory 1 to 0");
        assertEq(o3, hex"00");
        (bytes memory n1, bytes memory o1) = lathe.runStep(id, hex"00", hex"01");
        assertEq(n1, hex"01", "x0 = 1 flips memory 0 to 1");
        assertEq(o1, hex"01");
    }

    function test_runStep_masksPaddingAndChecksState() public {
        uint256 id = paidToggle();
        proc.setNewState(TOGGLE, 1, hex"ff");
        (bytes memory ns,) = lathe.runStep(id, hex"00", hex"01");
        assertEq(ns, hex"01");
        vm.expectRevert(LatheOrders.BadInputs.selector);
        lathe.runStep(id, hex"02", hex"01"); // state bit 1 set, nState = 1
        vm.expectRevert(LatheOrders.BadInputs.selector);
        lathe.runStep(id, hex"", hex"01");
        proc.setNewState(TOGGLE, 1, hex"");
        vm.expectRevert(LatheOrders.ShortOutput.selector);
        lathe.runStep(id, hex"00", hex"01");
    }

    // ---- labels ----

    function labels(uint256 n) internal pure returns (bytes32[] memory l) {
        l = new bytes32[](n);
        for (uint256 i = 0; i < n; ++i) {
            l[i] = bytes32(abi.encodePacked("in", uint8(48 + i)));
        }
    }

    function test_labels_wrongLength_reverts() public {
        uint64 dl = uint64(block.timestamp + 1 days);
        vm.startPrank(buyer);
        vm.expectRevert(LatheOrders.WrongLabelCount.selector);
        lathe.createOrder(2, 1, xorTable(), AMOUNT, dl, builder, 0, labels(1));
        vm.expectRevert(LatheOrders.WrongLabelCount.selector);
        lathe.createOrder(2, 1, xorTable(), AMOUNT, dl, builder, 0, labels(3));
        // a memory order names its inputs and its memory bit: nIn + nState labels
        vm.expectRevert(LatheOrders.WrongLabelCount.selector);
        lathe.createStatefulOrder(1, 1, 1, TOGGLE_TABLE, AMOUNT, dl, builder, 0, labels(1));
        vm.stopPrank();
    }

    function test_labels_roundTrip() public {
        uint64 dl = uint64(block.timestamp + 1 days);
        vm.startPrank(buyer);
        uint256 a = lathe.createOrder(2, 1, xorTable(), AMOUNT, dl, builder, 0, labels(2));
        uint256 b = lathe.createStatefulOrder(1, 1, 1, TOGGLE_TABLE, AMOUNT, dl, builder, 0, labels(2));
        uint256 c = lathe.createOrder(2, 1, xorTable(), AMOUNT, dl, builder, 0, new bytes32[](0));
        vm.stopPrank();
        bytes32[] memory la = lathe.labelsOf(a);
        assertEq(la.length, 2);
        assertEq(la[0], bytes32("in0"));
        assertEq(la[1], bytes32("in1"));
        assertEq(lathe.labelsOf(b).length, 2);
        assertEq(lathe.labelsOf(c).length, 0);
        assertEq(lathe.labelsOf(createXor()).length, 0, "label-less overload");
        assertEq(usdt.balanceOf(address(lathe)), 4 * uint256(AMOUNT), "every overload locks the amount");
        (,,,,, uint8 nIn,, uint8 nState,) = lathe.orders(b);
        assertEq(nIn, 1);
        assertEq(nState, 1);
    }

    /// The label overload of createStatefulOrder keeps the nState == 1 rule.
    function test_labels_statefulStillOneBit() public {
        vm.prank(buyer);
        vm.expectRevert(LatheOrders.UnsupportedStateBits.selector);
        lathe.createStatefulOrder(2, 1, 0, xorTable(), AMOUNT, uint64(block.timestamp + 1 days), builder, 0, labels(2));
    }
}

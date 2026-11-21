// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {LatheBase} from "./LatheBase.sol";
import {LatheOrders} from "../src/LatheOrders.sol";
import {MockProcessor} from "./mocks/MockProcessor.sol";

/// @notice V1 memory circuits (Task 7): orders checked with `step` instead of `eval`.
///
/// Packing under test (the same rule as TableLib and LatheOrders._answer):
/// - A stateful order has 2^(nIn + nState) cases. Case c's inputs are c & (2^nIn - 1) and its state is c >> nIn,
///   so the input bits are the low bits of the case number and the state bits sit above them.
/// - The contract calls step(id, pack(c >> nIn, nState), pack(c & (2^nIn - 1), nIn)), each packed LSB first.
/// - Each case's expected answer is w = nOut + nState bits at table bit c * w: the low nOut bits are the outputs,
///   the nState bits above them are the new state. Padding bits above nOut (outputs) and above nState (new state)
///   in the bytes step returns are ignored.
///
/// The breaker used here: inputs bit0 overload, bit1 short, bit2 reset, bit3 switch on; one state bit `tripped`.
/// newTripped = (tripped AND NOT reset) OR overload OR short; power (the one output) = switch AND NOT newTripped.
contract LatheOrdersStateTest is LatheBase {
    uint256 constant SMALL = 1; // 10 gates: 32 cases checked inside deliver
    uint256 constant BIG = 2; // BATCHED_GATES: checked in batches
    uint32 constant SMALL_GATES = 10;

    function setUp() public override {
        super.setUp();
        setStatefulCircuitFromTable(SMALL, builder, 4, 1, 1, breakerTable(), SMALL_GATES);
        setStatefulCircuitFromTable(BIG, builder, 4, 1, 1, breakerTable(), BATCHED_GATES);
    }

    function breakerAnswer(uint256 c) internal pure returns (uint256) {
        uint256 inp = c & 15;
        uint256 tripped = c >> 4;
        uint256 overload = inp & 1;
        uint256 short_ = (inp >> 1) & 1;
        uint256 reset = (inp >> 2) & 1;
        uint256 sw = (inp >> 3) & 1;
        uint256 newTripped = (tripped & (1 - reset)) | overload | short_;
        uint256 power = sw & (1 - newTripped);
        return power | (newTripped << 1); // outputs low, new state above
    }

    /// 32 cases x 2 bits = 64 bits = 8 bytes, no padding.
    function breakerTable() internal pure returns (bytes memory t) {
        t = new bytes(8);
        for (uint256 c = 0; c < 32; ++c) {
            uint256 a = breakerAnswer(c);
            for (uint256 i = 0; i < 2; ++i) {
                if ((a >> i) & 1 == 1) {
                    uint256 bit = c * 2 + i;
                    t[bit / 8] = bytes1(uint8(t[bit / 8]) | uint8(1 << (bit % 8)));
                }
            }
        }
    }

    /// The breaker with outputs and new state swapped in every answer.
    function swappedTable() internal pure returns (bytes memory t) {
        t = new bytes(8);
        for (uint256 c = 0; c < 32; ++c) {
            uint256 a = breakerAnswer(c);
            uint256 s = ((a & 1) << 1) | (a >> 1);
            for (uint256 i = 0; i < 2; ++i) {
                if ((s >> i) & 1 == 1) {
                    uint256 bit = c * 2 + i;
                    t[bit / 8] = bytes1(uint8(t[bit / 8]) | uint8(1 << (bit % 8)));
                }
            }
        }
    }

    function createBreaker() internal returns (uint256) {
        vm.prank(buyer);
        return lathe.createStatefulOrder(4, 1, 1, breakerTable(), AMOUNT, uint64(block.timestamp + 1 days), builder, 0);
    }

    function status(uint256 id) internal view returns (LatheOrders.Status s) {
        (,,,,,,,, s) = lathe.orders(id);
    }

    // ---- create ----

    /// The same bytes are a vector in web/test/table.test.mjs, so the page and the contract agree on the packing.
    function test_state_breakerTableBytes() public pure {
        assertEq(breakerTable(), hex"a8a8a9a9aaa8aaa9");
    }

    function test_state_createRecordsShape() public {
        uint256 id = createBreaker();
        (,,,,, uint8 nIn, uint8 nOut, uint8 nState,) = lathe.orders(id);
        assertEq(nIn, 4);
        assertEq(nOut, 1);
        assertEq(nState, 1);
        assertEq(lathe.tableOf(id), breakerTable());
        assertEq(usdt.balanceOf(address(lathe)), AMOUNT);
    }

    function test_state_nState2_reverts() public {
        // 2 inputs + 2 state bits = 16 cases, 1 + 2 = 3-bit answers = 48 bits = 6 bytes: a valid table shape.
        bytes memory t = new bytes(6);
        vm.startPrank(buyer);
        vm.expectRevert(LatheOrders.UnsupportedStateBits.selector);
        lathe.createStatefulOrder(2, 1, 2, t, AMOUNT, uint64(block.timestamp + 1 days), builder, 0);
        // nState 0 belongs to createOrder
        vm.expectRevert(LatheOrders.UnsupportedStateBits.selector);
        lathe.createStatefulOrder(2, 1, 0, hex"06", AMOUNT, uint64(block.timestamp + 1 days), builder, 0);
        vm.stopPrank();
    }

    /// The case limit counts the state bit: 6 inputs + 1 state = 7 bits is over MAX_CASE_BITS.
    function test_state_tooManyCases_countsState() public {
        bytes memory t = new bytes(32); // 128 cases x 2 bits
        vm.prank(buyer);
        vm.expectRevert(LatheOrders.TooManyCases.selector);
        lathe.createStatefulOrder(6, 1, 1, t, AMOUNT, uint64(block.timestamp + 1 days), builder, 0);
    }

    /// The table length counts the new-state column: 32 cases x 2 bits = 8 bytes; the stateless 4 bytes is wrong.
    function test_state_wrongTableLength_reverts() public {
        vm.prank(buyer);
        vm.expectRevert(LatheOrders.WrongTableLength.selector);
        lathe.createStatefulOrder(4, 1, 1, new bytes(4), AMOUNT, uint64(block.timestamp + 1 days), builder, 0);
    }

    /// 0 inputs + 1 state: 2 cases x 2 bits = 4 bits, so the top 4 bits of the one byte must be zero.
    function test_state_tablePadding_reverts() public {
        vm.prank(buyer);
        vm.expectRevert(LatheOrders.TablePaddingNotZero.selector);
        lathe.createStatefulOrder(0, 1, 1, hex"16", AMOUNT, uint64(block.timestamp + 1 days), builder, 0);
    }

    // ---- deliver and check ----

    /// All 32 cases run through step; the small circuit is checked and paid inside deliver.
    /// expectCall pins the packing: case 31 = inputs 0b1111 with state 1, case 16 = inputs 0 with state 1,
    /// case 5 = inputs 0b0101 with state 0.
    function test_state_breakerShape_32cases() public {
        uint256 id = createBreaker();
        bytes memory t = lathe.tableOf(id);
        assertEq(t.length, 8, "32 cases x (1 output + 1 new state) bits");
        vm.expectCall(address(proc), abi.encodeCall(MockProcessor.step, (SMALL, hex"01", hex"0f")));
        vm.expectCall(address(proc), abi.encodeCall(MockProcessor.step, (SMALL, hex"01", hex"00")));
        vm.expectCall(address(proc), abi.encodeCall(MockProcessor.step, (SMALL, hex"00", hex"05")));
        vm.prank(builder);
        lathe.deliver(id, address(proc), SMALL);
        assertEq(uint8(status(id)), uint8(LatheOrders.Status.Paid));
        (,,,,, uint32 nextCase) = lathe.deliveries(id);
        assertEq(nextCase, 32, "every one of the 2^(4+1) cases ran");
        assertEq(usdt.balanceOf(builder), AMOUNT - uint256(AMOUNT) * FEE_BPS / 10_000);
    }

    /// A stateful order never calls eval (the real processor reverts eval for circuits with memory).
    function test_state_neverCallsEval() public {
        uint256 id = createBreaker();
        vm.expectCall(address(proc), abi.encodeWithSelector(MockProcessor.eval.selector), 0);
        vm.prank(builder);
        lathe.deliver(id, address(proc), SMALL);
        assertEq(uint8(status(id)), uint8(LatheOrders.Status.Paid));
    }

    function test_state_batched_checkPays() public {
        uint256 id = createBreaker();
        vm.prank(builder);
        lathe.deliver(id, address(proc), BIG);
        assertEq(uint8(status(id)), uint8(LatheOrders.Status.Checking));
        (bool done, bool passed) = lathe.check(id, 20);
        assertFalse(done);
        assertFalse(passed);
        (,,,,, uint32 nextCase) = lathe.deliveries(id);
        assertEq(nextCase, 20);
        (done, passed) = lathe.check(id, 100);
        assertTrue(done);
        assertTrue(passed);
        assertEq(uint8(status(id)), uint8(LatheOrders.Status.Paid));
    }

    /// Outputs right, new state wrong in one case: inline delivery reverts at that case.
    function test_state_wrongNewState_rejects() public {
        uint256 id = createBreaker();
        // case 21 = inputs 0b0101 (overload, reset), tripped: newTripped = 1. Return 0 instead; output stays right.
        assertEq(breakerAnswer(21) >> 1, 1);
        proc.setNewState(SMALL, 21, hex"00");
        vm.prank(builder);
        vm.expectRevert(abi.encodeWithSelector(LatheOrders.WrongAnswer.selector, 21));
        lathe.deliver(id, address(proc), SMALL);
        assertEq(uint8(status(id)), uint8(LatheOrders.Status.Open));
    }

    /// Same on the batched path: check rejects at that case and reopens the order.
    function test_state_wrongNewState_batched_rejects() public {
        uint256 id = createBreaker();
        proc.setNewState(BIG, 21, hex"00");
        vm.prank(builder);
        lathe.deliver(id, address(proc), BIG);
        vm.expectEmit(true, false, false, true);
        emit LatheOrders.Rejected(id, 21);
        (bool done, bool passed) = lathe.check(id, 64);
        assertTrue(done);
        assertFalse(passed);
        assertEq(uint8(status(id)), uint8(LatheOrders.Status.Open));
    }

    /// A circuit that puts the new state where the outputs go (and the other way round) is wrong at the first case
    /// where they differ: case 1 = overload only, not tripped: power 0, newTripped 1.
    function test_state_swappedReturn_rejects() public {
        uint256 id = createBreaker();
        setStatefulCircuitFromTable(3, builder, 4, 1, 1, swappedTable(), SMALL_GATES);
        vm.prank(builder);
        assertEq(breakerAnswer(0), 0, "case 0: both bits zero, a swap is invisible");
        assertEq(breakerAnswer(1), 2, "case 1: output 0, new state 1");
        vm.expectRevert(abi.encodeWithSelector(LatheOrders.WrongAnswer.selector, 1));
        lathe.deliver(id, address(proc), 3);
    }

    /// Padding bits above nOut in outputs and above nState in the new state are ignored.
    function test_state_ignoresPadding() public {
        uint256 id = createBreaker();
        for (uint256 c = 0; c < 32; ++c) {
            uint256 a = breakerAnswer(c);
            proc.setOut(SMALL, c, abi.encodePacked(uint8(0xFE | (a & 1))));
            proc.setNewState(SMALL, c, abi.encodePacked(uint8(0xFE | (a >> 1))));
        }
        vm.prank(builder);
        lathe.deliver(id, address(proc), SMALL);
        assertEq(uint8(status(id)), uint8(LatheOrders.Status.Paid));
    }

    /// A new state with too few bytes is a wrong answer, not a read of zero.
    function test_state_shortNewState_rejects() public {
        uint256 id = createBreaker();
        proc.setNewState(SMALL, 0, hex"");
        vm.prank(builder);
        vm.expectRevert(abi.encodeWithSelector(LatheOrders.WrongAnswer.selector, 0));
        lathe.deliver(id, address(proc), SMALL);
    }

    function test_deliver_stateMismatch_reverts() public {
        uint256 id = createBreaker();
        proc.setCircuit(7, builder, 4, 1, 0, SMALL_GATES); // no memory
        proc.setCircuit(8, builder, 4, 1, 2, SMALL_GATES); // two memory bits
        proc.setCircuit(9, builder, 5, 1, 0, SMALL_GATES); // same case count, no memory
        vm.startPrank(builder);
        vm.expectRevert(LatheOrders.ShapeMismatch.selector);
        lathe.deliver(id, address(proc), 7);
        vm.expectRevert(LatheOrders.ShapeMismatch.selector);
        lathe.deliver(id, address(proc), 8);
        vm.expectRevert(LatheOrders.ShapeMismatch.selector);
        lathe.deliver(id, address(proc), 9);
        vm.stopPrank();
        // and a stateless order refuses a memory circuit
        uint256 x = createXor();
        proc.setCircuit(10, builder, 2, 1, 1, SMALL_GATES);
        vm.prank(builder);
        vm.expectRevert(LatheOrders.ShapeMismatch.selector);
        lathe.deliver(x, address(proc), 10);
    }

    /// No inputs, one state bit: a toggle. step gets an empty inputs field and a one-byte state.
    /// Case 0 (state 0): output 0, new state 1 -> answer 0b10. Case 1 (state 1): output 1, new state 0 -> 0b01.
    /// Table bits: 0,1,1,0 -> 0x06.
    function test_state_noInputs_toggle() public {
        setStatefulCircuitFromTable(4, builder, 0, 1, 1, hex"06", SMALL_GATES);
        vm.prank(buyer);
        uint256 id = lathe.createStatefulOrder(0, 1, 1, hex"06", AMOUNT, uint64(block.timestamp + 1 days), builder, 0);
        vm.expectCall(address(proc), abi.encodeCall(MockProcessor.step, (4, hex"00", hex"")));
        vm.expectCall(address(proc), abi.encodeCall(MockProcessor.step, (4, hex"01", hex"")));
        vm.prank(builder);
        lathe.deliver(id, address(proc), 4);
        assertEq(uint8(status(id)), uint8(LatheOrders.Status.Paid));
    }

    // ---- the V0 guards cover the step path ----

    function test_state_circuitChanged_reverts() public {
        uint256 id = createBreaker();
        vm.prank(builder);
        lathe.deliver(id, address(proc), BIG);
        proc.setNetlist(BIG, hex"beef");
        vm.expectRevert(LatheOrders.CircuitChanged.selector);
        lathe.check(id, 1);
    }

    function test_state_stepRevert_rejects() public {
        uint256 id = createBreaker();
        vm.prank(builder);
        lathe.deliver(id, address(proc), BIG);
        proc.setRevertEval(BIG, true); // the mock's switch covers step too
        vm.expectEmit(true, false, false, true);
        emit LatheOrders.Rejected(id, 0);
        lathe.check(id, 1);
    }

    /// A step that burns more than the budget is a wrong answer whatever gas the caller sends.
    function test_state_gasBomb_rejected() public {
        uint256 id = createBreaker();
        vm.prank(builder);
        lathe.deliver(id, address(proc), BIG);
        proc.setBurnGasEval(BIG, true);
        vm.expectEmit(true, false, false, true);
        emit LatheOrders.Rejected(id, 0);
        lathe.check{gas: 150_000_000}(id, 1);
    }

    /// Too little gas for one step's budget reverts the check; nothing is recorded, nothing rejected.
    function test_state_tooLittleGas_reverts() public {
        uint256 id = createBreaker();
        vm.prank(builder);
        lathe.deliver(id, address(proc), BIG);
        vm.expectRevert(LatheOrders.InsufficientGasForCase.selector);
        lathe.check{gas: 1_000_000}(id, 1);
        assertEq(uint8(status(id)), uint8(LatheOrders.Status.Checking));
    }
}

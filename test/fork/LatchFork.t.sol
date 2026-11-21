// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {LatheOrders} from "../../src/LatheOrders.sol";
import {IProcessor, IProcessorFactory} from "../../src/ITapeOut.sol";

/// @dev Exposes LatheOrders' own per-case code (_answer: packing, gas budget, step call) so it can be run on a
/// real memory circuit that no order could name.
contract LatheStepHarness is LatheOrders {
    constructor(address f, address u) LatheOrders(f, u, address(1), 0) {}

    function answerOf(address p, uint256 id, uint8 nIn, uint8 nOut, uint8 nState, uint256 c, uint256 gates)
        external
        returns (bool ok, uint256 got)
    {
        orders[0] = Order(address(1), address(1), 0, 0, 0, nIn, nOut, nState, Status.Open);
        return _answer(IProcessor(p), id, c, orders[0], evalBudget(gates));
    }

    function rawStep(address p, uint256 id, bytes calldata state, bytes calldata inputs)
        external
        view
        returns (bytes memory, bytes memory)
    {
        return IProcessor(p).step(id, state, inputs);
    }
}

/// @notice The real TapeOut latched circuit on an X Layer mainnet fork (block 76,432,018, 2026-11-20).
/// Processor 0x0565...551b id 1: 0 inputs, 1 output, 2 state bits, 10 gates.
/// It has 2 state bits, so it is NOT a valid Lathe order (createStatefulOrder takes nState == 1 only). This test
/// proves only that a step call made from inside a contract, through Lathe's own per-case code, reaches the real
/// processor and returns (newState 0x01, outputs 0x01) for state 0, as the preflight found.
/// Run: forge test --match-path 'test/fork/LatchFork.t.sol' -vv  (sequential; the public RPC 403s under load)
contract LatchForkTest is Test {
    uint256 constant FORK_BLOCK = 76_432_018;
    address constant FACTORY = 0x1f09DAeFA827f02CBb40967cc91b259763760761;
    address constant USDT0 = 0x779Ded0c9e1022225f8E0630b35a9b54bE713736;
    address constant LATCH_PROC = 0x0565EA48CA41Ae559d8d491dbb0a9ec945DB551b;
    uint256 constant LATCH_ID = 1;

    LatheStepHarness h;

    function setUp() public {
        vm.createSelectFork("xlayer", FORK_BLOCK);
        h = new LatheStepHarness(FACTORY, USDT0);
    }

    function test_fork_inContractStep() public {
        assertTrue(IProcessorFactory(FACTORY).isCPU(LATCH_PROC));
        (uint32 nIn, uint32 nOut, uint32 nState, uint32 gates) = IProcessor(LATCH_PROC).circuitInfo(LATCH_ID);
        assertEq(nIn, 0);
        assertEq(nOut, 1);
        assertEq(nState, 2);
        assertEq(gates, 10);

        (bytes memory ns, bytes memory out) = h.rawStep(LATCH_PROC, LATCH_ID, hex"00", hex"");
        assertEq(ns, hex"01", "new state");
        assertEq(out, hex"01", "outputs");

        // Lathe's own path: case 0 = state 0, no inputs. Answer = output 1 | new state 1 << 1 = 3.
        (bool ok, uint256 got) = h.answerOf(LATCH_PROC, LATCH_ID, 0, 1, 2, 0, gates);
        assertTrue(ok, "step within the budget");
        assertEq(got, 3);
    }

    /// @dev test_fork_inContractStep cannot tell `state` from `inputs`: the latch has no inputs and the processor
    /// reads short bytes as zeros, so the call above gives the same answer with the two swapped. These two probes
    /// do tell them apart, through IProcessor (the interface LatheOrders calls):
    /// - step(1, state 0x01, inputs empty) = (0x02, 0x00): a 1 in the SECOND argument changes the answer, so the
    ///   second argument is the memory (the latch has no inputs to read);
    /// - step(1, state empty, inputs 0x01) = (0x01, 0x01): the same 1 in the THIRD argument changes nothing (it is
    ///   the state-0 answer), so the third argument is the inputs, which this circuit ignores;
    /// - the first returned value moves with the memory given (0x01 from memory 0, 0x02 from memory 1) while the
    ///   output bit does not, so the first returned value is the new memory and the second is the outputs, the
    ///   order _stepAnswer and runStep assume.
    /// A real circuit with both inputs and memory would be a stronger check; none was found in a scan of 50
    /// processors, so the order is pinned on this latch only. Both probes checked with read-only calls at the
    /// fork block (2026-11-21).
    function test_fork_stepArgumentOrder() public view {
        (bytes memory ns, bytes memory out) = IProcessor(LATCH_PROC).step(LATCH_ID, hex"01", hex"");
        assertEq(ns, hex"02", "memory 1 in the state argument: new memory 2");
        assertEq(out, hex"00", "memory 1 in the state argument: output 0");

        (ns, out) = IProcessor(LATCH_PROC).step(LATCH_ID, hex"", hex"01");
        assertEq(ns, hex"01", "a 1 in the inputs argument is ignored: same new memory as memory 0");
        assertEq(out, hex"01", "a 1 in the inputs argument is ignored: same output as memory 0");
    }
}

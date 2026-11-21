// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {LatheBase} from "./LatheBase.sol";
import {LatheOrders} from "../src/LatheOrders.sol";
import {Piece, PieceKind} from "../src/FormulaLib.sol";
import {FormulaProcessor} from "./mocks/FormulaProcessor.sol";

/// @notice The contract-size split (V3a fix round): LatheOrders calls two linked libraries, LatheChecks (create-time
/// rules) and LatheReads (run, runStep, the piece join). These tests pin what the split must not change:
/// - the runtime stays under the 24,576-byte limit (EIP-170). Until V4 this pinned 19,500 bytes to keep room for the
///   next versions; V3b and V4 (top circuits, wires) used that room, so it now pins the hard limit;
/// - run's per-case gas guard still holds across the library hop. LatheOrders forwards only 63/64 of its gas to
///   LatheReads (EIP-150), and the guard runs inside LatheReads, so a caller with too little gas still gets
///   InsufficientGasForCase (or a plain out-of-gas revert), never an answer, and the gas the page asks for
///   (web/gas.js runGasLimit / runPiecedGasLimit) is still enough.
contract LatheOrdersLibsTest is LatheBase {
    FormulaProcessor fproc;

    uint32 constant GATES = 200; // budget 3,100,000 gas per case
    uint256 constant XOR_BURN = 10; // proc: XOR, burns nearly its whole budget
    uint256 constant GE_BURN = 11; // fproc: GreaterOrEqual(2, 2), burns nearly its whole budget
    uint256 constant ANDNOT_BURN = 12; // proc: 2-input table out = in0 AND NOT in1, burns nearly its whole budget

    // web/gas.js, kept equal by web/test/gas.test.mjs ("run gas ... library hop").
    uint256 constant RUN_OVERHEAD = 300_000;
    uint256 constant NETLIST_GAS_PER_GATE = 600;

    function setUp() public override {
        super.setUp();
        fproc = new FormulaProcessor();
        factory.setCPU(address(fproc), true);
        uint256 burn = lathe.evalBudget(GATES) - 60_000;
        setCircuitFromTable(XOR_BURN, builder, 2, 1, xorTable(), GATES);
        proc.setEvalGasCost(XOR_BURN, burn);
        fproc.setCircuit(GE_BURN, builder, false, 2, 2, GATES);
        fproc.setEvalGasCost(GE_BURN, burn);
        setCircuitFromTable(ANDNOT_BURN, builder, 2, 1, hex"02", GATES);
        proc.setEvalGasCost(ANDNOT_BURN, burn);
    }

    /// web/gas.js perCaseHold (rounded up, like the page).
    function hold(uint256 gates) internal view returns (uint256) {
        return (lathe.evalBudget(gates) * 64 + 62) / 63 + lathe.GAS_RESERVE();
    }

    /// web/gas.js runGasLimit: (overhead + netlist + one case's hold) x 64/63 for the library hop, rounded up.
    function pageRunGas(uint256 gates) internal view returns (uint256) {
        return ((RUN_OVERHEAD + NETLIST_GAS_PER_GATE * gates + hold(gates)) * 64 + 62) / 63;
    }

    /// web/gas.js runPiecedGasLimit: overhead + every piece's netlist and hold, x 64/63, rounded up.
    function pageRunPiecedGas(uint256 gatesA, uint256 gatesB) internal view returns (uint256) {
        uint256 g = RUN_OVERHEAD + NETLIST_GAS_PER_GATE * (gatesA + gatesB) + hold(gatesA) + hold(gatesB);
        return (g * 64 + 62) / 63;
    }

    /// A low-level call, not vm.expectRevert: the cheatcode does not see this revert for a view call given an
    /// explicit gas limit (seen while writing these tests), so the selector is checked by hand.
    function assertRefused(bool ok, bytes memory ret) internal pure {
        assertFalse(ok, "answered with too little gas");
        assertEq(bytes4(ret), LatheOrders.InsufficientGasForCase.selector, "not InsufficientGasForCase");
    }

    function test_size_underLimitWithRoom() public view {
        assertLe(address(lathe).code.length, 24_576, "LatheOrders runtime above the 24,576-byte limit");
    }

    function paidXor() internal returns (uint256 id) {
        id = createXor();
        vm.prank(builder);
        lathe.deliver{gas: 30_000_000}(id, address(proc), XOR_BURN); // 4 x 3.1M <= 30M: checked inline, paid
        (,,,,,,,, LatheOrders.Status s) = lathe.orders(id);
        assertEq(uint256(s), uint256(LatheOrders.Status.Paid));
    }

    /// The page's gas answers; the hold alone (what a pre-split caller could have squeezed in with) refuses.
    function test_run_libraryHop_pageGasAnswers_tooLittleRefuses() public {
        uint256 id = paidXor();
        bytes memory out = lathe.run{gas: pageRunGas(GATES)}(id, hex"01");
        assertEq(out, hex"01");
        (bool ok, bytes memory ret) = address(lathe).call{gas: hold(GATES)}(abi.encodeCall(lathe.run, (id, hex"03")));
        assertRefused(ok, ret);
    }

    /// Every gas limit from far too little to the page's figure gives either a refusal (InsufficientGasForCase or a
    /// plain out-of-gas revert) or the right answer. The smallest limit that answers is below the page's figure.
    function test_run_libraryHop_neverAWrongAnswer() public {
        uint256 id = paidXor();
        uint256 top = pageRunGas(GATES);
        uint256 firstAnswer;
        bool sawInsufficient;
        for (uint256 g = hold(GATES) - 200_000; g <= top; g += 25_000) {
            (bool ok, bytes memory ret) = address(lathe).call{gas: g}(abi.encodeCall(lathe.run, (id, hex"03")));
            if (ok) {
                assertEq(abi.decode(ret, (bytes)), hex"00", "wrong answer at some gas limit");
                if (firstAnswer == 0) firstAnswer = g;
            } else if (ret.length >= 4 && bytes4(ret) == LatheOrders.InsufficientGasForCase.selector) {
                assertEq(firstAnswer, 0, "refused after an answer at less gas");
                sawInsufficient = true;
            }
        }
        assertTrue(sawInsufficient, "never refused");
        assertGt(firstAnswer, 0, "never answered up to the page's gas");
        emit log_named_uint("smallest answering gas (25k steps)", firstAnswer);
        emit log_named_uint("page gas", top);
    }

    function paidBurningPair() internal returns (uint256 id) {
        Piece[] memory ps = new Piece[](2);
        ps[0] = Piece(PieceKind.GreaterOrEqual, 4, 1, 2, 2);
        ps[1] = Piece(PieceKind.Table, 2, 1, 0, 0);
        bytes[] memory ts = new bytes[](2);
        ts[1] = hex"02";
        vm.prank(buyer);
        id = lathe.createPiecedOrder(
            ps, ts, AMOUNT, uint64(block.timestamp + 1 days), builder, new uint32[](2), new bytes32[](0)
        );
        vm.startPrank(builder);
        lathe.deliverPiece{gas: 30_000_000}(id, 1, address(proc), ANDNOT_BURN); // 4 cases: inline
        lathe.deliverPiece{gas: 30_000_000}(id, 0, address(fproc), GE_BURN); // 16 x 3.1M > 30M: batched
        vm.stopPrank();
        lathe.checkPiece{gas: 100_000_000}(id, 0, 16);
        (,,,,,,,, LatheOrders.Status s) = lathe.orders(id);
        assertEq(uint256(s), uint256(LatheOrders.Status.Paid));
    }

    /// Two pieces, each burning nearly its whole budget: the page's two-piece figure answers; sized for one piece
    /// only, the second eval's guard refuses.
    function test_run_twoPiece_pageGasAnswers_onePieceGasRefuses() public {
        uint256 id = paidBurningPair();
        // x = a | b << 2 | x4 << 4; a = 3, b = 1, x4 = 0: a >= b and not x4, so 1.
        assertEq(lathe.run{gas: pageRunPiecedGas(GATES, GATES)}(id, hex"07"), hex"01");
        assertEq(lathe.run{gas: pageRunPiecedGas(GATES, GATES)}(id, hex"17"), hex"00");
        (bool ok, bytes memory ret) =
            address(lathe).call{gas: pageRunGas(GATES)}(abi.encodeCall(lathe.run, (id, hex"07")));
        assertRefused(ok, ret);
    }
}

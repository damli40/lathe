// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {WiredBase} from "./WiredBase.sol";
import {LatheOrders} from "../src/LatheOrders.sol";
import {Piece, PieceKind} from "../src/FormulaLib.sol";
import {Wire} from "../src/NetlistLib.sol";

/// @notice V4 (Task 13): orders of up to MAX_PIECES pieces with explicit wires, and the daily-cap example.
///
/// Wiring rules at create, each with a test here (LatheChecks._sortWires has the full list):
/// - forward only (lower to higher piece index): WiringNotForward;
/// - every piece input bit fed exactly once: InputUnconnected, FedTwice; every order output bit fed exactly once:
///   OutputUnconnected, FedTwice; at least one output;
/// - bit and piece indexes in range: BadWire; an order input straight to an order output: BadWire;
/// - order inputs are bits 0 .. nIn-1 (nIn = highest used + 1) and each must feed something: TopInputUnused;
/// - at most 64 order inputs (TooManyCases) and 64 outputs (TooManyOutputs); 1 to 8 pieces (BadPieceCount);
/// - the list may come in any order; it is stored sorted, so one wiring has one stored form and one fingerprint.
/// run without a top evaluates the pieces in index order along the wires (fuzzed against plain Solidity).
contract LatheOrdersChainTest is WiredBase {
    uint256 constant ADD88 = 1; // fproc ids
    uint256 constant GE89 = 2;
    uint256 constant ADD32 = 3;
    uint256 constant GE43 = 4;
    uint256 constant T32 = 10; // proc: 3-input, 2-output table
    uint256 constant NOT1 = 11; // proc: 1-input NOT
    uint32 constant DAILY_GATES = 70; // budget 1.15M per case: checked in batches

    function setUp() public override {
        super.setUp();
        fproc.setCircuit(ADD88, builder, true, 8, 8, DAILY_GATES);
        fproc.setCircuit(GE89, builder, false, 8, 9, DAILY_GATES);
        fproc.setCircuit(ADD32, builder, true, 3, 2, SMALL);
        fproc.setCircuit(GE43, builder, false, 4, 3, SMALL);
        setCircuitFromTable(T32, builder, 3, 2, t32Table(), SMALL);
        setCircuitFromTable(NOT1, builder, 1, 1, hex"01", SMALL);
    }

    // ---- the daily-cap example (examples/daily-cap.json) ----

    /// examples/daily-cap.json read field by field, so the test runs exactly the order the page and the crank use.
    function dailyCapSpec() internal view returns (LatheOrders.PiecedSpec memory s) {
        string memory j = vm.readFile("examples/daily-cap.json");
        uint256 np = _count(j, ".pieces");
        s.pieces = new Piece[](np);
        s.tables = new bytes[](np);
        s.maxGates = new uint32[](np);
        for (uint256 i = 0; i < np; ++i) {
            string memory p = string.concat(".pieces[", vm.toString(i), "]");
            s.pieces[i] = Piece(
                PieceKind(_u(j, p, ".kind")), uint8(_u(j, p, ".nIn")), uint8(_u(j, p, ".nOut")),
                uint8(_u(j, p, ".widthA")), uint8(_u(j, p, ".widthB"))
            );
            s.tables[i] = vm.parseJsonBytes(j, string.concat(".tables[", vm.toString(i), "]"));
            s.maxGates[i] = uint32(_u(j, string.concat(".maxGates[", vm.toString(i), "]"), ""));
        }
        uint256 nw = _count(j, ".wires");
        s.wires = new Wire[](nw);
        for (uint256 i = 0; i < nw; ++i) {
            string memory p = string.concat(".wires[", vm.toString(i), "]");
            s.wires[i] = Wire(
                uint8(_u(j, p, ".fromPiece")), uint8(_u(j, p, ".fromBit")), uint8(_u(j, p, ".toPiece")),
                uint8(_u(j, p, ".toBit"))
            );
        }
        assertEq(_count(j, ".labels"), 0);
        s.labels = new bytes32[](0);
        s.needsTop = vm.parseJsonBool(j, ".needsTop");
    }

    function _u(string memory j, string memory p, string memory f) internal pure returns (uint256) {
        return vm.parseJsonUint(j, string.concat(p, f));
    }

    function _count(string memory j, string memory p) internal view returns (uint256 n) {
        while (vm.keyExistsJson(j, string.concat(p, "[", vm.toString(n), "]"))) ++n;
    }

    function checkAll(uint256 id, uint256 piece, uint256 batch) internal {
        bool done;
        bool passed;
        while (!done) {
            (done, passed) = lathe.checkPiece(id, piece, batch);
        }
        assertTrue(passed, "piece failed");
    }

    function dailyInput(uint256 spent, uint256 amount, uint256 cap) internal pure returns (bytes memory) {
        return abi.encodePacked(uint8(spent), uint8(amount), uint8(cap));
    }

    /// Add(8, 8) of spent + amount, then GreaterOrEqual(cap, sum) gives "allowed".
    /// Layout: order input bits 0-7 = spent, 8-15 = amount, 16-23 = cap. Piece 1 = GreaterOrEqual(8, 9): a = cap in
    /// its inputs 0-7, b = the 9-bit sum in its inputs 8-16 (Add(8, 8) has 9 output bits, so widthB = 9).
    /// Both forms are run: the example's own "needs a top" (pays at deliverTop) and the same spec as "Lathe joins".
    function test_chain_dailyCap_mock() public {
        LatheOrders.PiecedSpec memory s = dailyCapSpec();
        assertTrue(s.needsTop);
        vm.prank(buyer);
        uint256 t = lathe.createPiecedOrder(s, AMOUNT, deadline, builder);
        s.needsTop = false;
        vm.prank(buyer);
        uint256 jn = lathe.createPiecedOrder(s, AMOUNT, deadline, builder);
        (uint8 nIn, uint8 nOut) = shape(t);
        assertEq(nIn, 24);
        assertEq(nOut, 1);
        uint256[2] memory orders_ = [t, jn];
        // 2 x 196,608 cases at ~13,000 gas each is more than forge's 2^30 gas for one test, so gas metering is
        // paused for the bulk checks. The per-case budget still applies: each eval is still given exactly
        // evalBudget(70) gas, and the guard still reads gasleft() (which stays high while metering is paused).
        vm.pauseGasMetering();
        for (uint256 k = 0; k < 2; ++k) {
            deliverP(orders_[k], 0, address(fproc), ADD88);
            deliverP(orders_[k], 1, address(fproc), GE89);
            checkAll(orders_[k], 0, 16_384); // 65,536 cases
            checkAll(orders_[k], 1, 16_384); // 131,072 cases
        }
        vm.resumeGasMetering();
        assertEq(uint8(status(jn)), uint8(LatheOrders.Status.Paid));
        assertEq(uint8(status(t)), uint8(LatheOrders.Status.Open)); // waits for its top circuit
        uint256 top = mintTop(t, builder);
        vm.prank(builder);
        lathe.deliverTop(t, address(rproc), top);
        assertEq(uint8(status(t)), uint8(LatheOrders.Status.Paid));
        for (uint256 k = 0; k < 2; ++k) {
            uint256 id = orders_[k];
            assertEq(lathe.run(id, dailyInput(100, 50, 200)), hex"01", "100 + 50 vs 200");
            assertEq(lathe.run(id, dailyInput(100, 150, 200)), hex"00", "100 + 150 vs 200");
            assertEq(lathe.run(id, dailyInput(100, 100, 200)), hex"01", "equal is allowed");
            assertEq(lathe.run(id, dailyInput(255, 255, 255)), hex"00", "9-bit sum: 510 is not 254");
            assertEq(lathe.run(id, dailyInput(0, 0, 0)), hex"01");
        }
    }

    // ---- wiring refusals ----

    /// Two NOT pieces in a row: x0 -> NOT -> NOT -> y0.
    function notChain() internal pure returns (Piece[] memory ps, bytes[] memory ts, Wire[] memory ws) {
        ps = new Piece[](2);
        ps[0] = tablePiece(1, 1);
        ps[1] = tablePiece(1, 1);
        ts = new bytes[](2);
        ts[0] = hex"01";
        ts[1] = hex"01";
        ws = new Wire[](3);
        ws[0] = w(TOP, 0, 0, 0);
        ws[1] = w(0, 0, 1, 0);
        ws[2] = w(1, 0, TOP, 0);
    }

    function test_wiring_backward_reverts() public {
        (Piece[] memory ps, bytes[] memory ts, Wire[] memory ws) = notChain();
        ws[0] = w(1, 0, 0, 0); // piece 0 fed by piece 1
        ws[1] = w(TOP, 0, 1, 0);
        expectCreateRevert(spec(ps, ts, ws, false), LatheOrders.WiringNotForward.selector);
        (ps, ts, ws) = notChain();
        ws[1] = w(1, 0, 1, 0); // piece 1 fed by itself
        expectCreateRevert(spec(ps, ts, ws, false), LatheOrders.WiringNotForward.selector);
    }

    function test_wiring_unconnectedInput_reverts() public {
        (Piece[] memory ps, bytes[] memory ts, Wire[] memory ws) = notChain();
        Wire[] memory two = new Wire[](2);
        two[0] = ws[0];
        two[1] = ws[2]; // piece 1's input has no wire
        expectCreateRevert(spec(ps, ts, two, false), LatheOrders.InputUnconnected.selector);
    }

    function test_wiring_fedTwice_reverts() public {
        (Piece[] memory ps, bytes[] memory ts, Wire[] memory ws) = notChain();
        Wire[] memory four = new Wire[](4);
        four[0] = ws[0];
        four[1] = ws[1];
        four[2] = ws[2];
        four[3] = w(TOP, 0, 1, 0); // piece 1's input fed a second time
        expectCreateRevert(spec(ps, ts, four, false), LatheOrders.FedTwice.selector);
        four[3] = w(0, 0, TOP, 0); // order output 0 fed a second time
        expectCreateRevert(spec(ps, ts, four, false), LatheOrders.FedTwice.selector);
    }

    function test_wiring_outputs_reverts() public {
        (Piece[] memory ps, bytes[] memory ts, Wire[] memory ws) = notChain();
        ws[2] = w(1, 0, TOP, 1); // output 1 fed, output 0 not
        expectCreateRevert(spec(ps, ts, ws, false), LatheOrders.OutputUnconnected.selector);
        Wire[] memory none = new Wire[](2);
        none[0] = ws[0];
        none[1] = ws[1]; // no output at all
        expectCreateRevert(spec(ps, ts, none, false), LatheOrders.OutputUnconnected.selector);
    }

    function test_wiring_badBits_reverts() public {
        Piece[] memory ps;
        bytes[] memory ts;
        Wire[] memory ws;
        (ps, ts, ws) = notChain();
        ws[1] = w(0, 1, 1, 0); // piece 0 has 1 output
        expectCreateRevert(spec(ps, ts, ws, false), LatheOrders.BadWire.selector);
        (ps, ts, ws) = notChain();
        ws[1] = w(0, 0, 1, 1); // piece 1 has 1 input
        expectCreateRevert(spec(ps, ts, ws, false), LatheOrders.BadWire.selector);
        (ps, ts, ws) = notChain();
        ws[1] = w(0, 0, 2, 0); // no piece 2
        expectCreateRevert(spec(ps, ts, ws, false), LatheOrders.BadWire.selector);
        (ps, ts, ws) = notChain();
        ws[2] = w(5, 0, TOP, 0); // from no piece 5
        expectCreateRevert(spec(ps, ts, ws, false), LatheOrders.BadWire.selector);
        (ps, ts, ws) = notChain();
        Wire[] memory four = new Wire[](4);
        (four[0], four[1], four[2]) = (ws[0], ws[1], ws[2]);
        four[3] = w(TOP, 0, TOP, 1); // input straight to an output
        expectCreateRevert(spec(ps, ts, four, false), LatheOrders.BadWire.selector);
    }

    function test_wiring_unusedInput_reverts() public {
        (Piece[] memory ps, bytes[] memory ts, Wire[] memory ws) = notChain();
        ws[0] = w(TOP, 1, 0, 0); // input 1 used, input 0 never
        expectCreateRevert(spec(ps, ts, ws, false), LatheOrders.TopInputUnused.selector);
    }

    /// Order inputs and outputs are capped at 64 each.
    function test_wiring_caps_reverts() public {
        // 4 x GreaterOrEqual(8, 9) = 68 input bits; order inputs 0..64 (65), the rest fed by input 0.
        Piece[] memory ps = new Piece[](4);
        for (uint256 k = 0; k < 4; ++k) {
            ps[k] = ge(8, 9);
        }
        Wire[] memory ws = new Wire[](69);
        uint256 n;
        for (uint256 k = 0; k < 4; ++k) {
            for (uint256 j = 0; j < 17; ++j) {
                uint256 b = k * 17 + j;
                ws[n++] = w(TOP, uint8(b <= 64 ? b : 0), uint8(k), uint8(j));
            }
        }
        ws[n] = w(3, 0, TOP, 0);
        expectCreateRevert(spec(ps, new bytes[](4), ws, false), LatheOrders.TooManyCases.selector);
        // 4 x Add(16, 1) = 68 output bits; order outputs 0..64 (65).
        for (uint256 k = 0; k < 4; ++k) {
            ps[k] = add(16, 1);
        }
        Wire[] memory wo = new Wire[](68 + 65);
        n = 0;
        for (uint256 k = 0; k < 4; ++k) {
            for (uint256 j = 0; j < 17; ++j) {
                wo[n++] = w(TOP, uint8(j), uint8(k), uint8(j));
            }
        }
        for (uint256 b = 0; b < 65; ++b) {
            wo[n++] = w(uint8(b / 17), uint8(b % 17), TOP, uint8(b));
        }
        expectCreateRevert(spec(ps, new bytes[](4), wo, false), LatheOrders.TooManyOutputs.selector);
    }

    /// 8 pieces is the most (MAX_PIECES); 9 is refused. Eight NOTs in a row: y = x when the count is even.
    function test_maxPieces_eight_ok_nine_reverts() public {
        assertEq(lathe.MAX_PIECES(), 8);
        for (uint256 count = 8; count <= 9; ++count) {
            Piece[] memory ps = new Piece[](count);
            bytes[] memory ts = new bytes[](count);
            Wire[] memory ws = new Wire[](count + 1);
            for (uint256 k = 0; k < count; ++k) {
                ps[k] = tablePiece(1, 1);
                ts[k] = hex"01";
                ws[k] = k == 0 ? w(TOP, 0, 0, 0) : w(uint8(k - 1), 0, uint8(k), 0);
            }
            ws[count] = w(uint8(count - 1), 0, TOP, 0);
            if (count == 9) {
                expectCreateRevert(spec(ps, ts, ws, false), LatheOrders.BadPieceCount.selector);
                continue;
            }
            uint256 id = createWired(ps, ts, ws, true);
            for (uint256 k = 0; k < count; ++k) {
                deliverP(id, k, address(proc), NOT1);
            }
            uint256 top = mintTop(id, builder);
            vm.prank(builder);
            lathe.deliverTop(id, address(rproc), top);
            assertEq(lathe.run(id, hex"01"), hex"01");
            assertEq(lathe.run(id, hex"00"), hex"00");
            assertEq(lathe.expectedTopNetlist(id).length, 8 * 34);
        }
    }

    /// The overload without wires keeps its V3a limit of 2 pieces (test_create_counts_and_join covers 3).
    function test_wirelessOverload_staysAtTwo() public {
        assertEq(lathe.MAX_PIECES(), 8);
        Piece[] memory ps = new Piece[](3);
        ps[0] = tablePiece(1, 1);
        ps[1] = tablePiece(1, 1);
        ps[2] = tablePiece(1, 1);
        bytes[] memory ts = new bytes[](3);
        vm.prank(buyer);
        vm.expectRevert(LatheOrders.BadPieceCount.selector);
        lathe.createPiecedOrder(ps, ts, AMOUNT, deadline, builder, new uint32[](3), new bytes32[](0));
    }

    // ---- run along the wires ----

    /// 8 inputs x0..x7. Piece 0 = Add(3, 2) on x0..x4 (4-bit sum s). Piece 1 = GreaterOrEqual(4, 3): a = s, b = x5..x7.
    /// Piece 2 = a 3-input, 2-output table T on (piece 1's answer, s3, x0). Outputs, deliberately not in piece order:
    /// y0 = T's bit 1, y1 = s0, y2 = piece 1's answer. So x0 and s feed more than one piece.
    function chainParts() internal pure returns (Piece[] memory ps, bytes[] memory ts, Wire[] memory ws) {
        ps = new Piece[](3);
        ps[0] = add(3, 2);
        ps[1] = ge(4, 3);
        ps[2] = tablePiece(3, 2);
        ts = new bytes[](3);
        ts[2] = t32Table();
        ws = new Wire[](5 + 7 + 3 + 3);
        uint256 n;
        for (uint256 j = 0; j < 5; ++j) {
            ws[n++] = w(TOP, uint8(j), 0, uint8(j));
        }
        for (uint256 j = 0; j < 4; ++j) {
            ws[n++] = w(0, uint8(j), 1, uint8(j));
        }
        for (uint256 j = 0; j < 3; ++j) {
            ws[n++] = w(TOP, uint8(5 + j), 1, uint8(4 + j));
        }
        ws[n++] = w(1, 0, 2, 0);
        ws[n++] = w(0, 3, 2, 1);
        ws[n++] = w(TOP, 0, 2, 2);
        ws[n++] = w(2, 1, TOP, 0);
        ws[n++] = w(0, 0, TOP, 1);
        ws[n++] = w(1, 0, TOP, 2);
    }

    /// T(c) = (3c + 1) mod 4, 2 bits per case, 8 cases.
    function t32Table() internal pure returns (bytes memory t) {
        t = new bytes(2);
        for (uint256 c = 0; c < 8; ++c) {
            uint256 v = (3 * c + 1) & 3;
            uint256 bit = 2 * c;
            t[bit / 8] = bytes1(uint8(t[bit / 8]) | uint8(v << (bit % 8)));
        }
    }

    function chainSolidity(uint256 x) internal pure returns (uint256) {
        uint256 s = (x & 7) + ((x >> 3) & 3);
        uint256 g = s >= (x >> 5) ? 1 : 0;
        uint256 c = g | (((s >> 3) & 1) << 1) | ((x & 1) << 2);
        uint256 tv = (3 * c + 1) & 3;
        return ((tv >> 1) & 1) | ((s & 1) << 1) | (g << 2);
    }

    function paidChain(Wire[] memory ws) internal returns (uint256 id) {
        (Piece[] memory ps, bytes[] memory ts,) = chainParts();
        id = createWired(ps, ts, ws, false);
        deliverP(id, 0, address(fproc), ADD32);
        deliverP(id, 1, address(fproc), GE43);
        deliverP(id, 2, address(proc), T32);
        assertEq(uint8(status(id)), uint8(LatheOrders.Status.Paid));
    }

    function testFuzz_chainRun_matchesSolidity(uint8 x) public {
        (,, Wire[] memory ws) = chainParts();
        uint256 id = paidChain(ws);
        assertEq(lathe.run(id, abi.encodePacked(x)), abi.encodePacked(uint8(chainSolidity(x))));
    }

    function test_chainRun_everyInput() public {
        (,, Wire[] memory ws) = chainParts();
        uint256 id = paidChain(ws);
        for (uint256 x = 0; x < 256; ++x) {
            assertEq(lathe.run(id, abi.encodePacked(uint8(x))), abi.encodePacked(uint8(chainSolidity(x))));
        }
        (uint8 nIn, uint8 nOut) = shape(id);
        assertEq(nIn, 8);
        assertEq(nOut, 3);
    }

    /// The buyer may list wires in any order: the stored form, the fingerprint and the answers are the same.
    function testFuzz_wireOrder_doesNotMatter(uint256 seed) public {
        (Piece[] memory ps, bytes[] memory ts, Wire[] memory sorted) = chainParts();
        Wire[] memory ws = new Wire[](sorted.length);
        for (uint256 i = 0; i < ws.length; ++i) {
            ws[i] = sorted[i];
        }
        for (uint256 i = ws.length - 1; i > 0; --i) {
            uint256 j = uint256(keccak256(abi.encode(seed, i))) % (i + 1);
            (ws[i], ws[j]) = (ws[j], ws[i]);
        }
        uint256 id = paidChain(ws);
        assertEq(keccak256(abi.encode(lathe.wiresOf(id))), keccak256(abi.encode(sorted)));
        assertEq(lathe.piecedHash(id), keccak256(abi.encode(ps, ts, sorted)));
        uint8 x = uint8(seed >> 200);
        assertEq(lathe.run(id, abi.encodePacked(x)), abi.encodePacked(uint8(chainSolidity(x))));
    }

    /// A V3a order (no wires) reports its fixed A -> B join as wires; the same wires given explicitly run the same.
    function test_wiresOf_wirelessOrder_isTheJoin() public {
        Piece[] memory ps = new Piece[](2);
        ps[0] = add(3, 2);
        ps[1] = ge(4, 3);
        bytes[] memory ts = new bytes[](2);
        vm.prank(buyer);
        uint256 old = lathe.createPiecedOrder(ps, ts, AMOUNT, deadline, builder, new uint32[](2), new bytes32[](0));
        Wire[] memory ws = lathe.wiresOf(old);
        assertEq(ws.length, 5 + 7 + 1);
        assertEq(ws[5].fromPiece, 0); // B's input 0 <- A's output 0
        assertEq(ws[9].fromPiece, TOP); // B's input 4 <- order input 5 (A.nIn)
        assertEq(ws[9].fromBit, 5);
        assertEq(ws[12].toPiece, TOP);
        uint256 wired = createWired(ps, ts, ws, false);
        deliverP(old, 0, address(fproc), ADD32);
        deliverP(old, 1, address(fproc), GE43);
        deliverP(wired, 0, address(fproc), ADD32);
        deliverP(wired, 1, address(fproc), GE43);
        for (uint256 x = 0; x < 256; ++x) {
            bytes memory inp = abi.encodePacked(uint8(x));
            assertEq(lathe.run(wired, inp), lathe.run(old, inp));
        }
        // The old order keeps its old fingerprint (no wires in it).
        assertEq(lathe.piecedHash(old), keccak256(abi.encode(ps, ts)));
        assertEq(lathe.wiresOf(createXor()).length, 0); // V0 order: no wires
    }

    function test_chain_rejectedPiece_reopensOnlyThatPiece() public {
        (Piece[] memory ps, bytes[] memory ts, Wire[] memory ws) = chainParts();
        uint256 id = createWired(ps, ts, ws, false);
        deliverP(id, 0, address(fproc), ADD32);
        fproc.setCircuit(99, builder, false, 4, 3, BATCHED_GATES);
        fproc.setWrongAt(99, 7);
        deliverP(id, 1, address(fproc), 99);
        (bool done, bool passed) = lathe.checkPiece(id, 1, 200);
        assertTrue(done);
        assertFalse(passed);
        (address p0,,,,, uint32 n0) = lathe.pieceOf(id, 0);
        assertEq(p0, address(fproc));
        assertEq(n0, 32);
        deliverP(id, 1, address(fproc), GE43);
        deliverP(id, 2, address(proc), T32);
        assertEq(uint8(status(id)), uint8(LatheOrders.Status.Paid));
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {WiredBase} from "./WiredBase.sol";
import {LatheOrders} from "../src/LatheOrders.sol";
import {IProcessor} from "../src/ITapeOut.sol";
import {Piece, PieceKind} from "../src/FormulaLib.sol";
import {Wire, WIRE_TOP} from "../src/NetlistLib.sol";

/// @notice Fixes from the adversarial review of the V3b (top circuit) and V4 (wired pieces) commits, Nov 21:
/// 1. ruleOf and the receipt named a 1-piece order's circuit even when the wires swap, fan out or drop bits, so the
///    named circuit computed another rule (or had another shape). Now only a circuit that computes the order's
///    rule exactly as is gets named: test_ruleOf_*.
/// 2. deliverTop refused an honest top whose pieces' gates add up to more than about 6,660 (the case-check size
///    guard, which a top never needs): test_honestTop_bigPieces_pays.
/// 3. run on a paid top gave the top only 100,000 + 15,000 per gate, far less than real REF records cost:
///    test_run_topOfOneGatePieces_answers (the mock RefProcessor now charges a realistic gas cost per REF).
/// Plus the reviewer's random-wiring check against an independent evaluator (3,000 wirings) and a gas sweep.
contract LatheOrdersReviewTest is WiredBase {
    uint256 nextCid = 100;

    // ---- 1. ruleOf names a circuit only when it computes the order's rule as is ----

    /// The reviewer's repro: piece "a AND NOT b", wires order bit 1 -> pin 0 and bit 0 -> pin 1, so the order's
    /// rule is "x1 AND NOT x0". On input 0x01, run says 0 and the piece circuit says 1. Before the fix ruleOf named
    /// that piece circuit; now there is no single circuit.
    function test_ruleOf_onePieceSwappedInputs_noSingleCircuit() public {
        Piece[] memory ps = new Piece[](1);
        ps[0] = tablePiece(2, 1);
        bytes[] memory ts = new bytes[](1);
        ts[0] = hex"02"; // case 1 (a = 1, b = 0) -> 1: a AND NOT b
        setCircuitFromTable(7, builder, 2, 1, ts[0], 3);
        Wire[] memory ws = new Wire[](3);
        ws[0] = w(TOP, 1, 0, 0);
        ws[1] = w(TOP, 0, 0, 1);
        ws[2] = w(0, 0, TOP, 0);
        uint256 id = createWired(ps, ts, ws, false);
        deliverP(id, 0, address(proc), 7);
        assertEq(uint8(status(id)), uint8(LatheOrders.Status.Paid));
        assertEq(lathe.run(id, hex"01"), hex"00", "run follows the wires");
        assertEq(proc.eval(7, hex"01"), hex"01", "the piece circuit computes another rule");
        _assertNoSingle(id);
    }

    /// The order has 1 input and 1 output (x0 fans out to both pins, only piece output 1 is used); the piece circuit
    /// has 2 and 2. Before the fix ruleOf named it.
    function test_ruleOf_onePieceFanOutAndDroppedOutput_noSingleCircuit() public {
        Piece[] memory ps = new Piece[](1);
        ps[0] = tablePiece(2, 2);
        bytes[] memory ts = new bytes[](1);
        ts[0] = hex"e4"; // answers 0, 1, 2, 3 (identity)
        setCircuitFromTable(8, builder, 2, 2, ts[0], 3);
        Wire[] memory ws = new Wire[](3);
        ws[0] = w(TOP, 0, 0, 0);
        ws[1] = w(TOP, 0, 0, 1);
        ws[2] = w(0, 1, TOP, 0);
        uint256 id = createWired(ps, ts, ws, false);
        (uint8 nIn, uint8 nOut) = shape(id);
        assertEq(nIn, 1);
        assertEq(nOut, 1);
        deliverP(id, 0, address(proc), 8);
        assertEq(uint8(status(id)), uint8(LatheOrders.Status.Paid));
        _assertNoSingle(id);
    }

    /// Only one output dropped, inputs in order: still another shape, so no single circuit.
    function test_ruleOf_onePieceDroppedOutputOnly_noSingleCircuit() public {
        Piece[] memory ps = new Piece[](1);
        ps[0] = tablePiece(2, 2);
        bytes[] memory ts = new bytes[](1);
        ts[0] = hex"e4";
        setCircuitFromTable(8, builder, 2, 2, ts[0], 3);
        Wire[] memory ws = new Wire[](3);
        ws[0] = w(TOP, 0, 0, 0);
        ws[1] = w(TOP, 1, 0, 1);
        ws[2] = w(0, 0, TOP, 0);
        uint256 id = createWired(ps, ts, ws, false);
        deliverP(id, 0, address(proc), 8);
        _assertNoSingle(id);
    }

    /// Outputs swapped, inputs in order: another rule.
    function test_ruleOf_onePieceSwappedOutputs_noSingleCircuit() public {
        Piece[] memory ps = new Piece[](1);
        ps[0] = tablePiece(2, 2);
        bytes[] memory ts = new bytes[](1);
        ts[0] = hex"e4";
        setCircuitFromTable(8, builder, 2, 2, ts[0], 3);
        Wire[] memory ws = new Wire[](4);
        ws[0] = w(TOP, 0, 0, 0);
        ws[1] = w(TOP, 1, 0, 1);
        ws[2] = w(0, 1, TOP, 0);
        ws[3] = w(0, 0, TOP, 1);
        uint256 id = createWired(ps, ts, ws, false);
        deliverP(id, 0, address(proc), 8);
        _assertNoSingle(id);
    }

    /// The identity wiring (listed out of order on purpose): the piece circuit is the rule, so it is named.
    function test_ruleOf_onePieceIdentityWires_namesPiece() public {
        Piece[] memory ps = new Piece[](1);
        ps[0] = tablePiece(2, 2);
        bytes[] memory ts = new bytes[](1);
        ts[0] = hex"b4"; // answers 0, 1, 3, 2
        setCircuitFromTable(9, builder, 2, 2, ts[0], 3);
        Wire[] memory ws = new Wire[](4);
        ws[0] = w(0, 1, TOP, 1);
        ws[1] = w(TOP, 1, 0, 1);
        ws[2] = w(0, 0, TOP, 0);
        ws[3] = w(TOP, 0, 0, 0);
        uint256 id = createWired(ps, ts, ws, false);
        deliverP(id, 0, address(proc), 9);
        (address rp, uint256 rc) = lathe.ruleOf(id);
        assertEq(rp, address(proc));
        assertEq(rc, 9);
        (address p, uint256 c,,) = lathe.receipts(id);
        assertEq(p, address(proc));
        assertEq(c, 9);
        for (uint8 x = 0; x < 4; ++x) {
            assertEq(proc.eval(rc, abi.encodePacked(x)), lathe.run(id, abi.encodePacked(x)));
        }
    }

    /// A 1-piece order made without wires still names its circuit (unchanged).
    function test_ruleOf_onePieceNoWires_namesPiece() public {
        Piece[] memory ps = new Piece[](1);
        ps[0] = tablePiece(2, 1);
        bytes[] memory ts = new bytes[](1);
        ts[0] = hex"02";
        setCircuitFromTable(7, builder, 2, 1, ts[0], 3);
        vm.prank(buyer);
        uint256 id = lathe.createPiecedOrder(ps, ts, AMOUNT, deadline, builder, new uint32[](1), new bytes32[](0));
        deliverP(id, 0, address(proc), 7);
        (address rp, uint256 rc) = lathe.ruleOf(id);
        assertEq(rp, address(proc));
        assertEq(rc, 7);
    }

    function _assertNoSingle(uint256 id) internal {
        (address p, uint256 c,,) = lathe.receipts(id);
        assertEq(p, address(0), "receipt names a processor");
        assertEq(c, 0, "receipt names a circuit");
        vm.expectRevert(LatheOrders.NoSingleCircuit.selector);
        lathe.ruleOf(id);
    }

    // ---- 2. deliverTop has no case-check size guard ----

    /// The reviewer's repro: two honest 4,000-gate pieces each pass (evalBudget 60.1M <= 100M), but the top's gate
    /// count is their sum, 8,000 (evalBudget 120.1M > MAX_CASE_GAS). Before the fix deliverTop reverted
    /// CircuitTooBigToCheck and the order could only refund; now it pays, and run answers when given the gas.
    function test_honestTop_bigPieces_pays() public {
        uint256 id = _bigPieceTopOrder();
        uint256 top = mintTop(id, builder);
        (,,, uint32 g) = rproc.circuitInfo(top);
        assertEq(g, 8000);
        assertGt(lathe.evalBudget(g), lathe.MAX_CASE_GAS());
        uint256 before = usdt.balanceOf(builder);
        vm.prank(builder);
        lathe.deliverTop(id, address(rproc), top);
        assertEq(uint8(status(id)), uint8(LatheOrders.Status.Paid));
        assertEq(usdt.balanceOf(builder) - before, AMOUNT - AMOUNT / 100);
        (address rp, uint256 rc) = lathe.ruleOf(id);
        assertEq(rp, address(rproc));
        assertEq(rc, top);
        // identity then NOT: y = NOT x
        assertEq(lathe.run{gas: 200_000_000}(id, hex"00"), hex"01");
        assertEq(lathe.run{gas: 200_000_000}(id, hex"01"), hex"00");
    }

    /// The size guard still applies where a circuit is checked case by case.
    function test_sizeGuard_stillOnDeliverAndDeliverPiece() public {
        uint32 tooBig = uint32((lathe.MAX_CASE_GAS() - lathe.EVAL_BASE_GAS()) / lathe.EVAL_GAS_PER_GATE() + 1);
        setCircuitFromTable(40, builder, 2, 1, xorTable(), tooBig);
        uint256 v0 = createXor();
        vm.prank(builder);
        vm.expectRevert(LatheOrders.CircuitTooBigToCheck.selector);
        lathe.deliver(v0, address(proc), 40);
        Piece[] memory ps = new Piece[](1);
        ps[0] = tablePiece(2, 1);
        bytes[] memory ts = new bytes[](1);
        ts[0] = xorTable();
        Wire[] memory ws = new Wire[](3);
        ws[0] = w(TOP, 0, 0, 0);
        ws[1] = w(TOP, 1, 0, 1);
        ws[2] = w(0, 0, TOP, 0);
        uint256 id = createWired(ps, ts, ws, true);
        vm.prank(builder);
        vm.expectRevert(LatheOrders.CircuitTooBigToCheck.selector);
        lathe.deliverPiece(id, 0, address(proc), 40);
    }

    function _bigPieceTopOrder() internal returns (uint256 id) {
        Piece[] memory ps = new Piece[](2);
        ps[0] = tablePiece(1, 1);
        ps[1] = tablePiece(1, 1);
        bytes[] memory ts = new bytes[](2);
        ts[0] = hex"02"; // identity
        ts[1] = hex"01"; // NOT
        setCircuitFromTable(21, builder, 1, 1, ts[0], 4000);
        setCircuitFromTable(22, builder, 1, 1, ts[1], 4000);
        Wire[] memory ws = new Wire[](3);
        ws[0] = w(TOP, 0, 0, 0);
        ws[1] = w(0, 0, 1, 0);
        ws[2] = w(1, 0, TOP, 0);
        id = createWired(ps, ts, ws, true);
        deliverP(id, 0, address(proc), 21);
        deliverP(id, 1, address(proc), 22);
        // 2 cases x 60.1M > 30M: checked with checkPiece, one case per call
        for (uint256 k = 0; k < 2; ++k) {
            for (uint256 c = 0; c < 2; ++c) {
                lathe.checkPiece{gas: 70_000_000}(id, k, 1);
            }
        }
        assertEq(uint8(status(id)), uint8(LatheOrders.Status.Open));
    }

    // ---- 3. run on a top budgets its REF records ----

    /// 8 one-gate XOR pieces in a chain (parity of 9 inputs), as a top. Old budget: 100,000 + 15,000 x 8 = 220,000,
    /// below what 8 REFs cost (the mock charges REF_GAS per REF, about the real cost), so run refused every input.
    /// Now the top gets 150,000 more per piece and answers right on every input with the page's gas figure.
    function test_run_topOfOneGatePieces_answers() public {
        uint256 id = _parityTop(8);
        assertEq(pageTopRunGas(id), 1_821_603, "the page's figure (web/test/gas.test.mjs, run gas for a top)");
        for (uint256 x = 0; x < 512; x += 37) {
            bytes memory inp = _pack(x, 9);
            uint256 parity;
            for (uint256 b = 0; b < 9; ++b) {
                parity ^= (x >> b) & 1;
            }
            assertEq(lathe.run{gas: pageTopRunGas(id)}(id, inp), abi.encodePacked(uint8(parity)), "run via the top");
        }
    }

    /// The same top: every gas limit up to the page's figure either answers right or refuses, never a wrong answer,
    /// and the old budget (evalBudget(gates) alone) is not enough for this top's eval.
    function test_run_topOfOneGatePieces_gasSweep_neverWrong() public {
        uint256 id = _parityTop(8);
        (, uint256 top,,,,) = lathe.deliveries(id);
        (,,, uint32 gates) = rproc.circuitInfo(top);
        (bool okOld,) = address(rproc).staticcall{gas: lathe.evalBudget(gates)}(abi.encodeCall(IProcessor.eval, (top, _pack(1, 9))));
        assertFalse(okOld, "the old budget would have been enough: the mock REF cost is not realistic");
        uint256 answered;
        for (uint256 g = 200_000; g <= pageTopRunGas(id); g += 41_011) {
            (bool ok, bytes memory ret) = address(lathe).call{gas: g}(abi.encodeCall(lathe.run, (id, _pack(3, 9))));
            if (ok) {
                assertEq(abi.decode(ret, (bytes)), hex"00", "wrong answer under a gas cap");
                answered++;
            }
        }
        assertGt(answered, 0, "never answered up to the page's gas");
    }

    /// web/gas.js runTopGasLimit: overhead + every piece's netlist read + the top's netlist read + the top's hold,
    /// x 64/63 for the library hop, rounded up. Kept equal by web/test/gas.test.mjs ("run gas for a top").
    function pageTopRunGas(uint256 id) internal view returns (uint256) {
        Piece[] memory ps = lathe.piecesOf(id);
        uint256 g = 300_000;
        uint256 topBytes;
        for (uint256 k = 0; k < ps.length; ++k) {
            (,,, uint32 pg,,) = lathe.pieceOf(id, k);
            g += 600 * uint256(pg);
            topBytes += 31 + 3 * uint256(ps[k].nIn); // the top's own netlist: one REF record per piece
        }
        (,,, uint32 topGates,,) = lathe.deliveries(id);
        g += 600 * ((topBytes + 6) / 7);
        uint256 budget = lathe.evalBudget(topGates) + lathe.EVAL_GAS_PER_REF() * ps.length;
        g += (budget * 64 + 62) / 63 + lathe.GAS_RESERVE();
        return (g * 64 + 62) / 63;
    }

    /// n one-gate XOR pieces: piece 0 = x0 ^ x1, piece k = piece(k-1) ^ x(k+1); output = the last piece. As a top.
    function _parityTop(uint256 n) internal returns (uint256 id) {
        Piece[] memory ps = new Piece[](n);
        bytes[] memory ts = new bytes[](n);
        Wire[] memory ws = new Wire[](2 * n + 1);
        setCircuitFromTable(50, builder, 2, 1, xorTable(), 1);
        for (uint256 k = 0; k < n; ++k) {
            ps[k] = tablePiece(2, 1);
            ts[k] = xorTable();
            ws[2 * k] = k == 0 ? w(TOP, 0, 0, 0) : w(uint8(k - 1), 0, uint8(k), 0);
            ws[2 * k + 1] = w(TOP, uint8(k + 1), uint8(k), 1);
        }
        ws[2 * n] = w(uint8(n - 1), 0, TOP, 0);
        id = createWired(ps, ts, ws, true);
        for (uint256 k = 0; k < n; ++k) {
            deliverP(id, k, address(proc), 50);
        }
        uint256 top = mintTop(id, builder);
        vm.prank(builder);
        lathe.deliverTop(id, address(rproc), top);
        assertEq(uint8(status(id)), uint8(LatheOrders.Status.Paid));
    }

    // ---- the reviewer's random wirings against an independent evaluator ----

    struct G {
        Piece[] ps;
        bytes[] ts;
        Wire[] ws;
        uint8 nIn;
        uint8 nOut;
        bool lastOuts;
    }

    function _rand(uint256 seed, uint256 i) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(seed, i)));
    }

    /// A random valid wiring of 1 to 8 table pieces (1 to 3 inputs and outputs each), at most 7 order inputs, the
    /// wires shuffled. Half of them take their outputs from the last output bits (so they can be a top).
    function gen(uint256 seed) internal pure returns (G memory g) {
        uint256 r;
        uint256 n = 1 + _rand(seed, r++) % 8;
        g.ps = new Piece[](n);
        g.ts = new bytes[](n);
        uint256 totalIns;
        uint256 totalOuts;
        for (uint256 k = 0; k < n; ++k) {
            uint8 ni = uint8(1 + _rand(seed, r++) % 3);
            uint8 no = uint8(1 + _rand(seed, r++) % 3);
            g.ps[k] = Piece(PieceKind.Table, ni, no, 0, 0);
            uint256 bits = (uint256(1) << ni) * no;
            bytes memory t = new bytes((bits + 7) / 8);
            uint256 v = _rand(seed, r++);
            for (uint256 b = 0; b < bits; ++b) {
                if ((v >> b) & 1 == 1) t[b / 8] |= bytes1(uint8(1 << (b % 8)));
            }
            g.ts[k] = t;
            totalIns += ni;
            totalOuts += no;
        }
        uint8 nIn = uint8(1 + _rand(seed, r++) % 7);
        uint8 nOut = uint8(1 + _rand(seed, r++) % (totalOuts < 6 ? totalOuts : 6));
        g.lastOuts = _rand(seed, r++) % 2 == 0;
        Wire[] memory ws = new Wire[](totalIns + nOut);
        uint256 w_;
        for (uint256 k = 0; k < n; ++k) {
            for (uint8 j = 0; j < g.ps[k].nIn; ++j) {
                uint256 pick = _rand(seed, r++);
                if (k == 0 || pick % 3 == 0) {
                    ws[w_++] = Wire(WIRE_TOP, uint8(pick / 3 % nIn), uint8(k), j);
                } else {
                    uint8 fp = uint8(pick / 3 % k);
                    ws[w_++] = Wire(fp, uint8(pick / 7 % g.ps[fp].nOut), uint8(k), j);
                }
            }
        }
        // Shrink nIn until every order input 0 .. nIn-1 feeds something (inputs above nIn are moved to bit 0).
        uint256 used = _used(ws, w_);
        while (nIn > 0 && used != (uint256(1) << nIn) - 1) {
            nIn--;
            for (uint256 i = 0; i < w_; ++i) {
                if (ws[i].fromPiece == WIRE_TOP && ws[i].fromBit >= nIn) ws[i].fromBit = 0;
            }
            used = _used(ws, w_);
        }
        if (g.lastOuts) {
            uint256 skip = totalOuts - nOut;
            uint256 seen;
            uint8 j;
            for (uint256 k = 0; k < n; ++k) {
                for (uint8 b = 0; b < g.ps[k].nOut; ++b) {
                    if (seen++ >= skip) ws[w_++] = Wire(uint8(k), b, WIRE_TOP, j++);
                }
            }
        } else {
            for (uint8 j = 0; j < nOut; ++j) {
                uint256 pick = _rand(seed, r++);
                uint8 fp = uint8(pick % n);
                ws[w_++] = Wire(fp, uint8(pick / 11 % g.ps[fp].nOut), WIRE_TOP, j);
            }
        }
        for (uint256 i = w_; i > 1; --i) {
            uint256 jx = _rand(seed, r++) % i;
            (ws[i - 1], ws[jx]) = (ws[jx], ws[i - 1]);
        }
        g.ws = ws;
        g.nIn = nIn;
        g.nOut = nOut;
    }

    function _used(Wire[] memory ws, uint256 len) internal pure returns (uint256 used) {
        for (uint256 i = 0; i < len; ++i) {
            if (ws[i].fromPiece == WIRE_TOP) used |= uint256(1) << ws[i].fromBit;
        }
    }

    /// The rule from the wires as listed (any order) and the tables, without any Lathe code.
    function model(G memory g, uint256 x) internal pure returns (uint256 y) {
        uint256 n = g.ps.length;
        uint256[] memory outs = new uint256[](n);
        for (uint256 k = 0; k < n; ++k) {
            uint256 xin;
            for (uint256 i = 0; i < g.ws.length; ++i) {
                Wire memory e = g.ws[i];
                if (e.toPiece != k) continue;
                uint256 v = e.fromPiece == WIRE_TOP ? x : outs[e.fromPiece];
                xin |= ((v >> e.fromBit) & 1) << e.toBit;
            }
            uint256 no = g.ps[k].nOut;
            uint256 val;
            for (uint256 b = 0; b < no; ++b) {
                uint256 bit = xin * no + b;
                val |= ((uint256(uint8(g.ts[k][bit / 8])) >> (bit % 8)) & 1) << b;
            }
            outs[k] = val;
        }
        for (uint256 i = 0; i < g.ws.length; ++i) {
            Wire memory e = g.ws[i];
            if (e.toPiece != WIRE_TOP) continue;
            uint256 v = e.fromPiece == WIRE_TOP ? x : outs[e.fromPiece];
            y |= ((v >> e.fromBit) & 1) << e.toBit;
        }
    }

    /// Both kinds of the same random wiring: run (joined and via the top) equals the model on every input, and
    /// whenever ruleOf names a circuit, that circuit has the order's shape and gives the model's answer on every
    /// input (fix 1, as a property). A wiring refused as a top must be one without the last outputs.
    /// forge-config: default.fuzz.runs = 3000
    function testFuzz_randomWiring_matchesModel(uint256 seed) public {
        G memory g = gen(seed);
        uint256[] memory cids = new uint256[](g.ps.length);
        for (uint256 k = 0; k < g.ps.length; ++k) {
            cids[k] = nextCid++;
            setCircuitFromTable(cids[k], builder, g.ps[k].nIn, g.ps[k].nOut, g.ts[k], 3);
        }
        uint256 j = createWired(g.ps, g.ts, g.ws, false);
        (uint8 ni, uint8 no) = shape(j);
        assertEq(ni, g.nIn, "nIn");
        assertEq(no, g.nOut, "nOut");
        for (uint256 k = 0; k < g.ps.length; ++k) {
            deliverP(j, k, address(proc), cids[k]);
        }
        assertEq(uint8(status(j)), uint8(LatheOrders.Status.Paid));
        uint256 t;
        bool topOk = true;
        vm.prank(buyer);
        try lathe.createPiecedOrder(spec(g.ps, g.ts, g.ws, true), AMOUNT, deadline, builder) returns (uint256 id) {
            t = id;
        } catch (bytes memory err) {
            topOk = false;
            assertEq(bytes4(err), LatheOrders.TopNeedsLastOutputs.selector, "refusal reason");
            assertFalse(g.lastOuts, "a last-outputs wiring was refused");
        }
        if (topOk) {
            for (uint256 k = 0; k < g.ps.length; ++k) {
                deliverP(t, k, address(proc), cids[k]);
            }
            assertEq(uint8(status(t)), uint8(LatheOrders.Status.Open));
            uint256 top = mintTop(t, builder);
            vm.prank(builder);
            lathe.deliverTop(t, address(rproc), top);
            assertEq(uint8(status(t)), uint8(LatheOrders.Status.Paid));
        }
        (bool named, address rp, uint256 rc) = _rule(j);
        if (named) {
            (uint32 ci, uint32 co,,) = IProcessor(rp).circuitInfo(rc);
            assertEq(ci, g.nIn, "ruleOf circuit inputs");
            assertEq(co, g.nOut, "ruleOf circuit outputs");
        }
        for (uint256 x = 0; x < (uint256(1) << g.nIn); ++x) {
            bytes memory inp = _pack(x, g.nIn);
            bytes memory want = _pack(model(g, x), g.nOut);
            assertEq(lathe.run(j, inp), want, "joined");
            if (named) assertEq(IProcessor(rp).eval(rc, inp), want, "the circuit ruleOf names");
            if (topOk) assertEq(lathe.run(t, inp), want, "top");
        }
    }

    function _rule(uint256 id) internal view returns (bool, address, uint256) {
        try lathe.ruleOf(id) returns (address p, uint256 c) {
            return (true, p, c);
        } catch (bytes memory err) {
            assertEq(bytes4(err), LatheOrders.NoSingleCircuit.selector, "ruleOf reverted for another reason");
            return (false, address(0), 0);
        }
    }

    function _pack(uint256 v, uint256 n) internal pure returns (bytes memory out) {
        out = new bytes((n + 7) / 8);
        for (uint256 i = 0; i < out.length; ++i) {
            out[i] = bytes1(uint8(v >> (8 * i)));
        }
    }

    /// An order input wired straight to an order output is refused.
    function test_inputStraightToOutput_refused() public {
        Piece[] memory ps = new Piece[](1);
        ps[0] = tablePiece(1, 1);
        bytes[] memory ts = new bytes[](1);
        ts[0] = hex"02";
        Wire[] memory ws = new Wire[](3);
        ws[0] = w(TOP, 0, 0, 0);
        ws[1] = w(0, 0, TOP, 0);
        ws[2] = w(TOP, 0, TOP, 1);
        expectCreateRevert(spec(ps, ts, ws, false), LatheOrders.BadWire.selector);
    }

    /// A 3-piece joined chain whose pieces burn 200,000 gas each: across gas limits from 50,000 to 1.5M, run either
    /// answers right or refuses, never a wrong answer.
    function test_chainRun_gasSweep_neverWrong() public {
        Piece[] memory ps = new Piece[](3);
        bytes[] memory ts = new bytes[](3);
        for (uint256 k = 0; k < 3; ++k) {
            ps[k] = tablePiece(2, 1);
        }
        ts[0] = hex"08"; // AND
        ts[1] = hex"06"; // XOR
        ts[2] = hex"0e"; // OR
        for (uint256 k = 0; k < 3; ++k) {
            setCircuitFromTable(31 + k, builder, 2, 1, ts[k], 10);
            proc.setEvalGasCost(31 + k, 200_000); // budget for 10 gates is 250,000
        }
        Wire[] memory ws = new Wire[](7);
        ws[0] = w(TOP, 0, 0, 0);
        ws[1] = w(TOP, 1, 0, 1);
        ws[2] = w(0, 0, 1, 0);
        ws[3] = w(TOP, 2, 1, 1);
        ws[4] = w(1, 0, 2, 0);
        ws[5] = w(TOP, 0, 2, 1);
        ws[6] = w(2, 0, TOP, 0);
        uint256 id = createWired(ps, ts, ws, false);
        for (uint256 k = 0; k < 3; ++k) {
            vm.prank(builder);
            lathe.deliverPiece{gas: 30_000_000}(id, k, address(proc), 31 + k);
        }
        assertEq(uint8(status(id)), uint8(LatheOrders.Status.Paid));
        uint256 ok;
        uint256 refused;
        for (uint256 g = 50_000; g < 1_500_000; g += 7_919) {
            for (uint8 x = 0; x < 8; ++x) {
                uint256 a = x & 1;
                uint256 b = (x >> 1) & 1;
                uint256 c = (x >> 2) & 1;
                uint8 want = uint8((((a & b) ^ c) | a));
                try lathe.run{gas: g}(id, abi.encodePacked(x)) returns (bytes memory out) {
                    assertEq(out, abi.encodePacked(want), "wrong answer under gas cap");
                    ok++;
                } catch {
                    refused++;
                }
            }
        }
        assertGt(ok, 0);
        assertGt(refused, 0);
    }
}

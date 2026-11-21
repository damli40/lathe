// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {LatheOrders} from "../../src/LatheOrders.sol";
import {IProcessor} from "../../src/ITapeOut.sol";
import {Piece, PieceKind} from "../../src/FormulaLib.sol";
import {NetlistLib, Wire, WIRE_TOP} from "../../src/NetlistLib.sol";

interface IERC20W {
    function approve(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

interface IMintW {
    function tapeout(bytes calldata netlist, uint32 nIn, uint32 nOut) external payable returns (uint256);
    function TAPEOUT_FEE() external view returns (uint256);
}

interface IFactoryW {
    function isCPU(address) external view returns (bool);
}

/// @dev One eval with all the gas there is, measured inside this contract (no transaction overhead).
contract TopEvalMeter {
    function once(address p, uint256 id, bytes calldata x) external view returns (uint256 used, bytes memory out) {
        uint256 g0 = gasleft();
        out = IProcessor(p).eval(id, x);
        used = g0 - gasleft();
    }
}

/// @notice Wired top circuits on live TapeOut (from the adversarial review of V3b / V4, Nov 21). X Layer mainnet fork
/// pinned at block 76,480,000; every circuit and order is made on the local fork, nothing is sent to X Layer.
/// Five pieces with asymmetric pins are minted on three processors (some made of REFs to the live AND / NAND / XOR,
/// one REF to a REF-made piece), then five wirings W1 to W5 are each ordered twice, as "Lathe joins" and as "needs a
/// top circuit". The top is minted with the real tapeout from expectedTopNetlist and delivered. On every input:
/// eval(top) = run(joined order) = run(topped order) = an independent Solidity model of the wiring.
/// Fix 3 of that review: before it, run on the topped order refused every input of W1 to W5 (the top's budget was
/// only 100,000 + 15,000 per gate; real REF records cost far more). Now run must answer on every input
/// (refusals == 0), with the measured eval gas logged against the old and the new budget.
/// Run: forge test --match-path 'test/fork/WiringTopFork.t.sol' -vv  (warm: the pieces were just delivered)
///      forge test --match-path 'test/fork/WiringTopFork.t.sol' --isolate -vv  (cold: each call its own transaction)
/// Evidence: evidence/2026-11-21-top-run-gas.md.
contract WiringTopForkTest is Test {
    uint256 constant FORK_BLOCK = 76_480_000;
    address constant FACTORY = 0x1f09DAeFA827f02CBb40967cc91b259763760761;
    address constant USDT0 = 0x779Ded0c9e1022225f8E0630b35a9b54bE713736;
    address constant C = 0xB04EB79D1A5EECaabAAfF7B77d7c27578EE693FF; // AND 1, OR 2, NAND 3
    address constant X = 0x839bdD6fa7A66416A609A735e11DE5411B98574e; // XOR 1
    address constant M = 0xCa6Fa40e0b548aBa9132F3f5050eE4C4c5eB7340; // id 3: 3-in 1-out
    uint8 constant TOP = WIRE_TOP;
    uint96 constant AMOUNT = 10_000_000;

    LatheOrders lathe;
    TopEvalMeter meter;
    uint256 refusals;
    address buyer = makeAddr("buyer");
    address bld = makeAddr("bld");

    // minted pieces: proc + id + function code
    struct P {
        address proc;
        uint256 id;
        uint8 nIn;
        uint8 nOut;
        uint8 fn;
    }

    P andnot; // fn 1: a & ~b
    P notand; // fn 2: (~a, a&b)
    P bax; // fn 3: (b, a, a^b)
    P mux; // fn 4: whatever M id 3 does (read by eval), wrapped
    P sub; // fn 5: 3 in, 2 out: (a&~b) , (c ^ a)

    function setUp() public {
        vm.createSelectFork("xlayer", FORK_BLOCK);
        lathe = new LatheOrders(FACTORY, USDT0, makeAddr("feeTo"), 100);
        meter = new TopEvalMeter();
        deal(USDT0, buyer, 1000 * uint256(AMOUNT));
        vm.prank(buyer);
        IERC20W(USDT0).approve(address(lathe), type(uint256).max);
        vm.deal(bld, 100 ether);
        assertTrue(IFactoryW(FACTORY).isCPU(X));
        assertTrue(IFactoryW(FACTORY).isCPU(M));
        // a & ~b on X: REF(C,NAND,[b,b]) -> w4 ; REF(C,AND,[a,w4]) -> w5
        andnot = P(X, mint(X, abi.encodePacked(ref(C, 3, 2, 1), w3(3), w3(3), ref(C, 1, 2, 1), w3(2), w3(4)), 2, 1), 2, 1, 1);
        // (~a, a&b) on C
        notand = P(C, mint(C, abi.encodePacked(ref(C, 3, 2, 1), w3(2), w3(2), ref(C, 1, 2, 1), w3(2), w3(3)), 2, 2), 2, 2, 2);
        // (b, a, a^b) on M
        bax = P(M, mint(M, abi.encodePacked(ref(C, 1, 2, 1), w3(3), w3(3), ref(C, 1, 2, 1), w3(2), w3(2), ref(X, 1, 2, 1), w3(2), w3(3)), 2, 3), 2, 3, 3);
        // wrap M id 3 on X
        mux = P(X, mint(X, abi.encodePacked(ref(M, 3, 3, 1), w3(2), w3(3), w3(4)), 3, 1), 3, 1, 4);
        // sub on C: REF andnot(a,b)->w5 ; REF XOR(c,a) -> w6 (outputs last 2)
        sub = P(C, mint(C, abi.encodePacked(ref(X, andnot.id, 2, 1), w3(2), w3(3), ref(X, 1, 2, 1), w3(4), w3(2)), 3, 2), 3, 2, 5);
    }

    function ref(address p, uint256 id, uint8 ni, uint8 no) internal pure returns (bytes memory) {
        return abi.encodePacked(uint8(2), p, uint64(id), ni, no);
    }

    function w3(uint24 v) internal pure returns (bytes3) {
        return bytes3(v);
    }

    function mint(address proc, bytes memory nl, uint32 ni, uint32 no) internal returns (uint256 id) {
        uint256 fee = IMintW(proc).TAPEOUT_FEE();
        vm.prank(bld);
        id = IMintW(proc).tapeout{value: fee}(nl, ni, no);
    }

    // independent model of every piece
    function model(P memory p, uint256 x) internal pure returns (uint256) {
        uint256 a = x & 1;
        uint256 b = (x >> 1) & 1;
        uint256 c = (x >> 2) & 1;
        if (p.fn == 1) return a & (1 - b);
        if (p.fn == 2) return (1 - a) | ((a & b) << 1);
        if (p.fn == 3) return b | (a << 1) | ((a ^ b) << 2);
        if (p.fn == 4) {
            // M id 3 from its decoded netlist: w5=NAND(c,c) w6=NAND(a,w5) w7=NAND(b,c) w8=NAND(w6,w7)
            uint256 w5 = 1 - c;
            uint256 w6 = 1 - (a & w5);
            uint256 w7 = 1 - (b & c);
            return 1 - (w6 & w7);
        }
        if (p.fn == 6) return a & b;
        if (p.fn == 7) return a | b;
        if (p.fn == 8) return 1 - (a & b);
        if (p.fn == 9) return a ^ b;
        if (p.fn == 5) return (a & (1 - b)) | ((c ^ a) << 1);
        revert("fn");
    }

    function table(P memory p) internal view returns (bytes memory t) {
        uint256 cases = uint256(1) << p.nIn;
        t = new bytes((cases * p.nOut + 7) / 8);
        for (uint256 cc = 0; cc < cases; ++cc) {
            uint256 v = model(p, cc);
            for (uint256 j = 0; j < p.nOut; ++j) {
                uint256 bit = cc * p.nOut + j;
                if ((v >> j) & 1 == 1) t[bit / 8] |= bytes1(uint8(1 << (bit % 8)));
            }
        }
    }

    function w(uint8 fp, uint8 fb, uint8 tp, uint8 tb) internal pure returns (Wire memory) {
        return Wire(fp, fb, tp, tb);
    }

    function mkSpec(P[] memory ps, Wire[] memory ws, bool top) internal view returns (LatheOrders.PiecedSpec memory s) {
        s.pieces = new Piece[](ps.length);
        s.tables = new bytes[](ps.length);
        for (uint256 i = 0; i < ps.length; ++i) {
            s.pieces[i] = Piece(PieceKind.Table, ps[i].nIn, ps[i].nOut, 0, 0);
            s.tables[i] = table(ps[i]);
        }
        s.maxGates = new uint32[](ps.length);
        s.labels = new bytes32[](0);
        s.wires = ws;
        s.needsTop = top;
    }

    // independent chain evaluator (reads wires as given, any order)
    function chain(P[] memory ps, Wire[] memory ws, uint256 x, uint256 nOut) internal pure returns (uint256 y) {
        uint256[] memory outs = new uint256[](ps.length);
        for (uint256 k = 0; k < ps.length; ++k) {
            uint256 xin;
            for (uint256 i = 0; i < ws.length; ++i) {
                if (ws[i].toPiece != k) continue;
                uint256 v = ws[i].fromPiece == TOP ? x : outs[ws[i].fromPiece];
                xin |= ((v >> ws[i].fromBit) & 1) << ws[i].toBit;
            }
            outs[k] = model(ps[k], xin);
        }
        for (uint256 i = 0; i < ws.length; ++i) {
            if (ws[i].toPiece != TOP) continue;
            uint256 v = ws[i].fromPiece == TOP ? x : outs[ws[i].fromPiece];
            y |= ((v >> ws[i].fromBit) & 1) << ws[i].toBit;
        }
        require(nOut > 0);
    }

    function status(uint256 id) internal view returns (LatheOrders.Status s) {
        (,,,,,,,, s) = lathe.orders(id);
    }

    function shape(uint256 id) internal view returns (uint8 nIn, uint8 nOut) {
        (,,,,, nIn, nOut,,) = lathe.orders(id);
    }

    function runCase(P[] memory ps, Wire[] memory ws, address topProc) internal {
        uint64 dl = uint64(block.timestamp + 1 days);
        vm.prank(buyer);
        uint256 t = lathe.createPiecedOrder(mkSpec(ps, ws, true), AMOUNT, dl, bld);
        vm.prank(buyer);
        uint256 j = lathe.createPiecedOrder(mkSpec(ps, ws, false), AMOUNT, dl, bld);
        for (uint256 i = 0; i < ps.length; ++i) {
            vm.prank(bld);
            lathe.deliverPiece(t, i, ps[i].proc, ps[i].id);
            vm.prank(bld);
            lathe.deliverPiece(j, i, ps[i].proc, ps[i].id);
        }
        assertEq(uint8(status(j)), uint8(LatheOrders.Status.Paid), "join paid");
        assertEq(uint8(status(t)), uint8(LatheOrders.Status.Open), "top waits");
        (uint8 nIn, uint8 nOut) = shape(t);
        bytes memory nl = lathe.expectedTopNetlist(t);
        uint256 topId = mint(topProc, nl, nIn, nOut);
        vm.prank(bld);
        lathe.deliverTop(t, topProc, topId);
        assertEq(uint8(status(t)), uint8(LatheOrders.Status.Paid), "top paid");
        _cmp(ps, ws, topProc, topId, t, j);
    }

    struct Ctx {
        P[] ps;
        Wire[] ws;
        address topProc;
        uint256 topId;
        uint256 t;
        uint256 j;
        uint8 nIn;
        uint8 nOut;
    }

    function _cmp(P[] memory ps, Wire[] memory ws, address topProc, uint256 topId, uint256 t, uint256 j) internal {
        Ctx memory c;
        c.ps = ps;
        c.ws = ws;
        c.topProc = topProc;
        c.topId = topId;
        c.t = t;
        c.j = j;
        (c.nIn, c.nOut) = shape(t);
        uint256 maxUsed;
        refusals = 0;
        for (uint256 x = 0; x < (uint256(1) << c.nIn); ++x) {
            uint256 used = _one(c, x);
            if (used > maxUsed) maxUsed = used;
        }
        (,,, uint32 gates) = IProcessor(topProc).circuitInfo(topId);
        uint256 newBudget = lathe.evalBudget(gates) + lathe.EVAL_GAS_PER_REF() * ps.length;
        console.log("pieces", ps.length, "nIn", c.nIn);
        console.log("top gates", gates, "old budget (evalBudget)", lathe.evalBudget(gates));
        console.log("new budget (+ EVAL_GAS_PER_REF x pieces)", newBudget);
        console.log("max eval gas of the top (meter)", maxUsed);
        console.log("run(topped order) refusals", refusals, "of", uint256(1) << c.nIn);
        assertEq(refusals, 0, "run refused on the topped order");
        assertLe(maxUsed, newBudget, "the top's eval costs more than its run budget");
    }

    function _one(Ctx memory c, uint256 x) internal returns (uint256 used) {
        bytes memory inp = pack(x, c.nIn);
        bytes memory e;
        (used, e) = meter.once(c.topProc, c.topId, inp);
        bytes memory want = pack(chain(c.ps, c.ws, x, c.nOut), c.nOut);
        assertEq(e, want, "eval(top) vs model");
        try lathe.run(c.t, inp) returns (bytes memory r) {
            assertEq(r, want, "run top order");
        } catch {
            refusals++;
        }
        assertEq(lathe.run(c.j, inp), want, "run join order");
    }

    function pack(uint256 v, uint256 n) internal pure returns (bytes memory out) {
        out = new bytes((n + 7) / 8);
        for (uint256 i = 0; i < out.length; ++i) {
            out[i] = bytes1(uint8(v >> (8 * i)));
        }
    }

    /// 3 pieces on 3 processors, asymmetric pins, outputs spanning two pieces, top on a 4th location (M).
    function test_W1() public {
        P[] memory ps = new P[](3);
        ps[0] = andnot;
        ps[1] = bax;
        ps[2] = mux;
        Wire[] memory ws = new Wire[](9);
        ws[0] = w(TOP, 2, 0, 0);
        ws[1] = w(TOP, 0, 0, 1);
        ws[2] = w(0, 0, 1, 0);
        ws[3] = w(TOP, 1, 1, 1);
        ws[4] = w(1, 2, 2, 0);
        ws[5] = w(TOP, 3, 2, 1);
        ws[6] = w(1, 0, 2, 2);
        ws[7] = w(2, 0, TOP, 1); // listed out of order on purpose
        ws[8] = w(1, 2, TOP, 0);
        runCase(ps, ws, M);
    }

    /// 4 pieces; piece 0 feeds two later pieces; input x2 feeds two pieces; outputs = last 3 wires over 2 pieces.
    function test_W2() public {
        P[] memory ps = new P[](4);
        ps[0] = notand;
        ps[1] = andnot;
        ps[2] = bax;
        ps[3] = andnot;
        Wire[] memory ws = new Wire[](11);
        ws[0] = w(TOP, 1, 0, 0);
        ws[1] = w(TOP, 0, 0, 1);
        ws[2] = w(0, 1, 1, 0);
        ws[3] = w(TOP, 2, 1, 1);
        ws[4] = w(TOP, 2, 2, 0);
        ws[5] = w(0, 0, 2, 1);
        ws[6] = w(1, 0, 3, 0);
        ws[7] = w(2, 0, 3, 1);
        ws[8] = w(2, 1, TOP, 0);
        ws[9] = w(2, 2, TOP, 1);
        ws[10] = w(3, 0, TOP, 2);
        runCase(ps, ws, C);
    }

    /// one piece, outputs = its last two bits only (bit 0 unused).
    function test_W3() public {
        P[] memory ps = new P[](1);
        ps[0] = bax;
        Wire[] memory ws = new Wire[](4);
        ws[0] = w(TOP, 1, 0, 0);
        ws[1] = w(TOP, 0, 0, 1);
        ws[2] = w(0, 1, TOP, 0);
        ws[3] = w(0, 2, TOP, 1);
        runCase(ps, ws, X);
    }

    /// 6 pieces incl. a nested-REF piece (sub refs andnot), 5 inputs.
    function test_W4() public {
        P[] memory ps = new P[](6);
        ps[0] = sub;
        ps[1] = bax;
        ps[2] = mux;
        ps[3] = notand;
        ps[4] = sub;
        ps[5] = andnot;
        Wire[] memory ws = new Wire[](20);
        uint256 i;
        ws[i++] = w(TOP, 4, 0, 0);
        ws[i++] = w(TOP, 1, 0, 1);
        ws[i++] = w(TOP, 3, 0, 2);
        ws[i++] = w(0, 1, 1, 0);
        ws[i++] = w(TOP, 0, 1, 1);
        ws[i++] = w(1, 2, 2, 0);
        ws[i++] = w(0, 0, 2, 1);
        ws[i++] = w(TOP, 2, 2, 2);
        ws[i++] = w(2, 0, 3, 0);
        ws[i++] = w(1, 1, 3, 1);
        ws[i++] = w(3, 1, 4, 0);
        ws[i++] = w(TOP, 4, 4, 1);
        ws[i++] = w(1, 0, 4, 2);
        ws[i++] = w(4, 1, 5, 0);
        ws[i++] = w(3, 0, 5, 1);
        // outputs: last 3 piece-output bits = piece4 bit0, piece4 bit1, piece5 bit0
        ws[i++] = w(4, 0, TOP, 0);
        ws[i++] = w(4, 1, TOP, 1);
        ws[i++] = w(5, 0, TOP, 2);
        // spare slots -> drop by resizing
        assembly {
            mstore(ws, i)
        }
        runCase(ps, ws, M);
    }

    /// 8 plain NAND-gate pieces (live AND, OR, NAND, XOR; not REF-made): a chain, top on C.
    function test_W5_eightPlainPieces() public {
        bld = 0xc742AdA2872a042dD36D2E706907b4036968960C;
        vm.deal(bld, 1 ether);
        P[] memory ps = new P[](8);
        P memory pand = P(C, 1, 2, 1, 6);
        P memory por = P(C, 2, 2, 1, 7);
        P memory pnand = P(C, 3, 2, 1, 8);
        ps[0] = pand;
        ps[1] = por; ps[2] = pnand; ps[3] = pand; ps[4] = por; ps[5] = pnand; ps[6] = pand; ps[7] = por;
        Wire[] memory ws = new Wire[](17);
        ws[0] = w(TOP, 0, 0, 0);
        ws[1] = w(TOP, 1, 0, 1);
        for (uint8 k = 1; k < 8; ++k) {
            ws[2 * k] = w(k - 1, 0, k, 0);
            ws[2 * k + 1] = w(TOP, k + 1, k, 1);
        }
        ws[16] = w(7, 0, TOP, 0);
        runCase(ps, ws, C);
    }



    /// same bytes minted with a different nIn (one extra unused input) must be refused.
    function test_shapeAndOrder() public {
        P[] memory ps = new P[](2);
        ps[0] = andnot;
        ps[1] = bax;
        Wire[] memory ws = new Wire[](6);
        ws[0] = w(TOP, 0, 0, 0);
        ws[1] = w(TOP, 1, 0, 1);
        ws[2] = w(TOP, 1, 1, 0);
        ws[3] = w(0, 0, 1, 1);
        ws[4] = w(1, 1, TOP, 0);
        ws[5] = w(1, 2, TOP, 1);
        vm.prank(buyer);
        uint256 t = lathe.createPiecedOrder(mkSpec(ps, ws, true), AMOUNT, uint64(block.timestamp + 1 days), bld);
        for (uint256 i = 0; i < 2; ++i) {
            vm.prank(bld);
            lathe.deliverPiece(t, i, ps[i].proc, ps[i].id);
        }
        bytes memory nl = lathe.expectedTopNetlist(t);
        uint256 wrongShape = mint(C, nl, 3, 2);
        vm.prank(bld);
        vm.expectRevert(LatheOrders.ShapeMismatch.selector);
        lathe.deliverTop(t, C, wrongShape);
        uint256 wrongOut = mint(C, nl, 2, 1);
        vm.prank(bld);
        vm.expectRevert(LatheOrders.ShapeMismatch.selector);
        lathe.deliverTop(t, C, wrongOut);
        // a top owned by someone else, same bytes
        uint256 fee = IMintW(C).TAPEOUT_FEE();
        address other = makeAddr("other");
        vm.deal(other, 1 ether);
        vm.prank(other);
        uint256 foreign = IMintW(C).tapeout{value: fee}(nl, 2, 2);
        vm.prank(bld);
        vm.expectRevert(LatheOrders.NotCircuitOwner.selector);
        lathe.deliverTop(t, C, foreign);
        // the piece circuit itself as a "top" (right shape? no: 2in/3out) ; a non-builder
        uint256 good = mint(C, nl, 2, 2);
        vm.prank(other);
        vm.expectRevert(LatheOrders.NotBuilder.selector);
        lathe.deliverTop(t, C, good);
        vm.prank(bld);
        lathe.deliverTop(t, C, good);
        vm.prank(bld);
        vm.expectRevert(LatheOrders.NotOpen.selector);
        lathe.deliverTop(t, C, good);
    }
}

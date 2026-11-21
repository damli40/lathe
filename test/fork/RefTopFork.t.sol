// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {LatheOrders} from "../../src/LatheOrders.sol";
import {IProcessor} from "../../src/ITapeOut.sol";
import {Piece, PieceKind} from "../../src/FormulaLib.sol";
import {NetlistLib, Wire, WIRE_TOP} from "../../src/NetlistLib.sol";

interface IERC20Top {
    function approve(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

/// TapeOut's mint function (evidence/2026-11-21-netlist-ref-format.md, section 5). Called here only on a local fork.
interface ITapeOutMint {
    function tapeout(bytes calldata netlist, uint32 nIn, uint32 nOut) external payable returns (uint256);
    function TAPEOUT_FEE() external view returns (uint256);
}

/// @notice V3b on live TapeOut circuits (X Layer mainnet fork pinned at block 76,480,000; everything runs on the local
/// fork, nothing is sent to X Layer).
/// Processor "Cerebr" 0xb04e...93ff holds three small parts, all owned by 0xc742...960C (read at this block):
/// id 1 = AND, id 2 = OR, id 3 = NAND (2 inputs, 1 output each), and id 5 = a REF-only XOR made of them:
/// REF id 2 (A, B), REF id 3 (A, B), REF id 1 (the two answers). Its 111 netlist bytes are decoded in the spike file.
/// - test_encode_matchesLiveRefCircuit: NetlistLib rebuilds id 5's bytes exactly from (processors, ids, wires).
/// - test_fork_deliverTop_liveTop: a needs-top order for "XOR made of OR, NAND, AND" is paid by delivering the live
///   id 5 as its top; run then evaluates id 5 itself.
/// - test_fork_mintedTop_matchesJoin_everyInput: a new 3-input, 2-output wiring with fan-out; the encoded top is
///   minted on the fork with tapeout (fee paid in fork OKB), delivered, and on all 8 inputs the top's eval equals
///   the joined pieces and plain Solidity.
/// Run: forge test --match-path 'test/fork/RefTopFork.t.sol' -vv  (sequential; the public RPC 403s under load)
contract RefTopForkTest is Test {
    uint256 constant FORK_BLOCK = 76_480_000;
    address constant FACTORY = 0x1f09DAeFA827f02CBb40967cc91b259763760761;
    address constant USDT0 = 0x779Ded0c9e1022225f8E0630b35a9b54bE713736;
    address constant CEREBR = 0xB04EB79D1A5EECaabAAfF7B77d7c27578EE693FF;
    address constant OWNER = 0xc742AdA2872a042dD36D2E706907b4036968960C;
    uint256 constant AND_ID = 1;
    uint256 constant OR_ID = 2;
    uint256 constant NAND_ID = 3;
    uint256 constant XOR_TOP_ID = 5;
    uint96 constant AMOUNT = 10_000_000;
    uint8 constant TOP = WIRE_TOP;

    LatheOrders lathe;
    address buyer = makeAddr("buyer");

    function setUp() public {
        vm.createSelectFork("xlayer", FORK_BLOCK);
        lathe = new LatheOrders(FACTORY, USDT0, makeAddr("feeTo"), 100);
        deal(USDT0, buyer, 100 * uint256(AMOUNT));
        vm.prank(buyer);
        IERC20Top(USDT0).approve(address(lathe), type(uint256).max);
    }

    function w(uint8 fp, uint8 fb, uint8 tp, uint8 tb) internal pure returns (Wire memory) {
        return Wire(fp, fb, tp, tb);
    }

    function t2() internal pure returns (Piece memory) {
        return Piece(PieceKind.Table, 2, 1, 0, 0);
    }

    function spec(bytes[] memory ts, Wire[] memory ws, bool top) internal pure returns (LatheOrders.PiecedSpec memory s) {
        s.pieces = new Piece[](3);
        s.pieces[0] = t2();
        s.pieces[1] = t2();
        s.pieces[2] = t2();
        s.tables = ts;
        s.maxGates = new uint32[](3);
        s.labels = new bytes32[](0);
        s.wires = ws;
        s.needsTop = top;
    }

    /// OR(A, B) -> piece 0, NAND(A, B) -> piece 1, AND(piece 0, piece 1) -> piece 2 -> the output.
    function xorWires() internal pure returns (Wire[] memory ws) {
        ws = new Wire[](7);
        ws[0] = w(TOP, 0, 0, 0);
        ws[1] = w(TOP, 1, 0, 1);
        ws[2] = w(TOP, 0, 1, 0);
        ws[3] = w(TOP, 1, 1, 1);
        ws[4] = w(0, 0, 2, 0);
        ws[5] = w(1, 0, 2, 1);
        ws[6] = w(2, 0, TOP, 0);
    }

    function xorTables() internal pure returns (bytes[] memory ts) {
        ts = new bytes[](3);
        ts[0] = hex"0e"; // OR
        ts[1] = hex"07"; // NAND
        ts[2] = hex"08"; // AND
    }

    function test_encode_matchesLiveRefCircuit() public view {
        address[] memory p = new address[](3);
        p[0] = CEREBR;
        p[1] = CEREBR;
        p[2] = CEREBR;
        uint256[] memory ids = new uint256[](3);
        ids[0] = OR_ID;
        ids[1] = NAND_ID;
        ids[2] = AND_ID;
        Piece[] memory ps = spec(xorTables(), xorWires(), true).pieces;
        bytes memory got = NetlistLib.encodeRefTop(p, ids, ps, xorWires(), 2, 1);
        bytes memory live = IProcessor(CEREBR).netlist(XOR_TOP_ID);
        assertEq(live.length, 111);
        assertEq(got, live);
        (uint32 nIn, uint32 nOut, uint32 nState, uint32 gates) = IProcessor(CEREBR).circuitInfo(XOR_TOP_ID);
        assertEq(nIn, 2);
        assertEq(nOut, 1);
        assertEq(nState, 0);
        assertEq(gates, 6); // 3 (OR) + 1 (NAND) + 2 (AND): the top's count includes the referenced gates
    }

    function deliverPieces(uint256 id, uint256[3] memory cids) internal {
        for (uint256 i = 0; i < 3; ++i) {
            vm.prank(OWNER);
            lathe.deliverPiece(id, i, CEREBR, cids[i]);
        }
    }

    function status(uint256 id) internal view returns (LatheOrders.Status s) {
        (,,,,,,,, s) = lathe.orders(id);
    }

    function test_fork_deliverTop_liveTop() public {
        vm.prank(buyer);
        uint256 id = lathe.createPiecedOrder(spec(xorTables(), xorWires(), true), AMOUNT, uint64(block.timestamp + 1 days), OWNER);
        deliverPieces(id, [OR_ID, NAND_ID, AND_ID]);
        assertEq(uint8(status(id)), uint8(LatheOrders.Status.Open)); // pieces passed; waits for the top
        assertEq(keccak256(lathe.expectedTopNetlist(id)), keccak256(IProcessor(CEREBR).netlist(XOR_TOP_ID)));
        uint256 before = IERC20Top(USDT0).balanceOf(OWNER);
        vm.prank(OWNER);
        lathe.deliverTop(id, CEREBR, XOR_TOP_ID);
        assertEq(uint8(status(id)), uint8(LatheOrders.Status.Paid));
        assertEq(IERC20Top(USDT0).balanceOf(OWNER) - before, AMOUNT - AMOUNT / 100);
        (address rp, uint256 rc) = lathe.ruleOf(id);
        assertEq(rp, CEREBR);
        assertEq(rc, XOR_TOP_ID);
        for (uint8 x = 0; x < 4; ++x) {
            bytes memory inp = abi.encodePacked(x);
            vm.expectCall(CEREBR, abi.encodeCall(IProcessor.eval, (XOR_TOP_ID, inp)), 1);
            bytes memory out = lathe.run(id, inp);
            assertEq(out, abi.encodePacked((x & 1) ^ (x >> 1)));
        }
    }

    /// Inputs a, b, c. Piece 0 = NAND(a, b) (id 3); piece 1 = OR(piece 0, c) (id 2); piece 2 = AND(a, piece 1) (id 1).
    /// Outputs: y0 = piece 1's answer, y1 = piece 2's answer: the last two wires (6 and 7), as a top must have.
    function fanWires() internal pure returns (Wire[] memory ws) {
        ws = new Wire[](8);
        ws[0] = w(TOP, 0, 0, 0);
        ws[1] = w(TOP, 1, 0, 1);
        ws[2] = w(0, 0, 1, 0);
        ws[3] = w(TOP, 2, 1, 1);
        ws[4] = w(TOP, 0, 2, 0); // input a fans out to pieces 0 and 2
        ws[5] = w(1, 0, 2, 1);
        ws[6] = w(1, 0, TOP, 0);
        ws[7] = w(2, 0, TOP, 1);
    }

    function test_fork_mintedTop_matchesJoin_everyInput() public {
        bytes[] memory ts = new bytes[](3);
        ts[0] = hex"07"; // NAND
        ts[1] = hex"0e"; // OR
        ts[2] = hex"08"; // AND
        uint64 dl = uint64(block.timestamp + 1 days);
        vm.prank(buyer);
        uint256 topOrder = lathe.createPiecedOrder(spec(ts, fanWires(), true), AMOUNT, dl, OWNER);
        vm.prank(buyer);
        uint256 joinOrder = lathe.createPiecedOrder(spec(ts, fanWires(), false), AMOUNT, dl, OWNER);
        deliverPieces(topOrder, [NAND_ID, OR_ID, AND_ID]);
        deliverPieces(joinOrder, [NAND_ID, OR_ID, AND_ID]);
        assertEq(uint8(status(joinOrder)), uint8(LatheOrders.Status.Paid));

        // Mint the top on the fork, as the builder, with the bytes the order asks for.
        bytes memory nl = lathe.expectedTopNetlist(topOrder);
        assertEq(nl.length, 3 * 37);
        uint256 fee = ITapeOutMint(CEREBR).TAPEOUT_FEE();
        vm.deal(OWNER, fee);
        vm.prank(OWNER);
        uint256 top = ITapeOutMint(CEREBR).tapeout{value: fee}(nl, 3, 2);
        assertEq(IProcessor(CEREBR).ownerOf(top), OWNER);
        (,,, uint32 gates) = IProcessor(CEREBR).circuitInfo(top);
        assertEq(gates, 1 + 3 + 2);
        vm.prank(OWNER);
        lathe.deliverTop(topOrder, CEREBR, top);
        assertEq(uint8(status(topOrder)), uint8(LatheOrders.Status.Paid));

        _compareAll(top, topOrder, joinOrder);
    }

    function _compareAll(uint256 top, uint256 topOrder, uint256 joinOrder) internal view {
        for (uint8 x = 0; x < 8; ++x) {
            uint8 a = x & 1;
            uint8 y0 = (1 - (a & ((x >> 1) & 1))) | ((x >> 2) & 1);
            bytes memory inp = abi.encodePacked(x);
            bytes memory want = abi.encodePacked(uint8(y0 | ((a & y0) << 1)));
            assertEq(IProcessor(CEREBR).eval(top, inp), want, "eval(top)");
            assertEq(lathe.run(topOrder, inp), want, "run via top");
            assertEq(lathe.run(joinOrder, inp), want, "run joined");
        }
    }
}

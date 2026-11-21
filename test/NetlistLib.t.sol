// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {NetlistLib, Wire, WIRE_TOP} from "../src/NetlistLib.sol";
import {Piece, PieceKind} from "../src/FormulaLib.sol";
import {LatheOrders} from "../src/LatheOrders.sol";

/// @notice NetlistLib.encodeRefTop on its own: the TAP-02 REF layout byte by byte, wire numbering, and every refusal.
/// The live-circuit match (Cerebr id 5, 111 bytes) is test/fork/RefTopFork.t.sol; this file also rebuilds the same
/// bytes offline from the hex recorded in evidence/2026-11-21-netlist-ref-format.md, so it runs without a fork.
contract NetlistLibTest is Test {
    address constant CEREBR = 0xB04EB79D1A5EECaabAAfF7B77d7c27578EE693FF;
    bytes constant ID5 =
        hex"02b04eb79d1a5eecaabaaff7b77d7c27578ee693ff0000000000000002020100000200000302b04eb79d1a5eecaabaaff7b77d7c27578ee693ff0000000000000003020100000200000302b04eb79d1a5eecaabaaff7b77d7c27578ee693ff00000000000000010201000004000005";

    function enc(address[] memory p, uint256[] memory ids, Piece[] memory ps, Wire[] memory ws, uint8 nIn, uint8 nOut)
        external
        pure
        returns (bytes memory)
    {
        return NetlistLib.encodeRefTop(p, ids, ps, ws, nIn, nOut);
    }

    function t(uint8 nIn, uint8 nOut) internal pure returns (Piece memory) {
        return Piece(PieceKind.Table, nIn, nOut, 0, 0);
    }

    function w(uint8 fp, uint8 fb, uint8 tp, uint8 tb) internal pure returns (Wire memory) {
        return Wire(fp, fb, tp, tb);
    }

    /// The id 5 recipe: OR (id 2) and NAND (id 3) on inputs A, B; AND (id 1) of their two answers.
    function xorRecipe()
        internal
        pure
        returns (address[] memory p, uint256[] memory ids, Piece[] memory ps, Wire[] memory ws)
    {
        p = new address[](3);
        p[0] = CEREBR;
        p[1] = CEREBR;
        p[2] = CEREBR;
        ids = new uint256[](3);
        ids[0] = 2;
        ids[1] = 3;
        ids[2] = 1;
        ps = new Piece[](3);
        ps[0] = t(2, 1);
        ps[1] = t(2, 1);
        ps[2] = t(2, 1);
        ws = new Wire[](7);
        ws[0] = w(WIRE_TOP, 0, 0, 0);
        ws[1] = w(WIRE_TOP, 1, 0, 1);
        ws[2] = w(WIRE_TOP, 0, 1, 0);
        ws[3] = w(WIRE_TOP, 1, 1, 1);
        ws[4] = w(0, 0, 2, 0);
        ws[5] = w(1, 0, 2, 1);
        ws[6] = w(2, 0, WIRE_TOP, 0);
    }

    function test_encode_rebuildsRecordedId5() public view {
        (address[] memory p, uint256[] memory ids, Piece[] memory ps, Wire[] memory ws) = xorRecipe();
        bytes memory got = this.enc(p, ids, ps, ws, 2, 1);
        assertEq(got, ID5);
        assertEq(keccak256(got), 0xaf654440443a6fbd0d5d22226905e7468312fe2d7163ecc82edf8501f591dbc3);
    }

    /// One REF with 2 inputs: 02 | processor | id (8 bytes, big-endian) | nIns | nOuts | 000002 | 000003.
    function test_encode_oneRef_layout() public view {
        address[] memory p = new address[](1);
        p[0] = address(uint160(0x1122334455667788990011223344556677889900));
        uint256[] memory ids = new uint256[](1);
        ids[0] = 0x0102030405060708;
        Piece[] memory ps = new Piece[](1);
        ps[0] = t(2, 1);
        Wire[] memory ws = new Wire[](3);
        ws[0] = w(WIRE_TOP, 1, 0, 0); // pins swapped on purpose: pin 0 <- input 1 (wire 3)
        ws[1] = w(WIRE_TOP, 0, 0, 1);
        ws[2] = w(0, 0, WIRE_TOP, 0);
        bytes memory got = this.enc(p, ids, ps, ws, 2, 1);
        assertEq(got, hex"02112233445566778899001122334455667788990001020304050607080201000003000002");
        assertEq(got.length, 37);
    }

    /// Wire numbers: inputs 2..(2+nIn-1), then piece 0's outputs, then piece 1's. A multi-output piece, fan-out of
    /// an input and of a piece output, and order outputs spanning two pieces (the last 2 wires: piece 0's output 2
    /// and piece 1's output 0).
    function test_encode_numbering_fanOut_multiOutput() public view {
        address[] memory p = new address[](2);
        p[0] = address(0xA);
        p[1] = address(0xB);
        uint256[] memory ids = new uint256[](2);
        ids[0] = 7;
        ids[1] = 300;
        Piece[] memory ps = new Piece[](2);
        ps[0] = Piece(PieceKind.Add, 4, 3, 2, 2); // wires 7, 8, 9 (nIn 5: inputs are wires 2..6)
        ps[1] = t(3, 1); // wire 10
        Wire[] memory ws = new Wire[](9);
        ws[0] = w(WIRE_TOP, 0, 0, 0);
        ws[1] = w(WIRE_TOP, 1, 0, 1);
        ws[2] = w(WIRE_TOP, 2, 0, 2);
        ws[3] = w(WIRE_TOP, 3, 0, 3);
        ws[4] = w(0, 2, 1, 0); // wire 9
        ws[5] = w(WIRE_TOP, 4, 1, 1); // wire 6
        ws[6] = w(0, 2, 1, 2); // wire 9 again
        ws[7] = w(0, 2, WIRE_TOP, 0); // second-to-last wire
        ws[8] = w(1, 0, WIRE_TOP, 1); // last wire
        bytes memory got = this.enc(p, ids, ps, ws, 5, 2);
        bytes memory want = abi.encodePacked(
            hex"02", address(0xA), uint64(7), hex"0403", hex"000002000003000004000005",
            hex"02", address(0xB), uint64(300), hex"0301", hex"000009000006000009"
        );
        assertEq(got, want);
    }

    function expectEnc(Piece[] memory ps, Wire[] memory ws, uint8 nIn, uint8 nOut, bytes4 sel) internal {
        address[] memory p = new address[](ps.length);
        uint256[] memory ids = new uint256[](ps.length);
        vm.expectRevert(sel);
        this.enc(p, ids, ps, ws, nIn, nOut);
    }

    function test_encode_refusals() public {
        (,, Piece[] memory ps, Wire[] memory ws) = xorRecipe();
        // Outputs must be the last wires: AND is last, so taking OR's answer as the output cannot be one REF-only top.
        ws[6] = w(0, 0, WIRE_TOP, 0);
        expectEnc(ps, ws, 2, 1, LatheOrders.TopNeedsLastOutputs.selector);
        // An order input straight to the output: never an element's output.
        ws[6] = w(WIRE_TOP, 0, WIRE_TOP, 0);
        expectEnc(ps, ws, 2, 1, LatheOrders.TopNeedsLastOutputs.selector);
        ws[6] = w(2, 0, WIRE_TOP, 0);
        // Not sorted (two pins swapped in the list).
        (ws[0], ws[1]) = (ws[1], ws[0]);
        expectEnc(ps, ws, 2, 1, LatheOrders.BadWire.selector);
        (ws[0], ws[1]) = (ws[1], ws[0]);
        // Backward: piece 1 fed by piece 1 / piece 2.
        ws[2] = w(1, 0, 1, 0);
        expectEnc(ps, ws, 2, 1, LatheOrders.WiringNotForward.selector);
        ws[2] = w(2, 0, 1, 0);
        expectEnc(ps, ws, 2, 1, LatheOrders.WiringNotForward.selector);
        ws[2] = w(WIRE_TOP, 0, 1, 0);
        // Out-of-range bits.
        ws[3] = w(WIRE_TOP, 2, 1, 1); // only 2 inputs
        expectEnc(ps, ws, 2, 1, LatheOrders.BadWire.selector);
        ws[3] = w(0, 1, 1, 1); // piece 0 has 1 output
        expectEnc(ps, ws, 2, 1, LatheOrders.BadWire.selector);
        ws[3] = w(WIRE_TOP, 1, 1, 1);
        // Missing or extra wires.
        Wire[] memory shortWs = new Wire[](6);
        for (uint256 i = 0; i < 6; ++i) {
            shortWs[i] = ws[i];
        }
        expectEnc(ps, shortWs, 2, 1, LatheOrders.BadWire.selector);
        // More outputs than pieces make, or none.
        expectEnc(ps, ws, 2, 4, LatheOrders.TopNeedsLastOutputs.selector);
        expectEnc(ps, ws, 2, 0, LatheOrders.TopNeedsLastOutputs.selector);
        // Sanity: the fixed list still encodes.
        address[] memory p = new address[](3);
        uint256[] memory ids = new uint256[](3);
        assertEq(this.enc(p, ids, ps, ws, 2, 1).length, 111);
        // A circuit id a REF cannot hold.
        ids[1] = uint256(type(uint64).max) + 1;
        vm.expectRevert(LatheOrders.BadPiece.selector);
        this.enc(p, ids, ps, ws, 2, 1);
        // Array lengths.
        vm.expectRevert(LatheOrders.BadPieceCount.selector);
        this.enc(new address[](2), new uint256[](3), ps, ws, 2, 1);
        vm.expectRevert(LatheOrders.BadPieceCount.selector);
        this.enc(new address[](0), new uint256[](0), new Piece[](0), ws, 2, 1);
    }
}

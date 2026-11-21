// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {LatheBase} from "./LatheBase.sol";
import {LatheOrders} from "../src/LatheOrders.sol";
import {Piece, PieceKind} from "../src/FormulaLib.sol";
import {Wire, WIRE_TOP} from "../src/NetlistLib.sol";
import {FormulaProcessor} from "./mocks/FormulaProcessor.sol";
import {RefProcessor} from "./mocks/RefProcessor.sol";

/// @notice Shared setup for orders created with wires (V3b top circuits, V4 chains): the LatheBase mocks plus a
/// FormulaProcessor (a + b, a >= b pieces) and a RefProcessor that really runs REF-only top circuits.
abstract contract WiredBase is LatheBase {
    FormulaProcessor fproc;
    RefProcessor rproc;
    uint64 deadline;
    uint8 constant TOP = WIRE_TOP;
    uint32 constant SMALL = 4; // gates: small pieces are checked inside deliverPiece

    function setUp() public virtual override {
        super.setUp();
        fproc = new FormulaProcessor();
        rproc = new RefProcessor();
        factory.setCPU(address(fproc), true);
        factory.setCPU(address(rproc), true);
        deadline = uint64(block.timestamp + 1 days);
    }

    function w(uint8 fp, uint8 fb, uint8 tp, uint8 tb) internal pure returns (Wire memory) {
        return Wire(fp, fb, tp, tb);
    }

    function tablePiece(uint8 nIn, uint8 nOut) internal pure returns (Piece memory) {
        return Piece(PieceKind.Table, nIn, nOut, 0, 0);
    }

    function ge(uint8 wa, uint8 wb) internal pure returns (Piece memory) {
        return Piece(PieceKind.GreaterOrEqual, wa + wb, 1, wa, wb);
    }

    function add(uint8 wa, uint8 wb) internal pure returns (Piece memory) {
        return Piece(PieceKind.Add, wa + wb, wa + 1, wa, wb);
    }

    function spec(Piece[] memory ps, bytes[] memory ts, Wire[] memory ws, bool top)
        internal
        pure
        returns (LatheOrders.PiecedSpec memory s)
    {
        s.pieces = ps;
        s.tables = ts;
        s.maxGates = new uint32[](ps.length);
        s.labels = new bytes32[](0);
        s.wires = ws;
        s.needsTop = top;
    }

    function createWired(Piece[] memory ps, bytes[] memory ts, Wire[] memory ws, bool top) internal returns (uint256) {
        vm.prank(buyer);
        return lathe.createPiecedOrder(spec(ps, ts, ws, top), AMOUNT, deadline, builder);
    }

    function expectCreateRevert(LatheOrders.PiecedSpec memory s, bytes4 sel) internal {
        vm.prank(buyer);
        vm.expectRevert(sel);
        lathe.createPiecedOrder(s, AMOUNT, deadline, builder);
    }

    function deliverP(uint256 id, uint256 i, address p, uint256 cid) internal {
        vm.prank(builder);
        lathe.deliverPiece(id, i, p, cid);
    }

    function status(uint256 id) internal view returns (LatheOrders.Status s) {
        (,,,,,,,, s) = lathe.orders(id);
    }

    function shape(uint256 id) internal view returns (uint8 nIn, uint8 nOut) {
        (,,,,, nIn, nOut,,) = lathe.orders(id);
    }

    /// Mint the order's expected top on the RefProcessor, owned by `who`, with the order's shape.
    function mintTop(uint256 id, address who) internal returns (uint256) {
        (uint8 nIn, uint8 nOut) = shape(id);
        return rproc.mint(lathe.expectedTopNetlist(id), nIn, nOut, who);
    }
}

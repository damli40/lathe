// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {TableLib} from "./TableLib.sol";
import {Piece, PieceKind} from "./FormulaLib.sol";
import {LatheOrders} from "./LatheOrders.sol";
import {NetlistLib, Wire, WIRE_TOP} from "./NetlistLib.sol";
import "./LatheConstants.sol";

/// @notice The create-time checks of LatheOrders: pure rules on the arguments, nothing stored, no money.
/// A separate (linked) library only to keep LatheOrders under the 24,576-byte contract size limit. Every revert
/// uses the error LatheOrders declares, so callers see exactly the same errors as before the split.
library LatheChecks {
    /// @notice The V0 table rules, shared by Table pieces (with nState 0).
    function checkTable(uint8 nIn, uint8 nOut, uint8 nState, bytes calldata table) external pure {
        _checkTable(nIn, nOut, nState, table);
    }

    /// @notice createPiecedOrder's argument rules. Returns the order's top-level shape.
    function checkPieces(Piece[] calldata pieces, bytes[] calldata tables, uint32[] calldata maxGates)
        external
        pure
        returns (uint8 nIn, uint8 nOut)
    {
        uint256 n = pieces.length;
        if (n == 0 || n > LATHE_MAX_JOIN_PIECES || tables.length != n || maxGates.length != n) {
            revert LatheOrders.BadPieceCount();
        }
        for (uint256 i = 0; i < n; ++i) {
            _checkPiece(pieces[i], tables[i]);
        }
        nIn = pieces[0].nIn;
        nOut = pieces[n - 1].nOut;
        if (n == 2) {
            if (pieces[1].nIn < pieces[0].nOut) revert LatheOrders.BadPiece();
            nIn = pieces[0].nIn + pieces[1].nIn - pieces[0].nOut;
        }
    }

    /// @notice Store a new pieced order's pieces, tables and gate caps (createPiecedOrder, after checkPieces).
    /// Reached by DELEGATECALL, so it writes LatheOrders' storage; it moves no money.
    function writePieces(
        Piece[] calldata pieces,
        bytes[] calldata tables,
        uint32[] calldata maxGates,
        Piece[] storage ps,
        mapping(uint256 => bytes) storage tableOf,
        mapping(uint256 => uint32) storage maxGatesOf
    ) external {
        _write(pieces, tables, maxGates, ps, tableOf, maxGatesOf);
    }

    /// @notice createPiecedOrder with wires: check the pieces and the wiring, then store the pieces and the wires in
    /// their sorted form (see _sortWires). Returns the order's top-level shape, which the wires decide.
    /// When `spec.needsTop` is true (the order needs one top circuit), the wiring must also be one that a REF-only top circuit
    /// can have; NetlistLib.encodeRefTop is the single judge of that (TopNeedsLastOutputs otherwise).
    /// Reached by DELEGATECALL, so it writes LatheOrders' storage; it moves no money.
    function storeWiredPieces(
        LatheOrders.PiecedSpec calldata spec,
        Piece[] storage ps,
        mapping(uint256 => bytes) storage tableOf,
        mapping(uint256 => uint32) storage maxGatesOf,
        Wire[] storage ws
    ) external returns (uint8 nIn, uint8 nOut) {
        uint256 n = spec.pieces.length;
        if (n == 0 || n > LATHE_MAX_PIECES || spec.tables.length != n || spec.maxGates.length != n) {
            revert LatheOrders.BadPieceCount();
        }
        for (uint256 i = 0; i < n; ++i) {
            _checkPiece(spec.pieces[i], spec.tables[i]);
        }
        Wire[] memory sorted;
        (nIn, nOut, sorted) = _sortWires(spec.pieces, spec.wires);
        if (spec.needsTop) NetlistLib.encodeRefTop(new address[](n), new uint256[](n), spec.pieces, sorted, nIn, nOut);
        _write(spec.pieces, spec.tables, spec.maxGates, ps, tableOf, maxGatesOf);
        for (uint256 i = 0; i < sorted.length; ++i) {
            ws.push(sorted[i]);
        }
    }

    function _write(
        Piece[] calldata pieces,
        bytes[] calldata tables,
        uint32[] calldata maxGates,
        Piece[] storage ps,
        mapping(uint256 => bytes) storage tableOf,
        mapping(uint256 => uint32) storage maxGatesOf
    ) private {
        for (uint256 i = 0; i < pieces.length; ++i) {
            ps.push(pieces[i]);
            tableOf[i] = tables[i];
            maxGatesOf[i] = maxGates[i];
        }
    }

    /// @dev The wiring rules, and the wires sorted by where they go: piece 0's input bits 0, 1, .., then piece 1's,
    /// .., then the order's output bits 0, 1, ... The buyer may list wires in any order; the sorted form is what is
    /// stored, so one wiring always has one stored form (and one fingerprint).
    /// Rules, each with its own error:
    /// - every bit index is in range (a piece's input or output, at most 64 order inputs and outputs): BadWire,
    ///   TooManyCases (more than 64 order inputs), TooManyOutputs (more than 64 order outputs);
    /// - a wire from the order's input straight to the order's output is refused (BadWire): a circuit's outputs are
    ///   always made by its parts, never copied inputs;
    /// - wires only go forward, from a lower to a higher piece index: WiringNotForward;
    /// - every piece input bit and every order output bit is fed exactly once: FedTwice, InputUnconnected,
    ///   OutputUnconnected; there is at least one order output;
    /// - the order has inputs 0 .. nIn-1 with nIn = the highest input bit used + 1, and every one of them feeds at
    ///   least one piece (TopInputUnused). One order input may feed many pieces, and a piece output may feed many
    ///   later pieces or none.
    function _sortWires(Piece[] calldata pieces, Wire[] calldata wires)
        private
        pure
        returns (uint8 nIn, uint8 nOut, Wire[] memory sorted)
    {
        uint256 n = pieces.length;
        // off[k] = where piece k's input bits start in the sorted list; off[n] = where the order's outputs start.
        uint256[] memory off = new uint256[](n + 1);
        for (uint256 k = 0; k < n; ++k) {
            off[k + 1] = off[k] + pieces[k].nIn;
        }
        uint256 ins;
        uint256 outs;
        for (uint256 i = 0; i < wires.length; ++i) {
            Wire calldata e = wires[i];
            if (e.toPiece == WIRE_TOP) {
                if (e.fromPiece == WIRE_TOP) revert LatheOrders.BadWire();
                if (e.toBit >= outs) outs = uint256(e.toBit) + 1;
            } else if (e.toPiece >= n || e.toBit >= pieces[e.toPiece].nIn) {
                revert LatheOrders.BadWire();
            }
            if (e.fromPiece == WIRE_TOP) {
                if (e.fromBit >= ins) ins = uint256(e.fromBit) + 1;
            } else {
                if (e.fromPiece >= n || e.fromBit >= pieces[e.fromPiece].nOut) revert LatheOrders.BadWire();
                if (e.toPiece != WIRE_TOP && e.fromPiece >= e.toPiece) revert LatheOrders.WiringNotForward();
            }
        }
        if (ins > LATHE_MAX_ORDER_BITS) revert LatheOrders.TooManyCases();
        if (outs > LATHE_MAX_ORDER_BITS) revert LatheOrders.TooManyOutputs();
        if (outs == 0) revert LatheOrders.OutputUnconnected();
        sorted = new Wire[](off[n] + outs);
        bool[] memory fed = new bool[](sorted.length);
        uint256 used; // bit i set when order input i feeds something
        for (uint256 i = 0; i < wires.length; ++i) {
            Wire calldata e = wires[i];
            uint256 slot = e.toPiece == WIRE_TOP ? off[n] + e.toBit : off[e.toPiece] + e.toBit;
            if (fed[slot]) revert LatheOrders.FedTwice();
            fed[slot] = true;
            sorted[slot] = e;
            if (e.fromPiece == WIRE_TOP) used |= uint256(1) << e.fromBit;
        }
        for (uint256 s = 0; s < sorted.length; ++s) {
            if (!fed[s]) {
                if (s < off[n]) revert LatheOrders.InputUnconnected();
                revert LatheOrders.OutputUnconnected();
            }
        }
        if (used != (uint256(1) << ins) - 1) revert LatheOrders.TopInputUnused();
        nIn = uint8(ins);
        nOut = uint8(outs);
    }

    function _checkTable(uint8 nIn, uint8 nOut, uint8 nState, bytes calldata table) private pure {
        if (uint256(nIn) + nState > LATHE_MAX_CASE_BITS) revert LatheOrders.TooManyCases();
        if (nOut == 0 || uint256(nOut) + nState > LATHE_MAX_ANSWER_BITS) revert LatheOrders.TooManyOutputs();
        uint256 cases = uint256(1) << (uint256(nIn) + nState);
        uint256 tableBits = cases * (uint256(nOut) + nState);
        if (table.length != TableLib.byteLength(cases, uint256(nOut) + nState)) revert LatheOrders.WrongTableLength();
        // Unused high bits of the last byte must be zero, so each rule has exactly one valid table.
        if (tableBits % 8 != 0 && uint8(table[table.length - 1]) >> (tableBits % 8) != 0) {
            revert LatheOrders.TablePaddingNotZero();
        }
    }

    function _checkPiece(Piece calldata p, bytes calldata table) private pure {
        if (p.kind == PieceKind.Table) {
            if (p.widthA != 0 || p.widthB != 0) revert LatheOrders.BadPiece();
            _checkTable(p.nIn, p.nOut, 0, table);
            return;
        }
        if (table.length != 0) revert LatheOrders.WrongTableLength();
        uint256 w = uint256(p.widthA) + p.widthB;
        if (w > LATHE_MAX_FORMULA_BITS) revert LatheOrders.TooManyCases();
        uint256 out = p.kind == PieceKind.Add ? uint256(p.widthA) + 1 : 1;
        if (p.widthA == 0 || p.widthB == 0 || p.nIn != w || p.nOut != out) revert LatheOrders.BadPiece();
        if (p.kind == PieceKind.Add && p.widthA < p.widthB) revert LatheOrders.BadPiece();
    }
}

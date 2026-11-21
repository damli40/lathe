// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {TableLib} from "./TableLib.sol";
import {Piece, PieceKind} from "./FormulaLib.sol";
import {LatheOrders} from "./LatheOrders.sol";
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
        if (n == 0 || n > LATHE_MAX_PIECES || tables.length != n || maxGates.length != n) {
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
        for (uint256 i = 0; i < pieces.length; ++i) {
            ps.push(pieces[i]);
            tableOf[i] = tables[i];
            maxGatesOf[i] = maxGates[i];
        }
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

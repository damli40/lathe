// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Piece} from "./FormulaLib.sol";
import {LatheOrders} from "./LatheOrders.sol";

/// @notice One wire of a pieced order: bit `fromBit` of piece `fromPiece`'s outputs feeds bit `toBit` of piece
/// `toPiece`'s inputs. `fromPiece == 255` means the order's own input bit `fromBit`; `toPiece == 255` means the
/// order's own output bit `toBit`. Bits are numbered from 0, least significant first, like everything else.
struct Wire {
    uint8 fromPiece;
    uint8 fromBit;
    uint8 toPiece;
    uint8 toBit;
}

/// @dev The piece index that stands for "the order itself" in a Wire.
uint8 constant WIRE_TOP = 255;

/// @notice Builds the exact TapeOut netlist bytes of a "top" circuit made only of references (REF records) to
/// already tested piece circuits, wired the way an order says. LatheOrders compares keccak256 of these bytes with
/// keccak256(netlist(topId)), so no netlist parser is needed on chain.
///
/// Byte layout (TAP-02, checked against live X Layer circuits in evidence/2026-11-21-netlist-ref-format.md): no
/// header, big-endian. A REF record is
///   0x02 | processor (20 bytes) | circuit id (8 bytes) | nIns (1 byte) | nOuts (1 byte) | nIns x wire (3 bytes each)
/// Wire numbers: 0 and 1 are the constants, the top's input i is wire 2 + i, then every record's outputs get the
/// next numbers in record order. The top's outputs are always its LAST nOut wires; they cannot be chosen.
///
/// The one fixed recipe (so equal wiring always gives equal bytes):
/// - one REF record per piece, in piece-index order, and nothing else (no NAND, no LATCH);
/// - piece k's input pin j is fed by the wire the order names for (k, j);
/// - piece k's output j is wire 2 + nIn + (outputs of pieces 0 .. k-1) + j;
/// - order output j must be piece-output bit number T - nOut + j, counting every piece's output bits in piece order
///   (T = all of them). In plain words: the order's outputs are the last output bits of the last piece(s), in the
///   same order. Any other wiring cannot be one REF-only circuit, and is refused (TopNeedsLastOutputs).
///
/// `wires` must be in the order LatheChecks stores them (sorted by where they go): piece 0's input bits 0, 1, ..,
/// then piece 1's, .., then the order's outputs 0, 1, ... Anything else reverts BadWire.
/// A separate (linked) library from the start, to keep LatheOrders under the 24,576-byte size limit.
library NetlistLib {
    /// @notice The netlist bytes of the REF-only top for pieces `pieces` delivered as (processors[k],
    /// circuitIds[k]), wired by `wires` (sorted, see above), with `nIn` top-level inputs and `nOut` outputs.
    /// Reverts BadPieceCount (array lengths), BadPiece (a circuit id above 2^64 - 1, which a REF cannot hold),
    /// BadWire (not the sorted form, or a bit out of range), WiringNotForward (a piece fed by itself or a later
    /// piece), TopNeedsLastOutputs (outputs that are not the last wires).
    function encodeRefTop(
        address[] memory processors,
        uint256[] memory circuitIds,
        Piece[] memory pieces,
        Wire[] memory wires,
        uint8 nIn,
        uint8 nOut
    ) external pure returns (bytes memory) {
        uint256 n = pieces.length;
        if (n == 0 || n >= WIRE_TOP || processors.length != n || circuitIds.length != n) {
            revert LatheOrders.BadPieceCount();
        }
        Enc memory c;
        c.pieces = pieces;
        c.wires = wires;
        c.nIn = nIn;
        // first[k] = the wire number of piece k's output 0; first[n] = one past the last wire.
        c.first = new uint256[](n + 1);
        c.first[0] = 2 + uint256(nIn);
        uint256 len;
        for (uint256 k = 0; k < n; ++k) {
            c.first[k + 1] = c.first[k] + pieces[k].nOut;
            len += 31 + 3 * uint256(pieces[k].nIn);
        }
        c.out = new bytes(len);
        for (uint256 k = 0; k < n; ++k) {
            if (circuitIds[k] > type(uint64).max) revert LatheOrders.BadPiece();
            _head(c, processors[k], circuitIds[k], pieces[k]);
            for (uint256 j = 0; j < pieces[k].nIn; ++j) {
                if (c.w >= wires.length) revert LatheOrders.BadWire();
                Wire memory e = wires[c.w++];
                if (e.toPiece != k || e.toBit != j) revert LatheOrders.BadWire();
                _put(c, _source(e, c.first, pieces, nIn, k), 3);
            }
        }
        _checkOutputs(c, nOut);
        return c.out;
    }

    /// @dev Encoder state, in memory to keep the stack small.
    struct Enc {
        bytes out;
        uint256 at; // write position in out
        uint256 w; // next wire to read
        uint256[] first;
        Piece[] pieces;
        Wire[] wires;
        uint8 nIn;
    }

    /// @dev 0x02 | processor | id (u64) | nIns | nOuts.
    function _head(Enc memory c, address proc, uint256 id, Piece memory p) private pure {
        _put(c, 0x02, 1);
        _put(c, uint160(proc), 20);
        _put(c, id, 8);
        _put(c, p.nIn, 1);
        _put(c, p.nOut, 1);
    }

    /// @dev The order's outputs must be exactly the last nOut wires, in order, and the last wires listed.
    function _checkOutputs(Enc memory c, uint8 nOut) private pure {
        uint256 n = c.pieces.length;
        uint256 end = c.first[n]; // one past the last wire
        if (nOut == 0 || nOut > end - c.first[0]) revert LatheOrders.TopNeedsLastOutputs();
        if (c.wires.length != c.w + nOut) revert LatheOrders.BadWire();
        for (uint256 j = 0; j < nOut; ++j) {
            Wire memory e = c.wires[c.w + j];
            if (e.toPiece != WIRE_TOP || e.toBit != j) revert LatheOrders.BadWire();
            if (e.fromPiece == WIRE_TOP) revert LatheOrders.TopNeedsLastOutputs();
            if (_source(e, c.first, c.pieces, c.nIn, n) != end - nOut + j) revert LatheOrders.TopNeedsLastOutputs();
        }
    }

    /// @dev The wire number feeding a sink of piece `k` (k == pieces.length for the order's outputs).
    function _source(Wire memory e, uint256[] memory first, Piece[] memory pieces, uint8 nIn, uint256 k)
        private
        pure
        returns (uint256)
    {
        if (e.fromPiece == WIRE_TOP) {
            if (e.fromBit >= nIn) revert LatheOrders.BadWire();
            return 2 + uint256(e.fromBit);
        }
        if (e.fromPiece >= k) revert LatheOrders.WiringNotForward();
        if (e.fromBit >= pieces[e.fromPiece].nOut) revert LatheOrders.BadWire();
        return first[e.fromPiece] + e.fromBit;
    }

    /// @dev Write the low `size` bytes of `v` big-endian at the write position and move it on.
    function _put(Enc memory c, uint256 v, uint256 size) private pure {
        for (uint256 i = 0; i < size; ++i) {
            c.out[c.at + i] = bytes1(uint8(v >> (8 * (size - 1 - i))));
        }
        c.at += size;
    }
}

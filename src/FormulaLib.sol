// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @notice What a piece of a pieced order must compute.
/// Table: answers come from a stored truth table (like a V0 order, no memory, at most 6 inputs).
/// GreaterOrEqual and Add: the contract computes the expected answer itself, so no 65,536-row table is stored.
enum PieceKind {
    Table,
    GreaterOrEqual,
    Add
}

/// @notice One piece of a pieced order: a circuit with `nIn` inputs and `nOut` outputs and no memory.
/// For Table pieces widthA and widthB are 0. For formula pieces nIn == widthA + widthB, and:
/// - GreaterOrEqual: nOut == 1.
/// - Add: widthA >= widthB and nOut == widthA + 1.
struct Piece {
    PieceKind kind;
    uint8 nIn;
    uint8 nOut;
    uint8 widthA;
    uint8 widthB;
}

/// @notice Expected answers for formula pieces.
///
/// Bit layout, least significant bit first everywhere (TAP-02 section 5), the same as table orders:
/// case c (0 .. 2^nIn - 1) is the circuit input whose bit k is bit k of c, so input byte j is (c >> 8j) & 0xff.
/// - a = the low widthA bits of c: input bits 0 .. widthA-1, a's least significant bit is input bit 0.
/// - b = the next widthB bits: input bits widthA .. widthA+widthB-1, b's least significant bit is input bit widthA.
/// - GreaterOrEqual: output bit 0 is 1 when a >= b (both unsigned), else 0.
/// - Add: outputs are a + b (unsigned, widthA + 1 bits, never overflows); output bit j is bit j of the sum,
///   so output bit widthA is the carry.
/// Example, GreaterOrEqual(8, 8): a = 5, b = 4 is case 5 + (4 << 8) = 0x0405, input bytes 0x05, 0x04; answer 1.
library FormulaLib {
    /// @notice The expected answer for case `c` of formula piece `p`. Pure and constant cost.
    /// Reverts for Table pieces, which read their stored table instead.
    function expected(Piece memory p, uint256 c) internal pure returns (uint256) {
        uint256 a = c & ((uint256(1) << p.widthA) - 1);
        uint256 b = (c >> p.widthA) & ((uint256(1) << p.widthB) - 1);
        if (p.kind == PieceKind.GreaterOrEqual) return a >= b ? 1 : 0;
        if (p.kind == PieceKind.Add) return a + b;
        revert("FormulaLib: table piece");
    }
}

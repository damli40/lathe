// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {FormulaLib, Piece, PieceKind} from "../src/FormulaLib.sol";

contract FormulaLibHarness {
    function expected(Piece calldata p, uint256 c) external pure returns (uint256) {
        return FormulaLib.expected(p, c);
    }
}

/// @notice FormulaLib against plain Solidity arithmetic.
/// Bit layout under test (LSB first): case c's input bit k is bit k of c. a = input bits 0 .. widthA-1 (a's LSB is
/// input bit 0), b = input bits widthA .. widthA+widthB-1 (b's LSB is input bit widthA). GreaterOrEqual answers
/// 1 bit (a >= b); Add answers widthA + 1 bits (a + b, output bit j = bit j of the sum).
contract FormulaLibTest is Test {
    FormulaLibHarness h;

    function setUp() public {
        h = new FormulaLibHarness();
    }

    function ge(uint8 wa, uint8 wb) internal pure returns (Piece memory) {
        return Piece(PieceKind.GreaterOrEqual, wa + wb, 1, wa, wb);
    }

    function add(uint8 wa, uint8 wb) internal pure returns (Piece memory) {
        return Piece(PieceKind.Add, wa + wb, wa + 1, wa, wb);
    }

    function cs(uint256 a, uint256 b, uint8 wa) internal pure returns (uint256) {
        return a | (b << wa);
    }

    function test_formula_ge_8bit() public view {
        assertEq(h.expected(ge(8, 8), cs(5, 5, 8)), 1);
        assertEq(h.expected(ge(8, 8), cs(4, 5, 8)), 0);
        assertEq(h.expected(ge(8, 8), cs(255, 0, 8)), 1);
        // Bit order: a = 5, b = 4 is input bytes 0x05, 0x04 (case 0x0405) and answers 1; swapped it would be 0.
        assertEq(h.expected(ge(8, 8), 0x0405), 1);
        assertEq(h.expected(ge(8, 8), 0x0504), 0);
    }

    function test_formula_add_8bit() public view {
        assertEq(h.expected(add(8, 8), cs(255, 255, 8)), 510);
        assertEq(h.expected(add(8, 8), cs(0, 0, 8)), 0);
        assertEq(h.expected(add(8, 8), cs(200, 100, 8)), 300); // carry into output bit 8
    }

    function test_formula_unequalWidths() public view {
        // GreaterOrEqual(8, 9), the daily-cap shape: a = cap (8 bits), b = sum (9 bits).
        assertEq(h.expected(ge(8, 9), cs(200, 150, 8)), 1);
        assertEq(h.expected(ge(8, 9), cs(200, 256, 8)), 0);
        // Add(9, 8): widthA >= widthB.
        assertEq(h.expected(add(9, 8), cs(511, 255, 9)), 766);
    }

    function test_formula_table_reverts() public {
        vm.expectRevert(bytes("FormulaLib: table piece"));
        h.expected(Piece(PieceKind.Table, 2, 1, 0, 0), 1);
    }

    function testFuzz_ge_matchesSolidity(uint8 wa, uint8 wb, uint256 a, uint256 b) public view {
        wa = uint8(bound(wa, 1, 16));
        wb = uint8(bound(wb, 1, 17 - uint256(wa)));
        a = bound(a, 0, (uint256(1) << wa) - 1);
        b = bound(b, 0, (uint256(1) << wb) - 1);
        assertEq(h.expected(ge(wa, wb), cs(a, b, wa)), a >= b ? 1 : 0);
    }

    function testFuzz_add_matchesSolidity(uint8 wa, uint8 wb, uint256 a, uint256 b) public view {
        wa = uint8(bound(wa, 1, 16));
        wb = uint8(bound(wb, 1, wa > 17 - wa ? 17 - uint256(wa) : wa));
        a = bound(a, 0, (uint256(1) << wa) - 1);
        b = bound(b, 0, (uint256(1) << wb) - 1);
        uint256 got = h.expected(add(wa, wb), cs(a, b, wa));
        assertEq(got, a + b);
        assertLt(got, uint256(1) << (uint256(wa) + 1)); // fits in nOut = widthA + 1 bits
    }

    /// Bits of c above nIn never reach the answer (the contract never passes them, but the formula must not care).
    function testFuzz_highBitsIgnored(uint256 c, uint256 junk) public view {
        c = bound(c, 0, (uint256(1) << 16) - 1);
        junk = bound(junk, 1, type(uint128).max);
        uint256 dirty = c | (junk << 16);
        assertEq(h.expected(ge(8, 8), dirty), h.expected(ge(8, 8), c));
        assertEq(h.expected(add(8, 8), dirty), h.expected(add(8, 8), c));
    }
}

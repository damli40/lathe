// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {BitLib} from "../src/BitLib.sol";

contract BitLibHarness {
    function pack(uint256 v, uint256 n) external pure returns (bytes memory) {
        return BitLib.pack(v, n);
    }

    function readBits(bytes calldata d, uint256 o, uint256 n) external pure returns (uint256) {
        return BitLib.readBits(d, o, n);
    }

    function lowBits(bytes calldata d, uint256 n) external pure returns (uint256) {
        return BitLib.lowBits(d, n);
    }
}

contract BitLibTest is Test {
    BitLibHarness h;

    function setUp() public {
        h = new BitLibHarness();
    }

    function test_pack_xorInputs() public view {
        assertEq(h.pack(2, 2), hex"02");
    }

    function test_pack_16bits() public view {
        assertEq(h.pack(0xFFFF, 16), hex"ffff");
    }

    function test_lowBits_ignoresPadding() public view {
        assertEq(h.lowBits(hex"ff", 1), 1);
        assertEq(h.lowBits(hex"fe", 1), 0);
    }

    function test_readBits_crossesByte() public view {
        // bit 7 of byte 0 is 1 (0x80), bit 8 = bit 0 of byte 1 is 1 (0x01): LSB first -> 0b11.
        assertEq(h.readBits(hex"8001", 7, 2), 3);
    }

    function test_pack_zeroBits() public view {
        assertEq(h.pack(0, 0).length, 0);
    }

    // Extra: pack drops bits above nBits, so a caller cannot smuggle extra bits in.
    function test_pack_masksHighBits() public view {
        assertEq(h.pack(0x1FF, 8), hex"ff");
        assertEq(h.pack(0x7, 2), hex"03");
    }

    // Extra: reading past the end of the data treats missing bits as 0 (short eval outputs never read garbage).
    function test_readBits_pastEndIsZero() public view {
        assertEq(h.readBits(hex"01", 0, 16), 1);
        assertEq(h.lowBits(hex"", 1), 0);
    }

    function testFuzz_packThenRead(uint256 v, uint8 n) public view {
        uint256 nBits = n; // 0..255
        bytes memory p = h.pack(v, nBits);
        assertEq(p.length, (nBits + 7) / 8);
        uint256 masked = v & ((uint256(1) << nBits) - 1);
        assertEq(h.lowBits(p, nBits), masked);
    }
}

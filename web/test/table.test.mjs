// Encoder tests. Every vector is copied from the Solidity tests named in each comment.
// Run: node --test web/test/
import { test } from "node:test";
import assert from "node:assert/strict";
import {
  encodeTable, decodeTable, expected, readBits, pack, toHex, fromHex, tableProblem, byteLength, presetAnswers,
} from "../table.js";

test("XOR 2 inputs, 1 output = 0x06 (test/LatheBase.sol xorTable, test/fork/XorFork.t.sol)", () => {
  assert.equal(toHex(encodeTable(2, 1, [0, 1, 1, 0])), "0x06");
  assert.equal(toHex(encodeTable(2, 1, presetAnswers("xor", 2))), "0x06");
});

test("XNOR = 0x09 and OR = 0x0e (test/fork/XorFork.t.sol test_fork_wrongTableFails)", () => {
  assert.equal(toHex(encodeTable(2, 1, [1, 0, 0, 1])), "0x09");
  assert.equal(toHex(encodeTable(2, 1, [0, 1, 1, 1])), "0x0e");
  assert.equal(toHex(encodeTable(2, 1, presetAnswers("or", 2))), "0x0e");
});

test("LSB first: expected() reads 0x06 as 0,1,1,0 (test/LatheOrders.create.t.sol test_expected_xorTable)", () => {
  const t = fromHex("0x06");
  assert.deepEqual([0, 1, 2, 3].map((c) => expected(t, c, 1)), [0, 1, 1, 0]);
});

test("3-bit answers 5,2,7 -> d5 01 (test/LatheOrders.create.t.sol test_expected_wideAnswers)", () => {
  assert.equal(toHex(encodeTable(2, 3, [5, 2, 7, 0])), "0xd501");
  const t = fromHex("0xd501");
  assert.equal(expected(t, 0, 3), 5);
  assert.equal(expected(t, 1, 3), 2);
  assert.equal(expected(t, 2, 3), 7);
  assert.deepEqual(decodeTable(2, 3, t), [5, 2, 7, 0]);
});

test("padding bits must be zero (test/LatheOrders.create.t.sol test_create_rejectsNonZeroTablePadding)", () => {
  assert.equal(tableProblem(2, 1, fromHex("0xf6")), "TablePaddingNotZero");
  assert.equal(tableProblem(2, 1, fromHex("0x86")), "TablePaddingNotZero");
  assert.equal(tableProblem(2, 3, fromHex("0xd511")), "TablePaddingNotZero");
  assert.equal(tableProblem(2, 1, fromHex("0x06")), null);
  assert.equal(tableProblem(2, 3, fromHex("0xd501")), null);
  // a whole number of bytes has no padding
  assert.equal(tableProblem(6, 1, fromHex("0xffffffffffffffff")), null);
  assert.equal(toHex(encodeTable(6, 1, new Array(64).fill(1))), "0xffffffffffffffff");
  // the encoder never sets a padding bit, for every shape
  for (let nIn = 1; nIn <= 6; nIn++) {
    for (let nOut = 1; nOut <= 16; nOut++) {
      const all = new Array(1 << nIn).fill(2 ** nOut - 1);
      assert.equal(tableProblem(nIn, nOut, encodeTable(nIn, nOut, all)), null, `${nIn}x${nOut}`);
    }
  }
});

test("wrong length (test/LatheOrders.create.t.sol test_create_rejectsWrongTableLength)", () => {
  assert.equal(tableProblem(2, 1, fromHex("0x0600")), "WrongTableLength");
  assert.equal(tableProblem(6, 1, new Uint8Array(7)), "WrongTableLength");
});

test("byteLength (test/LatheOrders.create.t.sol test_byteLength)", () => {
  assert.equal(byteLength(4, 1), 1);
  assert.equal(byteLength(64, 1), 8);
  assert.equal(byteLength(64, 16), 128);
  assert.equal(byteLength(3, 3), 2);
});

test("6-input parity table matches test/LatheBase.sol parityTable()", () => {
  // the Solidity loop, mirrored: t[c/8] |= 1 << (c%8) when parity(c) == 1
  const t = new Uint8Array(8);
  for (let c = 0; c < 64; c++) {
    let p = 0;
    for (let b = 0; b < 6; b++) p ^= (c >> b) & 1;
    if (p) t[c >> 3] |= 1 << (c % 8);
  }
  assert.equal(toHex(t), "0x9669699669969669");
  assert.equal(toHex(encodeTable(6, 1, presetAnswers("xor", 6))), "0x9669699669969669");
});

test("BitLib vectors (test/BitLib.t.sol)", () => {
  assert.equal(toHex(pack(2, 2)), "0x02");
  assert.equal(toHex(pack(0xffff, 16)), "0xffff");
  assert.equal(toHex(pack(0x1ff, 8)), "0xff");
  assert.equal(toHex(pack(0x7, 2)), "0x03");
  assert.equal(readBits(fromHex("0x8001"), 7, 2), 3);
  assert.equal(readBits(fromHex("0xff"), 0, 1), 1);
  assert.equal(readBits(fromHex("0xfe"), 0, 1), 0);
  assert.equal(readBits(fromHex("0x01"), 0, 16), 1);
  assert.equal(readBits(new Uint8Array(0), 0, 1), 0);
});

test("presets: AND and majority", () => {
  assert.deepEqual(presetAnswers("and", 2), [0, 0, 0, 1]);
  assert.deepEqual(presetAnswers("majority", 3), [0, 0, 0, 1, 0, 1, 1, 1]);
});

test("16 outputs, 64 cases round-trips", () => {
  const a = Array.from({ length: 64 }, (_, c) => (c * 2654435761) % 65536);
  const t = encodeTable(6, 16, a);
  assert.equal(t.length, 128);
  assert.deepEqual(decodeTable(6, 16, t), a);
});

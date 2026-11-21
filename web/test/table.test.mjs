// Encoder tests. Every vector is copied from the Solidity tests named in each comment.
// Run: node --test web/test/
import { test } from "node:test";
import assert from "node:assert/strict";
import {
  encodeTable, decodeTable, expected, readBits, pack, toHex, fromHex, tableProblem, byteLength, presetAnswers,
  cleanName, nameHasControls,
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

// ---- one memory bit (V1). Vectors copied from test/LatheOrders.state.t.sol.
import { caseCount, stateBit } from "../table.js";

test("memory: 2^(nIn + nState) cases, state bit sits above the inputs", () => {
  assert.equal(caseCount(4, 1), 32);
  assert.equal(caseCount(2), 4);
  assert.equal(stateBit(16, 4), 1);
  assert.equal(stateBit(15, 4), 0);
});

test("memory: breaker table = a8a8a9a9aaa8aaa9 (test_state_breakerTableBytes)", () => {
  const answers = [];
  for (let c = 0; c < 32; c++) {
    const i = c & 15;
    const tripped = c >> 4;
    const nt = (tripped & (1 - ((i >> 2) & 1))) | (i & 1) | ((i >> 1) & 1);
    const power = ((i >> 3) & 1) & (1 - nt);
    answers.push(power | (nt << 1)); // outputs low, new memory above
  }
  const hex = toHex(encodeTable(4, 1, answers, 1));
  assert.equal(hex, "0xa8a8a9a9aaa8aaa9");
  assert.deepEqual(decodeTable(4, 1, fromHex(hex), 1), answers);
});

test("memory: the no-input toggle of test_state_noInputs_toggle (output = old memory) is 0x06", () => {
  assert.equal(toHex(encodeTable(0, 1, [2, 1], 1)), "0x06");
  assert.deepEqual(decodeTable(0, 1, fromHex("0x06"), 1), [2, 1]);
});

test("memory: toggle preset (output = new memory): no inputs = 0x03, one input = 0x3c", () => {
  assert.deepEqual(presetAnswers("toggle", 0, 1), [3, 0]);
  assert.equal(toHex(encodeTable(0, 1, presetAnswers("toggle", 0, 1), 1)), "0x03");
  // x0 = 1 flips the memory: cases (x0,s) 00 -> 0, 10 -> 3, 01 -> 3, 11 -> 0
  assert.deepEqual(presetAnswers("toggle", 1, 1), [0, 3, 3, 0]);
  assert.equal(toHex(encodeTable(1, 1, presetAnswers("toggle", 1, 1), 1)), "0x3c");
});

test("memory: input presets ignore the memory bit and leave new memory 0", () => {
  assert.deepEqual(presetAnswers("xor", 2, 1), [0, 1, 1, 0, 0, 1, 1, 0]);
  assert.deepEqual(presetAnswers("and", 2, 1), [0, 0, 0, 1, 0, 0, 0, 1]);
});

test("memory: shape errors match the contract (test_state_* in LatheOrders.state.t.sol)", () => {
  assert.equal(tableProblem(0, 1, fromHex("0x16"), 1), "TablePaddingNotZero");
  assert.equal(tableProblem(0, 1, fromHex("0x06"), 1), null);
  assert.equal(tableProblem(4, 1, new Uint8Array(4), 1), "WrongTableLength");
  assert.equal(tableProblem(2, 1, new Uint8Array(6), 2), "UnsupportedStateBits");
  assert.equal(tableProblem(6, 1, new Uint8Array(32), 1), "TooManyCases");
  assert.throws(() => encodeTable(6, 1, new Array(128).fill(0), 1));
});

test("input names: text-direction and control characters are removed for display and refused on the form", () => {
  // "x1)" + RIGHT-TO-LEFT OVERRIDE would make a header read as another column
  assert.equal(cleanName("x1)\u202E"), "x1)");
  for (const ch of ["\u202A", "\u202B", "\u202C", "\u202D", "\u202E", "\u2066", "\u2067", "\u2068", "\u2069", "\u200E", "\u200F", "\u061C", "\u0000", "\u0007", "\t", "\n", "\u007F", "\u0085", "\u009F"]) {
    assert.equal(cleanName("a" + ch + "b"), "ab", "U+" + ch.codePointAt(0).toString(16));
    assert.equal(nameHasControls("a" + ch), true, "U+" + ch.codePointAt(0).toString(16));
  }
  assert.equal(cleanName("fault"), "fault");
  assert.equal(cleanName("故障 reset"), "故障 reset");
  assert.equal(nameHasControls("故障 reset"), false);
  assert.equal(nameHasControls(""), false);
  assert.equal(cleanName(null), "");
});

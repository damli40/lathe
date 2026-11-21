// Pieced orders in the page: the join and piece answers (web/pieces.js) and the refund rule (web/gas.js), with
// vectors worked out from src/FormulaLib.sol and LatheOrders.createPiecedOrder / refund.
import { test } from "node:test";
import assert from "node:assert/strict";
import { KIND, pieceExpected, joinExpected, topInputs, packBig, readBitsBig, pieceState } from "../pieces.js";
import { refundOpensAtPieced } from "../gas.js";

const ge = (wa, wb) => ({ kind: KIND.GreaterOrEqual, nIn: wa + wb, nOut: 1, widthA: wa, widthB: wb });
const add = (wa, wb) => ({ kind: KIND.Add, nIn: wa + wb, nOut: wa + 1, widthA: wa, widthB: wb });
const tab = (nIn, nOut) => ({ kind: KIND.Table, nIn, nOut, widthA: 0, widthB: 0 });

test("formula pieces: a is the low widthA bits, b the next widthB (FormulaLib example: GE(8,8) case 0x0405 = 1)", () => {
  assert.equal(pieceExpected(ge(8, 8), 0x0405, null), 1n);
  assert.equal(pieceExpected(ge(8, 8), 0x0504, null), 0n);
  assert.equal(pieceExpected(add(2, 2), 0b1111, null), 6n);
  assert.equal(pieceExpected(add(2, 2), 0b0110, null), 3n); // a = 2, b = 1
});

test("table piece reads its own table bits (AND-NOT 0x02: only case 1 answers 1)", () => {
  const t = new Uint8Array([0x02]);
  assert.deepEqual([0, 1, 2, 3].map((c) => pieceExpected(tab(2, 1), c, t)), [0n, 1n, 0n, 0n]);
});

test("join Add(2,2) then GE(3,2): (x0..1 + x2..3) >= x4..5 on all 64 inputs, and bit order matters", () => {
  const ps = [add(2, 2), ge(3, 2)];
  assert.equal(topInputs(ps), 6);
  for (let x = 0; x < 64; x++) {
    const want = (x & 3) + ((x >> 2) & 3) >= ((x >> 4) & 3) ? 1n : 0n;
    assert.equal(joinExpected(ps, [new Uint8Array(0), new Uint8Array(0)], x), want, "x=" + x);
  }
  // x4 = 1 (b = 1), a = b = 0: 0 >= 1 is false; the same bit at x0 gives 1 >= 0, true.
  assert.equal(joinExpected(ps, [null, null], 0b010000), 0n);
  assert.equal(joinExpected(ps, [null, null], 0b000001), 1n);
});

test("join GE(2,2) then AND-NOT table matches the contract's test (LatheOrders.pieces.t.sol createSmall)", () => {
  const ps = [ge(2, 2), tab(2, 1)];
  const t = [null, new Uint8Array([0x02])];
  for (let x = 0; x < 32; x++) {
    const want = (x & 3) >= ((x >> 2) & 3) && ((x >> 4) & 1) === 0 ? 1n : 0n;
    assert.equal(joinExpected(ps, t, x), want, "x=" + x);
  }
});

test("BigInt packing works past 31 bits", () => {
  const v = (1n << 32n) | 5n;
  assert.deepEqual(Array.from(packBig(v, 33)), [5, 0, 0, 0, 1]);
  assert.equal(readBitsBig(packBig(v, 33), 0, 33), v);
});

test("piece state: no delivery, being checked, passed", () => {
  const p = ge(2, 2);
  assert.equal(pieceState(p, { processor: "0x" + "0".repeat(40), nextCase: 0 }), "none");
  assert.equal(pieceState(p, { processor: "0x" + "1".repeat(40), nextCase: 15 }), "checking");
  assert.equal(pieceState(p, { processor: "0x" + "1".repeat(40), nextCase: 16 }), "passed");
});

test("pieced refund: right after the deadline while a piece has no delivery, else after the grace day; never unless Open", () => {
  assert.equal(refundOpensAtPieced(0, 1000n, 86400n, false), 1001n);
  assert.equal(refundOpensAtPieced(0, 1000n, 86400n, true), 87401n);
  assert.equal(refundOpensAtPieced(2, 1000n, 86400n, false), null);
  assert.equal(refundOpensAtPieced(3, 1000n, 86400n, true), null);
});

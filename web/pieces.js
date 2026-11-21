// Pieced orders (createPiecedOrder): the expected answer of a piece and of the joined rule, computed in the page the
// same way the contract does. Pure functions, BigInt throughout (a 2-piece order can have more than 31 inputs).
// Tested by web/test/pieces.test.mjs.
//
// Layout, lowest bit first everywhere (src/FormulaLib.sol, LatheOrders.createPiecedOrder):
// - piece case c: piece input k is bit k of c;
// - formula pieces: a = the low widthA bits of c, b = the next widthB bits;
//   GreaterOrEqual answers 1 bit (a >= b), Add answers widthA + 1 bits (a + b);
// - Table pieces: answer = the piece's table bits for case c (TableLib, no memory);
// - two pieces A, B: A gets x's low A.nIn bits; B gets A's answer in its low A.nOut input bits and x >> A.nIn above:
//   B.in = outA | ((x >> A.nIn) << A.nOut). The order answers B's outputs.

export const KIND = { Table: 0, GreaterOrEqual: 1, Add: 2 };

const mask = (n) => (1n << BigInt(n)) - 1n;

/** Read nBits from bytes starting at bit offset, LSB first, as a BigInt; bits past the end read as 0. */
export function readBitsBig(bytes, offset, nBits) {
  let v = 0n;
  for (let i = 0; i < nBits; i++) {
    const bit = offset + i;
    const byteIndex = bit >> 3;
    if (byteIndex >= bytes.length) break;
    if ((bytes[byteIndex] >> (bit & 7)) & 1) v |= 1n << BigInt(i);
  }
  return v;
}

/** The low nBits of value as ceil(nBits/8) bytes, LSB first (BitLib.pack). */
export function packBig(value, nBits) {
  const out = new Uint8Array(Math.ceil(nBits / 8));
  const v = BigInt(value) & mask(nBits);
  for (let i = 0; i < out.length; i++) out[i] = Number((v >> BigInt(8 * i)) & 0xffn);
  return out;
}

/** Piece p's expected answer for case c. `table` is the piece's table bytes (Table pieces only). */
export function pieceExpected(p, c, table) {
  const x = BigInt(c) & mask(p.nIn);
  if (p.kind === KIND.Table) return readBitsBig(table, Number(x) * p.nOut, p.nOut);
  const a = x & mask(p.widthA);
  const b = (x >> BigInt(p.widthA)) & mask(p.widthB);
  if (p.kind === KIND.GreaterOrEqual) return a >= b ? 1n : 0n;
  if (p.kind === KIND.Add) return a + b;
  throw new Error("unknown piece kind " + p.kind);
}

/** The order's top-level input count: A.nIn, or A.nIn + B.nIn - A.nOut for two pieces. */
export function topInputs(pieces) {
  return pieces.length === 1 ? pieces[0].nIn : pieces[0].nIn + pieces[1].nIn - pieces[0].nOut;
}

/** The joined rule's expected answer for top-level input x (BigInt or number). `tables[i]` = piece i's table bytes. */
export function joinExpected(pieces, tables, x) {
  const X = BigInt(x);
  const a = pieces[0];
  const outA = pieceExpected(a, X & mask(a.nIn), tables[0]);
  if (pieces.length === 1) return outA;
  const bIn = outA | ((X >> BigInt(a.nIn)) << BigInt(a.nOut));
  return pieceExpected(pieces[1], bIn, tables[1]);
}

/**
 * A piece's state from its pieceOf record: "none" (no delivery, processor 0), "checking" (cursor below 2^nIn) or
 * "passed" (cursor at 2^nIn), the same rule as LatheOrders._allPassedUnchanged.
 */
export function pieceState(p, d) {
  if (!d || /^0x0{40}$/i.test(d.processor)) return "none";
  return BigInt(d.nextCase) >= 1n << BigInt(p.nIn) ? "passed" : "checking";
}

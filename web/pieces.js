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
// - wired orders (createPiecedOrder with a PiecedSpec, 1 to 8 pieces): wiresOf(id) lists every wire in the stored
//   order (piece 0's inputs 0, 1, .., then piece 1's, .., then the order's outputs); fromPiece / toPiece 255 = the
//   order itself. The pieces run in index order, each on the bits its wires name (LatheReads._runChain).

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

/** The piece index that stands for "the order itself" in a wire (NetlistLib.WIRE_TOP). */
export const WIRE_TOP = 255;

/** A wire from wiresOf as plain numbers. */
export function normWire(w) {
  return { fromPiece: Number(w.fromPiece), fromBit: Number(w.fromBit), toPiece: Number(w.toPiece), toBit: Number(w.toBit) };
}

/**
 * The wired rule's expected answer for order input x, the same way LatheReads._runChain computes it: pieces in index
 * order, piece k's input j = the bit its wire names (an order input bit, or a bit of an earlier piece's answer).
 * `wires` must be in the stored order (wiresOf). nOut = the order's output count.
 */
export function chainExpected(pieces, tables, wires, nOut, x) {
  const X = BigInt(x);
  const ws = wires.map(normWire);
  const outs = [];
  const bit = (e) => (((e.fromPiece === WIRE_TOP ? X : outs[e.fromPiece]) >> BigInt(e.fromBit)) & 1n);
  let w = 0;
  pieces.forEach((p, k) => {
    let xin = 0n;
    for (let j = 0; j < p.nIn; j++) xin |= bit(ws[w++]) << BigInt(j);
    outs[k] = pieceExpected(p, xin, tables[k]);
  });
  let y = 0n;
  for (let j = 0; j < nOut; j++) y |= bit(ws[w + j]) << BigInt(j);
  return y;
}

/**
 * The wires grouped into runs for plain-words display: consecutive pins of one sink fed by consecutive bits of one
 * source. Each run: { to (piece index, or WIRE_TOP for the order's outputs), toFirst, toLast, from (piece index, or
 * WIRE_TOP for the order's inputs), fromFirst, fromLast }. Runs keep the stored order (piece 0 first, outputs last).
 */
export function wireRuns(wires) {
  const runs = [];
  for (const e of wires.map(normWire)) {
    const r = runs[runs.length - 1];
    if (r && r.to === e.toPiece && r.from === e.fromPiece && e.toBit === r.toLast + 1 && e.fromBit === r.fromLast + 1) {
      r.toLast = e.toBit;
      r.fromLast = e.fromBit;
    } else {
      runs.push({ to: e.toPiece, toFirst: e.toBit, toLast: e.toBit, from: e.fromPiece, fromFirst: e.fromBit, fromLast: e.fromBit });
    }
  }
  return runs;
}

/**
 * The wires of an order made without explicit wires (1 or 2 pieces), as LatheReads.wiresOf returns them: the fixed
 * join written out. An order whose wiresOf equals this is shown with the join text; any other with the wire list.
 */
export function defaultWires(pieces) {
  const a = pieces[0];
  const b = pieces[pieces.length - 1];
  const out = [];
  for (let j = 0; j < a.nIn; j++) out.push({ fromPiece: WIRE_TOP, fromBit: j, toPiece: 0, toBit: j });
  if (pieces.length === 2) {
    for (let j = 0; j < b.nIn; j++) out.push(j < a.nOut ? { fromPiece: 0, fromBit: j, toPiece: 1, toBit: j } : { fromPiece: WIRE_TOP, fromBit: a.nIn + j - a.nOut, toPiece: 1, toBit: j });
  }
  for (let j = 0; j < b.nOut; j++) out.push({ fromPiece: pieces.length - 1, fromBit: j, toPiece: WIRE_TOP, toBit: j });
  return out;
}

/** True when two wire lists are the same wires in the same order. */
export function sameWires(a, b) {
  if (a.length !== b.length) return false;
  return a.every((w, i) => {
    const x = normWire(w);
    const y = normWire(b[i]);
    return x.fromPiece === y.fromPiece && x.fromBit === y.fromBit && x.toPiece === y.toPiece && x.toBit === y.toBit;
  });
}

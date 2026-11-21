// Truth-table encoding, the same as src/TableLib.sol and src/BitLib.sol.
// Pure functions only: no DOM, no chain. Tested by web/test/table.test.mjs.
//
// The rule (TableLib.sol):
//   - case c runs 0 .. 2^nIn - 1; the circuit's inputs for case c are c & (2^nIn - 1),
//     input bit k is (c >> k) & 1;
//   - each case's answer is nOut bits (V0 orders have no memory bits);
//   - the table is every answer concatenated least significant bit first:
//     case c's answer starts at bit c * nOut; bit k of the table lives in byte k >> 3 at position k & 7;
//   - the table is exactly ceil(2^nIn * nOut / 8) bytes and the unused high bits of the last byte are zero
//     (LatheOrders reverts TablePaddingNotZero otherwise).

export const MAX_INPUTS = 6; // LatheOrders.MAX_CASE_BITS with no memory bits
export const MAX_OUTPUTS = 16; // LatheOrders.MAX_ANSWER_BITS with no memory bits

export function caseCount(nIn) {
  return 1 << nIn;
}

export function byteLength(cases, w) {
  return Math.ceil((cases * w) / 8);
}

/** Input bit k of case c. */
export function inputBit(c, k) {
  return (c >> k) & 1;
}

/**
 * Encode answers into table bytes.
 * @param {number} nIn 1..6
 * @param {number} nOut 1..16
 * @param {number[]} answers one integer per case, answers[c] in [0, 2^nOut)
 * @returns {Uint8Array}
 */
export function encodeTable(nIn, nOut, answers) {
  checkShape(nIn, nOut);
  const cases = caseCount(nIn);
  if (!Array.isArray(answers) || answers.length !== cases) {
    throw new Error(`need ${cases} answers, got ${answers?.length}`);
  }
  const out = new Uint8Array(byteLength(cases, nOut));
  for (let c = 0; c < cases; c++) {
    const a = answers[c];
    if (!Number.isInteger(a) || a < 0 || a >= 2 ** nOut) throw new Error(`answer for case ${c} out of range`);
    for (let i = 0; i < nOut; i++) {
      if ((a >> i) & 1) {
        const bit = c * nOut + i;
        out[bit >> 3] |= 1 << (bit & 7);
      }
    }
  }
  return out; // padding bits are never set, so they are zero
}

/** Read nBits starting at bit offset, LSB first; bits past the end read as 0 (BitLib.readBits). */
export function readBits(bytes, offset, nBits) {
  let v = 0;
  for (let i = 0; i < nBits; i++) {
    const bit = offset + i;
    const byteIndex = bit >> 3;
    if (byteIndex >= bytes.length) break;
    v |= ((bytes[byteIndex] >> (bit & 7)) & 1) << i;
  }
  return v >>> 0;
}

/** The expected answer for case c (TableLib.expected). */
export function expected(bytes, c, nOut) {
  return readBits(bytes, c * nOut, nOut);
}

/** Decode table bytes back into one answer per case. Throws if the length or padding is wrong. */
export function decodeTable(nIn, nOut, bytes) {
  const problem = tableProblem(nIn, nOut, bytes);
  if (problem) throw new Error(problem);
  const cases = caseCount(nIn);
  const answers = new Array(cases);
  for (let c = 0; c < cases; c++) answers[c] = expected(bytes, c, nOut);
  return answers;
}

/** null when createOrder would accept the table's shape, else the contract error name it would revert with. */
export function tableProblem(nIn, nOut, bytes) {
  if (!Number.isInteger(nIn) || nIn < 0 || nIn > MAX_INPUTS) return "TooManyCases";
  if (!Number.isInteger(nOut) || nOut < 1 || nOut > MAX_OUTPUTS) return "TooManyOutputs";
  const cases = caseCount(nIn);
  const bits = cases * nOut;
  if (bytes.length !== byteLength(cases, nOut)) return "WrongTableLength";
  if (bits % 8 !== 0 && bytes[bytes.length - 1] >> (bits % 8) !== 0) return "TablePaddingNotZero";
  return null;
}

export function toHex(bytes) {
  let s = "0x";
  for (const b of bytes) s += b.toString(16).padStart(2, "0");
  return s;
}

export function fromHex(hex) {
  const h = hex.startsWith("0x") ? hex.slice(2) : hex;
  if (h.length % 2 !== 0 || /[^0-9a-fA-F]/.test(h)) throw new Error("bad hex");
  const out = new Uint8Array(h.length / 2);
  for (let i = 0; i < out.length; i++) out[i] = parseInt(h.slice(2 * i, 2 * i + 2), 16);
  return out;
}

/** BitLib.pack: the low nBits of value as ceil(nBits/8) bytes, LSB first. */
export function pack(value, nBits) {
  const len = Math.ceil(nBits / 8);
  const out = new Uint8Array(len);
  const masked = nBits >= 31 ? value : value & ((1 << nBits) - 1);
  for (let i = 0; i < len; i++) out[i] = (masked >> (8 * i)) & 0xff;
  return out;
}

function checkShape(nIn, nOut) {
  if (!Number.isInteger(nIn) || nIn < 1 || nIn > MAX_INPUTS) throw new Error(`nIn must be 1..${MAX_INPUTS}`);
  if (!Number.isInteger(nOut) || nOut < 1 || nOut > MAX_OUTPUTS) throw new Error(`nOut must be 1..${MAX_OUTPUTS}`);
}

function popcount(c) {
  let n = 0;
  while (c) {
    n += c & 1;
    c >>= 1;
  }
  return n;
}

/**
 * Presets for one output bit, as a function of the case number.
 * xor: odd number of inputs on (parity); and: every input on; or: any input on;
 * majority: more than half of the inputs on.
 */
export const PRESETS = {
  xor: (c, nIn) => popcount(c & (caseCount(nIn) - 1)) % 2,
  and: (c, nIn) => (c === caseCount(nIn) - 1 ? 1 : 0),
  or: (c) => (c !== 0 ? 1 : 0),
  majority: (c, nIn) => (popcount(c) * 2 > nIn ? 1 : 0),
};

/** Answers for a preset on output bit 0, every other output bit zero. */
export function presetAnswers(name, nIn) {
  const f = PRESETS[name];
  if (!f) throw new Error(`unknown preset ${name}`);
  const cases = caseCount(nIn);
  const out = new Array(cases);
  for (let c = 0; c < cases; c++) out[c] = f(c, nIn);
  return out;
}

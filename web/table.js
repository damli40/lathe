// Truth-table encoding, the same as src/TableLib.sol and src/BitLib.sol.
// Pure functions only: no DOM, no chain. Tested by web/test/table.test.mjs.
//
// The rule (TableLib.sol). nState is the number of memory bits, 0 or 1 (V1 orders); it defaults to 0.
//   - case c runs 0 .. 2^(nIn + nState) - 1; the circuit's inputs for case c are c & (2^nIn - 1),
//     input bit k is (c >> k) & 1; the starting memory (state) is c >> nIn, so state bits sit above the inputs;
//   - each case's answer is w = nOut + nState bits: outputs in the low nOut bits, the new memory above them;
//   - the table is every answer concatenated least significant bit first:
//     case c's answer starts at bit c * w; bit k of the table lives in byte k >> 3 at position k & 7;
//   - the table is exactly ceil(2^(nIn + nState) * w / 8) bytes and the unused high bits of the last byte are
//     zero (LatheOrders reverts TablePaddingNotZero otherwise).

export const MAX_INPUTS = 6; // LatheOrders.MAX_CASE_BITS: inputs + memory bits
export const MAX_OUTPUTS = 16; // LatheOrders.MAX_ANSWER_BITS: outputs + memory bits
export const MAX_STATE = 1; // createStatefulOrder takes exactly one memory bit

export function caseCount(nIn, nState = 0) {
  return 1 << (nIn + nState);
}

/** Memory bit k of case c (the state the circuit starts the case with). */
export function stateBit(c, nIn, k = 0) {
  return (c >> (nIn + k)) & 1;
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
 * @param {number} nIn 1..6 (0..5 with a memory bit)
 * @param {number} nOut 1..16
 * @param {number[]} answers one integer per case, answers[c] in [0, 2^(nOut + nState)): outputs low, new memory above
 * @param {number} nState 0 or 1
 * @returns {Uint8Array}
 */
export function encodeTable(nIn, nOut, answers, nState = 0) {
  checkShape(nIn, nOut, nState);
  const cases = caseCount(nIn, nState);
  const w = nOut + nState;
  if (!Array.isArray(answers) || answers.length !== cases) {
    throw new Error(`need ${cases} answers, got ${answers?.length}`);
  }
  const out = new Uint8Array(byteLength(cases, w));
  for (let c = 0; c < cases; c++) {
    const a = answers[c];
    if (!Number.isInteger(a) || a < 0 || a >= 2 ** w) throw new Error(`answer for case ${c} out of range`);
    for (let i = 0; i < w; i++) {
      if ((a >> i) & 1) {
        const bit = c * w + i;
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

/** Decode table bytes back into one answer per case (outputs low, new memory above). Throws if the length or
 * padding is wrong. */
export function decodeTable(nIn, nOut, bytes, nState = 0) {
  const problem = tableProblem(nIn, nOut, bytes, nState);
  if (problem) throw new Error(problem);
  const cases = caseCount(nIn, nState);
  const answers = new Array(cases);
  for (let c = 0; c < cases; c++) answers[c] = expected(bytes, c, nOut + nState);
  return answers;
}

/** null when the create call would accept the table's shape, else the contract error name it would revert with. */
export function tableProblem(nIn, nOut, bytes, nState = 0) {
  if (!Number.isInteger(nState) || nState < 0 || nState > MAX_STATE) return "UnsupportedStateBits";
  if (!Number.isInteger(nIn) || nIn < 0 || nIn + nState > MAX_INPUTS) return "TooManyCases";
  if (!Number.isInteger(nOut) || nOut < 1 || nOut + nState > MAX_OUTPUTS) return "TooManyOutputs";
  const cases = caseCount(nIn, nState);
  const w = nOut + nState;
  const bits = cases * w;
  if (bytes.length !== byteLength(cases, w)) return "WrongTableLength";
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

function checkShape(nIn, nOut, nState = 0) {
  if (!Number.isInteger(nState) || nState < 0 || nState > MAX_STATE) throw new Error(`nState must be 0..${MAX_STATE}`);
  const minIn = nState > 0 ? 0 : 1;
  if (!Number.isInteger(nIn) || nIn < minIn || nIn + nState > MAX_INPUTS) throw new Error(`nIn must be ${minIn}..${MAX_INPUTS - nState}`);
  if (!Number.isInteger(nOut) || nOut < 1 || nOut + nState > MAX_OUTPUTS) throw new Error(`nOut must be 1..${MAX_OUTPUTS - nState}`);
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

/**
 * Answers for a preset on output bit 0, every other output bit zero. With a memory bit, the preset reads the
 * inputs only (the memory bit is ignored) and the new memory is 0, except "toggle" (memory presets below).
 */
export function presetAnswers(name, nIn, nState = 0, nOut = 1) {
  if (nState > 0 && STATE_PRESETS[name]) {
    const cases = caseCount(nIn, nState);
    const out = new Array(cases);
    for (let c = 0; c < cases; c++) out[c] = STATE_PRESETS[name](c, nIn, nOut);
    return out;
  }
  const f = PRESETS[name];
  if (!f) throw new Error(`unknown preset ${name}`);
  const cases = caseCount(nIn, nState);
  const mask = caseCount(nIn) - 1;
  const out = new Array(cases);
  for (let c = 0; c < cases; c++) out[c] = f(c & mask, nIn);
  return out;
}

/**
 * Presets for one memory bit. Each returns the whole answer: outputs low, new memory at bit nOut.
 * toggle: the memory flips when x0 is 1 and stays when x0 is 0; output y0 shows the new memory.
 * With no inputs it flips every case.
 */
export const STATE_PRESETS = {
  toggle: (c, nIn, nOut) => {
    const s = stateBit(c, nIn);
    const flip = nIn > 0 ? inputBit(c, 0) : 1;
    const next = s ^ flip;
    return next | (next << nOut);
  },
};

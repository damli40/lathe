// Gas and amount helpers. Pure functions only, BigInt throughout. Tested by web/test/gas.test.mjs.
// The constants (base, perGate, reserve, inlineMax, maxCaseGas) are read from the deployed contract
// at run time and passed in; nothing here hard-codes them.

/** LatheOrders.evalBudget: gas each case's eval gets. */
export function evalBudget(c, gateCount) {
  return c.base + c.perGate * BigInt(gateCount);
}

/** True when deliver checks every case in the same transaction (LatheOrders._checkInlineIfSmall). */
export function checksInline(c, cases, gateCount) {
  return BigInt(cases) * evalBudget(c, gateCount) <= c.inlineMax;
}

/** The largest gate count whose full check still fits inside deliver for this many cases. */
export function maxInlineGates(c, cases) {
  const perCase = c.inlineMax / BigInt(cases);
  if (perCase < c.base) return 0n;
  return (perCase - c.base) / c.perGate;
}

// Gas used around the per-case loop. Measured on the X Layer fork the whole inline XOR delivery used
// 347,941 gas (evidence/2026-11-20-eval-gas-budget.md); these overheads leave wide room on top of that.
export const DELIVER_OVERHEAD = 600_000n; // checks, storage writes, netlist hash, payout
export const NETLIST_GAS_PER_GATE = 600n; // reading and hashing a long netlist at delivery
export const CHECK_OVERHEAD = 400_000n; // circuit-changed check, netlist hash, payout
export const PER_CASE_EXTRA = 30_000n; // packing inputs, comparing the answer, loop
export const TX_GAS_CAP = 200_000_000n; // under the X Layer block gas limit of 210,000,000

/** Gas one case must have free before eval is called: budget * 64/63 + reserve (LatheOrders._caseMatches). */
export function perCaseHold(c, gateCount) {
  const b = evalBudget(c, gateCount);
  return (b * 64n + 62n) / 63n + c.reserve;
}

/**
 * Explicit gas limit for deliver. Worst case: every case burns its whole budget, and the last case still
 * needs its full hold free. Unused gas is not charged, so a high limit costs nothing extra.
 * Returns { gas, inline, capped }.
 */
export function deliverGasLimit(c, cases, gateCount) {
  const inline = checksInline(c, cases, gateCount);
  let gas = DELIVER_OVERHEAD + NETLIST_GAS_PER_GATE * BigInt(gateCount);
  if (inline) gas += BigInt(cases) * (perCaseHold(c, gateCount) + PER_CASE_EXTRA);
  const capped = gas > TX_GAS_CAP;
  return { gas: capped ? TX_GAS_CAP : gas, inline, capped };
}

/** Explicit gas limit for check(orderId, n). */
export function checkGasLimit(c, n, gateCount) {
  const gas =
    CHECK_OVERHEAD + NETLIST_GAS_PER_GATE * BigInt(gateCount) + BigInt(n) * (perCaseHold(c, gateCount) + PER_CASE_EXTRA);
  return gas > TX_GAS_CAP ? TX_GAS_CAP : gas;
}

// Both public X Layer RPCs cap eth_call at 50,000,000 gas, whatever the call asks for (measured 2026-11-21:
// 49,947,900 gas left inside the call). A simulation asked to run with more gas silently gets 50M, so the
// contract's per-case gasleft() test fails inside it. Simulations stay under this cap, with room to spare.
export const SIM_GAS_CAP = 48_000_000n;

/** Gas check(orderId, n) needs, before the transaction cap is applied. */
function checkGasRaw(c, n, gateCount) {
  return CHECK_OVERHEAD + NETLIST_GAS_PER_GATE * BigInt(gateCount) + BigInt(n) * (perCaseHold(c, gateCount) + PER_CASE_EXTRA);
}

/**
 * How many of `n` cases a check simulation can run under `cap`. 0 means not even one case fits, so the
 * check cannot be simulated through a capped RPC at all.
 */
export function simCases(c, n, gateCount, cap = SIM_GAS_CAP) {
  const room = cap - CHECK_OVERHEAD - NETLIST_GAS_PER_GATE * BigInt(gateCount);
  if (room <= 0n) return 0;
  const fit = room / (perCaseHold(c, gateCount) + PER_CASE_EXTRA);
  return Number(fit < BigInt(n) ? fit : BigInt(n));
}

/** The largest gate count whose single-case check still fits a simulation under `cap`. */
export function maxSimGates(c, cap = SIM_GAS_CAP) {
  let lo = 0n;
  let hi = 10_000_000n;
  if (checkGasRaw(c, 1, 0) > cap) return -1n;
  while (lo < hi) {
    const mid = (lo + hi + 1n) / 2n;
    if (checkGasRaw(c, 1, mid) <= cap) lo = mid;
    else hi = mid - 1n;
  }
  return lo;
}

/** The most cases one check transaction can run under the cap. */
export function maxCasesPerCheck(c, gateCount) {
  const room = TX_GAS_CAP - CHECK_OVERHEAD - NETLIST_GAS_PER_GATE * BigInt(gateCount);
  const per = perCaseHold(c, gateCount) + PER_CASE_EXTRA;
  return room > 0n ? room / per : 0n;
}

/**
 * Parse a decimal amount typed by a person into token base units.
 * Returns { value } or { error } with error one of: "empty", "comma", "format", "decimals", "zero", "tooBig".
 */
export function parseAmount(text, decimals, max = (1n << 96n) - 1n) {
  const s = String(text ?? "").trim();
  if (s === "") return { error: "empty" };
  // A comma is never a thousands separator here and never a decimal mark: "1,5" must not become 15.
  // Covers the ASCII comma, the full-width comma (U+FF0C) and the Arabic decimal separator (U+066B).
  if (/[,\uFF0C\u066B]/.test(s)) return { error: "comma" };
  if (!/^\d*(\.\d*)?$/.test(s) || s === ".") return { error: "format" };
  const [whole, frac = ""] = s.split(".");
  if (frac.length > decimals) return { error: "decimals" };
  const value = BigInt(whole || "0") * 10n ** BigInt(decimals) + BigInt((frac + "0".repeat(decimals)).slice(0, decimals) || "0");
  if (value === 0n) return { error: "zero" };
  if (value > max) return { error: "tooBig" };
  return { value };
}

/** Base units back to a plain decimal string, trailing zeros trimmed. */
export function formatUnitsPlain(value, decimals) {
  const neg = value < 0n;
  let v = neg ? -value : value;
  const base = 10n ** BigInt(decimals);
  const whole = v / base;
  let frac = (v % base).toString().padStart(decimals, "0").replace(/0+$/, "");
  return (neg ? "-" : "") + whole.toString() + (frac ? "." + frac : "");
}

/** Refund rule from LatheOrders.refund. status: 0 Open, 1 Checking. Times in unix seconds (BigInt). */
export function refundOpensAt(status, deadline, grace) {
  if (status === 0) return deadline + 1n; // t > deadline
  if (status === 1) return deadline + grace + 1n; // t > deadline + GRACE
  return null;
}

/** What the builder receives: the contract's fee is amount * feeBps / 10000, rounded down (LatheOrders._pay). */
export function payoutAfterFee(amount, feeBps) {
  return amount - (amount * BigInt(feeBps)) / 10_000n;
}

/** The fee rate as a plain percent string: 100 bps -> "1", 25 -> "0.25", 250 -> "2.5". */
export function feePercent(feeBps) {
  return formatUnitsPlain(BigInt(feeBps), 2);
}

// run / runStep (a free eth_call on a paid order): the contract re-checks the circuit (reads and hashes the
// netlist), then needs the full per-case hold free before the circuit runs, or it reverts InsufficientGasForCase.
// LatheOrders hands run / runStep to its linked library LatheReads, and that call passes on only 63/64 of the gas
// (EIP-150), so the total is scaled by 64/63. test/LatheOrders.libs.t.sol checks these figures against the contract.
export const RUN_OVERHEAD = 300_000n;

const hop = (g) => (g * 64n + 62n) / 63n;

/** Gas to ask for when calling run / runStep on a circuit of `gateCount` gates. */
export function runGasLimit(c, gateCount) {
  return hop(RUN_OVERHEAD + NETLIST_GAS_PER_GATE * BigInt(gateCount) + perCaseHold(c, gateCount));
}

/**
 * Gas to ask for when calling run on a paid pieced order. run checks and runs every piece in turn (piece 0, then
 * piece 1 on its answer), and each piece's eval needs its own full hold free, so every piece's netlist read and
 * hold are added. `gateCounts` holds each piece's recorded gate count.
 */
export function runPiecedGasLimit(c, gateCounts) {
  let g = RUN_OVERHEAD;
  for (const n of gateCounts) g += NETLIST_GAS_PER_GATE * BigInt(n) + perCaseHold(c, n);
  return hop(g);
}

/**
 * True when a run call fits under the public node's eth_call cap. When it does not, the page does not call:
 * the node would cut the gas and the contract would refuse (InsufficientGasForCase), so there is no answer to show.
 */
export function runFitsSim(c, gateCount, cap = SIM_GAS_CAP) {
  return runGasLimit(c, gateCount) <= cap;
}

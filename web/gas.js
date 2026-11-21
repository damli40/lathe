// Gas and amount helpers. Pure functions only, BigInt throughout. Tested by web/test/gas.test.mjs.
// The constants (base, perGate, reserve, inlineMax, maxCaseGas) are read from the deployed contract
// at run time and passed in; nothing here hard-codes them.

/** LatheOrders.evalBudget: the formula for the gas each case's eval gets. */
export function evalBudget(c, gateCount) {
  return c.base + c.perGate * BigInt(gateCount);
}

/**
 * The gas each case really gets: the delivery's stored per-case gas (caseGasOf / pieceCaseGasOf, or the figure
 * about to be declared) when there is one, else the formula. A contract from before the getters has none.
 */
export function caseBudget(c, gateCount, caseGas) {
  return caseGas && caseGas > 0n ? caseGas : evalBudget(c, gateCount);
}

/** True when deliver checks every case in the same transaction (LatheOrders._checkInlineIfSmall). */
export function checksInline(c, cases, gateCount, caseGas) {
  return BigInt(cases) * caseBudget(c, gateCount, caseGas) <= c.inlineMax;
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
export function perCaseHold(c, gateCount, caseGas) {
  const b = caseBudget(c, gateCount, caseGas);
  return (b * 64n + 62n) / 63n + c.reserve;
}

/**
 * Explicit gas limit for deliver. Worst case: every case burns its whole budget, and the last case still
 * needs its full hold free. Unused gas is not charged, so a high limit costs nothing extra.
 * Returns { gas, inline, capped }.
 */
export function deliverGasLimit(c, cases, gateCount, caseGas) {
  const inline = checksInline(c, cases, gateCount, caseGas);
  let gas = DELIVER_OVERHEAD + NETLIST_GAS_PER_GATE * BigInt(gateCount);
  if (inline) gas += BigInt(cases) * (perCaseHold(c, gateCount, caseGas) + PER_CASE_EXTRA);
  const capped = gas > TX_GAS_CAP;
  return { gas: capped ? TX_GAS_CAP : gas, inline, capped };
}

/** Explicit gas limit for check(orderId, n). */
export function checkGasLimit(c, n, gateCount, caseGas) {
  const gas =
    CHECK_OVERHEAD + NETLIST_GAS_PER_GATE * BigInt(gateCount) + BigInt(n) * (perCaseHold(c, gateCount, caseGas) + PER_CASE_EXTRA);
  return gas > TX_GAS_CAP ? TX_GAS_CAP : gas;
}

// Both public X Layer RPCs cap eth_call at 50,000,000 gas, whatever the call asks for (measured 2026-11-21:
// 49,947,900 gas left inside the call). A simulation asked to run with more gas silently gets 50M, so the
// contract's per-case gasleft() test fails inside it. Simulations stay under this cap, with room to spare.
export const SIM_GAS_CAP = 48_000_000n;

/**
 * Second try for a case that did not finish under SIM_GAS_CAP: enough for MAX_CASE_GAS through TapeOut's 63/64 plus
 * the call's own cost. A public node cuts this to 50M too, so the case stays "could not test" there; a node without
 * the cap (a local anvil, your own node) answers, which is how a case too big even for MAX_CASE_GAS is found.
 */
export function simRetryCap(c) {
  return (c.maxCaseGas * 64n) / 63n + 1_000_000n;
}

/** Gas check(orderId, n) needs, before the transaction cap is applied. */
function checkGasRaw(c, n, gateCount, caseGas) {
  return CHECK_OVERHEAD + NETLIST_GAS_PER_GATE * BigInt(gateCount) + BigInt(n) * (perCaseHold(c, gateCount, caseGas) + PER_CASE_EXTRA);
}

/**
 * How many of `n` cases a check simulation can run under `cap`. 0 means not even one case fits, so the
 * check cannot be simulated through a capped RPC at all.
 */
export function simCases(c, n, gateCount, cap = SIM_GAS_CAP, caseGas) {
  const room = cap - CHECK_OVERHEAD - NETLIST_GAS_PER_GATE * BigInt(gateCount);
  if (room <= 0n) return 0;
  const fit = room / (perCaseHold(c, gateCount, caseGas) + PER_CASE_EXTRA);
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
export function maxCasesPerCheck(c, gateCount, caseGas) {
  const room = TX_GAS_CAP - CHECK_OVERHEAD - NETLIST_GAS_PER_GATE * BigInt(gateCount);
  const per = perCaseHold(c, gateCount, caseGas) + PER_CASE_EXTRA;
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

/**
 * Refund rule for a pieced order (LatheOrders.refund with pieces): only while Open (pieced orders never use
 * Checking), when t > deadline and either some piece has no delivery or t > deadline + GRACE.
 * `allDelivered`: every piece has a delivery now (being checked or passed). Times in unix seconds (BigInt).
 */
export function refundOpensAtPieced(status, deadline, grace, allDelivered) {
  if (status !== 0) return null;
  return allDelivered ? deadline + grace + 1n : deadline + 1n;
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

/** Gas to ask for when calling run / runStep on a circuit of `gateCount` gates (`caseGas`: its stored per-case gas). */
export function runGasLimit(c, gateCount, caseGas) {
  return hop(RUN_OVERHEAD + NETLIST_GAS_PER_GATE * BigInt(gateCount) + perCaseHold(c, gateCount, caseGas));
}

/**
 * Gas to ask for when calling run on a paid pieced order. run checks and runs every piece in turn (piece 0, then
 * piece 1 on its answer), and each piece's eval needs its own full hold free, so every piece's netlist read and
 * hold are added. `gateCounts` holds each piece's recorded gate count.
 */
export function runPiecedGasLimit(c, gateCounts, caseGases = []) {
  let g = RUN_OVERHEAD;
  gateCounts.forEach((n, k) => (g += NETLIST_GAS_PER_GATE * BigInt(n) + perCaseHold(c, n, caseGases[k])));
  return hop(g);
}

/**
 * Gas to ask for when calling run on a paid order that has a top circuit. run checks every piece's circuit is
 * unchanged (reads each piece's netlist) and the top's (one REF record per piece, 31 + 3 x the piece's inputs bytes),
 * then makes one eval of the top with the top's budget: evalBudget(top gates) + perRef x pieces (the contract's
 * EVAL_GAS_PER_REF; 0 on a contract from before it, which gave the top evalBudget alone). The top's gate count
 * already includes every piece's gates, so the pieces get no hold of their own. `pieces` holds each piece's
 * recorded gate count and input count: [{ gates, nIn, caseGas }] (caseGas: the piece's stored per-case gas, if any;
 * what it adds above the piece's formula is added to the top's budget, as the contract does).
 */
export function runTopGasLimit(c, pieces, topGates) {
  let g = RUN_OVERHEAD;
  let topBytes = 0n;
  for (const p of pieces) {
    g += NETLIST_GAS_PER_GATE * BigInt(p.gates);
    topBytes += 31n + 3n * BigInt(p.nIn);
  }
  g += NETLIST_GAS_PER_GATE * ((topBytes + 6n) / 7n); // a NAND record is 7 bytes: one gate's worth of netlist
  const extra = pieces.reduce((s, p) => s + (caseBudget(c, p.gates, p.caseGas) - evalBudget(c, p.gates)), 0n);
  g += topHold(c, pieces.length, topGates, extra);
  return hop(g);
}

/**
 * Gas the top's one eval must have free: its budget * 64/63 + reserve (LatheReads.run). The budget is
 * evalBudget(top gates) + perRef x pieces + `extra`, what the pieces' declared per-case gas added above their formula.
 */
export function topHold(c, nPieces, topGates, extra = 0n) {
  const b = evalBudget(c, topGates) + (c.perRef ?? 0n) * BigInt(nPieces) + extra;
  return (b * 64n + 62n) / 63n + c.reserve;
}

/**
 * True when a run call fits under the public node's eth_call cap. When it does not, the page does not call:
 * the node would cut the gas and the contract would refuse (InsufficientGasForCase), so there is no answer to show.
 */
export function runFitsSim(c, gateCount, cap = SIM_GAS_CAP, caseGas) {
  return runGasLimit(c, gateCount, caseGas) <= cap;
}

// ---- testing every case before a delivery, and the per-case gas to declare ----

// Margin on top of the costliest case, as a percent. TapeOut's proxy passes on 63/64 of the gas it gets, so the
// figure is also scaled by 64/63 (the measured figure may already include it; the extra 1.6% is kept as room).
export const CASE_GAS_MARGIN_PCT = 10n;
export const CASE_GAS_ROUND = 10_000n;

/** Intrinsic gas of a plain call with this calldata (21,000 + 16 per non-zero byte + 4 per zero byte). */
export function intrinsicGas(dataHex) {
  const h = dataHex.startsWith("0x") ? dataHex.slice(2) : dataHex;
  let g = 21_000n;
  for (let i = 0; i < h.length; i += 2) g += h.slice(i, i + 2) === "00" ? 4n : 16n;
  return g;
}

/**
 * What one case's circuit call needs, from eth_estimateGas on a call straight to the processor (its own fresh
 * transaction, so everything it touches is cold): the estimate minus the transaction's intrinsic gas. That is the
 * gas the circuit must be handed, as LatheOrders hands it: eval{gas: budget}.
 */
export function needFromEstimate(estimate, dataHex) {
  const n = BigInt(estimate) - intrinsicGas(dataHex);
  return n > 0n ? n : 0n;
}

/** The per-case gas to declare for a costliest case that needs `worst`: worst x 64/63, + 10%, rounded up to 10,000. */
export function proposeCaseGas(worst) {
  const g = (BigInt(worst) * 64n * (100n + CASE_GAS_MARGIN_PCT) + 63n * 100n - 1n) / (63n * 100n);
  return ((g + CASE_GAS_ROUND - 1n) / CASE_GAS_ROUND) * CASE_GAS_ROUND;
}

/**
 * Decide a delivery from every case's measured need. `needs[i]` is case i's need (BigInt), or null when the case
 * could not be tested (it did not finish under the public node's eth_call cap, or it failed). An untested case
 * never counts as fitting.
 * Returns { kind, formula, worst, worstCase, proposed, untested }:
 *   "formula"  every tested case fits the formula budget with the margin: deliver as before (no declared gas);
 *   "declare"  some case needs more: deliver with `proposed` as the per-case gas;
 *   "tooBig"   even MAX_CASE_GAS would not be enough: do not deliver;
 *   "untested" no tested case needs more than the formula, but some case could not be tested: deliver with the
 *              formula, and say plainly that nothing is known about those cases (never that they fit).
 * `untested` lists the cases with no measurement; when it is not empty the page says so and claims nothing for them.
 */
export function planCaseGas(c, gateCount, needs) {
  const formula = evalBudget(c, gateCount);
  let worst = 0n;
  let worstCase = -1;
  const untested = [];
  needs.forEach((n, i) => {
    if (n === null || n === undefined) untested.push(i);
    else if (n > worst) {
      worst = n;
      worstCase = i;
    }
  });
  const proposed = worstCase < 0 ? 0n : proposeCaseGas(worst);
  let kind = proposed <= formula ? "formula" : "declare";
  if (proposed > c.maxCaseGas) kind = "tooBig";
  if (kind === "formula" && untested.length) kind = "untested";
  return { kind, formula, worst, worstCase, proposed, untested };
}

/** Check transactions a full check needs at most, with this per-case gas (the most cases per transaction). */
export function checkTxCount(c, cases, gateCount, caseGas) {
  const per = maxCasesPerCheck(c, gateCount, caseGas);
  if (per <= 0n) return null;
  return Number((BigInt(cases) + per - 1n) / per);
}

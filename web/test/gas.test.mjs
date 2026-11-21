// Gas and amount helper tests. Constants are the values in src/LatheOrders.sol.
import { test } from "node:test";
import assert from "node:assert/strict";
import { evalBudget, checksInline, maxInlineGates, perCaseHold, deliverGasLimit, parseAmount, formatUnitsPlain, refundOpensAt, maxCasesPerCheck } from "../gas.js";

const C = { base: 100_000n, perGate: 15_000n, reserve: 20_000n, inlineMax: 30_000_000n, maxCaseGas: 100_000_000n };

test("evalBudget(4) = 160,000 (test/fork/XorFork.t.sol logs it)", () => {
  assert.equal(evalBudget(C, 4), 160_000n);
});

test("largest inline gate count per input count (evidence/2026-11-20-eval-gas-budget.md table)", () => {
  const want = { 1: 993n, 2: 493n, 3: 243n, 4: 118n, 5: 55n, 6: 24n };
  for (const [nIn, g] of Object.entries(want)) {
    const cases = 1 << Number(nIn);
    assert.equal(maxInlineGates(C, cases), g, `nIn ${nIn}`);
    assert.equal(checksInline(C, cases, Number(g)), true);
    assert.equal(checksInline(C, cases, Number(g) + 1), false);
  }
});

test("per-case hold covers budget*64/63 + reserve", () => {
  assert.ok(perCaseHold(C, 4) >= (160_000n * 64n) / 63n + 20_000n);
});

test("deliver gas limit for 2-input XOR is above what the smoke run needed and far below the cap", () => {
  const { gas, inline, capped } = deliverGasLimit(C, 4, 4);
  assert.equal(inline, true);
  assert.equal(capped, false);
  assert.ok(gas > 1_000_000n && gas < 3_000_000n, String(gas));
  const big = deliverGasLimit(C, 64, 24);
  assert.ok(big.gas > 64n * perCaseHold(C, 24));
  assert.ok(big.gas < 210_000_000n);
  assert.equal(deliverGasLimit(C, 64, 25).inline, false);
});

test("a 6,660-gate circuit fits one case per check", () => {
  assert.equal(maxCasesPerCheck(C, 6600), 1n);
});

test("parseAmount", () => {
  assert.deepEqual(parseAmount("1", 6), { value: 1_000_000n });
  assert.deepEqual(parseAmount("1.5", 6), { value: 1_500_000n });
  assert.deepEqual(parseAmount("0.000001", 6), { value: 1n });
  assert.deepEqual(parseAmount("0.0000001", 6), { error: "decimals" });
  assert.deepEqual(parseAmount("", 6), { error: "empty" });
  assert.deepEqual(parseAmount("abc", 6), { error: "format" });
  assert.deepEqual(parseAmount("0", 6), { error: "zero" });
  assert.deepEqual(parseAmount("1e5", 6), { error: "format" });
  assert.deepEqual(parseAmount("100000000000000000000000", 6), { error: "tooBig" });
  assert.equal(formatUnitsPlain(1_500_000n, 6), "1.5");
  assert.equal(formatUnitsPlain(1_000_000n, 6), "1");
});

test("refund opens after the deadline when Open, after deadline + grace when Checking (LatheOrders.refund)", () => {
  assert.equal(refundOpensAt(0, 1000n, 86400n), 1001n);
  assert.equal(refundOpensAt(1, 1000n, 86400n), 87401n);
  assert.equal(refundOpensAt(2, 1000n, 86400n), null);
});

// ---- fix round: amounts with commas (B4), clipped simulations under the 50M eth_call cap (B1), fee (S1)
import { simCases, maxSimGates, checkGasLimit, SIM_GAS_CAP, payoutAfterFee, feePercent } from "../gas.js";

test("parseAmount refuses every comma instead of deleting it (B4: '1,5' was read as 15)", () => {
  for (const s of ["1,5", "0,5", "1,000.50", "1,,0", ",5", "5,", "1，5", "1٫5", " 1,5 "]) {
    assert.deepEqual(parseAmount(s, 6), { error: "comma" }, JSON.stringify(s));
  }
  // what still works and what still fails as before
  assert.deepEqual(parseAmount(" 2 ", 6), { value: 2_000_000n });
  assert.deepEqual(parseAmount("1.", 6), { value: 1_000_000n });
  assert.deepEqual(parseAmount(".5", 6), { value: 500_000n });
  assert.deepEqual(parseAmount("1 000", 6), { error: "format" });
  assert.deepEqual(parseAmount("１００", 6), { error: "format" }); // full-width digits
  assert.deepEqual(parseAmount("٣", 6), { error: "format" }); // Arabic-Indic digit
  assert.deepEqual(parseAmount("-1", 6), { error: "format" });
});

test("a 4,000-gate check cannot be simulated at all under the 48M cap (one case holds ~61M)", () => {
  assert.equal(simCases(C, 3, 4000), 0);
  assert.ok(perCaseHold(C, 4000) > SIM_GAS_CAP);
});

test("simCases clips n so the simulated gas stays under the cap, and one more case would not fit", () => {
  for (const g of [0, 4, 24, 25, 100, 500, 1000, 2000, 2995]) {
    for (const n of [1, 2, 7, 64]) {
      const k = simCases(C, n, g);
      assert.ok(k <= n, `g=${g} n=${n} k=${k} <= n`);
      if (k > 0) assert.ok(checkGasLimit(C, k, g) <= SIM_GAS_CAP, `g=${g} n=${n}: gas(k=${k}) <= cap`);
      if (k < n) assert.ok(checkGasLimit(C, k + 1, g) > SIM_GAS_CAP, `g=${g} n=${n}: gas(k+1) > cap`);
    }
  }
  // 25 gates (first batched size at 6 inputs): all 64 cases need ~34.5M, so the simulation runs them all
  assert.equal(simCases(C, 64, 25), 64);
});

test("maxSimGates is the exact boundary: one case fits at it and not one gate above", () => {
  const g = maxSimGates(C);
  assert.equal(g, 2995n);
  assert.equal(simCases(C, 1, Number(g)), 1);
  assert.equal(simCases(C, 1, Number(g) + 1), 0);
});

test("deliver never asks a simulation for more than the cap: every inline size, and non-inline up to 6,660 gates", () => {
  let worst = 0n;
  for (let nIn = 1; nIn <= 6; nIn++) {
    const cases = 1 << nIn;
    for (let g = 0; g <= 6660; g++) {
      const { gas, capped } = deliverGasLimit(C, cases, g);
      assert.equal(capped, false);
      if (gas > worst) worst = gas;
      if (gas > SIM_GAS_CAP) assert.fail(`nIn=${nIn} g=${g} deliver gas ${gas} > cap`);
    }
  }
  assert.ok(worst < 40_000_000n, `worst deliver gas ${worst}`);
});

test("payout after fee matches LatheOrders._pay (fee rounds down) and the percent reads plainly", () => {
  assert.equal(payoutAfterFee(1_000_000n, 100), 990_000n);
  assert.equal(payoutAfterFee(1n, 100), 1n); // fee 0.01 rounds down to 0
  assert.equal(payoutAfterFee(150n, 100), 149n); // fee 1.5 -> 1
  assert.equal(payoutAfterFee(1_000_000n, 0), 1_000_000n);
  assert.equal(payoutAfterFee(1_000_000n, 500), 950_000n);
  assert.equal(feePercent(100), "1");
  assert.equal(feePercent(25), "0.25");
  assert.equal(feePercent(250), "2.5");
  assert.equal(feePercent(500), "5");
});

import { runGasLimit, runFitsSim, perCaseHold as hold2, RUN_OVERHEAD, SIM_GAS_CAP as CAP2 } from "../gas.js";

test("run gas: overhead + netlist + one case's hold; big circuits do not fit the 48M test-call cap", () => {
  const c = { base: 100_000n, perGate: 15_000n, reserve: 20_000n };
  assert.equal(runGasLimit(c, 4), RUN_OVERHEAD + 600n * 4n + hold2(c, 4));
  assert.ok(runFitsSim(c, 4));
  assert.ok(runFitsSim(c, 652)); // the 8x8 multiplier
  assert.ok(!runFitsSim(c, 4000)); // budget 60.1M is above the cap
  assert.ok(runGasLimit(c, 3000) <= CAP2 === runFitsSim(c, 3000));
});

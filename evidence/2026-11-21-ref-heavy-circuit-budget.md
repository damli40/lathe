# Honest REF-heavy circuits and the per-case budget - 2026-11-21

## What this decides

Each case of a delivered circuit (a V0 to V2 order, or a piece) gets `100,000 + 15,000 × gates` gas, and running out of it counts as a wrong answer. A REF record (a link to another circuit) costs about 31,000 gas plus about 2,300 per gate of the circuit it links to, but adds only that circuit's gates to the count. So an honest circuit made mostly of links to very small circuits can be refused. This was true before V3b and V4; this file measures where the line is. The budget formula was **not** changed.

**The line, measured:**

| Circuit made only of REFs in a row to | Largest number of REFs that passes | First refused |
|---|---|---|
| a 1-gate circuit (NAND) | **4** | 5 |
| a 2-gate circuit (AND) | **13** | 14 |
| a 3-gate circuit (OR) | no line up to 24 (all passed) | - |
| a 4-gate circuit (XOR) | no line up to 24 (all passed) | - |
| a 1-gate circuit that is itself one REF to NAND | **1** | 2 |
| a 1-gate circuit two REFs deep | **0** (even one REF is refused) | 1 |

In plain words: links to circuits of 3 gates or more are fine at any length measured (the budget gives 15,000 per gate, a link costs about 31,000 + 2,300 per gate, so from 3 gates the budget grows faster than the cost). Links to 1- or 2-gate circuits are limited to about 4 and 13. Links to circuits that are themselves links are the worst: each extra level costs about 31,000 more and adds no gates.

What a refusal does: no money moves. A delivery checked inside `deliver` / `deliverPiece` reverts (`WrongAnswer(case)`) and the order stays open; a delivery checked in batches is cleared (`Rejected` / `PieceRejected`) and the order or piece opens again. The builder can deliver the same logic again built from plain gates, or from fewer links to bigger circuits, before the deadline.

## Numbers (measured)

X Layer mainnet fork pinned at block 76,480,000; every circuit minted on the fork with `tapeout`, nothing sent to X Layer. "Eval" is one cold eval measured inside a helper contract (cold: see [2026-11-21-top-run-gas.md](2026-11-21-top-run-gas.md) for the cross-check against `eth_estimateGas`), "warm" the same eval repeated. "Verdict" is a real 2-input, 1-output V0 order delivered with that circuit through `deliver` (4 cases checked inline, with the contract's guard); the table comes from the part's rule, not from `eval`.

Command: `forge test --match-path 'test/fork/RefGas.fork.t.sol' -vv` (tests `test_fork_refChain_nand`, `_and`, `_or`, `_xor`, `_nested1`, `_nested2`).

REFs to NAND (`0xb04e…93ff` id 3, 1 gate):

| REFs | Gates | Budget | Eval (cold) | Warm | Verdict |
|---|---|---|---|---|---|
| 1 | 1 | 115,000 | 69,833 | 43,404 | passes |
| 2 | 2 | 130,000 | 103,369 | 76,940 | passes |
| 3 | 3 | 145,000 | 136,513 | 110,084 | passes |
| 4 | 4 | 160,000 | 170,052 | 143,623 | passes |
| 5 | 5 | 175,000 | 203,198 | 176,769 | refused |
| 8 | 8 | 220,000 | 303,511 | 277,082 | refused |
| 24 | 24 | 460,000 | 837,401 | 810,972 | refused |

k = 4 passes although its cold eval (170,052) is above its budget, most likely because inside `deliver` the circuit's own netlist was already read (for its hash) before case 0, so case 0 is partly warm. The verdict column is what the contract decides; the eval column is the cost a fresh caller sees.

REFs to AND (id 1, 2 gates): 12 REFs (budget 460,000) cost 467,801 cold and pass; 13 (490,000) cost 503,808 and pass; 14 (520,000) cost 539,737 and are refused; 16 and 24 are refused.

REFs to OR (id 2, 3 gates): 24 REFs, budget 1,180,000, cost 952,961; all of 1 to 24 pass.

REFs to XOR (`0x839b…574e` id 1, 4 gates): 24 REFs, budget 1,540,000, cost 1,000,797; all of 1 to 24 pass.

Nested: N1 = one REF to NAND (1 gate). 1 REF to N1: budget 115,000, cost 109,517, passes; 2: 130,000 vs 174,082, refused. N2 = one REF to N1 (1 gate): 1 REF to N2: 115,000 vs 149,201, refused.

## The crank

`scripts/crank.mjs` only pushes the check forward; it gives each case the same budget. A REF-heavy piece over the line is rejected at its first case (`Rejected`, exit 2), the same as any wrong circuit. Nothing in the crank changes.

## Proposed contract change (not made)

Smallest change that removes the limit: **let the builder state the gas each case gets, at delivery.** New overloads `deliver(orderId, processor, circuitId, caseGas)` and `deliverPiece(orderId, pieceIndex, processor, circuitId, caseGas)`; the delivery records `max(evalBudget(gates), caseGas)` (still at most `MAX_CASE_GAS`, else `CircuitTooBigToCheck`) and every case check and `run` uses that recorded figure instead of `evalBudget(gates)`. The builder knows what their circuit costs (they can run `eval` with a capped gas limit first, which the page already suggests), and a higher figure only makes the check cost more to whoever runs it; it cannot make a wrong circuit pass or hold the order longer than today. It covers nested REFs at any depth, which no formula on the gate count can.

Size, measured on a prototype in a scratch copy of this commit's `src/` (compiled only, not tested): `LatheOrders` 22,555 → 22,957 bytes (**+402**), `LatheReads` 7,959 → 7,911 (−48). It adds a `uint64 caseGas` field to `Delivery`, which changes the outputs of the `deliveries` and `pieceOf` getters (one more value); the existing function signatures stay. A separate mapping instead of the field would keep the getters but cost more bytes (not measured).

Zero-byte alternative, weaker: raise `EVAL_GAS_PER_GATE` from 15,000 to about 40,000. That covers links to 1-gate circuits (33,400 each) but not nested links, and it raises every circuit's budget 2.7×: the largest checkable circuit drops from about 6,660 to about 2,500 gates and big pieces need about 2.7× as many crank transactions (the 16-input piece of [2026-11-21-gas-16-input-piece.md](2026-11-21-gas-16-input-piece.md): from about 3,450 to about 9,300).

## Limits

- Only chains of REFs to one live part were measured, at one fork block. A circuit mixing plain gates and REFs sits between the two cases: each plain gate brings 15,000 of budget for about 2,300 of cost, which pays for links elsewhere in the same circuit.
- The verdict depends a little on what is already warm in the delivering transaction (see k = 4 above). Batched checks (`check`, `checkPiece`) re-read the netlist first too, so they see the same partly warm first case.
- A change to the processor code behind TapeOut's beacon could change every figure here.

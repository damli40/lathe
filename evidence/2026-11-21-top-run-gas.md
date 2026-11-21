# Run gas for a top circuit - 2026-11-21

## What this decides

`run` on an order paid with a top circuit (one circuit made only of REF records, one per tested piece) used to give that circuit `100,000 + 15,000 × gates`, the same budget a plain circuit gets for one case. On real TapeOut a REF record costs about 33,000 to 40,000 gas on its own, so for a top of small pieces that budget was far too low and `run` refused every input. It was never a wrong answer and payment was not affected, but the free "try the rule" call did not work for those orders.

The budget for a top is now:

**budget = 100,000 + 15,000 × top gates + 150,000 × pieces** (`EVAL_GAS_PER_REF = 150,000`, in `src/LatheConstants.sol`, public on `LatheOrders`).

Why 150,000 per piece: 100,000 is the base each piece already had in its own case check (each piece was checked with `100,000 + 15,000 × its gates`, and the top's gate count is the sum of its pieces' gates), so the top gets at least what all its pieces were allowed together. The other 50,000 is the REF record itself, about 1.5 × the 33,400 measured per REF to a 1-gate part. Only `run` uses this budget. Case checks do not.

With this budget, the five review wirings W1 to W5 answer on every input. Before it, W1, W2 and W4 refused every input (measured, below).

## Numbers

All on an X Layer mainnet fork pinned at block 76,480,000. Every circuit and order was made on the local fork with the real `tapeout`; nothing was sent to X Layer.

### How "cold" was measured (measured)

The gas of one `eval` is measured inside a helper contract (`gasleft()` before and after), so it has no transaction overhead. In these forge runs, the first `eval` in each call from the test comes out cold (first touch of every account and storage slot): the same eval repeated inside one call costs 18,000 to 43,000 less. Cross-check against `eth_estimateGas` on an anvil fork at the same block, each estimate a fresh transaction (includes about 21,600 of transaction overhead):

| Circuit | forge, first eval | `cast estimate` (incl. ~21,600 tx overhead) | estimate − 21,600 |
|---|---|---|---|
| NAND `0xb04e…93ff` id 3 | 30,149 | 48,544 | ~26,900 |
| XOR `0x839b…574e` id 1 | 36,985 | 55,488 | ~33,900 |
| live REF-only XOR top `0xb04e…93ff` id 5 | 160,459 | 180,922 | ~159,300 |

The forge figures sit 1,200 to 3,300 above the estimate (the helper's own cold call into the processor), so they are a slightly high, safe reading of the cold cost. The review's figure for id 5 was 180,937; this run gave 180,922.

Commands:

```sh
forge test --match-path 'test/fork/RefGas.fork.t.sol' -vv
forge test --match-path 'test/fork/WiringTopFork.t.sol' -vv
anvil --fork-url https://rpc.xlayer.tech --fork-block-number 76480000 --port 8611 --silent
cast estimate --rpc-url http://127.0.0.1:8611 0xB04EB79D1A5EECaabAAfF7B77d7c27578EE693FF 'eval(uint256,bytes)' 5 0x01
```

`--isolate` gave the same figures as a plain run for these view calls, so it is not needed here.

### Parts on their own (measured, `test_fork_partsAlone`)

| Part | Gates | First eval (cold) | Same eval again (warm) |
|---|---|---|---|
| NAND id 3 | 1 | 30,149 | 12,220 |
| AND id 1 | 2 | 32,655 | 14,726 |
| OR id 2 | 3 | 34,896 | 16,967 |
| XOR (X) id 1 | 4 | 36,985 | 19,056 |
| live XOR top id 5 (REFs to OR, NAND, AND) | 6 | 160,459 | 117,030 |

### Gas per REF record (measured, `test_fork_refChain_*`)

A chain of k REFs in a row to a 2-input part is the same thing as a top made of k pieces that are that part. Per extra REF (the slope; cold and warm give the same slope, warm is about 26,400 lower in total):

| REF to | Gas per REF | One REF, cold, in a circuit of its own |
|---|---|---|
| NAND (1 gate) | ~33,400 | 69,833 |
| AND (2 gates) | ~35,900 | 72,604 |
| OR (3 gates) | ~38,200 | 74,845 |
| XOR (4 gates) | ~40,100 | 79,037 |
| N1 = a REF to NAND (1 gate, one REF deeper) | ~64,500 | 109,517 |
| N2 = a REF to N1 (1 gate, two REFs deeper) | ~95,600 | 149,201 |

So one REF record costs about 31,000 plus about 2,300 per gate of the part it calls, plus about 31,000 for every further REF level inside that part.

### The review wirings W1 to W5 (measured, `test/fork/WiringTopFork.t.sol`)

Five pieces with uneven pins on three processors (some made of REFs to the live AND, NAND and XOR, one made of a REF to a REF-made piece), each wiring ordered as "Lathe joins" and as "needs a top circuit", the top minted with `tapeout` from `expectedTopNetlist` and delivered. "Max eval" is the largest cold eval of the top over all inputs.

| Wiring | Pieces | Top gates | Old budget | New budget | Max eval | `run` refusals, old code | `run` refusals, new code |
|---|---|---|---|---|---|---|---|
| W1 | 3 | 15 | 325,000 | 775,000 | 412,402 | 16 of 16 | 0 of 16 |
| W2 | 4 | 17 | 355,000 | 955,000 | 528,815 | 8 of 8 | 0 of 8 |
| W3 | 1 | 8 | 220,000 | 370,000 | 204,179 | 0 of 4 | 0 of 4 |
| W4 (a nested-REF piece) | 6 | 32 | 580,000 | 1,480,000 | 876,621 | 32 of 32 | 0 of 32 |
| W5 (8 plain pieces) | 8 | 17 | 355,000 | 1,555,000 | 345,220 | 0 of 512 | 0 of 512 |

"Old code" is the same test run against the code at `7a5a2b6` (the review's commit). On every input of every wiring, `eval(top)` = `run(joined order)` = `run(topped order)` = an independent Solidity model of the wiring. The largest eval used 59% of its new budget (W4); W5 had only 3% to spare under the old budget.

## What the page asks for

The order page's "try the rule" gas for a top order is now `web/gas.js` `runTopGasLimit`: `(300,000 + 600 × every piece's gates + 600 × the top's netlist size in 7-byte steps + ⌈top budget × 64/63⌉ + 20,000) × 64/63`. The old figure gave a full hold to every piece and another to the top, whose gate count already includes the pieces: it over-stated. It also used the old budget, which under-stated what the top needs. `test/LatheOrders.review.t.sol` runs the contract at the page's figure (1,821,603 gas for 8 one-gate pieces, the same number `web/test/gas.test.mjs` pins), and a contract from before this fix (no `EVAL_GAS_PER_REF`) is read as 0, which is what it gave.

## Test doubles

`test/mocks/RefProcessor.sol` (the stand-in REF processor used by the unit tests, the smoke run and the page tests) now burns 40,000 gas per REF record, about the real cost above. Before, a REF there cost a few thousand gas and no test could see a too-small top budget. With the budget set back to the old one (`EVAL_GAS_PER_REF = 0`), checked on a local anvil: the new smoke step (n) (a top of 6 one-gate XOR pieces) stops with `Smoke (n)` and `web/test/pieces.mjs` (12) fails ("run via the 6-REF top ... The contract function run reverted"). The older smoke step (l) still passed, because its two pieces have 4 gates each.

## Limits

- **Nested REFs.** A piece that is itself made of REFs costs about 31,000 more per REF level inside it, and the contract cannot count those levels (it sees only the piece's gate count). The top's budget covers them through each piece's own budget: a piece only passes its case check if its own cold eval fits `100,000 + 15,000 × its gates`, and the top gets that much for every piece plus 50,000 per REF. W4 (one piece made of REFs to a REF-made piece) used 59% of its budget. This is reasoning backed by these five wirings, not a proof for every circuit. If a top ever does need more, the free `run` refuses (`InsufficientGasForCase` or out of gas), never gives a wrong answer; `ruleOf` still names the top, and an `eval` called directly on the processor with more gas still runs it.
- A top whose budget is too big for a free call (big pieces: about 3,000 gates in total and up, against the 48M the page keeps under the public node's 50M cap) cannot be run through the page; `run` refuses rather than answer with less, and `ruleOf` plus a direct `eval` work.
- Costs were measured on one fork block. A change to the processor code behind TapeOut's beacon could change them.

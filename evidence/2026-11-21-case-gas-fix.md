# Builder-declared per-case gas: the split-check fix - 2026-11-21

## What this decides

**The bug.** Each case of a delivered circuit gets a fixed gas budget, `100,000 + 15,000 × gates`, and a circuit that runs out of it inside its case counts as a wrong answer. The first case run in any transaction costs more than the others, because the circuits it calls are read for the first time in that transaction ("cold" in EIP-2929 terms: about 30,000 gas more for a circuit made of links). Anyone may call `check` and `checkPiece` and choose how many cases each call runs, so anyone chooses which case comes first in a transaction. For an honest circuit near its budget (in practice one made mostly of REF links to 1- to 4-gate circuits) the verdict therefore depended on where a transaction started: paid when checked in one transaction, rejected when a stranger first moved the cursor to an expensive case and then checked that case alone. The stranger pays only gas and can repeat it on every redelivery; the builder is never paid. Found by the final whole-repo review of HEAD `8522ba0`.

**The fix.** The builder states the gas each case gets when delivering: new overloads `deliver(orderId, processor, circuitId, uint32 caseGas)` and `deliverPiece(orderId, pieceIndex, processor, circuitId, uint32 caseGas)`. Each case then gets `max(evalBudget(gates), caseGas)`, at most `MAX_CASE_GAS` = 100,000,000 (`CaseGasTooHigh` above it). The figure is stored with the delivery and used for every check of it, the inline check, the inline-check threshold, `run`, `runStep` and the piece chain in `run`. The old three- and four-argument functions are `caseGas` 0, the formula, exactly as before.

**What a builder should declare:** the gas the costliest case needs when it runs alone in a fresh transaction, × 64/63, plus a margin. The 64/63 is because TapeOut's proxy passes on only 63/64 of the gas it is given (the reviewer measured a case that used 952,158 gas and needed 966,318 to succeed).

**What is still true:** a builder who declares too little is still rejected exactly as before, under the same split: the delivery is cleared, the order (or piece) opens again, no money moves, and the builder can deliver again with a new figure before the deadline.

## The reproduction (real TapeOut, X Layer mainnet fork, block 76,480,000)

`test/fork/CaseGasSplit.fork.t.sol`, ported from the reviewer's `ZGrief.fork.t.sol`. Circuit: 6 inputs, 1 output, 25 REFs in a chain (10 to the live 4-gate XOR `0x839b…574e` id 1, 13 to the live 1-gate NAND `0xB04E…93FF` id 3, 2 to the live 2-gate AND id 1): 57 reported gates, formula budget 955,000. The order's table is the circuit's own 64 answers, so it is right on every case.

| Test | Delivery | Checks (each its own transaction) | Result |
|---|---|---|---|
| `test_fork_formulaBudget_strangerSplitRejectsHonestCircuit` | three-argument `deliver` (955,000 per case) | order A: `check(A, 64)` | Paid |
| same | same | order B: `check(B, 7)` then `check(B, 1)` | **Rejected at case 7**, order Open, builder paid 0 |
| `test_fork_declaredCaseGas_everySplitPays` | `deliver(..., 1,080,000)` | `check(7)`, `check(1)`, `check(64)` | Paid (builder receives 9,900,000 of 10,000,000) |
| same | same, second order | 64 × `check(1)`: every case first in its own transaction | Paid, no case rejected |

Before the fix the reviewer's original test (scratch copy of `8522ba0`) passed with the same story: `order A ... Paid, builder received 9900000`, `order B ... Rejected at case 7; builder received 0`.

The same on a local anvil fork of mainnet (`anvil --fork-url https://rpc.xlayer.tech --fork-block-number 76480000`), with `script/LocalCaseGasFork.s.sol` (ported from the reviewer's `ZGriefAnvil.s.sol`) then `cast send` one transaction at a time, gas limit 80,000,000:

| Order | Delivery | `check(7)` | `check(1)` | `check(64)` |
|---|---|---|---|---|
| 1 | formula, 955,000 | gas used 6,521,242, status Checking | gas used 1,011,644, **status Open (rejected)** | not sent |
| 2 | declared, 1,080,000 (`caseGasOf(2)` = 1080000) | gas used 6,521,242, Checking | gas used 1,022,444, Checking | gas used 51,609,451, **Paid** |

## Unit tests (mocks)

`test/mocks/MockProcessor.sol` gained `setColdSlots(id, n)` (every call reads n storage slots nothing else touches: about 2,100 gas each on the first call of a transaction, 100 later) and `setCaseGasCost(id, c, gas)`. The fixture circuit (6-input parity, 25 gates, budget 475,000; 50 cold slots; burns 420,000, case 0 burns 280,000) measured: case 7 cold 558,007, case 7 warm 439,498, case 0 cold about 416,000. `test/LatheOrders.caseGas.t.sol`, 19 tests, all pass. What each conclusion of the review brief rests on:

| Conclusion | Test |
|---|---|
| The bug: formula budget, verdict depends on the split (one transaction pays, `check(7)` + `check(1)` rejects at 7) | `test_formulaBudget_verdictDependsOnSplit` |
| The fix: declared gas, splits 7, 1, 13, 2, 41 pay; every case first in its own transaction passes | `test_declared_everySplitPays`, `test_declared_eachCaseAloneInItsTransaction` |
| `caseGas` below the formula, or 0, is the formula; no delivery reads 0 | `test_caseGas_belowFormula_isFormula` |
| The cap: above 100M (and `type(uint32).max`) reverts `CaseGasTooHigh`; exactly 100M is accepted and one case of it fits a transaction (110M gas works; 100M gas reverts `InsufficientGasForCase` and changes nothing) | `test_caseGas_capBoundsATransaction`, `test_piece_caseGasTooHigh` |
| A huge `caseGas` cannot harm the buyer: the money stays locked, a refund in the grace period is refused as for any delivery being checked, and after it the buyer gets the full amount back | `test_hugeCaseGas_buyerRefundsAsBefore` |
| A huge `caseGas` cannot make a wrong circuit pass (batched and inline) | `test_hugeCaseGas_wrongCircuitStillRejected`, `test_declared_inline_wrongReverts_rightPays` |
| The inline threshold uses the per-case gas (4 × 7M inline, 4 × 7.6M batched) | `test_declared_inline_wrongReverts_rightPays` |
| A rejection clears the stored value; the redelivery chooses a new one and pays | `test_rejected_clearsCaseGas_redeliveryChoosesNew` |
| The changed-circuit check does not depend on it | `test_caseGas_circuitChangedStillRefused` |
| The receipt does not depend on it (same fingerprint and circuit with 600,000 and 1,200,000) | `test_caseGas_receiptUnchanged` |
| `deliveries(id)` still returns six words | `test_getters_shapeUnchanged` |
| `run` gives the declared gas (and refuses with gas for the formula only) | `test_run_usesDeclaredGas` |
| Memory orders (`step`): formula split rejects, declared pays, `runStep` uses the declared gas | `test_memory_formulaSplitRejects_declaredPays` |
| Pieces: formula split rejects and clears `pieceCaseGasOf`; declared pays | `test_piece_formulaSplitRejects_declaredPays` |
| A top's `run` budget covers its pieces' declared gas (a piece burning 780,000, above the top's formula 625,000: the top gets 625,000 + (900,000 − 475,000) = 1,050,000 and answers right; with gas for the old budget only, refused) | `test_top_runBudgetCoversPiecesDeclaredGas` |
| With nothing declared the top's run budget is unchanged | `test_top_noDeclared_budgetUnchanged` |

The top's run budget is `evalBudget(top gates) + 150,000 × pieces + Σ (piece caseGas − piece evalBudget)`. With nothing declared the sum is 0, so every earlier top figure holds. With declarations it is at least the sum of the pieces' per-case gas, because a REF-only top's gate count is the sum of its pieces' gates.

`test/LatheOrders.matrix.t.sol` (ported from the reviewer's `ZMatrix.t.sol`): 20 order states × 3 times × 11 calls = 660 cells (the reviewer's 9 calls plus the two new overloads). After every cell: tokens held = open amount + fees owed, and a stored per-case gas exists exactly when a delivery does and is never below the formula (a top stores none). Before the fix the reviewer's 540-cell version passed on `8522ba0`; after it the 660-cell version passes.

## Size

| Contract | Before (`8522ba0`) | After |
|---|---|---|
| `LatheOrders` | 22,555 | 23,095 (+540; limit 24,576, 1,481 left) |
| `LatheReads` | 7,959 | 8,078 (+119: the top's run budget adds the pieces' declared gas) |
| `LatheChecks` | 7,361 | 7,361 |
| `NetlistLib` | 3,269 | 3,269 |

Measured with `forge inspect <name> deployedBytecode` (byte length). `via_ir` stays off; no guard was cut. The value is a `uint32` (the narrowest that holds 100M) packed into the slot that already holds `builder` and `gateCount`, so a delivery still uses five storage slots. To keep the getters' shapes the two mappings became internal with hand-written `deliveries(id)` and `pieceOf(id, i)` returning the same six fields, plus `caseGasOf(id)` and `pieceCaseGasOf(id, i)`. This costs more bytes than the reviewer's prototype (+402, which changed the getters) and keeps every caller that decodes six values working.

## Crank and scripts

- `scripts/crank.mjs` reads `pieceCaseGasOf` and sizes batches from it (formula when the call fails, on an older contract). `scripts/test/crank-anvil.mjs` step 6: a piece delivered with 600,000 declared is planned at `budget 600000 gas per case (declared by the builder)`, every batch's gas limit holds k × 600,000 × 64/63 and stays under a 30M block, Paid; the same circuit with the formula is `Rejected` where the second batch starts (exit 2).
- `script/DeployTestnet.s.sol` sets up mock circuit 5 (the fixture above); `script/Smoke.s.sol` step (o) delivers it with 600,000 declared, checks it as 7 + 1 + 13 + 2 + 41 cases in five transactions, Paid; then simulates the formula delivery under `check(7)` + `check(1)`: rejected at case 7. Run on a local anvil (chain 1952): `ONCHAIN EXECUTION COMPLETE & SUCCESSFUL`; `cast call` afterwards read order 13 status 2 and `caseGasOf(13)` = 600000; the formula delivery of the same circuit sent by hand as order 14, then `check(14, 7)` and `check(14, 1)` as two transactions, left order 14 Open.

## Limits

- The figure is the builder's to get right. The contract cannot measure what a case costs cold; it only gives what was declared. Too little is a rejection (no money moves), too much costs checkers more gas per case and means fewer cases per transaction.
- Checked on mocks and on one real mainnet circuit at one fork block. A change to TapeOut's processor code could change every cost.
- The 64/63 and the cold extra were measured, not derived from TapeOut's source.
- Not deployed to testnet or mainnet with this change.

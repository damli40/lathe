# Per-case gas budget for `eval` - 2026-11-20

## What this decides

Each case of a delivered circuit now runs with a fixed amount of gas, worked out from the circuit's gate count:

**budget = 100,000 + 15,000 × gateCount** (`EVAL_BASE_GAS`, `EVAL_GAS_PER_GATE` in `src/LatheOrders.sol`).

Why: real TapeOut processors are beacon proxies (a small forwarding contract in front of the real code). The old guard tried to tell "the caller sent too little gas" apart from "the circuit itself failed" by looking at the gas left after the call. Through a proxy that guess never fired, so anyone could call `check` with about 400,000 gas and get an honest 652-gate circuit marked wrong (review proof, fork block 76,432,018). With a fixed budget, a case's result no longer depends on the caller's gas: either the caller provides enough for the whole budget, or the call reverts and nothing is recorded.

The cost of the choice: a circuit that needs more than its budget per case is rejected, the same way every time. A builder can check this before delivering by calling `evalBudget(gateCount)` and running `eval` with that much gas.

## Numbers (cold, one `eval` each, X Layer mainnet fork, block 76,432,018)

| Circuit | Gates (incl. REF'd) | One `eval` | Gas per gate | Budget | Budget ÷ cost |
|---|---|---|---|---|---|
| 8×8 multiplier, `0xbAF5…F969` id 16 (real gates only) | 652 | 1,508,716 | 2,313 | 9,880,000 | 6.5× |
| IDENT: one REF to that multiplier (the review's circuit) | 652 | 1,572,032 | 2,411 | 9,880,000 | 6.3× |
| XOR, `0x839b…574e` id 1 | 4 | 36,853 | 9,213 | 160,000 | 4.3× |
| XOR chain: 64 REFs in a row to XOR id 1 | 256 | 2,605,245 | 10,176 | 3,940,000 | **1.51×** |
| BOMB: 8 REFs to a 4-deep REF chain ending in XOR (logically correct) | 32 | 1,356,654 | 42,395 | 580,000 | 0.43× (rejected, as intended) |

What the numbers say:
- Real gates cost about 2,300-2,400 gas each, matching TAP-02's 2,317 measured on BNB Smart Chain. A 1.5× margin on that alone would be about 3,600 per gate.
- **REFs cost far more per gate.** Each REF to the 4-gate XOR costs about 40,000 gas (a call into the sub-circuit plus reading its netlist), about 10,000 per gate. A budget sized only on the multiplier (3,600 per gate) would reject an honest circuit built from small REF'd parts, such as adders made of XOR REFs. So the per-gate figure is set to 15,000: 1.5× the REF-to-XOR rate, the tightest honest case measured.
- The base of 100,000 covers the fixed cost of one call (proxy, netlist read, first-touch storage) with room: XOR alone is 36,853.
- Gate counts include gates reached through REF (TAP-02 §6), confirmed on the fork: IDENT reports 652, the XOR chain 256, the bomb 32.

Other constants:
- `GAS_RESERVE = 20,000`: before each case, `check` requires `gasleft() >= budget × 64/63 + 20,000`, so the call really receives the full budget (a call can pass on at most 63/64 of the gas left, EIP-150). Otherwise it reverts `InsufficientGasForCase`.
- `MAX_CASE_GAS = 100,000,000`: `deliver` refuses a circuit whose one-case budget is above this (`CircuitTooBigToCheck`), about 6,660 gates. A larger circuit could not be checked in one X Layer transaction (block gas limit 210,000,000, read with `cast block` on 2026-11-20) and would hold the order until deadline + grace.

## How it was measured

- Test: `test_fork_budgetMargin` and `test_fork_gasBombRejectedDeterministically` in `test/fork/EvalBudget.fork.t.sol`.
- Command: `forge test --match-path test/fork/EvalBudget.fork.t.sol --isolate -vv` (`--isolate` makes each top-level call its own transaction, so first-touch costs are included).
- The IDENT, XOR-chain and bomb circuits were minted on the fork with `tapeout` (REF-only netlists need no transistor tokens). Nothing was sent on chain.
- Gas figure: `gasleft()` before and after one `eval`, measured inside a helper contract.
- Compiler: solc 0.8.24, optimizer on, 200 runs.

## Limits

- Only these circuits were measured. A REF to a 1-gate circuit would cost roughly 35,000 per gate, above the 15,000 budget; a circuit made mostly of REFs to 1- or 2-gate parts, or of deep REF chains, will be rejected. That is deliberate (TAP-02 §7 says tools must bound REF depth), but builders need to know: the frontend should show `evalBudget(gateCount)` and run a capped `eval` before delivery.
- A cold first case costs about 27,000 more than a warm one (IDENT: 1,572,025 cold, 1,545,519 warm in the same transaction). The base absorbs it.
- If the processor implementation behind the beacon changes, these costs can change. `check` already refuses a circuit whose gate count or netlist changed, but not a changed implementation.

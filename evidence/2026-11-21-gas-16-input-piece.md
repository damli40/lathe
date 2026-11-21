# Gas per case for a 16-input piece (real 8×8 multiplier)

**Date:** 2026-11-21. **Fork block:** 76,432,018 (X Layer mainnet, chain 196). **Gas price and block gas limit read live:** block 76,476,223, 07:14 UTC.

## Plain summary

One case of a 16-input piece built like the real 8×8 multiplier (652 gates) costs about **1.5 million gas**. Lathe's own work per case is under 1% of that; the circuit is the cost.

So checking all 65,536 cases uses about **98 billion gas**, which is about **1.97 OKB** at today's gas price of 0.02 gwei. The price moves, so recompute before relying on it.

The number of transactions is set by the per-case gas budget, not by the real cost. Lathe must hand each case 9.88M gas (100,000 + 15,000 × 652), about 6.6 times what the multiplier really uses. A transaction may only start a case if that much gas is left. If the batch size is sized so that it can never run short (`scripts/crank.mjs` does this), a 200M-gas transaction fits **19 cases**. That makes **3,450 transactions**, each one reserving about 92% of a 210M block.

**What this decides:** a 16-input piece is affordable, but a 650-gate one means hours of cranking. A small comparator of about 70 gates (the two-of-three piece A) needs about **403 transactions** and about 0.22 OKB (an estimate from the per-gate figure, not measured). Use small formula circuits for 16- and 17-input pieces. The lever that would cut the transaction count is the per-gate budget, and it is not changed here (see "Not done").

## What was measured

`test/fork/PieceGas16.fork.t.sol`, run with:

```sh
forge test --match-path 'test/fork/PieceGas16.fork.t.sol' -vv
```

| Measurement | Gas |
|---|---|
| Real multiplier (processor `0xbAF5…F969` id 16, 16 in / 16 out / 652 gates) `eval`, warm, 8 inputs incl. `0x0000`, `0xffff`, `0x5a5a`: min / mean / max | 1,504,316 / 1,506,139 / 1,508,716 |
| `checkPiece` end to end, marginal gas per case ((30 cases − 10 cases) / 20) | 1,491,971 |
| `checkPiece`, 1 case, first call | 1,584,960 |
| Real multiplier `netlist(16)` read + keccak (4,564 bytes), read once per `checkPiece` call and once per piece at payout | 56,014 |

The test also confirms that the multiplier's input layout is the formula-piece layout: a = input byte 0, b = input byte 1, outputs = a × b, all LSB first.

**How the end-to-end figure was made.** No real 16-input `a >= b` circuit exists on chain. The test uses `MulCostPiece`, a stand-in GreaterOrEqual(8, 8) piece. Each case it calls the real multiplier with the same two input bytes, discards the product, and answers a >= b. It reports 652 gates, so Lathe gives it the real multiplier's budget. Lathe is deployed with a mock factory and mock token, because the real factory does not list the stand-in. The extra call layer makes the figure a little higher than a real 652-gate piece would be. The fixed cost per call (about 93,000 gas above one case, before the 21,000 intrinsic) was measured with a short stand-in netlist. A real piece also pays the ~56,000 netlist read.

## Projection for 65,536 cases (GreaterOrEqual(8, 8) on a 652-gate circuit)

| Item | Value |
|---|---|
| Gas used, all cases | 65,536 × ~1.49M ≈ 97.8B, plus ~0.17M fixed per transaction × 3,450 ≈ 0.6B → **~98B gas** |
| Gas price read (`cast gas-price --rpc-url https://rpc.xlayer.tech`) | 20,000,001 wei = 0.02 gwei |
| Cost of gas used | ~98B × 20,000,001 wei ≈ **1.97 OKB** (the price moves; OKB to dollars not checked here) |
| Block gas limit read (`cast block latest -f gasLimit`) | 210,000,000 |
| Safe batch at a 200M gas limit (crank maths, every case may burn its full 9.88M budget) | 19 cases, gas limit 192,149,174 → **3,450 transactions**, each using ~28M gas |
| Same at a 100M gas limit | 9 cases → 7,282 transactions |
| Balance needed up front per 192M-limit transaction | 192M × 0.02 gwei ≈ 0.0038 OKB (unused gas is not charged) |

Batch sizes come from `fitBatch` / `batchGasLimit` in `scripts/crank.mjs`. Per case they reserve ⌈budget × 64/63⌉ + 20,000 (`GAS_RESERVE`) + 30,000 slack. Per transaction they add 150,000 + the netlist read, and the payout on the last batch.

For comparison, a crank that sized batches from the measured 1.49M per case would fit about 125 cases in 200M (about 525 transactions). But a circuit that uses more of its budget than the multiplier does would then revert the transaction with `InsufficientGasForCase`. Nothing is lost when that happens (the contract records nothing), but the gas is wasted. That mode is not built.

## Limits

- Gas per case depends on the circuit. These numbers are for the 652-gate multiplier's eval cost. A real comparator has far fewer gates. The 70-gate figures (~0.17M per case, 403 transactions, ~0.22 OKB) are estimates from the ~2,320 gas per real gate in `evidence/2026-11-20-eval-gas-budget.md`, not a measurement.
- Measured on a fork, not in live transactions. Block inclusion was not tested: whether the sequencer accepts a steady stream of 192M-limit transactions, and how fast, is untested.
- The gas price and block gas limit were read once.

## Not done

- The per-gate budget (15,000) was not lowered. It covers REF-heavy circuits at ~10,000 gas per gate. Lowering it for plain circuits would need a way to tell the two apart at delivery, plus new measurements.

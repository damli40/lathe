# Gas per case for `check` on the real XOR circuit - 2026-11-20

## What this decides

Testing one more case of a delivered circuit costs about **21,600 gas** on the real 4-gate TapeOut XOR circuit. Every `check` call also pays a fixed cost of about **88,000 gas** (re-reading the circuit's shape and netlist to prove it has not changed, and loading the order). The final call that pays the builder adds about **76,000 gas** for the two token transfers.

So a full 64-case order on a small circuit costs roughly 88,000 + 64 × 21,600 + 76,000 ≈ **1.55M gas** in one call. That is under 1% of the 210M block limit, so V0 orders (at most 64 cases) fit in one transaction with a wide margin. The per-case cost grows with the circuit's gate count (the processor's `eval` does the work), so a bigger circuit costs more per case. This file measures only the 4-gate XOR; it does not measure a larger circuit.

## Numbers

| Call | Gas used by the call |
|---|---|
| `check(order, 1)`: first call, 1 case, no payout | 110,000 |
| `check(order, 3)`: first call, 3 cases, no payout | 153,179 |
| `check(order, 4)`: first call, all 4 cases + payout to builder and fee recipient | 251,206 |
| One more case (marginal) = (153,179 − 110,000) / 2 | **21,589** |
| Fixed cost per call ≈ 110,000 − 21,589 | ≈ 88,400 |
| Payout ≈ 251,206 − (110,000 + 3 × 21,589) | ≈ 76,400 |

`forge test --gas-report` over the fork suite (6 `check` calls, `--isolate`): `check` min 106,366 (rejected at case 0), median 162,091, max 251,206. `deliver` 170,020. `createOrder` 164,855–181,955. Contract size 9,244 bytes (limit 24,576).

## How it was measured

- Command: `forge test --match-path 'test/fork/*' --isolate -vv` (test `test_fork_gasPerCase` in `test/fork/XorFork.t.sol`), and the same with `--gas-report`.
- Fork: X Layer mainnet (chainId 196) via `https://rpc.xlayer.tech`, pinned at block **76,432,018** (read with `cast block-number` on 2026-11-20).
- Circuit: TapeOut XOR, processor `0x839bdD6fa7A66416A609A735e11DE5411B98574e`, id 1 (2 inputs, 1 output, 4 gates). Token: real USD₮0 `0x779Ded0c9e1022225f8E0630b35a9b54bE713736`, balance set with forge's `deal`. Factory: real `0x1f09DAeFA827f02CBb40967cc91b259763760761` (`isCPU` returned true).
- Gas figure: `vm.lastFrameGas().gasTotalUsed`, the gas used inside the `check` call frame. Each order was created and delivered before its check, in the same test.
- Compiler: solc 0.8.24, optimizer on, 200 runs.

## Limits

- The figures are the call's own gas. A real transaction also pays the 21,000 base cost and calldata (about 21,300 more), so add that to each row.
- Inside one Foundry test, contracts and storage touched earlier (the processor during `deliver`, the token during `createOrder`) stay "warm", so first-touch surcharges (up to 2,600 gas per account and 2,100 per storage slot) are partly missing. A real first `check` transaction may cost a few thousand gas more. `--isolate` did not change the numbers here.
- Only the 4-gate XOR was measured. Per-case gas on large circuits (the 652-gate multiplier) is Task 9's measurement, not this one.
- Local fork simulation, no transaction sent.

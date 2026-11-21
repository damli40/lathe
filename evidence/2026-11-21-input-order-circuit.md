# A real circuit that shows swapped inputs

**Plain summary.** The only real circuit Lathe had delivered was XOR, and XOR gives the same answer when its two
inputs are swapped, so it cannot show a mix-up of input order. A slow scan of X Layer mainnet found a 3-input
circuit that does: processor `0xCa6Fa40e0b548aBa9132F3f5050eE4C4c5eB7340`, circuit id 3. It is a switch:
output = x2 ? x1 : x0. A fork test delivers it against the right table (paid) and against the same table with x0
and x1 swapped (refused at case 1).

## The circuit

| Field | Value |
|---|---|
| Processor | `0xCa6Fa40e0b548aBa9132F3f5050eE4C4c5eB7340` (factory index `cpus(39)`) |
| Circuit id | 3 |
| Shape (`circuitInfo`) | 3 inputs, 1 output, 0 memory bits, 4 gates (at fork block 76,432,018 and at the scan's latest block) |
| Owner at block 76,432,018 | `0x983317279A43e19a9000950E1DB64ab1Ab4a959E` |
| `eval` for cases 0..7 | 0, 1, 0, 1, 0, 0, 1, 1 (output = x2 ? x1 : x0) |
| Table, LSB first | `0xca` |
| Same table with x0 and x1 swapped | `0xac`; first differs at case 1 (x0 = 1, x1 = 0, x2 = 0) |

## How it was found

2026-11-21. A node script read `cpus(k)` on the factory, then `circuitInfo(id)` for ids 1 to 3 of processors
k = 0 to 39, then `eval` on every input of combinational circuits with 2 to 6 inputs (at most three of each
shape). One request at a time with a 0.7 s pause, because `https://rpc.xlayer.tech` returns 403 under parallel
load. It stopped at the first circuit where swapping two inputs changes the table. It read 8 tables; the 7 before the switch were all symmetric: XOR (4 gates), NAND (3 gates, three
circuits), AND (2 gates), a half adder (2 in / 2 out, 5 gates) and a full adder (3 in / 2 out, 9 gates).

Limit: a sample, not a census. Only the first three ids of the first 40 processors were read.

## Test

`test/fork/RunFork.t.sol`, `test_fork_muxInputOrderMatters` and `test_fork_muxShape`, fork block 76,432,018:

```sh
forge test --match-path 'test/fork/RunFork.t.sol' -vv
```

The order with table `0xac` (inputs swapped) reverts `WrongAnswer(1)` inside `deliver`. The order with `0xca`
is paid. For every one of the 8 inputs, `run` returns the same bytes as the circuit's own `eval`.

# Crank run: a 16-input piece checked to Paid on a local anvil

**Date:** 2026-11-21. **Chain:** local anvil forked from X Layer mainnet at block 76,432,018, chain id set to 31337. No public network was sent anything.

## Plain summary

`scripts/crank.mjs` checked all 65,536 cases of a 16-input GreaterOrEqual(8, 8) piece in **400 transactions** over **1,193 seconds** (about 20 minutes, ~3 s per transaction). The last transaction paid the order. A second order, whose circuit answers case 300 wrong, stopped with `Rejected` at case 300 (exit code 2), and its piece reopened.

The circuits are mocks (`test/mocks/FormulaProcessor.sol`). Each case burns about 162,000 gas, the cost of a ~70-gate real circuit. So this run shows the crank's batching, gas limits, stop rules and payout. It does not show real TapeOut gas or real chain speed: anvil mines at once, and the ~3 s per transaction is cast's own send-and-wait time on this machine.

## Setup

```sh
anvil --fork-url https://rpc.xlayer.tech --fork-block-number 76432018 --chain-id 31337 --port 8561
forge script script/LocalCrankDemo.s.sol --rpc-url http://127.0.0.1:8561 \
  --unlocked --sender 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 --broadcast
```

`LocalCrankDemo` deploys MockUSDT, MockFactory, FormulaProcessor and LatheOrders. It creates order 1 (correct circuit, 70 gates reported, so the budget is 1,150,000 gas per case) and order 2 (wrong at case 300). It refuses any chain id but 31337.

The sender was a throwaway keystore holding anvil's public test account 1 (`0x7099…79C8`), made with `cast wallet import --keystore-dir <scratch dir>`, used through `--keystore` and `--password-file`, and deleted after the run. No raw key was passed to the script.

```sh
node scripts/crank.mjs --lathe <LATHE> --order 2 --piece 0 --batch 100 --rpc http://127.0.0.1:8561 --keystore <ks> --password-file <pw>
node scripts/crank.mjs --lathe <LATHE> --order 1 --piece 0 --batch 1000 --rpc http://127.0.0.1:8561 --keystore <ks> --password-file <pw>
```

## Results

| Run | Outcome |
|---|---|
| `--dry`, order 1, `--batch 1000` | batch lowered to 164 (gas limit 199,976,876 stays under the 200M default); plan 400 transactions; nothing sent |
| Order 2, `--batch 100` | 100/65536, 200/65536, 300/65536, then `Rejected: piece 0 answered case 300 wrong`; exit 2; `pieceOf(2, 0)` processor back to zero |
| Order 1, `--batch 1000` (164 per tx) | 400 transactions, 1,193.2 s, last line `order 1 paid`; `orders(1)` status 2 (Paid) |
| Gas used, order 1 | 11,110,056,428 in total; 27.8M per full batch of 164 cases (~169,500 per case: ~162,000 mock burn + ~7,500 Lathe); last batch 17,136,284 of a 122,341,840 limit (it also paid) |
| Refusals (no send) | `--private-key` refused; `--unlocked` with a non-local RPC refused; a piece with no delivery refused |

Gas used per batch was about 14% of the limit. The limit is sized for every case burning its whole budget, which these circuits never do (`evidence/2026-11-21-gas-16-input-piece.md`).

## Not tested

- `--account <name>` (a keystore in `~/.foundry/keystores`): the script passes it to cast unchanged, but this run used `--keystore <path>` so nothing was written to the real keystore folder.
- A password prompt per transaction (no `--password-file`).
- The retry path after a failed `cast send`, and a reverted transaction (`GraceOver`, `CircuitChanged`) mid-run.
- Any public RPC, real chain timing, or the sequencer's handling of 200M-limit transactions.

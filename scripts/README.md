# Crank: push a long piece check forward

A pieced order's piece can have up to 131,072 cases (17 inputs). That is far too many for one transaction, so `checkPiece(orderId, pieceIndex, maxCases)` checks a batch and moves a cursor forward. Anyone may call it. `crank.mjs` keeps calling it until the piece is done.

```sh
node scripts/crank.mjs --lathe <LatheOrders address> --order 7 --piece 0 --batch 200 \
  --rpc https://rpc.xlayer.tech --account <your keystore name>
```

It prints `next/total` after every transaction. It stops when the piece passes, or when the contract reports `Rejected` (exit code 2: the circuit gave a wrong answer and the piece reopened). It also stops on a reverted transaction (exit code 1). When the last piece of an order passes, that same transaction pays the builder, and the script prints `order N paid`.

## Your key never passes through the script

Every transaction is sent by a spawned `cast send --account <name>` (or `--keystore <path>`), which signs with your Foundry keystore. The script refuses `--private-key` and `--mnemonic`.

Without `--password-file`, cast asks for the keystore password on every transaction. A long check is hundreds or thousands of transactions, so for those, pass `--password-file <path>`: a file only you can read (`chmod 600`), deleted when the run ends.

`--unlocked --from <address>` (anvil's unlocked accounts) works only with a `127.0.0.1` / `localhost` RPC.

## How the gas limit is set, and why not by simulation

Each case's circuit gets exactly `evalBudget(gateCount) = 100,000 + 15,000 × gateCount` gas. The contract will not start a case unless that much is left (`InsufficientGasForCase`), so nobody can make an honest circuit fail by sending too little gas. A circuit may use its whole budget. So the script sets every gas limit from that budget, never from a simulation:

- per case: ⌈budget × 64/63⌉ + 20,000 + 30,000 slack
- per transaction: + 150,000 + the netlist read (30,000 + 70 gas per netlist byte)
- on the batch that finishes the piece: + 300,000 + one netlist read per piece, for the payout

`--batch K` is lowered if K cases would take the limit above `--max-gas` (default 200,000,000; an X Layer block holds 210M). Public RPCs cap `eth_call` at about 50M gas, so a simulated big batch would fail or come back wrong. `--dry` therefore does no simulation. It reads the order and prints the plan: batches, gas limit per batch, worst-case gas and the balance each transaction needs up front at the current gas price. Real use is much lower than the worst case. A real 652-gate circuit uses ~1.5M of its 9.88M budget per case (`evidence/2026-11-21-gas-16-input-piece.md`), and you pay only for gas used.

## Before you start

- The builder must have called `deliverPiece` for that piece.
- `checkPiece` runs until the order's deadline + 1 day. After that it reverts, and the buyer can refund.
- If `cast send` fails (RPC error, wrong password), the script reads the cursor again. If the cursor moved, the transaction landed and the script carries on. If not, it stops.

Tested on a local anvil (`evidence/2026-11-21-crank-anvil-run.md`). There, `script/LocalCrankDemo.s.sol` sets up a 16-input order with mock circuits.

# Crank: push a long piece check forward

A pieced order's piece can have up to 131,072 cases (17 inputs). That is far too many for one transaction, so `checkPiece(orderId, pieceIndex, maxCases)` checks a batch and moves a cursor forward. Anyone may call it. `crank.mjs` keeps calling it until the piece is done.

```sh
node scripts/crank.mjs --lathe <LatheOrders address> --order 7 --piece 0 --batch 200 \
  --rpc https://rpc.xlayer.tech --chain-id 196 --account <your keystore name>
```

It first prints the chain id and the block gas limit it read from the RPC. With `--chain-id N` it stops before sending anything if the RPC is on another chain (X Layer mainnet is 196, testnet 1952). It prints `next/total` after every transaction. It stops when the piece passes, or when the contract reports `Rejected` (exit code 2: the circuit gave a wrong answer and the piece reopened). It also stops on a reverted transaction (exit code 1). When the last piece of an order passes, that same transaction pays the builder, and the script prints `order N paid`.

## Your key never passes through the script

Every transaction is sent by a spawned `cast send --account <name>` (or `--keystore <path>`), which signs with your Foundry keystore. The script refuses `--private-key` and `--mnemonic`.

Without `--password-file`, cast asks for the keystore password on every transaction. A long check is hundreds or thousands of transactions, so for those, pass `--password-file <path>`: a file only you can read (`chmod 600`), deleted when the run ends.

`--unlocked --from <address>` (anvil's unlocked accounts) works only with a `127.0.0.1` / `localhost` RPC.

## How the gas limit is set, and why not by simulation

Each case's circuit gets exactly the delivery's per-case gas: `100,000 + 15,000 × gateCount`, or more if the builder declared more at delivery (see below). The script reads it with `pieceCaseGasOf(order, piece)`; on a contract from before that getter it uses the formula, which is what such a contract gives. A piece made mostly of links (REF records) to 1- or 2-gate circuits can need more than the formula on real TapeOut when a case runs first in a transaction, because the circuits it links to are cold then ([evidence](../evidence/2026-11-21-case-gas-fix.md)). Delivered without a declared per-case gas, such a piece passed or failed depending on where each check transaction started: with the formula budget the crank can see `Rejected` (exit 2) at the first case of a later batch although the circuit is right. Delivered with enough declared gas, it passes wherever the batches start. The contract will not start a case unless that much is left (`InsufficientGasForCase`), so nobody can make an honest circuit fail by sending too little gas. A circuit may use its whole budget. So the script sets every gas limit from that budget, never from a simulation:

- per case: ⌈budget × 64/63⌉ + 20,000 + 30,000 slack, where budget is the stored per-case gas
- per transaction: + 150,000 + the netlist read (30,000 + 70 gas per netlist byte)
- on the batch that finishes the piece: + 300,000 + one netlist read per piece, for the payout

`--batch K` is lowered if K cases would take the limit above `--max-gas` (default 200,000,000) or above the chain's block gas limit, read at start (an X Layer block holds 210M; a transaction with a higher limit than the block could never be included). If even one case does not fit, the script says so and sends nothing.

The batch that may finish the piece also pays the order, which reads every piece's netlist again. So right before that batch the script reads all netlist sizes again (another piece may have been delivered since the start) and prints `last batch may pay: netlists read again (N bytes over M piece(s))`. Public RPCs cap `eth_call` at about 50M gas, so a simulated big batch would fail or come back wrong. `--dry` therefore does no simulation. It reads the order and prints the plan: batches, gas limit per batch, worst-case gas and the balance each transaction needs up front at the current gas price. Real use is much lower than the worst case. A real 652-gate circuit uses ~1.5M of its 9.88M budget per case (`evidence/2026-11-21-gas-16-input-piece.md`), and you pay only for gas used.

## Before you start

- The builder must have called `deliverPiece` for that piece. The crank does not deliver. `deliverPiece(uint256,uint256,address,uint256)` gives each case the formula; `deliverPiece(uint256,uint256,address,uint256,uint32)` takes a declared per-case gas as its last argument (the costliest case's gas when it runs first in a transaction, × 64/63, plus a margin; at most 100,000,000). `scripts/measure-case-gas.mjs` (below) measures it and prints the command. The crank has no flag for it: it only reads the stored value back.
- `checkPiece` runs until the order's deadline + 1 day. After that it reverts, and the buyer can refund.
- If `cast send` fails (RPC error, wrong password, wrong `--from`), the script prints cast's own error text (with `--json`, cast writes it on stdout; it never holds your password), then reads the whole piece again, not only the cursor:
  - the delivery was cleared or replaced: a transaction landed and the circuit gave a wrong answer. It prints `Rejected` and exits with code 2;
  - the order is Paid: it says so and stops;
  - the cursor moved forward: the transaction landed, it carries on;
  - nothing changed: it stops (exit code 1).

Tested on a local anvil (`evidence/2026-11-21-crank-anvil-run.md`). There, `script/LocalCrankDemo.s.sol` sets up a 16-input order with mock circuits.

## Tests

```sh
node --test scripts/test/crank.test.mjs   # the pure parts: gas ceiling, batch fit, what a failed send means
node scripts/test/crank-anvil.mjs         # a local anvil with a 30M block (port 8556), no keys
```

`crank-anvil.mjs` checks: a `--chain-id` that does not match is refused before any send; a wrong `--from` shows cast's reason (`No Signer available`); on a 30M block every batch stays under 30M and the piece is checked to Paid, and a piece whose one case needs more than the block is refused; a piece delivered with a declared per-case gas is sized from it (`budget 600000 gas per case (declared by the builder)`) and Paid, while the same circuit without it is `Rejected` where the second batch starts; a send that "fails" (a stand-in `cast`, `scripts/test/fake-cast.mjs`, lets the transaction land and then exits 1) and rejected the piece gives `Rejected`, exit 2, and no further send; one that moved the check on carries on; the paying batch counts the netlist of a piece delivered after the start. `CRANK=<path>` runs it against another copy of the script.

# Measure: the per-case gas to declare at delivery

The first case of every transaction costs more than the rest (the circuits it calls are cold), and anyone chooses where a check transaction starts. So a builder whose circuit needs more than the formula budget (`100,000 + 15,000 × gates`) when a case runs first declares a per-case gas at delivery. `measure-case-gas.mjs` finds that number. It is read-only: it sends nothing and never sees a key.

```sh
# a plain order, or piece I of a pieced order: the shape and the gate cap come from the order
node scripts/measure-case-gas.mjs --rpc <your node> --lathe <LatheOrders address> --order 7 [--piece 0] \
  --processor <processor address> --circuit 42 --pause 200
# no order yet: give the shape
node scripts/measure-case-gas.mjs --rpc <your node> --processor <addr> --circuit 42 --inputs 6 [--state 1]
```

It runs every case as its own `eth_estimateGas` on a call straight to the processor's `eval` (`step` for a memory circuit), one request at a time (`--pause MS` between requests, for public RPCs; a rate-limited answer is retried 3 times). A simulated call is a fresh transaction, so the case runs cold, as the first case of a check transaction does. It subtracts the call's own base cost (21,000 + calldata) and prints:

- the costliest case and what it needs, and the formula budget, and whether it fits;
- the value to declare: worst × 64/63 + 10%, rounded up to 10,000 (the same rule as the order page, `web/gas.js`);
- the exact `cast send ... "deliver(uint256,address,uint256,uint32)" ...` or `"deliverPiece(uint256,uint256,address,uint256,uint32)" ...` command with that value and a gas limit (replace `--account YOUR_ACCOUNT` with your keystore).

A case it could not measure (it needed more than `--cap`, default 102,600,000, or it reverted) is listed as unknown, never as fitting. Exit code 1 when any case is unknown, when the value is above 100,000,000 (the contract cannot check it), or when the order's gate cap refuses it (a cap that promises a check inside the delivery accepts at most 30,000,000 / cases per case); 2 for a usage or read error; 0 otherwise. Public X Layer nodes cut a test run at 50,000,000 gas, so a case that needs more can only be measured on your own node.

How close it is: on real TapeOut the estimate minus the base cost came within about 40 gas of the true minimum on 256 cases, five link levels deep, and the proposal landed at 1.118× to 1.121× the true worst need ([evidence](../evidence/2026-11-21-case-gas-fix.md)).

```sh
node scripts/test/measure-anvil.mjs   # a local anvil (port 8566), no keys
```

`measure-anvil.mjs` checks: all 64 cases of mock circuit 5 measured and a value above its formula proposed; with `--order`, the printed command, run as printed, records the delivery and a 7 / 1 / 56 split pays (the formula is rejected at the same split); the same for `--piece`; a case above the cap, or behind a 50M-capped proxy, is unknown (exit 1); a case near 95M is refused above 100M; a gate-capped order refuses the value, and the contract refuses the printed command too; a node answering -32005 is retried, then unknown; a memory circuit is measured with `step`.

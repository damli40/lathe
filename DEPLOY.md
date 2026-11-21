# Deploying Lathe

This is the checklist for putting `LatheOrders` on X Layer. You sign every transaction yourself. The scripts never see your private key: `forge` asks for your keystore password and signs locally.

The order is fixed: **testnet first, smoke run passes, then mainnet.** Never mainnet without a passed testnet run of the same code.

## Read this first: what testnet proves and what it does not

TapeOut (the circuit contracts) and USDT do not exist on X Layer testnet (checked in `evidence/2026-11-20-preflight.md`, section 5). So the testnet deploy puts up stand-ins:

- **MockUSDT**: a fake 6-decimal dollar token anyone can mint.
- **MockFactory + MockProcessor**: fake TapeOut contracts. The processor holds two fake circuits you own: circuit 1 answers like a real XOR, circuit 2 gives one wrong answer (it says 1 XOR 1 = 1).

That means the testnet run proves **Lathe's own logic**: an order locks money, a correct circuit gets paid, a wrong one is refused, a late order refunds. It proves **nothing about real TapeOut circuits**. That part is proven by the mainnet fork tests (`test/fork/`), which run the real XOR circuit on a copy of mainnet.

The mock contracts have no access control (anyone can change the fake circuits). That is fine on a throwaway testnet and is why they never go to mainnet.

## 1. Make a throwaway testnet wallet

Use a new key that has never held real money. Never reuse your mainnet key here.

```sh
cast wallet new                     # prints a fresh address + key; copy the key
cast wallet import lathe-testnet --interactive
```

`--interactive` asks you to paste the key and choose a password. You type both; nothing lands in shell history. The key is stored encrypted under `~/.foundry/keystores/`. Check the address:

```sh
cast wallet address --account lathe-testnet
```

## 2. Get testnet OKB (gas)

Open https://web3.okx.com/xlayer/faucet and request testnet OKB for that address. The whole testnet run costs well under 0.01 OKB. Check it arrived:

```sh
cast balance $(cast wallet address --account lathe-testnet) --ether --rpc-url https://testrpc.xlayer.tech/terigon
```

## 3. Deploy on testnet

From the repo folder (`~/Desktop/lathe`):

```sh
forge script script/DeployTestnet.s.sol \
  --rpc-url https://testrpc.xlayer.tech/terigon \
  --account lathe-testnet --broadcast
```

It refuses to run on any chain except 1952.

**It sends three extra transactions first.** `LatheOrders` is too big to fit in one contract, so parts of it live in separate contracts called linked libraries: `LatheChecks` (the rules checked when an order is created), `LatheReads` (`run`, `runStep`, the piece join and the wiring for paid orders) and `NetlistLib` (builds the exact bytes a top circuit made of the tested pieces must have; `LatheChecks` and `LatheReads` both call it). None holds money or can change an order. `forge` deploys `NetlistLib` first, then the other two, then `LatheOrders`, and writes their addresses into the code that calls them. It uses the standard CREATE2 deployer (`0x4e59b44847b379578588920ca78fbf26c0b4956c`, present on X Layer testnet and mainnet when checked on 2026-11-21), so a library's address depends only on its compiled code: the same code gets the same address on every chain, and any change to `src/` (even a comment, since it changes the compiled metadata) gives a new one. If a library is already at that address, `forge` skips it. The addresses are in `broadcast/DeployTestnet.s.sol/1952/run-latest.json` under `libraries`.

It prints: `LATHE`, `USDT`, `FACTORY`, `PROCESSOR`, `XOR_ID` (1), `WRONG_ID` (2), `TOGGLE_ID` (3), `WRONG_TOGGLE_ID` (4), `FORMULA_PROCESSOR`, `ADD22_ID` (1), `GE32_ID` (2), `GE32_WRONG_ID` (3), `GE66_ID` (4), `GE23_ID` (5), `REF_PROCESSOR`. Keep them.

`FORMULA_PROCESSOR` is a second mock processor for pieced orders. Its circuits compute a formula instead of looking up a list of answers, all 4 gates: 1 = "a plus b" on two 2-bit numbers, 2 = "a is at least b" with a of 3 bits and b of 2, 3 = the same but wrong in case 5 (a = 5, b = 0), 4 = "a is at least b" on two 6-bit numbers (12 inputs, 4,096 cases, for the crank), 5 = "a is at least b" with a of 2 bits and b of 3 (for the daily-cap-shaped orders).

`REF_PROCESSOR` is a third mock processor. It holds circuits made only of references to other circuits (the "top circuit" of an order that needs one) and really runs them: each reference calls the referenced circuit. It reports `netlist` and `circuitInfo` the way TapeOut does, so `deliverTop` can compare the bytes. The smoke run mints its tops there.

**Optional, verify the source on OKLink** (needs an OKLink API key). Add these flags to the command above. `read -s` keeps the key off the screen and out of history:

```sh
read -s OKLINK_KEY
#   --verify --verifier oklink \
#   --verifier-url https://www.oklink.com/api/v5/explorer/contract/verify-source-code-plugin/XLAYER_TESTNET \
#   --etherscan-api-key $OKLINK_KEY
```

Not tested end to end. If it fails, try `xlayer_testnet` in lowercase, or verify after the fact. `LatheOrders` must be verified with the two library addresses it calls, `LatheChecks` and `LatheReads` with the `NetlistLib` address, and `NetlistLib` on its own:

```sh
forge verify-contract <LATHE address> src/LatheOrders.sol:LatheOrders \
  --libraries src/LatheChecks.sol:LatheChecks:<LatheChecks address> \
  --libraries src/LatheReads.sol:LatheReads:<LatheReads address> \
  --verifier oklink --verifier-url <same url> --etherscan-api-key $OKLINK_KEY --watch
forge verify-contract <LatheChecks address> src/LatheChecks.sol:LatheChecks \
  --libraries src/NetlistLib.sol:NetlistLib:<NetlistLib address> --verifier oklink --verifier-url <same url> --etherscan-api-key $OKLINK_KEY --watch
forge verify-contract <LatheReads address> src/LatheReads.sol:LatheReads \
  --libraries src/NetlistLib.sol:NetlistLib:<NetlistLib address> --verifier oklink --verifier-url <same url> --etherscan-api-key $OKLINK_KEY --watch
forge verify-contract <NetlistLib address> src/NetlistLib.sol:NetlistLib --verifier oklink --verifier-url <same url> --etherscan-api-key $OKLINK_KEY --watch
```

The constructor arguments of `LatheOrders` may also be needed (`--constructor-args $(cast abi-encode "constructor(address,address,address,uint16)" <factory> <usdt> <fee recipient> <fee bps>)`).

## 4. Smoke run on testnet

Paste the addresses from step 3 into this command:

```sh
LATHE=0x... USDT=0x... PROCESSOR=0x... XOR_ID=1 WRONG_ID=2 TOGGLE_ID=3 WRONG_TOGGLE_ID=4 \
FORMULA_PROCESSOR=0x... ADD22_ID=1 GE32_ID=2 GE32_WRONG_ID=3 GE66_ID=4 GE23_ID=5 REF_PROCESSOR=0x... \
forge script script/Smoke.s.sol \
  --rpc-url https://testrpc.xlayer.tech/terigon \
  --account lathe-testnet --broadcast
```

What it does and what you should see:

| Step | What happens | Expect |
|---|---|---|
| (a) | Creates an order for 2-input XOR (1 mUSDT) naming you as the builder, delivers the honest circuit | `order id 1 status 2` (2 = Paid). Small circuits are checked inside `deliver`, so it pays in the same transaction |
| (b) | Creates a second order, then tries the wrong circuit | `deliver reverts WrongAnswer(3)`, `order id 2 status 0` (0 = Open). Case 3 is 1 XOR 1, where the wrong circuit says 1 |
| (c) | Creates a third order with a 15-minute deadline | `order id 3 status 0`, plus the exact `cast send ... refund` command |
| (d) | Creates a memory order (1 input, 1 output, 1 memory bit, table `0x3c`) with input names `flip` and `mem`, delivers the honest toggle circuit 3 | `order id 4 status 2` (Paid in the same transaction) |
| (e) | Creates a second memory order, then tries the wrong toggle circuit 4 | `deliver reverts WrongAnswer(3)` (simulated, not sent), `order id 5 status 0`. Case 3 is x0 = 1 with memory 1, where circuit 4 keeps the memory at 1 instead of 0 |
| (f) | Reads the two paid orders (1 and 4): `receipts`, `ruleOf`, `labelsOf`, then `run` on all 4 XOR cases and `runStep` on all 4 toggle cases | `receipt + ruleOf ok for order 1` and `... order 4`, `labelsOf: (a) none, (d) flip, mem`, `run(a): ...`, `runStep(d): ...`. Any wrong answer stops the script with a `Smoke (f): ...` message |
| (g) | Creates a two-piece order: piece 0 adds two 2-bit numbers (inputs x0 x1 and x2 x3), piece 1 asks "is that sum at least x4 x5". Delivers formula circuit 1 as piece 0 and circuit 2 as piece 1. Both are small, so each is checked inside its `deliverPiece` | `order id 6 status 2` (Paid by the second delivery) |
| (h) | Creates the same two-piece order, delivers circuit 1 as piece 0 (passed), then tries the wrong circuit 3 as piece 1 | `deliverPiece reverts WrongAnswer(5)` (simulated, not sent), piece 0 still `16/16`, piece 1 not delivered, `order id 7 status 0` |
| (i) | Reads order 6: `piecesOf`, `receipts`, `ruleOf`, then `run` on all 64 inputs | receipt processor 0 (a two-piece order has no single circuit), fingerprint = `piecedHash`, `ruleOf` reverts `NoSingleCircuit`, every `run` answer = (x0x1 + x2x3) >= x4x5 with each number lowest bit first (inputs where bit order matters are named in the log) |
| (j) | Creates a one-piece order "a is at least b" on two 6-bit numbers (12 inputs, 4,096 cases) and delivers circuit 4. That is too many cases to check inside the delivery, so it stays at 0/4096 | `order id 8 status 0` and a `node scripts/crank.mjs ... --order 8 ...` command to check it (see below) |
| (k) | Creates a "daily cap" order on 2-bit numbers with explicit wires, paid as "Lathe joins": inputs x0 x1 = spent, x2 x3 = amount, x4 x5 = cap. Piece 0 adds spent and amount (formula circuit 1), piece 1 asks "is the cap at least that sum" (formula circuit 5, cap 2 bits, sum 3 bits). Both are checked inside `deliverPiece` | `order id 9 status 2` (Paid when piece 1 passes); `run` on all 64 inputs equals "cap >= spent + amount" (x = `0x25` gives 1, `0x27` gives 0) |
| (l) | The same order, created as "needs a top circuit". Both pieces pass but it stays Open. The script reads `expectedTopNetlist(10)`, mints a circuit with those bytes (6 inputs, 1 output) on `REF_PROCESSOR`, and calls `deliverTop` | `order id 10 status 2`; `ruleOf(10)` names the top circuit on `REF_PROCESSOR`; `run(10, x)` (one run of the top circuit) equals `run(9, x)` on all 64 inputs |
| (m) | A third "needs a top circuit" order with both pieces passed. Two bad tops are minted: the right bytes with the wrong shape (7 inputs), and wrong bytes (the comparator's five input wires rotated by one) | `deliverTop reverts ShapeMismatch` and `deliverTop reverts WrongTopCircuit` (both simulated, not sent); `order id 11 status 0` |
| (o) | The split-check fix. Circuit 5 on the mock `PROCESSOR` (set up by `DeployTestnet.s.sol`) is an honest 6-input parity whose cases cost more than their budget of 475,000 gas when they run first in a transaction, like a real circuit made of links (the mock reads 50 storage slots that are cold at the start of each transaction). The script delivers it with a declared per-case gas of 600,000 (`deliver(uint256,address,uint256,uint32)`) and checks it in five transactions that start at awkward cases (7, 1, 13, 2, then 41 cases). Then it **simulates** (never sends) the same circuit delivered the old way, without the declared gas, and a stranger's `check(7)` then `check(1)`, each from a cold start | `order id 13 status 2` and `caseGasOf(13)` = 600000; then `without the declared gas (simulated, not sent): check(7) then check(1) rejects case 7` |
| (n) | A "needs a top circuit" order of 6 one-gate XOR pieces in a chain (7 inputs, answer = their parity). Sets up circuit 9 on the mock `PROCESSOR` as a 1-gate XOR, delivers it as all 6 pieces, mints the top on `REF_PROCESSOR` and calls `deliverTop` | `order id 12 status 2`; `ruleOf(12)` names the top; `run(12, x)` with 3,000,000 gas equals the parity on all 128 inputs. The REF processor charges about what a real REF costs, so this step fails if a top's run budget ever drops back to `evalBudget(gates)` alone |

Every transaction (orders 1 to 13, their deliveries and checks, the mock circuit set up in (n) and the four top circuits minted in (l), (m) and (n)) is sent before the simulated calls in (b), (e), (h), (m) and (o). A pranked call from your account uses up one of its nonces in forge's simulation, so a transaction queued after it went out with a nonce the chain skipped (seen on the local anvil run: "provider nonce is still behind expected nonce").

The (f) reads and the `run` / `runStep` calls are free reads that forge runs in its simulation of the same transactions; they are never sent. `run` and `runStep` get an explicit 1,000,000 gas: like `check`, they refuse (`InsufficientGasForCase`) unless they can give the circuit its whole per-case budget. To confirm on chain afterwards:

```sh
cast call <LATHE> 'receipts(uint256)(address,uint256,bytes32,uint64)' 4 --rpc-url https://testrpc.xlayer.tech/terigon
cast call <LATHE> 'labelsOf(uint256)(bytes32[])' 4 --rpc-url https://testrpc.xlayer.tech/terigon
cast call <LATHE> 'runStep(uint256,bytes,bytes)(bytes,bytes)' 4 0x01 0x01 --gas-limit 1000000 --rpc-url https://testrpc.xlayer.tech/terigon
```

The last one is memory 1 with input 1: it must print `0x00` twice (new memory 0, output 0).

The receipt's fingerprint (third value) is `keccak256(abi.encodePacked(nIn, nOut, nState, table))`, so it covers the order's shape as well as its table bytes.

About (b): `forge` will not send a transaction it knows will revert, so the wrong delivery is **simulated** and its error checked, not sent. If you want a failed transaction on chain as evidence, the script prints a `cast send ... --gas-limit 1000000` command that sends it anyway. That transaction will show as failed on OKLink, and order 2 stays Open.

For (c): wait until the printed deadline passes (15 minutes by default, because on a slow public RPC the script takes several minutes to simulate before it sends; set `REFUND_DELAY=<seconds>` to change it), then run the printed `cast send ... refund(uint256) 3 ...` command. Then run the printed `cast call ... orders(...)` command: the last number must be `3` (Refunded). A refund before the deadline reverts `RefundNotAllowed`, which is correct.

Order 2's 1 mUSDT can also be refunded with the same command and id 2, but only after its one-day deadline.

**Where to paste the results:** create `evidence/2026-11-2x-testnet-v0.md` (use the real date) with the six addresses from step 3 and every transaction hash. The hashes are in `broadcast/DeployTestnet.s.sol/1952/run-latest.json` and `broadcast/Smoke.s.sol/1952/run-latest.json` (field `hash`), plus the `cast send` outputs for the refund and the optional failed delivery. The `broadcast/` folder is git-ignored, so copy the hashes into the evidence file. Add a line to `evidence/README.md`. Say in the file that testnet ran on mocks.

Every order must name its builder (`createOrder` reverts `BuilderRequired` for the zero address). The smoke run names the broadcasting account, which also owns the mock circuits.

**(j) on testnet: the crank.** Order 8 is there so `scripts/crank.mjs` can be tried on a public chain. Run the command (j) printed, from the repo folder, with your testnet keystore. It looks like this:

```sh
node scripts/crank.mjs --lathe <LATHE> --order 8 --piece 0 --batch 1000 \
  --rpc https://testrpc.xlayer.tech/terigon --chain-id 1952 --account lathe-testnet --password-file <path>
```

`--password-file` is a file only you can read (`chmod 600`) holding the keystore password; delete it after the run. Without it cast asks for the password on every transaction (about 5 here). Add `--dry` first to see the plan and the worst-case cost without sending anything. On the local anvil run the crank lowered the batch to 940 cases (gas limit 199,970,820 under the 200M default), sent 5 transactions, and the last one paid order 8. Expect `order 8 paid`.

All fourteen steps, (a) to (n), must behave as described before mainnet.

With step (n) and the top-run fix (2026-11-21, local anvil, chain id 1952, block gas limit 210M, anvil's unlocked default account): `ONCHAIN EXECUTION COMPLETE & SUCCESSFUL`, (a) to (n) as described. With the top's per-piece run gas set back to 0 (the old budget) as a check, the run stopped at `(n)`. Not yet run on testnet.

With the wired steps (k) to (m) (2026-11-21, local anvil, chain id 1952, block gas limit 210M, anvil's unlocked default account): `ONCHAIN EXECUTION COMPLETE & SUCCESSFUL`; read back from the chain afterwards, orders 9 and 10 were Paid and order 11 Open, and `ruleOf(10)` named circuit 1 on `REF_PROCESSOR`. The deploy broadcast held the three library deploys (CREATE2) before the mocks and `LatheOrders`. Not yet run on testnet.

With the pieced steps (g) to (j) (2026-11-21, local anvil, chain id 1952, block gas limit 210M): order 6 Paid, order 7 Open with piece 0 at 16/16 and piece 1 not delivered, order 8 Open at 0/4096, `run(6, 0x01)` = `0x01`, `run(6, 0x20)` = `0x00`, `run(6, 0x13)` = `0x01` by `cast call --gas-limit 2000000`, and the printed crank command (with `--rpc` pointed at the anvil and `--unlocked --from` instead of a keystore) checked order 8 to Paid in 5 transactions.

After the libraries split (2026-11-21), `DeployTestnet.s.sol` then `Smoke.s.sol` ran again on a local anvil (chain id 1952): the broadcast held the two library deploys (CREATE2) before the mocks and `LatheOrders`, and the smoke run gave the same results. `Deploy.s.sol` was dry-run on a mainnet fork (`--fork-url`, nothing sent): three transactions, the two libraries and `LatheOrders`.

Checked end to end on a local anvil (chain id 1952, `DeployTestnet.s.sol` then `Smoke.s.sol` with anvil's unlocked default account) on 2026-11-21: `ONCHAIN EXECUTION COMPLETE & SUCCESSFUL`, orders 1 and 4 Paid, 2, 3 and 5 Open, and the three `cast call` lines above gave the receipt, `flip` / `mem`, and `0x00 0x00`. Not yet run on testnet.

## 5. Mainnet

Use a **separate** keystore for mainnet, never the testnet one:

```sh
cast wallet import lathe-mainnet --interactive
```

Fund it with a little real OKB on X Layer for gas. The deploy is **four transactions**: `NetlistLib`, `LatheChecks`, `LatheReads` (the three linked libraries, see step 3), then `LatheOrders`. Forge's estimate for all four on the 2026-11-21 mainnet-fork dry run (V3b and V4 code) was 12,023,700 gas, about 0.00048 OKB at that run's gas price (forge's estimate includes its 1.3x margin; the real use is lower).

Decide two values first. Both are fixed forever once deployed (no owner, no upgrade):

- `FEE_RECIPIENT`: the address that receives Lathe's fee. Anyone can call `claimFees()` to send it there. Use an address USD₮0 will not block.
- `FEE_BPS`: the fee in basis points (100 = 1%). The contract refuses anything above 500 (5%). **You choose this.** The dry run used 100 only as a placeholder.

`USDT` is USD₮0, `0x779Ded0c9e1022225f8E0630b35a9b54bE713736` (Task 0's pick). The TapeOut factory `0x1f09DAeFA827f02CBb40967cc91b259763760761` is built into the script.

Dry run first (simulation only, nothing is sent, no key needed):

```sh
USDT=0x779Ded0c9e1022225f8E0630b35a9b54bE713736 FEE_RECIPIENT=0x<yours> FEE_BPS=<yours> \
forge script script/Deploy.s.sol --fork-url https://rpc.xlayer.tech
```

Then the real deploy:

```sh
read -s OKLINK_KEY
USDT=0x779Ded0c9e1022225f8E0630b35a9b54bE713736 FEE_RECIPIENT=0x<yours> FEE_BPS=<yours> \
forge script script/Deploy.s.sol \
  --rpc-url https://rpc.xlayer.tech \
  --account lathe-mainnet --broadcast \
  --verify --verifier oklink \
  --verifier-url https://www.oklink.com/api/v5/explorer/contract/verify-source-code-plugin/XLAYER \
  --etherscan-api-key $OKLINK_KEY
```

`--verify` also verifies the three libraries, because they are deployed by the same run (not tested; if one is missing on OKLink, use the four `forge verify-contract` commands in step 3 with the `XLAYER` URL). The library addresses are in `broadcast/Deploy.s.sol/196/run-latest.json` under `libraries`; record them with the `LatheOrders` address.

The script refuses to run unless the chain is 196, the factory and USDT have code, USDT has 6 decimals, `FEE_RECIPIENT` is not zero and `FEE_BPS` is at most 500. It prints one line: `LatheOrders 0x...`. Record that address, the three library addresses and the four transaction hashes (three libraries, then `LatheOrders`) (from `broadcast/Deploy.s.sol/196/run-latest.json`) in `evidence/2026-11-2x-deploy-v0.md`.

## Declaring the per-case gas at delivery

Each case of a delivery gets `100,000 + 15,000 × gates` gas unless the builder declares more with the overloads `deliver(uint256,address,uint256,uint32)` and `deliverPiece(uint256,uint256,address,uint256,uint32)`; then it gets the larger of the two, at most 100,000,000 (`CaseGasTooHigh` above that). `caseGasOf(id)` and `pieceCaseGasOf(id, i)` read the figure back. Why it exists: the first case of every transaction is dearer (the circuits it calls are cold), and anyone can choose where a check transaction starts, so a circuit near its budget could pass or fail depending on that. What to declare: the gas the costliest case needs when it runs alone in a fresh transaction, × 64/63 (TapeOut's proxy passes on 63/64 of the gas it is given), plus a margin. For a plain order the order page measures every case and proposes the number (it does not deliver while any case is untested); for a piece, or a case a public node cannot test, `node scripts/measure-case-gas.mjs --rpc URL --lathe ADDR --order N [--piece I] --processor ADDR --circuit ID` measures it and prints the exact `cast send` command. On an order or piece whose gate cap keeps `cases × evalBudget(cap)` at most 30,000,000, a declared value with `cases × caseGas` above 30,000,000 is refused (`CaseGasTooHigh`), so the cap keeps its promise of a check inside the delivery. A check then needs about `caseGas × 64/63 + 50,000` gas per case, so a larger figure means fewer cases per check transaction. On a local anvil (2026-11-21): `DeployTestnet.s.sol` then `Smoke.s.sol` ended `ONCHAIN EXECUTION COMPLETE & SUCCESSFUL` with order 13 Paid and `caseGasOf(13)` = 600000 read back by `cast call`; sending the old three-argument delivery of the same circuit by hand, then `check(14, 7)` and `check(14, 1)` as two transactions, left order 14 Open (rejected at case 7). See [evidence/2026-11-21-case-gas-fix.md](evidence/2026-11-21-case-gas-fix.md).

## Gotcha: give `deliver` explicit gas when using forge scripts

For each case, `deliver` must hold that case's whole gas budget before calling the circuit (100,000 + 15,000 per gate, plus a margin), but a small circuit uses far less. `forge script` sizes a transaction from the gas it saw used, so without an explicit limit the sent `deliver` reverts `InsufficientGasForCase`. This happened on the local dry run. `Smoke.s.sol` passes `{gas: 1_000_000}`. `cast send` and wallets ask the node to estimate gas by trial, which should find a working limit, but if a delivery fails with `InsufficientGasForCase`, resend with `--gas-limit 1000000`.

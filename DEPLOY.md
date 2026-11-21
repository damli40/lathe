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

It refuses to run on any chain except 1952. It prints six lines: `LATHE`, `USDT`, `FACTORY`, `PROCESSOR`, `XOR_ID` (1), `WRONG_ID` (2). Keep them.

**Optional, verify the source on OKLink** (needs an OKLink API key). Add these flags to the command above. `read -s` keeps the key off the screen and out of history:

```sh
read -s OKLINK_KEY
#   --verify --verifier oklink \
#   --verifier-url https://www.oklink.com/api/v5/explorer/contract/verify-source-code-plugin/XLAYER_TESTNET \
#   --etherscan-api-key $OKLINK_KEY
```

Not tested end to end. If it fails, try `xlayer_testnet` in lowercase, or verify after the fact with `forge verify-contract <LATHE address> src/LatheOrders.sol:LatheOrders --verifier oklink --verifier-url <same url> --etherscan-api-key $OKLINK_KEY --watch`.

## 4. Smoke run on testnet

Paste the addresses from step 3 into this command:

```sh
LATHE=0x... USDT=0x... PROCESSOR=0x... XOR_ID=1 WRONG_ID=2 TOGGLE_ID=3 WRONG_TOGGLE_ID=4 \
forge script script/Smoke.s.sol \
  --rpc-url https://testrpc.xlayer.tech/terigon \
  --account lathe-testnet --broadcast
```

What it does and what you should see:

| Step | What happens | Expect |
|---|---|---|
| (a) | Creates an order for 2-input XOR (1 mUSDT) naming you as the builder, delivers the honest circuit | `order id 1 status 2` (2 = Paid). Small circuits are checked inside `deliver`, so it pays in the same transaction |
| (b) | Creates a second order, then tries the wrong circuit | `deliver reverts WrongAnswer(3)`, `order id 2 status 0` (0 = Open). Case 3 is 1 XOR 1, where the wrong circuit says 1 |
| (c) | Creates a third order with a 5-minute deadline | `order id 3 status 0`, plus the exact `cast send ... refund` command |
| (d) | Creates a memory order (1 input, 1 output, 1 memory bit, table `0x3c`) with input names `flip` and `mem`, delivers the honest toggle circuit 3 | `order id 4 status 2` (Paid in the same transaction) |
| (e) | Creates a second memory order, then tries the wrong toggle circuit 4 | `deliver reverts WrongAnswer(3)` (simulated, not sent), `order id 5 status 0`. Case 3 is x0 = 1 with memory 1, where circuit 4 keeps the memory at 1 instead of 0 |
| (f) | Reads the two paid orders (1 and 4): `receipts`, `ruleOf`, `labelsOf`, then `run` on all 4 XOR cases and `runStep` on all 4 toggle cases | `receipt + ruleOf ok for order 1` and `... order 4`, `labelsOf: (a) none, (d) flip, mem`, `run(a): ...`, `runStep(d): ...`. Any wrong answer stops the script with a `Smoke (f): ...` message |

Every transaction (orders 1 to 5 and the two deliveries) is sent before the simulated wrong deliveries in (b) and (e). A pranked call from your account uses up one of its nonces in forge's simulation, so a transaction queued after it went out with a nonce the chain skipped (seen on the local anvil run: "provider nonce is still behind expected nonce").

The (f) reads and the `run` / `runStep` calls are free reads that forge runs in its simulation of the same transactions; they are never sent. `run` and `runStep` get an explicit 1,000,000 gas: like `check`, they refuse (`InsufficientGasForCase`) unless they can give the circuit its whole per-case budget. To confirm on chain afterwards:

```sh
cast call <LATHE> 'receipts(uint256)(address,uint256,bytes32,uint64)' 4 --rpc-url https://testrpc.xlayer.tech/terigon
cast call <LATHE> 'labelsOf(uint256)(bytes32[])' 4 --rpc-url https://testrpc.xlayer.tech/terigon
cast call <LATHE> 'runStep(uint256,bytes,bytes)(bytes,bytes)' 4 0x01 0x01 --gas-limit 1000000 --rpc-url https://testrpc.xlayer.tech/terigon
```

The last one is memory 1 with input 1: it must print `0x00` twice (new memory 0, output 0).

The receipt's fingerprint (third value) is `keccak256(abi.encodePacked(nIn, nOut, nState, table))`, so it covers the order's shape as well as its table bytes.

About (b): `forge` will not send a transaction it knows will revert, so the wrong delivery is **simulated** and its error checked, not sent. If you want a failed transaction on chain as evidence, the script prints a `cast send ... --gas-limit 1000000` command that sends it anyway. That transaction will show as failed on OKLink, and order 2 stays Open.

For (c): wait until the printed deadline passes (5 minutes; set `REFUND_DELAY=<seconds>` to change it), then run the printed `cast send ... refund(uint256) 3 ...` command. Then run the printed `cast call ... orders(...)` command: the last number must be `3` (Refunded). A refund before the deadline reverts `RefundNotAllowed`, which is correct.

Order 2's 1 mUSDT can also be refunded with the same command and id 2, but only after its one-day deadline.

**Where to paste the results:** create `evidence/2026-11-2x-testnet-v0.md` (use the real date) with the six addresses from step 3 and every transaction hash. The hashes are in `broadcast/DeployTestnet.s.sol/1952/run-latest.json` and `broadcast/Smoke.s.sol/1952/run-latest.json` (field `hash`), plus the `cast send` outputs for the refund and the optional failed delivery. The `broadcast/` folder is git-ignored, so copy the hashes into the evidence file. Add a line to `evidence/README.md`. Say in the file that testnet ran on mocks.

Every order must name its builder (`createOrder` reverts `BuilderRequired` for the zero address). The smoke run names the broadcasting account, which also owns the four mock circuits.

All six steps must behave as described before mainnet.

Checked end to end on a local anvil (chain id 1952, `DeployTestnet.s.sol` then `Smoke.s.sol` with anvil's unlocked default account) on 2026-11-21: `ONCHAIN EXECUTION COMPLETE & SUCCESSFUL`, orders 1 and 4 Paid, 2, 3 and 5 Open, and the three `cast call` lines above gave the receipt, `flip` / `mem`, and `0x00 0x00`. Not yet run on testnet.

## 5. Mainnet

Use a **separate** keystore for mainnet, never the testnet one:

```sh
cast wallet import lathe-mainnet --interactive
```

Fund it with a little real OKB on X Layer for gas. The deploy costs about 2.9M gas (about 0.0001 OKB at the dry-run gas price on 2026-11-20).

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

The script refuses to run unless the chain is 196, the factory and USDT have code, USDT has 6 decimals, `FEE_RECIPIENT` is not zero and `FEE_BPS` is at most 500. It prints one line: `LatheOrders 0x...`. Record that address and the transaction hash (from `broadcast/Deploy.s.sol/196/run-latest.json`) in `evidence/2026-11-2x-deploy-v0.md`.

## Gotcha: give `deliver` explicit gas when using forge scripts

For each case, `deliver` must hold that case's whole gas budget before calling the circuit (100,000 + 15,000 per gate, plus a margin), but a small circuit uses far less. `forge script` sizes a transaction from the gas it saw used, so without an explicit limit the sent `deliver` reverts `InsufficientGasForCase`. This happened on the local dry run. `Smoke.s.sol` passes `{gas: 1_000_000}`. `cast send` and wallets ask the node to estimate gas by trial, which should find a working limit, but if a delivery fails with `InsufficientGasForCase`, resend with `--gas-limit 1000000`.

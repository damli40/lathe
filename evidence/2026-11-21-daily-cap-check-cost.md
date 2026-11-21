# What it costs to check the daily-cap order (examples/daily-cap.json)

**Date:** 2026-11-21. **Chain:** local anvil forked from X Layer mainnet at block 76,483,570, chain id set to 31337. Nothing was sent to any public network. The X Layer gas price (20,000,001 wei = 0.02 gwei) and block gas limit (210,000,000) were read once from `https://rpc.xlayer.tech` at block 76,483,570 (`cast gas-price`, `cast block latest --field gasLimit`).

## Plain summary

The daily-cap rule is "spent today + this amount is at most the cap". It is two pieces: an 8-bit adder (16 inputs, 65,536 cases) and a comparison of the 8-bit cap with the 9-bit sum (17 inputs, 131,072 cases). That is 196,608 cases in all.

With small circuits (about 70 gates each), checking every case takes **1,210 transactions** and about **34 billion gas**, which is about **0.68 OKB** at the gas price read today. The transaction count comes from the crank's own maths (measured, see below). The gas per case comes from mock circuits that burn what a real circuit of that size is estimated to burn, so the OKB figure is an estimate.

**What this decides:** the daily-cap example is practical to check on mainnet if the two circuits stay small: well under 1 OKB and about 1,200 transactions. The circuit size is what moves the cost. At about 150 gates per circuit it doubles (about 2,400 transactions, 1.4 OKB); at 650 gates (the size of the real 8x8 multiplier) it is about 10,350 transactions and 6 OKB. So a builder should make the adder and the comparator as small as they can, and the buyer can cap them with `maxGates` in the order.

At the speed seen on public X Layer testnet (5 crank transactions in 55.6 s, `2026-11-21-testnet-v3a.md`), 1,210 transactions would take about 3.7 hours. That speed is from testnet with tiny circuits; mainnet speed is not measured.

The example is created as "needs a top circuit" (`"needsTop": true`), so after both pieces pass the builder mints one REF-only top circuit (fee 0.0013 OKB, `2026-11-21-netlist-ref-format.md` section 5) and calls `deliverTop`. That adds two ordinary transactions, not counted above.

## Which numbers are measured and which are estimated

| Figure | Value | Measured or estimated |
|---|---|---|
| Cases | 65,536 (adder) + 131,072 (comparator) = 196,608 | exact (2^16 + 2^17) |
| Gate counts | adder 72 (8 full adders x 9 NANDs), comparator 70 | **estimated**: no such TapeOut circuits exist yet |
| Gas a real circuit burns per case | 2,320 x gates (167,040 adder, 162,400 comparator) | **estimated** from the measured 2,320 gas per real gate (`2026-11-20-eval-gas-budget.md`); the mocks burn exactly this |
| Per-case budget Lathe must hold | 1,180,000 (72 gates), 1,150,000 (70 gates) | exact (100,000 + 15,000 x gates) |
| Cases per transaction, crank `--dry` | 160 (adder), 164 (comparator), gas limit 199,980,180 / 199,976,876 | **measured** (crank output below) |
| Transactions, crank `--dry` | 410 + 800 = **1,210** | **measured** (crank output) |
| Gas used per full batch, one `checkPiece` sent on the fork | adder 28,380,874 then 28,363,774 (160 cases); comparator 27,960,290 then 27,943,208 (164 cases) | **measured** on the local fork with the mock circuits |
| Gas used per case | 177,327 (adder), 170,437 (comparator): the mock burn plus about 8,000 to 10,000 of Lathe's own work | measured (mocks), so real circuits are only as close as the 2,320-per-gate estimate |
| Total gas | 65,536 x 177,327 + 131,072 x 170,437 = **33,960,820,736** | measured per case x exact case count |
| Cost | 33.96B x 20,000,001 wei = **0.679 OKB** | depends on the gas price, read once |
| Worst case, every case burning its whole budget | 81,991,873,800 + 159,981,500,800 = 242.0B gas, about 4.8 OKB at 0.02 gwei | exact from the budget maths; real circuits never burn their whole budget |
| OKB in dollars | not checked | |

The anvil fork reports its own gas price (about 1 gwei), so the OKB lines in the crank output below are not the mainnet cost; the mainnet price above was read separately.

## How it was run

```sh
anvil --fork-url https://rpc.xlayer.tech --fork-block-number 76483570 --chain-id 31337 --port 8571 --gas-limit 210000000
forge script script/LocalDailyCap.s.sol --rpc-url http://127.0.0.1:8571 \
  --unlocked --sender 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 --broadcast
node scripts/crank.mjs --lathe <LATHE> --order 1 --piece 0 --batch 100000 --rpc http://127.0.0.1:8571 --dry
node scripts/crank.mjs --lathe <LATHE> --order 1 --piece 1 --batch 100000 --rpc http://127.0.0.1:8571 --dry
# one full batch per piece, twice, to measure gas used (anvil's unlocked default account)
cast send <LATHE> 'checkPiece(uint256,uint256,uint256)' 1 0 160 --gas-limit 199980180 --unlocked --from <anvil account 0> --rpc-url http://127.0.0.1:8571
cast send <LATHE> 'checkPiece(uint256,uint256,uint256)' 1 1 164 --gas-limit 199976876 --unlocked --from <anvil account 0> --rpc-url http://127.0.0.1:8571
```

`script/LocalDailyCap.s.sol` refuses any chain id but 31337. It deploys MockUSDT, MockFactory, FormulaProcessor (mock circuits, `test/mocks/FormulaProcessor.sol`) and LatheOrders, creates the order exactly as `examples/daily-cap.json` says, and delivers piece 0 as an Add(8, 8) circuit reporting 72 gates and piece 1 as a GreaterOrEqual(8, 9) circuit reporting 70 gates, each burning 2,320 gas per gate per case.

Crank `--dry` output (piece 0, then piece 1):

```
chain id 31337, block gas limit 210000000
batch lowered from 65536 to 160 so the gas limit stays under --max-gas 200000000
order 1 piece 0: 0/65536 cases, 72 gates, budget 1180000 gas per case
plan: 410 transaction(s) of up to 160 cases, gas limit 199980180 each (the last one more if it pays)
this order needs a top circuit: it pays only when the builder calls deliverTop after every piece has passed (...)
worst case (every case burns its whole budget): 81991873800 gas

chain id 31337, block gas limit 210000000
batch lowered from 100000 to 164 so the gas limit stays under --max-gas 200000000
order 1 piece 1: 0/131072 cases, 70 gates, budget 1150000 gas per case
plan: 800 transaction(s) of up to 164 cases, gas limit 199976876 each (the last one more if it pays)
this order needs a top circuit: it pays only when the builder calls deliverTop after every piece has passed (...)
worst case (every case burns its whole budget): 159981500800 gas
```

After the four measuring sends, `pieceOf(1, 0)` showed 320 of 65,536 cases and `pieceOf(1, 1)` 328 of 131,072: the batches checked the cases they were sized for.

## If the circuits are bigger (estimated)

Same crank maths (`fitBatch`, `batchGasLimit` in `scripts/crank.mjs`, 200M limit per transaction), gas used per case estimated as 2,320 x gates + 9,000, both pieces the given size:

| Gates per circuit | Cases per transaction | Transactions | Gas used | OKB at 0.02 gwei |
|---|---|---|---|---|
| 70 | 164 | 1,200 | 33.7B | 0.67 |
| 150 | 81 | 2,429 | 70.2B | 1.40 |
| 300 | 42 | 4,682 | 138.6B | 2.77 |
| 652 | 19 | 10,349 | 299.2B | 5.98 |

## Sources this builds on

- `2026-11-21-gas-16-input-piece.md`: gas per case of a real 652-gate circuit (1.49M) and why the transaction count follows the per-case budget, not the real use.
- `2026-11-21-testnet-v3a.md`: a public X Layer chain (testnet) accepted crank transactions with gas limits of about 200M (5 sent, all included).
- `2026-11-20-eval-gas-budget.md`: about 2,320 gas per real gate on X Layer.

## Limits

- No real adder or comparator circuit exists on TapeOut, so the gate counts and gas per case are estimates; only the crank maths and the mock runs are measured.
- Only 2 batches per piece were sent, not the full 1,210 transactions.
- Mainnet inclusion of a steady stream of 200M-limit transactions, and its speed, are not tested.
- The gas price was read once.

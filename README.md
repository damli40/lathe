<p align="center"><img src="assets/logo.png" width="96" alt="Lathe logo"></p>

# Lathe

Pay only when circuits pass.

Order a small TapeOut circuit on X Layer, lock the USDT up front, and the builder gets paid only when the circuit gives the right answer for every possible input. A contract runs the check. No reviewer decides.

Status: entered in X Layer TapeOut Accelerate (deadline Dec 7, 2026). The order contract and the order page are built, including one-bit memory circuits, receipts, input names and orders made of two pieces (the page shows pieced orders read-only for now). The contract runs on X Layer testnet at `0x1E96e90E25E25b6fcb8cc28aa883d5a5df2715f4` with stand-in circuits, because TapeOut is not on testnet. It is not on mainnet yet. Test records are in [evidence/](evidence/README.md).

## The problem

TapeOut puts real logic chips on X Layer, and apps like games and agent wallets run their rules on them. Getting one built today means learning NAND design yourself, or paying a builder up front and hoping it works.

TapeOut already lets a contract run any circuit with `eval`. So a contract can check the work before it pays.

## How an order works

1. **The buyer writes the rule as a full table.** Up to 6 yes/no inputs, so 64 cases, each with its expected output. Small enough to test every case, not a sample.
2. **The buyer locks USDT** in the order contract, with a delivery deadline, and names the one builder who may deliver.
3. **The named builder delivers.** They mint the circuit on TapeOut and submit its ID.
4. **The contract runs all 64 cases** through `eval`, in batches if one transaction can't hold them all.
5. **Every output matches: the builder gets paid.** One miss: no payment. If nothing passes by the deadline, the buyer takes the money back.

A passed circuit stays on-chain and anyone can rerun it for free, so any app can check the rule before it relies on it.

## Orders made of pieces

A table can only cover 6 inputs. A rule like "the amount is at least the limit, and two of three people approved" has 19 inputs. Its table would have 524,288 rows, and no one can check that many cases through one circuit.

So a buyer can split the rule into one or two **pieces**. Each piece is its own circuit, with no memory, delivered on its own with `deliverPiece`. A piece is one of:

- a **table**, like a normal order, up to 6 inputs;
- a **formula** the contract works out itself, so no table is stored: "a is at least b" (one output) or "a plus b", on two numbers of up to 17 input bits together. a is the first input bits, b the ones after it, each lowest bit first.

**How the check works.** Each piece is checked alone, on every one of its own inputs. A 16-input piece has 65,536 cases. That is too many for one transaction, so anyone pushes the check forward in batches with `checkPiece`, for example with [scripts/crank.mjs](scripts/README.md). A wrong answer clears only that piece's delivery; the other piece keeps its state. The order pays the builder once every piece has passed.

**Why the joined rule is right.** The pieces are wired in one fixed way. The second piece gets the first piece's outputs as its first inputs, then the order's remaining inputs. Since each piece is right on all of its own inputs and the wiring is fixed, the joined rule is right too. The joined rule is not checked again as a whole. `run` on a paid order joins the pieces the same way.

**What can still go wrong.**

- A piece that passed cannot be replaced. If TapeOut's owners change a passed piece's circuit before the order pays (they can upgrade the processor code), the payout refuses (`CircuitChanged`) and the order can never pay. The buyer then takes the money back after the deadline and its one-day grace.
- Running a paid two-piece rule gives each piece its full gas budget, one after the other. With big circuits that can pass the about 50M gas that public X Layer nodes allow in a free call. The order page then says it cannot run the rule, rather than show an answer it did not get.

**What a 16-input piece costs.** Measured on a copy of X Layer mainnet with a circuit built like the real 652-gate 8x8 multiplier: about **1.5M gas per case** ([evidence](evidence/2026-11-21-gas-16-input-piece.md)). From that measured figure, all 65,536 cases come to about 98B gas, about 1.97 OKB at that day's gas price of 0.02 gwei. That total is a projection, and the gas price moves. The crank then needs about 3,450 transactions, because each case must be handed its whole 9.88M gas budget. A small comparator of about 70 gates took 400 transactions in a local test run with stand-in circuits ([evidence](evidence/2026-11-21-crank-anvil-run.md)); its cost of about 0.22 OKB is an estimate, not a measurement of a real circuit.

## What we checked (read-only, X Layer mainnet, Nov 16 2026)

| Question | Answer |
|---|---|
| Can a contract get an answer from someone else's circuit? | Yes. A 1,204-gate circuit returned output through `eval`. |
| Cost of one run | About 2,290 gas per gate: about $0.005 for that 1,204-gate circuit. |
| Cost of checking all 64 cases | About $0.32 for the 1,204-gate circuit. About a cent for a 50-gate rule. |
| Does one transaction hold all 64 cases? | For a 50-gate rule, yes (about 7M gas). For the 1,204-gate circuit, about 180M gas: under the 210M block limit, but over 16.7M, the per-transaction cap Ethereum and Base use. X Layer's per-transaction cap is not confirmed, so the check runs in batches. |
| Can the contract read gate count? | Yes, `circuitInfo(id)`. |
| Cost for a builder to mint a circuit | About 0.0013 OKB plus the gates used. No BEM or FAB needed on existing processors. |

Not yet tested: a contract calling a circuit chosen at claim time inside one transaction (reasoned, not simulated).

## Known limits

- A table covers at most 6 inputs. Bigger rules use pieces: at most two, each either a table of up to 6 inputs or one of two formulas ("a is at least b", "a plus b") of up to 17 inputs. Longer chains of pieces and free wiring between them come after Dec 7.
- Who can change the circuit runner: the processor factory is owned by a 3-of-5 multisig and is not sealed; the circuit beacon's owner is the zero address (read-only check, Nov 15 2026). We have not audited every upgrade path, so Lathe pins and inspects the exact processor before any order takes money.
- Lathe takes a fee on each paid order. Rate not set.
- Every order names its builder. Open orders, where any builder may deliver, come after Dec 7: an open order lets anyone mint a copy of the honest builder's circuit, or wrap it, and deliver first.
- A processor that returns badly encoded data (from `eval`, `step`, `circuitInfo` or `netlist`) makes `check` revert instead of counting a wrong answer. A delivered order then cannot finish its check: it waits until one day after its deadline, and then the buyer gets a refund. Only TapeOut's factory owners, who can change the processor code, could cause this. A builder cannot: a builder only picks a circuit, not the code that runs it.

- The contract is three contracts: `LatheOrders`, which holds the money, and two linked libraries it calls, `LatheChecks` (the rules checked when an order is created) and `LatheReads` (`run` and `runStep`). This keeps `LatheOrders` under the contract size limit. The libraries hold no money and cannot change an order on their own. A deploy sends all three ([DEPLOY.md](DEPLOY.md)).

## Roadmap to Dec 7

- [ ] Order contract on X Layer mainnet (lock, deliver, check in batches, pay, refund)
- [x] Order page in English and Chinese (`web/`, run it locally: see [web/README.md](web/README.md))
- [ ] One real order paid on mainnet, funded by someone other than the author
- [ ] Demo video

## License

MIT

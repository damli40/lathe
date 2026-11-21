<p align="center"><img src="assets/logo.png" width="96" alt="Lathe logo"></p>

# Lathe

Pay only when circuits pass.

Order a small TapeOut circuit on X Layer, lock the USDT up front, and the builder gets paid only when the circuit gives the right answer for every possible input. A contract runs the check. No reviewer decides.

Status: entered in X Layer TapeOut Accelerate (deadline Dec 7, 2026). The order contract and the order page are built. The contract runs on X Layer testnet at `0xDF3B0240Ed38d267De67e9Ed3Bad66F0Db8747fD` with stand-in circuits, because TapeOut is not on testnet. It is not on mainnet yet. Test records are in [evidence/](evidence/README.md).

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

- 6 inputs is the cap for this version. Rules with more inputs, or with numbers that must first become yes/no, come after Dec 7.
- Who can change the circuit runner: the processor factory is owned by a 3-of-5 multisig and is not sealed; the circuit beacon's owner is the zero address (read-only check, Nov 15 2026). We have not audited every upgrade path, so Lathe pins and inspects the exact processor before any order takes money.
- Lathe takes a fee on each paid order. Rate not set.
- Every order names its builder. Open orders, where any builder may deliver, come after Dec 7: an open order lets anyone mint a copy of the honest builder's circuit, or wrap it, and deliver first.

## Roadmap to Dec 7

- [ ] Order contract on X Layer mainnet (lock, deliver, check in batches, pay, refund)
- [x] Order page in English and Chinese (`web/`, run it locally: see [web/README.md](web/README.md))
- [ ] One real order paid on mainnet, funded by someone other than the author
- [ ] Demo video

## License

MIT

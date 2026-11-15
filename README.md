<p align="center"><img src="assets/logo.png" width="96" alt="Lathe logo"></p>

# Lathe

Post a circuit job with USDT locked up front. Lathe runs every submitted TapeOut circuit on X Layer, checks its answers, and pays the builder whose circuit passes. No reviewer decides.

Status: design stage, entered in X Layer TapeOut Accelerate (deadline Dec 7, 2026). No contract is deployed yet. This README describes the plan and the checks behind it.

## The problem

Projects and funds on TapeOut want circuits built: a smaller adder, a cheaper comparator, a rule chip for their app. Paying for that work today means a person reads the submission and decides. The builder waits on that person, and the poster has to trust their own reviewer.

TapeOut already lets a contract run a circuit and read its gate count. So a contract can do the review itself.

## How it works

1. **You post a job.** You give what the circuit must do (a reference circuit or a set of test inputs and expected outputs), an optional gate limit, a deadline and a USDT reward. The reward goes into a contract nobody owns.
2. **Builders submit.** A builder mints a TapeOut circuit and submits it in two steps: first a sealed commitment, then the reveal. A copied entry arrives too late to win.
3. **The contract checks.** It calls `eval` on the submitted circuit for each test input and compares the outputs. It reads the gate count with `circuitInfo`. Anyone can post an extra test input during a short challenge window; a circuit that disagrees with the reference fails.
4. **The contract pays.** The best passing circuit (fewest gates) gets the reward when the deadline passes. If none passes, the poster gets the money back.

FabX pays designers for TapeOut's own protocol tasks. Lathe lets any project or fund post its own job and pay with its own money.

## What we checked (read-only, X Layer mainnet, Nov 16 2026)

| Question | Answer |
|---|---|
| Can a contract get an answer from someone else's circuit? | Yes. A 1,204-gate circuit returned output through `eval`. |
| Cost of one check | About 2,290 gas per gate: about $0.005 for that 1,204-gate circuit. |
| Cost of a full test | 16 inputs on a 100-gate circuit: about $0.007. On a 1,000-gate circuit: about $0.065. |
| Limit | 256 inputs on a 1,000-gate circuit needs about 590M gas, above the 210M block limit. Large jobs split tests across transactions or rely on the challenge window. |
| Can the contract read gate count? | Yes, `circuitInfo(id)`. |
| Cost for a builder to mint a circuit | About 0.0013 OKB plus the gates used. No BEM or FAB needed on existing processors. |

Not yet tested: a contract calling a circuit chosen at claim time inside one transaction (reasoned, not simulated).

## Known limits

- A circuit can memorise fixed test inputs. The challenge window and reference comparison are the defence; small jobs can test every input.
- TapeOut can upgrade the processor contracts that run circuits. Lathe inherits that trust.
- Lathe takes a small fee on each paid job. Rate not set.

## Roadmap to Dec 7

- [ ] Job contract on X Layer mainnet (post, commit, reveal, challenge, pay, refund)
- [ ] Job page in English and Chinese
- [ ] First jobs live, including one funded by someone other than the author
- [ ] Demo video

## License

MIT

# Evidence index

Each file records what was measured, with the command, block number, date and limits. Plain-language summary first in every file.

| File | Date | What it settles |
|---|---|---|
| [2026-11-20-preflight.md](2026-11-20-preflight.md) | 2026-11-20 | Task 0 spike: which USDT to pay in, circuit ownership getter and return types, gas cap, the contract-to-processor probe on an anvil fork (GO), X Layer testnet facts, OKLink verify flags |
| [2026-11-20-gas-per-case.md](2026-11-20-gas-per-case.md) | 2026-11-20 | Gas per case for `check` on the real XOR circuit (fork block 76,432,018): ~21,600 per case, ~88,000 fixed per call, ~76,000 for the payout; a 64-case order fits in one transaction. Superseded in part by the eval-gas-budget file (XOR is now checked inside `deliver`; fee is pulled) |
| [2026-11-20-eval-gas-budget.md](2026-11-20-eval-gas-budget.md) | 2026-11-20 | Per-case gas budget for `eval` (FIX 1): ~2,300 gas per real gate, ~10,000 per gate for REF-to-XOR circuits; budget = 100,000 + 15,000 × gateCount; low-gas griefing now reverts instead of rejecting; a gas bomb is rejected the same way at any caller gas; FIX 4 inline check limit (30M) and which cases x gates fit inline |
| [2026-11-20-deploy-dryrun.md](2026-11-20-deploy-dryrun.md) | 2026-11-20 | Deploy scripts dry-run: mainnet deploy simulates on a fork (~2.86M gas); testnet deploy + smoke pass on local anvil chain 1952 (XOR paid, wrong circuit `WrongAnswer(3)`, refund after deadline only); forge-sent `deliver` needs explicit gas or it reverts `InsufficientGasForCase` |

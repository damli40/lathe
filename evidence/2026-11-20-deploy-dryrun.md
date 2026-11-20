# Deploy scripts: dry runs (2026-11-20)

**Plain summary.** All three scripts ran end to end without a real key and without sending anything to a real network. The mainnet deploy simulates cleanly on a mainnet fork (about 2.86M gas). On a local copy of the testnet chain (anvil, chain id 1952), the testnet deploy and the smoke run did what they should: the honest XOR circuit got paid, the wrong circuit was refused with `WrongAnswer(3)`, and the short-deadline order refunded after the deadline and not before. The first local smoke run found a real problem: `forge script` sent `deliver` with too little gas and it reverted `InsufficientGasForCase`. `Smoke.s.sol` now gives `deliver` an explicit 1,000,000 gas, and the rerun passed.

**What this does not prove.** Nothing here touched X Layer testnet or mainnet with a transaction. Testnet uses mock TapeOut contracts (TapeOut is not on testnet, see `2026-11-20-preflight.md` section 5), so it proves Lathe's own logic only; real circuits are covered by `test/fork/`. OKLink verification was not tried. Local runs used anvil's built-in unlocked account (`--unlocked --sender`), so no private key or keystore was created or used.

Tool: forge 1.8.6 (Homebrew), repo HEAD 0e5da8d plus the new `script/` files.

**Rerun after the named-builder fix (same day, on top of ebcc55e).** Every order must now name its builder; `createOrder` reverts `BuilderRequired()` (selector `0xc7dcdf4f`) for the zero address. `Smoke.s.sol` names the broadcaster. All sections below were rerun exactly as written and passed; numbers that changed are marked *rerun*.

## 1. Mainnet deploy, simulated on a fork

```sh
USDT=0x779Ded0c9e1022225f8E0630b35a9b54bE713736 FEE_RECIPIENT=0x000000000000000000000000000000000000dEaD FEE_BPS=100 \
forge script script/Deploy.s.sol --fork-url https://rpc.xlayer.tech
```

Env values were placeholders set inline on the command, not exported. Result: `Script ran successfully`, chain 196, `Estimated total gas used for script: 2855609`, `Estimated amount required: 0.000114224362855609` (OKB, at 0.04 gwei max fee). *Rerun:* 2,866,541 gas, 0.000114661642866541 OKB (the new check adds about 11k gas of bytecode). `SIMULATION COMPLETE`, nothing broadcast. The address it printed is a simulation address and means nothing.

## 2. Wrong-chain guards

Both scripts run against `anvil --chain-id 31337`:

- `Deploy.s.sol` → `Deploy: not X Layer mainnet (196)`
- `DeployTestnet.s.sol` → `DeployTestnet: not X Layer testnet (1952)`

## 3. Testnet deploy on local anvil (chain 1952)

```sh
anvil --chain-id 1952 --port 8547
forge script script/DeployTestnet.s.sol --rpc-url http://127.0.0.1:8547 \
  --unlocked --sender 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 --broadcast
```

`ONCHAIN EXECUTION COMPLETE & SUCCESSFUL`. Logged `LATHE`, `USDT`, `FACTORY`, `PROCESSOR`, `XOR_ID 1`, `WRONG_ID 2` (local addresses, not reusable). *Rerun:* same result. `DeployTestnet.s.sol` creates no orders, so it needed no change.

## 4. Smoke run on local anvil

```sh
LATHE=<from 3> USDT=<from 3> PROCESSOR=<from 3> XOR_ID=1 WRONG_ID=2 REFUND_DELAY=60 \
forge script script/Smoke.s.sol --rpc-url http://127.0.0.1:8547 \
  --unlocked --sender 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 --broadcast
```

**First run: failed.** Simulation passed, but the sent `deliver` for order (a) reverted on chain (gasUsed 184,231; `cast run` showed `InsufficientGasForCase()`). Cause: forge sets the gas limit from the gas it saw used times 1.3, but `deliver` must have each case's full eval budget (100,000 + 15,000 × 4 gates = 160,000, × 64/63, + 20,000) available before the call, while the mock eval uses far less. Fix: `lathe.deliver{gas: 1_000_000}(...)` in `Smoke.s.sol`. No contract change.

**Second run, fresh anvil: passed.** `ONCHAIN EXECUTION COMPLETE & SUCCESSFUL`.

*Rerun (named builder), fresh anvil: passed,* same three results as the table. `cast call orders(id)` now shows the builder field set to the broadcaster (`0xf39F…2266`) on all three orders, not zero. Extra check: `cast call createOrder(... builder = 0x0 ...)` from the same account reverted `0xc7dcdf4f` = `BuilderRequired()`.

| Step | Logged | Checked on chain afterwards with `cast call orders(id)` |
|---|---|---|
| (a) honest XOR | `order id 1 status 2` | status 2 (Paid); `feesOwed` = 10,000 (1% of 1 mUSDT) |
| (b) wrong circuit | `deliver reverts WrongAnswer(3) (simulated, not sent)`, `order id 2 status 0` | status 0 (Open). Sending the printed `cast send ... deliver ... --gas-limit 1000000` produced a failed tx (status 0); order stayed Open |
| (c) short deadline | `order id 3 status 0` + refund command | `refund(3)` before deadline → `RefundNotAllowed`; after `evm_increaseTime 120` → success, status 3 (Refunded) |

## What it decides

The scripts are ready for Dami to run on testnet (steps in `DEPLOY.md`). Anyone sending `deliver` from a `forge script` must set gas explicitly; `cast send` and wallets use the node's gas estimate, which searches for a limit that succeeds, but this was not tested on the X Layer node.

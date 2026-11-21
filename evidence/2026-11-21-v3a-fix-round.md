# V3a fix round: contract size, crank, smoke on a local anvil

**Date:** 2026-11-21. Local anvil only (chain ids 1952 and 31337), plus one mainnet-fork dry run of `Deploy.s.sol` (`--fork-url`, nothing sent). No public network was sent anything.

## Plain summary

`LatheOrders` was 22,206 bytes of the 24,576-byte limit. Two parts now live in linked libraries, so the contract is **19,499 bytes**: 5,077 bytes of room for the next versions. Nothing callers see changed (the ABI has the same 91 entries). The deploy now sends three transactions instead of one. The crank script now reads the chain's block gas limit, checks the chain id, shows cast's errors and handles a rejected piece on a failed send. The testnet smoke run now includes two-piece orders and a 12-input piece for the crank.

## Sizes (`forge build`, solc 0.8.24, optimizer 200 runs, no via_ir)

| Contract | Runtime bytes |
|---|---|
| `LatheOrders` before (commit `78d078c`) | 22,206 |
| `LatheOrders` after | 19,499 |
| `LatheChecks` (create-time rules, writes a new pieced order's pieces) | 3,602 |
| `LatheReads` (`run`, `runStep`, the piece join) | 4,200 |

What did not help, measured: `piecesOf` through the library (+254 bytes), `ruleOf` through the library (+50 bytes, so it stays in `LatheOrders`). Next option if more room is needed: optimizer runs 1 gives `LatheOrders` 19,304 bytes (only 195 less), so the real next step is moving more code, not compiler settings.

## Gas guard across the library hop

`test/LatheOrders.libs.t.sol` (forge, mock circuits that burn nearly all of a 200-gate budget, 3.1M gas per case): `run` refuses (`InsufficientGasForCase`) at one case's hold (3,169,207 gas) and answers at the page's figure (3,646,179 = `web/gas.js runGasLimit`, now x 64/63). A sweep in 25,000-gas steps from 200,000 under the hold up to the page's figure gave only refusals and right answers, never a wrong one; the smallest limit that answered was 3,269,207. Two pieces: the page's two-piece figure answers; a one-piece figure is refused.

## Deploy and smoke (local anvil, chain id 1952, block gas limit 210M)

- `DeployTestnet.s.sol`: the broadcast holds `LatheChecks` and `LatheReads` (CREATE2 through `0x4e59…956c`) before the mocks and `LatheOrders`.
- `Smoke.s.sol`: (a) to (f) as before; (g) two-piece order 6 Paid; (h) order 7: wrong piece 1 refused with `WrongAnswer(5)`, piece 0 stays 16/16, order Open; (i) order 6 receipt has processor 0, fingerprint = `piecedHash`, `ruleOf` reverts `NoSingleCircuit`, `run` right on all 64 inputs; on chain afterwards `run(6, 0x01)` = `0x01`, `run(6, 0x20)` = `0x00`, `run(6, 0x13)` = `0x01`; (j) order 8 (GreaterOrEqual(6, 6), 4,096 cases) recorded at 0/4096.
- The crank command (j) prints, pointed at the anvil with `--unlocked --from`: batch lowered from 1,000 to 940, 5 transactions, about 6.78M gas used per full batch of a 199,970,820 limit, `order 8 paid` in 1.8 s.
- `Deploy.s.sol` dry run on a mainnet fork: three transactions, forge's estimate 8,164,147 gas in total.
- `LocalCrankDemo.s.sol` (chain id 31337) still deploys.

## Crank (`node scripts/test/crank-anvil.mjs`, 30M block, chain id 1952)

| Case | After the fix | The script before the fix |
|---|---|---|
| `--chain-id 196` on chain 1952 | refused, nothing sent | `unknown option --chain-id` |
| wrong `--from` | shows `No Signer available` (cast prints it on stdout with `--json`), then "nothing changed" | "no progress was made", cast's reason hidden |
| 30M block | prints `chain id 1952, block gas limit 30000000`; 11 transactions, highest limit 29,421,316; Paid. A 2,000-gate piece (30.1M per case) refused before any send | asked for a 122M limit, which the 30M block refused: "no progress was made" |
| send "fails" after it landed and rejected the piece (stand-in `cast`) | `Rejected`, exit 2, 2 sends in all | not reached on a 30M block (the limit bug stops it first); the old code says "check moved to 0/N; continuing" when the cursor falls back |
| send "fails" after it landed and moved the cursor | "check moved to 48/256; continuing", then Paid | not reached (same) |
| piece 1 delivered during the run | paying batch counts both netlists (46 + 43 bytes) | not reached (same) |

`node --test scripts/test/crank.test.mjs`: 3 tests (gas ceiling, batch fit, what a failed send means).

## Page (pieced orders, read-only)

`node web/test/pieces.mjs` (local anvil, through the 50M-cap proxy): a paid two-piece order, a piece mid-check (100 of 4,096), a rejected piece, an order past its deadline with a piece never delivered, a paid 1-piece order, and a paid order of 1,600-gate pieces whose run needs 52,038,177 gas (the page says it cannot run it). The true texts are asserted, and none of the old false ones appear ("Does not match the table below", the zero address as processor, "No circuit delivered yet", a deliver box). `node --test web/test/`: 43 tests.

## Limits

- Mock circuits only. Nothing here measures real TapeOut gas.
- The crank was not run on a public chain. The (j) command is for Dami to run on testnet.
- `--verify` with the linked libraries on OKLink is not tested.

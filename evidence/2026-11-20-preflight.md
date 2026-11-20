# Preflight facts for the order contract (Task 0) - 2026-11-20

Read-only. Mainnet RPC `https://rpc.xlayer.tech` (chainId 196), run one call at a time (the public RPC returns HTTP 403 under about 24 parallel calls). Mainnet blocks 76,430,079 to 76,430,700 (about 2026-11-20 18:25 UTC, ~1 s blocks, so the whole session spans about 10 minutes). No transaction was sent to a live chain and no key was used. The probe ran only on a local anvil fork with anvil's public default test account. The `eth_call` with a spoofed `--from` below is a simulation, not a signature.

## What this decides

**GO.** A contract on X Layer can call a TapeOut processor and get the right answer. Both the combinational `eval` (XOR returned `0x01`) and the latched `step` (returned new state `0x01`, outputs `0x01`) work from inside a contract. The plan holds, with three things to fix before coding (details in "Contradicts or tightens the plan"):

1. There are **two** USDT tokens on X Layer. Pick one on purpose.
2. `ownerOf` works as the plan hoped, so the owner getter needs no workaround.
3. TapeOut does **not exist on X Layer testnet**. The testnet run must use mocks, and the evidence must say so.

## 1. USDT on X Layer mainnet

| Fact | Answer | Source / command | Limit |
|---|---|---|---|
| Current official token (recommended) | `0x779Ded0c9e1022225f8E0630b35a9b54bE713736`, symbol `USD₮0`, name `USD₮0`, decimals 6 | OKX help page "What's USDT0 and how do I use it?" (`okx.com/en-au/help/usdt0-faq`, updated 26 Aug 2026) says: "New USDT0 address on X Layer: 0x779D...3736". `cast call <addr> 'symbol()(string)'`, `'decimals()(uint8)'`, `'totalSupply()(uint256)'` at block 76,430,079: `"USD₮0"`, `6`, 119,481,542,420,442 (about 119.5M tokens) | Symbol contains the unicode character `₮`, not the letters "USDT". It is an upgradeable proxy (implementation `0x1ec7df9e74be05cb5a456aca2dc1ac2cec9ab6a3` via `cast implementation`), so its issuer can change its code. Not verified: whether it has a blacklist or freeze. |
| Older token | `0x1e4a5963abfd975d8c9021ce480b42188849d41d`, symbol `USDT`, name `Tether USD`, decimals 6, supply 3,056,742,537,342 (about 3.06M) | Same OKX page: "Old USDT address on X Layer: 0x1e4a...d41d". OKLink token page `oklink.com/x-layer/evm/token/0x1e4a...` labels it "USDT_Bridged". Not a proxy (`cast implementation` returned zero address) | Dormant: zero Transfer logs in blocks 76,430,000-76,430,090, while USD₮0 had 165 in the same window. |
| Does `transfer` return bool? | **Yes, for both** | `cast call <token> 'transfer(address,uint256)' 0x...dEaD 0 --from 0x...c0FFEE` returned `0x...01` (true) on both. `transferFrom(...,0)` also returned `0x...01` on both. Block 76,430,700 | Tested with amount 0 from an address holding nothing, because that cannot revert for lack of balance. It proves the return type (a 32-byte true), not behaviour on a real balance. Source not read on OKLink; this is a live-return check. |

Says what it decides: the OKX page says "the USDT/USDT0 token contract address remains unchanged", yet gives two different addresses, so that sentence is not reliable. Pay in USD₮0 (`0x779D...`): it holds 39x the supply and is the one still moving. Even so, if Dami's spec says "USDT", confirm that the builder's side will hold USD₮0, because the old token will not be used by anyone.

## 2. Circuit ownership and return types

| Fact | Answer | Source / command (block 76,430,485) | Limit |
|---|---|---|---|
| `ownerOf(uint256)` on processor `0x839bdD6f...574e`, id 1 | **Works.** Returns `0x571d447f4f24688eC35Ccf07f1D6993655F6aF15` | `cast call 0x839bdD6fa7A66416A609A735e11DE5411B98574e 'ownerOf(uint256)(address)' 1`. Also `supportsInterface(0x80ac58cd)` (ERC-721) returned `true`. TAP-02 line 45: "An ERC-721 contract created by the processor factory". | That address is the TapeOut hub owner per TAP-11, so this id is a team-owned circuit. Not tested on a circuit owned by a normal user. Not tested for a burned or non-existent id (I did not check whether it reverts). |
| `circuitInfo(uint256)` | `(uint32 nIn, uint32 nOut, uint32 nState, uint32 gateCount)`, selector `0x084d60f1` | TAP-02 line 129. Live raw return for id 1 is 4 words: `2, 1, 0, 4` (XOR: 2 in, 1 out, no state, 4 gates) | Each value is returned in a full 32-byte word, so decode as four `uint32`. |
| `netlist(uint256)` | `bytes`, selector `0x3fc4be56` | TAP-02 line 130. Live return is a standard ABI `bytes` (offset `0x20`, length `0x1c` = 28 bytes) | |
| `eval(uint256,bytes)` | `bytes`, selector `0x934d06ea`; reverts `has latch: use step` if `nState > 0` | TAP-02 line 131 | |
| `step(uint256,bytes,bytes)` | `(bytes newState, bytes outputs)`, selector `0xe8281a1a` | TAP-02 line 132 | |

## 3. Per-transaction gas cap

**Answer: none found below the 210M block limit. I am fairly sure (about 85%) for simulations, less sure for real sent transactions.**

- Block gas limit: 210,000,000 (`cast block latest --field gasLimit`, mainnet, and also on testnet).
- Live test, block 76,430,544: `cast estimate --from 0x...dEaD --rpc-url https://rpc.xlayer.tech --create <loop bytecode>`. The init code is `0x63<N as 8 hex digits>5b600190038060055700`, a countdown loop costing 26 gas per round. Results:

| Loop rounds N | Estimated gas |
|---|---|
| 770,000 | 20,233,700 |
| 1,923,077 | 50,451,638 |
| 3,846,154 | 100,848,465 |
| 5,769,231 | 151,245,293 |
| 7,692,308 | **201,642,120** |
| 9,000,000 | error `-32003: out of gas: gas required exceeds: 210000000` |

- What this decides: a single call that needs 200M gas is accepted, and the only wall is 210M, the block limit. So the plan's rule (gas = about 2,300 x gates x inputs, must stay under 210M) is the right budget. Nothing like Ethereum's 16.8M per-transaction cap (EIP-7825) showed up.
- Limits: `eth_estimateGas` is a node simulation. I could not send a real 200M-gas transaction (no sending allowed), so a mempool or sequencer cap on real transactions below 210M is not ruled out. The X Layer docs I searched say nothing about a per-transaction cap (I found none; absence is not proof). Plan for a safety margin: design for at most about 100M gas per `check` call and treat anything higher as untested.

## 4. Contract-to-processor call (GO / NO-GO)

**GO. Both calls from a deployed contract returned the expected bytes.**

- Setup: `anvil --fork-url https://rpc.xlayer.tech --port 8546` (fork block about 76,430,137). Probe source: `/private/tmp/claude-501/lathe-probe/Probe.sol` (outside the repo). Compiled with solc 0.8.28 (pragma `^0.8.20`; the plan's `=0.8.24` is not installed on this machine, so the probe used what was cached). Deployed with anvil default account 0 to `0x9E545E3C0baAB3E08CdfD552C960A1050f373042` (status 1, gas 756,983). The probe uses `staticcall` and abi-decodes the returned `bytes`.
- `evalXor(0x839bdD6fa7A66416A609A735e11DE5411B98574e, 1, 0x01)` returned `(true, 0x01)`. Control inputs on the same circuit: `0x00 -> 0x00`, `0x02 -> 0x01`, `0x03 -> 0x00`. That is the full XOR truth table (inputs are LSB-first bits).
- `stepLatched(0x0565EA48CA41Ae559d8d491dbb0a9ec945DB551b, 1, 0x00, 0x)` returned `(true, newState 0x01, outputs 0x01)`.
- Extra: `circuitInfo` through the probe returned `(0,1,2,10)` for the latched circuit (0 in, 1 out, 2 state bits, 10 gates) and `(2,1,0,4)` for XOR.
- Limits: the fork is a copy of mainnet state at one block, run locally; calls came from the probe as a view-style staticcall, not as a state-changing transaction. I did not test the `isCPU` factory check, a cold-call gas figure inside a loop, or a processor upgrade mid-order.

## 5. X Layer testnet

| Fact | Answer | Source / command | Limit |
|---|---|---|---|
| RPC and chainId | `https://testrpc.xlayer.tech/terigon` (alt `https://xlayertestrpc.okx.com/terigon`), chainId **1952** | OKX docs "Network information" (`web3.okx.com/onchainos/dev-docs/xlayer/developer/build-on-xlayer/network-information`). `cast chain-id --rpc-url <each>` returned `1952` on both; block about 46,740,803; gas limit 210,000,000 | Block explorer: `okx.com/web3/explorer/xlayer-test`. |
| Faucet | `https://web3.okx.com/xlayer/faucet` ("X Layer testnet faucet. Get OKB, USDG, and more on X Layer testnet") | Page fetched 2026-11-20. Docs link: `web3.okx.com/xlayer/docs/developer/bridge/get-testnet-okb-from-faucet` | I did not use it. Login or balance requirements not read. |
| TapeOut factory on testnet | **None** | `cast code 0x1f09DAeFA827f02CBb40967cc91b259763760761 --rpc-url https://testrpc.xlayer.tech/terigon` returned `0x`. Processor `0x839b...574e` also `0x`. TAP-10 chain table lists only BNB Smart Chain (56), Base (8453) and X Layer (196); the TAPs repo has no testnet address in TAP-02, 10, 11 (grep for testnet/faucet: no hits) | The factory could exist at a different address that TAP docs do not list; I found none. |
| Official test USDT | **None found** | The faucet advertises OKB and USDG, not USDT. Mainnet USDT and USD₮0 addresses have no code on testnet (`cast code` returned `0x`) | So deploy `MockUSDT` on testnet, as the plan says. |

Says what it decides: the testnet run proves the order contract's own logic only (create, fund, claim, refund) against a `MockProcessor` and a mock factory. It does **not** prove anything about real TapeOut circuits. Step 4 above (mainnet fork) is the only evidence for the TapeOut side, and the evidence file for the testnet run must say so.

## 6. Verification flags (OKLink)

| Network | Flags | Source | Limit |
|---|---|---|---|
| Mainnet (196) | `--verify --verifier oklink --verifier-url https://www.oklink.com/api/v5/explorer/contract/verify-source-code-plugin/XLAYER --etherscan-api-key <OKLink API key>` | OKLink docs (`oklink.com/docs/en/`, "Contract verification using foundry"): URL pattern `.../verify-source-code-plugin/{chainShortName}`; supported list includes `XLAYER` and `XLAYER_TESTNET`. Local `forge script --help` (forge 1.8.6) lists `oklink` as a verifier. Docs also say an OKLink API key is required ("Apply for OKLink API key") and recommend `--watch` with `forge verify-contract` | **Not tested end-to-end** (needs a real deployment and a key). The docs' own examples use lowercase short names (`eth`, `ethsepolia`) but list the supported names in capitals, so the exact case for X Layer (`XLAYER` vs `xlayer`) is unconfirmed. Try capitals first, then lowercase. Dami needs an OKLink API key before deploy day. |
| Testnet (1952) | Same, ending `.../XLAYER_TESTNET` | Same page | Same limits. |

If `--verify` fails, fall back to `forge verify-contract <addr> src/LatheOrders.sol:LatheOrders --verifier oklink --verifier-url <url above> --etherscan-api-key <key> --watch`, or paste standard-json input from `--show-standard-json-input` into `oklink.com/x-layer/verify-contract-preliminary` (testnet page exists at `oklink.com/x-layer-testnet/verify-contract-preliminary`).

## Contradicts or tightens the plan

1. Plan Task 0 Step 1 assumes one "USDT". There are two (section 1). Recommend USD₮0 `0x779D...3736`; its symbol is `USD₮0`, so any test that checks `symbol() == "USDT"` will fail.
2. Plan Task 3 can rely on `ownerOf` (section 2). Return widths for `circuitInfo` are `uint32`, matching the plan's interface.
3. Plan Task 6 Step 3 already anticipated "no TapeOut on testnet": confirmed, so the mock path is the real path.
4. The plan says `solc = "0.8.24"`. Only 0.8.28 (and 0.8.15, 0.5.17) are cached here; `forge build` will download 0.8.24 on first run, which needs network. Not a blocker.
5. Feasibility note's open item "per-transaction gas cap unchecked" is now answered for simulations (section 3).

## Not verified

- Real sent-transaction gas cap; OKLink verification end to end; exact `XLAYER` case; USD₮0 blacklist/freeze; `ownerOf` on a non-existent id; faucet requirements; whether OKX's page claim "address unchanged" is simply a copy error.

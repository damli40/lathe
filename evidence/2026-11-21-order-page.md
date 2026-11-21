# Order page (web/): tests and review, 2026-11-21

Date: 2026-11-21. Code: `web/` at the commit that adds this file. Contract under test: `LatheOrders` as of commit `666780b`.

## What this proves, and what it does not

- **Proves:** the page in `web/` creates an order, delivers a circuit, runs the check and refunds, and shows the right result each time. It was driven in headless Chrome against a local chain, against a copy of X Layer mainnet with a real circuit, and read-only against the live testnet contract.
- **Does not prove:** that a real wallet (OKX Wallet, MetaMask) behaves the same. Every write was signed by a test stand-in for a wallet on a local chain. No transaction was sent to a public network from the page.

## Results

All commands run from the repo root. Each line below is the last line the command printed.

| Test | Command | Result |
|---|---|---|
| Table encoder, gas maths, network picker | `node --test web/test/` | `tests 27, pass 27, fail 0` |
| Full flow on a local chain | `node web/test/e2e.mjs` | `E2E PASS: paid, refused with failing row, refunded` |
| Real circuit on a mainnet copy (fork block 76,432,018) | `node web/test/fork.mjs` | `FORK PASS: real XOR circuit delivered through the page, order Paid` |
| Live testnet contract, no wallet | `node web/test/readonly.mjs` | `READONLY PASS: live testnet orders 1, 2, 3 = Paid, Open, Refunded with no wallet` |
| Fixes from the review, behind a node that caps test runs at 50M gas | `node web/test/fixround.mjs` | `FIXROUND PASS` |
| Layout at 1440 and 390 px, dark and light, EN and ZH | `SHOTS_DIR=<dir> node web/test/shots.mjs` | `SHOTS PASS` (0 px sideways scroll in all 16 views) |

In the mainnet-copy test the real 4-gate XOR circuit at processor `0x839bdD6fa7A66416A609A735e11DE5411B98574e`, id 1, was delivered by its owner (impersonated on the copy). The builder received 9.9 of 10 tokens: the test deploy sets a 1% fee.

## What the adversarial review found, and the fixes

A separate reviewer tried to break the page. Four findings would have mattered on mainnet. All four are fixed and each has a test in `web/test/fixround.mjs` or the unit tests.

| Finding | Effect before the fix | Fix |
|---|---|---|
| X Layer's public nodes cap a test run (`eth_call`) at 50,000,000 gas, whatever the request asks for (measured on both RPCs: 49,947,900 gas left) | The page test-ran every `check` with up to 200M gas, so circuits above about 3,240 gates could never be checked through the page | The test run covers only as many cases as fit under 48M; the real transaction still runs the full batch. If one case does not fit, the page sends without a test run and says so |
| `check` never read the receipt status | A check that failed on chain showed "10 of 64 cases checked" when 0 were | Every send path now fails on a failed receipt; progress is re-read from the contract |
| "Nothing here touches real money" was shown on every network | False on mainnet | Heading and sub-line change with the network |
| A comma in the amount was deleted | "1,5" was read as 15 | Any comma is refused with a message |

Also fixed: the fee is now shown (what the builder receives), stale balance after an account switch, "failed" shown for a sent transaction whose receipt could not be read, the outputs field wiping answers mid-typing, `?net=__proto__`, keyboard use of the table grid.

What the reviewer found sound: the table encoding (nine order shapes from 1 input and 1 output up to 6 inputs and 16 outputs, encoded by the page, matched an independent encoder and were paid by the contract), the four presets for 1 to 6 inputs, the failing-row highlight, the gas limits for `deliver`, and no `innerHTML` anywhere.

## Limits

- No real wallet was used. A wallet may run its own gas estimate against the capped node and warn on large `check` transactions.
- The 50M cap and the one-request-at-a-time rule for mainnet were tested through a local proxy that imitates the node, not against the public RPC under load.
- The only real TapeOut circuit delivered is XOR, which gives the same answer whatever order its inputs arrive in. Input order on a non-symmetric real circuit is untested.
- The page loads the viem library from esm.sh at run time. A copy pinned in the repo is not done yet.
- No block-explorer links: no working URL format was confirmed for X Layer testnet, so hashes are shown as text.
- The hero drawing (`web/figure/`) passed its own geometry audit (`node web/figure/build.mjs --audit`: `audit passed`) and line check (0 floating line ends, dark and light). It was reviewed from screenshots only.

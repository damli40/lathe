# Mainnet deploy, 2026-11-22

Lathe is deployed on X Layer mainnet (chain 196). This file records what was sent, what the live contract reports, and what has not been done yet.

## What was deployed

Sent by `0xD618c61666d8848825E7e383c140eCd0Ad27e5aF`, a wallet used only for this deploy, with `forge script script/Deploy.s.sol --broadcast` from commit `9160a52`. The contract code is the same as commit `189a041`, the version run on testnet on Nov 21 (`git diff 189a041 9160a52 -- src script foundry.toml` is empty).

| Contract | Address | Transaction | Block | Gas used |
|---|---|---|---|---|
| NetlistLib | `0x3282dA37Ca907b87f5911096EF80f3528F1A52EA` | `0x956f3d1092dc89a8f9ebca0de70cb5b9941357c965cc9a3df6a02be5d307c2fd` | 76593108 | 761,918 |
| LatheChecks | `0x775aD1c2928720f67a4D0ff947829552D46deF60` | `0x5943779f97989b113401e84b7410d71e7e84e6635fe4c7d30ebb3fc3b5eb3499` | 76593109 | 1,648,050 |
| LatheReads | `0xDEcFd5eA065ffC687d34930be784D1361842344F` | `0x1636ea95a4c9523029cb4fc13f8c6ce01c6c6569e4e7094a3e3dc6d3693ed5d2` | 76593110 | 1,802,819 |
| **LatheOrders** | **`0x5218a5f49f816386459DdeC53EB03d9CbdFDEBD0`** | `0x58345184f210eb67f43155e5bd59d72c8b08608cebe52321085f9b7f06fc190d` | 76593111 | 5,125,986 |

All four receipts have status 1. Block 76593111 is timestamped 2026-11-22 15:42:27 UTC. Total: 9,338,773 gas, 0.000186775 OKB at 0.02 gwei. The dry run had estimated 12,763,073 gas (forge adds a 1.3x margin).

## What the live contract reports

Read with `cast call` against `https://rpc.xlayer.tech` after the deploy:

| Call | Result | Expected |
|---|---|---|
| `usdt()` | `0x779Ded0c9e1022225f8E0630b35a9b54bE713736` | USD₮0 |
| `factory()` | `0x1f09DAeFA827f02CBb40967cc91b259763760761` | TapeOut processor factory |
| `feeRecipient()` | `0x36599B0286D3c32F934BC8877eeA839D88f3AFFC` | the address chosen Nov 21 |
| `feeBps()` | `200` | 2% |
| `feesOwed()` | `0` | no orders yet |
| code size | 23,234 bytes | under the 24,576 limit |

These four settings are fixed: the contract has no owner and no upgrade path.

## Source published on OKLink

All four contracts returned `Pass - Verified` from OKLink through `forge verify-contract --verifier oklink --verifier-url https://www.oklink.com/api/v5/explorer/contract/verify-source-code-plugin/XLAYER`, with **no API key**. The libraries were passed with `--libraries`, and `LatheOrders` with its four constructor arguments. The commands are in `DEPLOY.md` section 5.

## Page

`NETWORKS.mainnet.lathe` in `web/config.js` now holds the address. `node web/test/config-live.mjs` printed `CONFIG PASS mainnet: token, factory match 0x5218…EBD0` (and `CONFIG PASS testnet`). `web/test/readonly.mjs` now checks that mainnet opens on the deployed contract; `web/test/receipt.mjs` step (j) blanks the address to keep testing the no-address state. `readonly`, `receipt`, `fixround` and the 53 unit tests pass.

## Not done yet

- No order has been created on mainnet. Nothing has been paid or refunded there, and no real TapeOut circuit has been delivered to this contract. Real circuits have only run against a copy of mainnet (see `2026-11-20-preflight.md` and `2026-11-21-case-gas-fix.md`).
- The page is not hosted yet.
- The explorer pages were not opened in a browser; "verified" here is OKLink's API answer.

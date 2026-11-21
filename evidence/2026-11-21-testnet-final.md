# Lathe, all versions (V0 to V4), on X Layer testnet: deploy, smoke run and crank

Date: 2026-11-21. Chain: X Layer testnet, chainId 1952, RPC `https://testrpc.xlayer.tech/terigon`. Code: commit `8b04ea8` (plus a longer default deadline in `script/Smoke.s.sol`, see "What went wrong on the way").

## What this proves, and what it does not

- **Proves:** on a real public network, every order type in the final contract works end to end: table orders, one-bit memory orders, two-piece orders, orders with explicit wiring between pieces (the daily-cap shape), and orders paid on delivery of one "top" circuit made of references to the tested pieces. Wrong deliveries were refused in the script's simulation, a late order was refunded, and the crank checked a 4,096-case piece to Paid in 5 transactions. The contract is four deployed pieces: `LatheOrders` and three linked libraries.
- **Does not prove:** anything about real TapeOut circuits. TapeOut is not on testnet (`2026-11-20-preflight.md`), so every circuit here is a stand-in, including the "top" circuits, which come from a mock processor that follows TapeOut's reference format and charges 40,000 gas per reference. Real tops were minted and compared on every input on a copy of mainnet (`test/fork/WiringTopFork.t.sol`, `2026-11-21-top-run-gas.md`). Mainnet behaviour of 200M-limit transactions is not shown by this run.

This contract replaces the V3a testnet contract `0x1E96e90E25E25b6fcb8cc28aa883d5a5df2715f4` (`2026-11-21-testnet-v3a.md`), which stays on chain. The page (`web/config.js`) now points at the new address.

Deployer, buyer and builder in every order: the throwaway testnet wallet `0x5a15Dca0F83Ae5878fD20eF0f9444b59Dbef03a0`. Fee: 1%.

## Deployed contracts

| Contract | Address | Deploy tx |
|---|---|---|
| LatheOrders | `0xde9A8a4b40d490C9Eff56157129902dc1d3D00b7` | `0xba2168eb69cd07cfb5a5751581116b2a4eb7236fa525921d043a4ce729d58d6c` |
| NetlistLib (library) | `0xBD7809c0863f60311c95A4FF4bB9fAA9eb5bf773` | `0x972ac580279ef05718c8412ea13d59c97ab89799043916340baf20309b9bcaca` |
| LatheChecks (library) | `0xF3c95039685045B249e2c2e2E49610Ec477f1aa0` | `0x0995239c7727b066cfcda1ca8daf43c3e02cc2dbe98449e03070bfa9c5d5c7c7` |
| LatheReads (library) | `0xD3390a7716bab9a39C4D93dc989D8cE250DF6b38` | `0x8e51c4abfefb959ba94fd1143727db90680c42e1ddb9f04cde3bbde4ece6649e` |
| MockUSDT | `0x1A3BED6F34c363df992F83C5b090B3d638AAa7a1` | `0x9ce042b7415ce4d8e289155e376d0dcdb394ce2e8ee328259036f284051b8bf8` |
| MockFactory | `0x9125d63fa26C4fCAB8E4ee9F6Ad0DD88CE46bE97` | `0x7741f562eb7d93b992da315fcdc89402b7ea57296f538a9a93891142baadda70` |
| MockProcessor | `0xc550651Cb57044Ad1c9E12ED591a9241ED6E3338` | `0x29175ace95ae9e5652562758fe91669c743ef74c43a27b59d5245cda26f18f7a` |
| FormulaProcessor | `0x648bDF760Fd155e80134E17dE68189F57a22aB77` | `0x32ec329adf033f56a49f21e84ac8c5eedea080915e7cd7ec3c563aea342c7638` |
| RefProcessor | `0xfB058Da1a43B157b3981728BEe7431D48c97c694` | `0xe124d1954db57fecaa239aada95d7c9a56585ec43128d6b5c7fdaf189c35fdbc` |

All 29 deploy transactions have receipt status 1.

## Orders on chain after the run (statuses read back with `orders(id)`)

Status: 0 Open, 2 Paid, 3 Refunded. Order ids start at 3 for the full run because orders 1 and 2 were created by the first, interrupted run (see below).

| Order | What it is | Status |
|---|---|---|
| 1 | 2-input XOR, honest circuit (first run) | 2 Paid |
| 2 | XOR order with no delivery (first run) | 0 Open |
| 3 | 2-input XOR, honest circuit | 2 Paid |
| 4 | XOR order; the wrong circuit was refused in simulation | 0 Open |
| 5 | Order with a short deadline, refunded after it | 3 Refunded |
| 6 | One-bit memory order with input names, honest toggle | 2 Paid |
| 7 | Memory order; the wrong toggle was refused in simulation | 0 Open |
| 8 | Two pieces: "a plus b", then "sum is at least c" | 2 Paid |
| 9 | Two pieces; piece 0 passed, the wrong piece 1 was refused in simulation | 0 Open |
| 10 | One piece, "a is at least b" on two 6-bit numbers, 4,096 cases, checked by the crank | 2 Paid |
| 11 | Daily-cap shape with explicit wires, paid when the last piece passed ("Lathe joins") | 2 Paid |
| 12 | The same rule as "needs a top": paid when the top circuit was delivered | 2 Paid |
| 13 | "Needs a top"; a wrong-shape top and a wrong-bytes top were refused in simulation | 0 Open |
| 14 | A top made of 6 one-gate XOR pieces (6 references) | 2 Paid |

Refund of order 5: `0x7b9c6f6a3a74c22228a4dcb7d04f040518b8945093906de070626a8cf60010f4`, status 1.

Unlike the earlier testnet runs, the refused deliveries were **not** also sent as failing transactions this time; the refusals are from the script's simulation against live chain state.

## Reads on the live contract (free calls, no wallet)

| Call | Answer |
|---|---|
| `ruleOf(12)` | RefProcessor `0xfB058D…c694`, circuit 1: the top circuit is the order's rule |
| `run(14, 0x07)` with 3,000,000 gas | `0x01`: parity of three set bits, through a top with 6 references |
| `run(11, 0x25)` and `run(11, 0x27)` with 3,000,000 gas | `0x01` and `0x00`: the cap is at least spent plus amount for the first input and not for the second |

## The crank (order 10)

`node scripts/crank.mjs --lathe 0xde9A8a4b40d490C9Eff56157129902dc1d3D00b7 --order 10 --piece 0 --batch 1000 --rpc https://testrpc.xlayer.tech/terigon --chain-id 1952 --keystore <file> --password-file <file>`: 5 transactions in 66.0 seconds, batch lowered to 940 cases to stay under a 200M gas limit.

| Cases done | Transaction | Gas used | Gas limit |
|---|---|---|---|
| 940 | `0x6705c26fd83d8000ea3ad15ef67170c6a92eb22d2d651edaf384e3cbd78594af` | 6,815,527 | 199,970,820 |
| 1,880 | `0x24b9439358573014c78f284905df2ec1f14620d156d0ffc8d4e8dcdcbce08d7f` | 6,802,387 | 199,970,820 |
| 2,820 | `0x07f68ab42d768e983d4c03f6094794364cee332dc64bff0544c0ecb8209763fe` | 6,805,897 | 199,970,820 |
| 3,760 | `0x200f45a3ce9f10acc063cdcc1205bb94a00fd8fe05201f978aab73ff426994a3` | 6,810,055 | 199,970,820 |
| 4,096, pays | `0xda79bc95e9bcc03f1803676f4c595e358a98a60092e96d1ed1db2cf81c62171b` | 2,608,156 | 71,929,880 |

## What went wrong on the way (none of it a contract bug)

1. **First smoke run stopped at its fifth transaction.** The order with a 5-minute deadline was sent after that deadline: the script now simulates 39 transactions against a slow public RPC before sending, which took longer than 5 minutes. The contract refused it with `DeadlinePassed` (transaction `0x5e5e16ed42633290f6f4a821b80dd46df23ccc7e01a21cbb0d8a9b29d18a6bba`, status 0). Orders 1 and 2 are left over from that run. Fix: the script's default short deadline is now 15 minutes, and `DEPLOY.md` says why.
2. **Two further attempts failed before sending anything**, with RPC errors ("could not instantiate resolved fork environment", then a revert during simulation that did not reproduce). The same script then simulated cleanly and the full run below went through.

## Smoke run transactions (`script/Smoke.s.sol`, 39 transactions, all receipt status 1)

In sending order:

1. `approve` `0x7fb3483f6e622e76cb7052a2f9c14d62d63e628406c7e5af62054941bd94fcb9`
2. `createOrder` `0xb74e216dbf2bd65c543ef18c70a36e76848dc376d1a29e89e260a6193f7fd915`
3. `deliver` `0xa3be213f3275c0f95e7938272b8456e9c33af166975ba6aea314bff94d524e37`
4. `createOrder` `0x7798a90062d9775a8faaf0ee376a9ce7156650f0bf2796e7a71b62d7a5dda64d`
5. `createOrder` `0x9eeb6bce129857491bc305621fe55ecad4f25a74bf9462c6df1368e508078e52`
6. `createStatefulOrder` `0xabd29d70306716c1d0d65f1af49e0c59ffaa150690a2209ab4a6dddfd012025f`
7. `deliver` `0x672fd406ad6a39acf190d988c35a329c672bba87a5522406ddee05c77f6d9e97`
8. `createStatefulOrder` `0x52cba7c639f6088131c884896200de151f82898f91884a7ffa9bdfcefb4fb319`
9. `createPiecedOrder` `0x235ad99f94d43a774f345e28efc2f616a861d51d351a16e876661d3e0c305ac3`
10. `deliverPiece` `0x9ca5d2f6d27b661b7632288dda46f1f07d6d207a5fc1bb1403a79ad3bd008c59`
11. `deliverPiece` `0x364e2d76ee3f4a9eb6957d618769165dca68848c99ea0455fb6f48688664349b`
12. `createPiecedOrder` `0x946ab89edebcd76021e5be33b6ff12c4522f749a9b8d21aeeaf156a99844cd2a`
13. `deliverPiece` `0x78e3c915b98ec472abfe48079f65258b59e82656e1e267f2a050ac4e8e7707a0`
14. `createPiecedOrder` `0x0f66303efffa3784e59f20b1c5d97a0f2f1f6e8555f41c85a76dedf0db4988cf`
15. `deliverPiece` `0xe177cf65d2f9c559002a955b61af249786af71dd5e489c4e55bc08e94ed79dd0`
16. `createPiecedOrder` `0x54acd391a846a020ab9766e82de47d43f55e26eaa27c642e57851c0dd8174e59`
17. `createPiecedOrder` `0x22c61d796ba0be2b919dce70e16eb5999fe7ef412f57dfcdb22536002b55415e`
18. `createPiecedOrder` `0x64e568bfc0b683337668315abe787b1fc01c7fbfc1b8621d03054c68ab348779`
19. `deliverPiece` `0xf57e02361122fd616bbb756da2639fe9ef0845ac3be1be470b6fb545f73cfa31`
20. `deliverPiece` `0x466323de26de568bb4f9e2d5cf39fa601ecfcb8d68fcad883ca0fd54e6d4430c`
21. `deliverPiece` `0x3bfb965c6961238b599a22e761d2d8d2f392c3c2bdcadbec281d1d6d428b0b0d`
22. `deliverPiece` `0xe176fe1532ac319d9a1b0e4b54369092584bc1f52df78ae0ed33e1838dbc8298`
23. `deliverPiece` `0x117b39905be36bddeb9fd4de58cdd241141b7818e285b0dce8ac11b86a62c96f`
24. `deliverPiece` `0x62a01ec7656b40857a02bd84d916774ae44539101d79199a34c9b805bc5c8217`
25. `mint` `0x383080fbbc73ad0fda535acf7f63811702fd9e76d6ce6688abea2a5f0de9f8e1`
26. `deliverTop` `0x43f41db605e9e4e6c34f416e5c135c07853c00e83fd4b4bfa6155b579f6822c0`
27. `mint` `0xe9b7557e5aeb7ad00b50772f85924ee671f9c6b7b4a97fdaa9dfde7dd3fb2533`
28. `mint` `0xef949f2b1036a2d51027572a18b5180d1257e5d28b8dc17a7bfac167ec93dab0`
29. `setCircuit` `0xd68122463d7ba8f9099c495381a49ce9f60e10c95b7d20290d47eb2852f7fcff`
30. `setOuts` `0xcb63356a4f6e51a18b791ec895a9ee1941595c7cdee865563c5bf6b906b92bed`
31. `createPiecedOrder` `0x04f6d50b255818669e1990ae8d92338125d881ed68ac22ac918d112846e70eb5`
32. `deliverPiece` `0xa335469e0a3ec93bb636ff58bb9000f4166123185a7edbafa7686231df18af6b`
33. `deliverPiece` `0x34a91ae6872926955ddd691962ff48128110e1cc15cc1f5f1d688bd64b7a21b9`
34. `deliverPiece` `0x13a665151d5f88942dcaa32ff2539017497c8522ff71adccc6461f509873eabe`
35. `deliverPiece` `0x80004d0fa29eb31d3baf7941239f0326803320afb269d82786f229c32c356fd1`
36. `deliverPiece` `0x75ceac465ebe4e42f4e726c4aabaacf19d3149f90e435ea2e62f3d3b88097095`
37. `deliverPiece` `0xc3350bbb3e68288e138b1309e98086644dae50c1bc00ae278980d4e80f8f9452`
38. `mint` `0xa79e814d6a50e8393b2deebfc54af2cc18e881e05fe56576642de1224eeae621`
39. `deliverTop` `0x3d43443a5fdd25543dc054b672a80e72b7c594b0bbb68ea5138ae2e45bfc6ef5`

Testnet block at the time of writing: about 46,802,599.

## Limits

- Stand-in circuits only, with 4 gates or fewer each (see above).
- Source not verified on OKLink (no API key yet); verifying a contract with three linked libraries there is untested.
- The page's no-wallet read test passed against this contract for orders 1, 2 and 5. The page's pieced-order and top-circuit views were tested on a local chain only.
- No order was created through the page on testnet with a real wallet.

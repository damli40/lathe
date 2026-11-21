# Lathe with builder-declared per-case gas, on X Layer testnet: deploy, smoke run and crank

Date: 2026-11-21. Chain: X Layer testnet, chainId 1952, RPC `https://testrpc.xlayer.tech/terigon`. Code: commit `189a041`. This is the code intended for mainnet.

## What this proves, and what it does not

- **Proves:** on a real public network, the final contract (all order types, plus the per-case gas a builder can declare at delivery, see `2026-11-21-case-gas-fix.md`) passes its full smoke run: 46 transactions, all status 1. The new case is order 13: a stand-in circuit whose first case in a transaction costs extra was delivered with 600,000 gas declared per case, checked in five transactions of 7, 1, 13, 2 and 41 cases, and paid. Splitting a check that way is what used to let a stranger get an honest circuit rejected. The crank then checked a 4,096-case piece to Paid in 5 transactions, and a late order was refunded.
- **Does not prove:** anything about real TapeOut circuits; every circuit here is a stand-in (TapeOut is not on testnet, `2026-11-20-preflight.md`). The fix was shown on real TapeOut on a copy of mainnet (`test/fork/CaseGasSplit.fork.t.sol`, `test/fork/CaseGasTop.fork.t.sol`, `2026-11-21-case-gas-fix.md`). The opposite case (the same circuit delivered without a declared value being rejected under a split) was not sent on testnet; it is shown on a local chain and on the mainnet copy. Wrong deliveries in steps (b), (e), (h) and (m) were refused in the script's simulation and not also sent as failing transactions. Mainnet behaviour of 200M-limit transactions is not shown by this run.

This contract replaces `0xde9A8a4b40d490C9Eff56157129902dc1d3D00b7` (`2026-11-21-testnet-final.md`), which stays on chain. The page (`web/config.js`) now points at the new address.

Deployer, buyer and builder in every order: the throwaway testnet wallet `0x5a15Dca0F83Ae5878fD20eF0f9444b59Dbef03a0`. Fee: 1%.

## Deployed contracts

| Contract | Address | Deploy tx |
|---|---|---|
| LatheOrders (23,234 bytes) | `0xaf1e479DDA53382D22BE5Dc19c1cc44C1472B6E3` | `0x73fb93a08c43c5d3d815992a202bb1b9d6864d0f947409a9d84b25a2796224fc` |
| NetlistLib (library) | `0x3282dA37Ca907b87f5911096EF80f3528F1A52EA` | `0x45b7818ae2baac1bd11750e08798ff007c10e0729b928f5e71a85c1735bd7c27` |
| LatheChecks (library) | `0x775aD1c2928720f67a4D0ff947829552D46deF60` | `0x6cde5c23ec1a23ff1b368ac28e35be48245bb4c3a0657cb3c3835d696c739a1b` |
| LatheReads (library) | `0xDEcFd5eA065ffC687d34930be784D1361842344F` | `0xa537ce226c5b06426bb1a7537ab07c5cc05d67590a56db4e35bd376e6efa4241` |
| MockUSDT | `0x023870C9B5bA1E4d62e5095e6BC986bc76C97A05` | `0xc9cd542112068f0142bb7660bc961214282d3e203b13db2580b09019c2c8b9ea` |
| MockFactory | `0xA37e78c6b42f29b543973132384C4583F6211c39` | `0xcde708f9e0930c786770bd24a888cbfccb77cfae12ae4ae77f8140fd77a5145d` |
| MockProcessor | `0xC2D6fCd615973cD126B29e7091Af6Cf9C462D58d` | `0xa9f9b457dffe99f467146bf3a77877090d27f8e7f28687d1f7524642913c5772` |
| FormulaProcessor | `0x7C2080903a621581292B2C1f7B9994796e49a8fe` | `0x3943e27d1385ac7a3caee28cad10070be478b66f129285105d9d7848f9db9ce8` |
| RefProcessor | `0xA71f59c701799b74E838F5dcece62dD52c84b762` | `0xda46f47d96ada24f03ce3cebdf736afa015e2f052a9845cd96c15ee91b7b15d4` |

All 34 deploy transactions have receipt status 1.

## Orders on chain after the run (statuses read back with `orders(id)`)

Status: 0 Open, 2 Paid, 3 Refunded.

| Order | What it is | Status |
|---|---|---|
| 1 | 2-input XOR, honest circuit | 2 Paid |
| 2 | XOR order; the wrong circuit was refused in simulation | 0 Open |
| 3 | Order with a short deadline, refunded after it | 3 Refunded |
| 4 | One-bit memory order with input names, honest toggle | 2 Paid |
| 5 | Memory order; the wrong toggle was refused in simulation | 0 Open |
| 6 | Two pieces: "a plus b", then "sum is at least c" | 2 Paid |
| 7 | Two pieces; piece 0 passed, the wrong piece 1 was refused in simulation | 0 Open |
| 8 | One piece, "a is at least b" on two 6-bit numbers, 4,096 cases, checked by the crank | 2 Paid |
| 9 | Daily-cap shape with explicit wires, paid when the last piece passed | 2 Paid |
| 10 | The same rule as "needs a top": paid when the top circuit was delivered | 2 Paid |
| 11 | "Needs a top"; a wrong-shape top and a wrong-bytes top were refused in simulation | 0 Open |
| 12 | A top made of 6 one-gate XOR pieces (6 references) | 2 Paid |
| 13 | A circuit with a costly first case, delivered with 600,000 gas declared per case, checked as 7 + 1 + 13 + 2 + 41 cases | 2 Paid |

Refund of order 3: `0xbc09af8ef8e06950bbc401521e84229237d7851b47edb8481781060b4aa684a6`, status 1.

## Reads on the live contract (free calls, no wallet)

| Call | Answer |
|---|---|
| `caseGasOf(13)` | 600,000: the value the builder declared |
| `caseGasOf(1)` | 160,000: nothing declared, so the standard figure for a 4-gate circuit (100,000 + 15,000 × 4) |
| `ruleOf(10)` | RefProcessor `0xA71f59…b762`, circuit 1: the top circuit is the order's rule |
| `run(12, 0x07)` with 3,000,000 gas | `0x01`: parity of three set bits, through a top with 6 references |

## The crank (order 8)

`node scripts/crank.mjs --lathe 0xaf1e479DDA53382D22BE5Dc19c1cc44C1472B6E3 --order 8 --piece 0 --batch 1000 --rpc https://testrpc.xlayer.tech/terigon --chain-id 1952 --keystore <file> --password-file <file>`: 5 transactions in 83.9 seconds.

| Cases done | Transaction | Gas used | Gas limit |
|---|---|---|---|
| 940 | `0x94f2ec4000b101bf6c4d8f7cbe12796d3a7dcd7ebe669fce51de14964f789259` | 6,815,325 | 199,970,820 |
| 1,880 | `0xc4cf398f602d63b2469db6e147e25144b42e9e42c189b46869bb94302b7244d1` | 6,802,185 | 199,970,820 |
| 2,820 | `0xe965a02f877137f26dca36380d6c35c787479a5631b4c4f3779d46dfaba7c10b` | 6,805,695 | 199,970,820 |
| 3,760 | `0xa954e6a845201ae867bf341d1a080dcebe87b820707b595eb87b61e6d2504e91` | 6,809,853 | 199,970,820 |
| 4,096, pays | `0xca6e4887f59658d8a0c142c0994f183afeaf94a3a279708e056aaed73589e5c6` | 2,607,954 | 71,929,880 |

## Smoke run transactions (`script/Smoke.s.sol`, 46 transactions, all receipt status 1)

In sending order:

1. `approve` `0xa430f37f15872e76b9ee04e6620388f854bf63fc7c0969c9a818dd7463c11269`
2. `createOrder` `0x5c7b287cb57beea505f32e52f1375fa079303092cb66c05b90ee097ef1a42237`
3. `deliver` `0xe9ec50dbfdde39c18c11c9d6268b85633cbaebfbc15d74a4702c63934e892b0b`
4. `createOrder` `0x7c7cb712b0a000ef60514e3e7948e00bb5ee0f21c56e892baf9c12060577953c`
5. `createOrder` `0x0d82bf62355712a4f015db17acc554d40c16a2608799da448484f65e0160237b`
6. `createStatefulOrder` `0xe2dad5cc6062d9982e066177d853d1da18091ade9f08396602dd9e67e98617e5`
7. `deliver` `0xde01710429f1b018a5944c5c438e5f69a1cc68778d2642453d55cb6def2c4b68`
8. `createStatefulOrder` `0x22cf1f289ada99bb38192f6fbece4bb18b6ef05724d6e14c536ee2f66f922227`
9. `createPiecedOrder` `0x5b9113e83608f3a7ab5c769bff54dd142232d3d388d7d2a455fdf474f970222f`
10. `deliverPiece` `0x39d831b8d06196500d542e38fc29b3befabb2a0054a538b4dbf20759889e4427`
11. `deliverPiece` `0x2062432f36092709196db761b58b5e3bc6c9a9c1d3cbde3927fbccb02e718b25`
12. `createPiecedOrder` `0x197fbaa57eb948914ba0c04fb8771bd0299acf98d82324701783642df8799b5e`
13. `deliverPiece` `0xcb1339a79d7045b27c59ae049ef7fc335fb6dcae4c2b6773b63809af180a22ba`
14. `createPiecedOrder` `0xfb94fa5dbb07bd0c34ea5e2e52e66f58c535aecf3247522fe1213a64fab7ae01`
15. `deliverPiece` `0xc26d5fd8a36cfb8af86c995a28683db3ff637b0da1c3e2365fb07e47121753bb`
16. `createPiecedOrder` `0x4bf203650ac16b48fc03b076e31615a1bf13c618a2568e54b687f3a074f9ab41`
17. `createPiecedOrder` `0x836b1266cb732491d8f1e663be8d30d4a8cc535747c9f4c80867713ac8390f0a`
18. `createPiecedOrder` `0x4da0a2b8ae4c7345f7d032ccd5ef078ab334b41203a4817ddd62c59db84a4dbe`
19. `deliverPiece` `0xc082057e726c6e9bbe1ba3e63235c703d39d97352e4a2ec21a1f4b743208a010`
20. `deliverPiece` `0xfd2a20202d0a1828b0352a8ff2d42fbcc29d3eb6b7c963513459f6d7ca0ab3af`
21. `deliverPiece` `0x840586ad0c358bd2527a4860f736d921f3055e4cc3886132dae5e3e683e7095d`
22. `deliverPiece` `0x02dc5c5745051485bc74494393dca6f4db0f2d9da5966d216c896051c0ee7a08`
23. `deliverPiece` `0xdbc051c18e3e430abcbd336a926e5c635bece84da5a192fc1e23444083db2387`
24. `deliverPiece` `0xd291b70ee6362a1bce7b7f20bd48b270f543c1b32d143ec484ae43ade517fdc2`
25. `mint` `0xa3110acf6c47cf3dba0a99bd8add08adc40c7dc2607f341a1ba51305d4baefac`
26. `deliverTop` `0x3e9a7c3474a3175566a3e0b2406de06703a4cbd60672c376168f1b8ff91dd373`
27. `mint` `0x364623c751a55bf2fb2d66a0461a5a37ad53ea558a9d1b854f01709ffa16a287`
28. `mint` `0xedb6ad87d26f52e34ca40b7779421b852938ca6392fc80a0c2405b4600d3e009`
29. `setCircuit` `0x6c4e0cdad50471f732940582c82ccf2cc93bcc2ce4c2bd4cd56410077257cefa`
30. `setOuts` `0x7b4ed4760dd5808fb8f917d6d08ac97d4a710a49b23fac22a599255ae19a3164`
31. `createPiecedOrder` `0x2a105ef8960795dd77086832dd99eed2cb384d43c58c1714c15a132172210399`
32. `deliverPiece` `0x0efeb5c420a4bcf97ede23ee586627d81133c355598398e1bd2e12a942f2d7b2`
33. `deliverPiece` `0xa379495e905bda185c785827c9c2669ba20e2dc6a87edced34c9549accf2dd8e`
34. `deliverPiece` `0xd61eee21435f83cdc613dd5a61d73261e7ef492ee2f1778a035c8d424f0ce5f7`
35. `deliverPiece` `0x90c92c7d75830249d382fe2671e71e398e743ab78507db2960ce4d53cb4d1278`
36. `deliverPiece` `0xd02d1412d8bfe0e174efd82fe681db58ece6c599a47c9baa542de86453c06a51`
37. `deliverPiece` `0x7fc080b57df730578a515840caed53c37c94ba34f18de137c0b4fcade960fa94`
38. `mint` `0x6f5c47a6a74e4c0ff490a3bc2e66ab5b9f5518cc8067d560e34a8e55bce5c6b0`
39. `deliverTop` `0x71b011b5c7bbb1eec5351f893b7d7c8456eff227e0114c7417a2cf405288889e`
40. `createOrder` `0x0e6f75f6b39d4f928bfe21bfc4bae81cc27bbb7d505aa87d7d363ce221463429`
41. `deliver` `0x0a1f26b7c2fc3ea661637e9725129415ee23b9ac214f836bcd8cf43e562a6286`
42. `check` `0x432dc40b396e6068b02664b57fc18deaa62b7b5c7e6cb4b2da6a871bc65c68f5`
43. `check` `0x05aad038579fd6f0fe15fcecb138211e0dbf62fcd9ab594fc219d2c69394f0f6`
44. `check` `0x90f36dafe562c432ac65d329b06dd9badd4b58d44d818b7bcd29b5e8ebcbf1f3`
45. `check` `0xc71573234a84ce672d627efbafc21a35357a1d70cf3a92c306e774fa13cbe5ea`
46. `check` `0xf5c8315a97a697811575ec9d580fcf58d30de3b382ffdc3b1e1da79e4adbbc87`

Testnet block at the time of writing: about 46,817,523.

## Limits

- Stand-in circuits only (see above).
- Source not verified on OKLink (no API key yet); verifying a contract with three linked libraries there is untested.
- The page's no-wallet read test passed against this contract for orders 1, 2 and 3. The page's delivery flow with a declared value was tested on a local chain only.
- No order was created through the page on testnet with a real wallet.

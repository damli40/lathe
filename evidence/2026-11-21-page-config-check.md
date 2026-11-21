# The order page's testnet settings pointed at the Nov 20 deploy

Date: 2026-11-21. Chain: X Layer testnet, chainId 1952, RPC `https://testrpc.xlayer.tech/terigon`. Fixed in commit `d543858`.

## What this settles

- **The bug:** when the testnet contract was redeployed (`2026-11-21-testnet-case-gas.md`), only `lathe` in `web/config.js` was updated. The token, factory and processor still named the Nov 20 deploy (`2026-11-20-testnet-v0.md`).
- **What it broke:** the page reads the real token and factory from the contract, so no money could go to the wrong token. But every testnet visitor saw a false notice, "The token in this page's settings is not the one the contract uses", and the delivery form pre-filled processor `0xe2995d1B…63C1`, which the new factory does not accept.
- **The fix:** config now names MockUSDT `0x023870C9…7A05`, MockFactory `0xA37e78c6…1c39` and MockProcessor `0xC2D6fCd6…D58d`, the addresses in `broadcast/DeployTestnet.s.sol/1952/run-latest.json`.
- **What would have caught it:** `node web/test/config-live.mjs`, new. For each network with `lathe` set, it reads `usdt()` and `factory()` from the contract and `isCPU(processor)` from that factory, and fails on any mismatch.
- **Does not cover:** mainnet, which has no `lathe` address yet. Run the check again after the mainnet deploy (DEPLOY.md section 5).

## Readings

Live reads on 2026-11-21 with `cast call`:

| Read | Answer |
|---|---|
| `usdt()` on `0xaf1e…B6E3` | `0x023870C9B5bA1E4d62e5095e6BC986bc76C97A05` |
| `factory()` on `0xaf1e…B6E3` | `0xA37e78c6b42f29b543973132384C4583F6211c39` |
| `isCPU(0xC2D6…D58d)` on the new factory | `true` |
| `isCPU(0xe299…63C1)` (the old processor) on the new factory | `false` |

`node web/test/config-live.mjs` on the old config (from `47055a0`): `CONFIG FAIL testnet` naming all three mismatches, exit 1. On the fixed config: `CONFIG PASS testnet: token, factory and processor match 0xaf1e479DDA53382D22BE5Dc19c1cc44C1472B6E3`, exit 0.

## Test run the same day

| Command | Result |
|---|---|
| `forge test --no-match-path 'test/fork/*'` | 239 passed, 0 failed |
| `forge test --match-path 'test/fork/*'` (X Layer mainnet copy) | 36 passed, 0 failed |
| `node --test web/test/` | 53 passed, 0 failed |
| `node web/test/readonly.mjs` (live testnet, no wallet, after the fix) | READONLY PASS: orders 1, 2, 3 = Paid, Open, Refunded |

These counts are the "328 automated tests" on the page and in the README.

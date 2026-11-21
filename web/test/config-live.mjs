// Live check that web/config.js matches the deployed contract, for every network whose `lathe` is set.
// The page reads the real token and factory from the contract, so a stale config cannot move money to the wrong
// token. But a stale config still breaks the page: it shows a false "token is not the one the contract uses"
// notice, and it pre-fills a processor the contract's factory does not accept. This happened on Nov 21 2026 when
// the testnet contract was redeployed and only `lathe` was updated.
// Read-only: only eth_call goes to each network's public RPC. Run from the repo root: node web/test/config-live.mjs
// Run it again after filling in NETWORKS.mainnet.lathe (DEPLOY.md section 5).
import { NETWORKS } from "../config.js";

const word = (hex) => "0x" + hex.slice(-40).toLowerCase();
const pad = (addr) => addr.toLowerCase().replace(/^0x/, "").padStart(64, "0");

async function call(rpc, to, data) {
  const res = await fetch(rpc, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "eth_call", params: [{ to, data }, "latest"] }),
  });
  const j = await res.json();
  if (j.error || typeof j.result !== "string" || j.result.length < 66) {
    throw new Error(`eth_call to ${to} failed: ${JSON.stringify(j.error ?? j.result)}`);
  }
  return j.result;
}

let failed = 0;
let checked = 0;
for (const n of Object.values(NETWORKS)) {
  if (!n.lathe) {
    console.log(`${n.key}: lathe not set, skipped`);
    continue;
  }
  checked++;
  const problems = [];
  const token = word(await call(n.rpc, n.lathe, "0x2f48ab7d")); // usdt()
  const factory = word(await call(n.rpc, n.lathe, "0xc45a0155")); // factory()
  if (n.token && n.token.toLowerCase() !== token) problems.push(`token is ${n.token}, contract uses ${token}`);
  if (n.factory && n.factory.toLowerCase() !== factory) problems.push(`factory is ${n.factory}, contract uses ${factory}`);
  if (n.processor) {
    const ok = BigInt(await call(n.rpc, factory, "0x5f5a364f" + pad(n.processor))); // isCPU(address)
    if (ok !== 1n) problems.push(`processor ${n.processor} is not accepted by the contract's factory ${factory}`);
  }
  if (problems.length) {
    failed++;
    console.error(`CONFIG FAIL ${n.key}: ${problems.join("; ")}`);
  } else {
    console.log(`CONFIG PASS ${n.key}: token, factory${n.processor ? " and processor" : ""} match ${n.lathe}`);
  }
}
if (checked === 0) console.log("no network has lathe set");
process.exitCode = failed ? 1 : 0;

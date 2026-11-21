// Mainnet-fork end to end: anvil forks X Layer mainnet (read-only against the public RPC), we deploy LatheOrders
// with a mock token on the fork, and the page delivers the REAL TapeOut XOR circuit (processor 0x839b...574e, id 1).
// The page's mainnet entry gets only the LatheOrders address (and the mock token, since USD₮0 cannot be minted):
// the same one-address change a real mainnet deploy needs. Nothing is sent to the real network.
// Run from the repo root: node web/test/fork.mjs
import { execFileSync } from "node:child_process";
import { serve, playwright, rpc, shimSource, assert } from "./lib.mjs";
import { startAnvil, forgeCreate, ANVIL_ACCOUNT0 } from "./anvil.mjs";
import { openTool, connect, createOrder, openOrder, waitStatus, deliver, statusText } from "./flows.mjs";

const FACTORY = "0x1f09DAeFA827f02CBb40967cc91b259763760761";
const XOR_PROC = "0x839bdD6fa7A66416A609A735e11DE5411B98574e";
const FORK_BLOCK = Number(process.env.FORK_BLOCK || 76432018); // same block as test/fork/XorFork.t.sol
const SHOTS = process.env.SHOTS_DIR || null;

const anvil = await startAnvil({ port: 8548, forkUrl: "https://rpc.xlayer.tech", forkBlock: FORK_BLOCK });
let browser;
let server;
try {
  const cast = (...a) => execFileSync("cast", [...a, "--rpc-url", anvil.url], { encoding: "utf8" }).trim();
  assert(cast("chain-id") === "196", "fork reports chain 196");
  const token = forgeCreate(anvil.url, "test/mocks/MockUSDT.sol:MockUSDT");
  const lathe = forgeCreate(anvil.url, "src/LatheOrders.sol:LatheOrders", [FACTORY, token, ANVIL_ACCOUNT0, "100"]);
  cast("send", token, "mint(address,uint256)", ANVIL_ACCOUNT0, "1000000000", "--unlocked", "--from", ANVIL_ACCOUNT0);
  const owner = cast("call", XOR_PROC, "ownerOf(uint256)(address)", "1");
  console.log("LatheOrders on fork:", lathe, "mock token:", token, "XOR circuit owner:", owner);
  await rpc(anvil.url, "anvil_impersonateAccount", [owner]);
  await rpc(anvil.url, "anvil_setBalance", [owner, "0x8AC7230489E80000"]);

  server = await serve();
  const { chromium } = await playwright();
  browser = await chromium.launch();
  const ctx = await browser.newContext({ bypassCSP: true, viewport: { width: 1440, height: 900 }, colorScheme: "dark" });
  await ctx.addInitScript({ content: `window.LATHE_TEST_CONFIG = ${JSON.stringify({ mainnet: { rpc: anvil.url, lathe, token, parallelReads: false } })};` });
  await ctx.addInitScript({ content: shimSource(anvil.url, ANVIL_ACCOUNT0) });
  const page = await ctx.newPage();
  const errors = [];
  page.on("pageerror", (e) => errors.push(e.message));

  await openTool(page, server.url + "?lang=en&net=mainnet");
  await connect(page);
  const id = await createOrder(page, { preset: "xor", amount: "10", builder: owner });
  await page.evaluate((a) => window.__shim.setAccount(a), owner);
  await openOrder(page, id);
  await deliver(page, { processor: XOR_PROC, circuit: 1 });
  await waitStatus(page, 2);
  assert((await statusText(page)) === "Paid", `order ${id} shows Paid after delivering the real XOR circuit`);
  const gates = await page.locator("#order-view .facts").nth(1).textContent();
  assert(/4 of 4/.test(gates), "delivered circuit shows 4 of 4 cases checked");
  const bal = cast("call", token, "balanceOf(address)(uint256)", owner);
  assert(bal.startsWith("9900000"), `builder received 9.9 tokens (10 less the 1% fee): ${bal}`);
  if (SHOTS) await page.locator("#order").screenshot({ path: `${SHOTS}/fork-paid.png` });
  assert(errors.length === 0, "no page errors" + (errors.length ? ": " + errors.join(" | ") : ""));
  console.log("FORK PASS: real XOR circuit delivered through the page, order Paid");
} catch (e) {
  console.error("FORK FAIL:", e.message);
  process.exitCode = 1;
} finally {
  await browser?.close();
  server?.close();
  anvil.stop();
}

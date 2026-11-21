// End-to-end on a local anvil, no keys: deploy the testnet mocks with script/DeployTestnet.s.sol, serve web/,
// drive the page in headless Chromium with a window.ethereum shim that forwards to anvil.
// Proves: (a) XOR order + honest circuit 1 -> Paid; (b) XOR order + wrong circuit 2 -> refusal sentence and
// failing row, nothing sent; (c) short-deadline order, anvil time moved forward, refund -> Refunded.
// Run from the repo root: node web/test/e2e.mjs
import { serve, playwright, rpc, shimSource, assert } from "./lib.mjs";
import { startAnvil, deployMocks, ANVIL_ACCOUNT0 } from "./anvil.mjs";
import { openTool, connect, createOrder, openOrder, waitStatus, deliver, statusText } from "./flows.mjs";

const SHOTS = process.env.SHOTS_DIR || null;
const anvil = await startAnvil({ port: 8547, chainId: 1952 });
let browser;
let server;
try {
  const addrs = deployMocks(anvil.url);
  console.log("deployed on anvil:", JSON.stringify(addrs));
  server = await serve();
  const { chromium } = await playwright();
  browser = await chromium.launch();
  const ctx = await browser.newContext({ bypassCSP: true, viewport: { width: 1440, height: 900 }, colorScheme: "dark" });
  // bypassCSP: the page's CSP only allows the public RPC hosts; the test points the testnet entry at localhost.
  await ctx.addInitScript({ content: `window.LATHE_TEST_CONFIG = ${JSON.stringify({ testnet: { rpc: anvil.url, ...addrs, parallelReads: true } })};` });
  await ctx.addInitScript({ content: shimSource(anvil.url, ANVIL_ACCOUNT0) });
  const page = await ctx.newPage();
  const errors = [];
  page.on("pageerror", (e) => errors.push(e.message));

  await openTool(page, server.url + "?lang=en");
  await connect(page);

  console.log("(a) honest XOR circuit");
  const a = await createOrder(page, { preset: "xor", amount: "1" });
  await openOrder(page, a);
  await deliver(page, { circuit: 1 });
  await waitStatus(page, 2);
  assert((await statusText(page)) === "Paid", `order ${a} shows Paid`);
  const lastA = await page.locator("#last-action").textContent();
  assert(/builder was paid/.test(lastA), `message: "${lastA}"`);
  if (SHOTS) await page.locator("#order").screenshot({ path: `${SHOTS}/e2e-a-paid.png` });

  console.log("(b) wrong circuit");
  const b = await createOrder(page, { preset: "xor", amount: "1" });
  await openOrder(page, b);
  const sentBefore = await page.evaluate(() => window.__shim.sent.length);
  await deliver(page, { circuit: 2 });
  await page.waitForSelector("#deliver-box .msg.is-err", { timeout: 60000 });
  const msgB = await page.locator("#deliver-box .msg.is-err").last().textContent();
  assert(/Case 3/.test(msgB) && /refused/.test(msgB), `refusal sentence: "${msgB}"`);
  assert(await page.locator('tr.is-failed[data-case="3"]').count() === 1, "row for case 3 is highlighted");
  const flag = await page.locator('tr.is-failed[data-case="3"] td.flag').textContent();
  assert(flag === "Wrong answer here", `row flag: "${flag}"`);
  assert((await page.evaluate(() => window.__shim.sent.length)) === sentBefore, "no transaction was sent for the wrong delivery");
  assert((await statusText(page)) === "Open", `order ${b} stays Open`);
  if (SHOTS) await page.locator("#order").screenshot({ path: `${SHOTS}/e2e-b-refused.png` });

  console.log("(c) refund after the deadline");
  const now = Number(BigInt((await rpc(anvil.url, "eth_getBlockByNumber", ["latest", false])).timestamp));
  const soon = new Date((now + 180) * 1000);
  const p = (x) => String(x).padStart(2, "0");
  const local = `${soon.getFullYear()}-${p(soon.getMonth() + 1)}-${p(soon.getDate())}T${p(soon.getHours())}:${p(soon.getMinutes())}`;
  const c = await createOrder(page, { preset: "xor", amount: "1", deadline: local });
  await openOrder(page, c);
  const gate = await page.locator("#refund-gate").textContent();
  assert(/Refund opens at/.test(gate) && await page.locator("#refund-btn").isDisabled(), `refund is closed before the deadline: "${gate}"`);
  await rpc(anvil.url, "evm_increaseTime", [3600]);
  await rpc(anvil.url, "evm_mine", []);
  await page.click("#order-view .ov-head button");
  await page.waitForFunction(() => !document.querySelector("#refund-btn")?.disabled, null, { timeout: 60000 });
  await page.click("#refund-btn");
  await waitStatus(page, 3);
  assert((await statusText(page)) === "Refunded", `order ${c} shows Refunded`);
  const lastC = await page.locator("#last-action").textContent();
  assert(/Refunded 1 mUSDT/.test(lastC), `message: "${lastC}"`);
  if (SHOTS) await page.locator("#order").screenshot({ path: `${SHOTS}/e2e-c-refunded.png` });

  assert(errors.length === 0, "no page errors" + (errors.length ? ": " + errors.join(" | ") : ""));
  console.log("E2E PASS: paid, refused with failing row, refunded");
} catch (e) {
  console.error("E2E FAIL:", e.message);
  process.exitCode = 1;
} finally {
  await browser?.close();
  server?.close();
  anvil.stop();
}

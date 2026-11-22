// Read-only against the live X Layer testnet contract, no wallet installed: orders 1, 2, 3 from the smoke run
// (evidence/2026-11-21-testnet-case-gas.md) must show Paid, Open, Refunded. Also checks that mainnet opens on the deployed contract (footer address, no "not deployed" notice).
// Only eth_call / eth_getBlock reads go to the public RPC. Run from the repo root: node web/test/readonly.mjs
import { serve, playwright, assert } from "./lib.mjs";
import { waitStatus, statusText } from "./flows.mjs";
import { NETWORKS } from "../config.js";

const want = { 1: "Paid", 2: "Open", 3: "Refunded" };
let browser;
let server;
try {
  server = await serve();
  const { chromium } = await playwright();
  browser = await chromium.launch();
  const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 } }); // real CSP, no shim
  const page = await ctx.newPage();
  const errors = [];
  page.on("pageerror", (e) => errors.push(e.message));
  for (const [id, label] of Object.entries(want)) {
    await page.goto(`${server.url}?order=${id}&lang=en`);
    await waitStatus(page, null);
    const s = await statusText(page);
    assert(s === label, `order ${id} shows ${label} (got ${s})`);
    assert(await page.evaluate(() => typeof window.ethereum === "undefined"), "no wallet in this browser");
  }
  // order 2 is Open: the deliver and refund boxes say a wallet is needed or why refund is closed
  await page.goto(`${server.url}?order=2&lang=en`);
  await waitStatus(page, 0);
  const side = await page.locator("#order-view .ov-side").textContent();
  assert(/Connect a wallet to send this|Refund opens at/.test(side), "order 2 explains what is needed without a wallet");
  const wallet = await page.locator("#wallet-status").textContent();
  assert(/No wallet found/.test(wallet), `wallet line: "${wallet}"`);
  await page.goto(`${server.url}?net=mainnet&lang=en`);
  await page.waitForFunction(() => /X Layer mainnet/.test(document.querySelector("#tool-sub")?.textContent || ""));
  await page.waitForTimeout(1500);
  assert(!/Not on mainnet yet/.test(await page.locator("#order").textContent()), "mainnet no longer says it is not deployed");
  const foot = (await page.locator("#foot-mainnet").textContent()).trim();
  assert(foot === NETWORKS.mainnet.lathe && /^0x[0-9a-fA-F]{40}$/.test(foot), `footer shows the mainnet contract: "${foot}"`);
  assert(errors.length === 0, "no page errors" + (errors.length ? ": " + errors.join(" | ") : ""));
  console.log("READONLY PASS: live testnet orders 1, 2, 3 = Paid, Open, Refunded with no wallet");
} catch (e) {
  console.error("READONLY FAIL:", e.message);
  process.exitCode = 1;
} finally {
  await browser?.close();
  server?.close();
}

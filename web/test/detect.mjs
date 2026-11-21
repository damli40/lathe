// Feature detection through a busy node. The page asks the contract whether it takes a declared per-case gas
// (caseGasOf) and a top-run gas per piece (EVAL_GAS_PER_REF). Before the case-gas review, any error that was not a
// network error counted as "older contract" and was saved in local storage with no expiry: a JSON-RPC rate limit
// (-32005) on caseGasOf made the page say the new contract was old and send the three-argument deliver.
// Every request from the page goes through a proxy that can answer chosen reads itself. Proves:
//   (a) -32005 on caseGasOf(0): "could not read, try again", the tool stays off (no Deliver), nothing cached
//   (b) HTTP 429 on caseGasOf(0): the same
//   (c) -32005 on EVAL_GAS_PER_REF: the same
//   (d) the node answers again: Try again loads the tool, and only then is the (positive) result cached
//   (e) a real revert of caseGasOf (an older contract): the tool loads, the older-contract warning shows on a
//       delivery that needs a declared gas, and that negative is not cached (a reload reads it again)
//   (f) in an order view, -32005 on caseGasOf(id) or piecesOf(id): a read error with Try again, not a view with
//       the formula gas or "no pieces"
// Run from the repo root: node web/test/detect.mjs
import { execFileSync } from "node:child_process";
import { serve, playwright, shimSource, assert } from "./lib.mjs";
import { startAnvil, deployMocks, ANVIL_ACCOUNT0 } from "./anvil.mjs";
import { startProxy } from "./proxy.mjs";
import { connect, createOrder, openOrder, waitStatus, T_LONG } from "./flows.mjs";

const sig = (s) => execFileSync("cast", ["sig", s], { encoding: "utf8" }).trim().toLowerCase();
const CASE_GAS_OF = sig("caseGasOf(uint256)");
const PER_REF = sig("EVAL_GAS_PER_REF()");
const PIECES_OF = sig("piecesOf(uint256)");
const RATE_LIMIT = { code: -32005, message: "request rate exceeded" };
const REVERT = { code: 3, message: "execution reverted" };

const anvil = await startAnvil({ port: 8561, chainId: 1952 });
const proxy = await startProxy(anvil.url, 8562);
let browser;
let server;
let page;

/** Answer eth_call to `selector` (and eth_estimateGas, which viem does not use for reads) with `reply`. */
function answerCalls(selector, reply) {
  proxy.st.forced = 0;
  proxy.st.answer = (m) => (m.method === "eth_call" && String(m.params?.[0]?.data || m.params?.[0]?.input || "").toLowerCase().startsWith(selector) ? reply : null);
}

const infoKeys = (p) => p.evaluate(() => Object.keys(localStorage).filter((k) => k.startsWith("lathe.info")));

async function loadFailed(p, url) {
  await p.goto(url);
  await p.waitForFunction(() => document.querySelector("#tool-notice.is-error, .notice.is-error"), null, { timeout: T_LONG });
  return (await p.locator(".notice.is-error").first().textContent()).trim();
}

try {
  const addrs = deployMocks(anvil.url);
  const L = addrs.lathe;
  const P = addrs.processor;
  server = await serve();
  const { chromium } = await playwright();
  browser = await chromium.launch();
  const ctx = await browser.newContext({ bypassCSP: true, viewport: { width: 1440, height: 900 } });
  await ctx.addInitScript({ content: `window.LATHE_TEST_CONFIG = ${JSON.stringify({ testnet: { rpc: proxy.url, ...addrs, parallelReads: true } })};` });
  await ctx.addInitScript({ content: shimSource(anvil.url, ANVIL_ACCOUNT0) });
  page = await ctx.newPage();
  const errors = [];
  page.on("pageerror", (e) => errors.push(e.message));
  const url = server.url + "?lang=en";

  for (const [name, sel, reply] of [
    ["(a) -32005 on caseGasOf(0)", CASE_GAS_OF, RATE_LIMIT],
    ["(b) HTTP 429 on caseGasOf(0)", CASE_GAS_OF, { http: 429 }],
    ["(c) -32005 on EVAL_GAS_PER_REF", PER_REF, RATE_LIMIT],
  ]) {
    console.log(name + ": could not read, nothing cached, no Deliver");
    answerCalls(sel, reply);
    const t = await loadFailed(page, url);
    assert(proxy.st.forced > 0, `the proxy answered ${proxy.st.forced} read(s) itself`);
    assert(/^Could not read from X Layer testnet: the node did not answer, or it is busy\. Nothing was sent\. Try again\./.test(t), `says it could not read: "${t}"`);
    assert(!/This contract is older/.test(await page.locator("body").textContent()), "never says the contract is older");
    assert((await page.evaluate(() => document.documentElement.dataset.toolReady)) !== "1", "the tool is not ready (no Deliver)");
    assert((await infoKeys(page)).length === 0, "nothing saved in local storage");
  }

  console.log("(d) the node answers again: Try again loads the tool and caches the positive result");
  proxy.st.answer = null;
  await page.locator(".notice.is-error button").first().click();
  await page.waitForFunction(() => document.documentElement.dataset.toolReady === "1", null, { timeout: T_LONG });
  const keys = await infoKeys(page);
  assert(keys.length === 1 && keys[0] === `lathe.info.v5.1952.${L.toLowerCase()}`, `one entry, keyed by chain id and address: ${keys}`);
  const saved = JSON.parse(await page.evaluate((k) => localStorage.getItem(k), keys[0]));
  assert(saved.hasCaseGas === true && BigInt(saved.perRef) > 0n, "saved: hasCaseGas true, perRef > 0");

  console.log("(e) a real revert of caseGasOf: older contract, warned, and not cached");
  await page.evaluate(() => localStorage.clear());
  answerCalls(CASE_GAS_OF, REVERT);
  await page.goto(url);
  await page.waitForFunction(() => document.documentElement.dataset.toolReady === "1", null, { timeout: T_LONG });
  assert(proxy.st.forced > 0, "caseGasOf reverted");
  assert((await infoKeys(page)).length === 0, "the negative is not saved");
  await connect(page);
  const o = await createOrder(page, { preset: "xor", amount: "1", nIn: 6, maxGates: 0 });
  await openOrder(page, o);
  await page.fill("#f-proc", P);
  await page.fill("#f-circ", "5");
  await page.click("#read-circuit");
  await page.waitForSelector("#deliver-box table.cmp", { timeout: 5 * T_LONG });
  const warn = await page.locator("#casegas").textContent();
  assert(/This contract is older and cannot take a declared gas per case/.test(warn), "the older-contract warning shows for a real revert");
  proxy.st.answer = null;
  await page.goto(url);
  await page.waitForFunction(() => document.documentElement.dataset.toolReady === "1", null, { timeout: T_LONG });
  const again = await infoKeys(page);
  assert(again.length === 1 && JSON.parse(await page.evaluate((k) => localStorage.getItem(k), again[0])).hasCaseGas === true, "the next load reads it again: hasCaseGas true");

  console.log("(f) order view: -32005 on caseGasOf(id) or piecesOf(id) is a read error, not a fact");
  for (const [what, sel] of [["caseGasOf", CASE_GAS_OF], ["piecesOf", PIECES_OF]]) {
    answerCalls(sel, RATE_LIMIT);
    await page.click("#tab-lookup");
    await page.fill("#f-lookup", String(o));
    await page.press("#f-lookup", "Enter");
    await page.waitForFunction(() => document.querySelector("#order-view .notice.is-error"), null, { timeout: T_LONG });
    const ve = (await page.locator("#order-view .notice.is-error").textContent()).trim();
    assert(/Could not read from the chain/.test(ve), `${what}: "${ve.slice(0, 140)}"`);
    assert((await page.locator("#order-view").getAttribute("data-status")) === null, `${what}: no order view shown`);
    proxy.st.answer = null;
    await page.locator("#order-view .notice.is-error button").click();
    await waitStatus(page, 0);
    assert(true, `${what}: Try again shows the order`);
  }

  assert(errors.length === 0, "no page errors" + (errors.length ? ": " + errors.join(" | ") : ""));
  console.log("DETECT PASS: rate limits and 429s are 'could not read', never 'older contract'; only positives are cached");
} catch (e) {
  console.error("DETECT FAIL:", e.message);
  process.exitCode = 1;
} finally {
  await browser?.close();
  server?.close();
  proxy.close();
  anvil.stop();
}

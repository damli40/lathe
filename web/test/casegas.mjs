// The declared per-case gas through the page, on a local anvil, no keys. DeployTestnet.s.sol sets up mock circuit 5:
// an honest 6-input parity that costs more on the first call of a transaction (it reads 50 storage slots that are
// cold at the start of each transaction), so every case but 0 needs more than its formula budget (475,000) when it
// runs first in a check transaction. Each anvil transaction and each eth_call / eth_estimateGas starts cold.
//   (a) new path: the page tests every case, proposes a declared per-case gas and delivers with the four-argument
//       deliver; checked through the page as 7, then 1, then the rest: Paid.
//   (b) old path: the same circuit delivered with the three-argument deliver (sent with cast, as an older page
//       would); checked through the page as 7, then 1: rejected at case 7, order back to Open.
//   (c) a case that needs more than even 100,000,000 gas: the page says so and does not deliver.
//   (d) a circuit whose cases fail in a test run: "could not test", never "fits"; the formula is used.
//   (e) a cheap circuit: "fits", delivered as before (no declared gas).
//   (f) the create form warns (does not block) when the deadline is more than 90 days away, in English and Chinese.
// Run from the repo root: node web/test/casegas.mjs
import { execFileSync } from "node:child_process";
import { serve, playwright, shimSource, assert, rpc } from "./lib.mjs";
import { startAnvil, deployMocks, ANVIL_ACCOUNT0 } from "./anvil.mjs";
import { openTool, connect, createOrder, openOrder, waitStatus, statusText, T_LONG } from "./flows.mjs";

const anvil = await startAnvil({ port: 8557, chainId: 1952 });
let browser;
let server;
let page;
const cast = (...a) => execFileSync("cast", [...a, "--rpc-url", anvil.url], { encoding: "utf8" }).trim();
const send = (...a) => cast("send", ...a, "--unlocked", "--from", ANVIL_ACCOUNT0, "--gas-limit", "25000000");
const first = (s) => s.split("\n")[0].trim().split(/\s+/)[0];

async function readCircuit(page, circuit) {
  await page.fill("#f-circ", String(circuit));
  await page.click("#read-circuit");
  await page.waitForSelector("#deliver-box table.cmp", { timeout: 5 * T_LONG });
}

/** One check transaction through the page: wait until it was sent, then until the view settled. */
async function check(page, n) {
  const before = await page.evaluate(() => window.__shim.sent.length);
  await page.fill("#f-checkn", String(n));
  await page.click("#check-btn");
  await page.waitForFunction((k) => window.__shim.sent.length > k, before, { timeout: T_LONG });
  await page.waitForFunction(() => {
    const s = document.querySelector("#order-view")?.getAttribute("data-status");
    const btn = document.querySelector("#check-btn");
    return s !== "1" || (btn && !btn.disabled && document.querySelector("#last-action"));
  }, null, { timeout: T_LONG });
}

try {
  const addrs = deployMocks(anvil.url);
  const L = addrs.lathe;
  const P = addrs.processor;
  server = await serve();
  const { chromium } = await playwright();
  browser = await chromium.launch();
  const ctx = await browser.newContext({ bypassCSP: true, viewport: { width: 1440, height: 900 } });
  await ctx.addInitScript({ content: `window.LATHE_TEST_CONFIG = ${JSON.stringify({ testnet: { rpc: anvil.url, ...addrs, parallelReads: true } })};` });
  await ctx.addInitScript({ content: shimSource(anvil.url, ANVIL_ACCOUNT0) });
  page = await ctx.newPage();
  const errors = [];
  page.on("pageerror", (e) => errors.push(e.message));
  await openTool(page, server.url + "?lang=en");
  await connect(page);

  console.log("(a) new path: test every case, declare, check split, Paid");
  const a = await createOrder(page, { preset: "xor", amount: "1", nIn: 6, maxGates: 0 });
  await openOrder(page, a);
  await page.fill("#f-proc", P);
  await readCircuit(page, 5);
  const kind = await page.locator("#casegas").getAttribute("data-kind");
  const declared = BigInt(await page.locator("#casegas").getAttribute("data-declared"));
  const say = await page.locator("#casegas").textContent();
  console.log("   page said: " + say.replace(/\s+/g, " ").slice(0, 400));
  assert(kind === "declare", `plan is "declare" (${kind})`);
  assert(declared > 475_000n && declared <= 700_000n && declared % 10_000n === 0n, `declared ${declared}: above the formula 475,000, rounded to 10,000`);
  assert(/most expensive is case \d+: it needs [\d,]+ gas/.test(say), "names the most expensive case and its gas");
  assert(/will deliver with [\d,]+ gas per case/.test(say), "says what it will declare");
  assert(/at most \d+ transaction\(s\), against \d+ with the standard gas/.test(say), "says what it means for check transactions");
  assert((await page.locator("#deliver-budget").textContent()).replace(/\D/g, "") === declared.toString(), "the gas each case gets is the declared figure");
  await page.click("#deliver-btn");
  await waitStatus(page, 1);
  assert(first(cast("call", L, "caseGasOf(uint256)(uint256)", a)) === declared.toString(), `on chain caseGasOf(${a}) = ${declared}`);
  assert(/recorded with [\d,]+ gas per case/.test(await page.locator("#last-action").textContent()), "message: recorded with the declared gas");
  assert((await page.locator("#check-budget").textContent()).replace(/\D/g, "") === declared.toString(), "the check box uses the declared gas");
  assert(await page.locator("#check-declared").count() === 1, "and says the builder declared it");
  await check(page, 7);
  await check(page, 1);
  assert((await page.locator("#order-view").getAttribute("data-status")) === "1", "case 7 alone passed");
  await check(page, 56);
  await waitStatus(page, 2);
  assert((await statusText(page)) === "Paid", `order ${a} Paid after a 7 / 1 / 56 split`);

  console.log("(b) old path: three-argument deliver, the same split rejects case 7");
  const b = await createOrder(page, { preset: "xor", amount: "1", nIn: 6, maxGates: 0 });
  send(L, "deliver(uint256,address,uint256)", b, P, "5");
  assert(first(cast("call", L, "caseGasOf(uint256)(uint256)", b)) === "475000", "formula 475,000 stored");
  await openOrder(page, b);
  await waitStatus(page, 1);
  await check(page, 7);
  await check(page, 1);
  await waitStatus(page, 0);
  assert((await statusText(page)) === "Open", `order ${b} back to Open: the honest circuit was rejected at the split`);
  const rej = await page.locator("#last-action").textContent();
  console.log("   page said: " + rej.trim());
  assert(/7/.test(rej), "the message names case 7");

  // (c), (d), (e): one-input orders (2 cases). Circuits on the mock processor, set up here (no access control).
  send(P, "setCircuit(uint256,address,uint32,uint32,uint32,uint32)", "20", ANVIL_ACCOUNT0, "1", "1", "0", "4");
  send(P, "setOuts(uint256,bytes[])", "20", "[0x00,0x01]");
  send(P, "setCaseGasCost(uint256,uint256,uint256)", "20", "1", "95000000"); // case 1 burns 95M
  send(P, "setCircuit(uint256,address,uint32,uint32,uint32,uint32)", "21", ANVIL_ACCOUNT0, "1", "1", "0", "4");
  send(P, "setOuts(uint256,bytes[])", "21", "[0x00,0x01]");
  send(P, "setRevertEval(uint256,bool)", "21", "true");
  send(P, "setCircuit(uint256,address,uint32,uint32,uint32,uint32)", "22", ANVIL_ACCOUNT0, "1", "1", "0", "4");
  send(P, "setOuts(uint256,bytes[])", "22", "[0x00,0x01]");

  console.log("(c) a case above even 100,000,000 gas: refused before sending");
  const c = await createOrder(page, { preset: "xor", amount: "1", nIn: 1 });
  await openOrder(page, c);
  await page.fill("#f-proc", P);
  await readCircuit(page, 20);
  assert((await page.locator("#casegas").getAttribute("data-kind")) === "tooBig", "plan is tooBig");
  const big = await page.locator("#deliver-box").textContent();
  assert(/Case 1 needs [\d,]+ gas\. Even the most gas a case can get \(100,000,000\)/.test(big), "says which case and why");
  assert(await page.locator("#deliver-btn").isDisabled(), "the deliver button is off");
  assert((await statusText(page)) === "Open", "nothing delivered");

  console.log("(d) cases that fail in a test run: could not test, never fits");
  const d = await createOrder(page, { preset: "xor", amount: "1", nIn: 1 });
  await openOrder(page, d);
  await page.fill("#f-proc", P);
  await readCircuit(page, 21);
  assert((await page.locator("#casegas").getAttribute("data-kind")) === "untested", "plan is untested");
  const un = await page.locator("#casegas").textContent();
  assert(/Could not test 2 case\(s\): 0, 1\./.test(un), `says which cases: "${un}"`);
  assert(!/fits the standard gas/.test(un), "never says they fit");
  assert((await page.locator("#casegas").getAttribute("data-declared")) === "0", "no declared gas");

  console.log("(e) a cheap circuit: fits, delivered as before");
  const e = await createOrder(page, { preset: "xor", amount: "1", nIn: 1 });
  await openOrder(page, e);
  await page.fill("#f-proc", P);
  await readCircuit(page, 22);
  assert((await page.locator("#casegas").getAttribute("data-kind")) === "formula", "plan is formula");
  assert(/fits the standard gas per case \(160,000\)/.test(await page.locator("#casegas").textContent()), "says it fits");
  await page.click("#deliver-btn");
  await waitStatus(page, 2);
  const sent = await page.evaluate(() => window.__shim.sent.at(-1));
  const threeArg = execFileSync("cast", ["sig", "deliver(uint256,address,uint256)"], { encoding: "utf8" }).trim();
  assert(String(sent.data || sent.input).startsWith(threeArg), `sent the three-argument deliver (${threeArg})`);
  assert((await statusText(page)) === "Paid", "Paid inline");

  console.log("(f) far deadline: a warning, not a block");
  await page.click("#tab-create");
  const fmt = (ms) => {
    const t = new Date(ms);
    const p = (x) => String(x).padStart(2, "0");
    return `${t.getFullYear()}-${p(t.getMonth() + 1)}-${p(t.getDate())}T${p(t.getHours())}:${p(t.getMinutes())}`;
  };
  const chainNow = Number(BigInt((await rpc(anvil.url, "eth_getBlockByNumber", ["latest", false])).timestamp)) * 1000;
  const base = Math.max(Date.now(), chainNow);
  await page.fill("#f-deadline", fmt(base + 120 * 86400_000));
  await page.locator("#f-deadline").blur();
  await page.fill("#f-amount", "1");
  await page.locator("#f-amount").blur();
  const warn = (await page.locator("#deadline-warn").textContent()).trim();
  assert(/more than 90 days away/.test(warn), `warns: "${warn}"`);
  assert(((await page.locator("#deadline-err").textContent()) || "").trim() === "", "not an error");
  await page.fill("#f-deadline", fmt(base + 30 * 86400_000));
  await page.locator("#f-deadline").blur();
  assert((await page.locator("#deadline-warn").textContent()).trim() === "", "no warning at 30 days");
  const zh = await ctx.newPage();
  await openTool(zh, server.url + "?lang=zh");
  await zh.click("#tab-create");
  await zh.fill("#f-deadline", fmt(base + 120 * 86400_000));
  await zh.locator("#f-deadline").blur();
  const zw = (await zh.locator("#deadline-warn").textContent()).trim();
  assert(/90 天以后/.test(zw), `Chinese warning: "${zw}"`);

  assert(errors.length === 0, "no page errors" + (errors.length ? ": " + errors.join(" | ") : ""));
  console.log("CASEGAS PASS: declared and paid under a split, old path rejected, too big refused, untested never fits, cheap as before, far-deadline warning");
} catch (e) {
  console.error("CASEGAS FAIL:", e.message);
  const box = await page?.locator("#order-view").textContent().catch(() => "");
  if (box) console.error("   order view: " + box.replace(/\s+/g, " ").slice(-700));
  process.exitCode = 1;
} finally {
  await browser?.close();
  server?.close();
  anvil.stop();
}

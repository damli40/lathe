// Receipts, rule lookup, run and input names (V2) end to end on a local anvil, no keys. Every request goes through
// the proxy that caps eth_call at 50M gas like the public nodes.
//   (a) XOR order with input names a, b -> Paid; the order view heads the columns "a (x0)", "b (x1)";
//   (b) toggle order (1 input + 1 memory bit) named flip, mem -> Paid;
//   (c) with NO wallet: ?receipt=A shows the receipt, the table fingerprint and ruleOf agree, the names are the row
//       headers of "Try the rule"; a=1, b=0 runs on chain: y0=1, same as the table for case 1;
//   (d) ?receipt=B, flip=1, mem=1: runStep answers y0=0, new memory 0, same as case 3;
//   (e) ?receipt=C for an unpaid order: "not paid", no receipt;
//   (f) a paid 4,000-gate circuit: the page says it cannot run it and does not call; the contract itself refuses a
//       run with the node's 50M gas (InsufficientGasForCase), so a capped call cannot return an answer;
//   (g) the node cuts run's gas to 150,000, below what XOR's one case must hold (about 182,000): the page shows an
//       error, not an answer.
// Run from the repo root: node web/test/receipt.mjs
import { execFileSync } from "node:child_process";
import { serve, playwright, shimSource, assert } from "./lib.mjs";
import { startAnvil, deployMocks, ANVIL_ACCOUNT0 } from "./anvil.mjs";
import { startProxy } from "./proxy.mjs";
import { openTool, connect, createOrder, openOrder, waitStatus, deliver, statusText, T_LONG } from "./flows.mjs";

const anvil = await startAnvil({ port: 8551, chainId: 1952 });
const proxy = await startProxy(anvil.url, 8552);
const cast = (...a) => execFileSync("cast", [...a, "--rpc-url", anvil.url], { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }).trim();
let browser;
let server;
try {
  const addrs = deployMocks(anvil.url);
  server = await serve();
  const { chromium } = await playwright();
  browser = await chromium.launch();
  const cfg = `window.LATHE_TEST_CONFIG = ${JSON.stringify({ testnet: { rpc: proxy.url, ...addrs, parallelReads: false } })};`;
  const ctx = await browser.newContext({ bypassCSP: true, viewport: { width: 1440, height: 900 } });
  await ctx.addInitScript({ content: cfg });
  await ctx.addInitScript({ content: shimSource(anvil.url, ANVIL_ACCOUNT0) });
  const page = await ctx.newPage();
  const errors = [];
  page.on("pageerror", (e) => errors.push(e.message));
  await openTool(page, server.url + "?lang=en");
  await connect(page);

  console.log("(a) XOR with input names");
  await page.click("#tab-create");
  await page.fill("#f-label-0", "a");
  await page.fill("#f-label-1", "b");
  const heads = await page.locator("#tt-wrap thead th").allTextContents();
  assert(heads.slice(1, 3).join(",") === "a (x0),b (x1)", `create grid heads: ${heads.join(",")}`);
  await page.fill("#f-label-0", "x".repeat(33));
  await page.locator("#f-label-0").blur();
  assert(/up to 32 bytes/.test(await page.locator("#labels-err").textContent()), "a 33-byte name is refused on the form");
  await page.fill("#f-label-0", "a");
  const A = await createOrder(page, { preset: "xor" });
  assert(cast("call", addrs.lathe, "labelsOf(uint256)(bytes32[])", A).includes("0x6100000000"), "labelsOf stored the name a");
  await openOrder(page, A);
  await deliver(page, { circuit: 1 });
  await waitStatus(page, 2);
  const oh = await page.locator("#order-view table.tt thead th").allTextContents();
  assert(oh.slice(1, 3).join(",") === "a (x0),b (x1)", `order view heads: ${oh.join(",")}`);
  assert(await page.locator("#receipt-btn").isVisible(), "a paid order offers its receipt");

  console.log("(b) toggle with names");
  await page.click("#tab-create");
  await page.click('#mem-seg [data-nstate="1"]');
  await page.click("#nin-seg button:nth-child(1)");
  await page.fill("#f-label-0", "flip");
  await page.fill("#f-label-1", "mem");
  const B = await createOrder(page, { preset: "toggle" });
  await openOrder(page, B);
  await deliver(page, { circuit: 3 });
  await waitStatus(page, 2);

  console.log("(e, f setup) an unpaid order and a paid 4,000-gate circuit, sent with cast");
  await page.click("#tab-create");
  await page.click('#mem-seg [data-nstate="0"]');
  await page.click("#nin-seg button:nth-child(2)");
  const C = await createOrder(page, { preset: "xor" });
  const send = (to, sig, ...a) => cast("send", to, sig, ...a, "--unlocked", "--from", ANVIL_ACCOUNT0, "--gas-limit", "190000000");
  send(addrs.processor, "setCircuit(uint256,address,uint32,uint32,uint32,uint32)", "9", ANVIL_ACCOUNT0, "2", "1", "0", "4000");
  send(addrs.processor, "setOuts(uint256,bytes[])", "9", "[0x00,0x01,0x01,0x00]");
  send(addrs.token, "approve(address,uint256)", addrs.lathe, "1000000");
  const deadline = String(Number(cast("block", "latest", "-f", "timestamp")) + 86400);
  send(addrs.lathe, "createOrder(uint8,uint8,bytes,uint96,uint64,address,uint32)", "2", "1", "0x06", "1000000", deadline, ANVIL_ACCOUNT0, "0");
  const D = String(BigInt(cast("call", addrs.lathe, "nextOrderId()(uint256)").split(" ")[0]) - 1n);
  send(addrs.lathe, "deliver(uint256,address,uint256)", D, addrs.processor, "9");
  send(addrs.lathe, "check(uint256,uint256)", D, "2");
  send(addrs.lathe, "check(uint256,uint256)", D, "2");
  assert(cast("call", addrs.lathe, "ruleOf(uint256)(address,uint256)", D).includes("9"), `order ${D} (4,000 gates) is paid`);

  // a visitor with no wallet
  const vctx = await browser.newContext({ bypassCSP: true, viewport: { width: 1440, height: 900 } });
  await vctx.addInitScript({ content: cfg });
  const vp = await vctx.newPage();
  vp.on("pageerror", (e) => errors.push(e.message));

  console.log("(c) receipt view of A, no wallet");
  await openTool(vp, `${server.url}?lang=en&receipt=${A}`);
  await vp.waitForSelector("#receipt-facts", { timeout: T_LONG });
  assert(new URL(vp.url()).searchParams.get("receipt") === A, "the URL keeps ?receipt=");
  assert((await vp.locator("#receipt-hash").textContent()) === "Matches the table below.", "table fingerprint matches");
  assert(/names the same processor and circuit/.test(await vp.locator("#receipt-rule").textContent()), "ruleOf agrees with the receipt");
  const rows = await vp.locator("#try-box tbody th").allTextContents();
  assert(rows.join(",") === "a (x0),b (x1)", `names are the row headers: ${rows.join(",")}`);
  await vp.click('#try-box button.bit[data-k="0"]');
  await vp.click("#run-btn");
  await vp.waitForSelector("#run-result", { timeout: T_LONG });
  assert((await vp.locator("#run-result").textContent()) === "The circuit answered y0=1.", "run(a=1, b=0) = y0=1");
  assert((await vp.locator("#run-check").textContent()) === "The table says the same for case 1.", "and the table agrees");

  console.log("(d) receipt view of the toggle, runStep");
  await vp.goto(`${server.url}?lang=en&receipt=${B}`);
  await vp.waitForSelector("#try-box", { timeout: T_LONG });
  const rowsB = await vp.locator("#try-box tbody th").allTextContents();
  assert(rowsB.join(",") === "flip (x0),mem (s)", `memory row named: ${rowsB.join(",")}`);
  await vp.click('#try-box button.bit[data-k="0"]');
  await vp.click('#try-box button.bit[data-k="1"]');
  await vp.click("#run-btn");
  await vp.waitForSelector("#run-result", { timeout: T_LONG });
  assert((await vp.locator("#run-result").textContent()) === "The circuit answered y0=0, new memory s′=0.", "runStep(flip=1, mem=1)");
  assert((await vp.locator("#run-check").textContent()) === "The table says the same for case 3.", "matches case 3");

  console.log("(e) unpaid order");
  await vp.goto(`${server.url}?lang=en&receipt=${C}`);
  await vp.waitForSelector("#receipt-none", { timeout: T_LONG });
  assert(/is not paid, so it has no receipt/.test(await vp.locator("#receipt-none").textContent()), "no receipt for an open order");
  let notPaid = false;
  try { cast("call", addrs.lathe, "ruleOf(uint256)(address,uint256)", C); } catch (e) { notPaid = /NotPaid|0x4ba1b6b4|revert/i.test(String(e.stderr || e.message)); }
  assert(notPaid, "ruleOf on the open order reverts");

  console.log("(f) 4,000-gate circuit");
  await vp.goto(`${server.url}?lang=en&receipt=${D}`);
  await vp.waitForSelector("#try-box", { timeout: T_LONG });
  assert(await vp.locator("#run-toobig").isVisible() && await vp.locator("#run-btn").isDisabled(), "the page says it cannot run it and the button is off");
  let capped = "";
  try { cast("call", addrs.lathe, "run(uint256,bytes)(bytes)", D, "0x01", "--gas-limit", "50000000"); } catch (e) { capped = String(e.stderr || e.message); }
  const sel = execFileSync("cast", ["sig", "InsufficientGasForCase()"], { encoding: "utf8" }).trim();
  assert(capped.includes(sel) || /InsufficientGasForCase/.test(capped), `run with 50M gas reverts InsufficientGasForCase (${sel})`);

  console.log("(g) node cuts the gas to 150,000");
  await vp.goto(`${server.url}?lang=en&receipt=${A}`);
  await vp.waitForSelector("#run-btn", { timeout: T_LONG });
  proxy.st.cap = 150_000n;
  await vp.click("#run-btn");
  await vp.waitForSelector("#run-result", { timeout: T_LONG });
  proxy.st.cap = 50_000_000n;
  const capMsg = await vp.locator("#run-result").textContent();
  assert(/refused to answer/.test(capMsg) && !(await vp.locator("#run-check").count()), `capped call is an error, not an answer: "${capMsg}"`);

  assert(errors.length === 0, "no page errors" + (errors.length ? ": " + errors.join(" | ") : ""));
  console.log("RECEIPT PASS: names, receipts, ruleOf, run and runStep with no wallet, capped calls refused");
} catch (e) {
  console.error("RECEIPT FAIL:", e.message);
  process.exitCode = 1;
} finally {
  await browser?.close();
  server?.close();
  proxy.close();
  anvil.stop();
}

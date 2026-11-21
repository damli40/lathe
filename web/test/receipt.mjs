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
//   (h) every answer through a proxy that holds each reply for 1.5 s: while run is out the switches are off, so a
//       flip cannot land; a flip that gets through anyway (switch forced back on) drops the answer; a reload
//       while run is out drops it; a flip after an answer clears it; the deliver box's processor and circuit boxes
//       are off while "Read circuit" is out;
//   (i) names are bytes: "x1)" + U+202E (right-to-left override) is shown as "x1)" inside <bdi>, then "(x0)"
//       outside it, with no direction control left on the page; the create form refuses such a name;
//   (j) mainnet has no contract address: ?receipt=1, ?order=1 and the create form show "Not on mainnet yet" and
//       nothing says it is loading.
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
  assert((await vp.locator("#receipt-hash").textContent()) === "Matches the table below.", "table fingerprint (shape + table) matches the contract's");
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

  console.log("(h) an answer never sits next to inputs it was not asked for");
  const bitsNow = async () => (await vp.locator("#try-box button.bit").allTextContents()).join(",");
  const runBit0 = vp.locator('#try-box button.bit[data-k="0"]');
  const waitRunOut = () => vp.waitForFunction(() => document.querySelector("#run-btn")?.disabled, null, { timeout: T_LONG });
  const waitRunBack = () => vp.waitForFunction(() => document.querySelector("#run-btn") && !document.querySelector("#run-btn").disabled, null, { timeout: T_LONG });
  await vp.goto(`${server.url}?lang=en&receipt=${A}`);
  await vp.waitForSelector("#run-btn", { timeout: T_LONG });
  await runBit0.click(); // x0 = 1
  proxy.st.delay = 1500;
  await vp.click("#run-btn");
  await waitRunOut();
  assert(await runBit0.isDisabled(), "the switches are off while run is out");
  await runBit0.click({ force: true, timeout: 2000 }).catch(() => {}); // the click the review made: flip x0 back
  await vp.waitForSelector("#run-result", { timeout: T_LONG });
  assert((await bitsNow()) === "1,0", `the switches still show the inputs that were run: ${await bitsNow()}`);
  assert((await vp.locator("#run-result").textContent()) === "The circuit answered y0=1.", "answer for 1,0");
  assert((await vp.locator("#run-check").textContent()) === "The table says the same for case 1.", "case 1");
  await runBit0.click(); // a change after the answer clears it
  assert((await vp.locator("#run-result").count()) === 0 && (await vp.locator("#run-check").count()) === 0, "a flip after the answer clears it");
  // second guard: a switch forced back on and flipped while run is out; the answer that comes back is dropped
  await runBit0.click(); // x0 = 1 again
  await vp.click("#run-btn");
  await waitRunOut();
  await runBit0.evaluate((b) => { b.disabled = false; });
  await runBit0.click();
  await waitRunBack();
  assert((await bitsNow()) === "0,0" && (await vp.locator("#run-result").count()) === 0, `answer for 1,0 dropped when the inputs became ${await bitsNow()}`);
  // a reload while run is out: the answer belongs to the old view and is dropped
  await runBit0.click(); // x0 = 1
  await vp.click("#run-btn");
  await waitRunOut();
  await vp.click("#receipt-refresh");
  await vp.waitForSelector("#run-btn:not([disabled])", { timeout: T_LONG });
  await vp.waitForTimeout(2000); // the old run's reply has come back by now
  assert((await vp.locator("#run-result").count()) === 0, "a reload while run is out drops its answer");
  // same rule on the deliver box: the processor and circuit boxes are off while "Read circuit" is out
  await openOrder(page, C);
  await page.fill("#f-circ", "1");
  await page.click("#read-circuit");
  await page.waitForFunction(() => document.querySelector("#read-circuit")?.disabled, null, { timeout: T_LONG });
  assert(await page.locator("#f-circ").isDisabled() && await page.locator("#f-proc").isDisabled(), "deliver inputs are off while the circuit is read");
  proxy.st.delay = 0;
  await page.waitForSelector("#deliver-box table.cmp", { timeout: T_LONG });
  assert(await page.locator("#f-circ").isEnabled() && (await page.locator("#f-circ").inputValue()) === "1", "and back on, still showing circuit 1, once the read-out is in");

  console.log("(i) a name with a text-direction control");
  await page.click("#tab-create");
  await page.fill("#f-label-0", "a\u202E");
  assert(/text-direction/.test(await page.locator("#labels-err").textContent()), "the create form refuses a direction control in a name");
  assert(await page.locator("#create-btn").isDisabled(), "and create stays off");
  await page.fill("#f-label-0", "");
  const rlo = "0x" + Buffer.from("x1)\u202E", "utf8").toString("hex").padEnd(64, "0");
  const zero = "0x" + "0".repeat(64);
  send(addrs.token, "approve(address,uint256)", addrs.lathe, "1000000");
  send(addrs.lathe, "createOrder(uint8,uint8,bytes,uint96,uint64,address,uint32,bytes32[])", "2", "1", "0x06", "1000000", deadline, ANVIL_ACCOUNT0, "0", `[${rlo},${zero}]`);
  const E = String(BigInt(cast("call", addrs.lathe, "nextOrderId()(uint256)").split(" ")[0]) - 1n);
  assert(cast("call", addrs.lathe, "labelsOf(uint256)(bytes32[])", E).includes(rlo), `order ${E} stores the name with U+202E`);
  send(addrs.lathe, "deliver(uint256,address,uint256)", E, addrs.processor, "1");
  await vp.goto(`${server.url}?lang=en&receipt=${E}`);
  await vp.waitForSelector("#try-box", { timeout: T_LONG });
  const th0 = vp.locator("#try-box tbody th").first();
  assert((await th0.textContent()) === "x1) (x0)" && (await th0.locator("bdi").textContent()) === "x1)", `row header: "${await th0.textContent()}"`);
  const colTh = vp.locator("#order-view table.tt thead th").nth(1);
  assert((await colTh.textContent()) === "x1) (x0)" && (await colTh.locator("bdi").count()) === 1, `column header: "${await colTh.textContent()}"`);
  assert(!/[\u200E\u200F\u202A-\u202E\u2066-\u2069]/.test(await vp.locator("#order-view").textContent()), "no direction control left in the view");

  console.log("(j) mainnet has no contract address");
  const mctx = await browser.newContext({ bypassCSP: true, viewport: { width: 1440, height: 900 } });
  await mctx.addInitScript({ content: cfg });
  const mp = await mctx.newPage();
  mp.on("pageerror", (e) => errors.push(e.message));
  for (const q of ["receipt=1", "order=1", ""]) {
    await mp.goto(`${server.url}?lang=en&net=mainnet${q ? "&" + q : ""}`);
    await mp.waitForSelector("#tool-notice:not([hidden])", { timeout: T_LONG });
    await mp.waitForTimeout(500);
    assert(/Not on mainnet yet/.test(await mp.locator("#tool-notice").textContent()), `?${q || "(create)"}: the notice says not on mainnet yet`);
    const body = await mp.locator("#tool-body").textContent();
    assert(!/Loading/i.test(body), `?${q || "(create)"}: nothing says it is loading`);
    assert((await mp.locator("#tool-body [aria-busy='true']").count()) === 0 && (await mp.locator("#order-view[aria-busy]").count()) === 0, `?${q || "(create)"}: nothing is marked busy`);
  }
  await mctx.close();

  assert(errors.length === 0, "no page errors" + (errors.length ? ": " + errors.join(" | ") : ""));
  console.log("RECEIPT PASS: names, receipts, ruleOf, run and runStep with no wallet, capped calls refused, stale answers dropped, direction controls removed, mainnet without a contract");
} catch (e) {
  console.error("RECEIPT FAIL:", e.message);
  process.exitCode = 1;
} finally {
  await browser?.close();
  server?.close();
  proxy.close();
  anvil.stop();
}

// Memory circuits (V1) end to end on a local anvil, no keys: deploy the testnet mocks with
// script/DeployTestnet.s.sol, then through the page:
//   (a) 1 input + 1 memory bit, Toggle preset: the table grows to 4 cases with s and s′ columns, bytes 0x3c;
//       honest toggle circuit 3 -> Paid inside the delivery;
//   (b) the same order with circuit 4 (new memory wrong in case 3) -> refusal sentence naming x0=1 s=1,
//       row 3 highlighted, nothing sent;
//   (c) a memory-free circuit (XOR, circuit 1) on a memory order -> the read-out says the shape does not match.
// Run from the repo root: node web/test/memory.mjs
import { serve, playwright, shimSource, assert } from "./lib.mjs";
import { startAnvil, deployMocks, ANVIL_ACCOUNT0 } from "./anvil.mjs";
import { openTool, connect, createOrder, openOrder, waitStatus, deliver, statusText, T_LONG } from "./flows.mjs";

const anvil = await startAnvil({ port: 8549, chainId: 1952 });
let browser;
let server;
try {
  const addrs = deployMocks(anvil.url);
  server = await serve();
  const { chromium } = await playwright();
  browser = await chromium.launch();
  const ctx = await browser.newContext({ bypassCSP: true, viewport: { width: 1440, height: 900 } });
  await ctx.addInitScript({ content: `window.LATHE_TEST_CONFIG = ${JSON.stringify({ testnet: { rpc: anvil.url, ...addrs, parallelReads: true } })};` });
  await ctx.addInitScript({ content: shimSource(anvil.url, ANVIL_ACCOUNT0) });
  const page = await ctx.newPage();
  const errors = [];
  page.on("pageerror", (e) => errors.push(e.message));
  await openTool(page, server.url + "?lang=en");
  await connect(page);

  console.log("(a) memory toggle, honest circuit");
  await page.click("#tab-create");
  await page.click('#mem-seg [data-nstate="1"]');
  await page.click("#nin-seg button:nth-child(1)");
  assert(await page.locator("#nin-seg button").count() === 5, "with a memory bit the inputs go up to 5");
  await page.click('#preset-row [data-preset="toggle"]');
  const heads = await page.locator("#tt-wrap thead th").allTextContents();
  assert(heads.join(",") === "Case,x0,s,y0,s′", `columns: ${heads.join(",")}`);
  assert(await page.locator("#tt-wrap tbody tr").count() === 4, "2^(1+1) = 4 rows");
  const hex = (await page.locator("#table-hex").textContent()).trim();
  assert(hex === "0x3c", `table bytes ${hex}`);
  assert(await page.locator("#table-help-state").isVisible(), "the s / s′ help line shows");
  // clicking an s′ cell changes the new-memory bit of that case: case 1 bit 1 (0x3c -> 0x34), then back
  await page.click('#tt-wrap button.bit[data-c="1"][data-k="1"]');
  assert((await page.locator("#table-hex").textContent()).trim() === "0x34", "s′ cell of case 1 toggles bit 3");
  await page.click('#tt-wrap button.bit[data-c="1"][data-k="1"]');

  const a = await createOrder(page, { preset: "toggle", amount: "1" }); // memory and nIn kept from above
  await openOrder(page, a);
  const shape = await page.locator("#order-view .facts").first().textContent();
  assert(/1 in, 1 out, 1 memory bit, 4 cases/.test(shape), "order view shows the memory bit and 4 cases");
  await deliver(page, { circuit: 3 });
  await waitStatus(page, 2);
  assert((await statusText(page)) === "Paid", `order ${a} shows Paid`);

  console.log("(b) memory toggle, circuit wrong in case 3");
  const b = await createOrder(page, { preset: "toggle", amount: "1" });
  await openOrder(page, b);
  const sentBefore = await page.evaluate(() => window.__shim.sent.length);
  await deliver(page, { circuit: 4 });
  await page.waitForSelector("#deliver-box .msg.is-err", { timeout: T_LONG });
  const msg = await page.locator("#deliver-box .msg.is-err").last().textContent();
  assert(/Case 3 \(inputs x0=1 s=1\)/.test(msg) && /refused/.test(msg), `refusal sentence: "${msg}"`);
  assert(await page.locator('tr.is-failed[data-case="3"]').count() === 1, "row for case 3 is highlighted");
  assert((await page.evaluate(() => window.__shim.sent.length)) === sentBefore, "nothing was sent");
  assert((await statusText(page)) === "Open", `order ${b} stays Open`);

  console.log("(c) a circuit with no memory on a memory order");
  await page.fill("#f-circ", "1");
  await page.click("#read-circuit");
  await page.waitForSelector("#deliver-box table.cmp", { timeout: T_LONG });
  const box = await page.locator("#deliver-box").textContent();
  assert(/do not match the order/.test(box), "the read-out says the shape does not match");

  assert(errors.length === 0, "no page errors" + (errors.length ? ": " + errors.join(" | ") : ""));
  console.log("MEMORY PASS: toggle paid, wrong memory refused with row, shape mismatch shown");
} catch (e) {
  console.error("MEMORY FAIL:", e.message);
  process.exitCode = 1;
} finally {
  await browser?.close();
  server?.close();
  anvil.stop();
}

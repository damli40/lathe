// Fix-round end to end: every request from the page goes through a proxy that caps eth_call at 50M gas, as the
// public X Layer RPCs do, and the testnet entry runs with parallelReads:false so the one-at-a-time queue is used.
// One anvil, the testnet mocks from script/DeployTestnet.s.sol (fee 1%), circuits set up with MockProcessor hooks.
// Proves, through the page:
//   B3 per-network heading   S7 ?net=__proto__     B4 comma refused        S1 payout after fee
//   S6 outputs field         S8 grid keys/sticky   6-input 13-output deliver to Paid (inline)
//   B1 4,000-gate circuit, maxGates 0, checked to Paid behind the cap (no simulation possible)
//   B1 1,000-gate circuit checked with a clipped simulation (3 of 12 cases simulated, 12 sent)
//   S2 account switch mid-read   S3 receipt unreadable -> warning, create locked, then finishes
//   wrong-network bar + switch button   ticking gates from chain time   B2 reverted check reported as a failure
//   at most one RPC request in flight; no eth_call above 48M gas.
// Run from the repo root: node web/test/fixround.mjs
import { execFileSync } from "node:child_process";
import { serve, playwright, rpc, shimSource, assert } from "./lib.mjs";
import { startAnvil, deployMocks, ANVIL_ACCOUNT0 } from "./anvil.mjs";
import { startProxy } from "./proxy.mjs";
import { openTool, connect, openOrder, waitStatus, deliver, statusText, T_LONG } from "./flows.mjs";

const ACCOUNT1 = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8"; // anvil's public default account 1
const anvil = await startAnvil({ port: 8549, chainId: 1952 });
const proxy = await startProxy(anvil.url, 8550);
let browser;
let server;
const cast = (...a) => execFileSync("cast", [...a, "--rpc-url", anvil.url], { encoding: "utf8" }).trim();
try {
  const addrs = deployMocks(anvil.url);
  console.log("deployed on anvil:", JSON.stringify(addrs));
  const P = addrs.processor;
  const psend = (sig, ...args) => cast("send", P, sig, ...args, "--unlocked", "--from", ANVIL_ACCOUNT0);
  const outBytes = (a, nOut) => {
    let h = "0x";
    for (let i = 0; i < Math.ceil(nOut / 8); i++) h += ((a >> (8 * i)) & 255).toString(16).padStart(2, "0");
    return h;
  };
  // independent table encoder (TableLib: case c's answer at bit c*nOut, LSB first)
  const myTable = (nIn, nOut, ans) => {
    const b = new Uint8Array(Math.ceil(((1 << nIn) * nOut) / 8));
    for (let c = 0; c < 1 << nIn; c++) for (let i = 0; i < nOut; i++) if ((ans[c] >> i) & 1) { const k = c * nOut + i; b[k >> 3] |= 1 << (k & 7); }
    return "0x" + [...b].map((x) => x.toString(16).padStart(2, "0")).join("");
  };
  const fnAns = (nIn, nOut) => [...Array(1 << nIn).keys()].map((c) => ((c * 40503 + nIn * 7919 + nOut * 104729) ^ (c << 5)) & ((1 << nOut) - 1));
  let nextCircuit = 100;
  const mkCircuit = (nIn, nOut, ans, gates, cost = 0) => {
    const id = nextCircuit++;
    psend("setCircuit(uint256,address,uint32,uint32,uint32,uint32)", String(id), ANVIL_ACCOUNT0, String(nIn), String(nOut), "0", String(gates));
    psend("setOuts(uint256,bytes[])", String(id), "[" + ans.map((a) => outBytes(a, nOut)).join(",") + "]");
    if (cost) psend("setEvalGasCost(uint256,uint256)", String(id), String(cost));
    return id;
  };
  const chainTime = async () => Number(BigInt((await rpc(anvil.url, "eth_getBlockByNumber", ["latest", false])).timestamp));
  const localInput = (unix) => {
    const d = new Date(unix * 1000);
    const p = (x) => String(x).padStart(2, "0");
    return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}T${p(d.getHours())}:${p(d.getMinutes())}`;
  };

  server = await serve();
  const { chromium } = await playwright();
  browser = await chromium.launch();
  const ctx = await browser.newContext({ bypassCSP: true, viewport: { width: 1440, height: 900 }, colorScheme: "dark" });
  await ctx.addInitScript({ content: `window.LATHE_TEST_CONFIG = ${JSON.stringify({ testnet: { rpc: proxy.url, ...addrs, parallelReads: false }, tickMs: 1000, unconfirmedRetryMs: 1000 })};` });
  await ctx.addInitScript({ content: shimSource(anvil.url, ANVIL_ACCOUNT0) });
  const page = await ctx.newPage();
  const errors = [];
  page.on("pageerror", (e) => errors.push(e.message));
  const text = (sel) => page.locator(sel).first().textContent().then((t) => (t || "").trim());

  // ---------------------------------------------------------------- S7: prototype names never pick a network
  console.log("S7 net picker");
  await page.goto(server.url + "?lang=en");
  await page.evaluate(() => localStorage.setItem("lathe.net", "constructor"));
  await openTool(page, server.url + "?net=__proto__&lang=en");
  const radios = await page.evaluate(() => [...document.querySelectorAll("#net-seg input")].map((i) => i.value + ":" + i.checked).join(","));
  assert(radios === "testnet:true,mainnet:false", `?net=__proto__ with stored "constructor" opens testnet (${radios})`);
  assert((await page.evaluate(() => localStorage.getItem("lathe.net"))) === "testnet", "the junk stored value was replaced");

  // ---------------------------------------------------------------- B3: heading and sub-line per network
  console.log("B3 per-network heading");
  assert((await text("#tool-h")) === "Try an order", "testnet heading");
  assert(/Nothing here touches real money/.test(await text("#tool-sub")), "testnet sub-line keeps the no-real-money sentence");
  await page.click('#net-seg label:has(input[value="mainnet"])');
  await page.waitForFunction(() => document.querySelector("#tool-h").textContent === "Orders");
  assert((await text("#tool-sub")) === "X Layer mainnet. Orders here lock real USD₮0.", `mainnet sub-line: "${await text("#tool-sub")}"`);
  assert(!/real money/.test(await page.locator("#order").textContent()), "no 'real money' sentence anywhere in the tool on mainnet");
  await page.click('[data-lang="zh"]');
  assert((await text("#tool-h")) === "订单" && (await text("#tool-sub")) === "X Layer 主网。这里的订单会锁定真实的 USD₮0。", "mainnet heading and sub-line in Chinese");
  await page.click('[data-lang="en"]');
  await page.click('#net-seg label:has(input[value="testnet"])');
  await page.waitForFunction(() => document.documentElement.dataset.toolReady === "1", null, { timeout: T_LONG });
  assert((await text("#tool-h")) === "Try an order", "back on testnet the heading is the testnet one");
  await connect(page);

  // ---------------------------------------------------------------- B4 and S1 in the form
  console.log("B4 commas, S1 payout");
  await page.click("#tab-create");
  for (const bad of ["1,5", "1，5", "1٫5", "1,000.50"]) {
    await page.fill("#f-amount", bad);
    await page.locator("#f-amount").blur();
    const err = await text("#amount-err");
    assert(err === "Use a point for decimals, like 1.5. Commas are not accepted.", `amount ${JSON.stringify(bad)} refused: "${err}"`);
    assert(await page.locator("#create-btn").isDisabled(), `create stays disabled for ${JSON.stringify(bad)}`);
  }
  await page.fill("#f-amount", "1.5");
  await page.locator("#f-amount").blur();
  assert((await text("#amount-err")) === "", "1.5 is accepted");
  assert((await text("#payout-line")) === "The builder receives 1.485 mUSDT after the 1% fee.", `payout line: "${await text("#payout-line")}"`);

  // ---------------------------------------------------------------- S6 outputs field
  console.log("S6 outputs field");
  await page.click("#nin-seg button:nth-child(2)");
  await page.fill("#f-nout", "1");
  await page.locator("#f-nout").blur();
  await page.click('#preset-row [data-preset="xor"]');
  await page.fill("#f-nout", "12");
  const colsMid = await page.locator("#tt-wrap thead th").count();
  assert(colsMid === 1 + 2 + 1, `while typing, the table is unchanged (${colsMid} columns)`);
  await page.locator("#f-nout").blur();
  assert((await page.locator("#tt-wrap thead th").count()) === 1 + 2 + 12, "after blur the table has 12 outputs");
  const y0 = await page.evaluate(() => [...document.querySelectorAll('#tt-wrap button.bit[data-k="0"]')].map((b) => b.textContent).join(""));
  assert(y0 === "0110", `y0 kept its XOR answers when growing: ${y0}`);
  await page.click('#tt-wrap button.bit[data-c="3"][data-k="5"]');
  await page.fill("#f-nout", "3");
  await page.locator("#f-nout").blur();
  assert((await text("#nout-note")) === "Outputs y3 and up were removed from every case.", `shrink note: "${await text("#nout-note")}"`);
  const y0b = await page.evaluate(() => [...document.querySelectorAll('#tt-wrap button.bit[data-k="0"]')].map((b) => b.textContent).join(""));
  assert(y0b === "0110", `y0 kept when shrinking: ${y0b}`);
  await page.fill("#f-nout", "40");
  await page.locator("#f-nout").blur();
  assert(/from 1 to 16/.test(await text("#nout-err")) && (await page.locator("#create-btn").isDisabled()), "outputs 40: error shown and create disabled");
  await page.fill("#f-nout", "1");
  await page.locator("#f-nout").blur();
  assert((await text("#nout-err")) === "", "outputs 1: error cleared");

  // ---------------------------------------------------------------- S8 grid keyboard and sticky column
  console.log("S8 grid");
  await page.click("#nin-seg button:nth-child(3)");
  await page.fill("#f-nout", "4");
  await page.locator("#f-nout").blur();
  const stops = await page.evaluate(() => document.querySelectorAll('#tt-wrap button.bit[tabindex="0"]').length);
  const cells = await page.evaluate(() => document.querySelectorAll("#tt-wrap button.bit").length);
  assert(stops === 1 && cells === 32, `one tab stop in a ${cells}-cell grid`);
  await page.focus('#tt-wrap button.bit[tabindex="0"]');
  await page.keyboard.press("ArrowDown");
  await page.keyboard.press("ArrowDown");
  await page.keyboard.press("ArrowRight");
  const at = await page.evaluate(() => [document.activeElement.dataset.c, document.activeElement.dataset.k, document.activeElement.getAttribute("aria-pressed")].join(","));
  assert(at.startsWith("2,1,"), `arrows moved focus to case 2, output y1 (${at})`);
  await page.keyboard.press("Space");
  const after = await page.evaluate(() => [document.activeElement.getAttribute("aria-pressed"), document.activeElement.getAttribute("aria-label")].join("|"));
  assert(after === "true|Case 2, output y1: 1", `Space toggled the cell and its label: ${after}`);
  await page.keyboard.press("Enter");
  assert((await page.evaluate(() => document.activeElement.getAttribute("aria-pressed"))) === "false", "Enter toggles back");
  assert((await page.evaluate(() => document.querySelectorAll('#tt-wrap button.bit[tabindex="0"]').length)) === 1, "still one tab stop after moving");
  const sticky = await page.evaluate(() => getComputedStyle(document.querySelector("#tt-wrap td.case")).position);
  assert(sticky === "sticky", "case column is sticky");

  // ---------------------------------------------------------------- shared create helper
  async function create({ nIn, nOut, ans, amount = "1", maxGates = null, deadline = null }) {
    await page.click("#tab-create");
    await page.click(`#nin-seg button:nth-child(${nIn})`);
    await page.fill("#f-nout", String(nOut));
    await page.locator("#f-nout").blur();
    await page.click('#preset-row [data-preset="clear"]');
    await page.evaluate(({ nOut, ans }) => {
      for (const tr of document.querySelectorAll("#tt-wrap tbody tr")) {
        const c = Number(tr.dataset.case);
        const btns = tr.querySelectorAll("button.bit");
        if (btns.length !== nOut) throw new Error("row has " + btns.length + " buttons");
        btns.forEach((b, k) => { if (((ans[c] >> k) & 1) !== Number(b.textContent)) b.click(); });
      }
    }, { nOut, ans });
    if (maxGates !== null) await page.fill("#f-maxgates", String(maxGates));
    if (deadline) await page.fill("#f-deadline", deadline);
    await page.fill("#f-amount", amount);
    await page.click("#use-mine");
    await page.locator("#f-amount").blur();
    const hex = await text("#table-hex");
    await page.waitForFunction(() => { const a = document.querySelector("#approve-btn"); const c = document.querySelector("#create-btn"); return (a && !a.hidden && !a.disabled) || (c && !c.disabled); }, null, { timeout: T_LONG });
    if (await page.locator("#approve-btn").isVisible() && await page.locator("#approve-btn").isEnabled()) {
      await page.click("#approve-btn");
      await page.waitForFunction(() => !document.querySelector("#create-btn").disabled, null, { timeout: T_LONG });
    }
    await page.click("#create-btn");
    await page.waitForFunction(() => !document.querySelector("#create-result").hidden || /failed|said|could not/.test(document.querySelector("#create-note").textContent), null, { timeout: T_LONG });
    const t = await page.locator("#create-result p").first().textContent().catch(() => "");
    const id = t.match(/Order (\d+)/)?.[1];
    if (!id) throw new Error("create failed: " + (await text("#create-note")));
    return { id, hex };
  }
  async function runCheck() {
    const n = await page.inputValue("#f-checkn");
    const before = await page.evaluate(() => window.__shim.sent.length);
    await page.click("#check-btn");
    await page.waitForFunction((b) => window.__shim.sent.length > b || document.querySelector("#check-box .msg.is-err"), before, { timeout: T_LONG });
    await page.waitForFunction(() => !document.querySelector("#check-btn") || (!document.querySelector("#check-btn").disabled && document.querySelector("#last-action")) || document.querySelector("#check-box .msg.is-err") || document.querySelector("#last-action.is-err"), null, { timeout: 300000 });
    return { n, last: await page.locator("#last-action").textContent().catch(() => null), err: await page.locator("#check-box .msg.is-err").textContent().catch(() => null), status: await statusText(page) };
  }

  // ---------------------------------------------------------------- S1 on the order view
  console.log("S1 order view payout");
  const xor2 = [0, 1, 1, 0];
  const o1 = await create({ nIn: 2, nOut: 1, ans: xor2, amount: "2" });
  await openOrder(page, o1.id);
  assert((await text("#order-payout")) === "The builder receives 1.98 mUSDT after the 1% fee.", `order view payout: "${await text("#order-payout")}"`);
  const tickOrder = o1.id; // Open, deadline +24h: used by the ticking test below

  // ---------------------------------------------------------------- 6 inputs, 13 outputs, inline deliver
  console.log("6-input, 13-output deliver");
  const ans613 = fnAns(6, 13);
  const o2 = await create({ nIn: 6, nOut: 13, ans: ans613 });
  assert(o2.hex === myTable(6, 13, ans613), "page table bytes equal an independent encoding (104 bytes)");
  assert(cast("call", addrs.lathe, "tableOf(uint256)(bytes)", o2.id).toLowerCase() === myTable(6, 13, ans613), "the contract stored the same bytes");
  await openOrder(page, o2.id);
  await deliver(page, { circuit: mkCircuit(6, 13, ans613, 4) });
  await waitStatus(page, 2);
  assert((await statusText(page)) === "Paid", `6-in 13-out order ${o2.id} Paid inline`);
  const shown = await page.evaluate(() => [...document.querySelectorAll("#order-view table.tt tbody tr")].map((tr) => [...tr.querySelectorAll(".bit-ro")].reduce((a, s, k) => a | (Number(s.textContent) << k), 0)));
  assert(JSON.stringify(shown) === JSON.stringify(ans613), "order view decodes all 64 answers back");

  // ---------------------------------------------------------------- B1: 4,000 gates behind the 50M cap
  console.log("B1 4,000-gate circuit, maxGates 0, behind the cap");
  await page.click("#tab-create");
  await page.fill("#f-maxgates", "0");
  assert(/Above 2,995 gates the page cannot test a check before it is sent/.test(await text("#maxgates-note")), `max gates 0 shows the big-circuit note: "${await text("#maxgates-note")}"`);
  await page.fill("#f-maxgates", "100");
  assert((await text("#maxgates-note")) === "", "max gates 100: no note");
  const o3 = await create({ nIn: 2, nOut: 1, ans: xor2, maxGates: 0 });
  await openOrder(page, o3.id);
  await deliver(page, { circuit: mkCircuit(2, 1, xor2, 4000, 1000) });
  await waitStatus(page, 1);
  assert(/Circuit recorded/.test(await text("#last-action")), "4,000-gate delivery recorded for batches");
  assert((await text("#checkn-help")) === "4 cases left to check. Up to 3 fit in one transaction. Anyone can run the check.", `help: "${await text("#checkn-help")}"`);
  assert(/sent without one/.test(await text("#check-nosim")), "the box says this check is sent without a test run");
  const c1 = await runCheck();
  assert(c1.n === "3" && c1.status === "Checking" && c1.last === "3 of 4 cases checked. Run the next batch.", `first batch: ${JSON.stringify(c1)}`);
  assert((await page.inputValue("#f-checkn")) === "1", "S4: the count was reset to the 1 case left");
  assert((await text("#checkn-help")).startsWith("1 cases left"), "help line now says 1 left");
  const c2 = await runCheck();
  assert(c2.status === "Paid" && /All cases matched/.test(c2.last), `second batch: ${JSON.stringify(c2)}`);

  // ---------------------------------------------------------------- B1: clipped simulation
  console.log("B1 clipped simulation, 1,000 gates, 16 cases");
  const ans4 = fnAns(4, 1);
  const o4 = await create({ nIn: 4, nOut: 1, ans: ans4, maxGates: 0 });
  await openOrder(page, o4.id);
  await deliver(page, { circuit: mkCircuit(4, 1, ans4, 1000, 1000) });
  await waitStatus(page, 1);
  assert((await page.locator("#check-nosim").count()) === 0, "1,000 gates: no 'sent without a test run' line");
  const callsBefore = proxy.st.callGas.length;
  const d1 = await runCheck();
  const simGas = proxy.st.callGas.slice(callsBefore).filter((g) => g !== null);
  assert(d1.n === "12" && /12 of 16/.test(d1.last), `12 cases sent in one transaction: ${JSON.stringify(d1)}`);
  assert(simGas.length >= 1 && simGas.every((g) => g <= 48_000_000n), `its simulation asked for ${simGas.map(String).join(",")} gas (<= 48M)`);
  const d2 = await runCheck();
  assert(d2.status === "Paid", `then Paid: ${JSON.stringify(d2)}`);

  // ---------------------------------------------------------------- S2: account switch while a read is out
  console.log("S2 account switch mid-read");
  await page.click("#tab-create");
  await page.fill("#f-amount", "5");
  await page.click("#use-mine");
  await page.locator("#f-amount").blur();
  await page.waitForFunction(() => /Your balance/.test(document.querySelector("#balance-line").textContent), null, { timeout: T_LONG });
  proxy.st.delay = 1500;
  await page.fill("#f-amount", "5.0");
  await page.waitForTimeout(700); // the 400 ms allowance timer has started a read for account 0
  await page.evaluate((b) => window.__shim.setAccount(b), ACCOUNT1);
  await page.waitForTimeout(300);
  assert((await text("#balance-line")) === "", "balance line cleared at once on the switch");
  await page.waitForFunction(() => /Your balance: 0 mUSDT/.test(document.querySelector("#balance-line").textContent), null, { timeout: 30000 });
  proxy.st.delay = 0;
  await page.waitForTimeout(500);
  const sw = await page.evaluate(() => ({ approveHidden: document.querySelector("#approve-btn").hidden, createDisabled: document.querySelector("#create-btn").disabled, err: document.querySelector("#amount-err").textContent }));
  assert(!sw.approveHidden && sw.createDisabled, `account 1 sees its own state: approve shown, create disabled (${JSON.stringify(sw)})`);
  await page.evaluate((a) => window.__shim.setAccount(a), ANVIL_ACCOUNT0);
  await page.waitForFunction(() => /Your balance: 9/.test(document.querySelector("#balance-line").textContent), null, { timeout: 30000 });

  // ---------------------------------------------------------------- wrong-network bar and its button
  console.log("wrong-network bar");
  await page.evaluate(() => window.__shim.setChainId(1));
  await page.waitForFunction(() => !document.querySelector("#netbar").hidden);
  assert((await text("#netbar-text")) === "Your wallet is on another network. Switch to X Layer testnet before you send anything.", "bar text");
  assert(await page.locator("#create-btn").isDisabled(), "create is disabled on the wrong network");
  assert(/another network/.test(await text("#create-note")), "create note says why");
  await page.click("#netbar-btn");
  await page.waitForFunction(() => document.querySelector("#netbar").hidden);
  assert((await page.evaluate(() => window.__shim.switchCalls.join())) === "0x7a0", "switch button asked the wallet for chain 0x7a0 (1952)");
  await page.waitForFunction(() => { const a = document.querySelector("#approve-btn"); const c = document.querySelector("#create-btn"); return (a && !a.hidden && !a.disabled) || (c && !c.disabled); }, null, { timeout: T_LONG });
  assert(!/another network/.test(await text("#create-note")), "bar gone and the send buttons usable again after the switch");
  if (await page.locator("#approve-btn").isVisible() && await page.locator("#approve-btn").isEnabled()) {
    await page.click("#approve-btn");
    await page.waitForFunction(() => !document.querySelector("#create-btn").disabled, null, { timeout: T_LONG });
  }

  // ---------------------------------------------------------------- S3: hash known, receipt unreadable
  console.log("S3 sent but not confirmed");
  proxy.st.fail = new Set(["eth_getTransactionReceipt"]);
  const sentBefore = await page.evaluate(() => window.__shim.sent.length);
  await page.click("#create-btn");
  await page.waitForFunction(() => /could not confirm/.test(document.querySelector("#create-note").textContent), null, { timeout: 200000 });
  const note = await text("#create-note");
  const hash = (await page.evaluate(() => window.__shim.sent.length)) > sentBefore ? note.match(/0x[0-9a-f]{64}/)?.[0] : null;
  assert(!!hash && note === `Sent, but this page could not confirm it. Check transaction ${hash} before you try again.`, `warning: "${note}"`);
  await page.waitForTimeout(2500);
  assert(await page.locator("#create-btn").isDisabled(), "create stays locked while the receipt is unknown");
  await page.click("#create-btn", { force: true }).catch(() => {});
  assert((await page.evaluate(() => window.__shim.sent.length)) === sentBefore + 1, "no second createOrder was sent");
  proxy.st.fail = new Set();
  await page.waitForFunction(() => !document.querySelector("#create-result").hidden, null, { timeout: 30000 });
  assert(/Order \d+ is created/.test(await text("#create-result p")), `once the node answers, the page finishes: "${await text("#create-result p")}"`);

  // ---------------------------------------------------------------- ticking gates from chain time
  console.log("ticking gates");
  await openOrder(page, tickOrder);
  assert(/Refund opens at/.test(await text("#refund-gate")) && (await page.locator("#refund-btn").isDisabled()), "refund closed before the deadline");
  assert(/left$/.test(await text("#deadline-left")), `time left shown: "${await text("#deadline-left")}"`);
  await rpc(anvil.url, "evm_increaseTime", [2 * 86400]);
  await rpc(anvil.url, "evm_mine", []);
  await page.waitForFunction(() => !document.querySelector("#refund-btn").disabled, null, { timeout: 15000 });
  assert(/ago$/.test(await text("#deadline-left")) && (await page.locator("#deliver-box").textContent()).includes("Delivery is closed"), "without a reload: refund open, deliver closed, 'passed ... ago'");

  // ---------------------------------------------------------------- B2: a check that reverts on chain
  console.log("B2 reverted check");
  const ans6 = fnAns(6, 1);
  const dl = localInput((await chainTime()) + 86400 + 120);
  const o5 = await create({ nIn: 6, nOut: 1, ans: ans6, maxGates: 0, deadline: dl });
  await openOrder(page, o5.id);
  await deliver(page, { circuit: mkCircuit(6, 1, ans6, 25, 1000) });
  await waitStatus(page, 1);
  await page.fill("#f-checkn", "10");
  await page.evaluate(() => { window.__shim.beforeSend = async (tx, fwd) => { await fwd("evm_increaseTime", [3 * 86400]); }; });
  const r = await runCheck();
  const tx = await rpc(anvil.url, "eth_getBlockByNumber", ["latest", false]);
  const rc = await rpc(anvil.url, "eth_getTransactionReceipt", [tx.transactions[0]]);
  assert(rc.status === "0x0", "the check transaction really reverted on chain (GraceOver)");
  assert(r.last === "The transaction was mined but failed. Nothing changed on the order." && !/cases checked/.test(r.last), `page reports the failure, not progress: "${r.last}"`);
  assert(r.status === "Checking" && (await page.locator("#check-box").textContent()).includes("0 of 64"), "order still Checking with 0 of 64 checked");

  // ---------------------------------------------------------------- whole-run checks
  assert(proxy.st.max === 1, `at most one RPC request in flight at a time (max seen ${proxy.st.max})`);
  const big = proxy.st.callGas.filter((g) => g !== null && g > 48_000_000n);
  assert(big.length === 0, `no eth_call asked for more than 48M gas (${proxy.st.callGas.length} calls with gas checked)`);
  assert(errors.length === 0, "no page errors" + (errors.length ? ": " + errors.join(" | ") : ""));
  console.log("FIXROUND PASS");
} catch (e) {
  console.error(e);
  process.exitCode = 1;
} finally {
  await browser?.close();
  server?.close();
  proxy.close();
  anvil.stop();
}

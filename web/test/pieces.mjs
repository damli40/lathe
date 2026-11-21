// Pieced orders (createPiecedOrder) in the read-only page, end to end on a local anvil, no keys. Orders are made with
// cast (anvil's unlocked default account); the page only reads them. Every request goes through the proxy that caps
// eth_call at 50M gas like the public nodes.
//   (1) a paid two-piece order: Add(2,2) then GreaterOrEqual(3,2), piece 2 capped at 10 gates;
//   (2) a 1-piece GreaterOrEqual(6,6) order with a short deadline, mid-check at 100 of 4,096 (every piece delivered);
//   (3) a two-piece order whose piece 2 (a 500-gate circuit wrong at case 5) was rejected by checkPiece;
//   (4) a two-piece order with a short deadline and piece 2 never delivered;
//   (5) a paid 1-piece order (GreaterOrEqual(3,2));
//   (6) a paid two-piece order of 1,600-gate pieces: running it needs more than the free-call cap.
//   (7) a paid 3-piece order with explicit wires, paid as "Lathe joins": Add(2,2), GreaterOrEqual(2,3) (cap x4 x5
//       against the sum), then XOR (a table piece) of that answer with x6;
//   (8) a 2-bit daily-cap order that needs a top circuit, both pieces passed, top minted on the REF processor and
//       delivered with deliverTop (paid; the receipt names the top);
//   (9) the same, both pieces passed, no top yet (open, waiting for the top);
//  (10) the same, only piece 1 delivered (open, waiting for the pieces).
// Then anvil time moves 200 s, past the short deadlines of (2) and (4).
// Asserts the true statements (made of N pieces, each piece's rule, state and cap, the refund rule matching
// LatheOrders.refund, the pieced receipt fingerprint, each piece's circuit, no single circuit, run answers on inputs
// where bit order matters) and that the false ones never appear (V0 table fingerprint mismatch, the zero address,
// "No circuit delivered yet", a deliver or check box, a top-level gate cap, refund at deadline + 1 with every piece
// delivered, NoSingleCircuit as an error).
// Run from the repo root: node web/test/pieces.mjs
import { execFileSync } from "node:child_process";
import { serve, playwright, shimSource, assert, rpc } from "./lib.mjs";
import { startAnvil, deployMocks, ANVIL_ACCOUNT0 } from "./anvil.mjs";
import { startProxy } from "./proxy.mjs";
import { openTool, connect, T_LONG } from "./flows.mjs";

const ZERO = "0x0000000000000000000000000000000000000000";
const anvil = await startAnvil({ port: 8553, chainId: 1952 });
const proxy = await startProxy(anvil.url, 8554);
const cast = (...a) => execFileSync("cast", [...a, "--rpc-url", anvil.url], { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }).trim();
const send = (to, sig, ...args) => {
  const gi = args.indexOf("--gas-limit");
  const extra = gi >= 0 ? args.splice(gi, 2) : ["--gas-limit", "20000000"];
  return cast("send", to, sig, ...args, ...extra, "--unlocked", "--from", ANVIL_ACCOUNT0);
};
const ADD22 = "(2,4,3,2,2)";
const GE32 = "(1,5,1,3,2)";
const GE66 = "(1,12,1,6,6)";
let browser;
let server;
try {
  const addrs = deployMocks(anvil.url);
  const L = addrs.lathe;
  const F = addrs.formula;
  assert(/^0x[0-9a-fA-F]{40}$/.test(F || ""), "DeployTestnet logged the formula processor");
  send(addrs.token, "approve(address,uint256)", L, "1000000000");
  const now = Number(cast("block", "latest", "--field", "timestamp"));
  const far = String(now + 86_400);
  const soon = String(now + 120);
  const SIG = "createPiecedOrder((uint8,uint8,uint8,uint8,uint8)[],bytes[],uint96,uint64,address,uint32[],bytes32[])";
  const create = (pieces, tables, deadline, caps) => {
    send(L, SIG, `[${pieces.join(",")}]`, `[${tables.join(",")}]`, "1000000", deadline, ANVIL_ACCOUNT0, `[${caps.join(",")}]`, "[]");
    return String(BigInt(cast("call", L, "nextOrderId()(uint256)").split(" ")[0]) - 1n);
  };
  const deliverPiece = (id, i, cid) => send(L, "deliverPiece(uint256,uint256,address,uint256)", id, String(i), F, String(cid), "--gas-limit", "30000000");
  const checkPiece = (id, i, n, gas) => send(L, "checkPiece(uint256,uint256,uint256)", id, String(i), String(n), "--gas-limit", String(gas));
  const status = (id) => cast("call", L, "orders(uint256)(address,address,uint96,uint64,uint32,uint8,uint8,uint8,uint8)", id).split("\n").pop().trim();

  // extra mock circuits on the formula processor (no access control: test only)
  send(F, "setCircuit(uint256,address,bool,uint8,uint8,uint32)", "9", ANVIL_ACCOUNT0, "false", "3", "2", "500");
  send(F, "setWrongAt(uint256,uint256)", "9", "5");
  send(F, "setCircuit(uint256,address,bool,uint8,uint8,uint32)", "10", ANVIL_ACCOUNT0, "true", "2", "2", "1600");
  send(F, "setCircuit(uint256,address,bool,uint8,uint8,uint32)", "11", ANVIL_ACCOUNT0, "false", "3", "2", "1600");

  const O1 = create([ADD22, GE32], ["0x", "0x"], far, ["0", "10"]);
  deliverPiece(O1, 0, 1);
  deliverPiece(O1, 1, 2);
  assert(status(O1) === "2", `order ${O1}: two-piece order paid inside the two deliveries`);

  const O2 = create([GE66], ["0x"], soon, ["0"]);
  deliverPiece(O2, 0, 4);
  checkPiece(O2, 0, 100, 30_000_000);
  assert(cast("call", L, "pieceOf(uint256,uint256)(address,uint256,address,uint32,bytes32,uint32)", O2, "0").split("\n").pop().startsWith("100"), `order ${O2}: cursor at 100`);

  const O3 = create([ADD22, GE32], ["0x", "0x"], far, ["0", "0"]);
  deliverPiece(O3, 0, 1);
  deliverPiece(O3, 1, 9);
  checkPiece(O3, 1, 32, 100_000_000);
  assert(cast("call", L, "pieceOf(uint256,uint256)(address,uint256,address,uint32,bytes32,uint32)", O3, "1").startsWith(ZERO), `order ${O3}: piece 2 rejected, delivery cleared`);

  const O4 = create([ADD22, GE32], ["0x", "0x"], soon, ["0", "0"]);
  deliverPiece(O4, 0, 1);

  const O5 = create([GE32], ["0x"], far, ["0"]);
  deliverPiece(O5, 0, 2);
  assert(status(O5) === "2", `order ${O5}: 1-piece order paid`);

  const O6 = create([ADD22, GE32], ["0x", "0x"], far, ["0", "0"]);
  deliverPiece(O6, 0, 10);
  deliverPiece(O6, 1, 11);
  for (let k = 0; k < 4; k++) checkPiece(O6, 0, 7, 200_000_000);
  for (let k = 0; k < 6; k++) checkPiece(O6, 1, 7, 200_000_000);
  assert(status(O6) === "2", `order ${O6}: 1,600-gate pieces checked in batches and paid`);

  // Wired orders: createPiecedOrder(PiecedSpec, amount, deadline, builder).
  const SPEC = "createPiecedOrder(((uint8,uint8,uint8,uint8,uint8)[],bytes[],uint32[],bytes32[],(uint8,uint8,uint8,uint8)[],bool),uint96,uint64,address)";
  const T = 255;
  const createWired = (pieces, tables, wires, needsTop) => {
    const spec = `([${pieces.join(",")}],[${tables.join(",")}],[${pieces.map(() => "0").join(",")}],[],[${wires.map((w) => `(${w.join(",")})`).join(",")}],${needsTop})`;
    send(L, SPEC, spec, "1000000", far, ANVIL_ACCOUNT0);
    return String(BigInt(cast("call", L, "nextOrderId()(uint256)").split(" ")[0]) - 1n);
  };
  const ADD = "(2,4,3,2,2)";
  const GE23 = "(1,5,1,2,3)";
  const XOR = "(0,2,1,0,0)";
  const capWires = [[T, 0, 0, 0], [T, 1, 0, 1], [T, 2, 0, 2], [T, 3, 0, 3], [T, 4, 1, 0], [T, 5, 1, 1], [0, 0, 1, 2], [0, 1, 1, 3], [0, 2, 1, 4]];
  const O7 = createWired([ADD, GE23, XOR], ["0x", "0x", "0x06"], [...capWires, [1, 0, 2, 0], [T, 6, 2, 1], [2, 0, T, 0]], false);
  deliverPiece(O7, 0, 1);
  deliverPiece(O7, 1, 5);
  send(L, "deliverPiece(uint256,uint256,address,uint256)", O7, "2", addrs.processor, "1", "--gas-limit", "30000000");
  assert(status(O7) === "2", `order ${O7}: 3-piece wired order paid when the last piece passed`);

  const R = addrs.ref;
  assert(/^0x[0-9a-fA-F]{40}$/.test(R || ""), "DeployTestnet logged the REF processor");
  const topWires = [...capWires, [1, 0, T, 0]];
  const O8 = createWired([ADD, GE23], ["0x", "0x"], topWires, true);
  deliverPiece(O8, 0, 1);
  deliverPiece(O8, 1, 5);
  assert(status(O8) === "0", `order ${O8}: needs a top, still open after both pieces passed`);
  const nl = cast("call", L, "expectedTopNetlist(uint256)(bytes)", O8);
  send(R, "mint(bytes,uint32,uint32,address)", nl, "6", "1", ANVIL_ACCOUNT0);
  const TOP = cast("call", R, "lastId()(uint256)").split(" ")[0];
  send(L, "deliverTop(uint256,address,uint256)", O8, R, TOP, "--gas-limit", "30000000");
  assert(status(O8) === "2", `order ${O8}: paid at deliverTop`);
  const O9 = createWired([ADD, GE23], ["0x", "0x"], topWires, true);
  deliverPiece(O9, 0, 1);
  deliverPiece(O9, 1, 5);
  const O10 = createWired([ADD, GE23], ["0x", "0x"], topWires, true);
  deliverPiece(O10, 0, 1);

  await rpc(anvil.url, "evm_increaseTime", [200]);
  await rpc(anvil.url, "evm_mine", []);

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

  const view = () => page.locator("#order-view").textContent();
  const noFalse = async (label) => {
    const t = await view();
    assert(!t.includes("Does not match the table below"), `${label}: no V0 table-fingerprint mismatch`);
    assert(!t.includes(ZERO), `${label}: the zero address is never shown`);
    assert(!t.includes("No circuit delivered yet"), `${label}: no V0 "no delivery" line`);
    assert(!t.includes("Read each piece's circuit instead"), `${label}: NoSingleCircuit is not shown as an error`);
    assert((await page.locator("#deliver-box, #check-box, #read-circuit").count()) === 0, `${label}: no deliver or check box`);
  };
  const openView = async (q, id) => {
    await page.goto(`${server.url}?lang=en&${q}=${id}`);
    await page.waitForSelector(q === "receipt" ? "#receipt-facts, #receipt-none" : "#pieces-made-of", { timeout: T_LONG });
  };
  const pieceText = (k) => page.locator(`#piece-${k}`).textContent();

  console.log(`(1) paid two-piece order ${O1}`);
  await openView("order", O1);
  assert(/made of 2 pieces/.test(await page.locator("#pieces-made-of").textContent()), "says the order is made of 2 pieces");
  assert(/piece 1 gets inputs x0 to x3\. Piece 2 gets piece 1's 3 outputs as its inputs 0 to 2, then inputs x4 to x5 as its inputs 3 to 4/.test(await page.locator("#pieces-join").textContent()), "says how the pieces join, bit by bit");
  const p0 = await pieceText(0);
  assert(/a plus b\. a is 2 bits \(piece inputs 0 to 1\), b is 2 bits \(piece inputs 2 to 3\)/.test(p0) && /4 in, 3 out, 16 cases/.test(p0), "piece 1: a plus b, widths and bits, 4 in 3 out 16 cases");
  assert(/Passed: all 16 cases matched/.test(p0) && /Circuit 1 on processor/.test(p0), "piece 1 passed, names its circuit");
  const p1 = await pieceText(1);
  assert(/a is at least b\. a is 3 bits \(piece inputs 0 to 2\), b is 2 bits \(piece inputs 3 to 4\)/.test(p1) && /Max gates10/.test(p1), "piece 2: a is at least b, widths, gate cap 10");
  assert((await page.locator("#order-status").textContent()) === "Paid", "status Paid");
  assert(!/Max gates/.test(await page.locator("#order-view .ov-main > .facts").first().textContent()), "no order-level gate cap line");
  await noFalse("order view (1)");

  await openView("receipt", O1);
  assert((await page.locator("#receipt-hash").textContent()) === `Matches the pieces shown here and piecedHash(${O1}).`, "receipt fingerprint = keccak256(abi.encode(pieces, tables)) = piecedHash");
  assert(/has no single circuit/.test(await page.locator("#receipt-nosingle").textContent()), "says a 2-piece order has no single circuit");
  assert((await page.locator("#receipt-rule").count()) === 0, "no ruleOf line for a 2-piece order");
  assert(/Circuit 1 on processor .*4 gates/.test(await page.locator("#receipt-piece-0").textContent()) && /Circuit 2 on processor/.test(await page.locator("#receipt-piece-1").textContent()), "lists each piece's circuit");
  await noFalse("receipt (1)");
  // join (x0..1 + x2..3) >= x4..5; bit order matters: x0 alone gives 1, x4 alone gives 0
  const runWith = async (bits, want) => {
    await page.goto(`${server.url}?lang=en&receipt=${O1}`);
    await page.waitForSelector("#run-btn", { timeout: T_LONG });
    for (const k of bits) await page.click(`#try-box button.bit[data-k="${k}"]`);
    await page.click("#run-btn");
    await page.waitForSelector("#run-result", { timeout: T_LONG });
    const r = await page.locator("#run-result").textContent();
    const c = await page.locator("#run-check").textContent();
    assert(r === `The rule answered y0=${want}.` && /give the same answer/.test(c), `run on inputs [${bits}] answers y0=${want}, same as the pieces' rules`);
  };
  await runWith([0], 1);
  await runWith([4], 0);
  await runWith([0, 1, 5], 1); // 3 >= 2
  await runWith([0, 4, 5], 0); // 1 >= 3 is false

  console.log(`(2) mid-check 1-piece order ${O2}, past its deadline, every piece delivered`);
  await openView("order", O2);
  assert(/made of 1 piece\./.test(await page.locator("#pieces-made-of").textContent()), "says the order is made of 1 piece");
  assert(/Being checked: 100 of 4,096 cases done/.test(await pieceText(0)), "piece being checked: 100 of 4,096");
  assert((await page.locator("#order-status").textContent()) === "Open", "status Open (pieced orders never show Checking)");
  assert(/deliverPiece/.test(await page.locator("#pieces-how").textContent()) && /scripts\/README\.md/.test(await page.locator("#pieces-how").textContent()), "says pieces are delivered with deliverPiece and checked with the crank script");
  assert(/right after the deadline while some piece has no delivery/.test(await page.locator("#refund-rule").textContent()), "states the pieced refund rule");
  const gate2 = await page.locator("#refund-gate").textContent();
  assert(/Every piece has a delivery\. Refund opens at .*one day after the deadline/.test(gate2), `refund waits for the grace day, not deadline + 1: ${gate2}`);
  assert(await page.locator("#refund-btn").isDisabled(), "refund button is off");
  await noFalse("order view (2)");

  console.log(`(3) order ${O3} with a rejected piece`);
  await openView("order", O3);
  assert(/Passed: all 16 cases matched/.test(await pieceText(0)), "piece 1 still passed");
  assert(/Not delivered yet/.test(await pieceText(1)), "rejected piece 2 shows as not delivered (its delivery was cleared)");
  assert(/A piece has no delivery yet\. Refund opens at/.test(await page.locator("#refund-gate").textContent()), "refund opens right after the deadline while a piece has no delivery");
  await noFalse("order view (3)");

  console.log(`(4) order ${O4} past its deadline with an undelivered piece`);
  await openView("order", O4);
  assert(/Not delivered yet/.test(await pieceText(1)), "piece 2 not delivered");
  assert((await page.locator("#refund-gate").count()) === 0 && await page.locator("#refund-btn").isEnabled(), "refund is open now (past the deadline, a piece has no delivery)");
  await noFalse("order view (4)");
  assert(/passed .* ago/.test(await page.locator("#deadline-left").textContent()), "deadline shows as passed");

  console.log(`(5) paid 1-piece order ${O5}`);
  await openView("order", O5);
  assert(/made of 1 piece/.test(await page.locator("#pieces-made-of").textContent()) && /Passed: all 32 cases/.test(await pieceText(0)), "order view: 1 piece, passed");
  await noFalse("order view (5)");
  await openView("receipt", O5);
  assert((await page.locator("#receipt-hash").textContent()) === `Matches the pieces shown here and piecedHash(${O5}).`, "1-piece receipt fingerprint matches");
  assert(/names the same processor and circuit/.test(await page.locator("#receipt-rule").textContent()), "1-piece order: ruleOf agrees with the receipt");
  assert((await page.locator("#receipt-facts").textContent()).includes(F), "1-piece receipt names the formula processor");
  await page.click('#try-box button.bit[data-k="0"]'); // a = 1, b = 0
  await page.click("#run-btn");
  await page.waitForSelector("#run-result", { timeout: T_LONG });
  assert((await page.locator("#run-result").textContent()) === "The rule answered y0=1." && /same answer/.test(await page.locator("#run-check").textContent()), "1-piece run: 1 >= 0 answers 1");
  await noFalse("receipt (5)");

  console.log(`(6) paid order ${O6} of 1,600-gate pieces`);
  await openView("receipt", O6);
  await page.waitForSelector("#try-box", { timeout: T_LONG });
  const big = await page.locator("#run-toobig").textContent();
  assert(/more than a public node allows in a free call/.test(big) && await page.locator("#run-btn").isDisabled(), `the page says it cannot run it and the button is off: ${big}`);
  assert((await page.locator("#run-result").count()) === 0, "no answer shown");
  assert((await page.locator("#receipt-hash").textContent()).startsWith("Matches"), "fingerprint still matches");

  console.log(`(7) paid 3-piece wired order ${O7}`);
  await openView("order", O7);
  assert(/made of 3 pieces/.test(await page.locator("#pieces-made-of").textContent()), "says 3 pieces");
  assert((await page.locator("#pieces-progress").textContent()) === "3 of 3 pieces passed.", "per-order progress: 3 of 3");
  const wires7 = await page.locator("#pieces-wires li").allTextContents();
  assert(JSON.stringify(wires7) === JSON.stringify([
    "Piece 1 inputs 0 to 3 come from the order's inputs x0 to x3.",
    "Piece 2 inputs 0 to 1 come from the order's inputs x4 to x5.",
    "Piece 2 inputs 2 to 4 come from piece 1 outputs 0 to 2.",
    "Piece 3 input 0 comes from piece 2 output 0.",
    "Piece 3 input 1 comes from the order's input x6.",
    "The order's output y0 comes from piece 3 output 0.",
  ]), "wires in plain words: " + JSON.stringify(wires7));
  assert((await page.locator("#pieces-join, #top-box").count()) === 0, "no fixed-join text and no top box for a wired Lathe-joins order");
  assert(/Passed: all 4 cases/.test(await pieceText(2)), "piece 3 (XOR) passed on its 4 cases");
  await noFalse("order (7)");
  await openView("receipt", O7);
  assert((await page.locator("#receipt-hash").textContent()) === `Matches the pieces shown here and piecedHash(${O7}).`, "wired receipt fingerprint = keccak256(abi.encode(pieces, tables, wires))");
  assert(/has no single circuit/.test(await page.locator("#receipt-nosingle").textContent()), "a Lathe-joins order has no single circuit");
  for (const [bits, want] of [[[0, 0, 0, 0, 1, 1, 0], 1], [[1, 1, 1, 0, 1, 1, 0], 0], [[1, 1, 1, 0, 1, 1, 1], 1], [[1, 0, 1, 0, 1, 1, 1], 0]]) {
    for (let k = 0; k < 7; k++) {
      if ((await page.locator(`#try-box button.bit[data-k="${k}"]`).getAttribute("aria-pressed")) !== String(!!bits[k])) await page.click(`#try-box button.bit[data-k="${k}"]`);
    }
    await page.click("#run-btn");
    await page.waitForSelector("#run-result", { timeout: T_LONG });
    const r = await page.locator("#run-result").textContent();
    assert(r === `The rule answered y0=${want}.` && /same answer/.test(await page.locator("#run-check").textContent()), `3-piece run on [${bits}] answers y0=${want}: ${r}`);
  }
  await noFalse("receipt (7)");

  console.log(`(8) needs-a-top order ${O8}, top delivered and paid`);
  await openView("order", O8);
  assert(/needs a top circuit/.test(await page.locator("#pieces-made-of").textContent()), "says the order needs a top circuit");
  assert((await page.locator("#top-state").getAttribute("data-state")) === "delivered" && (await page.locator("#top-state").textContent()).includes(`Circuit ${TOP} on processor ${R}`), "top box names the delivered top");
  await openView("receipt", O8);
  assert((await page.locator("#receipt-facts").textContent()).includes(R), "receipt names the REF processor");
  assert((await page.locator("#receipt-top").textContent()).startsWith(`Circuit ${TOP} on processor ${R}`), "receipt shows the top circuit");
  assert(/ruleOf/.test(await page.locator("#receipt-rule").textContent()) && !(await page.locator("#receipt-rule").getAttribute("class")).includes("bad"), "ruleOf names the top: " + await page.locator("#receipt-rule").textContent());
  assert((await page.locator("#receipt-nosingle").count()) === 0, "no 'no single circuit' line for a topped order");
  assert((await page.locator("#receipt-hash").textContent()).startsWith("Matches"), "topped receipt fingerprint matches");
  for (const [bits, want] of [[[1, 0, 1, 0, 0, 1], 1], [[1, 1, 1, 0, 0, 1], 0]]) {
    for (let k = 0; k < 6; k++) {
      if ((await page.locator(`#try-box button.bit[data-k="${k}"]`).getAttribute("aria-pressed")) !== String(!!bits[k])) await page.click(`#try-box button.bit[data-k="${k}"]`);
    }
    await page.click("#run-btn");
    await page.waitForSelector("#run-result", { timeout: T_LONG });
    const r = await page.locator("#run-result").textContent();
    assert(r === `The rule answered y0=${want}.` && /same answer/.test(await page.locator("#run-check").textContent()), `run via the top on [${bits}] answers y0=${want}: ${r}`);
  }
  await noFalse("receipt (8)");

  console.log(`(9) needs-a-top order ${O9}, pieces passed, no top yet`);
  await openView("order", O9);
  assert((await page.locator("#order-status").textContent()).length > 0 && (await page.locator("#top-state").getAttribute("data-state")) === "waiting", "waiting for the top");
  assert(/Every piece has passed\. Waiting for the builder to deliver the top circuit with deliverTop/.test(await page.locator("#top-state").textContent()), "says the top is next");
  assert((await page.locator("#pieces-progress").textContent()) === "2 of 2 pieces passed.", "2 of 2 passed");
  assert((await page.locator("#pieces-wires li").count()) === 4, "wires listed (not the fixed join)");
  await noFalse("order (9)");

  console.log(`(10) needs-a-top order ${O10}, piece 2 not delivered`);
  await openView("order", O10);
  assert((await page.locator("#top-state").getAttribute("data-state")) === "pieces" && /Waiting for every piece to pass/.test(await page.locator("#top-state").textContent()), "waiting for the pieces");
  assert((await page.locator("#pieces-progress").textContent()) === "1 of 2 pieces passed.", "1 of 2 passed");
  await noFalse("order (10)");

  console.log("ZH strings");
  await page.goto(`${server.url}?lang=zh&order=${O1}`);
  await page.waitForSelector("#pieces-made-of", { timeout: T_LONG });
  assert(/由 2 个部件组成/.test(await page.locator("#pieces-made-of").textContent()) && /a 加 b/.test(await pieceText(0)), "Chinese view: made of 2 pieces, a plus b");
  await page.goto(`${server.url}?lang=zh&order=${O9}`);
  await page.waitForSelector("#top-state", { timeout: T_LONG });
  assert(/需要一个顶层电路/.test(await page.locator("#pieces-made-of").textContent()) && /deliverTop/.test(await page.locator("#top-state").textContent()), "Chinese view: needs a top circuit, waiting for deliverTop");
  assert(/部件 2 的输入 2 到 4 来自部件 1 的输出 0 到 2/.test(await page.locator("#pieces-wires").textContent()), "Chinese wire text");

  assert(errors.length === 0, "no page errors" + (errors.length ? ": " + errors.join(" | ") : ""));
  console.log("PIECES PASS: pieced orders shown truthfully in the order and receipt views");
} catch (e) {
  console.error("PIECES FAIL:", e.message);
  process.exitCode = 1;
} finally {
  await browser?.close();
  server?.close();
  proxy.close?.();
  anvil.stop();
}

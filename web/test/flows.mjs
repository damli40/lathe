// Page actions shared by the end-to-end tests. Each one drives the real page the way a person would.
import { assert } from "./lib.mjs";

export const T_LONG = 60_000;

export async function openTool(page, url) {
  await page.goto(url);
  await page.waitForFunction(() => document.documentElement.dataset.toolReady === "1", null, { timeout: T_LONG });
}

export async function connect(page) {
  const btn = page.locator("#connect-btn");
  if (await btn.isVisible()) await btn.click();
  await page.waitForFunction(() => /0x/.test(document.querySelector("#wallet-status")?.textContent || ""), null, { timeout: T_LONG });
}

/** Fill the create form and run approve + create. Returns the new order id (string). */
export async function createOrder(page, { preset = "xor", amount = "1", builder = "mine", deadline = null, nIn = null, memory = null } = {}) {
  await page.click("#tab-create");
  if (memory !== null) await page.click(`#mem-seg [data-nstate="${memory}"]`);
  if (nIn) await page.click(`#nin-seg button:nth-child(${nIn})`);
  await page.click(`#preset-row [data-preset="${preset}"]`);
  await page.fill("#f-amount", amount);
  if (builder === "mine") await page.click("#use-mine");
  else await page.fill("#f-builder", builder);
  if (deadline) await page.fill("#f-deadline", deadline);
  await page.locator("#f-amount").blur();
  // approve when needed (the page reads the allowance first and hides approve when it is enough)
  await page.waitForFunction(() => {
    const a = document.querySelector("#approve-btn");
    const c = document.querySelector("#create-btn");
    return (a && !a.hidden && !a.disabled) || (c && !c.disabled);
  }, null, { timeout: T_LONG });
  if (await page.locator("#approve-btn").isVisible() && await page.locator("#approve-btn").isEnabled()) {
    await page.click("#approve-btn");
    await page.waitForFunction(() => !document.querySelector("#create-btn").disabled, null, { timeout: T_LONG });
  }
  await page.click("#create-btn");
  await page.waitForFunction(() => !document.querySelector("#create-result").hidden, null, { timeout: T_LONG });
  const text = await page.locator("#create-result p").first().textContent();
  const id = text.match(/\d+/)?.[0];
  assert(!!id, `order created: "${text.trim()}"`);
  return id;
}

export async function openOrder(page, id) {
  await page.click("#tab-lookup");
  await page.fill("#f-lookup", String(id));
  await page.press("#f-lookup", "Enter");
  await waitStatus(page, null);
}

/** Wait until the order view shows data; if want is given, until data-status equals it. */
export async function waitStatus(page, want) {
  await page.waitForFunction((w) => {
    const v = document.querySelector("#order-view");
    const s = v?.getAttribute("data-status");
    return s !== null && s !== undefined && (w === null || s === String(w));
  }, want, { timeout: T_LONG });
}

export async function deliver(page, { processor = null, circuit }) {
  if (processor) await page.fill("#f-proc", processor);
  await page.fill("#f-circ", String(circuit));
  await page.click("#read-circuit");
  await page.waitForSelector("#deliver-box table.cmp", { timeout: T_LONG });
  await page.click("#deliver-btn");
}

export async function statusText(page) {
  return (await page.locator("#order-status").textContent())?.trim();
}

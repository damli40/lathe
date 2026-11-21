// Screenshots: 1440x900 and 390x844, dark and light, EN and ZH; the top of the page, the create form with a
// 6-input table, and an order view (live testnet order 1, read-only). Also fails if the page scrolls sideways.
// Run from the repo root: SHOTS_DIR=/some/dir node web/test/shots.mjs
import { mkdirSync } from "node:fs";
import { serve, playwright, assert } from "./lib.mjs";
import { waitStatus } from "./flows.mjs";

const OUT = process.env.SHOTS_DIR || "web/test/shots";
mkdirSync(OUT, { recursive: true });
const sizes = [[1440, 900], [390, 844]];
let browser;
let server;
try {
  server = await serve();
  const { chromium } = await playwright();
  browser = await chromium.launch();
  for (const [w, h] of sizes) {
    for (const scheme of ["dark", "light"]) {
      for (const lang of ["en", "zh"]) {
        const ctx = await browser.newContext({ viewport: { width: w, height: h }, colorScheme: scheme, deviceScaleFactor: 1 });
        const page = await ctx.newPage();
        const tag = `${w}-${scheme}-${lang}`;
        await page.goto(`${server.url}?lang=${lang}`);
        await page.waitForFunction(() => document.documentElement.dataset.toolReady === "1", null, { timeout: 60000 });
        await page.waitForTimeout(800);
        await page.screenshot({ path: `${OUT}/top-${tag}.png` });
        const over = await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
        assert(over <= 0, `${tag}: no horizontal scroll (overflow ${over}px)`);
        await page.click("#nin-seg button:nth-child(6)");
        await page.click('#preset-row [data-preset="majority"]');
        await page.locator("#order-create").scrollIntoViewIfNeeded();
        await page.evaluate(() => document.querySelector("#order").scrollIntoView({ behavior: "instant", block: "start" }));
        await page.waitForTimeout(300);
        await page.screenshot({ path: `${OUT}/create-${tag}.png` });
        await page.screenshot({ path: `${OUT}/create-full-${tag}.png`, fullPage: true });
        const over2 = await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
        assert(over2 <= 0, `${tag}: no horizontal scroll with the 6-input table (overflow ${over2}px)`);
        await page.goto(`${server.url}?order=1&lang=${lang}`);
        await waitStatus(page, null);
        await page.evaluate(() => document.querySelector("#order-view").scrollIntoView({ behavior: "instant", block: "start" }));
        await page.waitForTimeout(300);
        await page.screenshot({ path: `${OUT}/order-${tag}.png` });
        await ctx.close();
      }
    }
  }
  console.log("SHOTS PASS: written to " + OUT);
} catch (e) {
  console.error("SHOTS FAIL:", e.message);
  process.exitCode = 1;
} finally {
  await browser?.close();
  server?.close();
}

// Shared test helpers: a static server for web/, Playwright from a path outside the repo, anvil RPC, the wallet shim.
// Nothing here is installed into the repo. Playwright is loaded from PLAYWRIGHT_DIR (default: an existing install).
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { extname, join, normalize, resolve, dirname } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { homedir } from "node:os";

export const WEB = resolve(dirname(fileURLToPath(import.meta.url)), "..");
export const REPO = resolve(WEB, "..");

const TYPES = { ".html": "text/html; charset=utf-8", ".js": "text/javascript; charset=utf-8", ".mjs": "text/javascript; charset=utf-8", ".css": "text/css; charset=utf-8", ".json": "application/json", ".svg": "image/svg+xml", ".png": "image/png" };

/** Serve web/ on 127.0.0.1:port. Resolves to { url, close }. */
export function serve(port = 0) {
  return new Promise((ok) => {
    const srv = createServer(async (req, res) => {
      const u = new URL(req.url, "http://x");
      let p = normalize(decodeURIComponent(u.pathname)).replace(/^(\.\.[/\\])+/, "");
      if (p.endsWith("/")) p += "index.html";
      const file = join(WEB, p);
      if (!file.startsWith(WEB)) return res.writeHead(403).end();
      try {
        const body = await readFile(file);
        res.writeHead(200, { "content-type": TYPES[extname(file)] || "application/octet-stream", "cache-control": "no-store" });
        res.end(body);
      } catch {
        res.writeHead(404).end("not found");
      }
    });
    srv.listen(port, "127.0.0.1", () => ok({ url: `http://127.0.0.1:${srv.address().port}/`, close: () => srv.close() }));
  });
}

export async function playwright() {
  const dir = process.env.PLAYWRIGHT_DIR || join(homedir(), "Desktop/career-ops/node_modules/playwright");
  return import(pathToFileURL(join(dir, "index.mjs")).href);
}

/** JSON-RPC to anvil from node (time travel, impersonation, mining). */
export async function rpc(url, method, params = []) {
  const r = await fetch(url, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }) });
  const j = await r.json();
  if (j.error) throw new Error(method + ": " + JSON.stringify(j.error));
  return j.result;
}

/**
 * Browser-side wallet shim: an EIP-1193 provider that forwards every request to anvil, which signs for its
 * unlocked (or impersonated) accounts. No private key exists anywhere in the test.
 * window.__shim.setAccount(addr) switches the account and fires accountsChanged.
 */
export function shimSource(anvilUrl, account) {
  // A stand-in wallet: forwards to anvil (like a wallet with its own RPC). Test hooks on window.__shim:
  // setAccount(a) emits accountsChanged; setChainId(id) makes the wallet report another chain and emits
  // chainChanged (wallet_switchEthereumChain then switches back to the chain asked for); beforeSend(tx, fwd)
  // runs just before a transaction is forwarded.
  return `(() => {
    const url = ${JSON.stringify(anvilUrl)};
    let account = ${JSON.stringify(account)};
    let chainOverride = null;
    const listeners = {};
    const emit = (ev, v) => (listeners[ev] || []).forEach((f) => f(v));
    let id = 0;
    async function forward(method, params) {
      const r = await fetch(url, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ jsonrpc: "2.0", id: ++id, method, params: params || [] }) });
      const j = await r.json();
      if (j.error) { const e = new Error(j.error.message); e.code = j.error.code; e.data = j.error.data; throw e; }
      return j.result;
    }
    window.ethereum = {
      isShim: true,
      on: (ev, f) => { (listeners[ev] = listeners[ev] || []).push(f); },
      removeListener: (ev, f) => { listeners[ev] = (listeners[ev] || []).filter((g) => g !== f); },
      request: async ({ method, params }) => {
        if (method === "eth_requestAccounts" || method === "eth_accounts") return [account];
        if (method === "eth_chainId" && chainOverride !== null) return "0x" + chainOverride.toString(16);
        if (method === "wallet_switchEthereumChain") {
          window.__shim.switchCalls.push(params?.[0]?.chainId);
          const real = Number(await forward("eth_chainId", []));
          if (chainOverride !== null && Number(params?.[0]?.chainId) === real) { chainOverride = null; emit("chainChanged", "0x" + real.toString(16)); }
          return null;
        }
        if (method === "wallet_addEthereumChain") return null;
        if (method === "eth_sendTransaction") {
          if (chainOverride !== null) { const e = new Error("wallet is on another chain"); e.code = 4901; throw e; }
          const tx = { ...params[0], from: account };
          window.__shim.sent.push(tx);
          if (window.__shim.beforeSend) { const f = window.__shim.beforeSend; window.__shim.beforeSend = null; await f(tx, forward); }
          return forward(method, [tx]);
        }
        return forward(method, params);
      },
    };
    window.__shim = {
      sent: [], switchCalls: [], beforeSend: null, forward,
      setAccount(a) { account = a; emit("accountsChanged", [a]); },
      setChainId(c) { chainOverride = c; emit("chainChanged", "0x" + c.toString(16)); },
    };
  })();`;
}

export function assert(cond, msg) {
  if (!cond) throw new Error("ASSERT FAILED: " + msg);
  console.log("  ok  " + msg);
}

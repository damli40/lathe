// RPC proxy in front of anvil, for the browser tests. Based on the reviewer's proxy:
// - caps eth_call / eth_estimateGas at 50,000,000 gas, as rpc.xlayer.tech and testrpc.xlayer.tech do (measured);
// - counts the most requests in flight at once;
// - can answer chosen methods with HTTP 503 (st.fail = new Set([...])) to stand in for a node that is down;
// - can delay every answer (st.delay, ms).
import { createServer } from "node:http";

export const RPC_CALL_GAS_CAP = 50_000_000n;

export function startProxy(target, port) {
  const st = { clamp: true, inflight: 0, max: 0, delay: 0, fail: new Set(), seen: [], callGas: [] };
  const srv = createServer(async (req, res) => {
    let body = "";
    for await (const ch of req) body += ch;
    const cors = { "access-control-allow-origin": "*", "access-control-allow-headers": "*", "access-control-allow-methods": "POST" };
    if (req.method === "OPTIONS" || !body) {
      res.writeHead(204, cors);
      return res.end();
    }
    st.inflight++;
    if (st.inflight > st.max) st.max = st.inflight;
    try {
      const j = JSON.parse(body);
      const arr = Array.isArray(j) ? j : [j];
      for (const m of arr) {
        st.seen.push(m.method);
        if (st.clamp && (m.method === "eth_call" || m.method === "eth_estimateGas") && m.params?.[0]) {
          const g = m.params[0].gas ? BigInt(m.params[0].gas) : null;
          st.callGas.push(g);
          if (g === null || g > RPC_CALL_GAS_CAP) m.params[0].gas = "0x" + RPC_CALL_GAS_CAP.toString(16);
        }
      }
      if (st.delay) await new Promise((r) => setTimeout(r, st.delay));
      if (arr.some((m) => st.fail.has(m.method))) {
        res.writeHead(503, { "content-type": "text/plain", ...cors });
        return res.end("unavailable");
      }
      const r = await fetch(target, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(j) });
      const t = await r.text();
      res.writeHead(200, { "content-type": "application/json", ...cors });
      res.end(t);
    } finally {
      st.inflight--;
    }
  });
  return new Promise((ok) => srv.listen(port, "127.0.0.1", () => ok({ url: `http://127.0.0.1:${port}`, st, close: () => srv.close() })));
}

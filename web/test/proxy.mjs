// RPC proxy in front of anvil, for the browser tests. Based on the reviewer's proxy:
// - caps eth_call / eth_estimateGas at 50,000,000 gas, as rpc.xlayer.tech and testrpc.xlayer.tech do (measured);
// - counts the most requests in flight at once;
// - can answer chosen methods with HTTP 503 (st.fail = new Set([...])) to stand in for a node that is down;
// - can delay every answer (st.delay, ms);
// - st.cap lowers the eth_call cap for one test (default RPC_CALL_GAS_CAP);
// - st.answer(m), when set, may answer a request itself: return a JSON-RPC error object ({ code, message }) to send
//   it with HTTP 200, { http: 429 } (or another status) for an HTTP error, or null to forward it. st.forced counts
//   the requests it answered.
import { createServer } from "node:http";

export const RPC_CALL_GAS_CAP = 50_000_000n;

export function startProxy(target, port) {
  const st = { clamp: true, cap: RPC_CALL_GAS_CAP, inflight: 0, max: 0, delay: 0, fail: new Set(), seen: [], callGas: [], answer: null, forced: 0 };
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
          if (g === null || g > st.cap) m.params[0].gas = "0x" + st.cap.toString(16);
        }
      }
      if (st.delay) await new Promise((r) => setTimeout(r, st.delay));
      if (arr.some((m) => st.fail.has(m.method))) {
        res.writeHead(503, { "content-type": "text/plain", ...cors });
        return res.end("unavailable");
      }
      const forced = st.answer ? arr.map((m) => st.answer(m)).find(Boolean) : null;
      if (forced) {
        st.forced++;
        if (forced.http) {
          res.writeHead(forced.http, { "content-type": "text/plain", ...cors });
          return res.end("too many requests");
        }
        const one = (m) => ({ jsonrpc: "2.0", id: m.id, error: forced });
        res.writeHead(200, { "content-type": "application/json", ...cors });
        return res.end(JSON.stringify(Array.isArray(j) ? arr.map(one) : one(j)));
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

// Network picker (S7): only a network's own key selects it; junk in the URL or in storage falls back.
import { test } from "node:test";
import assert from "node:assert/strict";
import { pickNetKey, NETWORKS, DEFAULT_NETWORK } from "../config.js";

test("URL and stored values pick only real network keys", () => {
  assert.deepEqual(pickNetKey(NETWORKS, { url: "mainnet" }), { key: "mainnet", resetStored: false });
  assert.deepEqual(pickNetKey(NETWORKS, { url: "testnet", stored: "mainnet" }), { key: "testnet", resetStored: false });
  assert.deepEqual(pickNetKey(NETWORKS, { stored: "mainnet" }), { key: "mainnet", resetStored: false });
  assert.deepEqual(pickNetKey(NETWORKS, {}), { key: DEFAULT_NETWORK, resetStored: false });
});

test("prototype names and other junk never select a network", () => {
  for (const bad of ["__proto__", "constructor", "toString", "hasOwnProperty", "valueOf", "", "Mainnet", "mainnet "]) {
    assert.equal(pickNetKey(NETWORKS, { url: bad }).key, DEFAULT_NETWORK, `url ${JSON.stringify(bad)}`);
    const r = pickNetKey(NETWORKS, { stored: bad });
    assert.deepEqual(r, { key: DEFAULT_NETWORK, resetStored: true }, `stored ${JSON.stringify(bad)}`);
  }
});

test("a bad URL value falls back to a good stored value; an order link opens the default network", () => {
  assert.deepEqual(pickNetKey(NETWORKS, { url: "__proto__", stored: "mainnet" }), { key: "mainnet", resetStored: false });
  assert.deepEqual(pickNetKey(NETWORKS, { stored: "mainnet", hasOrder: true }), { key: DEFAULT_NETWORK, resetStored: false });
  assert.deepEqual(pickNetKey(NETWORKS, { url: "mainnet", hasOrder: true }), { key: "mainnet", resetStored: false });
  assert.deepEqual(pickNetKey(NETWORKS, { stored: "__proto__", hasOrder: true }), { key: DEFAULT_NETWORK, resetStored: true });
});

// Network settings for the order tool.
// To go live on mainnet, fill in `lathe` under mainnet with the deployed LatheOrders address. Nothing else changes:
// the page reads the token (and its decimals and symbol), the gas constants, the grace period and the fee rate
// (feeBps) from that contract.

export const VIEM_URL = "https://esm.sh/viem@2.21.0";

export const NETWORKS = {
  testnet: {
    key: "testnet",
    chainId: 1952,
    chainName: "X Layer Testnet",
    rpc: "https://testrpc.xlayer.tech/terigon",
    nativeCurrency: { name: "OKB", symbol: "OKB", decimals: 18 },
    // evidence/2026-11-20-testnet-v0.md, full addresses from broadcast/DeployTestnet.s.sol/1952/run-latest.json
    lathe: "0xde9A8a4b40d490C9Eff56157129902dc1d3D00b7",
    token: "0x0d56908eac1faac3a400cb4ae695148c115c64d1", // MockUSDT, 6 decimals, public mint(address,uint256)
    factory: "0xA3D218C9D0e7301C5085557c404cDAb611449fAA", // MockFactory
    processor: "0xe2995d1B78F8D6Db6BbdFcCAd2db6aefF8af63C1", // MockProcessor: circuit 1 honest XOR, 2 wrong
    parallelReads: true, // the testnet RPC answered 12 parallel calls with 200 (checked 2026-11-21)
    mockMint: true, // the token has a public mint, so the page offers "get test tokens"
    mintAmount: "100", // in whole tokens
    // Explorer links: neither OKLink nor the OKX explorer resolved a known chain-1952 tx when checked on
    // 2026-11-21, so hashes are shown as copyable text. Set to e.g. "https://.../tx/" once one is confirmed.
    explorerTx: null,
    explorerAddress: null,
  },
  mainnet: {
    key: "mainnet",
    chainId: 196,
    chainName: "X Layer",
    rpc: "https://rpc.xlayer.tech",
    nativeCurrency: { name: "OKB", symbol: "OKB", decimals: 18 },
    lathe: null, // not deployed yet: fill in after `forge script script/Deploy.s.sol` (DEPLOY.md section 5)
    token: "0x779Ded0c9e1022225f8E0630b35a9b54bE713736", // USD₮0, 6 decimals
    factory: "0x1f09DAeFA827f02CBb40967cc91b259763760761", // TapeOut processor factory
    processor: null, // builders type their own processor
    parallelReads: false, // this RPC returns 403 under parallel load: one read at a time
    mockMint: false,
    explorerTx: null,
    explorerAddress: null,
  },
};

export const DEFAULT_NETWORK = "testnet";

// The test harness (web/test/e2e.mjs) sets window.LATHE_TEST_CONFIG before the page loads to point a network at a
// local anvil. A normal visitor never has it, and the CSP blocks any script that could set it.
export function networks() {
  const o = globalThis.LATHE_TEST_CONFIG;
  if (!o || typeof o !== "object") return NETWORKS;
  const out = {};
  for (const k of Object.keys(NETWORKS)) out[k] = { ...NETWORKS[k], ...(o[k] || {}) };
  return out;
}

/**
 * Which network the page opens on. `url` is ?net=, `stored` is the remembered choice, `hasOrder` is true when the
 * link names an order (share links leave out ?net for the default network, so those open on the default).
 * Only a network's own key is accepted (Object.hasOwn), so "__proto__" or "constructor" never selects anything.
 * Returns { key, resetStored } where resetStored says the remembered value is junk and should be removed.
 */
export function pickNetKey(nets, { url = null, stored = null, hasOrder = false } = {}) {
  const ok = (k) => typeof k === "string" && Object.hasOwn(nets, k);
  const resetStored = stored !== null && stored !== undefined && !ok(stored);
  if (ok(url)) return { key: url, resetStored };
  if (hasOrder) return { key: DEFAULT_NETWORK, resetStored };
  return { key: ok(stored) ? stored : DEFAULT_NETWORK, resetStored };
}

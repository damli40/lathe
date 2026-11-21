// Lathe page: pitch rendering, theme and language, the hero figure, and the order tool.
// Security rules kept throughout: chain data and URL parameters only ever enter the page as text
// (textContent / createTextNode / attributes we choose), never through innerHTML. Addresses are checked with viem.

import { strings, t as tr, LANGS } from "./i18n.js";
import { networks, DEFAULT_NETWORK, VIEM_URL, pickNetKey } from "./config.js";
import * as T from "./table.js";
import * as G from "./gas.js";
import * as P from "./pieces.js";

const NETS = networks();
const $ = (sel, root = document) => root.querySelector(sel);
const $$ = (sel, root = document) => Array.from(root.querySelectorAll(sel));

// ---------------------------------------------------------------- storage (per-viewer conveniences only)
const store = {
  get(k) {
    try {
      return localStorage.getItem(k);
    } catch {
      return null;
    }
  },
  set(k, v) {
    try {
      if (v === null) localStorage.removeItem(k);
      else localStorage.setItem(k, v);
    } catch {
      /* private mode or blocked storage: the page works without it */
    }
  },
};

// ---------------------------------------------------------------- state
const params = new URLSearchParams(location.search);
const state = {
  lang: pickLang(),
  theme: store.get("lathe.theme"), // "light" | "dark" | null (follow the system)
  netKey: pickNet(),
  fig: null,
  viem: null,
  abi: null, // LatheOrders ABI + token errors, for calls and error decoding
  tokenAbi: null,
  procAbi: null,
  factoryAbi: null,
  pub: null,
  info: {}, // per network: constants and token, read from chain
  provider: null,
  account: null,
  walletChainId: null,
  walletMsg: null,
  form: { nIn: 2, nOut: 1, nState: 0, labels: [], stateLabel: "", answers: T.presetAnswers("xor", 2), maxGatesTouched: false, approved: false, allowance: null, balance: null, steps: {}, result: null },
  view: null, // { id, loading, data, error, inputs, preview, msgs, failedCase, busy }
  tab: "create",
};

function pickLang() {
  const q = params.get("lang");
  if (q && LANGS.includes(q)) return q;
  const s = store.get("lathe.lang");
  if (s && LANGS.includes(s)) return s;
  return (navigator.language || "en").toLowerCase().startsWith("zh") ? "zh" : "en";
}

function pickNet() {
  const r = pickNetKey(NETS, { url: params.get("net"), stored: store.get("lathe.net"), hasOrder: !!params.get("order") || !!params.get("receipt") });
  if (r.resetStored) store.set("lathe.net", null);
  return r.key;
}

const net = () => NETS[state.netKey];
const info = () => state.info[state.netKey];
const txt = (key, vars) => tr(state.lang, key, vars);
const locale = () => (state.lang === "zh" ? "zh-CN" : (navigator.language || "en-US").toLowerCase().startsWith("en") ? navigator.language : "en-US");

// ---------------------------------------------------------------- DOM helpers (text only)
function el(tag, attrs = {}, ...children) {
  const e = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (v === null || v === undefined || v === false) continue;
    if (k === "class") e.className = v;
    else if (k === "text") e.textContent = v;
    else if (k === "on") for (const [ev, fn] of Object.entries(v)) e.addEventListener(ev, fn);
    else if (k === "hidden") e.hidden = true;
    else if (k === "disabled") e.disabled = true;
    else if (k === "value") e.value = v;
    else e.setAttribute(k, v === true ? "" : String(v));
  }
  for (const c of children.flat()) {
    if (c === null || c === undefined || c === false) continue;
    e.appendChild(typeof c === "string" || typeof c === "number" || typeof c === "bigint" ? document.createTextNode(String(c)) : c);
  }
  return e;
}
function setText(sel, s) {
  const e = typeof sel === "string" ? $(sel) : sel;
  if (e) e.textContent = s;
}
function clear(e) {
  while (e.firstChild) e.removeChild(e.firstChild);
  return e;
}

// ---------------------------------------------------------------- formatting
function fmtInt(n) {
  return BigInt(n).toLocaleString(locale());
}
function fmtAmount(v) {
  const d = info()?.decimals ?? 6;
  const plain = G.formatUnitsPlain(BigInt(v), d);
  const [w, f] = plain.split(".");
  const sep = new Intl.NumberFormat(locale()).formatToParts(1.5).find((p) => p.type === "decimal")?.value || ".";
  return BigInt(w).toLocaleString(locale()) + (f ? sep + f : "");
}
function fmtDate(unix) {
  return new Intl.DateTimeFormat(locale(), { dateStyle: "medium", timeStyle: "short" }).format(new Date(Number(unix) * 1000));
}
function fmtDur(sec) {
  let s = Math.max(0, Math.floor(Number(sec)));
  const d = Math.floor(s / 86400);
  const h = Math.floor((s % 86400) / 3600);
  const m = Math.floor((s % 3600) / 60);
  const parts = [];
  if (d) parts.push(txt("tool.dur.d", { n: d }));
  if (h && parts.length < 2) parts.push(txt("tool.dur.h", { n: h }));
  if (!d && m && parts.length < 2) parts.push(txt("tool.dur.m", { n: m }));
  if (!parts.length) parts.push(txt("tool.dur.s", { n: s % 60 }));
  return parts.join(" ");
}
function short(a) {
  return a ? a.slice(0, 6) + "…" + a.slice(-4) : "";
}
// "x0=1 x1=0", then the memory the case starts with: "s=1".
function inputsLabel(c, nIn, nState = 0) {
  const out = [];
  for (let k = 0; k < nIn; k++) out.push(`x${k}=${T.inputBit(c, k)}`);
  for (let k = 0; k < nState; k++) out.push(`s=${T.stateBit(c, nIn, k)}`);
  return out.join(" ");
}
// ---------------------------------------------------------------- input names (labels)
// Stored on chain as one bytes32 per input, then one for the memory bit; empty means "no name, show x0".
// Names are arbitrary bytes, so control and text-direction characters are removed on the way in (T.cleanName),
// and a shown name sits inside a <bdi> with the column code outside it: nothing in a name can reorder the code.
const utf8 = new TextEncoder();
function decodeLabels(arr) {
  if (!Array.isArray(arr)) return [];
  return arr.map((h) => {
    if (typeof h !== "string" || /^0x0{64}$/i.test(h)) return "";
    try {
      return T.cleanName(state.viem.hexToString(h, { size: 32 }));
    } catch {
      return "";
    }
  });
}
function colCode(k, nIn) {
  return k < nIn ? `x${k}` : "s";
}
// Header text for case bit k (inputs x0.., then the memory bit s) with an optional name. Plain text, for
// aria-labels; headers on screen use colHeadNode.
function colHead(labels, k, nIn) {
  const name = T.cleanName(labels?.[k]);
  return name ? `${name} (${colCode(k, nIn)})` : colCode(k, nIn);
}
// The same header as nodes: the name isolated in <bdi>, then " (x0)" outside it.
function colHeadNode(labels, k, nIn) {
  const name = T.cleanName(labels?.[k]);
  if (!name) return document.createTextNode(colCode(k, nIn));
  const f = document.createDocumentFragment();
  f.append(el("bdi", { class: "name", text: name }), ` (${colCode(k, nIn)})`);
  return f;
}

function sameAddr(a, b) {
  return !!a && !!b && a.toLowerCase() === b.toLowerCase();
}

// ---------------------------------------------------------------- theme
const mqLight = window.matchMedia("(prefers-color-scheme: light)");
function effectiveTheme() {
  return state.theme || (mqLight.matches ? "light" : "dark");
}
function applyTheme() {
  if (state.theme) document.documentElement.dataset.theme = state.theme;
  else delete document.documentElement.dataset.theme;
  const eff = effectiveTheme();
  const btn = $("#theme-toggle");
  const target = eff === "dark" ? "light" : "dark";
  btn.textContent = txt(target === "light" ? "tool.ui.themeLight" : "tool.ui.themeDark");
  btn.setAttribute("aria-label", txt("tool.ui.themeLabel") + ": " + btn.textContent);
  try {
    state.fig?.setTheme?.(eff);
  } catch {
    /* the figure is optional */
  }
}
$("#theme-toggle").addEventListener("click", () => {
  state.theme = effectiveTheme() === "dark" ? "light" : "dark";
  store.set("lathe.theme", state.theme);
  applyTheme();
});
mqLight.addEventListener?.("change", () => {
  if (!state.theme) applyTheme();
});

// ---------------------------------------------------------------- language and static strings
function applyStrings() {
  const s = strings[state.lang];
  document.documentElement.lang = state.lang === "zh" ? "zh-CN" : "en";
  document.title = s.meta.title;
  $('meta[name="description"]').setAttribute("content", s.meta.description);
  for (const e of $$("[data-i18n]")) e.textContent = txt(e.dataset.i18n);
  for (const e of $$("[data-i18n-alt]")) e.setAttribute("alt", txt(e.dataset.i18nAlt));
  for (const e of $$("[data-i18n-aria]")) e.setAttribute("aria-label", txt(e.dataset.i18nAria));
  for (const b of $$("[data-lang]")) b.setAttribute("aria-pressed", String(b.dataset.lang === state.lang));
  applyNetHead();

  const steps = clear($("#how-steps"));
  s.how.steps.forEach((st, i) => {
    const li = el("li", {}, el("h3", { text: st.title }), el("p", { text: st.body }));
    li.style.setProperty("--i", String(i));
    steps.appendChild(li);
  });
  const lim = clear($("#limits-list"));
  for (const item of s.limits.items) lim.appendChild(el("li", { text: item }));

  setText("#foot-testnet", NETS.testnet.lathe || s.footer.notDeployed);
  setText("#foot-mainnet", NETS.mainnet.lathe || s.footer.notDeployed);
  $("#foot-mainnet").classList.toggle("mono", !!NETS.mainnet.lathe);

  try {
    state.fig?.setStrings?.(s.fig);
  } catch {
    /* optional */
  }
  applyTheme();
  renderTool();
}
for (const b of $$("[data-lang]")) {
  b.addEventListener("click", () => {
    state.lang = b.dataset.lang;
    store.set("lathe.lang", state.lang);
    if (params.has("lang")) {
      params.set("lang", state.lang);
      history.replaceState(null, "", location.pathname + "?" + params.toString() + location.hash);
    }
    applyStrings();
  });
}

// ---------------------------------------------------------------- hero figure (optional, built separately)
async function mountFig() {
  const host = $("#fig-host");
  const fallback = $("#fig-fallback");
  let mod;
  try {
    mod = await import("./figure.js");
    if (typeof mod.mountFigure !== "function") return;
  } catch {
    return; // no figure: the logo stays
  }
  try {
    await new Promise((resolve) => {
      const link = el("link", { rel: "stylesheet", href: "figure.css" });
      const done = () => resolve();
      link.addEventListener("load", done);
      link.addEventListener("error", done);
      setTimeout(done, 3000);
      document.head.appendChild(link);
    });
    fallback.remove();
    state.fig = mod.mountFigure(host, { theme: effectiveTheme(), strings: strings[state.lang].fig });
    host.classList.add("has-fig");
  } catch (e) {
    console.warn("figure failed, showing the logo", e);
    state.fig = null;
    host.classList.remove("has-fig");
    for (const c of Array.from(host.children)) if (c !== fallback) c.remove();
    if (!fallback.isConnected) host.appendChild(fallback);
  }
}

// ---------------------------------------------------------------- tabs
function selectTab(tab, focus = false) {
  state.tab = tab;
  for (const b of $$("[role=tab]")) {
    const on = b.dataset.tab === tab;
    b.setAttribute("aria-selected", String(on));
    b.tabIndex = on ? 0 : -1;
    if (on && focus) b.focus();
  }
  $("#order-create").hidden = tab !== "create";
  $("#order-lookup").hidden = tab !== "lookup";
}
for (const b of $$("[role=tab]")) {
  b.addEventListener("click", () => selectTab(b.dataset.tab));
  b.addEventListener("keydown", (e) => {
    if (e.key !== "ArrowRight" && e.key !== "ArrowLeft") return;
    e.preventDefault();
    selectTab(state.tab === "create" ? "lookup" : "create", true);
  });
}
for (const a of $$("[data-tab-link]")) {
  a.addEventListener("click", (e) => {
    e.preventDefault();
    selectTab(a.dataset.tabLink);
    const reduce = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    $("#order").scrollIntoView({ behavior: reduce ? "auto" : "smooth", block: "start" });
    history.replaceState(null, "", location.pathname + location.search + a.getAttribute("href"));
  });
}

// ---------------------------------------------------------------- chain setup
async function loadLib() {
  if (state.viem) return true;
  try {
    const [viem, abiRes] = await Promise.all([import(VIEM_URL), fetch("abi.json")]);
    if (!abiRes.ok) throw new Error("abi.json " + abiRes.status);
    const latheAbi = await abiRes.json();
    state.viem = viem;
    const tokenAbi = viem.parseAbi([
      "function decimals() view returns (uint8)",
      "function symbol() view returns (string)",
      "function balanceOf(address) view returns (uint256)",
      "function allowance(address,address) view returns (uint256)",
      "function approve(address,uint256) returns (bool)",
      "function mint(address,uint256)",
      "error ERC20InsufficientBalance(address sender, uint256 balance, uint256 needed)",
      "error ERC20InsufficientAllowance(address spender, uint256 allowance, uint256 needed)",
    ]);
    state.tokenAbi = tokenAbi;
    state.abi = [...latheAbi, ...tokenAbi.filter((x) => x.type === "error")];
    state.procAbi = viem.parseAbi([
      "function circuitInfo(uint256) view returns (uint32,uint32,uint32,uint32)",
      "function ownerOf(uint256) view returns (address)",
      "function eval(uint256,bytes) view returns (bytes)",
      "function step(uint256,bytes,bytes) view returns (bytes,bytes)",
    ]);
    state.factoryAbi = viem.parseAbi(["function isCPU(address) view returns (bool)"]);
    return true;
  } catch (e) {
    console.error(e);
    return false;
  }
}

function chainDef(n) {
  return state.viem.defineChain({
    id: n.chainId,
    name: n.chainName,
    nativeCurrency: n.nativeCurrency,
    rpcUrls: { default: { http: [n.rpc] } },
  });
}

async function read(address, abi, functionName, args = []) {
  return state.pub.readContract({ address, abi, functionName, args });
}

// Every request to a network without parallelReads goes through one queue, so at most one is in flight at a
// time, whichever part of the page sent it (form reads, order view, receipt polling). viem's own http transport
// does the work, so its error types and retries are kept.
function queuedTransport(v, url) {
  const base = v.http(url, { batch: false, retryCount: 2, retryDelay: 500 });
  return (cfg) => {
    const t = base(cfg);
    let tail = Promise.resolve();
    const request = (args, opts) => {
      const run = tail.then(() => t.request(args, opts));
      tail = run.catch(() => {});
      return run;
    };
    return { ...t, request };
  };
}

// Several reads. One at a time unless the network allows parallel reads: the mainnet RPC returns 403 under
// parallel load, so it never gets Promise.all (and its transport queues every request). No multicall either.
async function readMany(thunks) {
  if (net().parallelReads) return Promise.all(thunks.map((f) => f()));
  const out = [];
  for (const f of thunks) out.push(await f());
  return out;
}

// Constants and immutables of a deployed LatheOrders never change, so they are cached per chain and address
// (a per-viewer convenience; the page reads them again whenever the cache is missing or unreadable).
// perRef is EVAL_GAS_PER_REF (extra run gas per piece for a top circuit); 0 for a contract from before it.
const INFO_BIG = ["base", "perGate", "reserve", "inlineMax", "maxCaseGas", "grace", "perRef"];
// hasCaseGas: the contract takes a declared per-case gas (deliver with caseGas, caseGasOf); false before the fix.
const infoCacheKey = (n) => `lathe.info.v4.${n.chainId}.${n.lathe.toLowerCase()}`;
const isInt = (x, lo, hi) => Number.isInteger(x) && x >= lo && x <= hi;

// A cached entry is used only if every field has the right type and a sane range; anything else is re-read.
function cachedInfo(raw) {
  const c = JSON.parse(raw);
  if (!c || typeof c !== "object") return null;
  for (const k of INFO_BIG) {
    if (typeof c[k] !== "string" || !/^\d{1,40}$/.test(c[k])) return null;
    c[k] = BigInt(c[k]);
  }
  if (c.base <= 0n || c.perGate <= 0n || c.inlineMax <= 0n || c.maxCaseGas <= 0n) return null;
  if (!isInt(c.maxCaseBits, 1, 16) || !isInt(c.maxAnswerBits, 1, 256)) return null;
  if (!isInt(c.decimals, 0, 36) || !isInt(c.feeBps, 0, 500)) return null;
  if (!state.viem.isAddress(c.token || "") || !state.viem.isAddress(c.factory || "")) return null;
  if (typeof c.symbol !== "string" || c.symbol.length > 32) return null;
  if (typeof c.hasCaseGas !== "boolean") return null;
  return c;
}

function dropInfo(n) {
  delete state.info[n.key];
  store.set(infoCacheKey(n), null);
}

async function loadInfo() {
  const n = net();
  if (state.info[n.key]) return state.info[n.key];
  const cacheKey = infoCacheKey(n);
  try {
    const raw = store.get(cacheKey);
    const c = raw ? cachedInfo(raw) : null;
    if (c) {
      c.tokenMismatch = !!n.token && !sameAddr(n.token, c.token);
      state.info[n.key] = c;
      return c;
    }
    if (raw) store.set(cacheKey, null);
  } catch {
    store.set(cacheKey, null); /* read from chain */
  }
  const L = n.lathe;
  const A = state.abi;
  const names = ["EVAL_BASE_GAS", "EVAL_GAS_PER_GATE", "GAS_RESERVE", "INLINE_CHECK_MAX_GAS", "MAX_CASE_GAS", "GRACE", "MAX_CASE_BITS", "MAX_ANSWER_BITS", "factory", "usdt", "feeBps"];
  const r = await readMany(names.map((fn) => () => read(L, A, fn)));
  const i = {
    base: r[0], perGate: r[1], reserve: r[2], inlineMax: r[3], maxCaseGas: r[4], grace: r[5],
    maxCaseBits: Number(r[6]), maxAnswerBits: Number(r[7]), factory: r[8], token: r[9], feeBps: Number(r[10]),
  };
  // A contract from before the top-run fix has no EVAL_GAS_PER_REF and gave a top evalBudget alone: 0 then.
  // A network failure is not taken as "old contract": it is thrown, like every other read here.
  try {
    i.perRef = await read(L, A, "EVAL_GAS_PER_REF");
  } catch (e) {
    if (explain(e, { read: true }).name === "network") throw e;
    i.perRef = 0n;
  }
  // caseGasOf exists only on a contract with the declared per-case gas; a revert means an older contract.
  try {
    await read(L, A, "caseGasOf", [0n]);
    i.hasCaseGas = true;
  } catch (e) {
    if (explain(e, { read: true }).name === "network") throw e;
    i.hasCaseGas = false;
  }
  const [dec, sym] = await readMany([() => read(i.token, state.tokenAbi, "decimals"), () => read(i.token, state.tokenAbi, "symbol")]);
  i.decimals = Number(dec);
  i.symbol = sym;
  i.tokenMismatch = !!n.token && !sameAddr(n.token, i.token);
  state.info[n.key] = i;
  const save = { ...i };
  for (const k of INFO_BIG) save[k] = save[k].toString();
  store.set(cacheKey, JSON.stringify(save));
  return i;
}

const toolStatus = { phase: "loading", error: null }; // loading | ready | missing | error | lib

// The tool's heading and sub-line differ per network: the testnet line says no real money is involved.
function applyNetHead() {
  const main = state.netKey === "mainnet";
  setText("#tool-h", txt(main ? "tool.headingMainnet" : "tool.heading"));
  setText("#tool-sub", txt(main ? "tool.subMainnet" : "tool.sub"));
}

async function setNetwork(key) {
  state.netKey = key;
  store.set("lathe.net", key);
  applyNetHead();
  for (const r of $$('#net-seg input')) r.checked = r.value === key;
  state.form.allowance = null;
  state.form.balance = null;
  state.form.result = null;
  state.form.steps = {};
  document.documentElement.dataset.toolReady = "0";
  const n = net();
  if (!n.lathe) {
    toolStatus.phase = "missing";
    renderTool();
    return;
  }
  toolStatus.phase = "loading";
  renderTool();
  if (!(await loadLib())) {
    toolStatus.phase = "lib";
    renderTool();
    return;
  }
  const v = state.viem;
  state.pub = v.createPublicClient({
    chain: chainDef(n),
    transport: n.parallelReads ? v.http(n.rpc, { batch: false, retryCount: 2, retryDelay: 500 }) : queuedTransport(v, n.rpc),
    batch: { multicall: false },
    pollingInterval: 1000,
  });
  try {
    await loadInfo();
  } catch (e) {
    console.error(e);
    if (state.netKey !== key) return;
    toolStatus.phase = "error";
    renderTool();
    return;
  }
  if (state.netKey !== key) return;
  toolStatus.phase = "ready";
  document.documentElement.dataset.toolReady = "1";
  if (!state.form.maxGatesTouched) $("#f-maxgates").value = String(defaultMaxGates());
  renderTool();
  refreshAccountReads();
  if (state.view?.id) loadOrder(state.view.id);
}
for (const r of $$('#net-seg input')) r.addEventListener("change", () => r.checked && setNetwork(r.value));

// ---------------------------------------------------------------- wallet
function findProvider() {
  return window.ethereum || window.okxwallet || null;
}

async function initWallet() {
  const p = findProvider();
  state.provider = p;
  if (!p) {
    renderWallet();
    return;
  }
  p.on?.("accountsChanged", (accs) => {
    state.account = accs && accs[0] ? safeAddr(accs[0]) : null;
    onWalletChange();
  });
  p.on?.("chainChanged", (cid) => {
    state.walletChainId = Number(cid);
    onWalletChange();
  });
  try {
    const accs = await p.request({ method: "eth_accounts" });
    state.account = accs && accs[0] ? safeAddr(accs[0]) : null;
    state.walletChainId = Number(await p.request({ method: "eth_chainId" }));
  } catch {
    /* wallet locked or slow: the connect button still works */
  }
  renderWallet();
}

function safeAddr(a) {
  try {
    return state.viem ? state.viem.getAddress(a) : a;
  } catch {
    return null;
  }
}

async function connect() {
  const p = state.provider;
  if (!p) return;
  const btn = $("#connect-btn");
  btn.disabled = true;
  btn.textContent = txt("tool.wallet.connecting");
  try {
    const accs = await p.request({ method: "eth_requestAccounts" });
    state.account = accs && accs[0] ? safeAddr(accs[0]) : null;
    state.walletChainId = Number(await p.request({ method: "eth_chainId" }));
    state.walletMsg = null;
  } catch (e) {
    state.walletMsg = explain(e).text;
  }
  btn.disabled = false;
  onWalletChange();
}
$("#connect-btn").addEventListener("click", connect);

function wrongNetwork() {
  return !!state.account && state.walletChainId !== net().chainId;
}
function canSend() {
  return !!state.account && !wrongNetwork() && toolStatus.phase === "ready";
}

async function switchNetwork() {
  const p = state.provider;
  const n = net();
  const hex = "0x" + n.chainId.toString(16);
  try {
    await p.request({ method: "wallet_switchEthereumChain", params: [{ chainId: hex }] });
  } catch (e) {
    const code = e?.code ?? e?.data?.originalError?.code;
    if (code === 4902 || code === -32603) {
      try {
        await p.request({
          method: "wallet_addEthereumChain",
          params: [{ chainId: hex, chainName: n.chainName, nativeCurrency: n.nativeCurrency, rpcUrls: [n.rpc] }],
        });
      } catch {
        state.walletMsg = txt("tool.wallet.switchFailed", { net: txt("tool.network." + n.key) });
      }
    } else if (code === 4001) {
      state.walletMsg = txt("tool.errors.rejected");
    } else {
      state.walletMsg = txt("tool.wallet.switchFailed", { net: txt("tool.network." + n.key) });
    }
  }
  try {
    state.walletChainId = Number(await p.request({ method: "eth_chainId" }));
  } catch {
    /* keep the old value */
  }
  onWalletChange();
}
$("#netbar-btn").addEventListener("click", switchNetwork);

function onWalletChange() {
  clearAccountReads();
  renderWallet();
  refreshAccountReads();
  renderCreateSend();
  if (state.view?.data) renderOrder();
}

function renderWallet() {
  const status = $("#wallet-status");
  const btn = $("#connect-btn");
  const n = net();
  if (!state.provider) {
    btn.hidden = true;
    status.textContent = txt("tool.wallet.none");
    status.classList.remove("mono");
  } else if (state.account) {
    btn.hidden = true;
    status.textContent = txt("tool.wallet.connected", { addr: short(state.account) });
    status.classList.add("mono");
    status.title = state.account;
  } else {
    btn.hidden = false;
    btn.textContent = txt("tool.wallet.connect");
    status.textContent = state.walletMsg || "";
    status.classList.remove("mono");
  }
  if (state.account && state.walletMsg) status.textContent += " " + state.walletMsg;
  const bar = $("#netbar");
  bar.hidden = !(wrongNetwork() && toolStatus.phase === "ready");
  if (!bar.hidden) {
    const name = txt("tool.network." + n.key);
    setText("#netbar-text", txt("tool.wallet.wrongNet", { net: name }));
    setText("#netbar-btn", txt("tool.wallet.switchBtn", { net: name }));
  }
}

// ---------------------------------------------------------------- errors into plain sentences
function explain(err, ctx = {}) {
  const v = state.viem;
  let name = null;
  let args = [];
  if (err?.code === 4001 || /user rejected|user denied/i.test(err?.message || "")) {
    return { name: "rejected", text: txt("tool.errors.rejected") };
  }
  if (err?.name === "WrongChain") return { name: "wrongChain", text: txt("tool.errors.wrongChain") };
  if (err?.name === "Reverted") return { name: "reverted", text: txt("tool.tx.reverted") };
  if (err?.name === "Unconfirmed") return { name: "unconfirmed", text: txt("tool.tx.unconfirmed", { hash: err.hash }) };
  // Match viem errors by name, not instanceof: the CDN build can hold more than one copy of a class.
  if (err && typeof err.walk === "function") {
    const rejected = err.walk((e) => e?.name === "UserRejectedRequestError" || e?.code === 4001);
    if (rejected) return { name: "rejected", text: txt("tool.errors.rejected") };
    const rev = err.walk((e) => e?.name === "ContractFunctionRevertedError");
    if (rev?.data?.errorName) {
      name = rev.data.errorName;
      args = rev.data.args || [];
    } else if (v) {
      const raw = err.walk((e) => typeof e?.data === "string" && e.data.startsWith("0x") && e.data.length >= 10);
      if (raw) {
        try {
          const d = v.decodeErrorResult({ abi: state.abi, data: raw.data });
          name = d.errorName;
          args = d.args || [];
        } catch {
          /* not one of ours */
        }
      }
    }
    if (!name && err.walk((e) => e?.name === "HttpRequestError" || e?.name === "TimeoutError")) {
      return { name: "network", text: txt("tool.errors.network") };
    }
  }
  if (name && strings.en.tool.errors[name]) {
    if (name === "WrongAnswer") {
      const c = Number(args[0]);
      return { name, caseIndex: c, text: txt("tool.errors.WrongAnswer", { c, inputs: inputsLabel(c, ctx.nIn ?? 0, ctx.nState ?? 0) }) };
    }
    if (name === "InsufficientGasForCase" && ctx.action === "deliver") return { name, text: txt("tool.errors.InsufficientGasForCaseDeliver") };
    if (name === "InsufficientGasForCase" && ctx.action === "run") return { name, text: txt("tool.errors.InsufficientGasForCaseRun") };
    return { name, text: txt("tool.errors." + name) };
  }
  const msg = (err?.shortMessage || err?.message || String(err)).split("\n")[0].slice(0, 240);
  return { name: "unknown", text: txt(ctx.read ? "tool.errors.read" : "tool.errors.unknown", { msg }) };
}

// ---------------------------------------------------------------- sending
/**
 * Simulate, then send, then wait. `slot` is a function(msgObj) that shows progress.
 * `simulate`: true runs the same call first; { args, gas } runs a smaller version of it (a check clipped to fit
 * the public node's eth_call gas cap); false skips it.
 * The network, its read client and the account are fixed when the call starts, so switching the page's network
 * while a transaction is out does not move the receipt poll to the other network's RPC.
 * Returns a successful receipt. Throws Reverted (mined, failed) with the receipt, Unconfirmed (hash known, receipt
 * not) with the hash, or the wallet/RPC error.
 */
async function send({ address, abi, functionName, args, gas, slot, simulate = true }) {
  const n = net();
  const pub = state.pub;
  const account = state.account;
  const chain = chainDef(n);
  const cid = Number(await state.provider.request({ method: "eth_chainId" }));
  if (cid !== n.chainId) {
    const e = new Error("wrong chain");
    e.name = "WrongChain";
    throw e;
  }
  if (simulate) {
    const sim = simulate === true ? { args, gas } : simulate;
    await pub.simulateContract({ address, abi, functionName, args: sim.args, account, gas: sim.gas });
  }
  slot({ kind: "wait", key: "tool.tx.waiting" });
  const wc = state.viem.createWalletClient({ chain, transport: state.viem.custom(state.provider) });
  const hash = await wc.writeContract({ address, abi, functionName, args, account, chain, gas });
  slot({ kind: "pending", key: "tool.tx.pending", hash });
  let receipt;
  try {
    receipt = await pub.waitForTransactionReceipt({ hash, pollingInterval: 1000, timeout: 180_000 });
  } catch (cause) {
    throw Object.assign(new Error("unconfirmed"), { name: "Unconfirmed", hash, pub, cause });
  }
  receipt._hash = hash;
  if (receipt.status !== "success") throw Object.assign(new Error("reverted"), { name: "Reverted", hash, receipt });
  return receipt;
}

function txLine(target, m) {
  clear(target);
  if (!m) return;
  if (m.key) target.appendChild(el("span", { text: txt(m.key, m.vars) }));
  if (m.hash) {
    target.appendChild(el("span", { text: txt("tool.tx.hash") }));
    const n = net();
    if (n.explorerTx) target.appendChild(el("a", { href: n.explorerTx + m.hash, rel: "noopener", class: "mono", text: short(m.hash) }));
    else target.appendChild(el("code", { text: m.hash }));
    target.appendChild(copyBtn(m.hash, "tool.tx.copyHash"));
  }
}

function copyBtn(value, labelKey) {
  const b = el("button", { type: "button", class: "copy", text: txt(labelKey) });
  b.addEventListener("click", async () => {
    try {
      await navigator.clipboard.writeText(value);
      b.textContent = txt("tool.create.copied");
      setTimeout(() => (b.textContent = txt(labelKey)), 1500);
    } catch {
      /* clipboard blocked: the text is selectable */
    }
  });
  return b;
}

// ---------------------------------------------------------------- tool shell
function renderTool() {
  const notice = clear($("#tool-notice"));
  const body = $("#tool-body");
  const n = net();
  notice.hidden = true;
  notice.classList.remove("is-error");
  body.hidden = false;
  if (toolStatus.phase === "missing") {
    body.hidden = true;
    notice.hidden = false;
    notice.append(
      el("h3", { text: txt("tool.mainnetMissing.title") }),
      el("p", { text: txt("tool.mainnetMissing.body") }),
      el("button", { type: "button", class: "btn btn-primary", text: txt("tool.mainnetMissing.btn"), on: { click: () => setNetwork("testnet") } }),
    );
  } else if (toolStatus.phase === "error" || toolStatus.phase === "lib") {
    body.hidden = true;
    notice.hidden = false;
    notice.classList.add("is-error");
    notice.append(
      el("p", { text: toolStatus.phase === "lib" ? txt("tool.load.lib") : txt("tool.load.failed", { net: txt("tool.network." + n.key) }) }),
      el("button", { type: "button", class: "btn btn-ghost", text: txt("tool.load.retry"), on: { click: () => setNetwork(state.netKey) } }),
    );
  } else if (toolStatus.phase === "ready" && info()?.tokenMismatch) {
    notice.hidden = false;
    notice.append(el("p", { text: txt("tool.load.tokenMismatch") }));
  }
  renderWallet();
  renderCreate();
  if (state.view) renderOrder();
  else renderOrderEmpty();
}

// ---------------------------------------------------------------- create form
function defaultMaxGates() {
  const i = info();
  if (!i) return 0;
  return G.maxInlineGates(i, T.caseCount(state.form.nIn, state.form.nState));
}

function renderCreate() {
  const ready = toolStatus.phase === "ready";
  const form = $("#create-form");
  let sk = $("#create-skeleton");
  if (!ready) {
    form.hidden = true;
    // The placeholder is only for a network that is still loading; with no contract (or a failed load) it would
    // say "busy" for ever under the notice.
    if (toolStatus.phase !== "loading") {
      sk?.remove();
      return;
    }
    if (!sk) {
      sk = el("div", { id: "create-skeleton", class: "create", "aria-busy": "true" },
        el("div", { class: "create-fields" }, ...[0, 1, 2, 3, 4].map(() => el("div", { class: "field" }, el("div", { class: "sk sk-line" }), el("div", { class: "sk sk-block" })))),
        el("div", { class: "create-table" }, el("div", { class: "sk sk-title" }), el("div", { class: "sk sk-table" })));
      $("#order-create").appendChild(sk);
    }
    return;
  }
  sk?.remove();
  form.hidden = false;
  const i = info();
  const f = state.form;

  // inputs 1..maxCaseBits, one fewer with a memory bit (the memory bit counts towards the case limit)
  const seg = clear($("#nin-seg"));
  seg.classList.add("mono");
  for (let k = 1; k <= maxInputs(); k++) {
    seg.appendChild(el("button", { type: "button", "aria-pressed": String(k === f.nIn), "aria-describedby": "nin-help", text: String(k), on: { click: () => setNIn(k) } }));
  }
  setText("#nin-note", f.nState ? txt("tool.create.inputsMaxState") : "");
  const mem = clear($("#mem-seg"));
  for (const k of [0, 1]) {
    mem.appendChild(el("button", { type: "button", "aria-pressed": String(k === f.nState), "aria-describedby": "mem-help", "data-nstate": k, text: txt(k ? "tool.create.memoryOne" : "tool.create.memoryNone"), on: { click: () => setNState(k) } }));
  }
  $("#table-help-state").hidden = !f.nState;
  renderLabelInputs();
  const maxOut = maxOutputs();
  $("#f-nout").max = String(maxOut);
  setText("#nout-help", txt("tool.create.outputsHelp", { max: maxOut }));

  const pr = clear($("#preset-row"));
  for (const p of f.nState ? ["xor", "and", "or", "majority", "toggle", "clear"] : ["xor", "and", "or", "majority", "clear"]) {
    pr.appendChild(el("button", { type: "button", class: "btn btn-quiet btn-sm", "data-preset": p, text: txt("tool.create.presets." + p), on: { click: () => applyPreset(p) } }));
  }

  setText("#amount-label", txt("tool.create.amountLabel", { symbol: i.symbol }));
  setText("#amount-help", txt("tool.create.amountHelp", { decimals: i.decimals }));
  const mintRow = $("#mint-row");
  mintRow.hidden = !net().mockMint;
  setText("#mint-btn", txt("tool.create.mintBtn", { amount: net().mintAmount, symbol: i.symbol }));

  const dl = $("#f-deadline");
  if (!dl.value) dl.value = localInputValue(Date.now() + 24 * 3600 * 1000);
  dl.min = localInputValue(Date.now());
  renderMaxGatesHelp();
  renderTable();
  validateAll(false);
  renderCreateSend();
}

// One name box per input, then one for the memory bit. Names are kept per position while the shape changes.
function renderLabelInputs() {
  const f = state.form;
  const row = clear($("#labels-row"));
  const n = f.nIn + f.nState;
  for (let k = 0; k < n; k++) {
    const code = k < f.nIn ? `x${k}` : "s";
    const input = el("input", { class: "input", id: "f-label-" + k, type: "text", autocomplete: "off", spellcheck: "false", "aria-label": txt("tool.create.labelFor", { col: code }), "aria-describedby": "labels-help labels-err", value: k < f.nIn ? f.labels[k] || "" : f.stateLabel });
    input.addEventListener("input", () => {
      if (k < f.nIn) f.labels[k] = input.value;
      else f.stateLabel = input.value;
      renderTable();
      validateAll(true);
      renderCreateSend();
    });
    row.appendChild(el("label", { class: "label-cell", for: "f-label-" + k }, el("span", { text: code }), input));
  }
}

// The names as the create call takes them: [] when every box is empty, else nIn + nState bytes32 values.
function readLabels() {
  const f = state.form;
  const names = formLabels();
  if (names.every((x) => !x)) return { value: [] };
  for (const x of names) {
    if (T.nameHasControls(x)) return { error: "labelChars" };
    const n = utf8.encode(x).length;
    if (n > 32) return { error: "label", n };
  }
  return { value: names.map((x) => (x ? state.viem.stringToHex(x, { size: 32 }) : "0x" + "0".repeat(64))) };
}
function formLabels() {
  const f = state.form;
  const out = [];
  for (let k = 0; k < f.nIn; k++) out.push((f.labels[k] || "").trim());
  if (f.nState) out.push(f.stateLabel.trim());
  return out;
}

function localInputValue(ms) {
  const d = new Date(ms);
  const p = (x) => String(x).padStart(2, "0");
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}T${p(d.getHours())}:${p(d.getMinutes())}`;
}

function setNIn(k) {
  const f = state.form;
  if (f.nIn === k) return;
  f.nIn = k;
  f.answers = new Array(T.caseCount(k, f.nState)).fill(0);
  if (!f.maxGatesTouched) $("#f-maxgates").value = String(defaultMaxGates());
  f.focusCell = null;
  for (const [idx, b] of $$("#nin-seg button").entries()) b.setAttribute("aria-pressed", String(idx + 1 === k));
  renderMaxGatesHelp();
  renderTable();
  validateAll(false);
}

// Memory bit on or off. The table changes shape (twice the cases, one more answer column), so it starts empty.
// The memory bit counts towards both limits: inputs + memory <= 6, outputs + memory <= 16.
function setNState(k) {
  const f = state.form;
  if (f.nState === k) return;
  f.nState = k;
  if (f.nIn > maxInputs()) f.nIn = maxInputs();
  if (f.nOut > maxOutputs()) {
    f.nOut = maxOutputs();
    $("#f-nout").value = String(f.nOut);
  }
  f.answers = new Array(T.caseCount(f.nIn, k)).fill(0);
  f.focusCell = null;
  if (!f.maxGatesTouched) $("#f-maxgates").value = String(defaultMaxGates());
  renderCreate();
}

function applyPreset(p) {
  const f = state.form;
  f.answers = p === "clear" ? new Array(T.caseCount(f.nIn, f.nState)).fill(0) : T.presetAnswers(p, f.nIn, f.nState, f.nOut);
  renderTable();
}

function maxInputs() {
  return Math.min(T.MAX_INPUTS, info()?.maxCaseBits ?? 6) - state.form.nState;
}
function maxOutputs() {
  return Math.min(T.MAX_OUTPUTS, info()?.maxAnswerBits ?? 16) - state.form.nState;
}
function readOutputs() {
  const v = $("#f-nout").value.trim();
  const max = maxOutputs();
  return /^\d+$/.test(v) && Number(v) >= 1 && Number(v) <= max ? { value: Number(v) } : { error: "bad" };
}
// The new output count is applied on change (blur or Enter), not on every keystroke: typing "12" passes through
// "1", which would otherwise wipe every higher answer bit. When the count shrinks the low bits are kept and the
// page says which outputs went.
function applyOutputs() {
  const r = readOutputs();
  if (r.error) return false;
  const f = state.form;
  if (r.value === f.nOut) return true;
  // Answers hold the outputs in the low nOut bits and the new memory above them, so the memory bit moves.
  const mask = 2 ** r.value - 1;
  const outMask = 2 ** f.nOut - 1;
  const lost = r.value < f.nOut && f.answers.some((a) => (a & outMask & ~mask) !== 0);
  const old = f.nOut;
  f.nOut = r.value;
  f.answers = f.answers.map((a) => (a & outMask & mask) | ((a >> old) << r.value));
  setText("#nout-note", lost ? txt("tool.create.outputsCleared", { from: r.value }) : "");
  renderTable();
  validateAll(touched.has("nout"));
  renderCreateSend();
  return true;
}
$("#f-nout").addEventListener("input", () => {
  setText("#nout-note", "");
  if (touched.has("nout")) validateAll(true);
  renderCreateSend();
});
$("#f-nout").addEventListener("change", applyOutputs);
$("#f-nout").addEventListener("blur", () => {
  touched.add("nout");
  applyOutputs();
  validateAll(true);
});

function renderMaxGatesHelp() {
  const i = info();
  if (!i) return;
  setText("#maxgates-help", txt("tool.create.maxGatesHelp", { g: fmtInt(defaultMaxGates()), cases: T.caseCount(state.form.nIn, state.form.nState) }));
  // Big circuits: checked in several transactions, and above maxSimGates a check cannot be simulated through the
  // public node (its eth_call gas cap), so the page sends it untested.
  const g = readMaxGates();
  const simMax = G.maxSimGates(i);
  const big = !g.error && (g.value === 0 || BigInt(g.value) > simMax);
  setText("#maxgates-note", big ? txt("tool.create.bigCircuit", { g: fmtInt(simMax) }) : "");
}

function renderTable() {
  const f = state.form;
  const wrap = clear($("#tt-wrap"));
  wrap.appendChild(buildTable(f.nIn, f.nOut, f.answers, { editable: true, nState: f.nState, labels: formLabels() }));
  setText("#table-hex", T.toHex(T.encodeTable(f.nIn, f.nOut, f.answers, f.nState)));
}

// Editable grid: one tab stop (roving tabindex). Arrow keys move, Home/End go to the row's ends, Space/Enter
// toggle (native button behaviour). The cell that last had focus keeps the tab stop across rebuilds.
function gridKeys(table) {
  table.addEventListener("keydown", (e) => {
    const b = e.target.closest?.("button.bit");
    if (!b) return;
    const f = state.form;
    let c = Number(b.dataset.c);
    let k = Number(b.dataset.k);
    const cases = T.caseCount(f.nIn, f.nState);
    const w = f.nOut + f.nState; // answer columns: outputs, then the new memory
    if (e.key === "ArrowDown") c = Math.min(cases - 1, c + 1);
    else if (e.key === "ArrowUp") c = Math.max(0, c - 1);
    else if (e.key === "ArrowRight") k = Math.min(w - 1, k + 1);
    else if (e.key === "ArrowLeft") k = Math.max(0, k - 1);
    else if (e.key === "Home") k = 0;
    else if (e.key === "End") k = w - 1;
    else if (e.key === "PageDown") c = Math.min(cases - 1, c + 8);
    else if (e.key === "PageUp") c = Math.max(0, c - 8);
    else return;
    e.preventDefault();
    const next = table.querySelector(`button.bit[data-c="${c}"][data-k="${k}"]`);
    if (!next || next === b) return;
    b.tabIndex = -1;
    next.tabIndex = 0;
    f.focusCell = { c, k };
    next.focus();
  });
}

// Columns: case number, inputs x0.., the memory the case starts with (s), outputs y0.., the new memory (s′).
// Answer bit k < nOut is output y_k; bit nOut is the new memory (TableLib: outputs low, new memory above).
function buildTable(nIn, nOut, answers, { editable, failedCase = null, nState = 0, labels = null }) {
  const w = nOut + nState;
  const cases = T.caseCount(nIn, nState);
  const fc = state.form.focusCell && state.form.focusCell.c < cases && state.form.focusCell.k < w ? state.form.focusCell : { c: 0, k: 0 };
  const head = el("tr", {}, el("th", { class: "case", scope: "col", text: txt("tool.create.colCase") }));
  for (let k = 0; k < nIn; k++) head.appendChild(el("th", { scope: "col", class: k === 0 ? "sep" : null }, colHeadNode(labels, k, nIn)));
  for (let k = 0; k < nState; k++) head.appendChild(el("th", { scope: "col", class: k === 0 && nIn === 0 ? "sep" : null }, colHeadNode(labels, nIn + k, nIn)));
  for (let k = 0; k < nOut; k++) head.appendChild(el("th", { scope: "col", class: k === 0 ? "sep" : null, text: `y${k}` }));
  for (let k = 0; k < nState; k++) head.appendChild(el("th", { scope: "col", class: "sep", text: "s′" }));
  if (failedCase !== null) head.appendChild(el("th", { scope: "col" }));
  const body = el("tbody");
  const cellLabel = (c, k, v) => (k < nOut ? txt("tool.create.cellLabel", { c, k, v }) : txt("tool.create.cellStateLabel", { c, v }));
  for (let c = 0; c < cases; c++) {
    const tr = el("tr", { class: c === failedCase ? "is-failed" : null, "data-case": c });
    tr.appendChild(el("td", { class: "case", text: String(c) }));
    for (let k = 0; k < nIn; k++) tr.appendChild(el("td", { class: "in" + (k === 0 ? " sep" : ""), text: String(T.inputBit(c, k)) }));
    for (let k = 0; k < nState; k++) tr.appendChild(el("td", { class: "in" + (k === 0 && nIn === 0 ? " sep" : ""), text: String(T.stateBit(c, nIn, k)) }));
    for (let k = 0; k < w; k++) {
      const bit = (answers[c] >> k) & 1;
      const td = el("td", { class: k === 0 || k === nOut ? "sep" : null });
      if (editable) {
        const b = el("button", { type: "button", class: "bit", "data-c": c, "data-k": k, tabindex: c === fc.c && k === fc.k ? "0" : "-1", "aria-pressed": String(!!bit), "aria-label": cellLabel(c, k, bit), text: String(bit) });
        b.addEventListener("focus", () => {
          state.form.focusCell = { c, k };
          for (const o of b.closest("table").querySelectorAll('button.bit[tabindex="0"]')) if (o !== b) o.tabIndex = -1;
          b.tabIndex = 0;
        });
        b.addEventListener("click", () => {
          state.form.answers[c] ^= 1 << k;
          const nb = (state.form.answers[c] >> k) & 1;
          b.textContent = String(nb);
          b.setAttribute("aria-pressed", String(!!nb));
          b.setAttribute("aria-label", cellLabel(c, k, nb));
          setText("#table-hex", T.toHex(T.encodeTable(state.form.nIn, state.form.nOut, state.form.answers, state.form.nState)));
        });
        td.appendChild(b);
      } else {
        td.appendChild(el("span", { class: "bit-ro" + (bit ? " on" : ""), text: String(bit) }));
      }
      tr.appendChild(td);
    }
    if (failedCase !== null) tr.appendChild(el("td", { class: "flag", text: c === failedCase ? txt("tool.order.failedRow") : "" }));
    body.appendChild(tr);
  }
  const caption = el("caption", { class: "sr-only", text: txt("tool.create.tableLabel") });
  const table = el("table", { class: "tt" }, caption, el("thead", {}, head), body);
  if (editable) gridKeys(table);
  return table;
}

// field validation
function showErr(id, msg) {
  const input = $("#f-" + id);
  const e = $("#" + id + "-err");
  e.textContent = msg || "";
  input?.setAttribute("aria-invalid", msg ? "true" : "false");
}

function readAmount() {
  const i = info();
  if (!i) return { error: "empty" };
  const r = G.parseAmount($("#f-amount").value, i.decimals);
  if (r.value !== undefined && state.form.balance !== null && r.value > state.form.balance) return { error: "balance", value: r.value };
  return r;
}
function readDeadline() {
  const v = $("#f-deadline").value;
  if (!v) return { error: "empty" };
  const ms = new Date(v).getTime();
  if (!Number.isFinite(ms)) return { error: "empty" };
  if (ms <= Date.now()) return { error: "past" };
  return { value: BigInt(Math.floor(ms / 1000)) };
}
function readBuilder() {
  const v = $("#f-builder").value.trim();
  if (!v) return { error: "empty" };
  if (!state.viem?.isAddress(v)) return { error: "invalid" };
  return { value: state.viem.getAddress(v) };
}
function readMaxGates() {
  const v = $("#f-maxgates").value.trim();
  if (!/^\d+$/.test(v) || BigInt(v) > 4294967295n) return { error: "bad" };
  return { value: Number(v) };
}

function validateAll(show = true) {
  const i = info();
  if (!i) return null;
  const a = readAmount();
  const d = readDeadline();
  const b = readBuilder();
  const g = readMaxGates();
  const o = readOutputs();
  const lb = readLabels();
  const dh = $("#f-deadline").value ? new Date($("#f-deadline").value) : null;
  // S1: what the builder gets after the contract's fee. Nothing extra with a 0 fee.
  setText("#payout-line", i.feeBps > 0 && a.value !== undefined ? txt("tool.payout", { net: fmtAmount(G.payoutAfterFee(a.value, i.feeBps)), symbol: i.symbol, pct: G.feePercent(i.feeBps) }) : "");
  setText("#deadline-help", txt("tool.create.deadlineHelp", {
    tz: Intl.DateTimeFormat().resolvedOptions().timeZone || "UTC",
    unix: dh && Number.isFinite(dh.getTime()) ? String(Math.floor(dh.getTime() / 1000)) : "-",
  }));
  // Soft warning, not a block: an order cannot be cancelled before its deadline, so a far deadline locks the money.
  const far = d.value !== undefined && d.value > BigInt(Math.floor(Date.now() / 1000)) + 90n * 86400n;
  setText("#deadline-warn", far ? txt("tool.create.deadlineFar") : "");
  if (show) {
    showErr("amount", a.error ? txt("tool.create.errors.amount." + a.error, { symbol: i.symbol, decimals: i.decimals, amount: state.form.balance !== null ? fmtAmount(state.form.balance) : "" }) : "");
    showErr("deadline", d.error ? txt("tool.create.errors.deadline." + d.error) : "");
    showErr("builder", b.error ? txt("tool.create.errors.builder." + b.error) : "");
    showErr("maxgates", g.error ? txt("tool.create.errors.maxGates") : "");
    showErr("nout", o.error ? txt("tool.create.errors.outputs", { max: maxOutputs() }) : "");
    setText("#labels-err", lb.error ? txt("tool.create.errors." + lb.error, { n: lb.n }) : "");
  }
  const ok = !a.error && !d.error && !b.error && !g.error && !o.error && !lb.error && o.value === state.form.nOut;
  return { ok, amount: a.value, deadline: d.value, builder: b.value, maxGates: g.value, labels: lb.value || [] };
}

const touched = new Set();
for (const id of ["amount", "deadline", "builder", "maxgates"]) {
  const input = $("#f-" + id);
  input.addEventListener("input", () => {
    if (id === "maxgates") {
      state.form.maxGatesTouched = true;
      renderMaxGatesHelp();
    }
    if (id === "amount") {
      state.form.allowance = null;
      scheduleAllowance();
    }
    validateAll(false);
    if (touched.has(id)) validateAll(true);
    renderCreateSend();
  });
  input.addEventListener("blur", () => {
    touched.add(id);
    validateAll(true);
  });
}

$("#use-mine").addEventListener("click", () => {
  if (!state.account) {
    showErr("builder", txt("tool.wallet.needWallet"));
    return;
  }
  $("#f-builder").value = state.account;
  touched.add("builder");
  validateAll(true);
  renderCreateSend();
});

$("#mint-btn").addEventListener("click", async () => {
  if (!canSend()) {
    setText("#balance-line", txt("tool.wallet.needWallet"));
    return;
  }
  const i = info();
  const btn = $("#mint-btn");
  btn.disabled = true;
  try {
    const amt = G.parseAmount(net().mintAmount, i.decimals).value;
    await send({ address: i.token, abi: state.tokenAbi, functionName: "mint", args: [state.account, amt], slot: (m) => setText("#balance-line", txt(m.key)) });
    // send() throws Reverted on a failed receipt, so reaching here means the mint landed.
    await refreshAccountReads();
    setText("#balance-line", txt("tool.create.minted", { amount: fmtAmount(amt), symbol: i.symbol }) + " " + txt("tool.create.balance", { amount: fmtAmount(state.form.balance ?? 0n), symbol: i.symbol }));
  } catch (e) {
    setText("#balance-line", explain(e).text);
  }
  btn.disabled = false;
});

let allowanceTimer = null;
function scheduleAllowance() {
  clearTimeout(allowanceTimer);
  allowanceTimer = setTimeout(() => refreshAccountReads(), 400);
}

// Balance and allowance of the connected account. One read runs at a time; a call that arrives while one is
// running asks for another pass. A result is kept only if the account and network are still the ones it was read
// for: otherwise it is dropped and the read runs again (S2: switching account mid-read showed A's numbers for B).
let readsRunning = null;
let readsAgain = false;
async function refreshAccountReads() {
  if (toolStatus.phase !== "ready" || !state.account) {
    state.form.balance = null;
    state.form.allowance = null;
    state.form.readFor = null;
    setText("#balance-line", "");
    renderCreateSend();
    return;
  }
  readsAgain = true;
  if (readsRunning) return readsRunning;
  readsRunning = (async () => {
    while (readsAgain && toolStatus.phase === "ready" && state.account) {
      readsAgain = false;
      const i = info();
      const who = state.account;
      const key = state.netKey;
      const still = () => who === state.account && key === state.netKey;
      try {
        const bal = await read(i.token, state.tokenAbi, "balanceOf", [who]);
        const al = await read(i.token, state.tokenAbi, "allowance", [who, net().lathe]);
        if (!still()) {
          readsAgain = true;
          continue;
        }
        state.form.balance = bal;
        state.form.allowance = al;
        state.form.readFor = who + "@" + key;
        setText("#balance-line", txt("tool.create.balance", { amount: fmtAmount(bal), symbol: i.symbol }));
      } catch (e) {
        if (!still()) {
          readsAgain = true;
          continue;
        }
        setText("#balance-line", explain(e, { read: true }).text);
      }
    }
    renderCreateSend();
  })();
  try {
    await readsRunning;
  } finally {
    readsRunning = null;
  }
}

// Called when the account or chain changes: old numbers belong to someone else, so they go at once.
function clearAccountReads() {
  const f = state.form;
  if (f.readFor === (state.account || "") + "@" + state.netKey) return;
  f.balance = null;
  f.allowance = null;
  f.readFor = null;
  f.steps = f.steps.unconfirmed ? f.steps : {};
  setText("#balance-line", "");
}

function renderCreateSend() {
  if (toolStatus.phase !== "ready") return;
  const i = info();
  const f = state.form;
  const v = validateAll(false);
  const approveBtn = $("#approve-btn");
  const createBtn = $("#create-btn");
  const amountText = v?.amount ? fmtAmount(v.amount) : "";
  approveBtn.textContent = txt("tool.create.approveBtn", { amount: amountText, symbol: i.symbol }).replace(/\s+/g, " ").trim();
  const needsApprove = !(v?.amount && f.allowance !== null && f.allowance >= v.amount);
  let approveNote = "";
  let createNote = "";
  if (!state.account) {
    approveNote = createNote = txt("tool.wallet.needWallet");
  } else if (wrongNetwork()) {
    approveNote = createNote = txt("tool.wallet.wrongNet", { net: txt("tool.network." + net().key) });
  } else if (!v?.ok) {
    approveNote = createNote = txt("tool.create.fixFirst");
  } else if (f.allowance === null) {
    approveNote = txt("tool.create.readingAllowance");
  } else if (!needsApprove) {
    approveNote = f.steps.approvedNow ? txt("tool.create.approved") : txt("tool.create.approveSkip");
  }
  if (f.steps.approveMsg) approveNote = f.steps.approveMsg;
  if (f.steps.createMsg) createNote = f.steps.createMsg;
  setText("#approve-note", approveNote);
  setText("#create-note", createNote);
  const busy = !!f.steps.busy;
  approveBtn.hidden = !needsApprove && f.allowance !== null && !!v?.amount;
  approveBtn.disabled = busy || !canSend() || !v?.ok || f.allowance === null || !needsApprove;
  createBtn.disabled = busy || !!f.steps.unconfirmed || !canSend() || !v?.ok || needsApprove;
  $("#step-approve").classList.toggle("is-done", !needsApprove && f.allowance !== null);
  txLine($("#approve-tx"), f.steps.approveTx);
  txLine($("#create-tx"), f.steps.createTx);
  renderCreateResult();
}

// Before any amount is sent, read the token's decimals again: a cached value that no longer matches would make
// "1.5" mean a different amount. On a mismatch nothing is sent; the page re-reads everything and says so.
async function decimalsStillRight() {
  const i = info();
  const n = net();
  const d = Number(await read(i.token, state.tokenAbi, "decimals"));
  if (d === i.decimals) return true;
  dropInfo(n);
  await loadInfo();
  renderCreate();
  return false;
}

$("#approve-btn").addEventListener("click", async () => {
  const v = validateAll(true);
  if (!v?.ok || !canSend()) return;
  const f = state.form;
  const i = info();
  f.steps = { busy: true };
  renderCreateSend();
  try {
    if (!(await decimalsStillRight())) {
      f.steps = { approveMsg: txt("tool.create.decimalsChanged") };
      return renderCreateSend();
    }
    await send({
      address: i.token, abi: state.tokenAbi, functionName: "approve", args: [net().lathe, v.amount],
      slot: (m) => {
        f.steps.approveTx = m;
        renderCreateSend();
      },
    });
    f.steps.approvedNow = true;
    f.steps.approveTx = null;
    await refreshAccountReads();
  } catch (e) {
    f.steps.approveMsg = explain(e).text;
  }
  f.steps.busy = false;
  renderCreateSend();
});

function createdFrom(receipt, L, amount) {
  let id = null;
  for (const log of receipt.logs) {
    if (!sameAddr(log.address, L)) continue;
    try {
      const ev = state.viem.decodeEventLog({ abi: state.abi, data: log.data, topics: log.topics });
      if (ev.eventName === "OrderCreated") id = ev.args.orderId;
    } catch {
      /* other event */
    }
  }
  return { id, amount, hash: receipt._hash || receipt.transactionHash };
}

// S3: createOrder was sent but its receipt could not be read. The create button stays locked with the warning in
// view (a second click would lock the amount twice), and the page keeps looking for the receipt in the background
// on the network the transaction went to. If it shows up, the form finishes as normal; until then a reload is
// the only way to unlock, and the warning names the hash to check first.
async function watchUnconfirmedCreate(err, L, amount, key) {
  const f = state.form;
  for (let tries = 0; tries < 40 && f.steps.unconfirmed === err.hash; tries++) {
    await new Promise((r) => setTimeout(r, UNCONFIRMED_RETRY_MS));
    if (f.steps.unconfirmed !== err.hash) return;
    let receipt = null;
    try {
      receipt = await err.pub.getTransactionReceipt({ hash: err.hash });
    } catch {
      continue; /* not found yet, or the node is still failing */
    }
    if (state.netKey !== key || f.steps.unconfirmed !== err.hash) return;
    if (receipt.status === "success") {
      f.result = createdFrom(receipt, L, amount);
      f.steps = {};
      refreshAccountReads();
    } else {
      f.steps = { createMsg: txt("tool.tx.reverted") };
    }
    return renderCreateSend();
  }
}
const UNCONFIRMED_RETRY_MS = Number(globalThis.LATHE_TEST_CONFIG?.unconfirmedRetryMs) || 10_000;

$("#create-btn").addEventListener("click", async () => {
  if (state.form.steps.unconfirmed) return;
  applyOutputs();
  const v = validateAll(true);
  if (!v?.ok || !canSend()) return;
  const f = state.form;
  const L = net().lathe;
  const key = state.netKey;
  const table = T.toHex(T.encodeTable(f.nIn, f.nOut, f.answers, f.nState));
  // No memory: createOrder. One memory bit: createStatefulOrder, checked with the circuit's step function.
  // With input names, the overload that takes them (the label-less overloads stay for orders without names).
  const call = f.nState
    ? { functionName: "createStatefulOrder", args: [f.nIn, f.nOut, f.nState, table, v.amount, v.deadline, v.builder, v.maxGates] }
    : { functionName: "createOrder", args: [f.nIn, f.nOut, table, v.amount, v.deadline, v.builder, v.maxGates] };
  if (v.labels.length) call.args.push(v.labels);
  f.result = null;
  f.steps = { ...f.steps, busy: true, createMsg: null, approveMsg: null };
  renderCreateSend();
  try {
    if (!(await decimalsStillRight())) {
      f.steps = { createMsg: txt("tool.create.decimalsChanged") };
      return renderCreateSend();
    }
    const receipt = await send({
      address: L, abi: state.abi, ...call,
      slot: (m) => {
        f.steps.createTx = m;
        renderCreateSend();
      },
    });
    f.result = createdFrom(receipt, L, v.amount);
    f.steps = {};
    await refreshAccountReads();
  } catch (e) {
    if (e?.name === "Unconfirmed") {
      f.steps = { unconfirmed: e.hash, createMsg: txt("tool.tx.unconfirmed", { hash: e.hash }), createTx: { hash: e.hash } };
      watchUnconfirmedCreate(e, L, v.amount, key);
    } else f.steps.createMsg = explain(e).text;
  }
  f.steps.busy = false;
  renderCreateSend();
});

function shareUrl(id) {
  const u = new URL(location.pathname, location.origin);
  u.searchParams.set("order", String(id));
  if (state.netKey !== DEFAULT_NETWORK) u.searchParams.set("net", state.netKey);
  return u.toString();
}

function renderCreateResult() {
  const box = clear($("#create-result"));
  const r = state.form.result;
  box.hidden = !r;
  if (!r) return;
  const i = info();
  box.append(el("p", { text: txt("tool.create.created", { id: String(r.id), amount: fmtAmount(r.amount), symbol: i.symbol }) }));
  const link = shareUrl(r.id);
  box.append(
    el("p", { class: "help", text: txt("tool.create.shareLabel") }),
    el("div", { class: "share" }, el("code", { class: "mono", text: link }), copyBtn(link, "tool.create.copy")),
    el("div", { class: "txline" }, el("span", { text: txt("tool.tx.hash") }), el("code", { text: r.hash }), copyBtn(r.hash, "tool.tx.copyHash")),
    el("button", { type: "button", class: "btn btn-ghost", text: txt("tool.create.openOrder", { id: String(r.id) }), on: { click: () => openOrder(r.id) } }),
  );
}

// ---------------------------------------------------------------- lookup and order view
$("#lookup-form").addEventListener("submit", (e) => {
  e.preventDefault();
  const v = $("#f-lookup").value.trim();
  if (!/^\d{1,12}$/.test(v) || BigInt(v) < 1n) {
    showErr("lookup", txt("tool.lookup.invalid"));
    return;
  }
  showErr("lookup", "");
  openOrder(BigInt(v));
});

function openOrder(id, mode = "order") {
  selectTab("lookup");
  $("#f-lookup").value = String(id);
  const reduce = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  $("#order-lookup").scrollIntoView({ behavior: reduce ? "auto" : "smooth", block: "start" });
  loadOrder(BigInt(id), { mode });
}

function renderOrderEmpty() {
  const box = clear($("#order-view"));
  box.appendChild(el("p", { class: "help", text: txt("tool.lookup.empty") }));
}

let orderSeq = 0;
async function loadOrder(id, keep = {}) {
  const seq = ++orderSeq;
  const key = state.netKey; // a result read for another network is dropped, like one for another order
  const prev = state.view && state.view.id === id ? state.view : null;
  const inputs = prev?.inputs || { processor: net().processor || "", circuit: net().mockMint ? "1" : "", n: "" };
  inputs.n = ""; // S4: the check count is worked out again from the re-read progress on every load
  state.view = {
    id, loading: true, data: prev?.data || null, error: null, inputs,
    preview: keep.preview ?? null, msgs: keep.msgs || {}, failedCase: keep.failedCase ?? null, busy: false,
    lastAction: keep.lastAction ?? null,
    mode: keep.mode ?? prev?.mode ?? "order", // "order" or "receipt" (?receipt=N)
    tryBits: prev?.tryBits || null, tryResult: null,
  };
  const p = new URLSearchParams(location.search);
  const urlKey = state.view.mode === "receipt" ? "receipt" : "order";
  p.delete(urlKey === "receipt" ? "order" : "receipt");
  p.set(urlKey, String(id));
  if (state.netKey !== DEFAULT_NETWORK) p.set("net", state.netKey);
  else p.delete("net");
  history.replaceState(null, "", location.pathname + "?" + p.toString());
  if (!keep.quiet) renderOrder();
  if (toolStatus.phase !== "ready") return;
  const L = net().lathe;
  const A = state.abi;
  try {
    const next = await read(L, A, "nextOrderId");
    let data = { next };
    if (id >= 1n && id < next) {
      const [o, table, d, block] = await readMany([
        () => read(L, A, "orders", [id]),
        () => read(L, A, "tableOf", [id]),
        () => read(L, A, "deliveries", [id]),
        () => state.pub.getBlock({ blockTag: "latest" }),
      ]);
      data = {
        next,
        order: { buyer: o[0], builder: o[1], amount: o[2], deadline: o[3], maxGates: Number(o[4]), nIn: Number(o[5]), nOut: Number(o[6]), nState: Number(o[7]), status: Number(o[8]) },
        table,
        delivery: { processor: d[0], circuitId: d[1], builder: d[2], gateCount: Number(d[3]), netlistHash: d[4], nextCase: Number(d[5]), caseGas: await readCaseGas(L, A, "caseGasOf", [id]) },
        now: block.timestamp,
        nowAt: performance.now(),
      };
      // Names are optional and a contract from before V2 has no labelsOf: a failed read shows no names.
      try {
        data.labels = decodeLabels(await read(L, A, "labelsOf", [id]));
      } catch {
        data.labels = [];
      }
      data.pieces = await readPieces(L, A, id);
      const pieced = data.pieces.length > 0;
      if (pieced) Object.assign(data, await readWiring(L, A, id, data.pieces));
      if (state.view.mode === "receipt" && data.order.status === 2) {
        const r = await read(L, A, "receipts", [id]);
        data.receipt = { processor: r[0], circuitId: r[1], tableHash: r[2], blockNumber: r[3] };
        if (pieced) data.piecedHash = await read(L, A, "piecedHash", [id]);
      }
      // Whether the order has a single circuit is read from the chain: the receipt names one (a V0-V2 circuit, a
      // top, or the piece of a 1-piece order without wires or with the identity wiring) or names none (processor 0),
      // and then ruleOf would revert NoSingleCircuit by design, so it is not asked.
      if (state.view.mode === "receipt" && data.order.status === 2 && hasSingle(data)) {
        try {
          const rule = await read(L, A, "ruleOf", [id]);
          data.rule = { processor: rule[0], circuitId: rule[1] };
        } catch (e) {
          data.rule = { error: explain(e, { read: true }).text };
        }
      }
    }
    if (seq !== orderSeq || state.netKey !== key) return;
    state.view.data = data;
    state.view.loading = false;
    if (typeof keep.after === "function") state.view.lastAction = keep.after(data);
  } catch (e) {
    if (seq !== orderSeq || state.netKey !== key) return;
    state.view.loading = false;
    state.view.error = explain(e, { read: true }).text;
  }
  renderOrder();
}

// The per-case gas stored with a delivery (caseGasOf / pieceCaseGasOf): null on a contract from before it, which
// gave every case the formula (G.caseBudget then uses the formula). A network failure is thrown, as elsewhere.
async function readCaseGas(L, A, fn, args) {
  try {
    return await read(L, A, fn, args);
  } catch (e) {
    if (explain(e, { read: true }).name === "network") throw e;
    return null;
  }
}

// A pieced order's pieces (createPiecedOrder) and each piece's record, gate cap and table. Empty for a V0-V2 order,
// and for a contract from before pieced orders (no piecesOf): that read reverts, which here means "no pieces". A
// network failure is not taken as "no pieces": it is thrown, so the view shows the read error instead of a V0 view.
async function readPieces(L, A, id) {
  let raw;
  try {
    raw = await read(L, A, "piecesOf", [id]);
  } catch (e) {
    if (explain(e, { read: true }).name === "network") throw e;
    return [];
  }
  const pieces = raw.map((p) => ({ kind: Number(p.kind), nIn: Number(p.nIn), nOut: Number(p.nOut), widthA: Number(p.widthA), widthB: Number(p.widthB) }));
  const per = await readMany(pieces.flatMap((_, i) => [
    () => read(L, A, "pieceOf", [id, BigInt(i)]),
    () => read(L, A, "pieceTableOf", [id, BigInt(i)]),
    () => read(L, A, "pieceMaxGatesOf", [id, BigInt(i)]),
  ]));
  const gasOf = await readMany(pieces.map((_, i) => () => readCaseGas(L, A, "pieceCaseGasOf", [id, BigInt(i)])));
  return pieces.map((p, i) => {
    const d = per[3 * i];
    return {
      ...p,
      delivery: { processor: d[0], circuitId: d[1], builder: d[2], gateCount: Number(d[3]), netlistHash: d[4], nextCase: Number(d[5]), caseGas: gasOf[i] },
      table: per[3 * i + 1],
      maxGates: Number(per[3 * i + 2]),
    };
  });
}

// A pieced order's wires (wiresOf) and kind (needsTop). A contract from before V4 has neither: its orders are the
// fixed join (P.defaultWires) and pay when the last piece passes. As in readPieces, a network failure is thrown.
async function readWiring(L, A, id, pieces) {
  const tryRead = async (fn, fallback) => {
    try {
      return await read(L, A, fn, [id]);
    } catch (e) {
      if (explain(e, { read: true }).name === "network") throw e;
      return fallback;
    }
  };
  const raw = await tryRead("wiresOf", null);
  const wires = raw ? raw.map(P.normWire) : P.defaultWires(pieces);
  const needsTop = (await tryRead("needsTop", false)) === true;
  return { wires, needsTop, joined: P.sameWires(wires, P.defaultWires(pieces)) };
}

/** When refund opens for this order (unix seconds, BigInt) or null: the pieced rule for a pieced order. */
function refundOpens(data) {
  const o = data.order;
  const i = info();
  if (data.pieces?.length) return G.refundOpensAtPieced(o.status, o.deadline, i.grace, data.pieces.every((p) => P.pieceState(p, p.delivery) !== "none"));
  return G.refundOpensAt(o.status, o.deadline, i.grace);
}

// Chain time, not the visitor's clock: the latest block's timestamp, moved on by the time since it was read.
function chainNow(data) {
  return data.now + BigInt(Math.floor((performance.now() - (data.nowAt ?? performance.now())) / 1000));
}

// Which gates are open at chain time t. When this changes the order view is drawn again, so "time left", the
// deliver window, the check window and the refund button move on without a reload.
function gateSig(data, t) {
  const o = data.order;
  const i = info();
  const opens = refundOpens(data);
  return [t > o.deadline, t > o.deadline + i.grace, opens !== null && t >= opens].join();
}

// A slow timer while an Open or Checking order is shown: re-read the latest block's time, then redraw if a gate
// changed, or just update the countdown text.
const TICK_MS = Number(globalThis.LATHE_TEST_CONFIG?.tickMs) || 20_000;
let ticking = false;
setInterval(async () => {
  const v = state.view;
  const o = v?.data?.order;
  if (ticking || !o || (o.status !== 0 && o.status !== 1) || v.busy || v.loading || toolStatus.phase !== "ready" || document.hidden) return;
  ticking = true;
  const id = v.id;
  const key = state.netKey;
  try {
    const before = gateSig(v.data, chainNow(v.data));
    const block = await state.pub.getBlock({ blockTag: "latest" });
    if (state.view !== v || v.id !== id || state.netKey !== key || v.busy) return;
    v.data.now = block.timestamp;
    v.data.nowAt = performance.now();
    if (gateSig(v.data, v.data.now) !== before) renderOrder();
    else setText("#deadline-left", leftText(o, v.data.now));
  } catch {
    /* keep the last known time; the next tick tries again */
  } finally {
    ticking = false;
  }
}, TICK_MS);

function leftText(o, now) {
  const remaining = o.deadline - now;
  return remaining > 0n ? txt("tool.order.left", { t: fmtDur(remaining) }) : txt("tool.order.ago", { t: fmtDur(-remaining) });
}

function renderOrder() {
  const box = clear($("#order-view"));
  const v = state.view;
  box.removeAttribute("data-status");
  box.removeAttribute("data-view");
  box.removeAttribute("aria-busy");
  // No contract on this network (mainnet today), or it failed to load: the tool notice says so and offers the way
  // on. Nothing is loading here, so the order view stays empty instead of showing "Loading order N" for ever.
  if (toolStatus.phase !== "ready" && toolStatus.phase !== "loading") return;
  if (!v) return renderOrderEmpty();
  if (v.loading && !v.data) {
    box.setAttribute("aria-busy", "true");
    box.append(
      el("p", { class: "sr-only", text: txt("tool.order.loading", { id: String(v.id) }) }),
      el("div", { class: "ov" },
        el("div", { class: "ov-head" }, el("div", { class: "sk sk-title" })),
        el("div", { class: "ov-main" }, el("div", { class: "sk sk-block" }), el("div", { class: "sk sk-table" })),
        el("div", { class: "ov-side" }, el("div", { class: "sk sk-block" }))),
    );
    return;
  }
  if (v.error) {
    box.append(el("div", { class: "notice is-error" }, el("p", { text: v.error }),
      el("button", { type: "button", class: "btn btn-ghost", text: txt("tool.load.retry"), on: { click: () => loadOrder(v.id) } })));
    return;
  }
  const data = v.data;
  if (!data) return;
  const netName = txt("tool.network." + net().key);
  if (!data.order) {
    const last = data.next - 1n;
    box.append(el("p", { class: "msg", text: last >= 1n ? txt("tool.order.notFound", { id: String(v.id), net: netName, last: String(last) }) : txt("tool.order.notFoundNone", { net: netName }) }));
    box.setAttribute("data-status", "none");
    return;
  }
  const o = data.order;
  const d = data.delivery;
  const i = info();
  const cases = T.caseCount(o.nIn, o.nState);
  box.setAttribute("data-status", String(o.status));
  if (v.mode === "receipt") return data.pieces?.length ? renderPiecedReceipt(box, v, data) : renderReceipt(box, v, data);
  if (data.pieces?.length) return renderPiecedOrder(box, v, data);
  const you = (a) => (sameAddr(a, state.account) ? " (" + txt("tool.order.you") + ")" : "");

  const head = el("div", { class: "ov-head" },
    el("h3", { text: txt("tool.order.title", { id: String(v.id) }) }),
    el("span", { class: "badge s-" + o.status, id: "order-status", text: txt("tool.order.status." + o.status) }),
    el("button", { type: "button", class: "btn btn-quiet btn-sm", text: txt("tool.order.refresh"), on: { click: () => loadOrder(v.id) } }),
    o.status === 2 ? el("button", { type: "button", class: "btn btn-ghost btn-sm", id: "receipt-btn", text: txt("tool.receipt.view"), on: { click: () => openOrder(v.id, "receipt") } }) : null,
    el("p", { class: "help", text: txt("tool.order.statusHelp." + o.status) }),
    v.lastAction ? el("p", { class: "msg " + (v.lastAction.err ? "is-err" : "is-ok"), role: "status", id: "last-action", text: txt(v.lastAction.key, v.lastAction.vars) }) : null);

  const now = chainNow(data);
  const payout = i.feeBps > 0 ? txt("tool.payout", { net: fmtAmount(G.payoutAfterFee(o.amount, i.feeBps)), symbol: i.symbol, pct: G.feePercent(i.feeBps) }) : null;
  const facts = el("dl", { class: "facts" },
    fact("tool.order.amount", el("span", {}, el("span", { class: "mono", text: fmtAmount(o.amount) + " " + i.symbol }),
      payout ? el("span", { class: "sub", id: "order-payout", text: payout }) : null)),
    fact("tool.order.deadline", el("span", {}, el("span", { class: "mono", text: fmtDate(o.deadline) }),
      el("span", { class: "sub", id: "deadline-left", text: leftText(o, now) }))),
    fact("tool.order.buyer", el("span", { class: "mono", text: o.buyer + you(o.buyer) }), true),
    fact("tool.order.builder", el("span", { class: "mono", text: o.builder + you(o.builder) }), true),
    fact("tool.order.shape", el("span", { text: txt(o.nState ? "tool.order.shapeValState" : "tool.order.shapeVal", { nIn: o.nIn, nOut: o.nOut, cases }) })),
    fact("tool.order.maxGates", el("span", { class: "mono", text: o.maxGates ? fmtInt(o.maxGates) : txt("tool.order.noCap") })));

  const hasDelivery = d.processor && !/^0x0{40}$/i.test(d.processor);
  const dbox = el("div", { class: "box" }, el("h4", { text: txt("tool.order.deliveryHeading") }));
  if (!hasDelivery) dbox.append(el("p", { class: "help", text: txt("tool.order.noDelivery") }));
  else {
    dbox.append(el("dl", { class: "facts" },
      fact("tool.order.processor", el("span", { class: "mono", text: d.processor }), true),
      fact("tool.order.circuitId", el("span", { class: "mono", text: d.circuitId.toString() })),
      fact("tool.order.gates", el("span", { class: "mono", text: fmtInt(d.gateCount) })),
      fact("tool.order.progress", el("span", { class: "mono", text: txt("tool.order.progressVal", { n: d.nextCase, total: cases }) }))));
  }

  let answers = null;
  try {
    answers = T.decodeTable(o.nIn, o.nOut, state.viem.hexToBytes(data.table), o.nState);
  } catch {
    answers = null;
  }
  const tbox = el("div", { class: "create-table" }, el("h4", { class: "label-like", text: txt("tool.order.tableHeading") }));
  if (answers) {
    const scroller = el("div", { class: "tt-scroll" }, buildTable(o.nIn, o.nOut, answers, { editable: false, failedCase: v.failedCase, nState: o.nState, labels: data.labels }));
    tbox.append(scroller);
    tbox.append(el("p", { class: "help bytes-line" }, el("span", { text: txt("tool.create.tableBytes") }), " ", el("code", { class: "mono", text: data.table })));
  }

  const side = el("div", { class: "ov-side" });
  if (o.status === 0) side.append(deliverBox(o, now));
  if (o.status === 1) side.append(checkBox(o, d, now));
  if (o.status === 0 || o.status === 1) side.append(refundBox(o, now));

  box.append(el("div", { class: "ov" }, head, el("div", { class: "ov-main" }, facts, dbox, tbox), side));

  if (v.failedCase !== null) {
    const row = box.querySelector(`tr[data-case="${v.failedCase}"]`);
    const sc = row?.closest(".tt-scroll");
    if (row && sc) sc.scrollTop = Math.max(0, row.offsetTop - sc.clientHeight / 2);
  }
}

function fact(labelKey, valueNode, wide = false) {
  return el("div", { class: wide ? "wide" : null }, el("dt", { text: txt(labelKey) }), el("dd", {}, valueNode));
}

function msgNode(m) {
  if (!m) return null;
  const text = m.text ?? txt(m.key, m.vars);
  return el("p", { class: "msg " + (m.err ? "is-err" : "is-ok"), role: m.err ? "alert" : "status", text });
}

function deliverBox(o, now) {
  const v = state.view;
  const n = net();
  const box = el("div", { class: "box", id: "deliver-box" }, el("h4", { text: txt("tool.deliver.heading") }));
  if (now > o.deadline) {
    box.append(el("p", { class: "help", text: txt("tool.deliver.closed") }));
    return box;
  }
  // Off while a read or a delivery is out, so its read-out never sits next to a different processor or circuit.
  const procIn = el("input", { class: "input mono", id: "f-proc", type: "text", autocomplete: "off", spellcheck: "false", "aria-describedby": "proc-help", value: v.inputs.processor, disabled: !!v.busy });
  const circIn = el("input", { class: "input mono", id: "f-circ", type: "text", inputmode: "numeric", autocomplete: "off", "aria-describedby": "circ-help circ-err", value: v.inputs.circuit, disabled: !!v.busy });
  procIn.addEventListener("input", () => {
    v.inputs.processor = procIn.value.trim();
    v.preview = null;
  });
  circIn.addEventListener("input", () => {
    v.inputs.circuit = circIn.value.trim();
    v.preview = null;
  });
  box.append(
    el("div", { class: "field" }, el("label", { for: "f-proc", text: txt("tool.deliver.processorLabel") }),
      el("p", { class: "help", id: "proc-help", text: txt(n.mockMint ? "tool.deliver.processorHelpTestnet" : "tool.deliver.processorHelp") }), procIn,
      el("p", { class: "err", id: "proc-err", text: v.msgs.procErr || "" })),
    el("div", { class: "field" }, el("label", { for: "f-circ", text: txt("tool.deliver.circuitLabel") }),
      el("p", { class: "help", id: "circ-help", text: txt("tool.deliver.circuitHelp") }), circIn,
      el("p", { class: "err", id: "circ-err", text: v.msgs.circErr || "" })),
  );
  const readLabel = v.busy === "read" && v.testing ? txt("tool.deliver.caseGas.testing", { n: v.testing.n, total: v.testing.total }) : txt(v.busy === "read" ? "tool.deliver.reading" : "tool.deliver.readBtn");
  const readBtn = el("button", { type: "button", class: "btn btn-ghost", id: "read-circuit", text: readLabel, disabled: !!v.busy });
  readBtn.addEventListener("click", () => readCircuit(o));
  box.append(readBtn);

  const pv = v.preview;
  if (pv) {
    const row = (k, a, b, ok) => el("tr", {}, el("th", { scope: "row", text: txt(k) }), el("td", { class: "mono", text: a }), el("td", { class: "mono" + (ok ? "" : " bad"), text: b }),
      el("td", { class: ok ? "" : "bad", text: txt(ok ? "tool.deliver.match" : "tool.deliver.noMatch") }));
    box.append(el("table", { class: "cmp" },
      el("thead", {}, el("tr", {}, el("th", { scope: "col", text: txt("tool.deliver.colWhat") }), el("th", { scope: "col", text: txt("tool.deliver.colOrder") }), el("th", { scope: "col", text: txt("tool.deliver.colCircuit") }), el("th", { scope: "col" }))),
      el("tbody", {},
        row("tool.deliver.rowInputs", String(o.nIn), String(pv.nIn), pv.nIn === o.nIn),
        row("tool.deliver.rowOutputs", String(o.nOut), String(pv.nOut), pv.nOut === o.nOut),
        row("tool.deliver.rowMemory", String(o.nState), String(pv.nState), pv.nState === o.nState),
        row("tool.deliver.rowGates", o.maxGates ? "≤ " + fmtInt(o.maxGates) : txt("tool.order.noCap"), fmtInt(pv.gates), !o.maxGates || pv.gates <= o.maxGates))));
    const problems = [];
    if (!pv.isCpu) problems.push(txt("tool.deliver.notCpu"));
    if (pv.owner && state.account && !sameAddr(pv.owner, state.account)) problems.push(txt("tool.deliver.notOwner"));
    if (pv.nIn !== o.nIn || pv.nOut !== o.nOut || pv.nState !== o.nState) problems.push(txt("tool.deliver.shapeBad"));
    if (o.maxGates && pv.gates > o.maxGates) problems.push(txt("tool.deliver.tooMany", { g: fmtInt(pv.gates), max: fmtInt(o.maxGates) }));
    if (pv.formula > info().maxCaseGas) problems.push(txt("tool.deliver.tooBig"));
    if (pv.plan?.kind === "tooBig") problems.push(txt("tool.deliver.caseGas.tooBig", { c: pv.plan.worstCase, need: fmtInt(pv.plan.worst), max: fmtInt(info().maxCaseGas) }));
    for (const pmsg of problems) box.append(el("p", { class: "msg is-err", text: pmsg }));
    box.append(el("div", { class: "gasinfo" },
      el("p", {}, txt("tool.deliver.budget", { budget: "" }), el("span", { class: "mono", id: "deliver-budget", text: fmtInt(pv.budget) })),
      el("p", { class: "help", id: "budget-refs", text: txt("tool.deliver.budgetRefs") }),
      caseGasNode(pv),
      el("p", { text: pv.inline ? txt("tool.deliver.inlineYes", { cases: T.caseCount(o.nIn, o.nState) }) : txt("tool.deliver.inlineNo") }),
      el("p", {}, txt("tool.deliver.gasLimit", { gas: "" }), el("span", { class: "mono", text: fmtInt(pv.gas) })),
      el("p", { text: txt("tool.deliver.gasWhy") }),
      pv.capped ? el("p", { class: "msg is-err", text: txt("tool.deliver.gasCapped") }) : null));
  }

  let gate = null;
  if (!state.account) gate = txt("tool.wallet.needWallet");
  else if (!sameAddr(state.account, o.builder)) gate = txt("tool.deliver.onlyBuilder", { addr: short(o.builder) });
  else if (wrongNetwork()) gate = txt("tool.wallet.wrongNet", { net: txt("tool.network." + n.key) });
  const label = v.busy === "deliver" ? txt("tool.deliver.simulating") : txt("tool.deliver.deliverBtn", { id: v.inputs.circuit || "" }).trim();
  const dBtn = el("button", { type: "button", class: "btn btn-primary", id: "deliver-btn", text: label, disabled: !!gate || !!v.busy || pv?.plan?.kind === "tooBig" });
  dBtn.addEventListener("click", () => doDeliver(o));
  box.append(dBtn);
  if (gate) box.append(el("p", { class: "help", text: gate }));
  if (v.msgs.deliverTx) {
    const tl = el("div", { class: "txline" });
    txLine(tl, v.msgs.deliverTx);
    box.append(tl);
  }
  const mn = msgNode(v.msgs.deliver);
  if (mn) box.append(mn);
  return box;
}

// What testing every case found, and what the page will do about it (G.planCaseGas).
function caseGasNode(pv) {
  const p = pv.plan;
  if (!p) return null;
  const i = info();
  const wrap = el("div", { id: "casegas", "data-kind": p.kind, "data-declared": pv.caseGas.toString() });
  const say = (key, vars, cls = "") => wrap.append(el("p", { class: cls, text: txt("tool.deliver.caseGas." + key, vars) }));
  if (p.worstCase >= 0) say("worst", { c: p.worstCase, need: fmtInt(p.worst) });
  if (p.kind === "formula") say("fits", { formula: fmtInt(p.formula) });
  if (p.kind === "declare" && i.hasCaseGas) {
    say("declare", { formula: fmtInt(p.formula), gas: fmtInt(p.proposed) });
    say("txs", { declared: pv.txs.declared ?? "-", formula: pv.txs.formula ?? "-" });
  }
  if (p.kind === "declare" && !i.hasCaseGas) say("oldContract", { formula: fmtInt(p.formula) }, "msg is-err");
  if (p.untested.length) {
    const list = p.untested.length > 8 ? p.untested.slice(0, 8).join(", ") + ", ..." : p.untested.join(", ");
    say("untested", { n: p.untested.length, list, cap: fmtInt(G.SIM_GAS_CAP) }, "msg is-err");
  }
  return wrap;
}

function parseDeliverInputs() {
  const v = state.view;
  v.msgs.procErr = "";
  v.msgs.circErr = "";
  const p = v.inputs.processor;
  const c = v.inputs.circuit;
  let ok = true;
  if (!p || !state.viem.isAddress(p)) {
    v.msgs.procErr = txt(p ? "tool.create.errors.builder.invalid" : "tool.create.errors.builder.invalid");
    ok = false;
  }
  if (!/^\d{1,30}$/.test(c || "")) {
    v.msgs.circErr = txt("tool.deliver.circuitInvalid");
    ok = false;
  }
  return ok ? { processor: state.viem.getAddress(p), id: BigInt(c) } : null;
}

async function readCircuit(o) {
  const v = state.view;
  const inp = parseDeliverInputs();
  if (!inp) return renderOrder();
  const asked = v.inputs.processor + "|" + v.inputs.circuit;
  v.busy = "read";
  v.msgs.deliver = null;
  renderOrder();
  const i = info();
  try {
    const isCpu = await read(i.factory, state.factoryAbi, "isCPU", [inp.processor]);
    let owner = null;
    try {
      owner = await read(inp.processor, state.procAbi, "ownerOf", [inp.id]);
    } catch {
      owner = null;
    }
    if (!owner && isCpu) {
      v.preview = null;
      v.msgs.deliver = { err: true, text: txt("tool.deliver.noCircuit", { id: inp.id.toString() }) };
    } else if (!isCpu) {
      v.preview = null;
      v.msgs.deliver = { err: true, text: txt("tool.deliver.notCpu") };
    } else {
      const ci = await read(inp.processor, state.procAbi, "circuitInfo", [inp.id]);
      const gates = Number(ci[3]);
      const formula = await read(net().lathe, state.abi, "evalBudget", [BigInt(gates)]);
      const shape = { nIn: Number(ci[0]), nOut: Number(ci[1]), nState: Number(ci[2]) };
      const cases = T.caseCount(o.nIn, o.nState);
      // Every case on its own, before anything is sent (only when the shape matches; otherwise the contract
      // refuses anyway and the inputs would not fit the circuit).
      let plan = null;
      if (shape.nIn === o.nIn && shape.nOut === o.nOut && shape.nState === o.nState) {
        const needs = await measureCases(o, inp, cases, () => state.view === v && v.inputs.processor + "|" + v.inputs.circuit === asked);
        if (needs) plan = G.planCaseGas(i, gates, needs);
      }
      // Declare only when a case needs more than the formula with the margin, and the contract takes a declared gas.
      const caseGas = plan && plan.kind === "declare" && i.hasCaseGas ? plan.proposed : 0n;
      const budget = caseGas > 0n ? caseGas : formula;
      const g = G.deliverGasLimit(i, cases, gates, caseGas);
      const txs = { formula: G.checkTxCount(i, cases, gates), declared: caseGas > 0n ? G.checkTxCount(i, cases, gates, caseGas) : null };
      v.preview = { processor: inp.processor, id: inp.id, isCpu, owner, ...shape, gates, formula, budget, caseGas, plan, txs, ...g };
    }
  } catch (e) {
    v.preview = null;
    v.msgs.deliver = { err: true, text: explain(e, { read: true }).text };
  }
  v.busy = false;
  v.testing = null;
  if (state.view !== v) return;
  // The boxes are off while the read is out; if they changed anyway, this read-out is for other inputs.
  if (v.inputs.processor + "|" + v.inputs.circuit !== asked) {
    v.preview = null;
    v.msgs.deliver = null;
  }
  renderOrder();
}

// Each case as its own eth_estimateGas on a call straight to the processor's eval (step for a memory order): a
// fresh simulated transaction, so everything the case touches is cold, as for the first case of a check
// transaction. The estimate minus the call's intrinsic gas is what the circuit must be handed. The call is capped at
// SIM_GAS_CAP because public nodes cut eth_call at 50M gas; a case that does not finish under it is tried once more
// with G.simRetryCap (which a capped node cuts to 50M again), and a case that still does not finish, or fails, is
// null, "could not test", and never counts as fitting. Returns null when the view or the inputs changed meanwhile.
async function measureCases(o, inp, cases, still) {
  const v = state.view;
  const needs = [];
  const mask = (1 << o.nIn) - 1;
  for (let c = 0; c < cases; c++) {
    if (!still()) return null;
    v.testing = { n: c + 1, total: cases };
    renderOrder();
    const inputs = T.toHex(T.pack(c & mask, o.nIn));
    const data = o.nState
      ? state.viem.encodeFunctionData({ abi: state.procAbi, functionName: "step", args: [inp.id, T.toHex(T.pack(c >> o.nIn, o.nState)), inputs] })
      : state.viem.encodeFunctionData({ abi: state.procAbi, functionName: "eval", args: [inp.id, inputs] });
    let need = null;
    for (const cap of [G.SIM_GAS_CAP, G.simRetryCap(info())]) {
      try {
        const est = await state.pub.request({ method: "eth_estimateGas", params: [{ to: inp.processor, data, gas: state.viem.toHex(cap) }] });
        need = G.needFromEstimate(BigInt(est), data);
        break;
      } catch (e) {
        if (explain(e, { read: true }).name === "network") throw e;
      }
    }
    needs.push(need);
  }
  return still() ? needs : null;
}

async function doDeliver(o) {
  const v = state.view;
  if (!v.preview || v.preview.processor !== safeAddr(v.inputs.processor) || v.preview.id.toString() !== v.inputs.circuit) {
    await readCircuit(o);
    if (!v.preview) return;
  }
  if (!canSend()) return;
  const pv = v.preview;
  if (pv.plan && pv.plan.kind === "tooBig") {
    v.msgs.deliver = { err: true, text: txt("tool.deliver.caseGas.tooBig", { c: pv.plan.worstCase, need: fmtInt(pv.plan.worst), max: fmtInt(info().maxCaseGas) }) + " " + txt("tool.deliver.refusedNotSent") };
    return renderOrder();
  }
  v.busy = "deliver";
  v.failedCase = null;
  v.msgs.deliver = null;
  renderOrder();
  const L = net().lathe;
  const key = state.netKey;
  try {
    const receipt = await send({
      address: L, abi: state.abi, functionName: "deliver", gas: pv.gas,
      // The four-argument overload when the page declares a per-case gas; otherwise the old call, unchanged.
      args: pv.caseGas > 0n ? [v.id, pv.processor, pv.id, Number(pv.caseGas)] : [v.id, pv.processor, pv.id],
      slot: (m) => {
        v.msgs.deliverTx = m;
        renderOrder();
      },
    });
    v.busy = false;
    v.msgs.deliverTx = null;
    if (state.netKey !== key) return;
    const paid = parseEvents(receipt, L).some((e) => e.eventName === "Paid");
    const done = paid ? { key: "tool.deliver.paid" } : pv.caseGas > 0n ? { key: "tool.deliver.recordedDeclared", vars: { gas: fmtInt(pv.caseGas) } } : { key: "tool.deliver.recorded" };
    return loadOrder(v.id, { quiet: true, lastAction: done });
  } catch (e) {
    v.busy = false;
    if (afterSendFailure(e, v, "deliverTx", "deliver", key)) return;
    v.msgs.deliverTx = null;
    const x = explain(e, { nIn: o.nIn, nState: o.nState, action: "deliver" });
    v.msgs.deliver = { err: true, text: x.name === "rejected" || x.name === "wrongChain" ? x.text : x.text + (x.name === "WrongAnswer" || x.name === "NotCircuitOwner" || x.name === "ShapeMismatch" || x.name === "TooManyGates" || x.name === "NotProcessor" ? " " + txt("tool.deliver.refusedNotSent") : "") };
    if (x.name === "WrongAnswer") v.failedCase = x.caseIndex;
    renderOrder();
  }
}

// Failures that happen after the transaction exists (B2, S3). Reverted: reload the order and say the
// transaction failed. Unconfirmed: keep the hash on screen with the warning. Returns true when handled.
function afterSendFailure(e, v, txSlot, msgSlot, key) {
  if (e?.name === "Reverted") {
    v.msgs[txSlot] = null;
    if (state.netKey === key && state.view === v) loadOrder(v.id, { quiet: true, lastAction: { err: true, key: "tool.tx.reverted" } });
    return true;
  }
  if (e?.name === "Unconfirmed") {
    v.msgs[txSlot] = { hash: e.hash };
    v.msgs[msgSlot] = { err: true, text: txt("tool.tx.unconfirmed", { hash: e.hash }) };
    if (state.view === v) renderOrder();
    return true;
  }
  return false;
}

function parseEvents(receipt, lathe) {
  const out = [];
  for (const log of receipt.logs) {
    if (!sameAddr(log.address, lathe)) continue;
    try {
      out.push(state.viem.decodeEventLog({ abi: state.abi, data: log.data, topics: log.topics }));
    } catch {
      /* not ours */
    }
  }
  return out;
}

function checkBox(o, d, now) {
  const v = state.view;
  const i = info();
  const box = el("div", { class: "box", id: "check-box" }, el("h4", { text: txt("tool.check.heading") }));
  const total = T.caseCount(o.nIn, o.nState);
  box.append(el("p", { class: "mono", text: txt("tool.order.progressVal", { n: d.nextCase, total }) }));
  if (now > o.deadline + i.grace) {
    box.append(el("p", { class: "help", text: txt("tool.check.graceOver") }));
    return box;
  }
  const remaining = total - d.nextCase;
  const fit = Number(G.maxCasesPerCheck(i, d.gateCount, d.caseGas));
  const maxN = Math.max(1, Math.min(remaining, fit));
  if (!v.inputs.n || Number(v.inputs.n) > maxN) v.inputs.n = String(maxN);
  const nIn = el("input", { class: "input mono", id: "f-checkn", type: "text", inputmode: "numeric", autocomplete: "off", "aria-describedby": "checkn-help checkn-err", value: v.inputs.n, disabled: !!v.busy });
  nIn.addEventListener("input", () => (v.inputs.n = nIn.value.trim()));
  box.append(el("div", { class: "field" }, el("label", { for: "f-checkn", text: txt("tool.check.label") }),
    el("p", { class: "help", id: "checkn-help", text: txt("tool.check.help", { remaining, fit: Math.max(1, fit) }) }), nIn,
    el("p", { class: "err", id: "checkn-err", text: v.msgs.checkErr || "" })));
  if (G.simCases(i, 1, d.gateCount, G.SIM_GAS_CAP, d.caseGas) === 0) box.append(el("p", { class: "help", id: "check-nosim", text: txt("tool.check.noSim") }));
  const n = Number(v.inputs.n);
  const gas = Number.isInteger(n) && n > 0 ? G.checkGasLimit(i, n, d.gateCount, d.caseGas) : null;
  if (gas) {
    const declared = d.caseGas && d.caseGas > G.evalBudget(i, d.gateCount);
    box.append(el("div", { class: "gasinfo" },
      el("p", {}, txt("tool.deliver.budget", { budget: "" }), el("span", { class: "mono", id: "check-budget", text: fmtInt(G.caseBudget(i, d.gateCount, d.caseGas)) })),
      declared ? el("p", { class: "help", id: "check-declared", text: txt("tool.check.declared") }) : null,
      el("p", {}, txt("tool.deliver.gasLimit", { gas: "" }), el("span", { class: "mono", text: fmtInt(gas) })),
      el("p", { text: txt("tool.deliver.gasWhy") })));
  }
  let gate = null;
  if (!state.account) gate = txt("tool.wallet.needWallet");
  else if (wrongNetwork()) gate = txt("tool.wallet.wrongNet", { net: txt("tool.network." + net().key) });
  const btn = el("button", { type: "button", class: "btn btn-primary", id: "check-btn", text: txt("tool.check.btn"), disabled: !!gate || !!v.busy });
  btn.addEventListener("click", () => doCheck(o, d, maxN));
  box.append(btn);
  if (gate) box.append(el("p", { class: "help", text: gate }));
  if (v.msgs.checkTx) {
    const tl = el("div", { class: "txline" });
    txLine(tl, v.msgs.checkTx);
    box.append(tl);
  }
  const mn = msgNode(v.msgs.check);
  if (mn) box.append(mn);
  return box;
}

async function doCheck(o, d, maxN) {
  const v = state.view;
  const i = info();
  const n = Number(v.inputs.n);
  if (!/^\d+$/.test(v.inputs.n) || n < 1 || n > maxN) {
    v.msgs.checkErr = txt("tool.check.invalid", { max: maxN });
    return renderOrder();
  }
  v.msgs.checkErr = "";
  if (!canSend()) return;
  v.busy = "check";
  v.msgs.check = null;
  renderOrder();
  // B1: the public RPCs run eth_call with at most 50M gas. The simulation runs only as many cases as fit under
  // SIM_GAS_CAP (it still catches GraceOver, NotChecking, CircuitChanged); if not even one case fits it is skipped.
  // A check that reverts only wastes its gas: it cannot move money. The real transaction runs all n cases with
  // the full explicit gas limit.
  const k = G.simCases(i, n, d.gateCount, G.SIM_GAS_CAP, d.caseGas);
  const L = net().lathe;
  const key = state.netKey;
  const total = T.caseCount(o.nIn, o.nState);
  try {
    const receipt = await send({
      address: L, abi: state.abi, functionName: "check", args: [v.id, BigInt(n)], gas: G.checkGasLimit(i, n, d.gateCount, d.caseGas),
      simulate: k > 0 ? { args: [v.id, BigInt(k)], gas: G.checkGasLimit(i, k, d.gateCount, d.caseGas) } : false,
      slot: (m) => {
        v.msgs.checkTx = m;
        renderOrder();
      },
    });
    v.busy = false;
    v.msgs.checkTx = null;
    if (state.netKey !== key) return;
    const rej = parseEvents(receipt, L).find((e) => e.eventName === "Rejected");
    const failedCase = rej ? Number(rej.args.caseIndex) : null;
    // B2: progress comes from the order as read after the transaction, not from what was asked for.
    await loadOrder(v.id, {
      failedCase, quiet: true,
      after: (data) => {
        if (rej) return { key: "tool.check.rejected", vars: { c: failedCase, inputs: inputsLabel(failedCase, o.nIn, o.nState) }, err: true };
        if (data.order?.status === 2) return { key: "tool.check.passed" };
        return { key: "tool.check.more", vars: { n: data.delivery?.nextCase ?? 0, total } };
      },
    });
  } catch (e) {
    v.busy = false;
    if (afterSendFailure(e, v, "checkTx", "check", key)) return;
    v.msgs.checkTx = null;
    v.msgs.check = { err: true, text: explain(e, { nIn: o.nIn, nState: o.nState, action: "check" }).text };
    renderOrder();
  }
}

// ---------------------------------------------------------------- receipt view (?receipt=N)
// No wallet needed: everything here is a read. The table fingerprint and ruleOf are checked against what is shown,
// and a run answer is compared with the table, so a mismatch is said out loud instead of shown as fact.
function renderReceipt(box, v, data) {
  const o = data.order;
  const i = info();
  box.setAttribute("data-view", "receipt");
  const head = el("div", { class: "ov-head" },
    el("h3", { text: txt("tool.receipt.title", { id: String(v.id) }) }),
    el("span", { class: "badge s-" + o.status, id: "order-status", text: txt("tool.order.status." + o.status) }),
    el("button", { type: "button", class: "btn btn-quiet btn-sm", id: "receipt-refresh", text: txt("tool.order.refresh"), on: { click: () => loadOrder(v.id) } }),
    el("button", { type: "button", class: "btn btn-ghost btn-sm", id: "open-order-btn", text: txt("tool.receipt.openOrder", { id: String(v.id) }), on: { click: () => openOrder(v.id, "order") } }));
  if (o.status !== 2 || !data.receipt) {
    box.append(el("div", { class: "ov" }, head, el("div", { class: "ov-main" }, el("p", { class: "msg", id: "receipt-none", text: txt("tool.receipt.notPaid", { id: String(v.id) }) }))));
    return;
  }
  const r = data.receipt;
  head.append(el("p", { class: "help", text: txt("tool.receipt.help") }));
  // The contract's fingerprint: keccak256(abi.encodePacked(uint8 nIn, uint8 nOut, uint8 nState, table)), so the
  // same bytes under another shape do not match.
  const fp = state.viem.keccak256(state.viem.encodePacked(["uint8", "uint8", "uint8", "bytes"], [o.nIn, o.nOut, o.nState, data.table]));
  const hashOk = fp.toLowerCase() === String(r.tableHash).toLowerCase();
  const rule = data.rule || {};
  const ruleOk = !rule.error && sameAddr(rule.processor, r.processor) && rule.circuitId === r.circuitId;
  const facts = el("dl", { class: "facts", id: "receipt-facts" },
    fact("tool.receipt.processor", el("span", { class: "mono", text: r.processor }), true),
    fact("tool.receipt.circuitId", el("span", { class: "mono", text: r.circuitId.toString() })),
    fact("tool.receipt.block", el("span", { class: "mono", text: fmtInt(r.blockNumber) })),
    fact("tool.receipt.tableHash", el("span", {}, el("span", { class: "mono", text: r.tableHash }),
      el("span", { class: "sub" + (hashOk ? "" : " bad"), id: "receipt-hash", text: txt(hashOk ? "tool.receipt.hashOk" : "tool.receipt.hashBad") })), true),
    fact("tool.receipt.ruleOf", el("span", { class: ruleOk ? "" : "bad", id: "receipt-rule", text: rule.error || txt(ruleOk ? "tool.receipt.ruleOk" : "tool.receipt.ruleBad", { id: String(v.id) }) }), true),
    fact("tool.order.shape", el("span", { text: txt(o.nState ? "tool.order.shapeValState" : "tool.order.shapeVal", { nIn: o.nIn, nOut: o.nOut, cases: T.caseCount(o.nIn, o.nState) }) })));
  let answers = null;
  try {
    answers = T.decodeTable(o.nIn, o.nOut, state.viem.hexToBytes(data.table), o.nState);
  } catch {
    answers = null;
  }
  const tbox = el("div", { class: "create-table" }, el("h4", { class: "label-like", text: txt("tool.order.tableHeading") }));
  if (answers) tbox.append(el("div", { class: "tt-scroll" }, buildTable(o.nIn, o.nOut, answers, { editable: false, nState: o.nState, labels: data.labels })));
  const side = el("div", { class: "ov-side" }, tryBox(o, data.delivery, answers, data.labels, i));
  box.append(el("div", { class: "ov" }, head, el("div", { class: "ov-main" }, facts, tbox), side));
}

// ---------------------------------------------------------------- pieced orders (createPiecedOrder), read only
// A pieced order has no table in tableOf and no delivery in deliveries: everything here comes from piecesOf,
// pieceOf, pieceTableOf and pieceMaxGatesOf. Creating and delivering pieces through the page comes later; the
// view says how it is done instead of offering the V0 deliver and check boxes.
function pieceKindText(p) {
  if (p.kind === P.KIND.Table) return txt("tool.pieces.kindTable");
  const vars = { wa: p.widthA, wb: p.widthB, aLast: p.widthA - 1, bFirst: p.widthA, bLast: p.widthA + p.widthB - 1, nOut: p.nOut };
  return txt(p.kind === P.KIND.Add ? "tool.pieces.kindAdd" : "tool.pieces.kindGe", vars);
}

function joinText(pieces) {
  const a = pieces[0];
  const b = pieces[1];
  if (b.nIn === a.nOut) return txt("tool.pieces.joinNoExtra", { aLast: a.nIn - 1, aOut: a.nOut });
  return txt("tool.pieces.joinExtra", { aLast: a.nIn - 1, aOut: a.nOut, aOutLast: a.nOut - 1, from: a.nIn, last: P.topInputs(pieces) - 1, bLast: b.nIn - 1 });
}

function pieceStateText(p) {
  const st = P.pieceState(p, p.delivery);
  const total = 2n ** BigInt(p.nIn);
  if (st === "none") return txt("tool.pieces.stateNone");
  if (st === "passed") return txt("tool.pieces.statePassed", { total: fmtInt(total) });
  return txt("tool.pieces.stateChecking", { n: fmtInt(p.delivery.nextCase), total: fmtInt(total) });
}

function circuitText(d) {
  return txt("tool.pieces.circuitVal", { id: d.circuitId.toString(), proc: d.processor, gates: fmtInt(d.gateCount) });
}

function pieceBox(p, i) {
  const st = P.pieceState(p, p.delivery);
  const box = el("div", { class: "box piece", id: "piece-" + i, "data-state": st }, el("h4", { text: txt("tool.pieces.heading", { i: i + 1 }) }));
  box.append(el("dl", { class: "facts" },
    fact("tool.pieces.kind", el("span", { class: "piece-kind", text: pieceKindText(p) }), true),
    fact("tool.order.shape", el("span", { text: txt("tool.order.shapeVal", { nIn: p.nIn, nOut: p.nOut, cases: fmtInt(2n ** BigInt(p.nIn)) }) })),
    fact("tool.order.maxGates", el("span", { class: "mono", text: p.maxGates ? fmtInt(p.maxGates) : txt("tool.order.noCap") })),
    fact("tool.pieces.state", el("span", { class: "piece-state", text: pieceStateText(p) }), true),
    st !== "none" ? fact("tool.pieces.circuit", el("span", { class: "mono", text: circuitText(p.delivery) }), true) : null));
  return box;
}

// "x0" or "x0 to x7": one bit or a run of bits, with the order's x / y names when given.
function bitsText(first, last, name = "") {
  return first === last ? name + first : txt("tool.pieces.range", { a: name + first, b: name + last });
}

// One line per run of wires, in plain words: which piece (or the order) feeds which. Pieces count from 1 on the
// page, bits from 0 (as everywhere else).
function wireLines(wires) {
  return P.wireRuns(wires).map((r) => {
    const out = r.to === P.WIRE_TOP;
    const fromTop = r.from === P.WIRE_TOP;
    const vars = { to: r.to + 1, from: r.from + 1, pins: bitsText(r.toFirst, r.toLast, out ? "y" : ""), src: bitsText(r.fromFirst, r.fromLast, fromTop ? "x" : "") };
    const key = out ? "wireOut" : fromTop ? "wireFromInput" : "wireFromPiece";
    return txt("tool.pieces." + key + (r.toFirst === r.toLast ? "1" : ""), vars);
  });
}

function piecedIntro(pieces, data) {
  const n = pieces.length;
  const top = !!data?.needsTop;
  const joined = data ? data.joined : true;
  const passed = pieces.filter((p) => P.pieceState(p, p.delivery) === "passed").length;
  const made = top ? txt("tool.pieces.madeOfNTop", { n }) : n === 1 ? txt("tool.pieces.madeOf1") : txt("tool.pieces.madeOfN", { n });
  const box = el("div", { class: "box", id: "pieces-intro" },
    el("p", { id: "pieces-made-of", text: made }),
    el("p", { class: "help", id: "pieces-progress", text: txt("tool.pieces.progress", { done: passed, n }) }));
  if (n === 2 && joined) {
    box.append(el("p", { class: "help", id: "pieces-join", text: joinText(pieces) }), el("p", { class: "help", text: txt("tool.pieces.joinWhy") }));
  } else if (!joined) {
    box.append(el("p", { class: "help", text: txt("tool.pieces.wiresHeading") }),
      el("ul", { class: "help", id: "pieces-wires" }, ...wireLines(data.wires).map((t) => el("li", { text: t }))),
      el("p", { class: "help", text: txt("tool.pieces.wiresWhy") }));
  }
  return box;
}

// Whether the order needs a top circuit, and where that stands. deliveries(id) holds the top once delivered.
function topBox(o, pieces, data, now) {
  const allPassed = pieces.every((p) => P.pieceState(p, p.delivery) === "passed");
  const d = data.delivery;
  const delivered = d && !/^0x0{40}$/i.test(d.processor);
  let st;
  if (delivered) st = txt("tool.pieces.topDelivered", { id: d.circuitId.toString(), proc: d.processor, gates: fmtInt(d.gateCount) });
  else if (o.status !== 0) st = txt("tool.pieces.topNone");
  else if (!allPassed) st = txt("tool.pieces.topWaitPieces");
  else st = txt("tool.pieces.topWaitTop", { time: fmtDate(o.deadline + info().grace) });
  return el("div", { class: "box", id: "top-box" }, el("h4", { text: txt("tool.pieces.topHeading") }),
    el("p", { class: "help", text: txt("tool.pieces.topNeeded") }),
    el("p", { id: "top-state", "data-state": delivered ? "delivered" : allPassed ? "waiting" : "pieces", text: st }));
}

function renderPiecedOrder(box, v, data) {
  const o = data.order;
  const i = info();
  const pieces = data.pieces;
  box.setAttribute("data-view", "pieced");
  const you = (a) => (sameAddr(a, state.account) ? " (" + txt("tool.order.you") + ")" : "");
  const head = el("div", { class: "ov-head" },
    el("h3", { text: txt("tool.order.title", { id: String(v.id) }) }),
    el("span", { class: "badge s-" + o.status, id: "order-status", text: txt("tool.order.status." + o.status) }),
    el("button", { type: "button", class: "btn btn-quiet btn-sm", text: txt("tool.order.refresh"), on: { click: () => loadOrder(v.id) } }),
    o.status === 2 ? el("button", { type: "button", class: "btn btn-ghost btn-sm", id: "receipt-btn", text: txt("tool.receipt.view"), on: { click: () => openOrder(v.id, "receipt") } }) : null,
    el("p", { class: "help", text: o.status === 0 ? txt(data.needsTop ? "tool.pieces.statusHelp0Top" : "tool.pieces.statusHelp0") : txt("tool.order.statusHelp." + o.status) }),
    v.lastAction ? el("p", { class: "msg " + (v.lastAction.err ? "is-err" : "is-ok"), role: "status", id: "last-action", text: txt(v.lastAction.key, v.lastAction.vars) }) : null);
  const now = chainNow(data);
  const payout = i.feeBps > 0 ? txt("tool.payout", { net: fmtAmount(G.payoutAfterFee(o.amount, i.feeBps)), symbol: i.symbol, pct: G.feePercent(i.feeBps) }) : null;
  const facts = el("dl", { class: "facts" },
    fact("tool.order.amount", el("span", {}, el("span", { class: "mono", text: fmtAmount(o.amount) + " " + i.symbol }),
      payout ? el("span", { class: "sub", id: "order-payout", text: payout }) : null)),
    fact("tool.order.deadline", el("span", {}, el("span", { class: "mono", text: fmtDate(o.deadline) }),
      el("span", { class: "sub", id: "deadline-left", text: leftText(o, now) }))),
    fact("tool.order.buyer", el("span", { class: "mono", text: o.buyer + you(o.buyer) }), true),
    fact("tool.order.builder", el("span", { class: "mono", text: o.builder + you(o.builder) }), true),
    fact("tool.order.shape", el("span", { text: txt("tool.pieces.shapeTop", { nIn: o.nIn, nOut: o.nOut }) }), true));
  const main = el("div", { class: "ov-main" }, facts, piecedIntro(pieces, data), data.needsTop ? topBox(o, pieces, data, now) : null, ...pieces.map((p, k) => pieceBox(p, k)));
  const side = el("div", { class: "ov-side" });
  if (o.status === 0) {
    side.append(el("div", { class: "box", id: "pieces-how" }, el("p", { class: "help", text: txt("tool.pieces.howDeliver") })));
    side.append(refundBox(o, now, data));
  }
  box.append(el("div", { class: "ov" }, head, main, side));
}

// The contract's piecedHash: keccak256(abi.encode(pieces, tables)) for an order made without wires, and
// keccak256(abi.encode(pieces, tables, wires)) for one made with them. Pieces as (uint8,uint8,uint8,uint8,uint8)[],
// tables[i] = pieceTableOf(id, i), wires as (uint8,uint8,uint8,uint8)[] from wiresOf. wiresOf shows the join for a
// wire-less order too, so the page cannot tell an order created with the join's own wires from one created without:
// both forms are worked out, and the receipt matches when either equals what the chain wrote.
function piecedFingerprints(pieces, wires) {
  const V = state.viem;
  const comps = ["kind", "nIn", "nOut", "widthA", "widthB"].map((name) => ({ name, type: "uint8" }));
  const wcomps = ["fromPiece", "fromBit", "toPiece", "toBit"].map((name) => ({ name, type: "uint8" }));
  const ps = pieces.map((p) => ({ kind: p.kind, nIn: p.nIn, nOut: p.nOut, widthA: p.widthA, widthB: p.widthB }));
  const ts = pieces.map((p) => p.table);
  const out = [V.keccak256(V.encodeAbiParameters([{ type: "tuple[]", components: comps }, { type: "bytes[]" }], [ps, ts]))];
  if (wires?.length) {
    out.push(V.keccak256(V.encodeAbiParameters([{ type: "tuple[]", components: comps }, { type: "bytes[]" }, { type: "tuple[]", components: wcomps }], [ps, ts, wires.map(P.normWire)])));
  }
  return out.map((h) => h.toLowerCase());
}

/** The receipt names one circuit (processor not zero): the contract's own answer to "is there a single circuit". */
function hasSingle(data) {
  return !!data.receipt && !/^0x0{40}$/i.test(String(data.receipt.processor));
}

function renderPiecedReceipt(box, v, data) {
  const o = data.order;
  const i = info();
  const pieces = data.pieces;
  box.setAttribute("data-view", "receipt");
  const head = el("div", { class: "ov-head" },
    el("h3", { text: txt("tool.receipt.title", { id: String(v.id) }) }),
    el("span", { class: "badge s-" + o.status, id: "order-status", text: txt("tool.order.status." + o.status) }),
    el("button", { type: "button", class: "btn btn-quiet btn-sm", id: "receipt-refresh", text: txt("tool.order.refresh"), on: { click: () => loadOrder(v.id) } }),
    el("button", { type: "button", class: "btn btn-ghost btn-sm", id: "open-order-btn", text: txt("tool.receipt.openOrder", { id: String(v.id) }), on: { click: () => openOrder(v.id, "order") } }));
  if (o.status !== 2 || !data.receipt) {
    box.append(el("div", { class: "ov" }, head, el("div", { class: "ov-main" }, el("p", { class: "msg", id: "receipt-none", text: txt("tool.receipt.notPaid", { id: String(v.id) }) }))));
    return;
  }
  const r = data.receipt;
  head.append(el("p", { class: "help", text: txt("tool.pieces.receiptHelp") }));
  const hashOk = piecedFingerprints(pieces, data.wires).some((fp) => fp === String(r.tableHash).toLowerCase() && fp === String(data.piecedHash).toLowerCase());
  const single = hasSingle(data);
  const rows = [];
  if (single) {
    const rule = data.rule || {};
    const ruleOk = !rule.error && sameAddr(rule.processor, r.processor) && rule.circuitId === r.circuitId;
    rows.push(fact("tool.receipt.processor", el("span", { class: "mono", text: r.processor }), true),
      fact("tool.receipt.circuitId", el("span", { class: "mono", text: r.circuitId.toString() })));
    rows.push(fact("tool.receipt.ruleOf", el("span", { class: ruleOk ? "" : "bad", id: "receipt-rule", text: rule.error || txt(ruleOk ? "tool.receipt.ruleOk" : "tool.receipt.ruleBad", { id: String(v.id) }) }), true));
  } else {
    rows.push(el("div", { class: "wide" }, el("dt", { text: txt("tool.receipt.processor") }), el("dd", {}, el("span", { id: "receipt-nosingle", text: txt("tool.pieces.noSingle") }))));
  }
  rows.push(fact("tool.receipt.block", el("span", { class: "mono", text: fmtInt(r.blockNumber) })));
  rows.push(fact("tool.receipt.tableHash", el("span", {}, el("span", { class: "mono", text: r.tableHash }),
    el("span", { class: "sub" + (hashOk ? "" : " bad"), id: "receipt-hash", text: txt(hashOk ? "tool.pieces.hashOk" : "tool.pieces.hashBad", { id: String(v.id) }) })), true));
  pieces.forEach((p, k) => rows.push(el("div", { class: "wide" }, el("dt", { text: txt("tool.pieces.pieceCircuit", { i: k + 1 }) }),
    el("dd", {}, el("span", { class: "mono", id: "receipt-piece-" + k, text: circuitText(p.delivery) })))));
  const facts = el("dl", { class: "facts", id: "receipt-facts" }, ...rows);
  facts.append(fact("tool.order.shape", el("span", { text: txt("tool.pieces.shapeTop", { nIn: o.nIn, nOut: o.nOut }) }), true));
  if (data.needsTop) {
    facts.append(el("div", { class: "wide" }, el("dt", { text: txt("tool.pieces.topHeading") }),
      el("dd", {}, el("span", { class: "mono", id: "receipt-top", text: txt("tool.pieces.topDelivered", { id: r.circuitId.toString(), proc: r.processor, gates: fmtInt(data.delivery.gateCount) }) }))));
  }
  const main = el("div", { class: "ov-main" }, facts, piecedIntro(pieces, data), ...pieces.map((p, k) => pieceBox(p, k)));
  const side = el("div", { class: "ov-side" }, piecedTryBox(o, pieces, data.labels, i, data));
  box.append(el("div", { class: "ov" }, head, main, side));
}

// The joined rule as a free eth_call: run with the gas runGas works out for this order.
// Same protections as tryBox / doRun: switches off while a call is out, an answer for another view, network or
// switch setting is dropped, an answer is only shown when every byte came back, and a call too big for a public
// node's free-call cap is not made at all.
// Gas for one run of this order: joined pieces get a netlist read and a full hold each (G.runPiecedGasLimit); an
// order paid with a top circuit gets the pieces' netlist reads and ONE hold for the top, whose budget already covers
// every piece's gates plus EVAL_GAS_PER_REF per piece (G.runTopGasLimit), the same budget the contract gives it.
function runGas(i, pieces, data) {
  const d = data?.delivery;
  if (data?.needsTop && d && !/^0x0{40}$/i.test(String(d.processor))) {
    return G.runTopGasLimit(i, pieces.map((p) => ({ gates: p.delivery.gateCount, nIn: p.nIn, caseGas: p.delivery.caseGas })), d.gateCount);
  }
  return G.runPiecedGasLimit(i, pieces.map((p) => p.delivery.gateCount), pieces.map((p) => p.delivery.caseGas));
}

function piecedTryBox(o, pieces, labels, i, data) {
  const v = state.view;
  const n = o.nIn;
  if (!v.tryBits || v.tryBits.length !== n) v.tryBits = new Array(n).fill(0);
  const help = data?.needsTop ? "tool.pieces.tryHelpTop" : data && !data.joined ? "tool.pieces.tryHelpChain" : "tool.pieces.tryHelp";
  const box = el("div", { class: "box", id: "try-box" }, el("h4", { text: txt("tool.receipt.tryHeading") }), el("p", { class: "help", text: txt(help) }));
  const body = el("tbody");
  for (let k = 0; k < n; k++) {
    const name = colHead(labels, k, n);
    const bit = v.tryBits[k];
    const b = el("button", { type: "button", class: "bit", "data-k": k, "aria-pressed": String(!!bit), "aria-label": txt("tool.receipt.cellLabel", { name, v: bit }), text: String(bit), disabled: !!v.busy });
    b.addEventListener("click", () => {
      v.tryBits[k] ^= 1;
      v.tryResult = null;
      renderOrder();
    });
    body.appendChild(el("tr", {}, el("th", { scope: "row" }, colHeadNode(labels, k, n)), el("td", {}, b)));
  }
  box.append(el("table", { class: "try-table" },
    el("thead", {}, el("tr", {}, el("th", { scope: "col", text: txt("tool.receipt.colInput") }), el("th", { scope: "col", text: txt("tool.receipt.colValue") }))), body));
  const gas = runGas(i, pieces, data);
  const fits = gas <= G.SIM_GAS_CAP;
  const btn = el("button", { type: "button", class: "btn btn-primary", id: "run-btn", text: txt(v.busy === "run" ? "tool.receipt.running" : "tool.receipt.runBtn"), disabled: !fits || !!v.busy });
  btn.addEventListener("click", () => doRunPieced(o, pieces, data));
  box.append(btn);
  if (!fits) box.append(el("p", { class: "msg is-err", id: "run-toobig", text: txt("tool.pieces.tooBig", { gas: fmtInt(gas) }) }));
  const res = v.tryResult;
  if (res) {
    box.append(el("p", { class: "msg " + (res.err ? "is-err" : "is-ok"), role: res.err ? "alert" : "status", id: "run-result", text: res.text }));
    if (res.check) box.append(el("p", { class: "msg " + (res.check.ok ? "is-ok" : "is-err"), id: "run-check", text: res.check.text }));
  }
  return box;
}

async function doRunPieced(o, pieces, data) {
  const v = state.view;
  const i = info();
  const gas = runGas(i, pieces, data);
  if (gas > G.SIM_GAS_CAP) return;
  const bits = v.tryBits.slice();
  let x = 0n;
  for (let k = 0; k < o.nIn; k++) if (bits[k]) x |= 1n << BigInt(k);
  const inputs = T.toHex(P.packBig(x, o.nIn));
  v.busy = "run";
  v.tryResult = null;
  renderOrder();
  const key = state.netKey;
  try {
    const r = await state.pub.readContract({ address: net().lathe, abi: state.abi, functionName: "run", args: [v.id, inputs], gas });
    if (state.view !== v || state.netKey !== key) return;
    if (v.tryBits.join() !== bits.join()) return dropRun(v);
    const outBytes = state.viem.hexToBytes(r);
    if (outBytes.length !== Math.ceil(o.nOut / 8)) throw new Error("short answer");
    const out = P.readBitsBig(outBytes, 0, o.nOut);
    const bitsText = (val) => Array.from({ length: o.nOut }, (_, k) => `y${k}=${(val >> BigInt(k)) & 1n}`).join(" ");
    const tables = pieces.map((p) => state.viem.hexToBytes(p.table));
    const exp = data?.wires ? P.chainExpected(pieces, tables, data.wires, o.nOut, x) : P.joinExpected(pieces, tables, x);
    v.tryResult = {
      text: txt("tool.pieces.result", { out: bitsText(out) }),
      check: exp === out ? { ok: true, text: txt("tool.pieces.match", { c: x.toString() }) } : { ok: false, text: txt("tool.pieces.mismatch", { c: x.toString(), exp: bitsText(exp) }) },
    };
  } catch (e) {
    if (state.view !== v || state.netKey !== key) return;
    if (v.tryBits.join() !== bits.join()) return dropRun(v);
    v.tryResult = { err: true, text: explain(e, { read: true, action: "run" }).text };
  }
  v.busy = false;
  renderOrder();
}

// One row per input (its name as the row header), then the memory bit; each value is a 0/1 switch.
// While a run is out the switches are off, so the answer always lands next to the inputs it was asked for; any
// change to a switch afterwards clears the answer (doRun also drops an answer whose inputs no longer match).
function tryBox(o, d, answers, labels, i) {
  const v = state.view;
  const n = o.nIn + o.nState;
  if (!v.tryBits || v.tryBits.length !== n) v.tryBits = new Array(n).fill(0);
  const box = el("div", { class: "box", id: "try-box" }, el("h4", { text: txt("tool.receipt.tryHeading") }), el("p", { class: "help", text: txt("tool.receipt.tryHelp") }));
  const body = el("tbody");
  for (let k = 0; k < n; k++) {
    const named = k < o.nIn || !!T.cleanName(labels?.[k]);
    const name = named ? colHead(labels, k, o.nIn) : txt("tool.receipt.memoryRow");
    const bit = v.tryBits[k];
    const b = el("button", { type: "button", class: "bit", "data-k": k, "aria-pressed": String(!!bit), "aria-label": txt("tool.receipt.cellLabel", { name, v: bit }), text: String(bit), disabled: !!v.busy });
    b.addEventListener("click", () => {
      v.tryBits[k] ^= 1;
      v.tryResult = null;
      renderOrder();
    });
    body.appendChild(el("tr", {}, el("th", { scope: "row" }, named ? colHeadNode(labels, k, o.nIn) : name), el("td", {}, b)));
  }
  box.append(el("table", { class: "try-table" },
    el("thead", {}, el("tr", {}, el("th", { scope: "col", text: txt("tool.receipt.colInput") }), el("th", { scope: "col", text: txt("tool.receipt.colValue") }))), body));
  const fits = G.runFitsSim(i, d.gateCount, G.SIM_GAS_CAP, d.caseGas);
  const btn = el("button", { type: "button", class: "btn btn-primary", id: "run-btn", text: txt(v.busy === "run" ? "tool.receipt.running" : "tool.receipt.runBtn"), disabled: !fits || !!v.busy });
  btn.addEventListener("click", () => doRun(o, d, answers));
  box.append(btn);
  if (!fits) box.append(el("p", { class: "msg is-err", id: "run-toobig", text: txt("tool.receipt.tooBig") }));
  const res = v.tryResult;
  if (res) {
    box.append(el("p", { class: "msg " + (res.err ? "is-err" : "is-ok"), role: res.err ? "alert" : "status", id: "run-result", text: res.text }));
    if (res.check) box.append(el("p", { class: "msg " + (res.check.ok ? "is-ok" : "is-err"), id: "run-check", text: res.check.text }));
  }
  return box;
}

// run / runStep as a free eth_call with an explicit gas limit under the public node's cap. The contract refuses
// (InsufficientGasForCase) rather than answer with less gas than the circuit's budget, and the page shows only
// bits it got back in full, so a cut-short call becomes an error, never an answer.
// An answer is shown only if, when it arrives, the page still shows the same receipt on the same network with the
// same switches. Otherwise it is dropped: a refresh, another order, the order view or another network replace
// state.view; switches that changed anyway (they are off while the call is out) clear it.
async function doRun(o, d, answers) {
  const v = state.view;
  const i = info();
  if (!G.runFitsSim(i, d.gateCount, G.SIM_GAS_CAP, d.caseGas)) return;
  const bits = v.tryBits.slice();
  let x = 0;
  for (let k = 0; k < o.nIn; k++) x |= bits[k] << k;
  const s = o.nState ? bits[o.nIn] : 0;
  const inputs = T.toHex(T.pack(x, o.nIn));
  const stateHex = T.toHex(T.pack(s, o.nState));
  v.busy = "run";
  v.tryResult = null;
  renderOrder();
  const id = v.id;
  const key = state.netKey;
  try {
    const gas = G.runGasLimit(i, d.gateCount, d.caseGas);
    const L = net().lathe;
    const r = o.nState
      ? await state.pub.readContract({ address: L, abi: state.abi, functionName: "runStep", args: [id, stateHex, inputs], gas })
      : await state.pub.readContract({ address: L, abi: state.abi, functionName: "run", args: [id, inputs], gas });
    if (state.view !== v || state.netKey !== key) return;
    if (v.tryBits.join() !== bits.join()) return dropRun(v);
    const outHex = o.nState ? r[1] : r;
    const outBytes = state.viem.hexToBytes(outHex);
    const nsBytes = o.nState ? state.viem.hexToBytes(r[0]) : new Uint8Array(0);
    if (outBytes.length !== Math.ceil(o.nOut / 8) || nsBytes.length !== Math.ceil(o.nState / 8)) throw new Error("short answer");
    const out = T.readBits(outBytes, 0, o.nOut);
    const ns = T.readBits(nsBytes, 0, o.nState);
    const outText = Array.from({ length: o.nOut }, (_, k) => `y${k}=${(out >> k) & 1}`).join(" ");
    const c = x | (s << o.nIn);
    const got = out | (ns << o.nOut);
    const res = { text: o.nState ? txt("tool.receipt.resultState", { out: outText, s: ns }) : txt("tool.receipt.result", { out: outText }) };
    if (answers) {
      const exp = answers[c];
      const expText = Array.from({ length: o.nOut }, (_, k) => `y${k}=${(exp >> k) & 1}`).join(" ") + (o.nState ? ` s′=${(exp >> o.nOut) & 1}` : "");
      res.check = exp === got ? { ok: true, text: txt("tool.receipt.match", { c }) } : { ok: false, text: txt("tool.receipt.mismatch", { c, exp: expText }) };
    }
    v.tryResult = res;
  } catch (e) {
    if (state.view !== v || state.netKey !== key) return;
    if (v.tryBits.join() !== bits.join()) return dropRun(v);
    v.tryResult = { err: true, text: explain(e, { read: true, action: "run" }).text };
  }
  v.busy = false;
  renderOrder();
}
function dropRun(v) {
  v.busy = false;
  v.tryResult = null;
  renderOrder();
}

function refundBox(o, now, data = null) {
  const v = state.view;
  const i = info();
  const box = el("div", { class: "box", id: "refund-box" }, el("h4", { text: txt("tool.refund.heading") }));
  const pieced = !!data?.pieces?.length;
  const opens = pieced ? refundOpens(data) : G.refundOpensAt(o.status, o.deadline, i.grace);
  if (pieced) box.append(el("p", { class: "help", id: "refund-rule", text: txt("tool.pieces.refundRule") }));
  let gate = null;
  if (opens !== null && now < opens) {
    const key = pieced
      ? (opens > o.deadline + 1n ? "tool.pieces.refundNotYetAll" : "tool.pieces.refundNotYetUndelivered")
      : (o.status === 1 ? "tool.refund.notYetChecking" : "tool.refund.notYet");
    gate = txt(key, { time: fmtDate(opens) });
  } else if (!state.account) gate = txt("tool.wallet.needWallet");
  else if (!sameAddr(state.account, o.buyer)) gate = txt("tool.refund.onlyBuyer", { addr: short(o.buyer) });
  else if (wrongNetwork()) gate = txt("tool.wallet.wrongNet", { net: txt("tool.network." + net().key) });
  const btn = el("button", { type: "button", class: "btn btn-ghost", id: "refund-btn", text: txt("tool.refund.btn", { amount: fmtAmount(o.amount), symbol: i.symbol }), disabled: !!gate || !!v.busy });
  btn.addEventListener("click", () => doRefund(o));
  box.append(btn);
  if (gate) box.append(el("p", { class: "help", id: "refund-gate", text: gate }));
  if (v.msgs.refundTx) {
    const tl = el("div", { class: "txline" });
    txLine(tl, v.msgs.refundTx);
    box.append(tl);
  }
  const mn = msgNode(v.msgs.refund);
  if (mn) box.append(mn);
  return box;
}

async function doRefund(o) {
  const v = state.view;
  if (!canSend()) return;
  v.busy = "refund";
  v.msgs.refund = null;
  renderOrder();
  const key = state.netKey;
  try {
    await send({
      address: net().lathe, abi: state.abi, functionName: "refund", args: [v.id],
      slot: (m) => {
        v.msgs.refundTx = m;
        renderOrder();
      },
    });
    v.busy = false;
    v.msgs.refundTx = null;
    if (state.netKey !== key) return;
    const i = info();
    await loadOrder(v.id, { quiet: true, lastAction: { key: "tool.refund.done", vars: { amount: fmtAmount(o.amount), symbol: i.symbol } } });
    refreshAccountReads();
  } catch (e) {
    v.busy = false;
    if (afterSendFailure(e, v, "refundTx", "refund", key)) return;
    v.msgs.refundTx = null;
    v.msgs.refund = { err: true, text: explain(e).text };
    renderOrder();
  }
}

// ---------------------------------------------------------------- start
applyStrings();
mountFig();
const startReceipt = params.get("receipt");
const startOrder = startReceipt || params.get("order");
if (startOrder && /^\d{1,12}$/.test(startOrder) && BigInt(startOrder) >= 1n) {
  selectTab("lookup");
  $("#f-lookup").value = startOrder;
  state.view = { id: BigInt(startOrder), loading: true, data: null, inputs: { processor: net().processor || "", circuit: net().mockMint ? "1" : "", n: "" }, msgs: {}, preview: null, failedCase: null, mode: startReceipt ? "receipt" : "order" };
} else {
  selectTab(location.hash === "#order-lookup" ? "lookup" : "create");
}
renderTool();
(async () => {
  await setNetwork(state.netKey);
  await initWallet();
  if (state.account && state.viem) state.account = safeAddr(state.account);
  onWalletChange();
})();

#!/usr/bin/env node
// Measure the gas every case of a circuit needs when it runs first in a transaction (cold), and print the per-case
// gas to declare at delivery with the exact `cast send` command. Read-only: it sends no transaction and never sees a
// key. See scripts/README.md.
//
// How: each case is its own eth_estimateGas on a call straight to the processor's eval (step for a memory circuit).
// A simulated call is a fresh transaction, so every circuit the case touches is cold, as for the first case of a
// check transaction. The estimate minus the call's own base cost (21,000 + calldata) is the gas the circuit must be
// handed. On real TapeOut that came within about 40 gas of the true minimum on 256 cases, five link levels deep
// (evidence/2026-11-21-case-gas-fix.md). The value to declare is the same rule the order page uses (web/gas.js):
// worst x 64/63 (TapeOut's proxy passes on 63/64 of the gas it gets) + 10%, rounded up to 10,000.
import { pathToFileURL } from 'node:url';
import { intrinsicGas, needFromEstimate, proposeCaseGas, deliverGasLimit } from '../web/gas.js';

const HELP = `usage: node scripts/measure-case-gas.mjs --rpc URL --processor ADDR --circuit ID
         (--lathe ADDR --order N [--piece I] | --inputs N [--state 1] [--lathe ADDR])
         [--pause MS] [--cap GAS]

  --lathe, --order  read the order's shape (inputs, memory bit, gate cap) from LatheOrders; with --piece I, piece I
                    of a pieced order (its inputs and its gate cap). The printed command then names them.
  --inputs N        no order: the circuit's inputs (1..17); --state 1 for a memory circuit (checked with step).
  --pause MS        wait this long between requests (default 0). One request is in flight at a time; on a public
                    RPC use 200 or more. A rate-limited request is retried 3 times, then the case is unknown.
  --cap GAS         gas each test run may use (default 102,600,000: enough for 100M through TapeOut's 63/64).
                    Public X Layer nodes cut a test run at 50,000,000, so a case needing more shows as unknown there:
                    run this against your own node to measure it.

Prints the costliest case, the formula budget (100,000 + 15,000 x gates), whether it fits, the value to declare and
the cast send command. Exit 0 when every case was measured and the value can be declared; 1 when a case could not
be measured (it is reported as unknown, never as fitting), the value is above 100,000,000, or the order's gate cap
refuses it; 2 for a usage or read error.`;

const SEL = {
  eval: '934d06ea', // eval(uint256,bytes)
  step: 'e8281a1a', // step(uint256,bytes,bytes)
  circuitInfo: '084d60f1', // circuitInfo(uint256)
  orders: 'a85c38ef', // orders(uint256)
  piecesOf: '7ed071ca', // piecesOf(uint256)
  pieceMaxGatesOf: 'e314f29f', // pieceMaxGatesOf(uint256,uint256)
  evalBudget: 'c8f5da9c', // evalBudget(uint256)
  inline: '961d79d8', // INLINE_CHECK_MAX_GAS()
  maxCase: 'eddbf6f2', // MAX_CASE_GAS()
  base: 'b3dd860e', // EVAL_BASE_GAS()
  perGate: 'f7692900', // EVAL_GAS_PER_GATE()
};

export function parseArgs(argv) {
  const a = { pause: 0, cap: 102_600_000n };
  for (let i = 0; i < argv.length; i++) {
    const k = argv[i];
    const v = () => {
      if (i + 1 >= argv.length) throw new Error(`${k} needs a value`);
      return argv[++i];
    };
    if (k === '--help' || k === '-h') a.help = true;
    else if (k === '--rpc') a.rpc = v();
    else if (k === '--processor') a.processor = v();
    else if (k === '--circuit') a.circuit = BigInt(v());
    else if (k === '--lathe') a.lathe = v();
    else if (k === '--order') a.order = BigInt(v());
    else if (k === '--piece') a.piece = BigInt(v());
    else if (k === '--inputs') a.inputs = Number(v());
    else if (k === '--state') a.state = Number(v());
    else if (k === '--pause') a.pause = Number(v());
    else if (k === '--cap') a.cap = BigInt(v());
    else throw new Error(`unknown option ${k}`);
  }
  if (a.help) return a;
  const isAddr = (x) => /^0x[0-9a-fA-F]{40}$/.test(x || '');
  if (!a.rpc) throw new Error('--rpc is required');
  if (!isAddr(a.processor)) throw new Error('--processor must be an address');
  if (a.circuit === undefined) throw new Error('--circuit is required');
  if (a.lathe !== undefined && !isAddr(a.lathe)) throw new Error('--lathe must be an address');
  if (a.order !== undefined) {
    if (!a.lathe) throw new Error('--order needs --lathe');
    if (a.inputs !== undefined || a.state !== undefined) throw new Error('give --order or --inputs, not both');
  } else {
    if (a.piece !== undefined) throw new Error('--piece needs --order');
    if (!Number.isInteger(a.inputs) || a.inputs < 1 || a.inputs > 17) throw new Error('give --order (with --lathe) or --inputs N (1..17)');
    if (a.state !== undefined && a.state !== 0 && a.state !== 1) throw new Error('--state is 0 or 1');
    if (a.state === 1 && a.inputs > 5) throw new Error('a memory circuit has at most 5 inputs');
  }
  if (!Number.isFinite(a.pause) || a.pause < 0) throw new Error('--pause must be a number of milliseconds');
  return a;
}

const word = (x) => BigInt(x).toString(16).padStart(64, '0');
/** Case bits packed LSB first, ceil(n/8) bytes (BitLib.pack). */
export function packHex(value, nBits) {
  let h = '';
  for (let i = 0; i < Math.ceil(nBits / 8); i++) h += ((value >> (8 * i)) & 0xff).toString(16).padStart(2, '0');
  return h;
}
const bytesArg = (h) => word(h.length / 2) + h.padEnd(Math.ceil(h.length / 64) * 64 || 64, '0');

/** Calldata for case c: eval(id, inputs), or step(id, state, inputs) for a memory circuit. */
export function caseCalldata(id, c, nIn, nState) {
  const inputs = packHex(c & ((1 << nIn) - 1), nIn);
  if (!nState) return '0x' + SEL.eval + word(id) + word(0x40) + bytesArg(inputs);
  const state = packHex(c >> nIn, nState);
  const s = bytesArg(state);
  return '0x' + SEL.step + word(id) + word(0x60) + word(0x60 + s.length / 2) + s + bytesArg(inputs);
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let rid = 0;
async function rpc(url, method, params) {
  const r = await fetch(url, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ jsonrpc: '2.0', id: ++rid, method, params }) });
  if (!r.ok) {
    const e = new Error(`HTTP ${r.status}`);
    e.transient = r.status === 429 || r.status >= 500;
    throw e;
  }
  const j = await r.json();
  if (j.error) {
    const e = new Error(`${j.error.message || 'error'} (code ${j.error.code})`);
    e.transient = j.error.code === -32005 || j.error.code === -32002 || j.error.code === 429;
    throw e;
  }
  return j.result;
}

/** One request at a time; a rate-limited or 5xx answer is retried 3 times with a growing pause. */
async function request(a, method, params) {
  for (let k = 0; ; k++) {
    if (a.pause) await sleep(a.pause);
    try {
      return await rpc(a.rpc, method, params);
    } catch (e) {
      if (!e.transient || k >= 3) throw e;
      await sleep(1000 * (k + 1));
    }
  }
}

const call = (a, to, data) => request(a, 'eth_call', [{ to, data }, 'latest']);
const words = (hex) => (hex.startsWith('0x') ? hex.slice(2) : hex).match(/.{64}/g)?.map((w) => BigInt('0x' + w)) || [];

const fmt = (n) => BigInt(n).toLocaleString('en-US');

export async function main(argv, out = console.log) {
  let a;
  try {
    a = parseArgs(argv);
  } catch (e) {
    out(`${e.message}\n\n${HELP}`);
    return 2;
  }
  if (a.help) {
    out(HELP);
    return 0;
  }
  let shape;
  let c;
  let cap = 0;
  try {
    const chain = BigInt(await request(a, 'eth_chainId', []));
    const ci = words(await call(a, a.processor, '0x' + SEL.circuitInfo + word(a.circuit)));
    if (ci.length < 4) throw new Error(`circuitInfo(${a.circuit}) gave no answer: is ${a.processor} a TapeOut processor?`);
    shape = { nIn: Number(ci[0]), nOut: Number(ci[1]), nState: Number(ci[2]), gates: ci[3] };
    let want;
    if (a.order !== undefined) {
      const o = words(await call(a, a.lathe, '0x' + SEL.orders + word(a.order)));
      if (o.length < 9 || o[0] === 0n) throw new Error(`order ${a.order} does not exist on ${a.lathe}`);
      if (a.piece !== undefined) {
        const p = words(await call(a, a.lathe, '0x' + SEL.piecesOf + word(a.order)));
        const n = p.length >= 2 ? Number(p[1]) : 0;
        if (a.piece >= BigInt(n)) throw new Error(`order ${a.order} has ${n} piece(s); there is no piece ${a.piece}`);
        const base = 2 + 5 * Number(a.piece);
        want = { nIn: Number(p[base + 1]), nState: 0 };
        cap = Number(words(await call(a, a.lathe, '0x' + SEL.pieceMaxGatesOf + word(a.order) + word(a.piece)))[0]);
      } else {
        want = { nIn: Number(o[5]), nState: Number(o[7]) };
        cap = Number(o[4]);
      }
    } else want = { nIn: a.inputs, nState: a.state || 0 };
    if (shape.nIn !== want.nIn || shape.nState !== want.nState) {
      throw new Error(`circuit ${a.circuit} has ${shape.nIn} input(s) and ${shape.nState} memory bit(s); expected ${want.nIn} and ${want.nState}`);
    }
    const read1 = async (sel, arg = '') => words(await call(a, a.lathe, '0x' + sel + arg))[0];
    c = a.lathe
      ? { base: await read1(SEL.base), perGate: await read1(SEL.perGate), reserve: 20_000n, inlineMax: await read1(SEL.inline), maxCaseGas: await read1(SEL.maxCase) }
      : { base: 100_000n, perGate: 15_000n, reserve: 20_000n, inlineMax: 30_000_000n, maxCaseGas: 100_000_000n };
    c.formula = a.lathe ? await read1(SEL.evalBudget, word(shape.gates)) : c.base + c.perGate * shape.gates;
    out(`chain ${chain}, processor ${a.processor}, circuit ${a.circuit}: ${shape.nIn} input(s), ${shape.nState} memory bit(s), ${fmt(shape.gates)} gates`);
  } catch (e) {
    out(`read failed: ${e.message}`);
    return 2;
  }

  const cases = 1 << (shape.nIn + shape.nState);
  out(`measuring ${cases} case(s), one eth_estimateGas each, up to ${fmt(a.cap)} gas per test run`);
  let worst = -1n;
  let worstCase = -1;
  const unknown = [];
  for (let k = 0; k < cases; k++) {
    const data = caseCalldata(a.circuit, k, shape.nIn, shape.nState);
    try {
      const est = await request(a, 'eth_estimateGas', [{ to: a.processor, data, gas: '0x' + a.cap.toString(16) }]);
      const need = needFromEstimate(BigInt(est), data);
      if (need > worst) {
        worst = need;
        worstCase = k;
      }
    } catch (e) {
      unknown.push([k, e.message.split('\n')[0].slice(0, 160)]);
    }
  }
  out(`base cost of one test call (21,000 + calldata) subtracted: ${fmt(intrinsicGas(caseCalldata(a.circuit, 0, shape.nIn, shape.nState)))} gas`);
  out(`formula budget per case: ${fmt(c.formula)} (100,000 + 15,000 x ${fmt(shape.gates)} gates)`);
  if (unknown.length) {
    out(`UNKNOWN: ${unknown.length} case(s) could not be measured. They are not counted as fitting:`);
    for (const [k, m] of unknown.slice(0, 20)) out(`  case ${k}: ${m}`);
    if (unknown.length > 20) out(`  ... and ${unknown.length - 20} more`);
    out('A case that needs more than --cap, or reverts, shows here. On a public node (50M cap per test run) try your own node.');
  }
  if (worstCase < 0) {
    out('No case could be measured: nothing to propose.');
    return 1;
  }
  const proposed = proposeCaseGas(worst);
  out(`costliest measured case: ${worstCase}, needs ${fmt(worst)} gas when it runs first in a transaction`);
  out(proposed <= c.formula
    ? `fits: the formula budget covers it with the margin (${fmt(proposed)} <= ${fmt(c.formula)}); declaring is not needed but does no harm`
    : `does not fit the formula budget with the margin: declare it`);
  out(`value to declare: ${fmt(proposed)}  (worst x 64/63 + 10%, rounded up to 10,000)`);
  let bad = unknown.length > 0;
  if (proposed > c.maxCaseGas) {
    out(`REFUSED: ${fmt(proposed)} is above the most a case can get (${fmt(c.maxCaseGas)}): the contract cannot check this circuit.`);
    bad = true;
  }
  const n = BigInt(cases);
  const capGates = BigInt(cap);
  if (cap && n * (c.base + c.perGate * capGates) <= c.inlineMax && n * proposed > c.inlineMax) {
    out(`REFUSED: the gate cap (${cap}) promises a check inside the delivery: all ${cases} cases within ${fmt(c.inlineMax)} gas, so at most ${fmt(c.inlineMax / n)} per case. The contract refuses ${fmt(proposed)} (CaseGasTooHigh).`);
    bad = true;
  }
  const declared = proposed > c.formula ? proposed : c.formula;
  const g = deliverGasLimit(c, cases, Number(shape.gates), declared);
  const lathe = a.lathe || 'LATHE_ADDRESS';
  const order = a.order !== undefined ? a.order : 'ORDER_ID';
  const cmd = a.piece !== undefined
    ? `cast send ${lathe} "deliverPiece(uint256,uint256,address,uint256,uint32)" ${order} ${a.piece} ${a.processor} ${a.circuit} ${proposed} --gas-limit ${g.gas} --rpc-url ${a.rpc} --account YOUR_ACCOUNT`
    : `cast send ${lathe} "deliver(uint256,address,uint256,uint32)" ${order} ${a.processor} ${a.circuit} ${proposed} --gas-limit ${g.gas} --rpc-url ${a.rpc} --account YOUR_ACCOUNT`;
  out(g.inline ? `the delivery checks all ${cases} cases inside it (gas limit ${fmt(g.gas)})` : `the delivery is recorded and checked in batches (check / checkPiece, or scripts/crank.mjs for a piece)`);
  out(bad ? 'NOT READY: fix the lines above first. The command would be:' : 'deliver with:');
  out(cmd);
  return bad ? 1 : 0;
}

if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  main(process.argv.slice(2)).then((code) => process.exit(code));
}

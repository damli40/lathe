#!/usr/bin/env node
// Push a long piece check forward: calls LatheOrders.checkPiece in batches until the piece is done.
// Every transaction is sent by a spawned `cast send`, which signs with your keystore. This script never sees a
// private key. See scripts/README.md.
import { spawnSync } from 'node:child_process';
import { pathToFileURL } from 'node:url';

const HELP = `usage: node scripts/crank.mjs --lathe ADDR --order N --piece I --batch K --rpc URL
         (--account NAME | --keystore PATH) [--password-file PATH]
         [--max-gas G] [--dry]
       local anvil only: --unlocked --from ADDR instead of a keystore

  --batch K       cases per transaction (lowered if the gas limit for K cases would pass --max-gas)
  --max-gas G     highest gas limit for one transaction (default 200000000; X Layer blocks hold 210M)
  --dry           read the order and print the plan (batches, gas limit per batch, worst-case cost); send nothing`;

// Gas maths. Each case's eval gets exactly evalBudget(gateCount) gas, and the contract refuses to start a case
// unless gasleft() >= budget * 64/63 + GAS_RESERVE (LatheOrders._requireCaseGas). A circuit may use all of its
// budget, so the only gas limit that can never fail with InsufficientGasForCase is sized from the budget, not from
// a simulation. (Public RPCs cap eth_call at about 50M gas, so a simulation of a big batch fails or lies.)
const EVAL_BASE_GAS = 100_000n;
const EVAL_GAS_PER_GATE = 15_000n;
const GAS_RESERVE = 20_000n;
const PER_CASE_OVERHEAD = 30_000n; // packing, compare, try/catch, memory: measured < 5,000 (evidence file)
const TX_BASE = 150_000n; // intrinsic gas, calldata, storage reads, events
const PAY_BASE = 300_000n; // receipt, fee, transfer, events when the last batch pays the order
const netlistGas = (bytes) => 30_000n + 70n * BigInt(bytes); // read + hash the whole netlist once (~12/byte measured)

export function evalBudget(gates) {
  return EVAL_BASE_GAS + EVAL_GAS_PER_GATE * BigInt(gates);
}

/// Gas limit for a checkPiece call that runs k cases. `pays` adds the payout, which re-reads every piece's netlist.
export function batchGasLimit({ k, gates, netlistBytes, pays, allNetlistBytes = [] }) {
  const budget = evalBudget(gates);
  const perCase = (budget * 64n + 62n) / 63n + GAS_RESERVE + PER_CASE_OVERHEAD;
  let g = TX_BASE + netlistGas(netlistBytes) + BigInt(k) * perCase;
  if (pays) g += PAY_BASE + allNetlistBytes.reduce((s, b) => s + netlistGas(b), 0n);
  return g;
}

/// The largest k <= want whose gas limit fits under maxGas (0 if not even one case fits).
export function fitBatch(want, opts, maxGas) {
  let k = want;
  while (k > 0 && batchGasLimit({ ...opts, k, pays: opts.paysAt(k) }) > maxGas) k--;
  return k;
}

function parseArgs(argv) {
  const a = { maxGas: 200_000_000n, dry: false, unlocked: false };
  for (let i = 0; i < argv.length; i++) {
    const k = argv[i];
    const v = () => {
      if (i + 1 >= argv.length) die(`${k} needs a value`);
      return argv[++i];
    };
    switch (k) {
      case '--lathe': a.lathe = v(); break;
      case '--order': a.order = BigInt(v()); break;
      case '--piece': a.piece = BigInt(v()); break;
      case '--batch': a.batch = Number(v()); break;
      case '--rpc': a.rpc = v(); break;
      case '--account': a.account = v(); break;
      case '--keystore': a.keystore = v(); break;
      case '--password-file': a.passwordFile = v(); break;
      case '--max-gas': a.maxGas = BigInt(v()); break;
      case '--dry': a.dry = true; break;
      case '--unlocked': a.unlocked = true; break;
      case '--from': a.from = v(); break;
      case '--private-key':
      case '--mnemonic':
        die(`${k} is refused: use --account or --keystore so cast signs and the key never passes through here`);
        break;
      case '-h':
      case '--help': console.log(HELP); process.exit(0);
      default: die(`unknown option ${k}\n${HELP}`);
    }
  }
  for (const r of ['lathe', 'order', 'piece', 'batch', 'rpc']) if (a[r] === undefined) die(`--${r} is required\n${HELP}`);
  if (!Number.isInteger(a.batch) || a.batch < 1) die('--batch must be a whole number >= 1');
  if (!a.dry) {
    const wallets = [a.account, a.keystore, a.unlocked || undefined].filter(Boolean).length;
    if (wallets !== 1) die('give exactly one of --account, --keystore, or --unlocked --from (anvil)');
    if (a.unlocked) {
      if (!a.from) die('--unlocked needs --from');
      if (!/^https?:\/\/(127\.0\.0\.1|localhost)(:\d+)?\/?$/.test(a.rpc)) die('--unlocked is for a local anvil only');
    }
  }
  return a;
}

function die(msg, code = 1) {
  console.error(msg);
  process.exit(code);
}

function cast(args, { inherit = false } = {}) {
  const r = spawnSync('cast', args, { encoding: 'utf8', stdio: ['inherit', 'pipe', inherit ? 'inherit' : 'pipe'] });
  if (r.error) die(`could not run cast: ${r.error.message}`);
  return { ok: r.status === 0, out: (r.stdout || '').trim(), err: (r.stderr || '').trim() };
}

function call(a, sig, ...params) {
  const r = cast(['call', a.lathe, sig, ...params.map(String), '--rpc-url', a.rpc]);
  if (!r.ok) die(`read failed: ${sig}\n${r.err}`);
  return r.out;
}

// cast prints each returned value on its own line, sometimes followed by " [1e6]"; keep the first token.
const fields = (out) => out.split('\n').map((l) => l.trim().split(/\s+/)[0]);

function readState(a) {
  const [proc, circuitId, , gates, , next] = fields(
    call(a, 'pieceOf(uint256,uint256)(address,uint256,address,uint32,bytes32,uint32)', a.order, a.piece));
  const o = fields(call(a, 'orders(uint256)(address,address,uint96,uint64,uint32,uint8,uint8,uint8,uint8)', a.order));
  const piecesRaw = call(a, 'piecesOf(uint256)((uint8,uint8,uint8,uint8,uint8)[])', a.order);
  const pieces = [...piecesRaw.matchAll(/\(([^)]*)\)/g)].map((m) => m[1].split(',').map((x) => Number(x.trim().split(/\s+/)[0])));
  if (pieces.length === 0) die('order has no pieces (a V0-V2 order: use check, not checkPiece)');
  if (Number(a.piece) >= pieces.length) die(`order has ${pieces.length} piece(s); --piece ${a.piece} does not exist`);
  const nIn = pieces[Number(a.piece)][1];
  const all = pieces.map((_, i) => {
    const [p, id] = fields(call(a, 'pieceOf(uint256,uint256)(address,uint256,address,uint32,bytes32,uint32)', a.order, i));
    return { proc: p, id };
  });
  return { proc, circuitId, gates: Number(gates), next: Number(next), total: 2 ** nIn, status: Number(o[8]), deadline: Number(o[3]), all };
}

function netlistBytes(a, proc, id) {
  if (/^0x0{40}$/i.test(proc)) return 0;
  const r = cast(['call', proc, 'netlist(uint256)(bytes)', String(id), '--rpc-url', a.rpc]);
  if (!r.ok) die(`could not read netlist of ${proc} #${id}\n${r.err}`);
  return (r.out.length - 2) / 2;
}

const topic = (sig) => cast(['keccak', sig]).out.toLowerCase();

function main() {
  const a = parseArgs(process.argv.slice(2));
  const T_REJECTED = topic('PieceRejected(uint256,uint256,uint256)');
  const T_PAID = topic('Paid(uint256,address,address,uint256)');
  let s = readState(a);
  if (s.status !== 0) die(`order status is ${['Open', 'Checking', 'Paid', 'Refunded'][s.status]}, not Open: nothing to check`);
  if (/^0x0{40}$/i.test(s.proc)) die('this piece has no delivery: the builder must call deliverPiece first');
  if (s.next >= s.total) die(`piece already passed (${s.next}/${s.total})`);

  const myNet = netlistBytes(a, s.proc, s.circuitId);
  const allNets = s.all.map((p) => netlistBytes(a, p.proc, p.id));
  const opts = {
    gates: s.gates,
    netlistBytes: myNet,
    allNetlistBytes: allNets,
    paysAt: (k) => s.next + k >= s.total, // a batch that finishes the piece may also pay the order
  };
  const want = Math.min(a.batch, s.total - s.next);
  const k = fitBatch(want, opts, a.maxGas);
  if (k === 0) die(`one case needs more than --max-gas ${a.maxGas} (budget ${evalBudget(s.gates)} per case)`);
  if (k < want) console.log(`batch lowered from ${want} to ${k} so the gas limit stays under ${a.maxGas}`);

  const remaining = s.total - s.next;
  const txs = Math.ceil(remaining / k);
  const fullLimit = batchGasLimit({ ...opts, k, pays: false });
  console.log(`order ${a.order} piece ${a.piece}: ${s.next}/${s.total} cases, ${s.gates} gates, budget ${evalBudget(s.gates)} gas per case`);
  console.log(`plan: ${txs} transaction(s) of up to ${k} cases, gas limit ${fullLimit} each (the last one more if it pays)`);
  console.log(`deadline ${new Date(s.deadline * 1000).toISOString()}; checks run until deadline + 1 day`);

  if (a.dry) {
    const gp = cast(['gas-price', '--rpc-url', a.rpc]);
    const worst = BigInt(txs) * fullLimit;
    console.log(`worst case (every case burns its whole budget): ${worst} gas`);
    if (gp.ok) {
      const price = BigInt(gp.out);
      console.log(`at gas price ${price} wei: worst case ${fmtEth(worst * price)} native token; balance needed up front per tx ${fmtEth(fullLimit * price)}`);
      console.log('real use is lower: a real circuit uses far less than its budget (see evidence/2026-11-21-gas-16-input-piece.md)');
    }
    console.log('dry run: nothing sent. The gas limits come from the budget maths, not from eth_call.');
    return;
  }

  const wallet = a.unlocked
    ? ['--unlocked', '--from', a.from]
    : [...(a.account ? ['--account', a.account] : ['--keystore', a.keystore]),
       ...(a.passwordFile ? ['--password-file', a.passwordFile] : [])];
  const t0 = Date.now();
  let sent = 0;
  while (s.next < s.total) {
    const kk = fitBatch(Math.min(k, s.total - s.next), opts, a.maxGas);
    const limit = batchGasLimit({ ...opts, k: kk, pays: opts.paysAt(kk) });
    const r = cast(['send', a.lathe, 'checkPiece(uint256,uint256,uint256)', String(a.order), String(a.piece), String(kk),
      '--rpc-url', a.rpc, '--gas-limit', String(limit), '--json', ...wallet], { inherit: true });
    sent++;
    if (!r.ok) {
      // Sending failed (RPC error, wrong password). Re-read before deciding: the transaction may have landed.
      const before = s.next;
      s = readState(a);
      if (s.next === before) die(`cast send failed and no progress was made (${s.next}/${s.total}); stopping`);
      console.log(`cast send reported an error but the check moved to ${s.next}/${s.total}; continuing`);
      continue;
    }
    let rc;
    try {
      rc = JSON.parse(r.out);
    } catch {
      die(`could not read cast's receipt:\n${r.out}`);
    }
    const logs = (rc.logs || []).filter((l) => l.address.toLowerCase() === a.lathe.toLowerCase());
    if (rc.status !== '0x1' && rc.status !== 1 && rc.status !== '1') {
      die(`transaction ${rc.transactionHash} reverted (status ${rc.status}). Possible reasons: deadline + grace over, circuit changed, too little gas. Stopping.`);
    }
    const rej = logs.find((l) => l.topics[0].toLowerCase() === T_REJECTED);
    if (rej) {
      console.log(`Rejected: piece ${a.piece} answered case ${BigInt(rej.data)} wrong (tx ${rc.transactionHash}). The piece reopened; stopping.`);
      process.exit(2);
    }
    s = readState(a);
    console.log(`${s.next}/${s.total}  tx ${rc.transactionHash}  gas used ${BigInt(rc.gasUsed)} of ${limit}`);
    if (logs.some((l) => l.topics[0].toLowerCase() === T_PAID)) console.log(`order ${a.order} paid`);
  }
  const secs = ((Date.now() - t0) / 1000).toFixed(1);
  console.log(`piece ${a.piece} passed: ${sent} transaction(s) in ${secs} s`);
}

function fmtEth(wei) {
  const w = BigInt(wei);
  const whole = w / 10n ** 18n;
  const frac = (w % 10n ** 18n).toString().padStart(18, '0').slice(0, 6);
  return `${whole}.${frac}`;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) main();

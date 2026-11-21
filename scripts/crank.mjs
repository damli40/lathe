#!/usr/bin/env node
// Push a long piece check forward: calls LatheOrders.checkPiece in batches until the piece is done.
// Every transaction is sent by a spawned `cast send`, which signs with your keystore. This script never sees a
// private key. See scripts/README.md.
import { spawnSync } from 'node:child_process';
import { pathToFileURL } from 'node:url';

const HELP = `usage: node scripts/crank.mjs --lathe ADDR --order N --piece I --batch K --rpc URL
         (--account NAME | --keystore PATH) [--password-file PATH]
         [--max-gas G] [--chain-id N] [--dry]
       local anvil only: --unlocked --from ADDR instead of a keystore

  --batch K       cases per transaction (lowered if the gas limit for K cases would pass --max-gas or the
                  chain's block gas limit)
  --max-gas G     highest gas limit for one transaction (default 200000000; X Layer blocks hold 210M)
  --chain-id N    stop before sending anything if the RPC is on another chain (X Layer: 196, testnet: 1952)
  --dry           read the order and print the plan (batches, gas limit per batch, worst-case cost); send nothing

The crank only checks. The builder delivers first, with cast:
  deliverPiece(uint256,uint256,address,uint256)            each case gets 100,000 + 15,000 x gates
  deliverPiece(uint256,uint256,address,uint256,uint32)     the same with --case-gas N: each case gets
      max(formula, N), at most 100,000,000. Declare N = (gas the costliest case needs when it runs first in a
      transaction) x 64/63 + a margin. The crank reads it back (pieceCaseGasOf) and sizes every batch from it.`;

// Gas maths. Each case's eval gets exactly the delivery's per-case gas: pieceCaseGasOf(order, piece), which is
// evalBudget(gateCount) or more if the builder declared more at delivery (deliverPiece with caseGas). A contract
// from before that getter gave evalBudget(gateCount): the script falls back to it. The contract refuses to start a case
// unless gasleft() >= budget * 64/63 + GAS_RESERVE (LatheOrders._requireCaseGas). A circuit may use all of its
// budget, so the only gas limit that can never fail with InsufficientGasForCase is sized from the budget, not from
// a simulation. (Public RPCs cap eth_call at about 50M gas, so a simulation of a big batch fails or lies.)
const EVAL_BASE_GAS = 100_000n;
const EVAL_GAS_PER_GATE = 15_000n;
const GAS_RESERVE = 20_000n;
// Lathe's own work per case (packing, compare, try/catch, memory) was measured at about 7,500 gas
// (evidence/2026-11-21-crank-anvil-run.md: ~169,500 used per case against a ~162,000 mock burn); 30,000 leaves room.
const PER_CASE_OVERHEAD = 30_000n;
const TX_BASE = 150_000n; // intrinsic gas, calldata, storage reads, events
const PAY_BASE = 300_000n; // receipt, fee, transfer, events when the last batch pays the order
const netlistGas = (bytes) => 30_000n + 70n * BigInt(bytes); // read + hash the whole netlist once (~12/byte measured)

export function evalBudget(gates) {
  return EVAL_BASE_GAS + EVAL_GAS_PER_GATE * BigInt(gates);
}

/// The gas each case gets: the stored per-case gas when the contract has one (`caseGas`, BigInt), else the formula.
export function caseBudget({ gates, caseGas }) {
  return caseGas && caseGas > 0n ? caseGas : evalBudget(gates);
}

/// Gas limit for a checkPiece call that runs k cases. `pays` adds the payout, which re-reads every piece's netlist.
/// `caseGas` is the delivery's stored per-case gas (pieceCaseGasOf); without it the formula evalBudget(gates).
export function batchGasLimit({ k, gates, caseGas, netlistBytes, pays, allNetlistBytes = [] }) {
  const budget = caseBudget({ gates, caseGas });
  const perCase = (budget * 64n + 62n) / 63n + GAS_RESERVE + PER_CASE_OVERHEAD;
  let g = TX_BASE + netlistGas(netlistBytes) + BigInt(k) * perCase;
  if (pays) g += PAY_BASE + allNetlistBytes.reduce((s, b) => s + netlistGas(b), 0n);
  return g;
}

/// The largest k <= want whose gas limit fits under maxGas (0 if not even one case fits). maxGas is the smaller of
/// --max-gas and the chain's block gas limit (see gasCeiling).
export function fitBatch(want, opts, maxGas) {
  let k = want;
  while (k > 0 && batchGasLimit({ ...opts, k, pays: opts.paysAt(k) }) > maxGas) k--;
  return k;
}

/// The highest gas limit one transaction may ask for: --max-gas, but never above the block gas limit, since a
/// transaction whose limit is above the block's can never be included.
export function gasCeiling(maxGas, blockGasLimit) {
  return blockGasLimit < maxGas ? blockGasLimit : maxGas;
}

/**
 * What happened to the piece after a send that failed or whose result is unknown, judged from the piece as read
 * again (`after`) against the piece before the send (`before`). Returns one of:
 *   'paid'      the order is Paid (the transaction landed and finished the order);
 *   'rejected'  the delivery was cleared or replaced (processor, circuit or netlist hash differ, or the cursor went
 *               back): a transaction landed and rejected the piece;
 *   'gone'      the order is no longer Open (Refunded) or the piece passed some other way;
 *   'moved'     the cursor moved forward: the transaction landed, carry on;
 *   'stuck'     nothing changed.
 */
export function judgeAfterFailure(before, after) {
  if (after.status === 2) return 'paid';
  if (after.status !== 0) return 'gone';
  const cleared = /^0x0{40}$/i.test(after.proc);
  const replaced = !cleared && (after.proc.toLowerCase() !== before.proc.toLowerCase() || after.circuitId !== before.circuitId
    || after.netlistHash.toLowerCase() !== before.netlistHash.toLowerCase());
  if (cleared || replaced || after.next < before.next) return 'rejected';
  if (after.next >= after.total) return 'gone';
  if (after.next > before.next) return 'moved';
  return 'stuck';
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
      case '--chain-id': a.chainId = BigInt(v()); break;
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

/// cast's error text. With --json, cast send writes its error to stdout, not stderr, so both are shown. Neither
/// can hold the keystore password: cast reads it from the prompt or the password file and never prints it.
function castError(r) {
  let out = r.out;
  try {
    // cast --json error shape: {"success":false,"errors":[{"message":"..."}]}; show the messages, not the JSON.
    const j = JSON.parse(out);
    if (Array.isArray(j.errors) && j.errors.length) out = j.errors.map((e) => e.message ?? JSON.stringify(e)).join('\n');
  } catch {
    /* not JSON: show it as it is */
  }
  return [r.err, out].filter(Boolean).join('\n') || '(cast printed nothing)';
}

function call(a, sig, ...params) {
  const r = cast(['call', a.lathe, sig, ...params.map(String), '--rpc-url', a.rpc]);
  if (!r.ok) die(`read failed: ${sig}\n${r.err}`);
  return r.out;
}

// cast prints each returned value on its own line, sometimes followed by " [1e6]"; keep the first token.
const fields = (out) => out.split('\n').map((l) => l.trim().split(/\s+/)[0]);

function readState(a) {
  const [proc, circuitId, , gates, netlistHash, next] = fields(
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
  return { proc, circuitId, netlistHash, gates: Number(gates), caseGas: readCaseGas(a), next: Number(next), total: 2 ** nIn, status: Number(o[8]), deadline: Number(o[3]), all };
}

/// pieceCaseGasOf(order, piece): the per-case gas fixed at delivery. null on a contract from before it (the call
/// fails), and then the formula is used, which is what such a contract gives each case.
function readCaseGas(a) {
  const r = cast(['call', a.lathe, 'pieceCaseGasOf(uint256,uint256)(uint256)', String(a.order), String(a.piece), '--rpc-url', a.rpc]);
  if (!r.ok) return null;
  return BigInt(r.out.trim().split(/\s+/)[0]);
}

function netlistBytes(a, proc, id) {
  if (/^0x0{40}$/i.test(proc)) return 0;
  const r = cast(['call', proc, 'netlist(uint256)(bytes)', String(id), '--rpc-url', a.rpc]);
  if (!r.ok) die(`could not read netlist of ${proc} #${id}\n${r.err}`);
  return (r.out.length - 2) / 2;
}

/// True for an order created as "needs a top circuit" (LatheOrders.needsTop): its last piece passing does not pay;
/// the builder then delivers one top circuit with deliverTop. A contract from before V3b has no needsTop: false.
function readNeedsTop(a) {
  const r = cast(['call', a.lathe, 'needsTop(uint256)(bool)', String(a.order), '--rpc-url', a.rpc]);
  return r.ok && r.out.trim() === 'true';
}

const topic = (sig) => cast(['keccak', sig]).out.toLowerCase();

/// Chain id and block gas limit, read once at start.
function chainFacts(a) {
  const id = cast(['chain-id', '--rpc-url', a.rpc]);
  if (!id.ok) die(`could not read the chain id from ${a.rpc}\n${castError(id)}`);
  const lim = cast(['block', 'latest', '--field', 'gasLimit', '--rpc-url', a.rpc]);
  if (!lim.ok) die(`could not read the block gas limit from ${a.rpc}\n${castError(lim)}`);
  return { chainId: BigInt(id.out), blockGasLimit: BigInt(lim.out.split(/\s+/)[0]) };
}

function main() {
  const a = parseArgs(process.argv.slice(2));
  const chain = chainFacts(a);
  console.log(`chain id ${chain.chainId}, block gas limit ${chain.blockGasLimit}`);
  if (a.chainId !== undefined && a.chainId !== chain.chainId) {
    die(`the RPC is on chain ${chain.chainId}, not --chain-id ${a.chainId}: stopping before anything is sent`);
  }
  const ceiling = gasCeiling(a.maxGas, chain.blockGasLimit);
  const ceilingName = ceiling < a.maxGas ? `the block gas limit ${ceiling}` : `--max-gas ${a.maxGas}`;
  const T_REJECTED = topic('PieceRejected(uint256,uint256,uint256)');
  const T_PAID = topic('Paid(uint256,address,address,uint256)');
  let s = readState(a);
  if (s.status !== 0) die(`order status is ${['Open', 'Checking', 'Paid', 'Refunded'][s.status]}, not Open: nothing to check`);
  if (/^0x0{40}$/i.test(s.proc)) die('this piece has no delivery: the builder must call deliverPiece first');
  if (s.next >= s.total) die(`piece already passed (${s.next}/${s.total})`);

  const needsTop = readNeedsTop(a);
  const myNet = netlistBytes(a, s.proc, s.circuitId);
  const allNets = s.all.map((p) => netlistBytes(a, p.proc, p.id));
  const opts = {
    gates: s.gates,
    caseGas: s.caseGas,
    netlistBytes: myNet,
    allNetlistBytes: allNets,
    // A batch that finishes the piece may also pay the order (never for a needs-top order: it pays at deliverTop).
    paysAt: (k) => !needsTop && s.next + k >= s.total,
  };
  const want = Math.min(a.batch, s.total - s.next);
  const k = fitBatch(want, opts, ceiling);
  if (k === 0) {
    const one = batchGasLimit({ ...opts, k: 1, pays: opts.paysAt(1) });
    die(`one case needs a gas limit of ${one}, above ${ceilingName} (budget ${caseBudget(opts)} per case): this piece cannot be checked on this chain`);
  }
  if (k < want) console.log(`batch lowered from ${want} to ${k} so the gas limit stays under ${ceilingName}`);

  const remaining = s.total - s.next;
  const txs = Math.ceil(remaining / k);
  const fullLimit = batchGasLimit({ ...opts, k, pays: false });
  const src = s.caseGas === null ? 'formula; this contract stores no per-case gas' : s.caseGas > evalBudget(s.gates) ? 'declared by the builder' : 'formula';
  console.log(`order ${a.order} piece ${a.piece}: ${s.next}/${s.total} cases, ${s.gates} gates, budget ${caseBudget(opts)} gas per case (${src})`);
  console.log(`plan: ${txs} transaction(s) of up to ${k} cases, gas limit ${fullLimit} each (the last one more if it pays)`);
  console.log(`deadline ${new Date(s.deadline * 1000).toISOString()}; checks run until deadline + 1 day`);
  if (needsTop) console.log(TOP_NOTE);

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
    let kk = fitBatch(Math.min(k, s.total - s.next), opts, ceiling);
    if (opts.paysAt(kk)) {
      // This batch may pay the order, which reads every piece's netlist again. Another piece may have been
      // delivered since the start (its netlist was 0 bytes then), so read the sizes again for this gas limit.
      opts.netlistBytes = netlistBytes(a, s.proc, s.circuitId);
      opts.allNetlistBytes = s.all.map((p) => netlistBytes(a, p.proc, p.id));
      kk = fitBatch(kk, opts, ceiling);
      if (kk === 0) die(`the last batch needs a gas limit above ${ceilingName} after re-reading the netlists; stopping`);
      const total = opts.allNetlistBytes.reduce((x, y) => x + y, 0);
      console.log(`last batch may pay: netlists read again (${total} bytes over ${opts.allNetlistBytes.length} piece(s))`);
    }
    const limit = batchGasLimit({ ...opts, k: kk, pays: opts.paysAt(kk) });
    const r = cast(['send', a.lathe, 'checkPiece(uint256,uint256,uint256)', String(a.order), String(a.piece), String(kk),
      '--rpc-url', a.rpc, '--gas-limit', String(limit), '--json', ...wallet], { inherit: true });
    sent++;
    if (!r.ok) {
      // Sending failed (RPC error, wrong password, wrong --from), or cast could not read the result. Say why, then
      // re-read the whole piece before deciding: the transaction may have landed, and may have rejected the piece.
      console.log(`cast send reported an error:\n${castError(r)}`);
      const before = s;
      s = readState(a);
      const what = judgeAfterFailure(before, s);
      if (what === 'rejected') {
        console.log(`Rejected: piece ${a.piece}'s delivery was cleared (a transaction landed and the circuit gave a wrong answer). The piece reopened; stopping.`);
        process.exit(2);
      }
      if (what === 'paid') {
        console.log(`order ${a.order} paid (the transaction landed although cast reported an error)`);
        break;
      }
      if (what === 'gone') die(`the order is now ${['Open', 'Checking', 'Paid', 'Refunded'][s.status]} with piece ${a.piece} at ${s.next}/${s.total}; nothing left to check. Stopping.`);
      if (what === 'stuck') die(`cast send failed and nothing changed (${s.next}/${s.total}); stopping`);
      console.log(`the transaction landed anyway: check moved to ${s.next}/${s.total}; continuing`);
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
  if (needsTop) console.log(TOP_NOTE);
}

const TOP_NOTE = 'this order needs a top circuit: it pays only when the builder calls deliverTop after every piece has passed '
  + '(read expectedTopNetlist(order), mint a circuit with those bytes and the order\'s nIn / nOut, then deliverTop it)';

function fmtEth(wei) {
  const w = BigInt(wei);
  const whole = w / 10n ** 18n;
  const frac = (w % 10n ** 18n).toString().padStart(18, '0').slice(0, 6);
  return `${whole}.${frac}`;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) main();

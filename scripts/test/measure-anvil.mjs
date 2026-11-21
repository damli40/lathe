// scripts/measure-case-gas.mjs on a local anvil (chain id 1952), no keys: anvil's unlocked default account signs
// the setup and the printed delivery. Circuit 5 of DeployTestnet.s.sol is an honest 6-input parity that costs more
// than its formula budget (475,000) when a case runs first in a transaction (it reads 50 storage slots that are
// cold at the start of each transaction), like a real circuit made of links.
//   1. --inputs 6 on circuit 5: every case measured, a value above the formula proposed, exit 0.
//   2. --lathe --order: the shape comes from the order; the printed cast command, run as printed (with anvil's
//      unlocked account instead of a keystore), records the delivery with that value; a split check 7 / 1 / 56
//      pays. The same circuit delivered with the formula is rejected at the same split.
//   3. --piece: the printed command is deliverPiece with the value; the piece then passes a 7 / 1 / 56 split.
//   4. a case needing more than --cap: UNKNOWN, never "fits", exit 1.
//   5. a case needing about 95M: the value is above 100,000,000: REFUSED, exit 1.
//   6. a gate-capped order that promises an inline check: the value would break it: REFUSED, exit 1.
//   7. a node answering every estimate with -32005 (rate limit): retried, then UNKNOWN, exit 1.
//   8. a memory circuit (step): measured, exit 0.
// Run from the repo root: node scripts/test/measure-anvil.mjs
import { execFileSync, spawnSync, spawn } from 'node:child_process';
import { resolve, dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { startAnvil, deployMocks, ANVIL_ACCOUNT0 } from '../../web/test/anvil.mjs';
import { startProxy } from '../../web/test/proxy.mjs';
import { assert } from '../../web/test/lib.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const SCRIPT = join(resolve(HERE, '../..'), 'scripts/measure-case-gas.mjs');
const anvil = await startAnvil({ port: 8566, chainId: 1952 });
const proxy = await startProxy(anvil.url, 8567);
let failed = false;
async function step(name, fn) {
  console.log(name);
  try {
    await fn();
  } catch (e) {
    failed = true;
    console.error('  FAIL ' + e.message);
  }
}
try {
  const R = anvil.url;
  const castOut = (...a) => execFileSync('cast', [...a, '--rpc-url', R], { encoding: 'utf8' }).trim();
  const send = (...a) => castOut('send', ...a, '--unlocked', '--from', ANVIL_ACCOUNT0, '--gas-limit', '25000000');
  const first = (s) => s.split('\n')[0].trim().split(/\s+/)[0];
  const m = deployMocks(R);
  const L = m.lathe;
  const P = m.processor;
  send(m.token, 'approve(address,uint256)', L, String(10n ** 30n));
  const PAR = '0x9669699669969669'; // parity of 6 inputs
  const deadline = String(Math.floor(Date.now() / 1000) + 86400 * 3);
  const nextId = () => first(castOut('call', L, 'nextOrderId()(uint256)'));
  const order = (cap = 0) => {
    const id = nextId();
    send(L, 'createOrder(uint8,uint8,bytes,uint96,uint64,address,uint32)', '6', '1', PAR, '1000000', deadline, ANVIL_ACCOUNT0, String(cap));
    return id;
  };
  const status = (id) => Number(castOut('call', L, 'orders(uint256)(address,address,uint96,uint64,uint32,uint8,uint8,uint8,uint8)', id).split('\n').map(first)[8]);
  // Async: the proxy runs in this process, so a blocking spawnSync would stop it from answering the script.
  const run = (args, rpc = R) => new Promise((ok) => {
    const ch = spawn('node', [SCRIPT, '--rpc', rpc, '--processor', P, ...args]);
    let out = '';
    ch.stdout.on('data', (d) => (out += d));
    ch.stderr.on('data', (d) => (out += d));
    ch.on('close', (code) => ok({ code, out }));
  });
  const value = (out) => BigInt((out.match(/value to declare: ([\d,]+)/) || [, '0'])[1].replace(/,/g, ''));
  /** The printed cast command, run as printed except for the signer. */
  const runPrinted = (out) => {
    const line = out.split('\n').find((l) => l.startsWith('cast send '));
    assert(!!line && line.endsWith('--account YOUR_ACCOUNT'), `prints a cast send command: ${line}`);
    const words = line.replace(/ --account YOUR_ACCOUNT$/, '').match(/"[^"]*"|\S+/g).map((w) => w.replace(/^"|"$/g, ''));
    execFileSync(words[0], [...words.slice(1), '--unlocked', '--from', ANVIL_ACCOUNT0], { encoding: 'utf8' });
  };
  // Checks get a high limit: 56 cases x 620,000 x 64/63 is about 36M gas.
  const sendBig = (...a) => castOut('send', ...a, '--unlocked', '--from', ANVIL_ACCOUNT0, '--gas-limit', '100000000');
  const check = (id, n) => sendBig(L, 'check(uint256,uint256)', id, String(n));
  const checkPiece = (id, n) => sendBig(L, 'checkPiece(uint256,uint256,uint256)', id, '0', String(n));

  let v1;
  await step('1. --inputs 6 on circuit 5', async () => {
    const r = await run(['--circuit', '5', '--inputs', '6']);
    console.log(r.out.split('\n').map((l) => '    | ' + l).join('\n'));
    v1 = value(r.out);
    assert(r.code === 0, `exit 0 (${r.code})`);
    assert(/measuring 64 case\(s\)/.test(r.out) && !/UNKNOWN/.test(r.out), 'all 64 cases measured');
    assert(/formula budget per case: 475,000/.test(r.out), 'formula 475,000');
    assert(v1 > 475_000n && v1 % 10_000n === 0n, `value ${v1} above the formula, a multiple of 10,000`);
    assert(/does not fit the formula budget/.test(r.out), 'says it does not fit the formula');
    assert(/cast send LATHE_ADDRESS "deliver\(uint256,address,uint256,uint32\)" ORDER_ID /.test(r.out), 'without an order: placeholders in the command');
  });

  await step('2. --order: the printed command delivers; a 7 / 1 / 56 split pays; the formula is rejected there', async () => {
    const o = order();
    const r = await run(['--circuit', '5', '--lathe', L, '--order', o]);
    assert(r.code === 0, `exit 0 (${r.code})`);
    assert(value(r.out) === v1, `same value read through the order (${value(r.out)})`);
    runPrinted(r.out);
    assert(first(castOut('call', L, 'caseGasOf(uint256)(uint256)', o)) === v1.toString(), `caseGasOf(${o}) = ${v1}`);
    check(o, 7);
    check(o, 1);
    check(o, 56);
    assert(status(o) === 2, `order ${o} Paid after the split`);
    const b = order();
    send(L, 'deliver(uint256,address,uint256)', b, P, '5');
    check(b, 7);
    check(b, 1);
    assert(status(b) === 0, `order ${b} with the formula: rejected at the split, Open again`);
  });

  await step('3. --piece: the printed deliverPiece passes a split', async () => {
    const id = nextId();
    send(L, 'createPiecedOrder((uint8,uint8,uint8,uint8,uint8)[],bytes[],uint96,uint64,address,uint32[],bytes32[])',
      '[(0,6,1,0,0)]', `[${PAR}]`, '1000000', deadline, ANVIL_ACCOUNT0, '[0]', '[]');
    const r = await run(['--circuit', '5', '--lathe', L, '--order', id, '--piece', '0']);
    assert(r.code === 0, `exit 0 (${r.code})`);
    assert(new RegExp(`"deliverPiece\\(uint256,uint256,address,uint256,uint32\\)" ${id} 0 `).test(r.out), 'prints deliverPiece with the piece index');
    runPrinted(r.out);
    assert(first(castOut('call', L, 'pieceCaseGasOf(uint256,uint256)(uint256)', id, '0')) === v1.toString(), `pieceCaseGasOf = ${v1}`);
    checkPiece(id, 7);
    checkPiece(id, 1);
    checkPiece(id, 56);
    assert(status(id) === 2, `pieced order ${id} Paid`);
  });

  // One-input circuits for 4, 5, 8 (no access control on the mock).
  send(P, 'setCircuit(uint256,address,uint32,uint32,uint32,uint32)', '30', ANVIL_ACCOUNT0, '1', '1', '0', '4');
  send(P, 'setOuts(uint256,bytes[])', '30', '[0x00,0x01]');
  send(P, 'setCaseGasCost(uint256,uint256,uint256)', '30', '1', '200000000');
  send(P, 'setCircuit(uint256,address,uint32,uint32,uint32,uint32)', '31', ANVIL_ACCOUNT0, '1', '1', '0', '4');
  send(P, 'setOuts(uint256,bytes[])', '31', '[0x00,0x01]');
  send(P, 'setCaseGasCost(uint256,uint256,uint256)', '31', '1', '95000000');

  await step('4. a case above --cap: UNKNOWN, never fits', async () => {
    const r = await run(['--circuit', '30', '--inputs', '1']);
    assert(r.code === 1, `exit 1 (${r.code})`);
    assert(/UNKNOWN: 1 case\(s\) could not be measured/.test(r.out) && /case 1: /.test(r.out), 'case 1 unknown');
    assert(/NOT READY/.test(r.out), 'says not ready');
    const r2 = await run(['--circuit', '5', '--inputs', '6'], proxy.url);
    assert(r2.code === 0, 'through a 50M-capped proxy a cheap circuit still measures' + (r2.code === 0 ? '' : ': ' + r2.out.slice(-400)));
    const r3 = await run(['--circuit', '31', '--inputs', '1'], proxy.url);
    assert(r3.code === 1 && /UNKNOWN: 1 case/.test(r3.out), 'through a 50M-capped proxy the 95M case is unknown, not fitting');
  });

  await step('5. about 95M: above 100,000,000, refused', async () => {
    const r = await run(['--circuit', '31', '--inputs', '1']);
    assert(r.code === 1, `exit 1 (${r.code})`);
    assert(/REFUSED: [\d,]+ is above the most a case can get \(100,000,000\)/.test(r.out), 'refused above MAX_CASE_GAS');
  });

  await step('6. a gate cap that promises an inline check refuses the value', async () => {
    send(P, 'setCircuit(uint256,address,uint32,uint32,uint32,uint32)', '32', ANVIL_ACCOUNT0, '6', '1', '0', '20');
    const outs = [...Array(64).keys()].map((c) => ((c.toString(2).split('1').length - 1) & 1 ? '0x01' : '0x00'));
    send(P, 'setOuts(uint256,bytes[])', '32', `[${outs.join(',')}]`);
    send(P, 'setColdSlots(uint256,uint256)', '32', '50');
    send(P, 'setEvalGasCost(uint256,uint256)', '32', '420000');
    const o = order(24);
    const r = await run(['--circuit', '32', '--lathe', L, '--order', o]);
    assert(r.code === 1, `exit 1 (${r.code})`);
    assert(/REFUSED: the gate cap \(24\) promises a check inside the delivery: all 64 cases within 30,000,000 gas, so at most 468,750 per case/.test(r.out), 'explains the cap');
    const line = r.out.split('\n').find((l) => l.startsWith('cast send '));
    const words = line.replace(/ --account YOUR_ACCOUNT$/, '').match(/"[^"]*"|\S+/g).map((w) => w.replace(/^"|"$/g, ''));
    spawnSync(words[0], [...words.slice(1), '--unlocked', '--from', ANVIL_ACCOUNT0], { encoding: 'utf8' });
    assert(status(o) === 0 && first(castOut('call', L, 'caseGasOf(uint256)(uint256)', o)) === '0', 'the printed command, sent anyway, records nothing');
    const sim = spawnSync('cast', ['call', ...words.slice(2, 8), '--rpc-url', R, '--from', ANVIL_ACCOUNT0], { encoding: 'utf8' });
    const sel = execFileSync('cast', ['sig', 'CaseGasTooHigh()'], { encoding: 'utf8' }).trim();
    assert(sim.status !== 0 && (sim.stderr + sim.stdout).includes(sel.slice(2)), `the contract refuses it with CaseGasTooHigh (${sel})`);
  });

  await step('7. -32005 on every estimate: retried, then unknown', async () => {
    proxy.st.forced = 0;
    proxy.st.answer = (q) => (q.method === 'eth_estimateGas' ? { code: -32005, message: 'request rate exceeded' } : null);
    const r = await run(['--circuit', '30', '--inputs', '1', '--pause', '10'], proxy.url);
    proxy.st.answer = null;
    assert(r.code === 1 && /UNKNOWN: 2 case\(s\)/.test(r.out) && /code -32005/.test(r.out), 'both cases unknown, the node\'s error shown: ' + r.out.slice(-300));
    assert(proxy.st.forced === 8, `each case tried 4 times (${proxy.st.forced} answers)`);
  });

  await step('8. a memory circuit is measured with step', async () => {
    const r = await run(['--circuit', '3', '--inputs', '1', '--state', '1']);
    assert(r.code === 0 && /measuring 4 case\(s\)/.test(r.out), `exit 0, 4 cases (${r.code})`);
    const bad = await run(['--circuit', '3', '--inputs', '1']);
    assert(bad.code === 2 && /expected 1 and 0/.test(bad.out), 'a shape mismatch is a read error (exit 2)');
  });
} catch (e) {
  failed = true;
  console.error('MEASURE FAIL:', e.message);
} finally {
  proxy.close();
  anvil.stop();
}
console.log(failed ? 'MEASURE FAIL' : 'MEASURE PASS: measured, delivered as printed, unknown never fits, refusals above 100M and under a gate cap');
process.exitCode = failed ? 1 : 0;

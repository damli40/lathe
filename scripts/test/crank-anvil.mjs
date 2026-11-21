// scripts/crank.mjs on a local anvil with a 30M block gas limit (chain id 1952), no keys: anvil's unlocked default
// account signs. Each case below is a fix from the V3a review; run with CRANK=<path> to point it at another copy
// of the script (for example the one before the fix) and see which cases fail.
//   1. --chain-id that does not match the RPC: refused before anything is sent.
//   2. a wrong --from: cast's own error text is shown (with --json cast prints it on stdout), and nothing changed.
//   3. a 30M block: the chain id and block gas limit are printed, batches stay under the block limit, the piece is
//      checked to Paid; a piece whose single case needs more than the block is refused before any send.
//   4. a send that "fails" (the transaction lands, cast exits 1) and was the one that rejected the piece: the script
//      re-reads the piece, says Rejected, exits 2, and sends nothing more.
//   5. the netlist sizes for the paying batch are read again: piece 1 is delivered while piece 0 is being cranked,
//      and the last batch's gas limit counts piece 1's netlist.
// Run from the repo root: node scripts/test/crank-anvil.mjs
import { execFileSync, spawnSync } from 'node:child_process';
import { mkdtempSync, writeFileSync, chmodSync, readFileSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { startAnvil, deployMocks, ANVIL_ACCOUNT0 } from '../../web/test/anvil.mjs';
import { assert } from '../../web/test/lib.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO = resolve(HERE, '../..');
const CRANK = process.env.CRANK || join(REPO, 'scripts/crank.mjs');
const REAL_CAST = execFileSync('sh', ['-c', 'command -v cast'], { encoding: 'utf8' }).trim();

// A folder with a `cast` that runs fake-cast.mjs, put first on PATH for the runs that need it.
const fakeDir = mkdtempSync(join(tmpdir(), 'lathe-fakecast-'));
writeFileSync(join(fakeDir, 'cast'), `#!/bin/sh\nexec node ${JSON.stringify(join(HERE, 'fake-cast.mjs'))} "$@"\n`);
chmodSync(join(fakeDir, 'cast'), 0o755);

const anvil = await startAnvil({ port: 8556, chainId: 1952, gasLimit: 30_000_000 });
let failed = false;
const results = [];
async function step(name, fn) {
  console.log(name);
  try {
    await fn();
    results.push(['pass', name]);
  } catch (e) {
    failed = true;
    results.push(['FAIL', name + ': ' + e.message]);
    console.error('  ' + e.message);
  }
}
try {
  const R = anvil.url;
  const castOut = (...a) => execFileSync(REAL_CAST, [...a, '--rpc-url', R], { encoding: 'utf8' }).trim();
  const send = (...a) => castOut('send', ...a, '--unlocked', '--from', ANVIL_ACCOUNT0, '--gas-limit', '25000000');
  const first = (s) => s.split('\n')[0].trim().split(/\s+/)[0];
  assert(first(castOut('block', 'latest', '--field', 'gasLimit')) === '30000000', 'anvil block gas limit is 30M');

  const m = deployMocks(R);
  const L = m.lathe;
  const FP = m.formula;
  send(m.token, 'approve(address,uint256)', L, String(10n ** 30n));
  // Extra mock circuits on the FormulaProcessor (no access control): GreaterOrEqual(4, 4), 256 cases.
  send(FP, 'setCircuit(uint256,address,bool,uint8,uint8,uint32)', '10', ANVIL_ACCOUNT0, 'false', '4', '4', '70'); // honest, budget 1.15M
  send(FP, 'setCircuit(uint256,address,bool,uint8,uint8,uint32)', '11', ANVIL_ACCOUNT0, 'false', '4', '4', '2000'); // budget 30.1M
  send(FP, 'setCircuit(uint256,address,bool,uint8,uint8,uint32)', '12', ANVIL_ACCOUNT0, 'false', '4', '4', '70');
  send(FP, 'setWrongAt(uint256,uint256)', '12', '30'); // in the second batch of 24
  const deadline = String(Math.floor(Date.now() / 1000) + 86400 * 3);
  const GE44 = '(1,8,1,4,4)';
  const XOR = '(0,2,1,0,0)';
  const create = (pieces, tables) => {
    const id = BigInt(first(castOut('call', L, 'nextOrderId()(uint256)')));
    const n = tables.length;
    send(L, 'createPiecedOrder((uint8,uint8,uint8,uint8,uint8)[],bytes[],uint96,uint64,address,uint32[],bytes32[])',
      `[${pieces.join(',')}]`, `[${tables.join(',')}]`, '1000000', deadline, ANVIL_ACCOUNT0, `[${Array(n).fill(0).join(',')}]`, '[]');
    return String(id);
  };
  const deliverPiece = (id, i, proc, cid) => send(L, 'deliverPiece(uint256,uint256,address,uint256)', id, String(i), proc, String(cid));
  const pieceState = (id, i) => castOut('call', L, 'pieceOf(uint256,uint256)(address,uint256,address,uint32,bytes32,uint32)', id, String(i)).split('\n').map(first);
  const status = (id) => Number(castOut('call', L, 'orders(uint256)(address,address,uint96,uint64,uint32,uint8,uint8,uint8,uint8)', id).split('\n').map(first)[8]);
  const blockNo = () => Number(castOut('block-number'));
  const crank = (args, env = {}) => {
    const r = spawnSync('node', [CRANK, '--lathe', L, '--rpc', R, '--unlocked', ...args], { encoding: 'utf8', env: { ...process.env, ...env } });
    const res = { code: r.status, out: (r.stdout || '') + (r.stderr || '') };
    if (process.env.CRANK_SHOW) console.log(`   [exit ${res.code}] ` + res.out.trim().split('\n').slice(-3).join(' | '));
    return res;
  };
  const me = ['--from', ANVIL_ACCOUNT0];
  let r;
  let b0;
  let o1;

  await step('1. --chain-id that does not match', async () => {
    o1 = create([GE44], ['0x']);
    deliverPiece(o1, 0, FP, 10);
    b0 = blockNo();
    r = crank(['--order', o1, '--piece', '0', '--batch', '10', '--chain-id', '196', ...me]);
    assert(r.code === 1 && /on chain 1952, not --chain-id 196/.test(r.out), 'refused: "the RPC is on chain 1952, not --chain-id 196"');
    assert(blockNo() === b0, 'nothing was sent');
  });

  await step('2. a wrong --from', async () => {
    b0 = blockNo();
    r = crank(['--order', o1, '--piece', '0', '--batch', '10', '--from', '0x000000000000000000000000000000000000dEaD']);
    assert(r.code === 1, 'exit code 1');
    assert(/cast send reported an error:\n[\s\S]*\S/.test(r.out), "cast's error text is shown");
    assert(/[Ss]igner|unknown account|not unlocked|No Signer/.test(r.out), "it is cast's / the node's reason (signer), not a generic line");
    assert(/nothing changed \(0\/256\)/.test(r.out), 'then: "nothing changed (0/256); stopping"');
    assert(blockNo() === b0, 'no transaction landed');
    console.log('   cast said: ' + (r.out.split('cast send reported an error:\n')[1] || '').split('\n').slice(0, 2).join(' | '));
  });

  await step('3. a 30M block', async () => {
    r = crank(['--order', o1, '--piece', '0', '--batch', '100', '--chain-id', '1952', ...me]);
    assert(/chain id 1952, block gas limit 30000000/.test(r.out), 'prints "chain id 1952, block gas limit 30000000"');
    assert(/batch lowered from 100 to \d+ so the gas limit stays under the block gas limit 30000000/.test(r.out), 'batch lowered under the block gas limit');
    const limits = [...r.out.matchAll(/gas used \d+ of (\d+)/g)].map((x) => BigInt(x[1]));
    assert(limits.length > 1 && limits.every((g) => g <= 30_000_000n), `every gas limit <= 30M (${limits.length} transactions, highest ${limits.reduce((a, b) => (a > b ? a : b), 0n)})`);
    assert(r.code === 0 && /order \d+ paid/.test(r.out) && status(o1) === 2, 'checked to Paid');
    const o3 = create([GE44], ['0x']);
    deliverPiece(o3, 0, FP, 11);
    b0 = blockNo();
    r = crank(['--order', o3, '--piece', '0', '--batch', '10', ...me]);
    assert(r.code === 1 && /one case needs a gas limit of \d+, above the block gas limit 30000000/.test(r.out), 'a 2,000-gate piece (budget 30.1M per case) is refused: one case does not fit the block');
    assert(blockNo() === b0, 'nothing was sent');
  });

  await step('4. a send that "fails" but landed and rejected the piece', async () => {
    const o4 = create([GE44], ['0x']);
    deliverPiece(o4, 0, FP, 12); // wrong at case 30: the second batch (cases 24..47) rejects it
    const log4 = join(fakeDir, 'log4');
    r = crank(['--order', o4, '--piece', '0', '--batch', '100', ...me], { PATH: fakeDir + ':' + process.env.PATH, REAL_CAST, FAKE_LOG: log4, FAKE_FAIL_SEND_AT: '2' });
    const sends = existsSync(log4) ? readFileSync(log4, 'utf8').trim().split('\n').length : 0;
    assert(/fake RPC timeout/.test(r.out), "the fake cast's error text is shown");
    assert(r.code === 2 && /Rejected: piece 0's delivery was cleared/.test(r.out), 'says Rejected, exit code 2');
    assert(!/continuing/.test(r.out), 'never says "check moved to 0/256; continuing"');
    assert(sends === 2, `sent 2 transactions, no more (${sends})`);
    assert(/^0x0{40}$/i.test(pieceState(o4, 0)[0]), 'on chain the delivery is cleared');
  });

  await step('4b. a send that "fails" but landed and moved the check on', async () => {
    const o4b = create([GE44], ['0x']);
    deliverPiece(o4b, 0, FP, 10);
    r = crank(['--order', o4b, '--piece', '0', '--batch', '100', ...me], { PATH: fakeDir + ':' + process.env.PATH, REAL_CAST, FAKE_LOG: join(fakeDir, 'log4b'), FAKE_FAIL_SEND_AT: '2' });
    assert(/the transaction landed anyway: check moved to 48\/256; continuing/.test(r.out), 'says "the transaction landed anyway: check moved to 48/256; continuing"');
    assert(r.code === 0 && status(o4b) === 2, 'and carries on to Paid');
  });

  await step('5. netlists read again for the paying batch', async () => {
    const o5 = create([GE44, XOR], ['0x', '0x06']);
    deliverPiece(o5, 0, FP, 10);
    const netA = (castOut('call', FP, 'netlist(uint256)(bytes)', '10').length - 2) / 2;
    const netB = (castOut('call', m.processor, 'netlist(uint256)(bytes)', '1').length - 2) / 2;
    const hook = ['send', L, 'deliverPiece(uint256,uint256,address,uint256)', o5, '1', m.processor, '1', '--rpc-url', R, '--unlocked', '--from', ANVIL_ACCOUNT0, '--gas-limit', '5000000'];
    r = crank(['--order', o5, '--piece', '0', '--batch', '100', ...me], { PATH: fakeDir + ':' + process.env.PATH, REAL_CAST, FAKE_LOG: join(fakeDir, 'log5'), FAKE_HOOK_AT: '2', FAKE_HOOK_ARGS: JSON.stringify(hook) });
    assert(new RegExp(`netlists read again \\(${netA + netB} bytes over 2 piece\\(s\\)\\)`).test(r.out), `the paying batch counts both netlists (${netA} + ${netB} bytes; piece 1 was delivered after the start)`);
    assert(r.code === 0 && status(o5) === 2, 'the last batch paid the two-piece order');
  });
} catch (e) {
  failed = true;
  console.error('CRANK FAIL:', e.message);
} finally {
  anvil.stop();
}
for (const [k, n] of results) console.log(`${k}  ${n}`);
if (failed) {
  process.exitCode = 1;
  console.log('CRANK FAIL');
} else console.log('CRANK PASS');

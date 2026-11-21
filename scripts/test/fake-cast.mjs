#!/usr/bin/env node
// Test stand-in for `cast`, used only by scripts/test/crank-anvil.mjs. It runs the real cast (REAL_CAST) and,
// for `cast send`, can misbehave on purpose:
//   FAKE_FAIL_SEND_AT=n   the n-th send (1 = first) really lands, then this exits 1 with junk on stdout, like an
//                         RPC that timed out after accepting the transaction;
//   FAKE_HOOK_AT=n        before the n-th send, run the real cast with the JSON array in FAKE_HOOK_ARGS;
//   FAKE_LOG=path         append one line per send, so the test can count sends.
import { spawnSync } from 'node:child_process';
import { appendFileSync, existsSync, readFileSync, writeFileSync } from 'node:fs';

const real = process.env.REAL_CAST;
const args = process.argv.slice(2);
if (args[0] === 'send') {
  const counter = process.env.FAKE_LOG + '.n';
  const n = (existsSync(counter) ? Number(readFileSync(counter, 'utf8')) : 0) + 1;
  writeFileSync(counter, String(n));
  appendFileSync(process.env.FAKE_LOG, `send ${n}: ${args.slice(1, 6).join(' ')}\n`);
  if (Number(process.env.FAKE_HOOK_AT) === n) {
    const h = spawnSync(real, JSON.parse(process.env.FAKE_HOOK_ARGS), { encoding: 'utf8' });
    if (h.status !== 0) {
      process.stderr.write('fake-cast hook failed: ' + h.stderr);
      process.exit(3);
    }
  }
  if (Number(process.env.FAKE_FAIL_SEND_AT) === n) {
    spawnSync(real, args, { encoding: 'utf8' }); // the transaction lands
    process.stdout.write('Error: fake RPC timeout after the transaction was accepted\n');
    process.exit(1);
  }
}
const r = spawnSync(real, args, { stdio: 'inherit' });
process.exit(r.status ?? 1);

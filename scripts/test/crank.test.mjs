// Pure parts of scripts/crank.mjs. Run: node --test scripts/test/
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { gasCeiling, judgeAfterFailure, batchGasLimit, fitBatch } from '../crank.mjs';

const P = '0x00000000000000000000000000000000000000aa';
const Z = '0x0000000000000000000000000000000000000000';
const H = '0x' + '11'.repeat(32);
const piece = (o) => ({ status: 0, proc: P, circuitId: '7', netlistHash: H, next: 100, total: 256, ...o });

test('gas ceiling is the smaller of --max-gas and the block gas limit', () => {
  assert.equal(gasCeiling(200_000_000n, 30_000_000n), 30_000_000n);
  assert.equal(gasCeiling(200_000_000n, 210_000_000n), 200_000_000n);
});

test('batches fit under the ceiling; 0 when one case does not', () => {
  const opts = { gates: 70, netlistBytes: 46, allNetlistBytes: [46], paysAt: () => false };
  const k = fitBatch(100, opts, 30_000_000n);
  assert.ok(k > 0 && batchGasLimit({ ...opts, k }) <= 30_000_000n && batchGasLimit({ ...opts, k: k + 1 }) > 30_000_000n);
  assert.equal(fitBatch(10, { ...opts, gates: 2000 }, 30_000_000n), 0);
});

test('after a failed send: judged from the whole piece, not the cursor alone', () => {
  const before = piece();
  assert.equal(judgeAfterFailure(before, piece({ proc: Z, circuitId: '0', netlistHash: '0x' + '00'.repeat(32), next: 0 })), 'rejected');
  assert.equal(judgeAfterFailure(before, piece({ circuitId: '8', next: 0 })), 'rejected'); // rejected, then delivered again
  assert.equal(judgeAfterFailure(before, piece({ next: 50 })), 'rejected'); // cursor went back
  assert.equal(judgeAfterFailure(before, piece({ next: 200 })), 'moved');
  assert.equal(judgeAfterFailure(before, piece()), 'stuck');
  assert.equal(judgeAfterFailure(before, piece({ status: 2, next: 256 })), 'paid');
  assert.equal(judgeAfterFailure(before, piece({ status: 3, proc: Z })), 'gone');
  assert.equal(judgeAfterFailure(before, piece({ next: 256 })), 'gone'); // passed, order waits for another piece
});

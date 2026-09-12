#!/usr/bin/env node
import { readFileSync, writeFileSync, mkdirSync, rmSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { tmpdir } from 'node:os';

const appRoot = resolve(import.meta.dirname, '..');
const sourcePath = join(appRoot, 'entry', 'src', 'main', 'ets', 'commons', 'services', 'LatencyController.ets');
const sandbox = join(tmpdir(), 'ssrvpn-latency-cache-' + process.pid);
rmSync(sandbox, { recursive: true, force: true });
mkdirSync(sandbox, { recursive: true });
writeFileSync(join(sandbox, 'package.json'), JSON.stringify({ type: 'module' }), 'utf8');
const stagedPath = join(sandbox, 'LatencyController.ts');
writeFileSync(stagedPath, readFileSync(sourcePath, 'utf8'), 'utf8');

try {
  const { LatencyController } = await import(pathToFileURL(stagedPath).href);
  LatencyController.clearAll();
  LatencyController.set('active-a', 31);
  LatencyController.set('stale-b', 92);
  LatencyController.set('active-c', -1);
  LatencyController.retainOnly(['active-a', 'active-c']);

  const checks = [
    ['active positive latency retained', LatencyController.latencyFor('active-a') === 31],
    ['active failed latency retained', LatencyController.latencyFor('active-c') === -1],
    ['stale latency reclaimed', LatencyController.latencyFor('stale-b') === null]
  ];
  const failed = checks.filter((entry) => !entry[1]);
  for (const [label, ok] of checks) {
    console.log((ok ? 'PASS ' : 'FAIL ') + label);
  }
  if (failed.length > 0) {
    process.exitCode = 1;
  }
} finally {
  rmSync(sandbox, { recursive: true, force: true });
}

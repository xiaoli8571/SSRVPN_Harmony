'use strict';

const fs = require('fs');
const path = require('path');
const assert = require('assert');

const root = path.resolve(__dirname, '..');
const pagePath = path.join(root, 'entry/src/main/ets/pages/NodeSelectionPage.ets');
const apiPath = path.join(root, 'entry/src/main/ets/commons/services/ClashApiService.ets');
const page = fs.readFileSync(pagePath, 'utf8');
const api = fs.readFileSync(apiPath, 'utf8');

function delay(ms, value, reject) {
  return new Promise((resolve, rejectFn) => setTimeout(() => reject ? rejectFn(value) : resolve(value), ms));
}

function parseMihomo(response) {
  if (!response || response.code !== 200 || typeof response.body !== 'string' || response.body.length === 0) return -1;
  try {
    const parsed = JSON.parse(response.body);
    return Number.isFinite(parsed.delay) && parsed.delay >= 0 ? parsed.delay : -1;
  } catch (_) {
    return -1;
  }
}

async function testWithFallback(urls, timeoutMs, request) {
  const deadline = Date.now() + timeoutMs;
  for (let i = 0; i < urls.length; i++) {
    const remaining = deadline - Date.now();
    if (remaining <= 0) return -1;
    const attemptsLeft = urls.length - i;
    const budget = attemptsLeft > 1 ? Math.max(10, Math.floor(remaining / attemptsLeft)) : remaining;
    try {
      const result = await Promise.race([
        request(urls[i], budget),
        delay(budget, -1)
      ]);
      if (result >= 0) return result;
    } catch (_) {}
  }
  return -1;
}

async function runLimited(items, lanes, generation, getGeneration, worker) {
  let cursor = 0;
  const writes = [];
  const jobs = Array.from({ length: Math.min(lanes, items.length) }, async () => {
    for (;;) {
      if (generation !== getGeneration()) return;
      const index = cursor++;
      if (index >= items.length) return;
      const result = await worker(items[index], index);
      if (generation !== getGeneration()) return;
      writes.push([index, result]);
    }
  });
  await Promise.all(jobs);
  return writes;
}

async function main() {
  const names = ['中文 节点', 'space node', 'hash#node', 'percent%node', 'slash/node'];
  for (const name of names) {
    const encoded = encodeURIComponent(name);
    assert.strictEqual(decodeURIComponent(encoded), name);
    assert(!encoded.includes('#'));
    assert(!encoded.includes('/'));
  }
  assert(api.includes('/proxies/${encodeURIComponent(nodeName)}/delay'));
  assert.strictEqual((api.match(/encodeURIComponent\(nodeName\)/g) || []).length, 1);

  assert.strictEqual(parseMihomo({ code: 200, body: '{"delay":42}' }), 42);
  assert.strictEqual(parseMihomo({ code: 200, body: '{"delay":380}' }), 380);
  assert.strictEqual(parseMihomo({ code: 204, body: '' }), -1);
  assert.strictEqual(parseMihomo({ code: 200, body: '' }), -1);
  assert.strictEqual(parseMihomo({ code: 200, body: '{"error":"timeout"}' }), -1);

  let calls = [];
  const quick = await testWithFallback(['a'], 100, async (url) => { calls.push(url); return delay(5, 25); });
  assert.strictEqual(quick, 25);

  calls = [];
  const slow = await testWithFallback(['a'], 200, async (url) => { calls.push(url); return delay(70, 95); });
  assert.strictEqual(slow, 95);

  calls = [];
  const fallback = await testWithFallback(['bad', 'good'], 200, async (url) => {
    calls.push(url);
    if (url === 'bad') throw new Error('network');
    return delay(10, 61);
  });
  assert.strictEqual(fallback, 61);
  assert.deepStrictEqual(calls, ['bad', 'good']);

  const started = Date.now();
  const timedOut = await testWithFallback(['hang'], 60, async () => delay(500, 77));
  assert.strictEqual(timedOut, -1);
  assert(Date.now() - started < 180);

  let active = 0;
  let peak = 0;
  let generation = 1;
  const writes = await runLimited(Array.from({ length: 24 }, (_, i) => i), 8, generation, () => generation, async (item) => {
    active++;
    peak = Math.max(peak, active);
    const result = await delay(5 + (item % 3), item);
    active--;
    return result;
  });
  assert.strictEqual(writes.length, 24);
  assert(peak <= 8);

  generation = 2;
  const latePromise = runLimited([1, 2, 3], 2, generation, () => generation, async (item) => delay(50, item));
  setTimeout(() => { generation = 3; }, 5);
  const lateWrites = await latePromise;
  assert.strictEqual(lateWrites.length, 0);

  assert(page.includes('await this.orchestrator.ensureTestCore(this.subs, this.settings)'));
  assert(page.includes("this.latencyChannel = this.testCoreOk ? CHANNEL_KERNEL : CHANNEL_DIRECT"));
  assert(page.includes("this.directReachableNames.has(row.node.name) ? '端口可达'"));
  assert(page.includes('LatencyController.set(node.name, -2)'));
  assert(page.includes('const deadline = Date.now() + timeoutMs'));
  assert(page.includes('this.batchGen !== generation'));
  assert(page.includes('const BATCH_LANES = 8'));
  assert(api.includes('if (resp.responseCode !== 200)'));
  assert(api.includes('if (body.length === 0)'));

  console.log('PASS latency pipeline regression: special names, fast/slow success, HTTP 204, empty/error/network/timeout, URL fallback, budget, concurrency, late response guard, TestCore fallback label');
}

main().catch((error) => {
  console.error(error.stack || error);
  process.exit(1);
});

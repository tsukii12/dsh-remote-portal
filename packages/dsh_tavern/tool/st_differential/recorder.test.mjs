import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import http from 'node:http';
import { createRecorder } from './recorder.mjs';
import { compareRequests } from './compare.mjs';
import { compareRecordingSets, compactComparisonReport } from './compare-all.mjs';

test('origin-form double slash from native ST DeepSeek reaches the active fixture unchanged', async () => {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'dsh-st-native-route-'));
  const recorder = await createRecorder({ outputDirectory: directory, fixtures: [{ id: 'native' }], port: 0, log: () => {} });
  const raw = '{ "messages": [{"role":"user","content":"海🐳"}], "stream": true }';
  // HTTP options.path is the actual request-target. Do not resolve this string
  // with URL(relative, base), which would reproduce the old test blind spot.
  const sendRawTarget = () => new Promise((resolve, reject) => {
    const request = http.request({ hostname: '127.0.0.1', port: Number(new URL(recorder.url).port),
      method: 'POST', path: '//chat/completions',
      headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(raw) } }, response => {
      const chunks = [];
      response.on('data', chunk => chunks.push(chunk));
      response.on('end', () => resolve({ status: response.statusCode, body: Buffer.concat(chunks).toString('utf8') }));
      response.on('error', reject);
    });
    request.on('error', reject);
    request.end(raw);
  });
  try {
    assert.equal((await sendRawTarget()).status, 404);
    const selection = await fetch(`${recorder.url}/active-case`, { method: 'POST', body: '{"id":"native"}' });
    assert.equal(selection.status, 200);
    await selection.text();
    const response = await sendRawTarget();
    assert.equal(response.status, 200);
    assert.ok(response.body.endsWith('data: [DONE]\n\n'));
    assert.deepEqual(await fs.readFile(path.join(directory, 'native/001.request.raw.json')), Buffer.from(raw));
    const metadata = JSON.parse(await fs.readFile(path.join(directory, 'native/001.meta.json'), 'utf8'));
    assert.equal(metadata.path, '//chat/completions');
    const health = await (await fetch(`${recorder.url}/health`)).json();
    assert.deepEqual(health.counts, { native: 1 });
    assert.deepEqual(health.attempts, { native: 1 });
  } finally {
    await recorder.close();
    await fs.rm(directory, { recursive: true, force: true });
  }
});

test('records exact request bytes, independent attempts, and valid fake responses', async () => {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'dsh-st-recorder-'));
  const recorder = await createRecorder({ outputDirectory: directory, fixtures: [{ id: 'cjk' }], port: 0, log: () => {} });
  try {
    const driver = await fetch(`${recorder.url}/browser-driver.mjs`);
    assert.equal(driver.status, 200);
    assert.match(driver.headers.get('content-type'), /^text\/javascript/);
    assert.match(await driver.text(), /export async function runFixture/);
    const raw = '{ "model": "fixture", "messages": [{"role":"user","content":"鲸鱼🐋\\n第二行"}], "stream": false }';
    const response = await fetch(`${recorder.url}/cases/cjk/chat/completions`, { method: 'POST', body: raw,
      headers: { 'Content-Type': 'application/json', Authorization: 'Bearer synthetic-only' } });
    assert.equal(response.status, 200);
    assert.equal((await response.json()).choices[0].message.content, 'RECORDER_OK');
    assert.deepEqual(await fs.readFile(path.join(directory, 'cjk/001.request.raw.json')), Buffer.from(raw));
    const stream = await fetch(`${recorder.url}/cases/cjk/beta/chat/completions`, { method: 'POST',
      body: JSON.stringify({ messages: [], stream: true }) });
    assert.match(stream.headers.get('content-type'), /^text\/event-stream/);
    const events = await stream.text();
    assert.match(events, /"finish_reason":"stop"/);
    assert.ok(events.endsWith('data: [DONE]\n\n'));
    assert.equal((await fs.readdir(path.join(directory, 'cjk'))).length, 6);
    const meta = await fs.readFile(path.join(directory, 'cjk/001.meta.json'), 'utf8');
    assert.ok(!meta.includes('synthetic-only'));
    assert.equal((await fetch(`${recorder.url}/cases/undeclared/chat/completions`, { method: 'POST', body: '{}' })).status, 404);
    assert.equal((await fetch(`${recorder.url}/cases/cjk/chat/completions`, { method: 'POST', body: 'broken' })).status, 400);
    assert.deepEqual((await (await fetch(`${recorder.url}/health`)).json()).counts, { cjk: 2 });
    assert.equal((await fetch(`${recorder.url}/chat/completions`, { method: 'POST', body: '{}' })).status, 404);
    const selected = await fetch(`${recorder.url}/active-case`, { method: 'POST', body: '{"id":"cjk"}' });
    assert.equal((await selected.json()).activeId, 'cjk');
    const selectedCall = await fetch(`${recorder.url}/chat/completions`, { method: 'POST', body: '{}' });
    assert.equal(selectedCall.status, 200);
    await selectedCall.text();
    assert.equal(recorder.counts.get('cjk'), 3);
  } finally {
    await recorder.close();
    await fs.rm(directory, { recursive: true, force: true });
  }
});

test('strict comparator does not hide JSON-equivalent serialization differences', () => {
  const equal = compareRequests('{"x":"鲸🐋"}', '{"x":"鲸🐋"}');
  assert.equal(equal.rawEqual, true);
  const numeric = compareRequests('{"x":1}', '{"x":1.0}');
  assert.equal(numeric.rawEqual, false);
  assert.equal(numeric.semanticEqual, true);
  const text = compareRequests('{"x":"a\\r\\nb"}', '{"x":"a\\nb"}');
  assert.equal(text.rawEqual, false);
  assert.equal(text.semanticEqual, false);
  assert.equal(text.differences[0].pointer, '/x');
  const absent = compareRequests('{"stop":[]}', '{}');
  assert.equal(absent.semanticEqual, false);
  assert.equal(absent.differences[0].expectedPresent, true);
});

test('compact replies keep failed byte verdicts and bound Unicode diagnostics below 18KB', () => {
  const comparison = compareRequests(JSON.stringify({ x: '鲸🐋'.repeat(10000) }), JSON.stringify({ x: 'other' }));
  const report = { complete: false, expectedCount: 20, passed: 0, failed: 20,
    cases: Array.from({ length: 20 }, (_, index) => ({ id: `case-${index}`, status: 'different', ...comparison })) };
  const compact = compactComparisonReport(report);
  assert.ok(Buffer.byteLength(JSON.stringify(compact), 'utf8') <= 18000);
  assert.equal(compact.passed, 0);
  assert.equal(compact.failed, 20);
  assert.equal(compact.complete, false);
  assert.equal(compact.cases.length, 20);
  for (const result of compact.cases) {
    assert.equal(result.rawEqual, false);
    assert.equal(result.firstByteDifference, comparison.firstByteDifference);
    assert.equal(result.differences[0].pointer, '/x');
  }
  assert.equal(report.cases[0].differences[0].expected.length, 30000);
});

test('a write collision never counts as a captured request and retries retain their real attempt number', async () => {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'dsh-st-write-failure-'));
  await fs.mkdir(path.join(directory, 'one'));
  const old = path.join(directory, 'one/001.request.raw.json');
  await fs.writeFile(old, '{"old":true}');
  const recorder = await createRecorder({ outputDirectory: directory, fixtures: [{ id: 'one' }], port: 0, log: () => {} });
  try {
    const send = () => fetch(`${recorder.url}/cases/one/chat/completions`, { method: 'POST', body: '{"messages":[]}' });
    const failed = await send();
    assert.equal(failed.status, 500);
    await failed.text();
    let health = await (await fetch(`${recorder.url}/health`)).json();
    assert.deepEqual(health.counts, {});
    assert.deepEqual(health.attempts, { one: 1 });
    assert.equal(await fs.readFile(old, 'utf8'), '{"old":true}');
    const retried = await send();
    assert.equal(retried.status, 200);
    await retried.text();
    health = await (await fetch(`${recorder.url}/health`)).json();
    assert.deepEqual(health.counts, { one: 1 });
    assert.deepEqual(health.attempts, { one: 2 });
    assert.equal((JSON.parse(await fs.readFile(path.join(directory, 'one/002.meta.json'), 'utf8'))).attempt, 2);
  } finally {
    await recorder.close();
    await fs.rm(directory, { recursive: true, force: true });
  }
});

test('suite requires every declared recording and fails absent or merely equivalent bytes', async () => {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'dsh-st-compare-'));
  try {
    const fixtures = [{ id: 'first' }, { id: 'second' }];
    const expected = path.join(directory, 'st'), actual = path.join(directory, 'dart');
    const save = async (root, id, body) => {
      const target = path.join(root, id);
      await fs.mkdir(target, { recursive: true });
      await fs.writeFile(path.join(target, '001.request.raw.json'), body);
    };
    await save(expected, 'first', '{"temperature":1}');
    await save(actual, 'first', '{"temperature":1}');
    let result = await compareRecordingSets(fixtures, expected, actual);
    assert.equal(result.complete, false);
    assert.equal(result.passed, 1);
    assert.equal(result.cases[1].status, 'missing-or-unreadable');
    await save(expected, 'second', '{"temperature":1}');
    await save(actual, 'second', '{"temperature":1.0}');
    result = await compareRecordingSets(fixtures, expected, actual);
    assert.equal(result.complete, false);
    assert.equal(result.cases[1].semanticEqual, true);
    await save(actual, 'second', '{"temperature":1}');
    result = await compareRecordingSets(fixtures, expected, actual);
    assert.equal(result.complete, true);
    assert.equal(result.passed, 2);
    await assert.rejects(compareRecordingSets([], expected, actual));
  } finally {
    await fs.rm(directory, { recursive: true, force: true });
  }
});

// Local synthetic-fixture recorder. No provider calls or external dependencies.
import http from 'node:http';
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const expectedStCommit = '7e8663cd9c184a550b37238218bdd32c6efc68e9';
const fixtureId = /^[a-z0-9][a-z0-9_-]{0,63}$/;

export async function createRecorder({ outputDirectory, fixtures = [], port = 19091, log = console.log }) {
  const byId = new Map(fixtures.map(fixture => [fixture.id, fixture]));
  if (byId.size !== fixtures.length || fixtures.some(fixture => typeof fixture.id !== 'string' || !fixtureId.test(fixture.id))) {
    throw new Error('Fixture ids must be unique safe leaf names.');
  }
  await fs.mkdir(outputDirectory, { recursive: true });
  const counts = new Map();
  const attempts = new Map();
  let activeId = null;
  const pending = new Set();
  const server = http.createServer((request, response) => {
    const operation = handle(request, response).catch(error => {
      log(`RECORDER_ERROR ${error.message}`);
      if (!response.headersSent) reply(response, 500, { error: 'Recorder failed; inspect its console.' });
      else response.destroy();
    });
    pending.add(operation);
    operation.finally(() => pending.delete(operation));
  });
  function reply(response, status, value) {
    response.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8', 'Access-Control-Allow-Origin': '*' });
    response.end(JSON.stringify(value));
  }
  async function handle(request, response) {
    response.setHeader('Access-Control-Allow-Origin', '*');
    if (request.method === 'OPTIONS') {
      response.writeHead(204, { 'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
        'Access-Control-Allow-Headers': 'Content-Type, Authorization' });
      response.end();
      return;
    }
    // Node gives an origin-form request-target. ST's native DeepSeek backend
    // sends //chat/completions after normalizing its proxy root with new URL.
    // Keep both slashes in the path instead of treating them as an authority.
    const url = new URL(`http://127.0.0.1${request.url}`);
    if (request.method === 'GET' && url.pathname === '/health') {
      reply(response, 200, { recorder: 'dsh-tavern', expectedStCommit, fixtureCount: byId.size, activeId,
        counts: Object.fromEntries(counts), attempts: Object.fromEntries(attempts) });
      return;
    }
    if (request.method === 'GET' && url.pathname === '/fixtures') {
      reply(response, 200, fixtures);
      return;
    }
    if (request.method === 'GET' && url.pathname === '/browser-driver.mjs') {
      const source = await fs.readFile(new URL('./browser-driver.mjs', import.meta.url));
      response.writeHead(200, { 'Content-Type': 'text/javascript; charset=utf-8', 'Cache-Control': 'no-store' });
      response.end(source);
      return;
    }
    if (request.method === 'GET' && /\/models\/?$/.test(url.pathname)) {
      reply(response, 200, { object: 'list', data: [{ id: 'deepseek-flash', object: 'model', owned_by: 'fixture' }] });
      return;
    }
    const match = /^\/cases\/([a-z0-9][a-z0-9_-]{0,63})(?:\/beta)?\/+chat\/completions\/?$/.exec(url.pathname);
    const selectedId = match?.[1] ?? (/^\/(?:beta\/)?\/?chat\/completions\/?$/.test(url.pathname) ? activeId : null);
    const selection = url.pathname === '/active-case';
    if (request.method !== 'POST' || (!selection && !byId.has(selectedId))) {
      reply(response, 404, { error: 'Use a declared /cases/<id>/chat/completions fixture route.' });
      return;
    }
    const chunks = [];
    let length = 0;
    for await (const chunk of request) {
      length += chunk.length;
      if (length > 32 * 1024 * 1024) {
        reply(response, 413, { error: 'Synthetic fixture request exceeds 32 MiB.' });
        return;
      }
      chunks.push(chunk);
    }
    const raw = Buffer.concat(chunks);
    let body;
    try {
      body = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(raw));
      if (!body || typeof body !== 'object' || Array.isArray(body)) throw new Error('Expected object');
    } catch {
      reply(response, 400, { error: 'Expected a UTF-8 JSON object.' });
      return;
    }
    if (selection) {
      if (!byId.has(body.id)) { reply(response, 400, { error: 'Unknown fixture id.' }); return; }
      activeId = body.id;
      reply(response, 200, { activeId });
      return;
    }
    const id = selectedId;
    const attempt = (attempts.get(id) ?? 0) + 1;
    attempts.set(id, attempt);
    const directory = path.join(outputDirectory, id);
    await fs.mkdir(directory, { recursive: true });
    const prefix = path.join(directory, String(attempt).padStart(3, '0'));
    // Refuse to overwrite an earlier capture. Start a new output directory for a rerun.
    await fs.writeFile(`${prefix}.request.raw.json`, raw, { flag: 'wx' });
    await fs.writeFile(`${prefix}.request.json`, JSON.stringify(body, null, 2) + '\n', { flag: 'wx' });
    await fs.writeFile(`${prefix}.meta.json`, JSON.stringify({ fixture: id, attempt,
      capturedAt: new Date().toISOString(), path: url.pathname, byteLength: raw.length,
      nodeVersion: process.version, expectedStCommit }, null, 2) + '\n', { flag: 'wx' });
    counts.set(id, (counts.get(id) ?? 0) + 1);
    // Authorization and all other headers are intentionally outside the recording contract.
    log(`RECORDED ${id} #${attempt} ${raw.length} bytes`);
    const model = typeof body.model === 'string' ? body.model : 'fixture';
    if (body.stream === true) {
      response.writeHead(200, { 'Content-Type': 'text/event-stream; charset=utf-8', 'Cache-Control': 'no-cache' });
      const chunk = (delta, finish_reason, usage) => ({ id: 'fixture-response', object: 'chat.completion.chunk', model,
        choices: [{ index: 0, delta, finish_reason }], ...(usage ? { usage } : {}) });
      response.write(`data: ${JSON.stringify(chunk({ role: 'assistant', content: 'RECORDER_OK' }, null))}\n\n`);
      response.write(`data: ${JSON.stringify(chunk({}, 'stop', usage()))}\n\n`);
      response.end('data: [DONE]\n\n');
    } else {
      reply(response, 200, { id: 'fixture-response', object: 'chat.completion', model,
        choices: [{ index: 0, message: { role: 'assistant', content: 'RECORDER_OK' }, finish_reason: 'stop' }],
        usage: usage() });
    }
  }
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(port, '127.0.0.1', resolve);
  });
  const address = server.address();
  const url = `http://127.0.0.1:${address.port}`;
  log(`LISTENING ${url}`);
  return { url, counts, async close() {
    const closed = new Promise((resolve, reject) => server.close(error => error ? reject(error) : resolve()));
    server.closeIdleConnections();
    await Promise.allSettled([...pending]);
    await closed;
  } };
}

function usage() {
  // Synthetic completion metadata, never an assertion about provider tokenization.
  return { prompt_tokens: 0, completion_tokens: 0, total_tokens: 0, prompt_cache_hit_tokens: 0 };
}

if (process.argv[1] && fileURLToPath(import.meta.url) === path.resolve(process.argv[1])) {
  const args = process.argv.slice(2);
  const argument = (name, fallback) => {
    const index = args.indexOf(name);
    if (index < 0) return fallback;
    if (!args[index + 1] || args[index + 1].startsWith('--')) throw new Error(`Missing ${name} value`);
    return args[index + 1];
  };
  const fixtureFile = argument('--fixtures', path.resolve(path.dirname(fileURLToPath(import.meta.url)),
    '../../test/fixtures/st-differential.json'));
  const outputDirectory = argument('--out', path.resolve('tmp', `st-recordings-${Date.now()}`));
  const fixtures = JSON.parse(await fs.readFile(fixtureFile, 'utf8'));
  const recorder = await createRecorder({ outputDirectory, fixtures,
    port: Number(argument('--port', '19091')) });
  console.log(`OUTPUT ${path.resolve(outputDirectory)}`);
  process.once('SIGINT', () => { void recorder.close().then(() => process.exit(0)); });
  process.once('SIGTERM', () => { void recorder.close().then(() => process.exit(0)); });
}

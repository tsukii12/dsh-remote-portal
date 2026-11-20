// Writes webcrypto_vectors.json: hosted-link blobs made by WebCrypto (node's
// crypto.subtle, the same API the web viewer decrypts with), for
// hosted_crypto_test.dart to match byte for byte.
//
//   node app/test/share_hosted/fixtures/make_vectors.mjs

import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { gzipSync } from 'node:zlib';

const here = dirname(fileURLToPath(import.meta.url));
const b64 = (b) => Buffer.from(b).toString('base64');
const b64url = (b) => b64(b).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');

// Fixed inputs, so the file is stable; the key and IV are test-only.
const seed = (n, mul) => Uint8Array.from({ length: n }, (_, i) => (i * mul + 7) & 0xff);
const fixture = join(here, '../../replay/fixtures/timeline.json');
let conversation;
try {
  conversation = JSON.parse(readFileSync(fixture, 'utf8')).file;
} catch {
  conversation = '{"dshgo":2,"kind":"conversation","name":"示例","code":"x"}';
}
const texts = [
  { name: 'empty', text: '' },
  { name: 'short', text: '{"dshgo":2,"kind":"conversation","name":"你好 👋"}' },
  { name: 'conversation', text: conversation },
];

const vectors = [];
for (const [i, { name, text }] of texts.entries()) {
  const rawKey = seed(32, 13 + i);
  const iv = seed(12, 29 + i);
  const plain = gzipSync(Buffer.from(text, 'utf8'));
  const key = await crypto.subtle.importKey('raw', rawKey, { name: 'AES-GCM' }, false, ['encrypt']);
  const ct = new Uint8Array(await crypto.subtle.encrypt({ name: 'AES-GCM', iv }, key, plain));
  const blob = Buffer.concat([Buffer.from('DSG1'), Buffer.from(iv), Buffer.from(ct)]);
  vectors.push({ name, key: b64url(rawKey), iv: b64(iv), text, gzip: b64(plain), blob: b64(blob) });
}
writeFileSync(join(here, 'webcrypto_vectors.json'), JSON.stringify({ generator: 'node ' + process.version + ' crypto.subtle', vectors }, null, 1) + '\n');
console.log(`wrote ${vectors.length} vectors`);

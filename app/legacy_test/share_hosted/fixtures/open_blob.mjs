// Opens a hosted-link blob the app sealed, the way a browser does: WebCrypto
// AES-GCM, then DecompressionStream('gzip'). With site/share/viewer.js present,
// also through its own decryptHosted. Prints the file text as JSON.
//
//   node open_blob.mjs <blob-file> <base64url-key>

import { existsSync, readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const [blobPath, keyText] = process.argv.slice(2);
const bytes = new Uint8Array(readFileSync(blobPath));
const raw = Buffer.from(keyText.replace(/-/g, '+').replace(/_/g, '/'), 'base64');
if (String.fromCharCode(...bytes.slice(0, 4)) !== 'DSG1') throw new Error('magic');
const key = await crypto.subtle.importKey('raw', raw, { name: 'AES-GCM' }, false, ['decrypt']);
const plain = await crypto.subtle.decrypt({ name: 'AES-GCM', iv: bytes.slice(4, 16) }, key, bytes.slice(16));
const text = await new Response(new Blob([plain]).stream().pipeThrough(new DecompressionStream('gzip'))).text();

let viewer = null;
const viewerJs = join(dirname(fileURLToPath(import.meta.url)), '../../../../site/share/viewer.js');
if (existsSync(viewerJs)) {
  await import(viewerJs);
  if (globalThis.DshgoViewer?.decryptHosted) viewer = await globalThis.DshgoViewer.decryptHosted(bytes.buffer, keyText);
}
process.stdout.write(JSON.stringify({ text, viewer }));

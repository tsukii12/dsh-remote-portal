import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export function compareRequests(expected, actual) {
  expected = Buffer.from(expected);
  actual = Buffer.from(actual);
  let firstByteDifference = -1;
  const length = Math.min(expected.length, actual.length);
  for (let index = 0; index < length; index++) {
    if (expected[index] !== actual[index]) { firstByteDifference = index; break; }
  }
  if (firstByteDifference < 0 && expected.length !== actual.length) firstByteDifference = length;
  const differences = [];
  const decoder = new TextDecoder('utf-8', { fatal: true });
  visit(JSON.parse(decoder.decode(expected)), JSON.parse(decoder.decode(actual)), '');
  function visit(left, right, pointer) {
    if (differences.length >= 20 || Object.is(left, right)) return;
    const leftArray = Array.isArray(left), rightArray = Array.isArray(right);
    if (left === null || right === null || typeof left !== 'object' || typeof right !== 'object'
        || leftArray !== rightArray) {
      differences.push({ pointer: pointer || '/', expected: left, actual: right });
      return;
    }
    if (leftArray && left.length !== right.length) {
      differences.push({ pointer: `${pointer}/length`, expected: left.length, actual: right.length });
    }
    const keys = [...new Set([...Object.keys(left), ...Object.keys(right)])];
    for (const key of keys) {
      const next = `${pointer}/${key.replaceAll('~', '~0').replaceAll('/', '~1')}`;
      if (!Object.hasOwn(left, key) || !Object.hasOwn(right, key)) {
        differences.push({ pointer: next, expectedPresent: Object.hasOwn(left, key), actualPresent: Object.hasOwn(right, key) });
      } else visit(left[key], right[key], next);
      if (differences.length >= 20) break;
    }
  }
  return { rawEqual: firstByteDifference < 0, semanticEqual: differences.length === 0,
    expectedBytes: expected.length, actualBytes: actual.length, firstByteDifference, differences };
}

if (process.argv[1] && fileURLToPath(import.meta.url) === path.resolve(process.argv[1])) {
  const [expectedFile, actualFile] = process.argv.slice(2);
  if (!expectedFile || !actualFile) throw new Error('Usage: node compare.mjs ST.request.raw.json Dart.request.raw.json');
  const report = compareRequests(await fs.readFile(expectedFile), await fs.readFile(actualFile));
  console.log(JSON.stringify(report, null, 2));
  // Even JSON-equivalent formatting differences fail strict byte acceptance.
  process.exitCode = report.rawEqual ? 0 : 1;
}

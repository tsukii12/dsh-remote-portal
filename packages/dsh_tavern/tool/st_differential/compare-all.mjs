import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { compareRequests } from './compare.mjs';

export async function compareRecordingSets(fixtures, expectedDirectory, actualDirectory) {
  const ids = fixtures.map(fixture => fixture.id);
  if (!ids.length || new Set(ids).size !== ids.length || ids.some(id => !/^[a-z0-9][a-z0-9_-]{0,63}$/.test(id))) {
    throw new Error('Expected a nonempty set of unique declared fixture ids.');
  }
  const cases = [];
  for (const id of ids) {
    const relative = path.join(id, '001.request.raw.json');
    const files = [path.join(expectedDirectory, relative), path.join(actualDirectory, relative)];
    const reads = await Promise.allSettled(files.map(file => fs.readFile(file)));
    if (reads.some(result => result.status !== 'fulfilled')) {
      cases.push({ id, status: 'missing-or-unreadable', expectedReadable: reads[0].status === 'fulfilled',
        actualReadable: reads[1].status === 'fulfilled' });
      continue;
    }
    try {
      const comparison = compareRequests(reads[0].value, reads[1].value);
      cases.push({ id, status: comparison.rawEqual ? 'equal' : 'different', ...comparison });
    } catch (error) {
      cases.push({ id, status: 'invalid-json', error: String(error) });
    }
  }
  const passed = cases.filter(result => result.status === 'equal').length;
  return { complete: passed === fixtures.length, expectedCount: fixtures.length, passed,
    failed: fixtures.length - passed, cases };
}

// Verification runs stay on the owner's machine. Bound the text reply without
// weakening the full-byte verdict or modifying either recording.
export function compactComparisonReport(report) {
  let valueLimit = 80;
  const shortened = value => {
    const text = JSON.stringify(value);
    if (text === undefined) return undefined;
    return text.length > valueLimit ? `${text.slice(0, valueLimit)}…` : text;
  };
  const make = () => ({ complete: report.complete, expectedCount: report.expectedCount,
    passed: report.passed, failed: report.failed, diagnosticValuesAreExcerpts: true,
    cases: report.cases.map(result => ({ id: result.id, status: result.status,
      rawEqual: result.rawEqual, semanticEqual: result.semanticEqual,
      expectedBytes: result.expectedBytes, actualBytes: result.actualBytes,
      firstByteDifference: result.firstByteDifference,
      expectedReadable: result.expectedReadable, actualReadable: result.actualReadable,
      error: result.error?.slice(0, 160),
      differences: result.differences?.slice(0, 2).map(difference => ({
        pointer: difference.pointer.slice(0, 160), expectedPresent: difference.expectedPresent,
        actualPresent: difference.actualPresent,
        ...(valueLimit ? { expected: shortened(difference.expected), actual: shortened(difference.actual) } : {}),
      })),
    })),
  });
  let summary = make();
  while (Buffer.byteLength(JSON.stringify(summary), 'utf8') > 18000 && valueLimit > 0) {
    valueLimit = Math.floor(valueLimit / 2);
    summary = make();
  }
  if (Buffer.byteLength(JSON.stringify(summary), 'utf8') > 18000) {
    throw new Error('Compact report exceeds 18KB; retain the full report locally and return counts only.');
  }
  return summary;
}

if (process.argv[1] && fileURLToPath(import.meta.url) === path.resolve(process.argv[1])) {
  const args = process.argv.slice(2);
  const compact = args.includes('--compact');
  const positional = args.filter(argument => argument !== '--compact');
  const [expectedDirectory, actualDirectory, fixtureArgument] = positional;
  if (!expectedDirectory || !actualDirectory || positional.length > 3) {
    throw new Error('Usage: node compare-all.mjs <ST-recording-directory> <Dart-recording-directory> [fixtures.json] [--compact]');
  }
  const fixtureFile = fixtureArgument ?? new URL('../../test/fixtures/st-differential.json', import.meta.url);
  const fixtures = JSON.parse(await fs.readFile(fixtureFile, 'utf8'));
  const report = await compareRecordingSets(fixtures, expectedDirectory, actualDirectory);
  console.log(compact ? JSON.stringify(compactComparisonReport(report)) : JSON.stringify(report, null, 2));
  process.exitCode = report.complete ? 0 : 1;
}

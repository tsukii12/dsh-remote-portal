import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/diagnostics/diagnostics_bundle.dart';
import 'package:dsh_app/diagnostics/diagnostics_export.dart';
import 'package:dsh_app/diagnostics/redact.dart';
import 'package:dsh_app/runtime/runtime_bridge.dart';
import 'package:dsh_app/state/artifacts.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/zip_reader.dart';

const _begin = '-----BEGIN OPENSSH PRIVATE KEY-----';
const _end = '-----END OPENSSH PRIVATE KEY-----';
const _body = ['SYNTHETIC-PRIVATE-MATERIAL-FIRST', 'SYNTHETIC-PRIVATE-MATERIAL-LAST'];
const _complete = [_begin, ..._body, _end];

void main() {
  test('a complete block in one string is masked with surrounding text retained', () {
    final text = redactDiagnostics(['before', ..._complete, 'after'].join('\n'));
    expect(text, 'before\n$_begin\n$redactionMark\n$_end\nafter');
    for (final secret in _body) {
      expect(text, isNot(contains(secret)));
    }
  });

  test('ordinary, empty, and blank log lines keep their existing contents', () {
    expect(redactLines(const []), isEmpty);
    expect(redactLines(const ['']), ['']);
    expect(redactLines(const ['before', '', 'token=synthetic-token', 'after']), [
      'before',
      '',
      'token=$redactionMark',
      'after',
    ]);
  });

  test('line-list masking retains the private-key context across body lines', () {
    final lines = redactLines(['before', ..._complete, 'after']);
    for (final secret in _body) {
      expect(lines.join('\n'), isNot(contains(secret)));
    }
    expect(lines, ['before', _begin, redactionMark, _end, 'after']);
  });

  test('an unterminated private-key block does not preserve its last secret line', () {
    final text = redactDiagnostics([_begin, ..._body].join('\n'));
    for (final secret in _body) {
      expect(text, isNot(contains(secret)));
    }
    expect(text, '$_begin\n$redactionMark');
  });

  for (final complete in [true, false]) {
    test('the real exported ZIP masks ${complete ? 'complete' : 'unterminated'} log blocks', () async {
      final root = await Directory.systemTemp.createTemp('dsh-diagnostics-pem-');
      addTearDown(() => root.delete(recursive: true));
      final block = [_begin, ..._body, if (complete) _end];
      final at = DateTime(2026, 11, 3, 13);
      final exporter = DiagnosticsExporter(
        collect: (_) async => DiagnosticsSnapshot(
          at: at,
          status: RuntimeStatus(phase: RuntimePhase.error, error: complete ? 'ordinary failure' : block.join('\n')),
          settings: const AppSettings(),
          engineLog: ['engine-before', ...block, if (complete) 'engine-after'],
          failureLog: ['failure-before', ...block, if (complete) 'failure-after'],
        ),
        files: const FilesChannel(),
        cacheRoot: () async => root,
        clock: () => at,
      );

      final file = await exporter.build();
      expect(file.existsSync(), isTrue);
      final entries = {for (final entry in readZip(await file.readAsBytes())) entry.name: utf8.decode(entry.data)};
      expect(entries.keys, containsAll(['engine.log', 'failure.log', 'summary.json']));
      for (final name in ['engine.log', 'failure.log', 'summary.json']) {
        for (final secret in _body) {
          expect(entries[name], isNot(contains(secret)), reason: name);
        }
      }
      expect(entries['engine.log'], contains('engine-before'));
      expect(entries['failure.log'], contains('failure-before'));
      if (complete) {
        expect(entries['engine.log'], contains('engine-after'));
        expect(entries['failure.log'], contains('failure-after'));
      }
    });
  }
}

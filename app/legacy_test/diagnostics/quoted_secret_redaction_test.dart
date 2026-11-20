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

void main() {
  const values = ['synthetic phrase, with; punctuation&tail', 'synthetic"quoted"tail', r'synthetic\path with tail'];

  for (var i = 0; i < values.length; i++) {
    test('a complete JSON password is masked and JSON remains valid ($i)', () {
      final input = jsonEncode({'password': values[i], 'attempt': 2});
      final output = redactDiagnostics(input);
      expect(jsonDecode(output), {'password': redactionMark, 'attempt': 2});
      expect(redactDiagnostics(output), output);
    });
  }

  test('a single-quoted passphrase is masked through its closing quote', () {
    const input = "passphrase='synthetic phrase, with; punctuation&tail'; attempt=2";
    expect(redactDiagnostics(input), "passphrase='$redactionMark'; attempt=2");
  });

  test('unquoted credentials, already masked headers, and plain facts keep their contract', () {
    expect(redactDiagnostics('password=ordinary-value attempt=2'), 'password=$redactionMark attempt=2');
    expect(redactDiagnostics('Authorization: Bearer synthetic-token'), 'Authorization: Bearer $redactionMark');
    expect(redactDiagnostics('Authorization: "Bearer $redactionMark"'), 'Authorization: "Bearer $redactionMark"');
    expect(redactDiagnostics('authorization: \'Basic $redactionMark\''), 'authorization: \'Basic $redactionMark\'');
    expect(redactDiagnostics('max_tokens=8192 ready=true'), 'max_tokens=8192 ready=true');
  });

  test('the real exported ZIP does not retain the tail of a quoted credential', () async {
    final root = await Directory.systemTemp.createTemp('dsh-quoted-secret-');
    addTearDown(() => root.delete(recursive: true));
    final line = jsonEncode({'password': values.first, 'attempt': 2});
    final at = DateTime(2026, 11, 3, 14);
    final exporter = DiagnosticsExporter(
      collect: (_) async => DiagnosticsSnapshot(
        at: at,
        status: RuntimeStatus(phase: RuntimePhase.error, error: line),
        settings: const AppSettings(),
        engineLog: [line],
        failureLog: [line],
      ),
      files: const FilesChannel(),
      cacheRoot: () async => root,
      clock: () => at,
    );
    final file = await exporter.build();
    final entries = {for (final e in readZip(await file.readAsBytes())) e.name: utf8.decode(e.data)};
    for (final name in ['engine.log', 'failure.log']) {
      expect(jsonDecode(entries[name]!), {'password': redactionMark, 'attempt': 2}, reason: name);
    }
    final summary = jsonDecode(entries['summary.json']!) as Map<String, dynamic>;
    final error = (summary['runtime'] as Map<String, dynamic>)['error'] as String;
    expect(jsonDecode(error), {'password': redactionMark, 'attempt': 2});
  });
}

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

void _expectValidOutput(String input, String expected) {
  final output = redactDiagnostics(input);
  expect(output, expected);
  expect(utf8.decode(utf8.encode(output)), output);
  for (final line in output.split('\n')) {
    expect(line.length, lessThanOrEqualTo(maxLineLength + 1));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('keeps a complete pair that fits exactly at the line budget', () {
    final input = '${'A' * (maxLineLength - 2)}😀';
    _expectValidOutput(input, input);
  });

  test('omits an entire scalar when its pair crosses the line budget', () {
    final prefix = 'A' * (maxLineLength - 1);
    for (final scalar in [0x10000, 0x1f600, 0x10ffff]) {
      final character = String.fromCharCode(scalar);
      expect(character.length, 2);
      _expectValidOutput('$prefix${character}tail', '$prefix…');
    }
  });

  test('keeps the full prefix when a pair begins after the budget', () {
    final prefix = 'A' * maxLineLength;
    _expectValidOutput('$prefix😀', '$prefix…');
  });

  test('keeps the existing ASCII and BMP budget and extra ellipsis', () {
    for (final character in ['A', '界']) {
      _expectValidOutput(character * (maxLineLength + 1), '${character * maxLineLength}…');
    }
  });

  test('applies scalar-safe truncation independently to each line', () {
    final prefix = 'A' * (maxLineLength - 1);
    _expectValidOutput('$prefix😀\nready\n${'界' * (maxLineLength + 1)}', '$prefix…\nready\n${'界' * maxLineLength}…');
  });

  test('the boundary is measured after existing ANSI stripping', () {
    final prefix = 'A' * (maxLineLength - 1);
    _expectValidOutput('\x1b[31m$prefix😀\x1b[0m', '$prefix…');
  });

  test('nested diagnostic string values keep complete scalars', () {
    final prefix = 'A' * (maxLineLength - 1);
    final output = redactJson({
      'error': '$prefix😀',
      'nested': [
        {'note': '$prefix😀'},
        7,
        true,
      ],
    });
    expect(output, {
      'error': '$prefix…',
      'nested': [
        {'note': '$prefix…'},
        7,
        true,
      ],
    });
    expect(jsonDecode(utf8.decode(utf8.encode(jsonEncode(output)))), output);
  });

  test('a real exported ZIP keeps logs and summary free of split pairs', () async {
    final cache = await Directory.systemTemp.createTemp('dsh-surrogate-diagnostics-');
    addTearDown(() => cache.delete(recursive: true));
    final prefix = 'A' * (maxLineLength - 1);
    final line = '$prefix😀';
    final at = DateTime.utc(2026, 11, 3, 21, 50);
    final exporter = DiagnosticsExporter(
      collect: (_) async => DiagnosticsSnapshot(
        at: at,
        status: RuntimeStatus(phase: RuntimePhase.error, error: line),
        settings: const AppSettings(),
        engineLog: [line, 'ready'],
        failureLog: [line],
      ),
      files: const FilesChannel(),
      cacheRoot: () async => cache,
      clock: () => at,
    );
    final file = await exporter.build();
    final entries = {for (final e in readZip(await file.readAsBytes())) e.name: utf8.decode(e.data)};
    expect(entries['engine.log'], '$prefix…\nready\n');
    expect(entries['failure.log'], '$prefix…\n');
    final summary = jsonDecode(entries['summary.json']!) as Map<String, dynamic>;
    expect((summary['runtime'] as Map<String, dynamic>)['error'], '$prefix…');
  });
}

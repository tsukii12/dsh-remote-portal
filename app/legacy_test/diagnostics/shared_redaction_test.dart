import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/diagnostics/redact.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final text = File('../tooling/fixtures/diagnostic-redaction.json').readAsStringSync();
  final data = jsonDecode(text) as Map<String, dynamic>;
  for (final item in data['cases'] as List<dynamic>) {
    final entry = item as Map<String, dynamic>;
    test('shared redaction: ${entry['name']}', () {
      final input = (entry['inputParts'] as List<dynamic>).cast<String>().join();
      final expected = (entry['expectedParts'] as List<dynamic>).cast<String>().join();
      expect(redactDiagnostics(input), expected);
      expect(redactDiagnostics(expected), expected);
    });
  }
}

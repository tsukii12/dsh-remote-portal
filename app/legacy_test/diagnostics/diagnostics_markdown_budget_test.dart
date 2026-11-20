import 'dart:convert';

import 'package:dsh_app/diagnostics/diagnostics_bundle.dart';
import 'package:dsh_app/diagnostics/diagnostics_channel.dart';
import 'package:dsh_app/diagnostics/diagnostics_markdown.dart';
import 'package:dsh_app/diagnostics/diagnostics_publish.dart';
import 'package:dsh_app/runtime/runtime_bridge.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _notice = '\n…（诊断文件过长，已截断；完整内容用 设置 → 诊断 的导出包）\n';

DiagnosticsSnapshot _snapshot({List<String> engineLog = const []}) => DiagnosticsSnapshot(
  at: DateTime(2026, 11, 3, 12),
  status: const RuntimeStatus(phase: RuntimePhase.running, abi: 'arm64-v8a'),
  settings: const AppSettings(),
  native: const NativeDiagnostics(device: {'model': 'budget-test', 'android': '16'}),
  engineLog: engineLog,
  appErrors: const [],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a report that fits its exact UTF-8 budget remains unchanged and redacted', () {
    final snapshot = _snapshot(engineLog: ['中文 😀 token=synthetic-budget-secret']);
    final full = diagnosticsMarkdown(snapshot, maxBytes: 1000000);
    expect(full, contains('中文 😀'));
    expect(full, isNot(contains('synthetic-budget-secret')));
    expect(diagnosticsMarkdown(snapshot, maxBytes: utf8.encode(full).length), full);
    expect(() => diagnosticsMarkdown(snapshot, maxBytes: -1), throwsRangeError);
  });

  test('the default byte cap also bounds a CJK report below the code-unit cap', () {
    final snapshot = _snapshot(engineLog: List.generate(8, (_) => '汉' * 1000));
    final full = diagnosticsMarkdown(snapshot, maxBytes: 1000000);
    expect(full.length, lessThan(diagnosticsMarkdownBytes));
    expect(utf8.encode(full).length, greaterThan(diagnosticsMarkdownBytes));

    final text = diagnosticsMarkdown(snapshot);
    expect(utf8.encode(text).length, lessThanOrEqualTo(diagnosticsMarkdownBytes));
    expect(text, endsWith(_notice));
  });

  test('content and notice share the byte budget without splitting Unicode scalars', () {
    for (final (character, width) in [('汉', 3), ('😀', 4)]) {
      final snapshot = _snapshot(engineLog: ['BUDGET_LOG:${character * 500}']);
      final full = diagnosticsMarkdown(snapshot, maxBytes: 1000000);
      final prefix = full.substring(0, full.indexOf('BUDGET_LOG:') + 'BUDGET_LOG:'.length);
      for (var spare = 0; spare < width; spare++) {
        final budget = utf8.encode(prefix).length + 7 * width + spare + utf8.encode(_notice).length;
        final text = diagnosticsMarkdown(snapshot, maxBytes: budget);
        expect(text, '$prefix${character * 7}$_notice', reason: '$character with $spare spare bytes');
        expect(utf8.encode(text).length, lessThanOrEqualTo(budget));
        expect(utf8.decode(utf8.encode(text)), text);
      }
    }
  });

  test('small nonnegative budgets stay bounded and preserve complete characters', () {
    for (final budget in [0, 1, 2, 3, 4, 5, 6, 15, 16, 31, 100]) {
      final text = diagnosticsMarkdown(_snapshot(), maxBytes: budget);
      expect(utf8.encode(text).length, lessThanOrEqualTo(budget), reason: 'budget $budget');
      expect(utf8.decode(utf8.encode(text)), text);
    }
  });

  testWidgets('the actual publisher sends a byte-bounded report through the platform codec', (tester) async {
    final received = <String>[];
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(DiagnosticsPublisher.channel, (MethodCall call) async {
      expect(call.method, 'publishDiagnostics');
      final markdown = (call.arguments as Map<Object?, Object?>)['markdown'] as String;
      received.add(markdown);
      return {'bytes': utf8.encode(markdown).length, 'path': '/synthetic/diagnostics.md'};
    });
    addTearDown(() => messenger.setMockMethodCallHandler(DiagnosticsPublisher.channel, null));

    final result = await DiagnosticsPublisher(
      collect: (_) async => _snapshot(engineLog: List.generate(8, (_) => '汉' * 1000)),
    ).publish();
    final markdown = received.single;
    expect(utf8.encode(markdown).length, lessThanOrEqualTo(diagnosticsMarkdownBytes));
    expect(markdown, endsWith(_notice));
    expect(result?.bytes, utf8.encode(markdown).length);
  });
}

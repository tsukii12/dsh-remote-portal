import 'dart:convert';

import 'package:dsh_app/diagnostics/app_error_log.dart';
import 'package:dsh_app/diagnostics/diagnostics_bundle.dart';
import 'package:dsh_app/diagnostics/diagnostics_channel.dart';
import 'package:dsh_app/diagnostics/diagnostics_markdown.dart';
import 'package:dsh_app/diagnostics/diagnostics_publish.dart';
import 'package:dsh_app/diagnostics/diagnostics_sections.dart';
import 'package:dsh_app/runtime/runtime_bridge.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:flutter_test/flutter_test.dart';

DiagnosticsSnapshot snapshot({List<String> engine = const [], Map<String, Object?>? evidence}) => DiagnosticsSnapshot(
  at: DateTime.utc(2026, 11, 14, 8),
  status: const RuntimeStatus(phase: RuntimePhase.running, token: 'PRIVATE_LAUNCH', error: 'PRIVATE_MESSAGE'),
  settings: const AppSettings(apiKey: 'PRIVATE_KEY'),
  native: NativeDiagnostics(
    app: const {'versionName': '1.0.16', 'versionCode': 123, 'private': 'PRIVATE_APP'},
    device: const {'sdkInt': 36, 'model': 'V2405A', 'private': 'PRIVATE_DEVICE'},
    evidence:
        evidence ??
        {
          'availability': {'appErrors': 'available', 'voiceStages': 'available', 'processExits': 'unsupported'},
          'appErrors': [
            {
              'at': 123,
              'source': 'flutter',
              'errorType': 'StateError',
              'stack': 'package:dsh_app/speech/call/voice_call.dart:1:2',
              'message': 'PRIVATE_BODY',
            },
          ],
          'voiceStages': [
            {'at': 122, 'stage': 'playback_opening', 'backend': 'deepseek', 'audio': 'PRIVATE_AUDIO'},
          ],
          'processExits': [],
          'private': 'PRIVATE_EVIDENCE',
        },
  ),
  engineLog: engine,
  appErrors: [
    AppErrorRecord(
      at: DateTime.utc(2026),
      source: AppErrorSource.flutter,
      message: 'PRIVATE_MEMORY_BODY',
      stack: 'PRIVATE_STACK',
    ),
  ],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('automatic facts exclude all free-form content, logs, credentials and paths', () {
    final facts = diagnosticsAnalysisFacts(snapshot(engine: ['PRIVATE_ENGINE']));
    final text = jsonEncode(facts);
    expect(text, isNot(contains('PRIVATE_')));
    expect(facts['app'], {'versionName': '1.0.16', 'versionCode': 123});
    expect(text, contains('playback_opening'));
    expect(text, contains('package:dsh_app/speech/call/voice_call.dart:1:2'));
    expect((facts['evidence'] as Map)['availability'], containsPair('processExits', 'unsupported'));
  });

  test('all six tool sections are separately bounded valid JSON and preserve newest evidence', () {
    final location = 'package:dsh_app/${'a' * 105}.dart:1234567:1234567';
    final input = snapshot(
      engine: List.generate(2000, (i) => 'line $i ${'long log' * 100}'),
      evidence: {
        'availability': {'appErrors': 'available'},
        'appErrors': List.generate(
          40,
          (i) => {
            'at': i + 1,
            'source': 'flutter',
            'errorType': 'StateError',
            'stack': List.filled(6, location).join('\n'),
          },
        ),
      },
    );
    final sections = diagnosticsSections(input);
    expect(sections.keys.toSet(), {'summary', 'evidence', 'appErrors', 'voice', 'engine', 'failure'});
    for (final section in sections.values) {
      expect(utf8.encode(section).length, lessThanOrEqualTo(diagnosticsSectionBytes));
      expect(jsonDecode(section), isA<Map>());
    }
    final errors = jsonDecode(sections['appErrors']!) as Map;
    expect(errors['truncated'], true);
    expect((errors['appErrors'] as List).last, containsPair('at', 40));
    expect(jsonDecode(sections['engine']!)['truncated'], true);
  });

  test('persistent evidence appears before huge engine output and enters the export', () {
    final input = snapshot(engine: List.filled(80, 'x' * 1800));
    final markdown = diagnosticsMarkdown(input);
    expect(markdown.indexOf('playback_opening'), lessThan(markdown.indexOf('引擎日志')));
    final entry = DiagnosticsBundle.entries(input).singleWhere((entry) => entry.name == 'app-evidence.json');
    final text = utf8.decode(entry.bytes);
    expect(text, contains('StateError'));
    expect(text, isNot(contains('PRIVATE_')));
  });

  test('ordinary publication refreshes sections; manual IME publication cannot populate the tool cache', () async {
    final calls = <Map<Object?, Object?>>[];
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(DiagnosticsPublisher.channel, (call) async {
      calls.add(call.arguments as Map<Object?, Object?>);
      return {'bytes': 1};
    });
    addTearDown(() => messenger.setMockMethodCallHandler(DiagnosticsPublisher.channel, null));
    final publisher = DiagnosticsPublisher(collect: (_) async => snapshot());
    expect((await publisher.publish())?.manual, false);
    expect(calls.last['sections'], contains('evidence'));
    expect(calls.last['collectedAt'], '2026-11-14T08:00:00.000Z');
    expect((await publisher.publish(includeSystemIme: true))?.manual, true);
    expect(calls.last.containsKey('sections'), false);
    publisher.dispose();
  });
}

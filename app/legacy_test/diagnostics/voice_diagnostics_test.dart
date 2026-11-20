import 'dart:convert';

import 'package:dsh_app/diagnostics/diagnostics_bundle.dart';
import 'package:dsh_app/diagnostics/diagnostics_channel.dart';
import 'package:dsh_app/runtime/runtime_bridge.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/state/voice_settings.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/zip_reader.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('persistent evidence is bounded, content-free and distinguishes unavailable from empty', () {
    final raw = {
      'appErrors': [
        for (var i = 0; i < 60; i++)
          {
            'at': i,
            'source': 'flutter',
            'errorType': 'StateError',
            'stack': 'package:dsh_app/main.dart:1:2\nPRIVATE_TOKEN',
            'message': 'PRIVATE_CHAT',
          },
      ],
      'voiceStages': [
        {'at': 1, 'stage': 'failed', 'backend': 'cloud', 'code': 5, 'text': 'PRIVATE_CHAT', 'audio': 'PRIVATE_AUDIO'},
        {'at': 2, 'stage': 'PRIVATE_CHAT', 'backend': 'cloud'},
      ],
      'processExits': [
        for (var i = 0; i < 20; i++) {'at': i, 'reason': 6, 'trace': 'PRIVATE_TRACE', 'description': 'PRIVATE_CHAT'},
      ],
      'availability': {'appErrors': 'available', 'voiceStages': 'unavailable', 'processExits': 'unsupported'},
    };
    final facts = NativeDiagnostics.fromMap({'evidence': raw}).evidence;
    expect(facts['appErrors'], hasLength(40));
    expect((facts['appErrors'] as List).first['at'], 20);
    expect(facts['voiceStages'], hasLength(1));
    expect(facts['processExits'], hasLength(8));
    expect(jsonEncode(facts), isNot(contains('PRIVATE_')));
    expect(utf8.encode(jsonEncode(facts)).length, lessThanOrEqualTo(64 * 1024));
    final empty = diagnosticEvidenceFacts({
      'appErrors': [],
      'availability': {'appErrors': 'available'},
    });
    expect((empty['availability'] as Map)['appErrors'], 'available');
    expect((diagnosticEvidenceFacts(null)['availability'] as Map)['appErrors'], 'unavailable');
  });

  test('voice stage writes use the whitelist and failures leave the voice chain intact', () async {
    const method = MethodChannel('dsh/diagnostics/evidence-test');
    final calls = <MethodCall>[];
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(method, (call) async {
      calls.add(call);
      throw PlatformException(code: 'evidence_unavailable');
    });
    addTearDown(() => messenger.setMockMethodCallHandler(method, null));
    const channel = DiagnosticsChannel(method);
    await channel.recordVoiceStage('failed', backend: 'deepseek', code: 5);
    await channel.recordVoiceStage('PRIVATE_CHAT', backend: 'cloud');
    await channel.recordVoiceStage('recognized', backend: 'https://private');
    expect(calls, hasLength(1));
    expect(calls.single.method, 'recordVoiceStage');
    expect(calls.single.arguments, {'stage': 'failed', 'backend': 'deepseek', 'code': 5});
    messenger.setMockMethodCallHandler(method, (_) async => throw MissingPluginException());
    await channel.recordVoiceStage('playback_started', backend: 'system');
  });

  test('diagnostics retain bounded error facts and reject audio and transcript fields', () {
    final hostile = {
      'sdk': 35,
      'defaultService': 'vendor.voice/.Recognizer',
      'recognizerAvailable': true,
      'onDeviceFactoryApiAvailable': true,
      'onDeviceAvailable': false,
      'systemUnreliable': true,
      'text': 'PRIVATE_SPOKEN_WORDS',
      'audioBase64': 'PRIVATE_AUDIO_BYTES',
      'visibleServices': [for (var i = 0; i < 30; i++) 'vendor.voice/$i'],
      'recentFailures': [
        for (var i = 0; i < 30; i++)
          {
            'at': i,
            'code': 5,
            'name': 'CLIENT',
            'stage': 'listen',
            'partial': 'PRIVATE_SPOKEN_WORDS',
            'wav': 'PRIVATE_AUDIO_BYTES',
            'exceptionMessage': 'PRIVATE_SPOKEN_WORDS',
          },
      ],
    };
    final decoded = NativeDiagnostics.fromMap({'voice': hostile});
    expect(decoded.voice['recentFailures'], hasLength(20));
    expect((decoded.voice['recentFailures'] as List).first['at'], 10);
    expect(decoded.voice['visibleServices'], hasLength(16));
    final snapshot = DiagnosticsSnapshot(
      at: DateTime.utc(2026, 10, 27),
      status: const RuntimeStatus(phase: RuntimePhase.running),
      settings: const AppSettings(),
      voiceMode: VoiceMode.engine,
      // Direct construction must pass the same boundary at export.
      native: NativeDiagnostics(voice: hostile),
    );
    final entries = readZip(DiagnosticsBundle.build(snapshot));
    final text = entries.map((entry) => utf8.decode(entry.data)).join('\n');
    expect(text, isNot(contains('PRIVATE_SPOKEN_WORDS')));
    expect(text, isNot(contains('PRIVATE_AUDIO_BYTES')));
    expect(text, isNot(contains('exceptionMessage')));
    final summary = jsonDecode(utf8.decode(entries.firstWhere((e) => e.name == 'summary.json').data)) as Map;
    expect(summary['voice']['mode'], 'engine');
    expect(summary['voice']['recentFailures'], hasLength(20));
    expect(summary['voice']['recognizerAvailable'], isTrue);
  });
}

import 'dart:async';
import 'dart:convert';

import 'package:dsh_app/diagnostics/diagnostics_bundle.dart';
import 'package:dsh_app/diagnostics/diagnostics_channel.dart';
import 'package:dsh_app/diagnostics/diagnostics_markdown.dart';
import 'package:dsh_app/runtime/runtime_bridge.dart';
import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/state/voice_settings.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/zip_reader.dart';

class _Runtime extends LocalRuntimeController {
  @override
  LocalRuntimeState build() => const LocalRuntimeState(loaded: true);
}

class _Settings extends SettingsController {
  @override
  AppSettings build() => const AppSettings(loaded: true);
}

class _Bridge extends RuntimeBridge {
  @override
  Stream<RuntimeEvent> get events => const Stream.empty();
  @override
  Future<List<String>> logs({int lines = 500}) async => const [];
}

class _Diagnostics extends DiagnosticsChannel {
  @override
  Future<NativeDiagnostics> info() async => const NativeDiagnostics();
  @override
  Future<List<String>> engineLog({int maxBytes = 512 * 1024}) async => const [];
}

class _Voice extends VoiceSettingsController {
  @override
  VoiceMode build() => VoiceMode.auto;
  @override
  Future<VoiceMode> ready() async => VoiceMode.auto;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dsh/phone');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late ProviderContainer container;
  final calls = <String>[];

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    calls.clear();
    container = ProviderContainer(
      overrides: [
        localRuntimeProvider.overrideWith(_Runtime.new),
        settingsProvider.overrideWith(_Settings.new),
        runtimeBridgeProvider.overrideWithValue(_Bridge()),
        diagnosticsChannelProvider.overrideWithValue(_Diagnostics()),
        voiceSettingsProvider.overrideWith(_Voice.new),
      ],
    );
  });
  tearDown(() {
    container.dispose();
    messenger.setMockMethodCallHandler(channel, null);
  });

  Future<DiagnosticsSnapshot> collect() =>
      container.read(Provider((ref) => collectDiagnostics(ref, DateTime.utc(2026, 11, 5))));

  Map summary(DiagnosticsSnapshot snapshot) {
    final file = readZip(DiagnosticsBundle.build(snapshot)).singleWhere((e) => e.name == 'summary.json');
    return jsonDecode(utf8.decode(file.data)) as Map;
  }

  for (final connected in [false, true]) {
    test('exports fresh configured accessibility with connected=$connected', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        expect(call.method, 'status');
        return {
          'enabled': true,
          'bridgeListening': true,
          'a11y': {'enabled': true, 'serviceConnected': connected},
          'task': {
            'app': 'PRIVATE_APP',
            'description': 'PRIVATE_TASK',
            'interjections': ['PRIVATE_INPUT'],
          },
          'clipboard': 'PRIVATE_CLIPBOARD',
        };
      });
      final snapshot = await collect();
      expect(summary(snapshot)['phone'], {
        'available': true,
        'enabled': true,
        'bridgeListening': true,
        'a11y': {'enabled': true, 'serviceConnected': connected},
      });
      final markdown = diagnosticsMarkdown(snapshot);
      expect(markdown, contains('无障碍开关：true · 服务已连接：$connected'));
      final exported = readZip(DiagnosticsBundle.build(snapshot)).map((e) => utf8.decode(e.data)).join();
      expect('$exported\n$markdown', isNot(contains('PRIVATE_')));
      expect(calls, ['status']);
    });
  }

  test('a new collection reads the new status instead of retaining prior facts', () async {
    var enabled = true;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return {
        'enabled': enabled,
        'bridgeListening': enabled,
        'a11y': {'enabled': enabled, 'serviceConnected': enabled},
      };
    });
    expect((summary(await collect())['phone'] as Map)['enabled'], true);
    enabled = false;
    expect(summary(await collect())['phone'], {
      'available': true,
      'enabled': false,
      'bridgeListening': false,
      'a11y': {'enabled': false, 'serviceConnected': false},
    });
    expect(calls, ['status', 'status']);
  });

  testWidgets('an unanswered status times out without blocking the bundle', (tester) async {
    final response = Completer<Object?>();
    messenger.setMockMethodCallHandler(channel, (call) {
      calls.add(call.method);
      return response.future;
    });
    DiagnosticsSnapshot? snapshot;
    final collecting = collect().then((value) => snapshot = value);
    await tester.pump();
    expect(calls, ['status']);
    expect(snapshot, isNull);
    await tester.pump(const Duration(seconds: 5));
    await collecting;
    expect(summary(snapshot!)['phone'], {'available': false});
    expect(summary(snapshot!)['runtime'], isNotEmpty);
    // Finish the fake platform reply; no wall-clock wait is involved.
    response.complete({
      'enabled': true,
      'a11y': {'enabled': true, 'serviceConnected': true},
    });
    await tester.pump();
    expect(summary(snapshot!)['phone'], {'available': false});
  });

  for (final unavailable in ['missing', 'platform-error']) {
    test('$unavailable leaves the original diagnostics usable and reports unknown', () async {
      if (unavailable == 'platform-error') {
        messenger.setMockMethodCallHandler(channel, (call) async {
          throw PlatformException(code: 'failed', message: 'PRIVATE_NATIVE_DETAIL');
        });
      }
      final snapshot = await collect();
      expect(summary(snapshot)['phone'], {'available': false});
      expect(summary(snapshot)['runtime'], isNotEmpty);
      final markdown = diagnosticsMarkdown(snapshot);
      expect(markdown, contains('手机状态不可用'));
      expect(markdown, isNot(contains('无障碍开关：false')));
      expect(markdown, isNot(contains('PRIVATE_NATIVE_DETAIL')));
    });
  }
}

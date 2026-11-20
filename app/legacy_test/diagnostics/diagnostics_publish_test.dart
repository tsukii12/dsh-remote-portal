import 'package:dsh_app/diagnostics/diagnostics_bundle.dart';
import 'package:dsh_app/diagnostics/diagnostics_channel.dart';
import 'package:dsh_app/diagnostics/diagnostics_publish.dart';
import 'package:dsh_app/runtime/runtime_bridge.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

DiagnosticsSnapshot snapshot() => DiagnosticsSnapshot(
  at: DateTime(2026, 10, 31, 18, 0),
  status: const RuntimeStatus(
    phase: RuntimePhase.running,
    abi: 'arm64-v8a',
    dshVersion: '0.2.1-rc.4',
    nodeVersion: '24.22.1',
  ),
  settings: const AppSettings(),
  native: const NativeDiagnostics(device: {'model': 'V2405A', 'android': '16'}),
  appErrors: const [],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('publishes the rendered report and reads the native reply', (tester) async {
    final calls = <MethodCall>[];
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(DiagnosticsPublisher.channel, (call) async {
      calls.add(call);
      return {'bytes': 42, 'path': '/data/rootfs/root/.dsh/dsh-app/diagnostics.md'};
    });
    addTearDown(() => messenger.setMockMethodCallHandler(DiagnosticsPublisher.channel, null));

    final published = await DiagnosticsPublisher(collect: (_) async => snapshot()).publish();
    expect(published?.bytes, 42);
    expect(published?.hostPath, endsWith('diagnostics.md'));
    final call = calls.single;
    expect(call.method, 'publishDiagnostics');
    final markdown = (call.arguments as Map<Object?, Object?>)['markdown'] as String;
    expect(markdown, contains('# DSH Go 本机诊断'));
    expect(markdown, contains('## 环境'));
  });

  testWidgets('a missing runtime (null reply) is reported as not published', (tester) async {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(DiagnosticsPublisher.channel, (call) async => null);
    addTearDown(() => messenger.setMockMethodCallHandler(DiagnosticsPublisher.channel, null));
    expect(await DiagnosticsPublisher(collect: (_) async => snapshot()).publish(), isNull);
  });

  testWidgets('a platform failure is swallowed, not thrown at the UI', (tester) async {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      DiagnosticsPublisher.channel,
      (call) async => throw PlatformException(code: 'io'),
    );
    addTearDown(() => messenger.setMockMethodCallHandler(DiagnosticsPublisher.channel, null));
    expect(await DiagnosticsPublisher(collect: (_) async => snapshot()).publish(), isNull);
  });
}

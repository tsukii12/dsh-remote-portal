import 'package:dsh_app/diagnostics/diagnostics_bundle.dart';
import 'package:dsh_app/diagnostics/diagnostics_channel.dart';
import 'package:dsh_app/runtime/runtime_bridge.dart';
import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/ui/settings/diagnostics_page.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Bridge extends RuntimeBridge {
  @override
  Stream<RuntimeEvent> get events => const Stream.empty();
  @override
  Future<RuntimeStatus> status() async => const RuntimeStatus(phase: RuntimePhase.installed);
  @override
  Future<List<String>> logs({int lines = 500}) async => throw StateError('historical logs unavailable');
}

class _Diagnostics extends DiagnosticsChannel {
  @override
  Future<NativeDiagnostics> info() async => const NativeDiagnostics();
  @override
  Future<List<String>> engineLog({int maxBytes = 512 * 1024}) async => const [];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('diagnostics retains independent in-memory fallback and explicit report count', () async {
    SharedPreferences.setMockInitialValues({});
    const logs = ['first', 'same', 'same'];
    final c = ProviderContainer(
      overrides: [
        runtimeBridgeProvider.overrideWithValue(_Bridge()),
        localRuntimeLogsProvider.overrideWithBuild((ref, notifier) => logs),
        settingsProvider.overrideWithBuild((ref, notifier) => const AppSettings(loaded: true)),
        diagnosticsChannelProvider.overrideWithValue(_Diagnostics()),
      ],
    );
    addTearDown(c.dispose);
    final collect = Provider((ref) => collectDiagnostics(ref, DateTime.utc(2026, 11, 1)));
    final result = await c.read(collect);
    expect(result.engineLog, logs);
    final report = DiagnosticsPage.report(
      runtime: c.read(localRuntimeProvider),
      settings: const AppSettings(),
      connection: 'test',
      logLines: logs.length,
    );
    expect((report['runtime'] as Map)['logLines'], 3);
  });
}

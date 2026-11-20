// Inventory rows shaped like `dynamicCordisRunner/inventory` on DSH
// 0.2.1-rc.2 (`DynamicCordisInventoryRow`), and the pages' fixed overrides.

import 'package:dsh_app/state/cordis_state.dart';
import 'package:dsh_app/state/read_list_identity.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/misc.dart' show Override;

import '../shell/golden_harness.dart' show FakeCurrentSession, FakeSessions;

Map<String, Object?> cordisRow(
  String pluginId,
  String agentId, {
  List<(String id, String name, String purpose)> versions = const [],
  bool host = true,
  bool client = true,
  String? current,
  String? next,
  String? running,
  Map<String, Object?>? latest,
}) => {
  'pluginId': pluginId,
  'agentId': agentId,
  'packages': [
    for (final (id, name, purpose) in versions)
      {'packageId': id, 'name': name, 'purpose': purpose, 'hasHostHalf': host, 'hasClientHalf': client},
  ],
  'currentPackageId': ?current,
  'nextPackageId': ?next,
  if (running != null) 'activeRun': {'pluginRunId': 'run-$pluginId', 'packageId': running},
  'latestRun': ?latest,
};

Map<String, Object?> attempt(String packageId, String status, {Map<String, Object?>? error}) => {
  'pluginRunId': 'run-$packageId',
  'packageId': packageId,
  'mode': 'run',
  'status': status,
  'host': {'status': status == 'failed' ? 'failed' : 'running', 'waitingFor': <String>[]},
  'client': {'status': 'absent', 'waitingFor': <String>[]},
  'error': ?error,
};

/// Four plugins over three conversations: running (two versions), waiting
/// for approval, failed, stopped.
final sampleCordisRows = <Map<String, Object?>>[
  cordisRow(
    'clock-a1b2',
    's1',
    versions: [('pkg-1', '桌面时钟', '在侧边栏显示时间'), ('pkg-2', '桌面时钟', '在侧边栏显示时间和日期')],
    current: 'pkg-2',
    running: 'pkg-2',
    latest: attempt('pkg-2', 'running'),
  ),
  cordisRow(
    'notify-c3d4',
    's1',
    versions: [('pkg-3', '构建通知', '构建结束时在页面右上角提示')],
    latest: {...attempt('pkg-3', 'awaiting-approval'), 'requiresApproval': true, 'approvalRequestId': 'req-1'},
  ),
  cordisRow(
    'translate-e5f6',
    's2',
    versions: [('pkg-4', '翻译助手', '选中文字后显示译文')],
    client: false,
    next: 'pkg-4',
    latest: attempt(
      'pkg-4',
      'failed',
      error: {
        'phase': 'host-apply',
        'message': "TypeError: Cannot read properties of undefined (reading 'fs')",
        'pluginId': 'translate-e5f6',
        'packageId': 'pkg-4',
        'pluginRunId': 'run-pkg-4',
      },
    ),
  ),
  cordisRow(
    'weather-a7b8',
    's3',
    versions: [('pkg-5', '天气卡片', '')],
    host: false,
    current: 'pkg-5',
    latest: attempt('pkg-5', 'stopped'),
  ),
];

List<CordisPlugin> get samplePlugins => [for (final row in sampleCordisRows) CordisPlugin.fromJson(row)!];

SessionSummary _session(String id, String title) => SessionSummary(
  sessionId: id,
  updatedAt: DateTime(2026, 10, 24, 15, 20),
  running: false,
  blank: false,
  agentAvailable: false,
  cwd: '/root/workspace',
  projections: SessionProjections(1, {'title': title}),
);

final cordisSessions = [_session('s1', '做一个桌面时钟插件'), _session('s2', '划词翻译'), _session('s3', '天气卡片')];

/// Fixed inventory (goldens): no client calls.
List<Override> cordisOverrides({List<CordisPlugin>? plugins, CordisReach reach = CordisReach.available}) => [
  cordisReachProvider.overrideWithValue(reach),
  cordisInventoryProvider.overrideWith((ref) async => plugins ?? samplePlugins),
  sessionsProvider.overrideWith(() => FakeSessions(cordisSessions)),
  currentSessionProvider.overrideWith(() => FakeCurrentSession('s1')),
  // The plugin detail sheet reads live plugins, not the read-list display
  // cache (whose identity would read the unfaked local runtime).
  readListIdentityProvider.overrideWithValue(null),
];

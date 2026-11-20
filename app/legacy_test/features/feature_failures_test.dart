import 'dart:async';

import 'package:dsh_app/runtime/runtime_bridge.dart';
import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/features_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/ui/features/agent_presets_page.dart';
import 'package:dsh_app/ui/features/feature_format.dart';
import 'package:dsh_app/ui/features/feature_kit.dart';
import 'package:dsh_app/ui/features/feature_widgets.dart';
import 'package:dsh_app/ui/features/jobs_page.dart';
import 'package:dsh_app/ui/features/permission_page.dart';
import 'package:dsh_app/ui/features/schedules_page.dart';
import 'package:dsh_app/ui/features/skills_page.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import '../chat/support/harness.dart';
import '../plugins/support/fake_plugin_host.dart';

class _Settings extends SettingsController {
  _Settings(this.approve);
  final bool approve;
  @override
  AppSettings build() => AppSettings(loaded: true, autoApproveCommands: approve);
  @override
  Future<void> setAutoApproveCommands(bool value) async {
    state = state.copyWith(autoApproveCommands: value);
  }
}

class _Runtime extends LocalRuntimeController {
  _Runtime(this.safe);
  final bool safe;
  @override
  LocalRuntimeState build() => LocalRuntimeState(
    loaded: true,
    status: RuntimeStatus(phase: RuntimePhase.running, mode: safe ? EngineMode.safe : EngineMode.normal),
  );
}

class _Host extends ActiveHostController {
  _Host(this.host);
  final HostRef host;
  @override
  HostRef build() => host;
}

class _Remote extends RemoteConnectionController {
  _Remote(super.host);
  int retries = 0;
  @override
  Future<HostConnection?> build() async => null;
  @override
  void retry() => retries++;
}

const _permission = PermissionState(
  options: [
    PermissionOption('workspace-write', 'workspace-write'),
    PermissionOption('danger-full-access', 'danger-full-access'),
  ],
  hostDefault: 'workspace-write',
  defaultRevision: 2,
);

Future<void> _pump(WidgetTester tester, Widget page, List<Override> overrides) async {
  usePhoneView(tester);
  await tester.pumpWidget(testApp(page, overrides: overrides));
  await pumpFrames(tester, 6);
}

void main() {
  final errors = <(Object, String?)>[
    (const DshRemoteException('session/not-found', 'raw'), '这个对话已经不在了'),
    (const DshRemoteException('gateway/not-found', 'raw'), '当前引擎版本不支持'),
    (const DshRemoteException('gateway/internal', 'raw'), null),
    (const DshRemoteException('settings/conflict', 'raw'), null),
    (const DshTransportException('raw'), '没能连上引擎'),
    (TimeoutException('raw'), '没能连上引擎'),
    (const DshCarrierLostException('raw'), '没能连上引擎'),
    (const DshClosedException(), '没能连上引擎'),
    (const DshHttpException(401, 'raw'), '没能通过引擎的验证'),
    (const DshHttpException(403, 'raw'), '没能通过引擎的验证'),
    (const DshHttpException(500, 'raw'), null),
    (StateError('raw'), null),
  ];
  for (final (error, reason) in errors) {
    test('public reason: $error', () {
      expect(featureErrorReason(error), reason);
      expect(featureErrorText('没能读取', error), reason == null ? '没能读取' : '没能读取：$reason');
    });
  }
  const failure = DshRemoteException('gateway/not-found', 'Unknown method Exception');
  final pages = <Widget>[
    const SchedulesPage(),
    const JobsPage(sessionId: 's1'),
    const SkillsPage(sessionId: 's1'),
    const AgentPresetsPage(),
    const PermissionPage(),
  ];
  for (final page in pages) {
    testWidgets('${page.runtimeType} hides host diagnostics', (tester) async {
      await _pump(tester, page, [
        activeConnectionProvider.overrideWithValue(AsyncData(fakeConnection)),
        settingsProvider.overrideWith(() => _Settings(false)),
        localRuntimeProvider.overrideWith(() => _Runtime(false)),
        schedulesProvider.overrideWith((ref) async => throw failure),
        jobsProvider.overrideWith((ref, id) => Stream.error(failure)),
        skillsProvider.overrideWith((ref, id) async => throw failure),
        agentPresetsProvider.overrideWith((ref) async => throw failure),
        permissionStateProvider.overrideWith((ref, id) async => throw failure),
      ]);
      expect(find.text('当前引擎版本不支持'), findsOneWidget);
      if (page is SchedulesPage || page is AgentPresetsPage) {
        expect(find.byTooltip('在网页版打开'), findsNothing);
        expect(find.byTooltip('新建'), findsOneWidget);
      }
      expect(find.textContaining('Exception'), findsNothing);
      expect(find.textContaining('gateway/'), findsNothing);
    });
  }

  for (final safe in [false, true]) {
    testWidgets('permission forced selection respects safe mode=$safe', (tester) async {
      await _pump(tester, const PermissionPage(), [
        activeConnectionProvider.overrideWithValue(AsyncData(fakeConnection)),
        settingsProvider.overrideWith(() => _Settings(true)),
        localRuntimeProvider.overrideWith(() => _Runtime(safe)),
        permissionStateProvider.overrideWith((ref, id) async => _permission),
      ]);
      final selected = find.ancestor(
        of: find.text(safe ? '工作区内修改' : '完全权限'),
        matching: find.byWidgetPredicate((w) => w is Semantics && w.properties.selected == true),
      );
      expect(selected, findsOneWidget);
      expect(find.textContaining('一律'), findsNothing);
    });
  }

  for (final conflict in [false, true]) {
    testWidgets('permission saves host preset and clears forced mode; conflict=$conflict', (tester) async {
      final carrier = FakePluginCarrier();
      final client = DshClient.withCarrier(carrier);
      addTearDown(client.close);
      carrier.handlers['settings/mutate'] = (_) {
        if (conflict) throw const DshRemoteException('settings/conflict', 'raw');
        return {
          'ns': 'permission',
          'value': {'defaultPreset': 'workspace-write'},
          'revision': 3,
        };
      };
      await _pump(tester, const PermissionPage(), [
        activeConnectionProvider.overrideWithValue(
          AsyncData(HostConnection(hostId: '', client: client, label: '本机', isLocal: true)),
        ),
        settingsProvider.overrideWith(() => _Settings(true)),
        localRuntimeProvider.overrideWith(() => _Runtime(false)),
        permissionStateProvider.overrideWith((ref, id) async => _permission),
      ]);
      await tester.tap(find.text('工作区内修改'));
      await tester.pumpAndSettle();
      expect(carrier.argsOf('settings/mutate').single['expectedRevision'], 2);
      final container = ProviderScope.containerOf(tester.element(find.byType(PermissionPage)));
      expect(container.read(settingsProvider).autoApproveCommands, conflict);
      expect(find.byType(AlertDialog), findsNothing);
      if (conflict) expect(find.text('刚在别处改过，已刷新'), findsOneWidget);
    });
  }

  testWidgets('full access enables local override without mutating host default', (tester) async {
    final carrier = FakePluginCarrier();
    final client = DshClient.withCarrier(carrier);
    addTearDown(client.close);
    await _pump(tester, const PermissionPage(), [
      activeConnectionProvider.overrideWithValue(AsyncData(HostConnection(hostId: '', client: client, label: '本机', isLocal: true))),
      settingsProvider.overrideWith(() => _Settings(false)),
      localRuntimeProvider.overrideWith(() => _Runtime(false)),
      permissionStateProvider.overrideWith((ref, id) async => _permission),
    ]);
    await tester.tap(find.text('完全权限'));
    await tester.pumpAndSettle();
    expect(find.text('开启完全权限？'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '开启完全权限'));
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(tester.element(find.byType(PermissionPage)));
    expect(container.read(settingsProvider).autoApproveCommands, isTrue);
    expect(carrier.argsOf('settings/mutate'), isEmpty);
  });

  const host = HostRef.portal('computer');
  testWidgets('remote loading has a named quiet spinner', (tester) async {
    await _pump(tester, const Scaffold(body: FeatureOffline()), [
      activeConnectionProvider.overrideWithValue(const AsyncLoading()),
      activeHostProvider.overrideWith(() => _Host(host)),
      hostNameProvider.overrideWith((ref, host) => '电脑'),
    ]);
    expect(find.byType(QuietSpinner), findsOneWidget);
    expect(find.text('正在连接「电脑」…'), findsOneWidget);
  });
  testWidgets('remote failure has a working retry', (tester) async {
    final remote = _Remote(host);
    await _pump(tester, const Scaffold(body: FeatureOffline()), [
      activeConnectionProvider.overrideWithValue(AsyncError(StateError('raw'), StackTrace.current)),
      activeHostProvider.overrideWith(() => _Host(host)),
      hostNameProvider.overrideWith((ref, host) => '电脑'),
      remoteConnectionProvider(host).overrideWith(() => remote),
      hostLinkStatusProvider.overrideWith(
        (ref, host) => Stream.value(
          const HostLinkStatus(
            HostLinkPhase.failed,
            error: HostLinkError(HostLinkErrorKind.unreachable, '网络不可用', retryable: true),
          ),
        ),
      ),
    ]);
    expect(find.text('连不上「电脑」'), findsOneWidget);
    expect(find.text('网络不可用'), findsOneWidget);
    await tester.tap(find.text('重试'));
    expect(remote.retries, 1);
  });
  testWidgets('local idle only has a title and does not create native runtime', (tester) async {
    await _pump(tester, const Scaffold(body: FeatureOffline()), [
      activeConnectionProvider.overrideWithValue(const AsyncData(null)),
      activeHostProvider.overrideWith(() => _Host(HostRef.none)),
      localRuntimeProvider.overrideWith(() => throw StateError('must not watch native runtime')),
    ]);
    expect(find.text('没能连上引擎'), findsOneWidget);
    expect(find.byType(QuietSpinner), findsNothing);
    expect(find.text('引擎运行或连上远程主机后可用'), findsNothing);
  });
}

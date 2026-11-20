import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/state/update_state.dart';
import 'package:dsh_app/ui/update/update_sheet.dart';
import 'package:dsh_app/update/privileged_installer.dart';
import 'package:dsh_app/update/release.dart';
import 'package:dsh_app/update/version.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../shell/golden_harness.dart';
import '../support/english_preview.dart';

class _Update extends AppUpdateController {
  _Update(this.initial);
  final AppUpdateState initial;
  final calls = <String>[];

  @override
  AppUpdateState build() => initial;

  @override
  Future<void> get ready async {}

  @override
  Future<void> refreshInstallStatus() async => calls.add('status');

  @override
  Future<void> requestUpdateShizukuPermission() async => calls.add('permission');

  @override
  Future<void> install({UpdateInstallRoute route = UpdateInstallRoute.system, int? port}) async =>
      calls.add('install:${route.name}:$port');

  @override
  Future<void> retry({int? port}) async => calls.add('retry:$port');

  @override
  Future<void> reconcileSelfUpdate() async => calls.add('reconcile');

  @override
  Future<void> acknowledgeUnknownSelfUpdate() async => calls.add('acknowledge');
}

AppUpdateState _ready({SelfUpdatePending pending = const SelfUpdatePending(), bool offer = true}) => AppUpdateState(
  loaded: true,
  current: const AppVersion(1, 0, 0, build: 1),
  flavor: ApkFlavor.arm64,
  check: UpdateCheckPhase.available,
  latest: offer ? parseUpdateManifest({
    'schema': 1, 'version': '1.2.0+2', 'tag': 'v1.2.0', 'notes': '',
    'assets': {'arm64': {'name': 'dsh-go-1.2.0-arm64.apk', 'size': 1}},
  }) : null,
  task: pending.unresolved ? UpdateTaskPhase.installing : UpdateTaskPhase.ready,
  selfUpdate: pending,
);

void main() {
  tearDown(() => AppLocale.use(AppLocale.zhCN));

  Future<_Update> pump(WidgetTester tester, AppUpdateState state, {bool english = false}) async {
    if (english) useEnglish();
    usePhoneSurface(tester);
    final update = _Update(state);
    const sheet = Scaffold(body: SingleChildScrollView(child: UpdateSheet()));
    await tester.pumpWidget(goldenApp(
      home: english ? inEnglish(sheet) : sheet,
      brightness: Brightness.light,
      overrides: [
        localRuntimeProvider.overrideWith(() => FakeRuntime(const LocalRuntimeState(loaded: true, status: runningStatus))),
        settingsProvider.overrideWith(() => FakeSettings(const AppSettings(loaded: true))),
        appUpdateProvider.overrideWith(() => update),
      ],
    ));
    await tester.pump();
    return update;
  }

  testWidgets('the complete APK defaults to normal install and selecting Shizuku does not authorize or install', (tester) async {
    final update = await pump(tester, _ready());
    expect(find.text('正常安装（默认）'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('update-route-system')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Shizuku').last);
    await tester.pumpAndSettle();
    expect(update.calls, ['status']);
    expect(find.byKey(const ValueKey('update-authorize-shizuku')), findsOneWidget);
    await tester.ensureVisible(find.byKey(const ValueKey('update-authorize-shizuku')));
    await tester.tap(find.byKey(const ValueKey('update-authorize-shizuku')));
    await tester.pump();
    expect(update.calls, ['status', 'permission']);
    expect(find.textContaining('授权 Shizuku 不等于同意安装'), findsOneWidget);
  });

  for (final phase in [UpdateTaskPhase.ready, UpdateTaskPhase.needsPermission, UpdateTaskPhase.failed]) {
    testWidgets('queued $phase submit rejects the current invalid ADB port before dispatch', (tester) async {
      final update = await pump(tester, _ready().copyWith(
        task: phase,
        installRoute: UpdateInstallRoute.adb,
        problem: () => phase == UpdateTaskPhase.failed ? UpdateProblem.installFailed : null,
      ));
      final label = phase == UpdateTaskPhase.failed ? '重试' : '安装';
      final submit = tester.widget<FilledButton>(find.widgetWithText(FilledButton, label)).onPressed!;
      final field = find.byKey(const ValueKey('update-adb-port'));
      for (final invalid in ['0', '65536', '9' * 48]) {
        await tester.enterText(field, invalid);
        submit(); // Invoke the queued callback before a rebuilt button can disable it.
        await tester.pump();
        expect(update.calls, isEmpty, reason: 'nonempty invalid ports must not become mDNS discovery');
      }
      await tester.enterText(field, '37123');
      submit();
      await tester.pump();
      expect(update.calls, [phase == UpdateTaskPhase.failed ? 'retry:37123' : 'install:adb:37123']);
    });
  }

  testWidgets('unknown outcome offers only read and explicitly confirmed end-wait, never retry or fallback', (tester) async {
    final update = await pump(tester, _ready(pending: const SelfUpdatePending(
      state: SelfUpdatePendingState.unknown, backend: UpdateInstallRoute.adb, versionCode: 2, canAcknowledge: true,
    )));
    expect(find.text('安装结果未知'), findsOneWidget);
    expect(find.text('重试'), findsNothing);
    expect(find.byKey(const ValueKey('update-system-installer')), findsNothing);
    expect(find.byKey(const ValueKey('update-route-system')), findsNothing);
    expect(find.textContaining('清除本次记录不等于取消系统安装'), findsOneWidget);
    await tester.ensureVisible(find.text('读取实际安装状态'));
    await tester.tap(find.text('读取实际安装状态'));
    await tester.pump();
    await tester.ensureVisible(find.byKey(const ValueKey('update-end-waiting')));
    await tester.tap(find.byKey(const ValueKey('update-end-waiting')));
    await tester.pump();
    expect(update.calls, ['reconcile', 'acknowledge']);
  });

  testWidgets('active pending never offers ending the wait', (tester) async {
    await pump(tester, _ready(pending: const SelfUpdatePending(
      state: SelfUpdatePendingState.pending, backend: UpdateInstallRoute.adb, versionCode: 2, canAcknowledge: true,
    )));
    expect(find.byKey(const ValueKey('update-end-waiting')), findsNothing);
    expect(find.text('读取实际安装状态'), findsOneWidget);
  });

  testWidgets('startup recovery without a cached offer still shows actual current version and read controls in English', (tester) async {
    await pump(tester, _ready(offer: false, pending: const SelfUpdatePending(
      state: SelfUpdatePendingState.unknown, backend: UpdateInstallRoute.adb, versionCode: 2,
    )), english: true);
    expect(find.text('Installation outcome unknown'), findsOneWidget);
    expect(find.text('Read actual installed state'), findsOneWidget);
    expect(find.textContaining('does not prove failure'), findsOneWidget);
    expect(find.textContaining('1.0.0'), findsOneWidget);
    expect(find.byKey(const ValueKey('update-end-waiting')), findsNothing);
  });
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dsh_app/state/update_state.dart';
import 'package:dsh_app/update/installer.dart';
import 'package:dsh_app/update/privileged_installer.dart';
import 'package:dsh_app/update/update_config.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support.dart';

const _name = 'dsh-go-1.2.0-arm64.apk';
const _url = 'https://github.com/ccch1mneyyy/dsh-go/releases/download/v1.2.0/$_name';
final _bytes = utf8.encode('fixed host-only privileged update bytes');
const _inspection = ApkInspection(
  valid: true, packageName: 'io.github.ccch1mneyyy.dsh_app', versionName: '1.2.0', versionCode: 2, signatureMatches: true,
);

class _Privileged implements PrivilegedInstaller {
  final calls = <String>[];
  final requests = <Map<String, Object?>>[];
  PrivilegedInstallStatus transport = const PrivilegedInstallStatus(
    supported: true, shizukuInstalled: true, shizukuRunning: true, shizukuGranted: true, shizukuUid: 2000, adbPaired: true,
  );
  PrivilegedInstallResult result = const PrivilegedInstallResult(
    status: PrivilegedInstallOutcome.unavailable, errorCode: 'notConnected', outcomeUnknown: false,
  );
  SelfUpdatePending pending = const SelfUpdatePending();
  SelfUpdatePending acknowledged = const SelfUpdatePending();
  Completer<PrivilegedInstallResult>? waiting;
  final dispatchStarted = Completer<void>();
  bool denyAcknowledge = false;

  @override
  Future<PrivilegedInstallStatus> status() async {
    calls.add('status');
    return transport;
  }

  @override
  Future<bool> requestShizukuPermission() async {
    calls.add('permission');
    return true;
  }

  @override
  Future<PrivilegedInstallResult> install({
    required String path, required String sha256, required int versionCode, required UpdateInstallRoute backend, int? port,
  }) async {
    calls.add('install');
    if (!dispatchStarted.isCompleted) dispatchStarted.complete();
    requests.add({'path': path, 'sha256': sha256, 'versionCode': versionCode, 'backend': backend, 'port': port});
    return waiting?.future ?? result;
  }

  @override
  Future<SelfUpdatePending> reconcile() async {
    calls.add('reconcile');
    return pending;
  }

  @override
  Future<SelfUpdatePending> acknowledgeUnknown() async {
    calls.add('acknowledge');
    if (denyAcknowledge) throw StateError('native confirmation denied');
    return acknowledged;
  }
}

void main() {
  late Directory directory;
  late FakeInstaller installer;
  late _Privileged privileged;
  late FakeHttp http;
  late ProviderContainer container;
  late AppUpdateController controller;

  ProviderContainer makeContainer() => ProviderContainer(overrides: [
    updateHttpProvider.overrideWithValue(http),
    updateInstallerProvider.overrideWithValue(installer),
    privilegedInstallerProvider.overrideWithValue(privileged),
    updateSourcesProvider.overrideWithValue(const UpdateSources(mirrors: [UpdateMirror.github])),
    updateFlavorNameProvider.overrideWithValue('arm64'),
    updateDirectoryProvider.overrideWithValue(() async => directory),
  ]);

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('privileged-update-');
    installer = FakeInstaller(inspection: _inspection);
    privileged = _Privileged();
    http = FakeHttp({_url: fileRoute(_bytes)});
    SharedPreferences.setMockInitialValues({
      'update_latest': jsonEncode({
        'schema': 1, 'version': '1.2.0+2', 'tag': 'v1.2.0', 'notes': '',
        'assets': {'arm64': {'name': _name, 'size': _bytes.length, 'sha256': sha256.convert(_bytes).toString()}},
      }),
    });
    container = makeContainer();
    controller = container.read(appUpdateProvider.notifier);
    await controller.ready;
    await controller.startDownload();
    expect(container.read(appUpdateProvider).task, UpdateTaskPhase.ready);
  });

  tearDown(() async {
    container.dispose();
    await directory.delete(recursive: true);
  });

  test('new fields have defaults and normal installation keeps the old installer contract', () async {
    final state = container.read(appUpdateProvider);
    expect(state.installRoute, UpdateInstallRoute.system);
    expect(state.selfUpdate.state, SelfUpdatePendingState.none);
    expect(privileged.calls, ['reconcile']);
    await controller.install();
    expect(installer.calls, ['canRequestInstalls', 'inspect', 'install']);
    expect(privileged.requests, isEmpty);
    expect(container.read(appUpdateProvider).task, UpdateTaskPhase.idle);
  });

  for (final route in [UpdateInstallRoute.shizuku, UpdateInstallRoute.adb]) {
    test('$route is explicit and independent of unknown-app permission or Phone control', () async {
      installer.canInstall = false;
      await controller.install(route: route, port: route == UpdateInstallRoute.adb ? 37123 : null);
      expect(installer.calls, ['inspect']);
      expect(privileged.requests.single, {
        'path': '${directory.path}/$_name', 'sha256': sha256.convert(_bytes).toString(),
        'versionCode': 2, 'backend': route, 'port': route == UpdateInstallRoute.adb ? 37123 : null,
      });
      expect(privileged.calls.where((call) => call == 'permission'), isEmpty);
      expect(container.read(appUpdateProvider).problem, UpdateProblem.installFailed);
    });
  }

  test('changing route while system permission is pending never resumes the normal installer', () async {
    installer.canInstall = false;
    await controller.install();
    expect(container.read(appUpdateProvider).task, UpdateTaskPhase.needsPermission);
    controller.selectInstallRoute(UpdateInstallRoute.shizuku);
    installer.canInstall = true;
    await controller.onAppResumed(confirmGrace: Duration.zero);
    expect(installer.installed, isEmpty);
    expect(privileged.requests, isEmpty);
    expect(container.read(appUpdateProvider).installRoute, UpdateInstallRoute.shizuku);
  });

  test('authorizing Shizuku never installs or changes the selected route', () async {
    await controller.requestUpdateShizukuPermission();
    expect(privileged.calls, ['reconcile', 'permission', 'status']);
    expect(privileged.requests, isEmpty);
    expect(installer.calls, isEmpty);
    expect(container.read(appUpdateProvider).installRoute, UpdateInstallRoute.system);
    expect(container.read(appUpdateProvider).task, UpdateTaskPhase.ready);
  });

  for (final signature in [null, false]) {
    test('privileged installation rejects signature evidence $signature', () async {
      installer.inspection = ApkInspection(valid: true, versionName: '1.2.0', versionCode: 2, signatureMatches: signature);
      await controller.install(route: UpdateInstallRoute.shizuku);
      expect(privileged.requests, isEmpty);
      expect(container.read(appUpdateProvider).problem, UpdateProblem.signature);
    });
  }

  test('normal installation still lets native decide a missing signature result', () async {
    installer.inspection = const ApkInspection(valid: true);
    await controller.install();
    expect(installer.calls.last, 'install');
    expect(privileged.requests, isEmpty);
  });

  test('changed full APK bytes cannot reach a privileged backend', () async {
    await File('${directory.path}/$_name').writeAsString('changed');
    await controller.install(route: UpdateInstallRoute.adb);
    expect(privileged.requests, isEmpty);
    expect(container.read(appUpdateProvider).problem, UpdateProblem.checksum);
    await controller.retry();
    expect(container.read(appUpdateProvider).installRoute, UpdateInstallRoute.adb);
    expect(privileged.requests, isEmpty, reason: 're-downloading never installs or switches routes');
  });

  test('unknown outcome is not the system three-second failure and blocks every replay path', () async {
    privileged.result = const PrivilegedInstallResult(submitted: true);
    privileged.pending = const SelfUpdatePending(
      state: SelfUpdatePendingState.unknown, backend: UpdateInstallRoute.adb, versionCode: 2,
    );
    await controller.install(route: UpdateInstallRoute.adb);
    final downloads = http.requests.length;
    await controller.onAppResumed(confirmGrace: Duration.zero);
    await controller.retry();
    await controller.startDownload();
    await controller.install();
    controller.selectInstallRoute(UpdateInstallRoute.system);
    expect(await controller.installWithSystem(), isFalse);
    final state = container.read(appUpdateProvider);
    expect(state.selfUpdate.state, SelfUpdatePendingState.unknown);
    expect(state.busy, isTrue);
    expect(state.installRoute, UpdateInstallRoute.adb);
    expect(state.problem, isNot(UpdateProblem.installUnconfirmed));
    expect(privileged.requests, hasLength(1));
    expect(installer.installed, isEmpty);
    expect(http.requests, hasLength(downloads));
  });

  test('resume reads pending without ending a live RPC, and a definite abort clears the wait', () async {
    final waiting = privileged.waiting = Completer<PrivilegedInstallResult>();
    final installing = controller.install(route: UpdateInstallRoute.adb);
    await privileged.dispatchStarted.future;
    privileged.pending = const SelfUpdatePending(
      state: SelfUpdatePendingState.pending, backend: UpdateInstallRoute.adb, versionCode: 2,
    );
    await controller.onAppResumed(confirmGrace: Duration.zero);
    expect(container.read(appUpdateProvider).selfUpdate.state, SelfUpdatePendingState.pending);
    expect(container.read(appUpdateProvider).task, UpdateTaskPhase.installing);
    waiting.complete(const PrivilegedInstallResult(
      status: PrivilegedInstallOutcome.aborted, outcomeUnknown: false,
    ));
    await installing;
    expect(container.read(appUpdateProvider).task, UpdateTaskPhase.ready);
    expect(container.read(appUpdateProvider).selfUpdate.state, SelfUpdatePendingState.none);
    expect(container.read(appUpdateProvider).busy, isFalse);
    expect(privileged.requests, hasLength(1));
  });

  test('a successful native RPC is unknown until installed version is reconciled', () async {
    privileged.result = const PrivilegedInstallResult(
      status: PrivilegedInstallOutcome.success, submitted: true, outcomeUnknown: false,
    );
    await controller.install(route: UpdateInstallRoute.shizuku);
    expect(container.read(appUpdateProvider).selfUpdate.state, SelfUpdatePendingState.unknown);
    privileged.pending = const SelfUpdatePending(
      state: SelfUpdatePendingState.installed, backend: UpdateInstallRoute.shizuku, versionCode: 2,
    );
    await controller.reconcileSelfUpdate();
    expect(container.read(appUpdateProvider).selfUpdate.state, SelfUpdatePendingState.unknown,
      reason: 'the installed app still reports build 1');
    installer.app = const InstalledApp(versionName: '1.2.0', versionCode: 2, abi: 'arm64');
    await controller.reconcileSelfUpdate();
    final state = container.read(appUpdateProvider);
    expect(state.selfUpdate.state, SelfUpdatePendingState.installed);
    expect(state.current.toString(), '1.2.0+2');
    expect(state.hasUpdate, isFalse);
    expect(state.busy, isFalse);
    expect(privileged.requests, hasLength(1));
  });

  test('startup reads native evidence and real installed version without reinstalling', () async {
    container.dispose();
    privileged.pending = const SelfUpdatePending(
      state: SelfUpdatePendingState.superseded, backend: UpdateInstallRoute.adb, versionCode: 2,
    );
    installer.app = const InstalledApp(versionName: '1.3.0', versionCode: 3, abi: 'arm64');
    final downloads = http.requests.length;
    container = makeContainer();
    controller = container.read(appUpdateProvider.notifier);
    await controller.ready;
    final state = container.read(appUpdateProvider);
    expect(state.current.toString(), '1.3.0+3');
    expect(state.selfUpdate.state, SelfUpdatePendingState.superseded);
    expect(state.hasUpdate, isFalse);
    expect(privileged.requests, isEmpty);
    expect(http.requests, hasLength(downloads));
  });

  for (final canAcknowledge in [false, true]) {
    test('active pending cannot be acknowledged even with capability $canAcknowledge', () async {
      privileged.pending = SelfUpdatePending(
        state: SelfUpdatePendingState.pending, backend: UpdateInstallRoute.adb, versionCode: 2,
        canAcknowledge: canAcknowledge,
      );
      await controller.install(route: UpdateInstallRoute.adb);
      // The definite result above can finish locally; restore the native pending state by reading it.
      await controller.reconcileSelfUpdate();
      await controller.acknowledgeUnknownSelfUpdate();
      expect(privileged.calls.where((call) => call == 'acknowledge'), isEmpty);
      expect(container.read(appUpdateProvider).selfUpdate.state, SelfUpdatePendingState.pending);
    });
  }

  test('native-confirmed end-wait only restores readiness and never retries or switches route', () async {
    privileged.result = const PrivilegedInstallResult(submitted: true);
    privileged.pending = const SelfUpdatePending(
      state: SelfUpdatePendingState.unknown, backend: UpdateInstallRoute.adb, versionCode: 2, canAcknowledge: true,
    );
    await controller.install(route: UpdateInstallRoute.adb);
    final downloads = http.requests.length;
    await controller.acknowledgeUnknownSelfUpdate();
    final state = container.read(appUpdateProvider);
    expect(state.selfUpdate.state, SelfUpdatePendingState.none);
    expect(state.task, UpdateTaskPhase.ready);
    expect(state.installRoute, UpdateInstallRoute.adb);
    expect(privileged.requests, hasLength(1));
    expect(installer.installed, isEmpty);
    expect(http.requests, hasLength(downloads));
  });

  test('native denial of end-wait preserves the unknown result', () async {
    privileged.result = const PrivilegedInstallResult(submitted: true);
    privileged.pending = const SelfUpdatePending(
      state: SelfUpdatePendingState.unknown, backend: UpdateInstallRoute.adb, versionCode: 2, canAcknowledge: true,
    );
    privileged.denyAcknowledge = true;
    await controller.install(route: UpdateInstallRoute.adb);
    final before = container.read(appUpdateProvider).selfUpdate;
    await controller.acknowledgeUnknownSelfUpdate();
    expect(container.read(appUpdateProvider).selfUpdate, same(before));
    expect(container.read(appUpdateProvider).busy, isTrue);
    expect(privileged.requests, hasLength(1));
  });
}

// Who owns the update task when answers arrive late. Started from the audit's
// counterexamples (022 APP-UPDATE-AUDIT, U1 and U2), which asserted that the
// defects happen; these assert the behaviour that has to hold instead.
//
// U1: the APK handed to the installer is the one on screen: same version, and
//     bytes that still hash to what was verified for it.
// U2: an abandoned install attempt (the grace period freed the UI) can't touch
//     the state any more, whether it ends with an answer or an exception.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dsh_app/state/update_state.dart';
import 'package:dsh_app/update/installer.dart';
import 'package:dsh_app/update/update_config.dart';
import 'package:dsh_app/update/update_http.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support.dart';

const _sources = UpdateSources(mirrors: [UpdateMirror.github]);
const _manifest = 'https://github.com/ccch1mneyyy/dsh-go/releases/latest/download/update.json';

String _apkName(String version) => 'dsh-go-$version-arm64.apk';
String _apkUrl(String version) =>
    'https://github.com/ccch1mneyyy/dsh-go/releases/download/v$version/${_apkName(version)}';

/// Different bytes per version, so the hashes differ too.
List<int> _apk(String version) => utf8.encode('PK pretend this is DSH $version for arm64');

Map<String, Object?> _release(String version) => {
  'schema': 1,
  'version': version,
  'tag': 'v$version',
  'notes': '- $version',
  'assets': {
    'arm64': {
      'name': _apkName(version),
      'size': _apk(version).length,
      'sha256': sha256.convert(_apk(version)).toString(),
    },
  },
};

Route _manifestOf(String version) =>
    (_, _) => textResponse(jsonEncode(_release(version)));

/// Answers once [gate] completes; [entered] completes when the request arrives.
Route _gated(Completer<UpdateHttpResponse> gate, Completer<void> entered) => (_, _) {
  entered.complete();
  return gate.future;
};

/// Sends [bytes] once [gate] completes.
Route _slowFile(List<int> bytes, Completer<void> gate, Completer<void> entered) => (_, _) {
  entered.complete();
  Stream<List<int>> body() async* {
    await gate.future;
    yield bytes;
  }

  return UpdateHttpResponse(status: 200, contentLength: bytes.length, body: body());
};

/// A download in flight, and a check that started before it, still unanswered.
typedef _LateCheck = ({
  AppUpdateController controller,
  Completer<UpdateHttpResponse> check,
  Future<UpdateCheckPhase> checking,
  Completer<void> bytes,
  Future<void> downloading,
});

void main() {
  late Directory dir;
  late FakeHttp http;
  late FakeInstaller installer;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('dsh_update_ownership');
    http = FakeHttp();
    installer = FakeInstaller();
    SharedPreferences.setMockInitialValues({});
  });
  tearDown(() => dir.deleteSync(recursive: true));

  ProviderContainer container() {
    final c = ProviderContainer(
      overrides: [
        updateHttpProvider.overrideWithValue(http),
        updateInstallerProvider.overrideWithValue(installer),
        updateSourcesProvider.overrideWithValue(_sources),
        updateClockProvider.overrideWithValue(() => DateTime(2026, 11, 2, 9)),
        updateFlavorNameProvider.overrideWithValue('arm64'),
        updateDirectoryProvider.overrideWithValue(() async => dir),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  Future<AppUpdateController> ready(ProviderContainer c) async {
    final controller = c.read(appUpdateProvider.notifier);
    await controller.ready;
    return controller;
  }

  String path(String version) => '${dir.path}/${_apkName(version)}';
  Future<String?> cachedOffer() async {
    final raw = (await SharedPreferences.getInstance()).getString('update_latest');
    return raw == null ? null : (jsonDecode(raw) as Map)['version'] as String?;
  }

  /// 1.2.0 on offer, its download held at the first byte, and a second check
  /// that started before the download and is waiting for its answer.
  Future<_LateCheck> lateCheckDuringDownload(ProviderContainer c) async {
    http.routes[_manifest] = _manifestOf('1.2.0');
    final controller = await ready(c);
    await controller.check();

    final check = Completer<UpdateHttpResponse>();
    final checkEntered = Completer<void>();
    http.routes[_manifest] = _gated(check, checkEntered);
    final checking = controller.check();
    await checkEntered.future;

    final bytes = Completer<void>();
    final downloadEntered = Completer<void>();
    http.routes[_apkUrl('1.2.0')] = _slowFile(_apk('1.2.0'), bytes, downloadEntered);
    http.routes[_apkUrl('1.3.0')] = fileRoute(_apk('1.3.0'));
    final downloading = controller.startDownload();
    await downloadEntered.future;
    expect(c.read(appUpdateProvider).task, UpdateTaskPhase.downloading);
    return (controller: controller, check: check, checking: checking, bytes: bytes, downloading: downloading);
  }

  group('U1: what is installed is what is on screen', () {
    test('a newer release found during a download leaves that download and its offer alone', () async {
      final c = container();
      final run = await lateCheckDuringDownload(c);

      run.check.complete(textResponse(jsonEncode(_release('1.3.0'))));
      await run.checking;
      var state = c.read(appUpdateProvider);
      expect(state.latest!.version.name, '1.2.0', reason: 'the release being downloaded stays on screen');
      expect(state.task, UpdateTaskPhase.downloading, reason: 'the running download is still busy');
      expect(await cachedOffer(), '1.2.0', reason: 'the remembered offer matches the download');

      // A second tap can't start a parallel download of the newer one.
      await run.controller.startDownload();
      expect(http.urls.where((u) => u.endsWith('.apk')), [_apkUrl('1.2.0')]);

      run.bytes.complete();
      await run.downloading;
      state = c.read(appUpdateProvider);
      expect(state.task, UpdateTaskPhase.ready);
      expect(state.latest!.version.name, '1.2.0');

      await run.controller.install();
      expect(installer.installed, [path('1.2.0')]);
      expect(c.read(appUpdateProvider).task, UpdateTaskPhase.idle);

      // Afterwards a check takes the newer release as usual.
      http.routes[_manifest] = _manifestOf('1.3.0');
      await run.controller.check();
      expect(c.read(appUpdateProvider).latest!.version.name, '1.3.0');
      expect(await cachedOffer(), '1.3.0');
    });

    test('"nothing newer" from a stale source during a download drops neither the offer nor the task', () async {
      final c = container();
      final run = await lateCheckDuringDownload(c);

      run.check.complete(textResponse(jsonEncode(_release('1.0.0'))));
      await run.checking;
      expect(c.read(appUpdateProvider).latest!.version.name, '1.2.0');
      expect(c.read(appUpdateProvider).task, UpdateTaskPhase.downloading);

      run.bytes.complete();
      await run.downloading;
      expect(c.read(appUpdateProvider).task, UpdateTaskPhase.ready);
      await run.controller.install();
      expect(installer.installed, [path('1.2.0')]);
    });

    test('cancelling after a late answer goes back to the offer that was downloading', () async {
      final c = container();
      final run = await lateCheckDuringDownload(c);

      run.check.complete(textResponse(jsonEncode(_release('1.3.0'))));
      await run.checking;
      run.controller.cancelDownload();
      await run.downloading;
      final state = c.read(appUpdateProvider);
      expect(state.task, UpdateTaskPhase.idle);
      expect(state.latest!.version.name, '1.2.0');
      await run.controller.install();
      expect(installer.calls, isNot(contains('install')));
    });

    test('a check answering after the download finished does not swap the offer under the ready APK', () async {
      final c = container();
      final run = await lateCheckDuringDownload(c);

      run.bytes.complete();
      await run.downloading;
      expect(c.read(appUpdateProvider).task, UpdateTaskPhase.ready);
      run.check.complete(textResponse(jsonEncode(_release('1.3.0'))));
      await run.checking;

      final state = c.read(appUpdateProvider);
      expect(state.task, UpdateTaskPhase.ready);
      expect(state.latest!.version.name, '1.2.0');
      await run.controller.install();
      expect(installer.installed, [path('1.2.0')]);
    });

    test('once a newer release is on screen, the APK of the older one is never installed', () async {
      http.routes[_manifest] = _manifestOf('1.2.0');
      http.routes[_apkUrl('1.2.0')] = fileRoute(_apk('1.2.0'));
      http.routes[_apkUrl('1.3.0')] = fileRoute(_apk('1.3.0'));
      final c = container();
      final controller = await ready(c);
      await controller.check();
      await controller.startDownload();
      expect(c.read(appUpdateProvider).task, UpdateTaskPhase.ready);

      http.routes[_manifest] = _manifestOf('1.3.0');
      await controller.check();
      expect(c.read(appUpdateProvider).latest!.version.name, '1.3.0');
      expect(c.read(appUpdateProvider).task, UpdateTaskPhase.idle);
      await controller.install();
      expect(installer.calls, isNot(contains('install')));

      await controller.startDownload();
      await controller.install();
      expect(installer.installed, [path('1.3.0')]);
    });

    test('bytes changed on disk after verification are not installed', () async {
      http.routes[_manifest] = _manifestOf('1.2.0');
      http.routes[_apkUrl('1.2.0')] = fileRoute(_apk('1.2.0'));
      final c = container();
      final controller = await ready(c);
      await controller.check();
      await controller.startDownload();
      expect(c.read(appUpdateProvider).task, UpdateTaskPhase.ready);

      File(path('1.2.0')).writeAsBytesSync(_apk('1.3.0'));
      await controller.install();
      expect(installer.calls, isNot(contains('install')));
      expect(c.read(appUpdateProvider).task, UpdateTaskPhase.failed);
      expect(c.read(appUpdateProvider).problem, UpdateProblem.checksum);
      expect(File(path('1.2.0')).existsSync(), isFalse, reason: 'thrown away, the retry downloads it again');

      await controller.retry();
      expect(c.read(appUpdateProvider).task, UpdateTaskPhase.ready);
      await controller.install();
      expect(installer.installed, [path('1.2.0')]);
    });

    test('an APK whose manifest names another version is not installed', () async {
      http.routes[_manifest] = _manifestOf('1.2.0');
      http.routes[_apkUrl('1.2.0')] = fileRoute(_apk('1.2.0'));
      installer.inspection = const ApkInspection(
        valid: true,
        packageName: 'io.github.ccch1mneyyy.dsh_app',
        versionName: '1.1.0',
        versionCode: 9,
        signatureMatches: true,
      );
      final c = container();
      final controller = await ready(c);
      await controller.check();
      await controller.startDownload();
      await controller.install();
      expect(installer.calls, isNot(contains('install')));
      expect(c.read(appUpdateProvider).problem, UpdateProblem.checksum);

      installer.inspection = const ApkInspection(
        valid: true,
        packageName: 'io.github.ccch1mneyyy.dsh_app',
        versionName: '1.2.0',
        versionCode: 9,
        signatureMatches: true,
      );
      await controller.retry();
      await controller.install();
      expect(installer.installed, [path('1.2.0')]);
    });
  });

  group('U2: an abandoned install attempt changes nothing', () {
    Future<AppUpdateController> downloaded(ProviderContainer c) async {
      http.routes[_manifest] = _manifestOf('1.2.0');
      http.routes[_apkUrl('1.2.0')] = fileRoute(_apk('1.2.0'));
      final controller = await ready(c);
      await controller.check();
      await controller.startDownload();
      expect(c.read(appUpdateProvider).task, UpdateTaskPhase.ready);
      return controller;
    }

    test('a late exception after the grace period leaves the recovered ready state', () async {
      final c = container();
      final controller = await downloaded(c);
      final dialog = installer.pending = Completer<InstallResult>();
      final installing = controller.install();
      await installer.called('install');

      await controller.onAppResumed(confirmGrace: Duration.zero);
      expect(c.read(appUpdateProvider).task, UpdateTaskPhase.ready);
      dialog.completeError(StateError('late platform failure'));
      await installing;
      expect(c.read(appUpdateProvider).task, UpdateTaskPhase.ready);
      expect(c.read(appUpdateProvider).problem, UpdateProblem.installUnconfirmed);
    });

    test('a newer attempt is untouched by the abandoned one ending, with an answer or an exception', () async {
      final c = container();
      final controller = await downloaded(c);
      final first = installer.pending = Completer<InstallResult>();
      final firstRun = controller.install();
      await installer.called('install');
      await controller.onAppResumed(confirmGrace: Duration.zero);

      final second = installer.pending = Completer<InstallResult>();
      final secondRun = controller.install();
      await installer.called('install', times: 2);
      expect(c.read(appUpdateProvider).task, UpdateTaskPhase.installing);

      first.completeError(StateError('late platform failure'));
      await firstRun;
      expect(c.read(appUpdateProvider).task, UpdateTaskPhase.installing);
      expect(c.read(appUpdateProvider).problem, isNull);

      second.complete(const InstallResult(InstallStatus.aborted));
      await secondRun;
      expect(c.read(appUpdateProvider).task, UpdateTaskPhase.ready);
      expect(c.read(appUpdateProvider).problem, UpdateProblem.installCancelled);
    });

    test('a second tap while the first is still checking permission starts nothing', () async {
      final c = container();
      final controller = await downloaded(c);
      await Future.wait([controller.install(), controller.install()]);
      expect(installer.calls.where((m) => m == 'canRequestInstalls'), hasLength(1));
      expect(installer.calls.where((m) => m == 'install'), hasLength(1));
      expect(c.read(appUpdateProvider).task, UpdateTaskPhase.idle);
    });

    test('a late "invalid" from the abandoned attempt neither fails the state nor deletes the APK', () async {
      final c = container();
      final controller = await downloaded(c);
      final inspection = installer.pendingInspect = Completer<ApkInspection>();
      final installing = controller.install();
      await installer.called('inspect');

      await controller.onAppResumed(confirmGrace: Duration.zero);
      expect(c.read(appUpdateProvider).task, UpdateTaskPhase.ready);
      inspection.complete(const ApkInspection(valid: false));
      await installing;
      expect(c.read(appUpdateProvider).task, UpdateTaskPhase.ready);
      expect(File(path('1.2.0')).existsSync(), isTrue);
      expect(installer.calls, isNot(contains('install')));

      installer.pendingInspect = null;
      await controller.install();
      expect(installer.installed, [path('1.2.0')]);
    });
  });
}

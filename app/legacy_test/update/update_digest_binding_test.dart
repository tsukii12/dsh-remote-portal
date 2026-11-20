// One (version, file, digest) from the offer on screen to the APK handed to
// the installer. Started from CR-e0b8ece U1's counterexample, which showed a
// late check filling in a conflicting digest for the same version and file
// while an install waited on its checks, and the old file still going to the
// installer. These assert what has to hold instead: the same version and file
// name under two different digests is a conflict; the attempt fails, its APK is
// thrown away and the next try downloads against the digest now on screen.
//
// Covered orders: null → same, null → conflicting, known → null, two known
// digests, and a check answering during the SHA256SUMS lookup, during the
// download, with the APK ready, while the install waits on its checks and
// after the APK went to the system installer.

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
const _name = 'dsh-go-1.2.0-arm64.apk';
const _asset = 'https://github.com/ccch1mneyyy/dsh-go/releases/download/v1.2.0/$_name';
const _sums = 'https://github.com/ccch1mneyyy/dsh-go/releases/download/v1.2.0/SHA256SUMS';

final _bytesA = utf8.encode('PK synthetic release payload alpha');
final _bytesB = utf8.encode('PK synthetic release payload bravo');
final _hashA = sha256.convert(_bytesA).toString();
final _hashB = sha256.convert(_bytesB).toString();

/// 1.2.0+2 for arm64, with [digest] or (null) none, as the manifest says it.
Map<String, Object?> _release(String? digest) => {
  'schema': 1,
  'version': '1.2.0+2',
  'tag': 'v1.2.0',
  'assets': {
    'arm64': {'name': _name, 'size': _bytesA.length, 'sha256': ?digest},
  },
};

UpdateHttpResponse _answer(String? digest) => textResponse(jsonEncode(_release(digest)));

/// Records the SHA-256 of what each `install` call was handed.
class _ReadingInstaller extends FakeInstaller {
  final received = <String>[];

  @override
  Future<InstallResult> install(String path) async {
    received.add(sha256.convert(await File(path).readAsBytes()).toString());
    return super.install(path);
  }
}

/// A check that started and is waiting for its answer.
typedef _HeldCheck = ({Completer<UpdateHttpResponse> answer, Future<UpdateCheckPhase> done});

class _Rig {
  _Rig(this.dir, this.http, this.installer, this.container);

  final Directory dir;
  final FakeHttp http;
  final _ReadingInstaller installer;
  final ProviderContainer container;

  AppUpdateController get controller => container.read(appUpdateProvider.notifier);
  AppUpdateState get state => container.read(appUpdateProvider);
  File get file => File('${dir.path}/$_name');
  File get part => File('${dir.path}/$_name.part');

  Future<String?> cachedDigest() async {
    final raw = (await SharedPreferences.getInstance()).getString('update_latest');
    if (raw == null) return null;
    final assets = (jsonDecode(raw) as Map)['assets'] as Map;
    return (assets['arm64'] as Map)['sha256'] as String?;
  }

  /// Starts a check whose answer waits for [_HeldCheck.answer].
  Future<_HeldCheck> holdCheck() async {
    final answer = Completer<UpdateHttpResponse>();
    final entered = Completer<void>();
    http.routes[_manifest] = (_, _) {
      entered.complete();
      return answer.future;
    };
    final done = controller.check();
    await entered.future.timeout(const Duration(seconds: 5));
    return (answer: answer, done: done);
  }

  /// The APK verified and ready to install.
  Future<void> download() async {
    await controller.startDownload();
    expect(state.task, UpdateTaskPhase.ready);
    expect(sha256.convert(file.readAsBytesSync()).toString(), _hashA);
  }
}

void main() {
  /// [offered] is the digest the first check names (null: none, so the
  /// download takes it from SHA256SUMS, which says hA). The server's APK is A.
  Future<_Rig> rig({String? offered}) async {
    final dir = Directory.systemTemp.createTempSync('dsh_update_digest');
    final http = FakeHttp();
    final installer = _ReadingInstaller();
    // A remembered offer: no first-launch cleanup of the update folder runs
    // under the download.
    SharedPreferences.setMockInitialValues({'update_latest': jsonEncode(_release(offered))});
    http.routes[_manifest] = (_, _) => _answer(offered);
    http.routes[_asset] = fileRoute(_bytesA);
    http.routes[_sums] = (_, _) => textResponse('$_hashA  $_name\n');
    final container = ProviderContainer(
      overrides: [
        updateHttpProvider.overrideWithValue(http),
        updateInstallerProvider.overrideWithValue(installer),
        updateSourcesProvider.overrideWithValue(_sources),
        updateClockProvider.overrideWithValue(() => DateTime(2026, 11, 2, 9)),
        updateFlavorNameProvider.overrideWithValue('arm64'),
        updateDirectoryProvider.overrideWithValue(() async => dir),
      ],
    );
    addTearDown(() {
      container.dispose();
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    final r = _Rig(dir, http, installer, container);
    await r.controller.ready;
    await r.controller.check();
    expect(r.state.asset!.sha256, offered);
    return r;
  }

  /// After a conflict: nothing installed, the APK gone, the attempt failed,
  /// and the offer on screen and in the cache is the one that answered last.
  Future<void> expectThrownAway(_Rig r, {required String shown}) async {
    expect(r.installer.received, isEmpty, reason: 'no APK reaches the installer under a conflicting digest');
    expect(r.state.task, UpdateTaskPhase.failed);
    expect(r.state.problem, UpdateProblem.checksum);
    expect(r.file.existsSync(), isFalse, reason: 'the APK of the other digest is thrown away');
    expect(r.part.existsSync(), isFalse);
    expect(r.state.asset!.sha256, shown);
    expect(await r.cachedDigest(), shown);
    // The ready APK is gone: 「安装」 has nothing to hand over.
    await r.controller.install();
    expect(r.installer.calls, isNot(contains('install')));
  }

  /// 「重试」 downloads afresh against the digest on screen (B now) and
  /// installs exactly those bytes.
  Future<void> expectRetryInstallsB(_Rig r) async {
    r.http.routes[_asset] = fileRoute(_bytesB);
    final downloads = r.http.urls.where((u) => u == _asset).length;
    await r.controller.retry();
    expect(r.http.urls.where((u) => u == _asset).length, downloads + 1, reason: 'downloaded again');
    expect(r.state.task, UpdateTaskPhase.ready);
    await r.controller.install();
    expect(r.installer.received, [_hashB]);
    expect(r.state.task, UpdateTaskPhase.idle);
  }

  group('U1: the offer on screen, the bytes verified and the APK installed are one', () {
    test('a download pins the digest it took from SHA256SUMS to the offer on screen and in the cache', () async {
      final r = await rig();
      await r.download();
      expect(r.http.urls, contains(_sums));
      expect(r.state.asset!.sha256, _hashA);
      expect(await r.cachedDigest(), _hashA);
    });

    test('CR-e0b8ece U1: a conflicting digest filled in while the install waits on its checks fails it and throws the APK away', () async {
      final r = await rig();
      await r.download();
      final check = await r.holdCheck();

      final inspect = r.installer.pendingInspect = Completer<ApkInspection>();
      final installing = r.controller.install();
      await r.installer.called('inspect').timeout(const Duration(seconds: 5));
      expect(r.state.task, UpdateTaskPhase.installing);
      // Same version, same file name, another digest. No file is touched.
      check.answer.complete(_answer(_hashB));
      await check.done;
      inspect.complete(r.installer.inspection);
      await installing;

      await expectThrownAway(r, shown: _hashB);
      r.installer.pendingInspect = null;
      await expectRetryInstallsB(r);
    });

    test('the same digest filled in while the install waits changes nothing', () async {
      final r = await rig();
      await r.download();
      final check = await r.holdCheck();
      final inspect = r.installer.pendingInspect = Completer<ApkInspection>();
      final installing = r.controller.install();
      await r.installer.called('inspect');

      check.answer.complete(_answer(_hashA));
      await check.done;
      inspect.complete(r.installer.inspection);
      await installing;
      expect(r.installer.received, [_hashA]);
      expect(r.state.task, UpdateTaskPhase.idle);
      expect(r.state.asset!.sha256, _hashA);
    });

    test('an answer without a digest keeps the known one, on screen and in the cache', () async {
      final r = await rig(offered: _hashA);
      await r.download();
      final check = await r.holdCheck();
      final inspect = r.installer.pendingInspect = Completer<ApkInspection>();
      final installing = r.controller.install();
      await r.installer.called('inspect');

      check.answer.complete(_answer(null));
      await check.done;
      expect(r.state.asset!.sha256, _hashA, reason: 'unknown is not a different digest, nor a reason to forget one');
      expect(await r.cachedDigest(), _hashA);
      inspect.complete(r.installer.inspection);
      await installing;
      expect(r.installer.received, [_hashA]);
    });

    test('a pinned digest is kept by a later answer without one, with the APK ready', () async {
      final r = await rig();
      await r.download();
      await r.controller.check();
      expect(r.state.asset!.sha256, _hashA);
      expect(await r.cachedDigest(), _hashA);
      expect(r.state.task, UpdateTaskPhase.ready);
      await r.controller.install();
      expect(r.installer.received, [_hashA]);
    });

    test('two known digests for the same file while the install waits: it fails and the APK goes', () async {
      final r = await rig(offered: _hashA);
      await r.download();
      final check = await r.holdCheck();
      final inspect = r.installer.pendingInspect = Completer<ApkInspection>();
      final installing = r.controller.install();
      await r.installer.called('inspect');

      check.answer.complete(_answer(_hashB));
      await check.done;
      inspect.complete(r.installer.inspection);
      await installing;
      await expectThrownAway(r, shown: _hashB);
    });

    test('a conflicting digest during the SHA256SUMS lookup fails the download', () async {
      final r = await rig();
      final check = await r.holdCheck();
      final sums = Completer<UpdateHttpResponse>();
      final sumsAsked = Completer<void>();
      r.http.routes[_sums] = (_, _) {
        sumsAsked.complete();
        return sums.future;
      };
      final downloading = r.controller.startDownload();
      await sumsAsked.future.timeout(const Duration(seconds: 5));

      check.answer.complete(_answer(_hashB));
      await check.done;
      sums.complete(textResponse('$_hashA  $_name\n'));
      await downloading;
      expect(r.http.urls, isNot(contains(_asset)), reason: 'nothing downloaded against either digest');
      await expectThrownAway(r, shown: _hashB);
      await expectRetryInstallsB(r);
    });

    test('a conflicting digest while the bytes download stops it and throws them away', () async {
      for (final offered in [_hashA, null]) {
        final r = await rig(offered: offered);
        final check = await r.holdCheck();
        final bytes = Completer<void>();
        final asked = Completer<void>();
        r.http.routes[_asset] = (_, _) {
          asked.complete();
          Stream<List<int>> body() async* {
            yield _bytesA.sublist(0, 8);
            await bytes.future;
            yield _bytesA.sublist(8);
          }

          return UpdateHttpResponse(status: 200, contentLength: _bytesA.length, body: body());
        };
        final downloading = r.controller.startDownload();
        await asked.future.timeout(const Duration(seconds: 5));
        expect(r.state.asset!.sha256, _hashA, reason: 'offered or pinned from SHA256SUMS');

        check.answer.complete(_answer(_hashB));
        await check.done;
        if (!bytes.isCompleted) bytes.complete();
        await downloading;
        await expectThrownAway(r, shown: _hashB);
        await expectRetryInstallsB(r);
      }
    });

    test('a conflicting digest for a ready APK nobody is installing throws it away', () async {
      for (final offered in [_hashA, null]) {
        final r = await rig(offered: offered);
        await r.download();
        r.http.routes[_manifest] = (_, _) => _answer(_hashB);
        await r.controller.check();
        await expectThrownAway(r, shown: _hashB);
        await expectRetryInstallsB(r);
      }
    });

    test('a conflicting digest after the APK went to the system installer: unfinished, it is thrown away', () async {
      final r = await rig();
      await r.download();
      final check = await r.holdCheck();
      final dialog = r.installer.pending = Completer<InstallResult>();
      final installing = r.controller.install();
      await r.installer.called('install');
      // Handed over while the offer on screen still named A.
      expect(r.installer.received, [_hashA]);

      check.answer.complete(_answer(_hashB));
      await check.done;
      expect(r.state.task, UpdateTaskPhase.installing, reason: 'the system installer still has it');
      dialog.complete(const InstallResult(InstallStatus.aborted));
      await installing;
      expect(r.state.task, UpdateTaskPhase.failed);
      expect(r.state.problem, UpdateProblem.checksum);
      expect(r.file.existsSync(), isFalse);
      expect(r.state.asset!.sha256, _hashB);
      r.installer.pending = null;
      r.installer.received.clear();
      await expectRetryInstallsB(r);
    });
  });
}

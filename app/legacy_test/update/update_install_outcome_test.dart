import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dsh_app/state/update_state.dart';
import 'package:dsh_app/update/installer.dart';
import 'package:dsh_app/update/update_config.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support.dart';

const _name = 'dsh-go-1.2.0-arm64.apk';
const _url = 'https://github.com/ccch1mneyyy/dsh-go/releases/download/v1.2.0/$_name';
final _bytes = utf8.encode('fixed host-only update test bytes');

void main() {
  late Directory directory;
  late FakeInstaller installer;
  late ProviderContainer container;
  late AppUpdateController controller;
  late bool disposed;

  setUp(() async {
    disposed = false;
    directory = Directory.systemTemp.createTempSync('update-result-');
    installer = FakeInstaller();
    SharedPreferences.setMockInitialValues({
      'update_latest': jsonEncode({
        'schema': 1,
        'version': '1.2.0',
        'tag': 'v1.2.0',
        'notes': '',
        'assets': {
          'arm64': {'name': _name, 'size': _bytes.length, 'sha256': sha256.convert(_bytes).toString()},
        },
      }),
    });
    container = ProviderContainer(
      overrides: [
        updateHttpProvider.overrideWithValue(FakeHttp({_url: fileRoute(_bytes)})),
        updateInstallerProvider.overrideWithValue(installer),
        updateSourcesProvider.overrideWithValue(const UpdateSources(mirrors: [UpdateMirror.github])),
        updateFlavorNameProvider.overrideWithValue('arm64'),
        updateDirectoryProvider.overrideWithValue(() async => directory),
      ],
    );
    controller = container.read(appUpdateProvider.notifier);
    await controller.ready;
    await controller.startDownload();
    expect(container.read(appUpdateProvider).task, UpdateTaskPhase.ready);
  });

  tearDown(() async {
    if (!disposed) container.dispose();
    await directory.delete(recursive: true);
  });

  void unconfirmed() {
    final state = container.read(appUpdateProvider);
    expect(state.task, UpdateTaskPhase.ready);
    // Name keeps this same regression runnable against the original enum.
    expect(state.problem?.name, 'installUnconfirmed');
    expect(state.problem, isNot(UpdateProblem.installCancelled));
    expect(File('${directory.path}/$_name').existsSync(), isTrue);
  }

  test('resume while inspect is pending reports unknown, never user cancellation', () async {
    final pending = installer.pendingInspect = Completer<ApkInspection>();
    final installing = controller.install();
    await installer.called('inspect');
    await controller.onAppResumed(confirmGrace: Duration.zero);
    unconfirmed();
    expect(installer.calls.where((call) => call == 'install'), isEmpty);
    pending.complete(const ApkInspection(valid: false));
    await installing;
    unconfirmed();
  });

  for (final late in [InstallStatus.success, InstallStatus.invalid]) {
    test('no native result stays unknown after a late $late and permits system fallback', () async {
      final pending = installer.pending = Completer<InstallResult>();
      final installing = controller.install();
      await installer.called('install');
      await controller.onAppResumed(confirmGrace: Duration.zero);
      unconfirmed();
      expect(await controller.installWithSystem(), isTrue);
      expect(installer.calls.last, 'openWithSystemInstaller');
      pending.complete(InstallResult(late));
      await installing;
      unconfirmed();
    });
  }

  test('late exception and repeated resumes cannot cancel a newer attempt', () async {
    final first = installer.pending = Completer<InstallResult>();
    final firstRun = controller.install();
    await installer.called('install');
    await Future.wait([
      controller.onAppResumed(confirmGrace: Duration.zero),
      controller.onAppResumed(confirmGrace: Duration.zero),
    ]);
    unconfirmed();
    final second = installer.pending = Completer<InstallResult>();
    final secondRun = controller.install();
    await installer.called('install', times: 2);
    first.completeError(StateError('late fixed test error'));
    await firstRun;
    expect(container.read(appUpdateProvider).task, UpdateTaskPhase.installing);
    expect(container.read(appUpdateProvider).problem, isNull);
    second.complete(const InstallResult(InstallStatus.aborted));
    await secondRun;
    expect(container.read(appUpdateProvider).task, UpdateTaskPhase.ready);
    expect(container.read(appUpdateProvider).problem, UpdateProblem.installCancelled);
    expect(File('${directory.path}/$_name').existsSync(), isTrue);
  });

  test('an explicit native abort keeps cancellation and system fallback', () async {
    installer.result = const InstallResult(InstallStatus.aborted);
    await controller.install();
    expect(container.read(appUpdateProvider).problem, UpdateProblem.installCancelled);
    await controller.onAppResumed(confirmGrace: Duration.zero);
    expect(container.read(appUpdateProvider).problem, UpdateProblem.installCancelled);
    expect(await controller.installWithSystem(), isTrue);
  });

  test('system fallback does not open after another install starts during its file check', () async {
    final inspection = installer.pendingInspect = Completer<ApkInspection>();
    final opening = controller.installWithSystem();
    final installing = controller.install();

    final opened = await opening;
    await installer.called('inspect');
    inspection.complete(installer.inspection);
    await installing;

    expect(opened, isFalse);
    expect(installer.calls, isNot(contains('openWithSystemInstaller')));
    expect(installer.calls.where((call) => call == 'install'), hasLength(1));
  });

  test('system fallback retires quietly when its provider is disposed during the file check', () async {
    final opening = controller.installWithSystem();
    container.dispose();
    disposed = true;

    await expectLater(opening, completion(isFalse));
    expect(installer.calls, isNot(contains('openWithSystemInstaller')));
  });
}

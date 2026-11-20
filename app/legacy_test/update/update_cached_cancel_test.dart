import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dsh_app/state/update_state.dart';
import 'package:dsh_app/update/update_config.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support.dart';

const _name = 'dsh-go-1.2.0-arm64.apk';
const _url = 'https://github.com/ccch1mneyyy/dsh-go/releases/download/v1.2.0/$_name';
final _bytes = utf8.encode('PK a cached update, checked by the real file hasher');
final _wrong = utf8.encode('PK another cached file');

Map<String, Object?> _offer() => {
  'schema': 1,
  'version': '1.2.0',
  'tag': 'v1.2.0',
  'assets': {
    'arm64': {'name': _name, 'size': _bytes.length, 'sha256': sha256.convert(_bytes).toString()},
  },
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> exercise({required bool cancel, List<int>? cached}) async {
    final dir = Directory.systemTemp.createTempSync('dsh_update_cached_cancel');
    final target = File('${dir.path}/$_name');
    if (cached != null) target.writeAsBytesSync(cached);
    // A remembered offer keeps startup cleanup out of this download. The
    // directory seam is the production getTemporaryDirectory await, while
    // the controller still exposes its normal downloading/cancel action.
    SharedPreferences.setMockInitialValues({'update_latest': jsonEncode(_offer())});
    final http = FakeHttp({_url: fileRoute(_bytes)});
    final installer = FakeInstaller();
    final entered = Completer<void>();
    final directory = Completer<Directory>();
    final container = ProviderContainer(
      overrides: [
        updateHttpProvider.overrideWithValue(http),
        updateInstallerProvider.overrideWithValue(installer),
        updateSourcesProvider.overrideWithValue(const UpdateSources(mirrors: [UpdateMirror.github])),
        updateFlavorNameProvider.overrideWithValue('arm64'),
        updateDirectoryProvider.overrideWithValue(() {
          entered.complete();
          return directory.future;
        }),
      ],
    );
    Future<void>? downloading;
    try {
      final controller = container.read(appUpdateProvider.notifier);
      await controller.ready;
      expect(container.read(appUpdateProvider).hasUpdate, isTrue);
      final phases = <UpdateTaskPhase>[];
      container.listen(appUpdateProvider, (_, next) => phases.add(next.task));
      downloading = controller.startDownload();
      await entered.future;
      expect(container.read(appUpdateProvider).task, UpdateTaskPhase.downloading);
      if (cancel) controller.cancelDownload();
      directory.complete(dir);
      await downloading;

      final state = container.read(appUpdateProvider);
      expect(state.task, cancel ? UpdateTaskPhase.idle : UpdateTaskPhase.ready);
      expect(installer.installed, isEmpty, reason: 'no test calls install');
      if (cancel) {
        expect(target.existsSync(), cached != null);
        if (cached != null) expect(target.readAsBytesSync(), cached);
        expect(phases, isNot(contains(UpdateTaskPhase.verifying)));
        expect(http.requests, isEmpty);
      } else {
        expect(phases, contains(UpdateTaskPhase.verifying));
        expect(target.readAsBytesSync(), _bytes);
        expect(http.requests, hasLength(identical(cached, _bytes) ? 0 : 1));
      }
    } finally {
      if (!directory.isCompleted) directory.complete(dir);
      await downloading;
      container.dispose();
      dir.deleteSync(recursive: true);
    }
  }

  test('cancel during preparation does not reuse a valid cached APK', () => exercise(cancel: true, cached: _bytes));
  test(
    'cancel during preparation leaves an unverified cached file alone',
    () => exercise(cancel: true, cached: _wrong),
  );
  test('cancel without a cached APK remains idle without HTTP', () => exercise(cancel: true));
  test('an uncancelled valid cache is still verified and reused', () => exercise(cancel: false, cached: _bytes));
  test('an uncancelled invalid cache still downloads and verifies', () => exercise(cancel: false, cached: _wrong));
}

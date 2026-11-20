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
final _bytes = utf8.encode('PK a complete update awaiting its file operation');

enum _Operation { close, rename }

/// Holds delivery of one real file operation's completion, not its result.
class _CompletionGate {
  final entered = Completer<void>();
  final release = Completer<void>();

  Future<void> wait() async {
    if (entered.isCompleted) return;
    entered.complete();
    await release.future;
  }
}

class _GatedSink implements IOSink {
  _GatedSink(this.inner, this.gate);

  final IOSink inner;
  final _CompletionGate gate;

  @override
  void add(List<int> data) => inner.add(data);

  @override
  Future<void> get done => inner.done;

  @override
  Future<void> close() async {
    await inner.close();
    await gate.wait();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError('${invocation.memberName}');
}

class _GatedPart implements File {
  _GatedPart(this.inner, this.operation, this.gate);

  final File inner;
  final _Operation operation;
  final _CompletionGate gate;

  @override
  String get path => inner.path;

  @override
  Future<bool> exists() => inner.exists();

  @override
  Future<int> length() => inner.length();

  @override
  Future<FileSystemEntity> delete({bool recursive = false}) => inner.delete(recursive: recursive);

  @override
  IOSink openWrite({FileMode mode = FileMode.write, Encoding encoding = utf8}) {
    final sink = inner.openWrite(mode: mode, encoding: encoding);
    return operation == _Operation.close ? _GatedSink(sink, gate) : sink;
  }

  @override
  Future<File> rename(String newPath) async {
    final file = await inner.rename(newPath);
    if (operation == _Operation.rename) await gate.wait();
    return file;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError('${invocation.memberName}');
}

final class _Files extends IOOverrides {
  _Files(this.partPath, this.operation, this.gate);

  final String partPath;
  final _Operation operation;
  final _CompletionGate gate;

  @override
  File createFile(String path) {
    final file = super.createFile(path);
    return path == partPath ? _GatedPart(file, operation, gate) : file;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> exercise(_Operation operation, {required bool cancel}) async {
    final dir = Directory.systemTemp.createTempSync('dsh_update_file_completion_');
    final target = File('${dir.path}/$_name');
    final part = File('${target.path}.part');
    final gate = _CompletionGate();
    SharedPreferences.setMockInitialValues({
      'update_latest': jsonEncode({
        'schema': 1,
        'version': '1.2.0',
        'tag': 'v1.2.0',
        'assets': {
          'arm64': {'name': _name, 'size': _bytes.length, 'sha256': sha256.convert(_bytes).toString()},
        },
      }),
    });
    // The existing HTTP seam supplies finite bytes. File writes, close,
    // rename, and the resumed download's isolated SHA-256 are all real.
    final http = FakeHttp({_url: fileRoute(_bytes)});
    final installer = FakeInstaller();
    final container = ProviderContainer(
      overrides: [
        updateHttpProvider.overrideWithValue(http),
        updateInstallerProvider.overrideWithValue(installer),
        updateSourcesProvider.overrideWithValue(const UpdateSources(mirrors: [UpdateMirror.github])),
        updateFlavorNameProvider.overrideWithValue('arm64'),
        updateDirectoryProvider.overrideWithValue(() async => dir),
      ],
    );
    Future<void>? downloading;
    try {
      final controller = container.read(appUpdateProvider.notifier);
      await controller.ready;
      final phases = <UpdateTaskPhase>[];
      container.listen(appUpdateProvider, (_, next) => phases.add(next.task));
      downloading = IOOverrides.runWithIOOverrides(controller.startDownload, _Files(part.path, operation, gate));
      await gate.entered.future;
      expect(container.read(appUpdateProvider).task, UpdateTaskPhase.downloading);
      expect((operation == _Operation.close ? part : target).readAsBytesSync(), _bytes);
      if (cancel) controller.cancelDownload();
      gate.release.complete();
      await downloading;

      expect(container.read(appUpdateProvider).task, cancel ? UpdateTaskPhase.idle : UpdateTaskPhase.ready);
      if (cancel) {
        expect(phases, isNot(contains(UpdateTaskPhase.verifying)));
        await controller.install();
        expect(installer.installed, isEmpty, reason: 'a cancelled file must not become an installable offer');
        phases.clear();
        await controller.startDownload();
        expect(container.read(appUpdateProvider).task, UpdateTaskPhase.ready);
        expect(phases, contains(UpdateTaskPhase.verifying));
      }
      expect(target.readAsBytesSync(), _bytes);
      expect(http.requests, hasLength(1), reason: 'resuming a complete file still verifies it without another request');
      expect(installer.installed, isEmpty);
    } finally {
      if (!gate.release.isCompleted) gate.release.complete();
      await downloading;
      container.dispose();
      dir.deleteSync(recursive: true);
    }
  }

  for (final operation in _Operation.values) {
    test(
      'cancel while ${operation.name} is pending stays idle and permits verified reuse',
      () => exercise(operation, cancel: true),
    );
    test(
      'uncancelled ${operation.name} completion still makes the verified file ready',
      () => exercise(operation, cancel: false),
    );
  }
}

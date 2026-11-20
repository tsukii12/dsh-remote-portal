// The on-device source against a real temp rootfs: inotify, debounce, atomic
// renames, deletion, the runtime coming and going, ui.status.json.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/ui_config/ui_config.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

void main() {
  late Directory root;
  late List<UiConfigRead> reads;
  late StreamController<void> kicks;
  late LocalUiConfigSource source;
  StreamSubscription<UiConfigRead>? sub;
  Directory? rootfs;

  File config() => File('${root.path}/root/.dsh/dsh-go/ui.json');

  void start() {
    source = LocalUiConfigSource(
      rootfs: () async => rootfs,
      kicks: kicks.stream,
      debounce: const Duration(milliseconds: 50),
    );
    sub = source.watch().listen(reads.add);
  }

  setUp(() {
    root = tempRootfs();
    rootfs = root;
    reads = [];
    kicks = StreamController<void>.broadcast();
  });

  tearDown(() async {
    await sub?.cancel();
    sub = null;
    await kicks.close();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  String? lastText() => switch (reads.lastOrNull) {
    UiConfigText(:final text) => text,
    _ => null,
  };

  test('no file yet: creates dsh-go/, reports absent, then follows the file', () async {
    start();
    await until(() => reads.isNotEmpty);
    expect(reads.last, isA<UiConfigAbsent>());
    expect(Directory('${root.path}/root/.dsh/dsh-go').existsSync(), isTrue);

    config().writeAsStringSync('{"version": 1, "density": "compact"}');
    await until(() => lastText() != null);
    expect(lastText(), '{"version": 1, "density": "compact"}');
    expect((reads.last as UiConfigText).version, isNotNull);

    config().writeAsStringSync('{"version": 1, "density": "comfortable"}');
    await until(() => lastText() == '{"version": 1, "density": "comfortable"}');

    config().deleteSync();
    await until(() => reads.last is UiConfigAbsent);
  });

  test('a burst of writes settles into one read', () async {
    config().parent.createSync(recursive: true);
    config().writeAsStringSync('{"version": 1}');
    start();
    await until(() => lastText() != null);
    final before = reads.length;
    for (var i = 0; i < 10; i++) {
      config().writeAsStringSync('{"version": 1, "hide": ["whaleTail"], "n": $i}');
    }
    await until(() => lastText()?.contains('"n": 9') ?? false);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(reads.length - before, lessThanOrEqualTo(2));
  });

  test('an editor\'s write-then-rename is picked up', () async {
    config().parent.createSync(recursive: true);
    start();
    await until(() => reads.isNotEmpty);
    final tmp = File('${config().parent.path}/.ui.json.swp')
      ..writeAsStringSync('{"version": 1, "theme": {"mode": "dark"}}');
    tmp.renameSync(config().path);
    await until(() => lastText()?.contains('dark') ?? false);
  });

  test('other files in dsh-go/ are not reads', () async {
    config().parent.createSync(recursive: true);
    config().writeAsStringSync('{"version": 1}');
    start();
    await until(() => lastText() != null);
    final before = reads.length;
    File('${config().parent.path}/notes.txt').writeAsStringSync('x');
    await source.writeStatus(parseUiConfig('{"version": 1}'));
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(reads.length, before);
  });

  test('larger than 64 KiB: broken without reading it', () async {
    config().parent.createSync(recursive: true);
    config().writeAsStringSync('{"version": 1, "x": "${'a' * (65 * 1024)}"}');
    start();
    await until(() => reads.isNotEmpty);
    expect(reads.last, isA<UiConfigBroken>().having((b) => b.message, 'message', '文件超过 64 KiB'));
  });

  test('before the runtime is installed: noRuntime; afterwards a kick finds the file', () async {
    rootfs = null;
    start();
    await until(() => reads.isNotEmpty);
    expect(
      reads.last,
      isA<UiConfigUnavailable>().having((u) => u.reason, 'reason', UiConfigUnavailableReason.noRuntime),
    );

    config().parent.createSync(recursive: true);
    config().writeAsStringSync('{"version": 1, "density": "compact"}');
    rootfs = root;
    kicks.add(null);
    await until(() => lastText() != null);
    config().writeAsStringSync('{"version": 1, "density": "comfortable"}');
    await until(() => lastText()?.contains('comfortable') ?? false);
  });

  test('DSH home missing (engine never ran): no directory is made', () async {
    root.deleteSync(recursive: true);
    root = tempRootfs(withHome: false);
    rootfs = root;
    start();
    await until(() => reads.isNotEmpty);
    expect(reads.last, isA<UiConfigAbsent>());
    expect(Directory('${root.path}/root/.dsh').existsSync(), isFalse);
  });

  test('while an install moves /root around nothing is created or written', () async {
    var installing = true;
    source = LocalUiConfigSource(
      rootfs: () async => root,
      kicks: kicks.stream,
      debounce: const Duration(milliseconds: 50),
      mayWrite: () => !installing,
    );
    sub = source.watch().listen(reads.add);
    await until(() => reads.isNotEmpty);
    expect(Directory('${root.path}/root/.dsh/dsh-go').existsSync(), isFalse);
    installing = false;
    kicks.add(null);
    await until(() => Directory('${root.path}/root/.dsh/dsh-go').existsSync());
    config().writeAsStringSync('{"version": 1}');
    await until(() => lastText() != null);
    installing = true;
    await source.writeStatus(parseUiConfig(lastText()!));
    expect(File('${config().parent.path}/ui.status.json').existsSync(), isFalse);
  });

  test('the folder vanishing (runtime reset) and coming back', () async {
    config().parent.createSync(recursive: true);
    config().writeAsStringSync('{"version": 1}');
    start();
    await until(() => lastText() != null);
    Directory('${root.path}/root').deleteSync(recursive: true);
    await until(() => reads.last is UiConfigAbsent);
    config().parent.createSync(recursive: true);
    config().writeAsStringSync('{"version": 1, "density": "compact"}');
    kicks.add(null);
    await until(() => lastText()?.contains('compact') ?? false);
    config().writeAsStringSync('{"version": 1, "density": "comfortable"}');
    await until(() => lastText()?.contains('comfortable') ?? false);
  });

  test('ui.status.json mirrors what the app applied, and goes with the file', () async {
    config().parent.createSync(recursive: true);
    config().writeAsStringSync('{"version": 1, "density": "cozy"}');
    start();
    await until(() => lastText() != null);
    final load = parseUiConfig(lastText()!);
    await source.writeStatus(load);
    final status = File('${config().parent.path}/ui.status.json');
    final body = jsonDecode(status.readAsStringSync()) as Map;
    expect(body['applied'], 0);
    expect(body['fatal'], false);
    expect(body['issues'], [
      {'pointer': '/density', 'kind': 'invalid', 'message': '不支持的值「cozy」，可选：compact、comfortable'},
    ]);
    expect(body['readAt'], isA<String>());
    await source.writeStatus(null);
    expect(status.existsSync(), isFalse);
    await source.writeStatus(load);
    expect(jsonDecode(status.readAsStringSync()), body);
    status.deleteSync();
    await source.writeStatus(load);
    expect(jsonDecode(status.readAsStringSync()), body);
  });

  test('a successful status body is not rewritten for a later readAt', () async {
    const text = '{"version": 1, "density": "compact"}';
    config().parent.createSync(recursive: true);
    config().writeAsStringSync(text);
    start();
    await until(() => lastText() != null);
    final firstReadAt = DateTime.utc(2026, 1, 1);
    await source.writeStatus(parseUiConfig(text, readAt: firstReadAt));
    final status = File('${config().parent.path}/ui.status.json');
    final original = status.readAsStringSync();
    final body = jsonDecode(original) as Map;
    expect(body['applied'], 1);
    expect(body['readAt'], firstReadAt.toIso8601String());
    status.setLastModifiedSync(DateTime.utc(2000));
    final modified = status.lastModifiedSync();

    await source.writeStatus(parseUiConfig(text, readAt: firstReadAt.add(const Duration(hours: 1))));

    expect(status.readAsStringSync(), original);
    expect(status.lastModifiedSync(), modified);
  });

  test('a failed status replacement can retry the same body', () async {
    config().parent.createSync(recursive: true);
    config().writeAsStringSync('{"version": 1}');
    start();
    await until(() => lastText() != null);
    final initial = parseUiConfig(lastText()!);
    final latest = parseUiConfig('{"version": 1, "density": "compact"}');
    await source.writeStatus(initial);
    final status = File('${config().parent.path}/ui.status.json');
    final original = status.readAsStringSync();
    final obstacle = Directory('${status.path}.tmp')..createSync();
    expect(() => File(obstacle.path).writeAsStringSync('control', flush: true), throwsA(isA<FileSystemException>()));

    await source.writeStatus(latest);
    expect(status.readAsStringSync(), original);
    obstacle.deleteSync();
    await source.writeStatus(latest);

    final retried = jsonDecode(status.readAsStringSync()) as Map;
    expect(retried['applied'], latest.appliedCount);
    expect(retried['readAt'], latest.readAt.toUtc().toIso8601String());
  });
}

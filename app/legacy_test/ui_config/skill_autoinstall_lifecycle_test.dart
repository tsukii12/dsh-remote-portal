// Integrated lifecycle cases. The original pre-change probe is preserved byte-for-byte in Phase2 evidence.
import 'dart:async';
import 'dart:io';

import 'package:dsh_app/runtime/runtime_bridge.dart';
import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/ui_config/ui_config.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart' show tempRootfs, until;

UiSkillBundle _bundle(String value) =>
    UiSkillBundle({'SKILL.md': '---\n# dsh-go:managed\nname: dsh-go-ui\n---\n$value\n', 'value.txt': value});

class _Runtime extends LocalRuntimeController {
  @override
  LocalRuntimeState build() => _value(RuntimePhase.installed, 'initial');
  LocalRuntimeState _value(RuntimePhase phase, String token) => LocalRuntimeState(
    loaded: true,
    status: RuntimeStatus(
      phase: phase,
      installedVersion: 'test-runtime',
      baseUrl: 'http://127.0.0.1:1',
      token: token,
      managedSkillGeneration: token == 'run-two' ? 2 : 1,
    ),
  );
  void emit(RuntimePhase phase, [String token = 'run-one']) => state = _value(phase, token);
}

class _Harness {
  _Harness(this.loader) {
    root = tempRootfs();
    currentRoot = root;
    c = ProviderContainer(
      overrides: [
        localRuntimeProvider.overrideWith(() => runtime),
        uiRootfsResolverProvider.overrideWithValue(() async => currentRoot),
        uiSkillBundleLoaderProvider.overrideWithValue(() async {
          loads++;
          return loader(loads);
        }),
        extraSkillLoadersProvider.overrideWithValue(const []),
      ],
    );
    c.listen(uiSkillAutoInstallProvider, (_, _) {});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('dsh/runtime'),
      (call) async {
        if (call.method == 'cancelManagedSkill') {
          cancelled.add((call.arguments as Map)['requestId'] as String);
          return null;
        }
        if (call.method != 'installManagedSkill') throw StateError('unexpected method ${call.method}');
        final args = call.arguments as Map;
        bool current() =>
            !disposed &&
            !cancelled.contains(args['requestId']) &&
            c.read(localRuntimeProvider).status.phase == RuntimePhase.running &&
            c.read(localRuntimeProvider).status.token == args['expectedToken'] &&
            c.read(localRuntimeProvider).status.managedSkillGeneration == args['expectedGeneration'];
        if (!current()) return {'result': null, 'current': false};
        final result = await installUiSkill(
          Directory(args['expectedRoot'] as String),
          UiSkillBundle((args['files'] as Map).cast<String, String>(), name: args['name'] as String),
        );
        return {'result': result.name, 'current': current()};
      },
    );
  }
  final Future<UiSkillBundle> Function(int call) loader;
  final runtime = _Runtime();
  late final Directory root;
  late Directory currentRoot;
  late final ProviderContainer c;
  final cancelled = <String>{};
  var loads = 0;
  var disposed = false;

  Future<void> begin([String token = 'run-one']) async {
    runtime.emit(RuntimePhase.running, token);
    await until(() => loads > 0);
  }

  Future<void>? get running => c.read(uiSkillAutoInstallProvider.notifier).running;
  File skill(Directory dir) => File('${dir.path}/root/.dsh/skills/dsh-go-ui/SKILL.md');
  void dispose() {
    if (!disposed) {
      disposed = true;
      c.dispose();
    }
  }

  Future<void> close() async {
    dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('dsh/runtime'),
      null,
    );
    if (root.existsSync()) root.deleteSync(recursive: true);
    if (currentRoot.path != root.path && currentRoot.existsSync()) currentRoot.deleteSync(recursive: true);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('late asset load cannot write a replacement root after installing begins', () async {
    final held = Completer<UiSkillBundle>();
    final h = _Harness((_) => held.future);
    Directory? retired;
    try {
      await h.begin();
      final running = h.running;
      h.runtime.emit(RuntimePhase.installing);
      await h.c.pump();
      retired = h.root.renameSync('${h.root.path}.retired');
      Directory('${h.root.path}/root/.dsh').createSync(recursive: true);
      held.complete(_bundle('old run'));
      await running;
      expect(h.skill(h.root).existsSync(), isFalse, reason: 'a late old loader cannot populate newly activated root');
    } finally {
      if (!held.isCompleted) held.complete(_bundle('cleanup'));
      await h.close();
      if (retired?.existsSync() == true) retired!.deleteSync(recursive: true);
    }
  });

  test('disposing the installer retires a loader before any file writes', () async {
    final held = Completer<UiSkillBundle>();
    final h = _Harness((_) => held.future);
    try {
      await h.begin();
      final running = h.running;
      h.dispose();
      held.complete(_bundle('old disposed scope'));
      await running;
      expect(h.skill(h.root).existsSync(), isFalse);
    } finally {
      if (!held.isCompleted) held.complete(_bundle('cleanup'));
      await h.close();
    }
  });

  test('stop then new ready coalesces one latest root instead of dropping it', () async {
    final held = Completer<UiSkillBundle>();
    final h = _Harness((call) => call == 1 ? held.future : Future.value(_bundle('new run')));
    try {
      await h.begin();
      final running = h.running;
      h.runtime.emit(RuntimePhase.installed);
      await h.c.pump();
      h.currentRoot = tempRootfs();
      h.runtime.emit(RuntimePhase.running, 'run-two');
      await h.c.pump();
      held.complete(_bundle('old run'));
      await running;
      expect(h.skill(h.root).existsSync(), isFalse, reason: 'retired root receives no late writes');
      expect(
        h.skill(h.currentRoot).existsSync(),
        isTrue,
        reason: 'latest ready must not be lost behind old in-flight work',
      );
      expect(h.skill(h.currentRoot).readAsStringSync(), contains('new run'));
      expect(h.loads, 2);
    } finally {
      if (!held.isCompleted) held.complete(_bundle('cleanup'));
      await h.close();
    }
  });

  test('normal run installs and duplicate running status remains deduplicated', () async {
    final h = _Harness((_) async => _bundle('normal'));
    try {
      await h.begin();
      await h.running;
      h.runtime.emit(RuntimePhase.running);
      await h.c.pump();
      await h.running;
      expect(h.skill(h.root).readAsStringSync(), contains('normal'));
      expect(h.loads, 1);
    } finally {
      await h.close();
    }
  });

  test('a failed load is retried on the next engine start', () async {
    final h = _Harness((call) async {
      if (call == 1) throw StateError('fixture load failure');
      return _bundle('retry');
    });
    try {
      await h.begin();
      await h.running;
      h.runtime.emit(RuntimePhase.installed);
      await h.c.pump();
      h.runtime.emit(RuntimePhase.running, 'run-two');
      await h.c.pump();
      await h.running;
      expect(h.skill(h.root).readAsStringSync(), contains('retry'));
      expect(h.loads, 2);
    } finally {
      await h.close();
    }
  });
}

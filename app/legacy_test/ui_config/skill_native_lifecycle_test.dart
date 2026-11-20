import 'dart:async';
import 'dart:io';

import 'package:dsh_app/runtime/runtime_bridge.dart';
import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/ui_config/ui_config.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart' show tempRootfs;

UiSkillBundle bundle([String name = uiSkillName]) =>
    UiSkillBundle({'SKILL.md': '---\n# dsh-go:managed\nname: $name\n---\nfixture\n'}, name: name);

class Runtime extends LocalRuntimeController {
  @override
  LocalRuntimeState build() => const LocalRuntimeState(loaded: true);
  void emit(RuntimePhase phase, {String? token = 'one', int generation = 1}) => state = LocalRuntimeState(
    loaded: true,
    status: RuntimeStatus(
      phase: phase,
      baseUrl: 'http://127.0.0.1:1',
      token: token,
      managedSkillGeneration: generation,
    ),
  );
}

class Request {
  Request(this.id, this.token, this.name, this.root, this.generation);
  final String id;
  final String token;
  final String name;
  final String root;
  final int? generation;
  final completion = Completer<ManagedSkillInstallResponse>();
  void complete({String result = 'installed', bool current = true}) {
    completion.complete(ManagedSkillInstallResponse(result: result, current: current));
  }
}

class Bridge extends RuntimeBridge {
  final requests = <Request>[];
  final cancelled = <String>[];
  void Function(Request)? onRequest;

  @override
  Future<ManagedSkillInstallResponse> installManagedSkill({
    required String requestId,
    required String expectedRoot,
    required String expectedToken,
    required int? expectedGeneration,
    required String name,
    required Map<String, String> files,
  }) {
    final request = Request(requestId, expectedToken, name, expectedRoot, expectedGeneration);
    requests.add(request);
    onRequest?.call(request);
    return request.completion.future;
  }

  @override
  Future<void> cancelManagedSkill(String requestId) async => cancelled.add(requestId);
}

class Harness {
  Harness({
    Future<Directory?> Function()? resolve,
    UiSkillBundleLoader? load,
    List<UiSkillBundleLoader> extras = const [],
    RuntimeBridge? bridgeOverride,
  }) {
    c = ProviderContainer(
      overrides: [
        localRuntimeProvider.overrideWith(() => runtime),
        runtimeBridgeProvider.overrideWithValue(bridgeOverride ?? bridge),
        uiRootfsResolverProvider.overrideWithValue(resolve ?? () async => root),
        uiSkillBundleLoaderProvider.overrideWithValue(() async {
          loads++;
          return load == null ? bundle() : await load();
        }),
        extraSkillLoadersProvider.overrideWithValue(extras),
      ],
    );
    c.listen(uiSkillAutoInstallProvider, (_, _) {});
  }
  final root = tempRootfs();
  final runtime = Runtime();
  final bridge = Bridge();
  late final ProviderContainer c;
  int loads = 0;
  Future<void>? get running => c.read(uiSkillAutoInstallProvider.notifier).running;
  Future<void> flush() async {
    await c.pump();
    await Future<void>.delayed(Duration.zero);
    await c.pump();
  }

  void close() {
    c.dispose();
    root.deleteSync(recursive: true);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('running without a verified token has no local write fallback', () async {
    final h = Harness();
    try {
      h.runtime.emit(RuntimePhase.running, token: null);
      await h.flush();
      expect(h.loads, 0);
      expect(h.bridge.requests, isEmpty);
      expect(Directory('${h.root.path}/root/.dsh/skills').existsSync(), isFalse);
    } finally {
      h.close();
    }
  });

  test('late root resolver is retired before loading or submitting assets', () async {
    final held = Completer<Directory?>();
    final h = Harness(resolve: () => held.future);
    try {
      h.runtime.emit(RuntimePhase.running);
      await h.flush();
      final running = h.running;
      h.runtime.emit(RuntimePhase.installing);
      await h.flush();
      held.complete(h.root);
      await running;
      expect(h.loads, 0);
      expect(h.bridge.requests, isEmpty);
    } finally {
      if (!held.isCompleted) held.complete(null);
      h.close();
    }
  });

  test('native cancellation keeps one newest ready and ignores old success', () async {
    final h = Harness();
    try {
      h.runtime.emit(RuntimePhase.running);
      await h.flush();
      final running = h.running;
      final old = h.bridge.requests.single;
      for (final token in ['two', 'three', 'four']) {
        h.runtime.emit(RuntimePhase.installed);
        await h.flush();
        h.runtime.emit(RuntimePhase.running, token: token);
        await h.flush();
      }
      expect(h.bridge.cancelled, [old.id]);
      expect(h.bridge.requests.length, 1);
      old.complete();
      await h.flush();
      expect(h.c.read(uiSkillAutoInstallProvider), isNull);
      expect(h.bridge.requests.map((r) => r.token), ['one', 'four']);
      h.bridge.requests.last.complete(result: 'updated');
      await running;
      expect(h.c.read(uiSkillAutoInstallProvider), UiSkillInstallResult.updated);
      expect(h.loads, 2);
    } finally {
      h.close();
    }
  });

  test('build replacement publishes only its own native result', () async {
    final h = Harness();
    try {
      h.runtime.emit(RuntimePhase.running);
      await h.flush();
      final old = h.bridge.requests.single;
      final oldRunning = h.running;
      h.c.invalidate(uiSkillAutoInstallProvider);
      await h.flush();
      expect(h.bridge.requests.length, 2);
      final next = h.bridge.requests.last;
      expect(next.id, isNot(old.id));
      next.complete(result: 'unchanged');
      await h.running;
      old.complete(result: 'updated');
      await oldRunning;
      expect(h.c.read(uiSkillAutoInstallProvider), UiSkillInstallResult.unchanged);
      expect(h.bridge.cancelled, contains(old.id));
    } finally {
      h.close();
    }
  });

  test('same token and base URL in a later native generation retire the old batch', () async {
    final h = Harness();
    try {
      h.runtime.emit(RuntimePhase.running);
      await h.flush();
      final old = h.bridge.requests.single;
      final running = h.running;
      h.runtime.emit(RuntimePhase.running, generation: 2);
      await h.flush();
      expect(h.bridge.cancelled, [old.id]);
      old.complete();
      await h.flush();
      expect(h.c.read(uiSkillAutoInstallProvider), isNull);
      expect(h.bridge.requests.map((r) => r.generation), [1, 2]);
      h.bridge.requests.last.complete(result: 'unchanged');
      await running;
      expect(h.c.read(uiSkillAutoInstallProvider), UiSkillInstallResult.unchanged);
    } finally {
      h.close();
    }
  });

  test('native retired response prevents loading the remaining bundles', () async {
    var extraLoads = 0;
    final h = Harness(
      extras: [
        () async {
          extraLoads++;
          return bundle(guideSkillName);
        },
      ],
    );
    try {
      h.runtime.emit(RuntimePhase.running);
      await h.flush();
      h.bridge.requests.single.complete(current: false);
      await h.running;
      expect(h.c.read(uiSkillAutoInstallProvider), isNull);
      expect(extraLoads, 0);
    } finally {
      h.close();
    }
  });

  test('a ready triggered while a completed batch publishes is not lost', () async {
    final h = Harness();
    h.bridge.onRequest = (r) => r.complete();
    var restarted = false;
    final sub = h.c.listen(uiSkillAutoInstallProvider, (_, value) {
      if (value != null && !restarted) {
        restarted = true;
        scheduleMicrotask(() => h.runtime.emit(RuntimePhase.running, generation: 2));
      }
    });
    try {
      h.runtime.emit(RuntimePhase.running);
      await h.flush();
      await h.running;
      await h.flush();
      await h.running;
      expect(h.bridge.requests.map((r) => r.generation), [1, 2]);
    } finally {
      sub.close();
      h.close();
    }
  });

  test('failed extra asset does not prevent the next bundled skill', () async {
    final h = Harness(extras: [() async => throw StateError('fixture'), () async => bundle(guideSkillName)]);
    h.bridge.onRequest = (r) => r.complete();
    try {
      h.runtime.emit(RuntimePhase.running);
      await h.flush();
      await h.running;
      expect(h.bridge.requests.map((r) => r.name), [uiSkillName, guideSkillName]);
      expect(h.c.read(uiSkillAutoInstallProvider), UiSkillInstallResult.installed);
    } finally {
      h.close();
    }
  });

  test('failed extra native transaction does not prevent the next bundled skill', () async {
    final h = Harness(extras: [() async => bundle(pluginSkillName), () async => bundle(guideSkillName)]);
    h.bridge.onRequest = (r) {
      if (r.name == pluginSkillName) {
        r.completion.completeError(PlatformException(code: 'fixture-io'));
      } else {
        r.complete();
      }
    };
    try {
      h.runtime.emit(RuntimePhase.running);
      await h.flush();
      await h.running;
      expect(h.bridge.requests.map((r) => r.name), [uiSkillName, pluginSkillName, guideSkillName]);
    } finally {
      h.close();
    }
  });

  test('missing Android bridge never falls back to synchronous live-root writes', () async {
    final h = Harness(bridgeOverride: RuntimeBridge(methods: const MethodChannel('missing-phase2-runtime')));
    try {
      h.runtime.emit(RuntimePhase.running);
      await h.flush();
      await h.running;
      expect(h.loads, 1);
      expect(h.c.read(uiSkillAutoInstallProvider), isNull);
      expect(Directory('${h.root.path}/root/.dsh/skills').existsSync(), isFalse);
    } finally {
      h.close();
    }
  });

  testWidgets('a real button handles input while the native file transaction is still pending', (tester) async {
    final h = Harness();
    var presses = 0;
    try {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: h.c,
          child: MaterialApp(
            home: Scaffold(
              body: StatefulBuilder(
                builder: (context, setState) => Column(
                  children: [
                    Text('presses:$presses'),
                    OutlinedButton(onPressed: () => setState(() => presses++), child: const Text('respond')),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      h.runtime.emit(RuntimePhase.running);
      await tester.pump();
      expect(h.bridge.requests.length, 1);
      expect(h.bridge.requests.single.completion.isCompleted, isFalse);
      await tester.tap(find.text('respond'));
      await tester.pump();
      expect(find.text('presses:1'), findsOneWidget);
      expect(h.bridge.requests.single.completion.isCompleted, isFalse);
      h.bridge.requests.single.complete();
      await tester.pump();
      expect(h.c.read(uiSkillAutoInstallProvider), UiSkillInstallResult.installed);
      await tester.pumpWidget(const SizedBox());
    } finally {
      h.close();
    }
  });

  test('private MethodChannel preserves request identity and decodes current', () async {
    const channel = MethodChannel('phase2-runtime-wire');
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return call.method == 'installManagedSkill' ? {'result': 'installed', 'current': false, 'reason': 'stale'} : null;
    });
    try {
      final bridge = RuntimeBridge(methods: channel);
      final response = await bridge.installManagedSkill(
        requestId: 'unique',
        expectedRoot: '/fixture/root',
        expectedToken: 'fixture-only',
        expectedGeneration: 7,
        name: uiSkillName,
        files: bundle().files,
      );
      expect(response.result, 'installed');
      expect(response.current, isFalse);
      expect(response.reason, 'stale');
      await bridge.cancelManagedSkill('unique');
      expect(calls.map((c) => c.method), ['installManagedSkill', 'cancelManagedSkill']);
      expect((calls.first.arguments as Map)['requestId'], 'unique');
      expect((calls.first.arguments as Map)['expectedGeneration'], 7);
      expect((calls.last.arguments as Map), {'requestId': 'unique'});
    } finally {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    }
  });

  test('private generation status is a positive integer or unknown', () {
    for (final value in [null, 0, -1, 1.0, '1', true]) {
      expect(
        RuntimeStatus.fromMap({'phase': 'running', 'managedSkillGeneration': value}).managedSkillGeneration,
        isNull,
      );
    }
    expect(RuntimeStatus.fromMap({'phase': 'running', 'managedSkillGeneration': 9}).managedSkillGeneration, 9);
    // Other runtime/RPC readiness semantics do not depend on this private grant.
    expect(
      const RuntimeStatus(phase: RuntimePhase.running, baseUrl: 'http://fixture', token: 'fixture').isRunning,
      isTrue,
    );
  });
}

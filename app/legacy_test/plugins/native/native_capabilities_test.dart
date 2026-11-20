// v1.2 capabilities in the app (docs/design/native-plugins-protocol.md §11):
// nothing happens without a declaring plugin; one owner at a time; local
// stop before any notice; listening asked per plugin and remembered.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/plugins/native/native_capabilities.dart';
import 'package:dsh_app/plugins/native/native_model.dart';
import 'package:dsh_app/plugins/native/native_platform.dart';
import 'package:dsh_app/plugins/native/native_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/ui/plugins/native/native_capability_scope.dart';
import 'package:dsh_app/ui/plugins/native/native_taps.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support.dart';

class _Socket implements DshGoSocket {
  final input = StreamController<Object?>();
  final sent = <Map<String, dynamic>>[];

  @override
  Stream<Object?> get messages => input.stream;

  @override
  void send(String text) {
    final map = jsonDecode(text) as Map<String, dynamic>;
    sent.add(map);
    if (map['t'] == 'hello') {
      input.add(jsonEncode({'t': 'welcome', 'conn': 'c1', 'features': map['features'] ?? []}));
    }
  }

  void receive(Map<String, Object?> data) => input.add(jsonEncode(data));

  Iterable<String> get events => sent.where((m) => m['t'] == 'cap.event').map((m) => m['event'] as String);

  @override
  Future<void> close([int? code]) async {
    if (!input.isClosed) await input.close();
  }
}

class _GateStream extends DshGoStream {
  _GateStream(super.connect) : super(features: const ['audio', 'voice', 'micro', 'overlay']);
  Completer<String?>? nextHold;

  @override
  Future<String?> hold({Duration timeout = const Duration(seconds: 2)}) {
    final actual = super.hold(timeout: timeout);
    final gate = nextHold;
    nextHold = null;
    return gate?.future ?? actual;
  }
}

class _Platform implements NativeMediaPlatform {
  final input = StreamController<Object?>.broadcast();
  final calls = <(String, Map<String, Object?>)>[];
  int probes = 0;
  Object? grant = true;
  Completer<Object?>? delayedGrant;
  Completer<Object?>? nextActivate;
  bool failDispose = false;
  final gates = <String, Completer<Object?>>{};
  final failing = <String>{};

  Iterable<String> get methods => calls.map((c) => c.$1);

  @override
  Future<Set<String>> capabilities() async {
    probes++;
    return {'audio', 'voice', 'overlay'};
  }

  @override
  Stream<Object?> get events => input.stream;

  @override
  Future<Object?> call(String method, Map<String, Object?> args) async {
    calls.add((method, args));
    final gate = gates.remove(method);
    if (gate != null) return gate.future;
    if (failing.contains(method)) throw PlatformException(code: 'unsupported');
    if (method == 'activate' && nextActivate != null) {
      final gate = nextActivate!;
      nextActivate = null;
      return gate.future;
    }
    if (method == 'disposeOwner' && failDispose) throw StateError('native close failed');
    if (method == 'requestVoiceGrant') return delayedGrant == null ? grant : delayedGrant!.future;
    return null;
  }

  void event(String kind, {bool localStopped = false, int? generation, String? reason}) {
    final owner = calls.lastWhere((c) => c.$1 == 'activate').$2;
    input.add({...owner, 'kind': kind, 'localStopped': localStopped, 'generation': ?generation, 'reason': ?reason});
  }
}

Future<void> _tick([int milliseconds = 5]) => Future<void>.delayed(Duration(milliseconds: milliseconds));

const _plugin = NativePlugin(
  package: 'voice-plugin',
  capabilities: {'audio', 'voice', 'micro', 'overlay'},
  media: ['clip'],
  micro: ['caption'],
  overlays: [DshGoOverlay('subtitle', channel: 'caption')],
);
const _scope = DshGoScope(sessionId: 's1');

NativeCapabilityEffect _effect(String type, String op, {String lease = 'lease-1'}) => NativeCapabilityEffect(
  type,
  op,
  'reading',
  lease,
  resource: type == 'audio' && op == 'play' ? 'clip' : (type == 'overlay' ? 'subtitle' : null),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('without a declaring plugin', () {
    test('no platform call, no features, the v1.1 caps and hello', () async {
      final platform = _Platform();
      final bridge = FakeBridge(contributions([quickPlugin(), usagePlugin()]));
      final container = ProviderContainer(
        overrides: [
          ...nativeOverrides(bridge),
          nativeMediaPlatformProvider.overrideWithValue(platform),
          nativeLocaleProvider.overrideWithValue('zh-CN'),
        ],
      );
      addTearDown(container.dispose);
      final discovery = container.listen(nativeCapabilityDiscoveryProvider, (_, _) {});
      final runtime = container.listen(nativeCapabilityRuntimeProvider, (_, _) {});
      await container.read(nativeRawContributionsProvider.future);
      await container.read(nativeCapabilityDiscoveryProvider.future);
      expect(platform.probes, 0);
      expect(platform.calls, isEmpty);
      expect(container.read(nativeFeatureStateProvider), isEmpty);
      expect(container.read(nativeCapsProvider).query.containsKey('features'), isFalse);
      final stream = container.read(nativeStreamProvider)!;
      await stream.hold();
      expect(bridge.socket.sent.first['t'], 'hello');
      expect(bridge.socket.sent.first.containsKey('features'), isFalse);
      stream.release();
      runtime.close();
      discovery.close();
    });

    testWidgets('the scope opens no channel: dsh/native-media is never called', (tester) async {
      final calls = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('dsh/native-media'), (
        call,
      ) async {
        calls.add(call.method);
        return null;
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          const MethodChannel('dsh/native-media'),
          null,
        ),
      );
      final bridge = FakeBridge(contributions([quickPlugin(), usagePlugin()]));
      await tester.pumpWidget(
        ProviderScope(
          overrides: nativeOverrides(bridge),
          child: const MaterialApp(home: NativeCapabilityScope(child: Text('chat'))),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(find.text('chat'), findsOneWidget);
      expect(calls, isEmpty);
    });
  });

  test('a declaring plugin: micro plus what the platform has; a native fault takes them back', () async {
    final platform = _Platform();
    final container = ProviderContainer(
      overrides: [
        nativeContributionsProvider.overrideWithValue(const NativeContributions(plugins: [_plugin])),
        nativeMediaPlatformProvider.overrideWithValue(platform),
        nativeBridgeProvider.overrideWithValue(FakeBridge()),
        nativeLocaleProvider.overrideWithValue('en'),
      ],
    );
    addTearDown(container.dispose);
    final discovery = container.listen(nativeCapabilityDiscoveryProvider, (_, _) {});
    await container.read(nativeCapabilityDiscoveryProvider.future);
    expect(container.read(nativeFeatureStateProvider), ['audio', 'micro', 'overlay', 'voice']);
    expect(platform.probes, 1);
    container.read(nativePlatformFaultProvider.notifier).fail();
    await _tick(30);
    expect(container.read(nativeFeatureStateProvider), ['micro']);
    discovery.close();
  });

  test('requires: a button needing a capability shows only when the app has it', () {
    final raw = contributions([
      plugin(
        'voice-plugin',
        composer: [
          {
            'id': 'read',
            'label': '朗读',
            'requires': ['audio'],
          },
          {'id': 'plain', 'label': '普通'},
        ],
      ),
    ]);
    expect(nativeContributionsFrom(raw).plugins.single.composerActions.map((a) => a.id), ['plain']);
    expect(nativeContributionsFrom(raw, features: {'audio'}).plugins.single.composerActions.map((a) => a.id), [
      'read',
      'plain',
    ]);
  });

  test('effects: only media sources, no unknown fields, a lease always', () {
    NativeCapabilityEffect? parse(Map<String, Object?> e) => NativeCapabilityEffect.parse(e);
    expect(parse({'type': 'audio', 'op': 'play', 'instance': 'x', 'lease': 'l', 'src': 'https://evil/clip'}), isNull);
    expect(
      parse({'type': 'audio', 'op': 'play', 'instance': 'x', 'lease': 'l', 'src': 'media:clip', 'url': 'file:/x'}),
      isNull,
    );
    expect(parse({'type': 'audio', 'op': 'stop', 'instance': 'x', 'lease': 'l', 'src': 'media:clip'}), isNull);
    expect(parse({'type': 'voice', 'op': 'start', 'instance': 'x'}), isNull);
    expect(parse({'type': 'overlay', 'op': 'show', 'instance': 'x', 'lease': 'l'}), isNull);
    final ok = parse({
      'type': 'audio',
      'op': 'play',
      'instance': 'x',
      'lease': 'l',
      'src': 'media:clip',
      'key': 'k_1',
    })!;
    expect((ok.resource, ok.key, ok.starts), ('clip', 'k_1', true));
  });

  testWidgets('a tap runs capability effects through the runtime, after the other effects', (tester) async {
    final socket = _Socket();
    final stream = _GateStream(() async => socket);
    await tester.runAsync(() => stream.hold());
    final platform = _Platform();
    final bridge = FakeBridge()
      ..answer = (_) => const DshGoInvokeResult(
        effects: [
          {'type': 'audio', 'op': 'play', 'instance': 'reading', 'lease': 'lease-1', 'src': 'media:clip'},
          {'type': 'toast', 'text': '开始朗读'},
        ],
      );
    final download = Completer<(File, String)>();
    final runtime = NativeCapabilityRuntime(
      platform: platform,
      stream: stream,
      download: (_, _, _) => download.future,
      plugin: (_) => _plugin,
      hostIdentity: 'local',
      hostTitle: 'This phone',
      session: () => 's1',
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...nativeOverrides(bridge),
          nativeStreamProvider.overrideWithValue(stream),
          nativeLocaleProvider.overrideWithValue('en'),
          nativeContributionsProvider.overrideWithValue(const NativeContributions(plugins: [_plugin])),
          nativePluginTitleProvider('voice-plugin').overrideWithValue('Voice plugin'),
          nativeCapabilityRuntimeProvider.overrideWithValue(runtime),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Consumer(
              builder: (context, ref, _) => GestureDetector(
                onTap: () => runNativeTap(
                  context,
                  ref,
                  package: 'voice-plugin',
                  surface: NativeSurface.composerActions,
                  id: 'read',
                  scope: _scope,
                ),
                child: const Text('Read aloud'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Read aloud'));
    await tester.pump();
    await tester.pump();
    expect(bridge.invocations.single.stream, 'c1');
    expect(platform.methods, ['activate']);
    expect(runtime.active, isTrue);
    expect(find.text('开始朗读'), findsOneWidget, reason: 'the ordinary effects still run');
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() async {
      await runtime.dispose();
      stream.release();
      await stream.close();
      await platform.input.close();
    });
  });

  group('owner', () {
    late _Socket socket;
    late _GateStream stream;
    late _Platform platform;
    late NativeCapabilityRuntime runtime;
    late Completer<(File, String)> download;
    late Directory directory;
    String? currentSession;
    var consent = true;
    var asked = 0;

    Future<bool> execute(NativeCapabilityEffect effect) {
      final now = DateTime.now();
      return runtime.execute(
        effect,
        pkg: 'voice-plugin',
        scope: _scope,
        connection: 'c1',
        tappedAt: now,
        now: now,
        consent: (_) async {
          asked++;
          return consent;
        },
      );
    }

    setUp(() async {
      socket = _Socket();
      platform = _Platform();
      stream = _GateStream(() async => socket);
      await stream.hold();
      download = Completer<(File, String)>();
      directory = await Directory.systemTemp.createTemp('native-media-test-');
      currentSession = 's1';
      consent = true;
      asked = 0;
      runtime = NativeCapabilityRuntime(
        platform: platform,
        stream: stream,
        download: (_, _, _) => download.future,
        plugin: (_) => _plugin,
        hostIdentity: 'local',
        hostTitle: 'This phone',
        session: () => currentSession,
      );
    });

    tearDown(() async {
      await runtime.dispose();
      stream.release();
      await stream.close();
      await platform.input.close();
      try {
        await directory.delete(recursive: true);
      } on PathNotFoundException {
        // The late download removed it already.
      }
    });

    Future<void> finishDownload() async {
      final file = File('${directory.path}/clip');
      await file.writeAsBytes([1, 2, 3]);
      download.complete((file, 'audio/mpeg'));
      await _tick();
    }

    test('play: activate, download, then the private file to the platform', () async {
      expect(await execute(_effect('audio', 'play')), isTrue);
      expect(platform.methods, ['activate']);
      await finishDownload();
      final play = platform.calls.singleWhere((c) => c.$1 == 'play').$2;
      expect(play['privatePath'], '${directory.path}/clip');
      expect(play['contentType'], 'audio/mpeg');
      expect(play['lease'], 'lease-1');
    });

    test('speech needs proof of a local stop; then notice, and a late download never plays', () async {
      await execute(_effect('audio', 'play'));
      await execute(_effect('voice', 'start'));
      expect(platform.methods, ['activate', 'requestVoiceGrant', 'startVoice']);
      platform.event('voice.speechStart');
      await _tick();
      expect(socket.events, isEmpty, reason: 'no localStopped: not forwarded');
      platform.event('voice.speechStart', localStopped: true);
      await _tick();
      expect(socket.events, ['voice.speechStart']);
      await finishDownload();
      expect(platform.methods.where((m) => m == 'play'), isEmpty);
      expect(runtime.active, isTrue, reason: 'still listening while the person speaks');
      expect(await execute(_effect('audio', 'play')), isFalse, reason: 'another clip is a new tap and lease');
      // The sentence is over: listening ends with the clip it guarded.
      platform.event('voice.speechEnd');
      await _tick(250);
      expect(platform.methods.where((m) => m == 'stopVoice').length, 1);
      expect(socket.events, ['voice.speechStart', 'voice.speechEnd', 'voice.stopped']);
      expect(socket.sent.lastWhere((m) => m['event'] == 'voice.stopped')['reason'], 'speech-ended');
      await _tick(150);
      expect(runtime.active, isFalse, reason: 'every role ended');
    });

    test('the clip ends: listening and the caption stop with it', () async {
      await execute(_effect('audio', 'play'));
      await execute(_effect('voice', 'start'));
      await execute(_effect('overlay', 'show'));
      await finishDownload();
      platform.event('audio.ended');
      await _tick(400);
      expect(platform.methods, containsAll(['stopVoice', 'hideOverlay']));
      expect(socket.events, containsAll(['audio.ended', 'voice.stopped', 'overlay.closed']));
      expect(socket.events.first, 'audio.ended');
      expect(runtime.active, isFalse);
      expect(platform.methods.last, 'disposeOwner');
      expect(await directory.exists(), isFalse, reason: 'the clip is deleted after the native close');
    });

    test('listening is asked once per plugin; declined means no system prompt', () async {
      await execute(_effect('audio', 'play'));
      consent = false;
      expect(await execute(_effect('voice', 'start')), isFalse);
      expect(asked, 1);
      expect(platform.methods.where((m) => m == 'requestVoiceGrant'), isEmpty);
      await _tick();
      expect(socket.events, ['voice.error']);
      expect(socket.sent.lastWhere((m) => m['t'] == 'cap.event')['reason'], 'declined');
      expect(await execute(_effect('audio', 'stop')), isTrue, reason: 'manual stop is never lost');
    });

    test('the microphone is busy (dictation): listening fails alone, the clip plays on', () async {
      platform.failing.add('startVoice');
      await execute(_effect('audio', 'play'));
      expect(await execute(_effect('voice', 'start')), isFalse);
      await _tick();
      expect(runtime.active, isTrue);
      expect(socket.events, ['voice.error']);
      await finishDownload();
      expect(platform.methods.where((m) => m == 'play').length, 1);
    });

    test('without a consent question it never listens', () async {
      final now = DateTime.now();
      expect(
        await runtime.execute(
          _effect('voice', 'start'),
          pkg: 'voice-plugin',
          scope: _scope,
          connection: 'c1',
          tappedAt: now,
          now: now,
        ),
        isFalse,
      );
      expect(platform.methods.where((m) => m == 'startVoice'), isEmpty);
    });

    test('a system denial is not asked again for the same lease', () async {
      platform.grant = false;
      expect(await execute(_effect('voice', 'start')), isFalse);
      expect(await execute(_effect('voice', 'start')), isFalse);
      expect(platform.methods.where((m) => m == 'requestVoiceGrant').length, 1);
      currentSession = 's2';
      runtime.revalidate();
      await _tick();
      expect(runtime.active, isFalse);
    });

    test('no caption window here: the caption is off, the clip plays on', () async {
      platform.failing.add('showOverlay');
      await execute(_effect('audio', 'play'));
      expect(await execute(_effect('overlay', 'show')), isFalse);
      await _tick();
      expect(runtime.active, isTrue);
      expect(socket.sent.lastWhere((m) => m['t'] == 'cap.event')['reason'], 'unsupported');
      await finishDownload();
      expect(platform.methods.where((m) => m == 'play').length, 1);
    });

    test('a late caption update failure cannot end a replacement owner', () async {
      final update = platform.gates['updateOverlay'] = Completer<Object?>();
      await execute(_effect('overlay', 'show'));
      await _tick();
      final sid = socket.sent.lastWhere((m) => m['t'] == 'micro.sub')['sub'];
      socket.receive({
        't': 'micro.data',
        'sub': sid,
        'rev': '0123456789abcdef.1',
        'data': {'text': 'caption'},
      });
      await _tick();
      expect(platform.calls.where((c) => c.$1 == 'updateOverlay').single.$2['text'], 'caption');
      expect(await execute(_effect('voice', 'start', lease: 'lease-2')), isTrue);
      update.completeError(StateError('late overlay failure'));
      await _tick();
      expect(runtime.active, isTrue);
      expect(platform.methods.where((m) => m == 'disposeOwner').length, 1);
    });

    test('a stop pending on the platform still voids a late download', () async {
      await execute(_effect('audio', 'play'));
      final gate = platform.gates['stop'] = Completer<Object?>();
      final stopped = execute(_effect('audio', 'stop'));
      await _tick();
      await finishDownload();
      final plays = platform.methods.where((m) => m == 'play').length;
      gate.complete(null);
      await stopped;
      expect(plays, 0);
    });

    test('stop during download: no play, no file, audio.stopped once', () async {
      expect(await execute(_effect('audio', 'play')), isTrue);
      expect(await execute(_effect('audio', 'stop')), isTrue);
      await finishDownload();
      expect(platform.methods.where((m) => m == 'play'), isEmpty);
      await _tick(150);
      expect(await directory.exists(), isFalse);
      expect(socket.events, ['audio.stopped']);
    });

    test('a failed native close keeps the file, claims no stop and refuses new owners', () async {
      await execute(_effect('audio', 'play'));
      await finishDownload();
      platform.failDispose = true;
      expect(await execute(_effect('voice', 'start', lease: 'lease-2')), isFalse);
      expect(await File('${directory.path}/clip').exists(), isTrue);
      expect(await execute(_effect('voice', 'start', lease: 'lease-2')), isFalse);
      expect(socket.events.where((e) => e == 'audio.stopped'), isEmpty);
    });

    test('a late play failure cannot delete a file after a failed close', () async {
      final gate = platform.gates['play'] = Completer<Object?>();
      await execute(_effect('audio', 'play'));
      await finishDownload();
      platform.failDispose = true;
      await runtime.revoke();
      gate.completeError(StateError('late play failure'));
      await _tick();
      expect(await File('${directory.path}/clip').exists(), isTrue);
    });

    test('owner.revoked (the indicator, dictation, the background) ends only the current owner', () async {
      await execute(_effect('audio', 'play'));
      await execute(_effect('voice', 'start'));
      platform.event('owner.revoked', generation: 999);
      await _tick();
      expect(runtime.active, isTrue);
      platform.event('owner.revoked', reason: 'user');
      await _tick();
      expect(runtime.active, isFalse);
      await finishDownload();
      expect(platform.methods.where((m) => m == 'play'), isEmpty);
      await runtime.revoke();
      expect(socket.events, containsAll(['audio.stopped', 'voice.stopped']));
      expect(socket.events, isNot(contains('owner.revoked')));
    });

    test('background while the system prompt is open: nothing starts', () async {
      platform.delayedGrant = Completer<Object?>();
      final start = execute(_effect('voice', 'start'));
      await _tick();
      runtime.foreground(false);
      platform.delayedGrant!.complete(true);
      expect(await start, isFalse);
      expect(platform.methods.where((m) => m == 'startVoice'), isEmpty);
      expect(platform.methods.where((m) => m == 'disposeOwner').length, 1);
    });

    test('old generations and repeated terminals notify once', () async {
      await execute(_effect('audio', 'play'));
      await finishDownload();
      platform.event('audio.ended', generation: 999);
      await _tick();
      expect(socket.events, isEmpty);
      platform.event('audio.ended');
      platform.event('audio.ended');
      await _tick();
      expect(socket.events, ['audio.ended']);
    });

    test('a late activate cannot end a replacement owner', () async {
      final gate = platform.nextActivate = Completer<Object?>();
      final first = execute(_effect('audio', 'play'));
      await _tick();
      expect(await execute(_effect('voice', 'start', lease: 'lease-2')), isTrue);
      gate.completeError(StateError('late activation failure'));
      expect(await first, isFalse);
      expect(runtime.active, isTrue);
      expect(platform.methods.where((m) => m == 'disposeOwner').length, 1);
    });

    test('a late hold cannot end a replacement owner', () async {
      final hold = stream.nextHold = Completer<String?>();
      final first = execute(_effect('audio', 'play'));
      await _tick();
      expect(await execute(_effect('voice', 'start', lease: 'lease-2')), isTrue);
      hold.complete(null);
      expect(await first, isFalse);
      expect(runtime.active, isTrue);
      expect(platform.methods.where((m) => m == 'disposeOwner').length, 1);
    });

    test('a flood of speech edges stops locally; the terminal still goes out', () async {
      await execute(_effect('voice', 'start'));
      for (var i = 0; i < 8; i++) {
        platform.event(i.isEven ? 'voice.speechStart' : 'voice.speechEnd', localStopped: true);
      }
      await _tick();
      expect(runtime.active, isFalse);
      final closing = runtime.revoke();
      expect(await execute(_effect('voice', 'start', lease: 'lease-2')), isFalse, reason: 'not while closing');
      await closing;
      expect(platform.methods.where((m) => m == 'disposeOwner').length, 1);
      expect(socket.events.last, 'voice.stopped');
    });
  });

  test('consent is per host and plugin, remembered, and switchable', () async {
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final consents = container.read(nativeVoiceConsentProvider.notifier);
    expect(consents.of(HostRef.none, 'voice-plugin'), isNull);
    await consents.set(HostRef.none, 'voice-plugin', false);
    expect(consents.of(HostRef.none, 'voice-plugin'), isFalse);
    expect(consents.of(HostRef.none, 'other'), isNull);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList(NativeVoiceConsents.prefsKey), [
      '0:${NativeVoiceConsents.keyOf(HostRef.none, 'voice-plugin')}',
    ]);
    await consents.set(HostRef.none, 'voice-plugin', true);
    final fresh = ProviderContainer();
    addTearDown(fresh.dispose);
    fresh.read(nativeVoiceConsentProvider);
    await _tick();
    expect(fresh.read(nativeVoiceConsentProvider.notifier).of(HostRef.none, 'voice-plugin'), isTrue);
  });
}

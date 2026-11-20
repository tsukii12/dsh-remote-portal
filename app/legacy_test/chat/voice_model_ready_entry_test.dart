// Model changes must reach the already-open composer on the same local host.
// Keep the real ChatScreen/Composer/controller; only native and RPC IO is fake.
import 'dart:async';

import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/voice_model_state.dart';
import 'package:dsh_app/state/voice_state.dart';
import 'package:dsh_app/ui/chat/chat_screen.dart';
import 'package:dsh_app/ui/chat/composer.dart';
import 'package:dsh_app/ui/chat/voice/voice_bridge.dart';
import 'package:dsh_app/ui/chat/voice/voice_controller.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/composer_fakes.dart';
import 'support/harness.dart';

class _Model extends VoiceModelController {
  _Model(this.initial);
  final VoiceModelStatus initial;

  @override
  VoiceModelState build() => VoiceModelState(status: initial);

  void change(VoiceModelStatus status) => state = state.copyWith(status: status);
}

class _Host extends Notifier<HostConnection?> {
  _Host(this.initial);
  final HostConnection initial;

  @override
  HostConnection? build() => initial;

  void use(HostConnection connection) => state = connection;
}

final _hostProvider = NotifierProvider<_Host, HostConnection?>(() => throw UnimplementedError());

class _Carrier extends FakeRpcCarrier {
  _Carrier({this.phase = 'unprepared'}) : super({});
  String phase;
  Future<Object?>? pendingCatalog;

  @override
  Future<RpcResult> call(String endpoint, Map<String, Object?> args, {Duration? timeout}) async {
    if (endpoint != 'speech/catalog') return super.call(endpoint, args, timeout: timeout);
    calls.add((endpoint, args));
    final pending = pendingCatalog;
    pendingCatalog = null;
    return RpcOk(pending == null ? readySpeechCatalog(phase: phase) : await pending);
  }

  int get probes => argsOf('speech/catalog').length;
}

class _Rig {
  _Rig({bool local = true, bool system = false, VoiceModelStatus status = VoiceModelStatus.downloading})
    : model = _Model(status),
      bridge = FakeVoiceBridge(caps: VoiceCapabilities(recognizer: system, recorder: true)) {
    client = DshClient.withCarrier(carrier);
    host = _Host(HostConnection(hostId: '', client: client, isLocal: local));
    if (status == VoiceModelStatus.ready) carrier.phase = 'standby';
  }

  final _Model model;
  final FakeVoiceBridge bridge;
  final carrier = _Carrier();
  late final DshClient client;
  late final _Host host;

  Future<void> pump(WidgetTester tester) async {
    usePhoneView(tester);
    mockClipboard(tester);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 500));
      await client.close();
    });
    final harness = ChatHarness(session: 'first-chat');
    await tester.pumpWidget(
      testApp(
        const ChatScreen(),
        overrides: [
          _hostProvider.overrideWith(() => host),
          activeConnectionProvider.overrideWith((ref) => AsyncData(ref.watch(_hostProvider))),
          // Replace the harness's first override (its fixed connection).
          ...harness.overrides.skip(1),
          voiceBridgeProvider.overrideWithValue(bridge),
          voiceModelProvider.overrideWith(() => model),
        ],
      ),
    );
    await pumpFrames(tester);
    ProviderScope.containerOf(tester.element(find.byType(ChatScreen))).read(voiceModelProvider);
  }

  VoiceInputController voice(WidgetTester tester) => tester.widget<Composer>(find.byType(Composer)).voice!;
}

Finder get _mic => find.byIcon(AppIcons.voice);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('download becoming ready exposes the microphone on the existing local host', (tester) async {
    final rig = _Rig();
    await rig.pump(tester);
    expect(_mic, findsNothing);
    expect(rig.carrier.probes, 1);

    rig.carrier.phase = 'standby';
    rig.model.change(VoiceModelStatus.ready);
    await pumpFrames(tester);

    expect(rig.voice(tester).available, isTrue);
    expect(_mic, findsOneWidget);
    expect(rig.carrier.probes, 2);
  });

  testWidgets('deleting the model removes the microphone on the same local connection', (tester) async {
    final rig = _Rig(status: VoiceModelStatus.ready);
    await rig.pump(tester);
    expect(_mic, findsOneWidget);

    rig.carrier.phase = 'unprepared';
    rig.model.change(VoiceModelStatus.absent);
    await pumpFrames(tester);

    expect(rig.voice(tester).available, isFalse);
    expect(_mic, findsNothing);
    expect(rig.carrier.probes, 2);
  });

  testWidgets('local model changes do not refresh or remove a remote microphone', (tester) async {
    final rig = _Rig(local: false);
    rig.carrier.phase = 'standby';
    await rig.pump(tester);
    expect(_mic, findsOneWidget);
    final before = rig.carrier.probes;

    rig.model.change(VoiceModelStatus.ready);
    await pumpFrames(tester);
    rig.model.change(VoiceModelStatus.absent);
    await pumpFrames(tester);

    expect(_mic, findsOneWidget);
    expect(rig.carrier.probes, before);
  });

  testWidgets('download progress without a ready change does not repeat the capability probe', (tester) async {
    final rig = _Rig();
    await rig.pump(tester);
    rig.model.change(VoiceModelStatus.preparing);
    await pumpFrames(tester);
    expect(_mic, findsNothing);
    expect(rig.carrier.probes, 1);
  });

  testWidgets('a system microphone stays available without an eager engine query', (tester) async {
    final rig = _Rig(system: true);
    await rig.pump(tester);
    expect(_mic, findsOneWidget);
    rig.model.change(VoiceModelStatus.ready);
    await pumpFrames(tester);
    rig.model.change(VoiceModelStatus.absent);
    await pumpFrames(tester);
    expect(_mic, findsOneWidget);
    expect(rig.carrier.probes, 0);
  });

  testWidgets('ready arriving during an older catalog probe is checked again after that reply', (tester) async {
    final pending = Completer<Object?>();
    final rig = _Rig();
    rig.carrier.pendingCatalog = pending.future;
    await rig.pump(tester);
    expect(rig.carrier.probes, 1);
    expect(_mic, findsNothing);

    rig.carrier.phase = 'standby';
    rig.model.change(VoiceModelStatus.ready);
    await pumpFrames(tester);
    // The old response was computed before the model became ready.
    pending.complete(readySpeechCatalog(phase: 'unprepared'));
    await pumpFrames(tester);

    expect(rig.voice(tester).available, isTrue);
    expect(_mic, findsOneWidget);
    expect(rig.carrier.probes, 2);
  });

  testWidgets('a pending local refresh cannot replay a model event onto a replacement host', (tester) async {
    final pending = Completer<Object?>();
    final rig = _Rig();
    rig.carrier.pendingCatalog = pending.future;
    await rig.pump(tester);
    rig.carrier.phase = 'standby';
    rig.model.change(VoiceModelStatus.ready);
    await tester.pump();

    final remote = _Carrier(phase: 'unprepared');
    final remoteClient = DshClient.withCarrier(remote);
    addTearDown(remoteClient.close);
    rig.host.use(HostConnection(hostId: '', client: remoteClient, isLocal: false));
    await tester.pump();
    pending.complete(readySpeechCatalog());
    await pumpFrames(tester);

    expect(rig.voice(tester).available, isFalse);
    expect(_mic, findsNothing);
    expect(rig.carrier.probes, 1);
    // This probe belongs to the host switch, not the previous local model.
    expect(remote.probes, 1);
  });

  testWidgets('disposing the chat retires its pending model refresh', (tester) async {
    final pending = Completer<Object?>();
    final rig = _Rig();
    rig.carrier.pendingCatalog = pending.future;
    await rig.pump(tester);
    rig.model.change(VoiceModelStatus.ready);
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    pending.complete(readySpeechCatalog(phase: 'unprepared'));
    await pumpFrames(tester);

    expect(rig.carrier.probes, 1);
    expect(tester.takeException(), isNull);
  });
}

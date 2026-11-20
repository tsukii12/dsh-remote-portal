import 'dart:async';

import 'package:dsh_app/state/voice_settings.dart';
import 'package:dsh_app/ui/chat/voice/voice_bridge.dart';
import 'package:dsh_app/ui/chat/voice/voice_controller.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../plugins/support/fake_plugin_host.dart' show FakeMuxLink;
import 'support/composer_fakes.dart';

class _Link extends FakeMuxLink {
  late DshMuxLossHandler lose;

  @override
  void start({required DshMuxFrameHandler onFrame, required DshMuxLossHandler onLost}) {
    lose = onLost;
    super.start(onFrame: onFrame, onLost: onLost);
  }
}

class _Carrier extends FakeRpcCarrier {
  _Carrier() : super({'speech/catalog': (_) => readySpeechCatalog()});
  late _Link link;

  @override
  Future<DshMuxLink> openLink(MuxOptions options) async => link = _Link();
}

class _Bridge extends FakeVoiceBridge {
  Completer<VoicePermission>? permissionGate;
  Completer<void>? recognizerGate;

  @override
  Future<VoicePermission> requestPermission() async {
    final permission = await super.requestPermission();
    return permissionGate == null ? permission : await permissionGate!.future;
  }

  @override
  Future<void> startRecognizer({String? language}) async {
    await super.startRecognizer(language: language);
    await recognizerGate?.future;
  }
}

class _Rig {
  _Rig(VoiceMode mode, {Future<VoiceMode> Function()? choose}) {
    client = DshClient.withCarrier(carrier, muxOptions: const MuxOptions(autoReconnect: false));
    selected = client;
    voice = VoiceInputController(
      input: input,
      bridge: bridge,
      client: () => selected,
      mode: choose ?? () async => mode,
      observeLifecycle: false,
    );
    addTearDown(() async {
      voice.dispose();
      input.dispose();
      await client.close();
    });
  }

  final carrier = _Carrier();
  final bridge = _Bridge();
  final input = TextEditingController(text: 'draft ');
  late final DshClient client;
  late final VoiceInputController voice;
  DshClient? selected;

  Future<void> start() async {
    await client.mux.start();
    await voice.refresh();
    await voice.start();
  }

  void disconnect() {
    carrier.link.lose(const DshCarrierLostException('controlled link loss'), StackTrace.current);
    expect(client.mux.generation, isNull);
    // Composer.build calls this after the connection status changes.
    voice.ensureFresh();
  }
}

void main() {
  for (final mode in [VoiceMode.system, VoiceMode.auto]) {
    for (final stopping in [false, true]) {
      testWidgets('${mode.name} system dictation survives mux loss and a new ready generation, stopping=$stopping', (
        tester,
      ) async {
        final rig = _Rig(mode);
        await rig.start();
        expect(rig.voice.engine, VoiceEngine.system);
        final firstGeneration = rig.client.mux.generation;
        expect(firstGeneration, isNotNull);
        rig.bridge.emit(const VoicePartial('spoken words'));
        await tester.pump();
        expect(rig.input.text, 'draft spoken words');
        if (stopping) await rig.voice.stop();
        final phase = stopping ? VoicePhase.transcribing : VoicePhase.listening;

        rig.disconnect();
        await tester.pump();
        expect(rig.voice.phase, phase);
        expect(rig.input.text, 'draft spoken words');
        expect(rig.bridge.calls, isNot(contains('cancel')));

        await rig.client.mux.start();
        expect(rig.client.mux.generation, isNot(same(firstGeneration)));
        rig.voice.ensureFresh();
        await tester.pump();
        expect(rig.voice.phase, phase);
        expect(rig.bridge.calls.where((call) => call == 'recognizer'), hasLength(1));
        rig.bridge.emit(const VoiceFinal('completed words'));
        await tester.pump();
        expect(rig.voice.phase, VoicePhase.idle);
        expect(rig.input.text, 'draft completed words');
        expect(rig.carrier.calls, isEmpty, reason: 'phone recognition never uploads audio to the Host');
      });
    }
  }

  testWidgets('replacing the selected client still cancels system dictation and restores its draft', (tester) async {
    final rig = _Rig(VoiceMode.system);
    await rig.start();
    rig.bridge.emit(const VoicePartial('old host words'));
    await tester.pump();
    final replacement = DshClient.withCarrier(_Carrier());
    addTearDown(replacement.close);
    rig.selected = replacement;
    rig.voice.ensureFresh();
    await tester.pump();
    expect(rig.voice.phase, VoicePhase.idle);
    expect(rig.input.text, 'draft ');
    expect(rig.bridge.calls.last, 'cancel');
  });

  testWidgets('engine recording remains bound to its ready generation', (tester) async {
    final rig = _Rig(VoiceMode.engine);
    await rig.start();
    expect(rig.voice.engine, VoiceEngine.engine);
    rig.disconnect();
    await tester.pump();
    expect(rig.voice.phase, VoicePhase.idle);
    expect(rig.bridge.calls.last, 'cancel');
    expect(rig.carrier.calls.map((call) => call.$1), ['speech/catalog']);
  });

  testWidgets('a system error after link loss cannot start engine fallback on a stale generation', (tester) async {
    final rig = _Rig(VoiceMode.auto);
    await rig.start();
    rig.disconnect();
    await tester.pump();
    rig.bridge.emit(const VoiceError(2));
    await tester.pump();
    expect(rig.voice.phase, VoicePhase.idle);
    expect(rig.bridge.calls.where((call) => call.startsWith('recorder:')), isEmpty);
    expect(rig.carrier.calls, isEmpty);
  });

  for (final waitingForPermission in [true, false]) {
    testWidgets('unselected recognition keeps startup generation guard, permission=$waitingForPermission', (
      tester,
    ) async {
      final permission = Completer<VoicePermission>();
      final mode = Completer<VoiceMode>();
      final rig = _Rig(VoiceMode.system, choose: waitingForPermission ? null : () => mode.future);
      if (waitingForPermission) rig.bridge.permissionGate = permission;
      await rig.client.mux.start();
      await rig.voice.refresh();
      final starting = rig.voice.start();
      await tester.pump();
      expect(rig.voice.phase, VoicePhase.starting);
      expect(rig.voice.engine, isNull);
      rig.disconnect();
      await tester.pump();
      expect(rig.voice.phase, VoicePhase.idle);
      if (waitingForPermission) {
        permission.complete(VoicePermission.granted);
      } else {
        mode.complete(VoiceMode.system);
      }
      await starting;
      expect(rig.bridge.calls, isNot(contains('recognizer')));
      expect(rig.input.text, 'draft ');
    });
  }

  for (final replaceClient in [false, true]) {
    testWidgets('pending system start reply follows client identity, replacement=$replaceClient', (tester) async {
      final rig = _Rig(VoiceMode.system);
      final started = rig.bridge.recognizerGate = Completer<void>();
      await rig.client.mux.start();
      await rig.voice.refresh();
      final starting = rig.voice.start();
      await tester.pump();
      expect(rig.voice.engine, VoiceEngine.system);
      expect(rig.voice.phase, VoicePhase.starting);
      if (replaceClient) {
        final replacement = DshClient.withCarrier(_Carrier());
        addTearDown(replacement.close);
        rig.selected = replacement;
        rig.voice.ensureFresh();
      } else {
        rig.disconnect();
      }
      await tester.pump();
      expect(rig.voice.phase, replaceClient ? VoicePhase.idle : VoicePhase.starting);
      started.complete();
      await starting;
      expect(rig.voice.phase, replaceClient ? VoicePhase.idle : VoicePhase.listening);
      rig.bridge.emit(const VoiceFinal('late result'));
      await tester.pump();
      expect(rig.input.text, replaceClient ? 'draft ' : 'draft late result');
    });
  }
}

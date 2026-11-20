// Voice input in the composer: the mic key on an empty draft, dictation with
// the system recognizer (preferred: partials stream into the draft), the
// engine's recognizer as the fallback when the phone has none (record, then
// transcribe), cancel, the permission flow, and goldens. Regenerate with
// `flutter test --update-goldens test/chat/composer_voice_test.dart`.

import 'dart:convert';

import 'package:dsh_app/ui/chat/composer.dart';
import 'package:dsh_app/ui/chat/mention/mention_text_controller.dart';
import 'package:dsh_app/ui/chat/voice/voice_bridge.dart';
import 'package:dsh_app/ui/chat/voice/voice_controller.dart';
import 'package:dsh_app/ui/chat/voice/voice_widgets.dart';
import 'package:dsh_app/ui/chat/widgets/attachments.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/composer_fakes.dart';
import 'support/harness.dart';

class _Rig {
  _Rig({FakeVoiceBridge? bridge, this.client, this.modelReady = false}) : bridge = bridge ?? FakeVoiceBridge();

  final FakeVoiceBridge bridge;
  final DshClient? client;

  /// The on-device voice model is downloaded (voice settings).
  final bool modelReady;
  final input = MentionTextController();
  late final voice = VoiceInputController(
    input: input,
    bridge: bridge,
    client: () => client,
    modelReady: () => modelReady,
    observeLifecycle: false,
  );
  var sent = 0;

  Future<void> pump(WidgetTester tester, {Brightness brightness = Brightness.light}) async {
    usePhoneView(tester);
    addTearDown(voice.dispose);
    await tester.pumpWidget(
      testApp(
        Scaffold(
          body: Column(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Composer(
                  controller: input,
                  connected: true,
                  running: false,
                  onSend: () => sent++,
                  onStop: () {},
                  leading: AttachButton(onPressed: () {}),
                  voice: voice,
                ),
              ),
            ],
          ),
        ),
        brightness: brightness,
      ),
    );
    await tester.pump();
    await tester.pump();
  }
}

Finder get _mic => find.byIcon(AppIcons.voice);
Finder get _stop => find.byIcon(AppIcons.stopGenerating);
Finder get _cancel => find.byIcon(AppIcons.close);

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  setUpAll(loadTestFonts);

  testWidgets('the mic shows on an empty draft and gives way to send', (tester) async {
    final rig = _Rig();
    await rig.pump(tester);
    expect(_mic, findsOneWidget);
    expect(find.bySemanticsLabel('语音输入'), findsOneWidget);
    rig.input.text = '你好';
    await _settle(tester);
    expect(_mic, findsNothing);
    expect(find.byIcon(AppIcons.send), findsOneWidget);
  });

  testWidgets('no recognizer and no engine: no mic', (tester) async {
    final rig = _Rig(bridge: FakeVoiceBridge(caps: VoiceCapabilities.none));
    await rig.pump(tester);
    expect(_mic, findsNothing);
    expect(find.byIcon(AppIcons.send), findsOneWidget);
  });

  testWidgets('the recorder alone needs the engine recognizer', (tester) async {
    final bridge = FakeVoiceBridge(caps: const VoiceCapabilities(recognizer: false, recorder: true));
    // Bundle off: `speech/*` is not served.
    final rig = _Rig(bridge: bridge, client: DshClient.withCarrier(FakeRpcCarrier({})));
    await rig.pump(tester);
    expect(_mic, findsNothing);
  });

  testWidgets('system recognizer: partials stream in, the final stays', (tester) async {
    final rig = _Rig();
    await rig.pump(tester);
    await tester.tap(_mic);
    await _settle(tester);
    expect(rig.bridge.calls, ['permission', 'recognizer']);
    expect(rig.voice.phase, VoicePhase.listening);
    expect(_cancel, findsOneWidget);
    expect(_stop, findsOneWidget);
    expect(find.byType(VoiceWaveform), findsOneWidget);
    expect(find.text('正在聆听…'), findsOneWidget);
    expect(find.byIcon(AppIcons.add), findsNothing);

    rig.bridge.emit(const VoiceLevel(0.8));
    rig.bridge.emit(const VoicePartial('帮我看看'));
    await tester.pump();
    expect(rig.input.text, '帮我看看');
    expect(rig.input.provisional, const TextRange(start: 0, end: 4));

    rig.bridge.emit(const VoicePartial('帮我看看日志'));
    rig.bridge.emit(const VoiceFinal('帮我看看日志'));
    await _settle(tester);
    expect(rig.input.text, '帮我看看日志');
    expect(rig.input.provisional, TextRange.empty);
    expect(rig.voice.phase, VoicePhase.idle);
    expect(find.byIcon(AppIcons.add), findsOneWidget);
    expect(find.byIcon(AppIcons.send), findsOneWidget);
    expect(rig.sent, 0);
  });

  testWidgets('stop waits for the final text', (tester) async {
    final rig = _Rig();
    await rig.pump(tester);
    await tester.tap(_mic);
    await _settle(tester);
    rig.bridge.emit(const VoicePartial('明天'));
    await tester.pump();
    await tester.tap(_stop);
    await tester.pump();
    expect(rig.bridge.calls.last, 'stop');
    expect(rig.voice.phase, VoicePhase.transcribing);
    expect(find.text('明天'), findsOneWidget);
    rig.bridge.emit(const VoiceFinal('明天下午三点'));
    rig.bridge.emit(const VoiceEnd());
    await _settle(tester);
    expect(rig.input.text, '明天下午三点');
    expect(rig.voice.phase, VoicePhase.idle);
  });

  testWidgets('✕ puts the draft back', (tester) async {
    final rig = _Rig();
    await rig.pump(tester);
    await tester.tap(_mic);
    await _settle(tester);
    rig.bridge.emit(const VoicePartial('算了'));
    await tester.pump();
    await tester.tap(_cancel);
    await _settle(tester);
    expect(rig.input.text, '');
    expect(rig.bridge.calls.last, 'cancel');
    expect(_mic, findsOneWidget);
  });

  testWidgets('nothing heard: a short note, the draft unchanged', (tester) async {
    final rig = _Rig();
    await rig.pump(tester);
    await tester.tap(_mic);
    await _settle(tester);
    rig.bridge.emit(const VoiceError(7));
    await _settle(tester);
    expect(find.text('没有听清，再说一次'), findsOneWidget);
    expect(rig.input.text, '');
    expect(rig.voice.phase, VoicePhase.idle);
  });

  testWidgets('permission: denied explains, blocked offers Settings', (tester) async {
    final rig = _Rig(bridge: FakeVoiceBridge(permission: VoicePermission.denied));
    await rig.pump(tester);
    await tester.tap(_mic);
    await _settle(tester);
    expect(find.text('需要麦克风权限才能语音输入'), findsOneWidget);
    expect(rig.bridge.calls, ['permission']);
    expect(rig.voice.phase, VoicePhase.idle);

    rig.bridge.permission = VoicePermission.blocked;
    ScaffoldMessenger.of(tester.element(find.byType(Composer))).removeCurrentSnackBar();
    await _settle(tester);
    await tester.tap(_mic);
    await _settle(tester);
    expect(find.text('麦克风权限已关闭'), findsOneWidget);
    await tester.tap(find.text('去设置'));
    await tester.pump();
    expect(rig.bridge.calls.last, 'settings');
  });

  testWidgets('both available: a downloaded voice model wins over the phone service', (tester) async {
    final carrier = FakeRpcCarrier({'speech/catalog': (_) => readySpeechCatalog()});
    final rig = _Rig(client: DshClient.withCarrier(carrier), modelReady: true);
    await rig.pump(tester);
    await tester.tap(_mic);
    await _settle(tester);
    // Phone services on Chinese ROMs report themselves available and then fail.
    expect(rig.bridge.calls, ['permission', 'recorder:119']);
    expect(rig.voice.engine, VoiceEngine.engine);
    await tester.tap(_cancel);
    await _settle(tester);
  });

  testWidgets('model not downloaded: the system recognizer wins (live text)', (tester) async {
    final carrier = FakeRpcCarrier({'speech/catalog': (_) => readySpeechCatalog()});
    final rig = _Rig(client: DshClient.withCarrier(carrier));
    await rig.pump(tester);
    await tester.tap(_mic);
    await _settle(tester);
    expect(rig.bridge.calls, ['permission', 'recognizer']);
    expect(rig.voice.engine, VoiceEngine.system);
    // With a recognizer on the phone and no model of its own the engine is not even asked.
    expect(carrier.calls, isEmpty);
    await tester.tap(_cancel);
    await _settle(tester);
  });

  testWidgets('no system recognizer: the engine records, then transcribes', (tester) async {
    final carrier = FakeRpcCarrier({
      'speech/catalog': (_) => readySpeechCatalog(),
      'speech/transcribe': (_) => {'text': '把测试再跑一遍', 'audioSeconds': 1.0, 'inferenceSeconds': 0.3},
    });
    // A ROM without Google: no recognition service.
    final bridge = FakeVoiceBridge(caps: const VoiceCapabilities(recognizer: false, recorder: true))
      ..recording = silentWav(1);
    final rig = _Rig(bridge: bridge, client: DshClient.withCarrier(carrier));
    await rig.pump(tester);
    expect(_mic, findsOneWidget);
    await tester.tap(_mic);
    await _settle(tester);
    expect(bridge.calls, ['permission', 'recorder:119']);
    expect(rig.voice.engine, VoiceEngine.engine);
    bridge.emit(const VoiceLevel(0.5));
    await tester.pump();
    await tester.tap(_stop);
    await tester.pump();
    await _settle(tester);
    expect(rig.input.text, '把测试再跑一遍');
    final request = carrier.argsOf('speech/transcribe').single['request'] as Map;
    expect(request['providerId'], 'sensevoice-local');
    expect(request['language'], 'auto');
    expect(base64Decode(request['audioBase64'] as String), silentWav(1));
  });

  testWidgets('engine recognizer: a too-short recording is not sent', (tester) async {
    final carrier = FakeRpcCarrier({'speech/catalog': (_) => readySpeechCatalog(phase: 'ready')});
    final bridge = FakeVoiceBridge(caps: const VoiceCapabilities(recognizer: false, recorder: true))
      ..recording = silentWav(0.1);
    final rig = _Rig(bridge: bridge, client: DshClient.withCarrier(carrier));
    await rig.pump(tester);
    await tester.tap(_mic);
    await _settle(tester);
    await tester.tap(_stop);
    await _settle(tester);
    expect(carrier.argsOf('speech/transcribe'), isEmpty);
    expect(find.text('没有听清，再说一次'), findsOneWidget);
  });

  testWidgets('Latin words get a space at the seam, CJK does not', (tester) async {
    final bridge = FakeVoiceBridge();
    final input = MentionTextController(text: 'run');
    final voice = VoiceInputController(input: input, bridge: bridge, client: () => null, observeLifecycle: false);
    addTearDown(voice.dispose);
    input.selection = const TextSelection.collapsed(offset: 3);
    await voice.start();
    bridge.emit(const VoiceFinal('the tests'));
    await tester.pump();
    expect(input.text, 'run the tests');

    input.value = const TextEditingValue(text: '跑一下', selection: TextSelection.collapsed(offset: 3));
    await voice.start();
    bridge.emit(const VoiceFinal('测试'));
    await tester.pump();
    expect(input.text, '跑一下测试');
  });

  for (final brightness in Brightness.values) {
    testWidgets('golden: mic, then dictating (${brightness.name})', (tester) async {
      final rig = _Rig();
      await rig.pump(tester, brightness: brightness);
      await expectLater(find.byType(Composer), matchesGoldenFile('goldens/composer_voice_idle_${brightness.name}.png'));
      await tester.tap(_mic);
      await _settle(tester);
      for (final level in [0.2, 0.7, 1.0, 0.5, 0.3]) {
        rig.bridge.emit(VoiceLevel(level));
        await tester.pump(const Duration(milliseconds: 60));
      }
      rig.bridge.emit(const VoicePartial('帮我看看昨天的构建日志'));
      await _settle(tester);
      await expectLater(
        find.byType(Composer),
        matchesGoldenFile('goldens/composer_voice_listening_${brightness.name}.png'),
      );
    });
  }
}

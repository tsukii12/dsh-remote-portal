import 'package:dsh_app/speech/deepseek_speech.dart';
import 'package:dsh_app/speech/voice_cloud.dart';
import 'package:dsh_app/state/voice_settings.dart';
import 'package:dsh_app/ui/chat/voice/voice_bridge.dart';
import 'package:dsh_app/ui/chat/voice/voice_controller.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../chat/support/composer_fakes.dart';
import 'speech_fakes.dart';

class _Rig {
  _Rig({required VoiceMode mode, VoiceCloud? cloud, VoiceCapabilities? caps, bool live = false}) {
    if (caps != null) bridge.caps = caps;
    voice = VoiceInputController(
      input: input,
      bridge: bridge,
      client: () => null,
      mode: () async => mode,
      cloud: (asked) async {
        modes.add(asked);
        return cloud;
      },
      observeLifecycle: false,
      liveWords: live
          ? (onWords) async {
              words = onWords;
              return null;
            }
          : null,
    );
    voice.onMessage = (message) => messages.add(message);
    addTearDown(() {
      voice.dispose();
      input.dispose();
    });
  }

  final bridge = FakeVoiceBridge()..recording = silentWav(1);
  final input = TextEditingController(text: '前面 ');
  final messages = <VoiceMessage>[];
  final modes = <VoiceMode>[];
  void Function(String)? words;
  late VoiceInputController voice;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('automatic: DeepSeek records, recognizes, and fills the draft', (tester) async {
    final cloud = FakeCloud('你好世界');
    final rig = _Rig(mode: VoiceMode.auto, cloud: cloud);
    rig.input.selection = const TextSelection.collapsed(offset: 3);
    await rig.voice.start();
    expect(rig.voice.engine, VoiceEngine.cloud);
    expect(rig.voice.phase, VoicePhase.listening);
    expect(rig.bridge.calls, contains('recorder:118'));
    expect(rig.bridge.calls, isNot(contains('recognizer')));
    await rig.voice.stop();
    expect(cloud.heard, hasLength(1));
    expect(rig.input.text, '前面 你好世界');
    expect(rig.voice.phase, VoicePhase.idle);
  });

  testWidgets('live words show in the draft while recording; the recording\'s text replaces them', (tester) async {
    final rig = _Rig(mode: VoiceMode.auto, cloud: FakeCloud('你好世界'), live: true);
    rig.input.selection = const TextSelection.collapsed(offset: 3);
    await rig.voice.start();
    await tester.pump();
    rig.words!('你好');
    expect(rig.input.text, '前面 你好');
    rig.words!('你好世');
    expect(rig.input.text, '前面 你好世');
    await rig.voice.stop();
    expect(rig.input.text, '前面 你好世界');
    // Late words after the end change nothing.
    rig.words!('你好世界啊');
    expect(rig.input.text, '前面 你好世界');
  });

  testWidgets('live words the recording does not confirm go: the draft is as it was', (tester) async {
    final rig = _Rig(mode: VoiceMode.auto, cloud: FakeCloud()..fail = StateError('offline'), live: true);
    final before = rig.input.text;
    await rig.voice.start();
    await tester.pump();
    rig.words!('你好');
    expect(rig.input.text, isNot(before));
    await rig.voice.stop();
    expect(rig.input.text, before);
  });

  testWidgets('automatic sends audio to DeepSeek unasked: said once, with 更换', (tester) async {
    final rig = _Rig(mode: VoiceMode.auto, cloud: FakeCloud());
    await rig.voice.start();
    await tester.pump();
    await rig.voice.stop();
    await rig.voice.start();
    await tester.pump();
    final notices = rig.messages.where((m) => m.change && m.text.contains('DeepSeek')).toList();
    expect(notices, hasLength(1));
  });

  testWidgets('automatic without anyone to pay: the phone service as before', (tester) async {
    final rig = _Rig(mode: VoiceMode.auto);
    await rig.voice.start();
    expect(rig.voice.engine, VoiceEngine.system);
    expect(rig.bridge.calls, contains('recognizer'));
  });

  testWidgets('DeepSeek chosen but nobody to pay: says so and offers 更换', (tester) async {
    final rig = _Rig(mode: VoiceMode.deepseek);
    await rig.voice.start();
    expect(rig.voice.phase, VoicePhase.idle);
    expect(rig.messages.single.change, isTrue);
    expect(rig.bridge.calls, isNot(contains('recognizer')));
  });

  testWidgets('a refused recognition keeps the draft and says why', (tester) async {
    final cloud = FakeCloud()..fail = const DeepSeekSpeechError(DeepSeekSpeechFailure.insufficientBalance);
    final rig = _Rig(mode: VoiceMode.deepseek, cloud: cloud);
    await rig.voice.start();
    await rig.voice.stop();
    expect(rig.input.text, '前面 ');
    expect(rig.messages.last.text, contains('余额'));
  });

  testWidgets('the system mode never asks for a cloud recognizer', (tester) async {
    final rig = _Rig(mode: VoiceMode.system, cloud: FakeCloud());
    await rig.voice.start();
    expect(rig.modes, isEmpty);
    expect(rig.voice.engine, VoiceEngine.system);
  });

  testWidgets('the recorder hitting its limit stops and recognizes', (tester) async {
    final cloud = FakeCloud('够长了');
    final rig = _Rig(mode: VoiceMode.deepseek, cloud: cloud);
    await rig.voice.start();
    rig.bridge.emit(const VoiceLimit());
    await tester.pump();
    await tester.pump();
    expect(cloud.heard, hasLength(1));
    expect(rig.input.text, contains('够长了'));
  });
}

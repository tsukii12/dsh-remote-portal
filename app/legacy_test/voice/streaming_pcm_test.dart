import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dsh_app/ui/chat/voice/voice_bridge.dart';
import 'package:dsh_app/voice/streaming_pcm.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const methods = MethodChannel('dsh/voice');
  const eventsChannel = MethodChannel('dsh/voice/events');
  const codec = StandardMethodCodec();

  Future<void> emit(Map<String, Object> event) async {
    final done = Completer<void>();
    ServicesBinding.instance.channelBuffers.push(
      'dsh/voice/events',
      codec.encodeSuccessEnvelope(event),
      (_) => done.complete(),
    );
    await done.future;
    await Future<void>.delayed(Duration.zero);
  }

  tearDown(() {
    messenger.setMockMethodCallHandler(methods, null);
    messenger.setMockMethodCallHandler(eventsChannel, null);
  });

  test('dictation and PCM share one EventChannel without cancelling each other', () async {
    var listens = 0;
    var cancels = 0;
    var voiceSession = 0;
    var pcmSession = 0;
    messenger.setMockMethodCallHandler(eventsChannel, (call) async {
      if (call.method == 'listen') listens++;
      if (call.method == 'cancel') cancels++;
      return null;
    });
    messenger.setMockMethodCallHandler(methods, (call) async {
      final args = call.arguments as Map;
      if (call.method == 'startRecorder') voiceSession = args['sessionId'] as int;
      if (call.method == 'streamingPcm' && args['source'] != null) pcmSession = args['pcmSession'] as int;
      return null;
    });
    final bridge = MethodChannelVoiceBridge();
    final pcm = StreamingPcmCapture();
    final words = <VoiceEvent>[];
    final frames = <Uint8List>[];
    final wordsSubscription = bridge.events.listen(words.add);
    final frameSubscription = pcm.frames.listen(frames.add);
    await bridge.startRecorder(maxSeconds: 60);
    await pcm.start(StreamingPcmSource.dictation);
    expect(listens, 1);
    await emit({'type': 'partial', 'text': 'hello', 'sessionId': voiceSession});
    await emit({'type': 'pcm', 'rate': 16000, 'bytes': Uint8List(640), 'pcmSession': pcmSession});
    expect(words.single, isA<VoicePartial>());
    expect(frames, hasLength(1));
    await wordsSubscription.cancel();
    expect(cancels, 0);
    await emit({'type': 'pcm', 'rate': 16000, 'bytes': Uint8List(640), 'pcmSession': pcmSession});
    expect(frames, hasLength(2));
    final old = pcmSession;
    await pcm.stop();
    expect(cancels, 1);
    await pcm.start(StreamingPcmSource.call);
    await emit({'type': 'pcm', 'rate': 16000, 'bytes': Uint8List(640), 'pcmSession': old});
    await emit({'type': 'pcm', 'rate': 48000, 'bytes': Uint8List(640), 'pcmSession': pcmSession});
    await emit({'type': 'pcm', 'rate': 16000, 'bytes': Uint8List(2), 'pcmSession': pcmSession});
    expect(frames, hasLength(2));
    await emit({'type': 'pcm', 'rate': 16000, 'bytes': Uint8List(640), 'pcmSession': pcmSession});
    expect(frames, hasLength(3));
    await pcm.dispose();
    await frameSubscription.cancel();
  });

  test('stop waits for an in-flight enable and disables its own session', () async {
    final incoming = StreamController<dynamic>.broadcast();
    final entered = Completer<void>();
    final release = Completer<void>();
    final calls = <Map>[];
    messenger.setMockMethodCallHandler(methods, (call) async {
      final args = call.arguments as Map;
      calls.add(args);
      if (args['source'] != null) {
        entered.complete();
        await release.future;
      }
      return null;
    });
    final pcm = StreamingPcmCapture(platformEvents: incoming.stream);
    final started = pcm.start(StreamingPcmSource.call);
    await entered.future;
    final stopped = pcm.stop();
    release.complete();
    await Future.wait([started, stopped]);
    expect(calls, hasLength(2));
    expect(calls.last['pcmSession'], calls.first['pcmSession']);
    expect(calls.last.containsKey('source'), isFalse);
    await pcm.dispose();
    await incoming.close();
  });
}

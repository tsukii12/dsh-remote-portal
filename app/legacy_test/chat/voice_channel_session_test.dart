import 'package:dsh_app/ui/chat/voice/voice_bridge.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('actual MethodChannel bridge rejects retired recognizer and recorder events', (tester) async {
    const methods = MethodChannel('dsh/voice');
    const events = MethodChannel('dsh/voice/events');
    final messenger = tester.binding.defaultBinaryMessenger;
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(methods, (call) async {
      calls.add(call);
      if (call.method == 'capabilities') {
        return {'recognizer': true, 'recorder': true, 'systemUnreliable': true, 'environmentId': 'versioned-service'};
      }
      return null;
    });
    messenger.setMockMethodCallHandler(events, (_) async => null);
    final bridge = MethodChannelVoiceBridge();
    final received = <VoiceEvent>[];
    final subscription = bridge.events.listen(received.add);
    await tester.pump();
    addTearDown(() async {
      await subscription.cancel();
      await messenger.handlePlatformMessage(events.name, null, (_) {});
      messenger.setMockMethodCallHandler(methods, null);
      messenger.setMockMethodCallHandler(events, null);
    });
    Future<void> native(Map<String, Object?> event) async {
      await messenger.handlePlatformMessage(
        events.name,
        const StandardMethodCodec().encodeSuccessEnvelope(event),
        (_) {},
      );
      await tester.pump();
    }

    final caps = await bridge.capabilities();
    expect(caps.systemUnreliable, isTrue);
    expect(caps.environmentId, 'versioned-service');
    await bridge.startRecognizer();
    final system = (calls.last.arguments as Map)['sessionId'];
    await native({'type': 'partial', 'text': 'current speech', 'sessionId': system});
    expect(received.whereType<VoicePartial>().single.text, 'current speech');
    await bridge.startRecorder(maxSeconds: 30);
    final recorder = (calls.last.arguments as Map)['sessionId'];
    expect(recorder, isNot(system));
    await native({'type': 'end', 'sessionId': system});
    await native({'type': 'error', 'code': 5, 'sessionId': system});
    await native({'type': 'partial', 'text': 'stale speech', 'sessionId': system});
    await native({'type': 'error', 'code': 5});
    await native({'type': 'level', 'value': 0.5, 'sessionId': recorder});
    expect(received, hasLength(2));
    expect(received.last, isA<VoiceLevel>());
    await bridge.cancel();
    await native({'type': 'limit', 'sessionId': recorder});
    await native({'type': 'end', 'sessionId': recorder});
    expect(received, hasLength(2));
    expect(calls.map((c) => c.method), ['capabilities', 'startRecognizer', 'startRecorder', 'cancel']);
    for (final call in calls) {
      expect('${call.arguments}', isNot(contains('current speech')));
      expect('${call.arguments}', isNot(contains('stale speech')));
    }
  });
}

import 'package:dsh_app/ui/features/schedule_editor/time_zones.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dsh/app');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <MethodCall>[];

  void respond(Future<Object?> Function(MethodCall) handler) {
    messenger.setMockMethodCallHandler(channel, (call) {
      calls.add(call);
      return handler(call);
    });
  }

  setUp(calls.clear);
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('Android channel returns the system zone rather than the offset preference', () async {
    respond((_) async => ' America/Phoenix ');
    expect(await detectAndroidTimeZone(fallbackOffset: const Duration(hours: 8)), 'America/Phoenix');
    expect(calls.single.method, 'getTimeZoneId');
    expect(calls.single.arguments, isNull);
  });

  test('empty Android zone falls back to the existing preferred offset zone', () async {
    respond((_) async => '  ');
    expect(await detectAndroidTimeZone(fallbackOffset: const Duration(hours: 8)), 'Asia/Shanghai');
    expect(calls, hasLength(1));
  });

  test('unknown Android zone falls back to the existing preferred offset zone', () async {
    respond((_) async => 'Unknown/Zone');
    expect(await detectAndroidTimeZone(fallbackOffset: const Duration(hours: 5, minutes: 30)), 'Asia/Kolkata');
  });

  test('Android platform failure falls back without throwing', () async {
    respond((_) async => throw PlatformException(code: 'unavailable'));
    expect(await detectAndroidTimeZone(fallbackOffset: const Duration(hours: 9)), 'Asia/Tokyo');
  });

  test('null result and unmatched offset reach UTC', () async {
    respond((_) async => null);
    expect(await detectAndroidTimeZone(fallbackOffset: const Duration(hours: 25)), 'UTC');
  });

  test('missing activity channel uses the offset fallback', () async {
    expect(await detectAndroidTimeZone(fallbackOffset: const Duration(hours: 7)), 'Asia/Bangkok');
  });

  test('a known zero-offset zone is accepted without replacing it with London', () async {
    respond((_) async => 'UTC');
    expect(await detectAndroidTimeZone(fallbackOffset: Duration.zero), 'UTC');
  });
}

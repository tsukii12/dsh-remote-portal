import 'dart:convert';
import 'dart:io';

import 'package:dsh_client/dsh_client.dart';
import 'package:test/test.dart';

import 'dsbot_api_test.dart' show FakeDsBot;

void main() {
  final fixture = jsonDecode(File('test/fixtures/dsbot_truncated_post.json').readAsStringSync()) as Map;
  final partial = (fixture['unit'] as String) * (fixture['inputRepeats'] as int);
  final text = partial.substring(0, fixture['textLength'] as int);
  final long = DsBotLongText(partial.length, {'attachmentId': 'synthetic'});
  late FakeDsBot host;
  late DsBotApi api;
  setUp(() async {
    host = await FakeDsBot.start();
    api = DsBotApi(
      DsBotHttpTransport(
        DshConnection(
          host.baseUri,
          cookie: DshCookie(name: 'dsh-auth-test', value: 'v1.payload.sig', authority: '127.0.0.1:${host.port}'),
        ),
      ),
    );
  });
  tearDown(() async {
    await api.close();
    await host.close();
  });

  test('actual truncated response retains whole false, exact preview and payload', () async {
    host.handlers['file-text'] = (_) => {'text': text, 'whole': fixture['whole']};
    final result = await api.readFileText(long);
    expect(result.text, text);
    expect(result.text.length, 200000);
    expect(result.whole, isFalse);
    expect(host.calls.single['payload'], {'file': long.file});
    expect(await api.fileText(long), text); // Existing text-only callers stay compatible.
  });
  test('actual complete response retains whole true', () async {
    host.handlers['file-text'] = (_) => fixture['complete'];
    final result = await api.readFileText(long);
    expect(result.text, fixture['complete']['text']);
    expect(result.whole, isTrue);
  });
  for (final meta in [null, 'false', 0]) {
    test('unknown completeness metadata $meta is not guessed', () async {
      host.handlers['file-text'] = (_) => {'text': 'synthetic', 'whole': ?meta};
      expect((await api.readFileText(long)).whole, isNull);
    });
  }
  test('legacy string has unknown completeness', () async {
    host.handlers['file-text'] = (_) => 'legacy synthetic';
    final result = await api.readFileText(long);
    expect(result.text, 'legacy synthetic');
    expect(result.whole, isNull);
  });
  for (final bad in [
    null,
    42,
    {'whole': true},
    {'text': false, 'whole': true},
  ]) {
    test('malformed response $bad is not silently an empty complete document', () async {
      host.handlers['file-text'] = (_) => bad;
      await expectLater(api.readFileText(long), throwsFormatException);
    });
  }
}

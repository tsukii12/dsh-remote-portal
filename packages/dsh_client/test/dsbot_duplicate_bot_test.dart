import 'dart:convert';
import 'dart:io';

import 'package:dsh_client/dsh_client.dart';
import 'package:test/test.dart';

import 'dsbot_api_test.dart' show FakeDsBot;

void main() {
  final fixture = jsonDecode(File('test/fixtures/dsbot_duplicate_bot.json').readAsStringSync()) as Map;
  test('official duplicate replies retain settings with unique fresh identities', () {
    final original = DsBot.fromJson(fixture['original']['value']);
    final first = DsBot.fromJson(fixture['first']['value']);
    final second = DsBot.fromJson(fixture['second']['value']);
    expect(first.id, isNot(original.id));
    expect(second.id, isNot(first.id));
    expect(first.name, isNot(second.name));
    expect(first.role, original.role);
    expect(first.instructions, original.instructions);
    expect(first.workDir, original.workDir);
    expect(DsBot.fromJson(fixture['missingFolder']['value']).workDir, isNull);
    expect(fixture['absent']['ok'], false);
  });
  test('duplicate uses the existing endpoint with only the source id', () async {
    final host = await FakeDsBot.start();
    final api = DsBotApi(
      DsBotHttpTransport(
        DshConnection(
          host.baseUri,
          cookie: DshCookie(name: 'dsh-auth-test', value: 'v1.payload.sig', authority: '127.0.0.1:${host.port}'),
        ),
      ),
    );
    addTearDown(() async {
      await api.close();
      await host.close();
    });
    host.handlers['duplicate-bot'] = (_) => fixture['first']['value'];
    final bot = await api.duplicateBot('source-id');
    expect(bot.id, fixture['first']['value']['id']);
    expect(host.calls.single['endpoint'], 'duplicate-bot');
    expect(host.calls.single['payload'], {'id': 'source-id'});
  });
}

import 'dart:convert';
import 'dart:io';
import 'package:dsh_client/dsh_client.dart';
import 'package:test/test.dart';
import 'dsbot_api_test.dart' show FakeDsBot;

void main() {
  final fixture = jsonDecode(File('test/fixtures/dsbot_working_folder.json').readAsStringSync()) as Map;
  test('real upstream folder catalog and Bot/Room custom/reset snapshots', () {
    final catalog = DsBotFolders.fromJson(fixture['folders']['value']);
    expect(catalog.folders.single.path, fixture['botCustom']['workDir']);
    expect(catalog.team, isNotEmpty);
    expect(DsBot.fromJson(fixture['botCustom']).workDir, catalog.folders.single.path);
    expect(DsBotRoom.fromJson(fixture['roomCustom']).workDir, catalog.folders.single.path);
    expect(DsBot.fromJson(fixture['botReset']['value']).workDir, isNull);
    expect(DsBotRoom.fromJson(fixture['roomReset']['value']['room']).workDir, isNull);
    for (final failure in fixture['invalid'] as List) {
      expect(failure['response']['ok'], false);
    }
    expect(fixture['afterInvalid']['workDir'], fixture['botCustom']['workDir']);
  });
  test('HTTP catalog and writes preserve exact path and explicit empty reset', () async {
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
    host.handlers['folders'] = (_) => fixture['folders']['value'];
    host.handlers['update-bot'] = (_) => fixture['botSet']['value'];
    host.handlers['update-room'] = (_) => fixture['roomSet']['value'];
    final catalog = await api.folders();
    final path = catalog.folders.single.path;
    await api.setBotWorkDir('b', path);
    await api.setRoomWorkDir('r', path);
    await api.setBotWorkDir('b', '');
    await api.setRoomWorkDir('r', '');
    expect(host.calls.skip(1).map((c) => c['payload']), [
      {'id': 'b', 'workDir': path},
      {'id': 'r', 'workDir': path},
      {'id': 'b', 'workDir': ''},
      {'id': 'r', 'workDir': ''},
    ]);
  });
}

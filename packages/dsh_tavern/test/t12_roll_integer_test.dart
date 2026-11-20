import 'dart:io';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:test/test.dart';

import 'support/t24_engine_harness.dart';

void main() {
  test('roll uses binary64 for each die and adds the modifier after the dice sum', () {
    var draws = 0;
    final context = MacroContext(
      random: () {
        draws++;
        return 0.5;
      },
    );
    const engine = MacroEngine();
    // Fixed ST 7e8663cd delegates to droll 0.2.1. Its dice sum starts at
    // zero, then receives the modifier once. Each row uses at most two dice.
    for (final row in const [
      ('1d1+9007199254740992', '9007199254740992', 1),
      ('2d1+9007199254740992', '9007199254740994', 2),
      ('1d18014398509481984', '9007199254740992', 1),
      ('1d1-9007199254740992', '-9007199254740991', 1),
      ('1d1-1', '0', 1),
    ]) {
      final before = draws;
      expect(engine.expand('{{roll::${row.$1}}}', context), row.$2, reason: row.$1);
      expect(draws - before, row.$3, reason: row.$1);
    }
  });

  test('modern sendOnly roll preserves binary64 integer output through reopen', () async {
    final root = await Directory.systemTemp.createTemp('dsh-t12-roll-integer-');
    TavernEngine? ownedEngine;
    addTearDown(() async {
      await ownedEngine?.close();
      if (await root.exists()) await root.delete(recursive: true);
      expect(await root.exists(), isFalse);
      stdout.writeln('ROLL_INTEGER_CLEANUP');
    });
    final model = T24Model();
    var keyReads = 0;
    final config = TavernModelConfig(
      apiKey: () async {
        keyReads++;
        return 'fixture-key';
      },
      model: 'roll-oracle',
    );
    var draws = 0;
    Future<TavernEngine> open() => TavernEngine.openDirectory(
      root,
      config: config,
      modelClient: model,
      random: () {
        draws++;
        return 0.5;
      },
    );
    var engine = await open();
    ownedEngine = engine;
    Tavern facade = engine;
    await facade.setSettings({'macroEngine': 'modern', 'globalRegexScripts': <Object?>[]});
    final character = await facade.importCard(t24Card());
    final chatId = await facade.createChat(character.id);
    final settings = await facade.readSettings(chatId: chatId);
    expect(settings['macroEngine'], 'modern');
    expect(settings['globalRegexScripts'], isEmpty);
    final greeting = (await facade.path(chatId)).single;
    expect(greeting.text, 'G');
    final ordinary = await facade.sendOnly(chatId, '{{roll::1d1+3}}');
    expect(ordinary.text, '4');
    expect(ordinary.parentId, greeting.nodeId);
    expect((await facade.path(chatId)).map((message) => (message.nodeId, message.text)), [
      (greeting.nodeId, 'G'),
      (ordinary.nodeId, '4'),
    ]);
    expect(draws, 1);
    expect(model.generated, 0);
    expect(keyReads, 0);
    expect(await facade.inspectTurn(chatId), isNull);
    stdout.writeln('ROLL_INTEGER_READY');

    final boundary = await facade.sendOnly(chatId, '{{roll::1d1+9007199254740992}}');
    // First target assertion: the whole public returned body, not a helper.
    // Old native S2 instead returns the literal 9007199254740993.
    expect(boundary.text, '9007199254740992');
    expect(boundary.role, TavernRole.user);
    expect(boundary.parentId, ordinary.nodeId);
    expect(draws, 2);
    final expected = [(greeting.nodeId, 'G'), (ordinary.nodeId, '4'), (boundary.nodeId, '9007199254740992')];
    expect((await facade.path(chatId)).map((message) => (message.nodeId, message.text)), expected);
    expect(model.generated, 0);
    expect(keyReads, 0);

    await facade.close();
    ownedEngine = null;
    engine = await open();
    ownedEngine = engine;
    facade = engine;
    expect((await facade.readSettings(chatId: chatId))['macroEngine'], 'modern');
    expect((await facade.path(chatId)).map((message) => (message.nodeId, message.text)), expected);
    expect(draws, 2);
    expect(model.generated, 0);
    expect(keyReads, 0);
    expect(await facade.inspectTurn(chatId), isNull);
  });
}

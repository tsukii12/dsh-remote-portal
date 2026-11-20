import 'dart:io';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:test/test.dart';

import 'support/t24_engine_harness.dart';

void main() {
  test('modern if bare-name lookup preserves JavaScript whitespace and random order', () {
    // Literal complete-output oracles from the original fixed-ST Registry and
    // if/random handlers. Each row has its own deterministic entropy sequence.
    const rows = <(String, String, String)>[
      ('ordinary bare name', 'random', '|A'),
      ('ordinary space suffix', 'random ', '|A'),
      ('NBSP BOM suffix', 'random\u00a0\ufeff', '|A'),
      ('NEL after SP', 'random \u0085', 'KEPT|A'),
      ('NEL after TAB', 'random\t\u0085', 'KEPT|A'),
      ('NEL after NBSP', 'random\u00a0\u0085', 'KEPT|A'),
      ('outside JS whitespace', ' random \u0085\ufeff', 'KEPT|A'),
      ('NEL adjacent without argument gap', 'random\u0085', 'KEPT|A'),
      ('NEL prefix', '\u0085random', 'KEPT|A'),
      ('NEL both edges', '\u0085random\u0085', 'KEPT|A'),
      ('ZWSP retained control', 'random \u200b', 'KEPT|A'),
      ('visible suffix blocks native trim match', 'random \u0085X', 'KEPT|A'),
    ];
    for (final row in rows) {
      const entropy = [0.0, 0.99];
      var draws = 0;
      final context = MacroContext(random: () => entropy[draws++]);
      final condition = row.$2;
      final actual = const MacroEngine().expand('{{if::$condition::KEPT}}|{{random::A::B}}', context);
      expect(actual, row.$3, reason: row.$1);
      expect(draws, 1, reason: row.$1);
    }
  });

  test('modern sendOnly preserves bare-name lookup random order through export and reopen', () async {
    final root = await Directory.systemTemp.createTemp('dsh-t12-canonical-lookup-');
    TavernEngine? ownedEngine;
    addTearDown(() async {
      try {
        await ownedEngine?.close();
      } finally {
        if (await root.exists()) await root.delete(recursive: true);
      }
      expect(await root.exists(), isFalse);
      stdout.writeln('CANONICAL_LOOKUP_CLEANUP');
    });
    final model = T24Model();
    var keyReads = 0;
    final config = TavernModelConfig(
      apiKey: () async {
        keyReads++;
        return 'fixture-key';
      },
      model: 'canonical-lookup-oracle',
    );
    const entropy = [0.0, 0.99];
    var position = 0;
    var totalDraws = 0;
    double nextRandom() {
      totalDraws++;
      return entropy[position++];
    }

    Future<TavernEngine> open() =>
        TavernEngine.openDirectory(root, config: config, modelClient: model, random: nextRandom);
    var engine = await open();
    ownedEngine = engine;
    Tavern facade = engine;
    await facade.setSettings({'macroEngine': 'modern', 'globalRegexScripts': <Object?>[]});
    final character = await facade.importCard(t24Card());
    final chatId = await facade.createChat(character.id);
    final greeting = (await facade.path(chatId)).single;
    expect(greeting.text, 'G');
    expect(greeting.role, TavernRole.character);
    expect(greeting.parentId, isNull);

    final ordinary = await facade.sendOnly(chatId, '{{if::truthy::KEPT}}|{{random::A::B}}');
    expect(ordinary.text, 'KEPT|A');
    expect(position, 1);
    expect(totalDraws, 1);
    final beforeTarget = [
      (greeting.nodeId, null, TavernRole.character, 'G'),
      (ordinary.nodeId, greeting.nodeId, TavernRole.user, 'KEPT|A'),
    ];
    expect(
      (await facade.path(chatId)).map((message) => (message.nodeId, message.parentId, message.role, message.text)),
      beforeTarget,
    );
    final ordinaryFile = (await facade.exportChat(chatId)).single;
    final ordinaryDocument = StChatDocument.decode(ordinaryFile.fileName, ordinaryFile.bytes);
    expect(ordinaryDocument.messages.map((message) => message['mes']), ['G', 'KEPT|A']);
    final settings = await facade.readSettings(chatId: chatId);
    expect(settings['macroEngine'], 'modern');
    expect(settings['globalRegexScripts'], isEmpty);
    expect(await facade.readVariables(chatId), isEmpty);
    expect(await facade.inspectTurn(chatId), isNull);
    expect(model.generated, 0);
    expect(keyReads, 0);

    // Reset only the sequence cursor. Keep the total across both public sends.
    position = 0;
    stdout.writeln('CANONICAL_LOOKUP_READY');
    final boundary = await facade.sendOnly(chatId, '{{if::random \u0085::KEPT}}|{{random::A::B}}');
    // First target assertion. Raw097 predicts KEPT|B after one extra draw.
    expect(boundary.text, 'KEPT|A');
    expect(position, 1);
    expect(totalDraws, 2);
    final expected = [...beforeTarget, (boundary.nodeId, ordinary.nodeId, TavernRole.user, 'KEPT|A')];
    Future<void> checkSaved() async {
      final path = await facade.path(chatId);
      expect(path.map((message) => (message.nodeId, message.parentId, message.role, message.text)), expected);
      final file = (await facade.exportChat(chatId)).single;
      final document = StChatDocument.decode(file.fileName, file.bytes);
      expect(document.messages.map((message) => message['mes']), ['G', 'KEPT|A', 'KEPT|A']);
      expect(await facade.readVariables(chatId), isEmpty);
      expect(await facade.inspectTurn(chatId), isNull);
      expect(position, 1);
      expect(totalDraws, 2);
      expect(model.generated, 0);
      expect(keyReads, 0);
    }

    await checkSaved();

    await facade.close();
    ownedEngine = null;
    engine = await open();
    ownedEngine = engine;
    facade = engine;
    final reopenedSettings = await facade.readSettings(chatId: chatId);
    expect(reopenedSettings['macroEngine'], 'modern');
    expect(reopenedSettings['globalRegexScripts'], isEmpty);
    await checkSaved();
  });
}

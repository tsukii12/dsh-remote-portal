import 'dart:io';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:test/test.dart';

import 'support/t24_engine_harness.dart';

void main() {
  test('legacy roll preserves JavaScript whitespace before droll validation', () {
    // Literal complete-output/count oracles from fixed ST getDiceRollMacro
    // and official droll 0.2.1. Each row starts a new counted [0, 0.99] sequence.
    const rows = <(String, String, String, int)>[
      ('ordinary colon dice', 'L{{roll:1d1}}R', 'L1R', 1),
      ('ordinary space numeric shorthand', 'L{{roll 6}}R', 'L1R', 1),
      ('macro and D case insensitive', 'L{{RoLl:1D6}}R', 'L1R', 1),
      ('JS exterior whitespace', 'L{{roll: \t\u00a0\ufeff1d1\u2003\u3000 }}R', 'L1R', 1),
      ('NEL dice prefix', 'L{{roll:\u00851d1}}R', 'LR', 0),
      ('NEL dice suffix', 'L{{roll:1d1\u0085}}R', 'LR', 0),
      ('NEL dice both edges', 'L{{roll:\u00851d1\u0085}}R', 'LR', 0),
      ('NEL numeric prefix', 'L{{roll:\u00856}}R', 'LR', 0),
      ('NEL numeric suffix', 'L{{roll:6\u0085}}R', 'LR', 0),
      ('NEL numeric both edges', 'L{{roll:\u00856\u0085}}R', 'LR', 0),
      ('interior NEL remains invalid', 'L{{roll:1d\u00851}}R', 'LR', 0),
      ('NEL alone is not a formula', 'L{{roll:\u0085}}R', 'LR', 0),
      ('double colon is not legacy formula syntax', 'L{{roll::1d1}}R', 'LR', 0),
      ('empty capture remains literal', 'L{{roll:}}R', 'L{{roll:}}R', 0),
      ('LF CR exterior whitespace', 'L{{roll:\n1d1\r}}R', 'L1R', 1),
      ('visible suffix blocks native edge trim', 'L{{roll:1d1\u0085X}}R', 'LR', 0),
      ('ordinary pair consumes in text order', 'L{{roll:1d1}}R|{{roll:1d6}}', 'L1R|6', 2),
      ('NEL rejection preserves the following roll draw', 'L{{roll:\u00851d1\u0085}}R|{{roll:1d6}}', 'LR|1', 1),
    ];
    for (final row in rows) {
      const entropy = [0.0, 0.99];
      var draws = 0;
      final context = MacroContext(random: () => entropy[draws++]);
      final actual = const LegacyMacroEngine().expand(row.$2, context);
      expect(actual, row.$3, reason: row.$1);
      expect(draws, row.$4, reason: row.$1);
    }
  });

  test('legacy sendOnly roll rejection preserves random order through export and reopen', () async {
    final root = await Directory.systemTemp.createTemp('dsh-t12-legacy-roll-trim-');
    TavernEngine? ownedEngine;
    addTearDown(() async {
      try {
        await ownedEngine?.close();
      } finally {
        if (await root.exists()) await root.delete(recursive: true);
      }
      expect(await root.exists(), isFalse);
      stdout.writeln('LEGACY_ROLL_TRIM_CLEANUP');
    });
    final model = T24Model();
    var keyReads = 0;
    final config = TavernModelConfig(
      apiKey: () async {
        keyReads++;
        return 'fixture-key';
      },
      model: 'legacy-roll-trim-oracle',
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
    await facade.setSettings({'macroEngine': 'legacy', 'globalRegexScripts': <Object?>[]});
    final character = await facade.importCard(t24Card());
    final chatId = await facade.createChat(character.id);
    final greeting = (await facade.path(chatId)).single;
    expect(greeting.text, 'G');
    expect(greeting.role, TavernRole.character);
    expect(greeting.parentId, isNull);

    final ordinary = await facade.sendOnly(chatId, 'L{{roll:1d1}}R|{{roll:1d6}}');
    expect(ordinary.text, 'L1R|6');
    expect(position, 2);
    expect(totalDraws, 2);
    final beforeTarget = [
      (greeting.nodeId, null, TavernRole.character, 'G'),
      (ordinary.nodeId, greeting.nodeId, TavernRole.user, 'L1R|6'),
    ];
    expect(
      (await facade.path(chatId)).map((message) => (message.nodeId, message.parentId, message.role, message.text)),
      beforeTarget,
    );
    final ordinaryFile = (await facade.exportChat(chatId)).single;
    final ordinaryDocument = StChatDocument.decode(ordinaryFile.fileName, ordinaryFile.bytes);
    expect(ordinaryDocument.messages.map((message) => message['mes']), ['G', 'L1R|6']);
    final settings = await facade.readSettings(chatId: chatId);
    expect(settings['macroEngine'], 'legacy');
    expect(settings['globalRegexScripts'], isEmpty);
    expect(await facade.readVariables(chatId), isEmpty);
    expect(await facade.inspectTurn(chatId), isNull);
    expect(model.generated, 0);
    expect(keyReads, 0);

    // Reset only the cursor. The cumulative count still includes both ordinary draws.
    position = 0;
    stdout.writeln('LEGACY_ROLL_TRIM_READY');
    final boundary = await facade.sendOnly(chatId, 'L{{roll:\u00851d1\u0085}}R|{{roll:1d6}}');
    // First target assertion. Raw097 predicts L1R|6 after accepting the NEL formula.
    expect(boundary.text, 'LR|1');
    expect(position, 1);
    expect(totalDraws, 3);
    final expected = [...beforeTarget, (boundary.nodeId, ordinary.nodeId, TavernRole.user, 'LR|1')];
    Future<void> checkSaved() async {
      final path = await facade.path(chatId);
      expect(path.map((message) => (message.nodeId, message.parentId, message.role, message.text)), expected);
      final file = (await facade.exportChat(chatId)).single;
      final document = StChatDocument.decode(file.fileName, file.bytes);
      expect(document.messages.map((message) => message['mes']), ['G', 'L1R|6', 'LR|1']);
      expect(await facade.readVariables(chatId), isEmpty);
      expect(await facade.inspectTurn(chatId), isNull);
      expect(position, 1);
      expect(totalDraws, 3);
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
    expect(reopenedSettings['macroEngine'], 'legacy');
    expect(reopenedSettings['globalRegexScripts'], isEmpty);
    await checkSaved();
  });
}

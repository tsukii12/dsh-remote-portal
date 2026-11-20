import 'dart:io';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:test/test.dart';

import 'support/t24_engine_harness.dart';

void main() {
  test('both time macro engines preserve Moment week pipe lexemes', () {
    // Literal actual from the sole derived-boundary ST/Moment probe. Its
    // prewritten numerical w/W expectations were wrong; the original output
    // and exit 1 are preserved. These ordinary rows expose the lexer difference.
    const format = 'w|ww|wo|W|WW|Wo|gg|gggg|GG|GGGG';
    const rows = [
      ('en', 'LEFTw|01|1st|W|53|53rd|21|2021|20|2020RIGHT'),
      ('zh-cn', 'LEFTw|53|53周|W|53|53周|20|2020|20|2020RIGHT'),
    ];
    for (final (locale, expected) in rows) {
      final context = MacroContext(
        now: DateTime.utc(2021, 1, 1, 0, 5),
        timeZoneOffset: Duration.zero,
        locale: locale,
        random: () => throw StateError('Unexpected random draw.'),
      );
      expect(
        const MacroEngine().expand('LEFT{{datetimeformat::$format}}RIGHT', context),
        expected,
        reason: 'original modern handler literal: $locale',
      );
      expect(
        const LegacyMacroEngine().expand('LEFT{{datetimeformat $format}}RIGHT', context),
        expected,
        reason: 'original legacy replacement literal: $locale',
      );
    }
  });

  test('modern sendOnly preserves literal week pipe tokens through export and reopen', () async {
    final root = await Directory.systemTemp.createTemp('dsh-t12-week-pipe-');
    TavernEngine? ownedEngine;
    addTearDown(() async {
      try {
        await ownedEngine?.close();
      } finally {
        if (await root.exists()) await root.delete(recursive: true);
      }
      expect(await root.exists(), isFalse);
      stdout.writeln('DATETIMEFORMAT_WEEK_PIPE_CLEANUP');
    });
    final model = T24Model();
    var keyReads = 0;
    final config = TavernModelConfig(
      apiKey: () async {
        keyReads++;
        return 'fixture-key';
      },
      model: 'week-pipe-oracle',
    );
    var now = DateTime.utc(2024, 2, 29, 18, 7, 8, 123);
    Future<TavernEngine> open() =>
        TavernEngine.openDirectory(root, config: config, modelClient: model, clock: () => now);
    var engine = await open();
    ownedEngine = engine;
    Tavern facade = engine;
    await facade.setSettings({'macroEngine': 'modern', 'locale': 'en', 'globalRegexScripts': <Object?>[]});
    final character = await facade.importCard(t24Card());
    final chatId = await facade.createChat(character.id);
    final greeting = (await facade.path(chatId)).single;
    expect(greeting.text, 'G');
    expect(greeting.role, TavernRole.character);
    expect(greeting.parentId, isNull);
    const ordinaryBody = 'LEFT060|60thRIGHT';
    final ordinary = await facade.sendOnly(chatId, 'LEFT{{datetimeformat::DDDD|DDDo}}RIGHT');
    expect(ordinary.text, ordinaryBody);
    expect(ordinary.role, TavernRole.user);
    expect(ordinary.parentId, greeting.nodeId);
    expect(ordinary.at.millisecondsSinceEpoch, 1709230028123);
    final beforeTarget = [
      (greeting.nodeId, null, TavernRole.character, 'G'),
      (ordinary.nodeId, greeting.nodeId, TavernRole.user, ordinaryBody),
    ];
    expect((await facade.path(chatId)).map((node) => (node.nodeId, node.parentId, node.role, node.text)), beforeTarget);
    final ordinaryFile = (await facade.exportChat(chatId)).single;
    final ordinaryDocument = StChatDocument.decode(ordinaryFile.fileName, ordinaryFile.bytes);
    expect(ordinaryDocument.messages.map((message) => message['mes']), ['G', ordinaryBody]);
    expect(ordinaryDocument.messages.last['send_date'], '2024-02-29T18:07:08.123Z');
    final settings = await facade.readSettings(chatId: chatId);
    expect(settings['macroEngine'], 'modern');
    expect(settings['locale'], 'en');
    expect(settings['globalRegexScripts'], isEmpty);
    expect(await facade.readVariables(chatId), isEmpty);
    expect(await facade.inspectTurn(chatId), isNull);
    expect(model.generated, 0);
    expect(keyReads, 0);

    now = DateTime.utc(2021, 1, 1, 0, 5);
    stdout.writeln('DATETIMEFORMAT_WEEK_PIPE_READY');
    final boundary = await facade.sendOnly(chatId, 'LEFT{{datetimeformat::w|ww|wo|W|WW|Wo|gg|gggg|GG|GGGG}}RIGHT');
    // First target assertion. Raw097 source predicts numerical w/W fields:
    // LEFT1|01|1st|53|53|53rd|21|2021|20|2020RIGHT. No prior Dart run.
    const targetBody = 'LEFTw|01|1st|W|53|53rd|21|2021|20|2020RIGHT';
    expect(boundary.text, targetBody);
    expect(boundary.at.millisecondsSinceEpoch, 1609459500000);
    final expected = [...beforeTarget, (boundary.nodeId, ordinary.nodeId, TavernRole.user, targetBody)];
    Future<void> checkSaved() async {
      final path = await facade.path(chatId);
      expect(path.map((node) => (node.nodeId, node.parentId, node.role, node.text)), expected);
      expect(path.last.at.millisecondsSinceEpoch, 1609459500000);
      final file = (await facade.exportChat(chatId)).single;
      final document = StChatDocument.decode(file.fileName, file.bytes);
      expect(document.messages.map((message) => message['mes']), ['G', ordinaryBody, targetBody]);
      expect(document.messages.last['send_date'], '2021-01-01T00:05:00.000Z');
      expect(await facade.readVariables(chatId), isEmpty);
      expect(await facade.inspectTurn(chatId), isNull);
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
    expect(reopenedSettings['locale'], 'en');
    expect(reopenedSettings['globalRegexScripts'], isEmpty);
    await checkSaved();
  });
}

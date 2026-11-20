import 'dart:io';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:test/test.dart';

import 'support/t24_engine_harness.dart';

void main() {
  test('datetimeformat calendar and week years use Moment padding and signed remainders', () {
    const modern = MacroEngine();
    const legacy = LegacyMacroEngine();
    const pattern = 'Y|YY|gg|GG|YYYY|gggg|GGGG';
    // Actual Moment 2.30.1 output at June 15 noon UTC, for both en and zh-cn.
    // June stays inside the same calendar, locale-week and ISO-week year.
    const rows = <(int, String)>[
      (-101, '-0101|-01|-01|-01|-0101|-0101|-0101'),
      (-100, '-0100|00|00|00|-0100|-0100|-0100'),
      (-99, '-0099|-99|-99|-99|-0099|-0099|-0099'),
      (-1, '-0001|-01|-01|-01|-0001|-0001|-0001'),
      (0, '0000|00|00|00|0000|0000|0000'),
      (1, '0001|01|01|01|0001|0001|0001'),
      (99, '0099|99|99|99|0099|0099|0099'),
      (999, '0999|99|99|99|0999|0999|0999'),
      (1000, '1000|00|00|00|1000|1000|1000'),
      (2024, '2024|24|24|24|2024|2024|2024'),
      (9999, '9999|99|99|99|9999|9999|9999'),
      (10000, '+10000|00|00|00|10000|10000|10000'),
    ];
    for (final row in rows) {
      for (final locale in ['en', 'zh-cn']) {
        for (final isLegacy in [false, true]) {
          final context = MacroContext(
            now: DateTime.utc(row.$1, 6, 15, 12),
            timeZoneOffset: Duration.zero,
            locale: locale,
          );
          final actual = isLegacy
              ? legacy.expand('{{datetimeformat $pattern}}', context)
              : modern.expand('{{datetimeformat::$pattern}}', context);
          expect(actual, row.$2, reason: '${isLegacy ? 'legacy' : 'modern'} $locale year ${row.$1}');
        }
      }
    }
  });

  test('modern sendOnly preserves signed calendar and week years through export and reopen', () async {
    final root = await Directory.systemTemp.createTemp('dsh-t12-calendar-year-');
    TavernEngine? ownedEngine;
    addTearDown(() async {
      try {
        await ownedEngine?.close();
      } finally {
        if (await root.exists()) await root.delete(recursive: true);
      }
      expect(await root.exists(), isFalse);
      stdout.writeln('CALENDAR_YEAR_CLEANUP');
    });
    final model = T24Model();
    var keyReads = 0;
    final config = TavernModelConfig(
      apiKey: () async {
        keyReads++;
        return 'fixture-key';
      },
      model: 'calendar-year-oracle',
    );
    var now = DateTime.utc(2024, 6, 15, 12);
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
    const input = '{{datetimeformat::Y|YY|gg|GG|YYYY|gggg|GGGG}}';
    const ordinaryBody = '2024|24|24|24|2024|2024|2024';
    final ordinary = await facade.sendOnly(chatId, input);
    expect(ordinary.text, ordinaryBody);
    expect(ordinary.parentId, greeting.nodeId);
    final beforeTarget = [(greeting.nodeId, 'G'), (ordinary.nodeId, ordinaryBody)];
    expect((await facade.path(chatId)).map((message) => (message.nodeId, message.text)), beforeTarget);
    final settings = await facade.readSettings(chatId: chatId);
    expect(settings['macroEngine'], 'modern');
    expect(settings['locale'], 'en');
    expect(settings['globalRegexScripts'], isEmpty);
    expect(await facade.readVariables(chatId), isEmpty);
    expect(await facade.inspectTurn(chatId), isNull);
    expect(model.generated, 0);
    expect(keyReads, 0);
    now = DateTime.utc(-1, 6, 15, 12);
    expect(now.year, -1);
    expect(now.isUtc, isTrue);
    expect(now.timeZoneOffset, Duration.zero);
    stdout.writeln('CALENDAR_YEAR_READY');

    final boundary = await facade.sendOnly(chatId, input);
    const boundaryBody = '-0001|-01|-01|-01|-0001|-0001|-0001';
    // First target assertion: raw097 instead returns the complete body
    // -1|99|99|99|-0001|-0001|-0001 (source prediction, not a Dart run).
    expect(boundary.text, boundaryBody);
    expect(boundary.role, TavernRole.user);
    expect(boundary.parentId, ordinary.nodeId);
    expect(boundary.at, now);
    final expected = [...beforeTarget, (boundary.nodeId, boundaryBody)];
    Future<void> checkSaved() async {
      final path = await facade.path(chatId);
      expect(path.map((message) => (message.nodeId, message.text)), expected);
      expect(path.last.at, now);
      expect(await facade.readVariables(chatId), isEmpty);
      final file = (await facade.exportChat(chatId)).single;
      final document = StChatDocument.decode(file.fileName, file.bytes);
      expect(document.messages.map((message) => message['mes']), expected.map((row) => row.$2));
      expect(document.messages.last['send_date'], now.toIso8601String());
      expect(model.generated, 0);
      expect(keyReads, 0);
      expect(await facade.inspectTurn(chatId), isNull);
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
    await checkSaved();
  });
}

import 'dart:io';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:test/test.dart';

import 'support/t24_engine_harness.dart' show T24Model, t24Card;

void main() {
  test('modern sendOnly preserves valid boundary month timeDiff through export and reopen', () async {
    final root = await Directory.systemTemp.createTemp('dsh-t12-timediff-date-range-');
    TavernEngine? ownedEngine;
    addTearDown(() async {
      try {
        await ownedEngine?.close();
      } finally {
        if (await root.exists()) await root.delete(recursive: true);
      }
      expect(await root.exists(), isFalse);
      stdout.writeln('TIMEDIFF_DATE_RANGE_CLEANUP');
    });
    final model = T24Model();
    var keyReads = 0;
    final config = TavernModelConfig(
      apiKey: () async {
        keyReads++;
        return 'fixture-key';
      },
      model: 'timediff-date-range-oracle',
    );
    final now = DateTime.utc(2024, 6, 15, 12);
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

    final ordinary = await facade.sendOnly(chatId, 'LEFT{{timeDiff::2024-01-02T00:00:00Z::2024-01-01T00:00:00Z}}RIGHT');
    expect(ordinary.text, 'LEFTin a dayRIGHT');
    final beforeTarget = [
      (greeting.nodeId, null, TavernRole.character, 'G'),
      (ordinary.nodeId, greeting.nodeId, TavernRole.user, 'LEFTin a dayRIGHT'),
    ];
    expect(
      (await facade.path(chatId)).map((message) => (message.nodeId, message.parentId, message.role, message.text)),
      beforeTarget,
    );
    final ordinaryFile = (await facade.exportChat(chatId)).single;
    final ordinaryDocument = StChatDocument.decode(ordinaryFile.fileName, ordinaryFile.bytes);
    expect(ordinaryDocument.messages.map((message) => message['mes']), ['G', 'LEFTin a dayRIGHT']);
    final settings = await facade.readSettings(chatId: chatId);
    expect(settings['macroEngine'], 'modern');
    expect(settings['locale'], 'en');
    expect(settings['globalRegexScripts'], isEmpty);
    expect(await facade.readVariables(chatId), isEmpty);
    expect(await facade.inspectTurn(chatId), isNull);
    expect(model.generated, 0);
    expect(keyReads, 0);

    stdout.writeln('TIMEDIFF_DATE_RANGE_READY');
    final boundary = await facade.sendOnly(
      chatId,
      'LEFT{{timeDiff::+275760-09-12T00:00:00Z::+275760-09-11T00:00:00Z}}RIGHT',
    );
    // First target assertion. Raw097's synthetic September 30 throws, so its
    // outer macro handler preserves the entire call (source prediction only).
    expect(boundary.text, 'LEFTin a dayRIGHT');
    final expected = [...beforeTarget, (boundary.nodeId, ordinary.nodeId, TavernRole.user, 'LEFTin a dayRIGHT')];
    Future<void> checkSaved() async {
      final path = await facade.path(chatId);
      expect(path.map((message) => (message.nodeId, message.parentId, message.role, message.text)), expected);
      final file = (await facade.exportChat(chatId)).single;
      final document = StChatDocument.decode(file.fileName, file.bytes);
      expect(document.messages.map((message) => message['mes']), ['G', 'LEFTin a dayRIGHT', 'LEFTin a dayRIGHT']);
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

  test('timeDiff bounds use calendar days and retain wall before offset validity', () {
    // Twenty literal pairs from the sole fixed-ST/Moment 2.30.1 probe, with
    // complete-output oracles for both locales. These are not Dart run results.
    const rows = <(String, String, String, String)>[
      (
        'ordinary_day',
        'LEFT{{timeDiff::2024-01-02T00:00:00Z::2024-01-01T00:00:00Z}}RIGHT',
        'LEFTin a dayRIGHT',
        'LEFT1 天后RIGHT',
      ),
      (
        'upper_previous_month_control',
        'LEFT{{timeDiff::+275760-08-31T03:00:00Z::+275760-08-31T00:00:00Z}}RIGHT',
        'LEFTin 3 hoursRIGHT',
        'LEFT3 小时后RIGHT',
      ),
      (
        'upper_first_day_of_month',
        'LEFT{{timeDiff::+275760-09-01T03:00:00Z::+275760-09-01T00:00:00Z}}RIGHT',
        'LEFTin 3 hoursRIGHT',
        'LEFT3 小时后RIGHT',
      ),
      (
        'upper_valid_day_core',
        'LEFT{{timeDiff::+275760-09-12T00:00:00Z::+275760-09-11T00:00:00Z}}RIGHT',
        'LEFTin a dayRIGHT',
        'LEFT1 天后RIGHT',
      ),
      (
        'upper_exact_endpoint',
        'LEFT{{timeDiff::+275760-09-13T00:00:00Z::+275760-09-12T21:00:00Z}}RIGHT',
        'LEFTin 3 hoursRIGHT',
        'LEFT3 小时后RIGHT',
      ),
      (
        'upper_one_millisecond_outside',
        'LEFT{{timeDiff::+275760-09-13T00:00:00.001Z::+275760-09-12T21:00:00Z}}RIGHT',
        'LEFTInvalid dateRIGHT',
        'LEFTInvalid dateRIGHT',
      ),
      (
        'lower_first_day_control',
        'LEFT{{timeDiff::-271821-04-20T03:00:00Z::-271821-04-20T00:00:00Z}}RIGHT',
        'LEFTin 3 hoursRIGHT',
        'LEFT3 小时后RIGHT',
      ),
      (
        'lower_one_millisecond_outside',
        'LEFT{{timeDiff::-271821-04-19T23:59:59.999Z::-271821-04-20T00:00:00Z}}RIGHT',
        'LEFTInvalid dateRIGHT',
        'LEFTInvalid dateRIGHT',
      ),
      (
        'lower_valid_offset_endpoint',
        'LEFT{{timeDiff::-271821-04-20T01:00:00+01:00::-271821-04-20T00:00:00Z}}RIGHT',
        'LEFTa few seconds agoRIGHT',
        'LEFT几秒前RIGHT',
      ),
      (
        'lower_offset_crosses_limit',
        'LEFT{{timeDiff::-271821-04-20T00:00:00+00:01::-271821-04-20T00:00:00Z}}RIGHT',
        'LEFTInvalid dateRIGHT',
        'LEFTInvalid dateRIGHT',
      ),
      (
        'upper_valid_numeric_offset',
        'LEFT{{timeDiff::+275760-09-12T22:00:00-01:00::+275760-09-12T21:00:00Z}}RIGHT',
        'LEFTin 2 hoursRIGHT',
        'LEFT2 小时后RIGHT',
      ),
      (
        'upper_offset_crosses_limit',
        'LEFT{{timeDiff::+275760-09-13T00:00:00-00:01::+275760-09-13T00:00:00Z}}RIGHT',
        'LEFTInvalid dateRIGHT',
        'LEFTInvalid dateRIGHT',
      ),
      (
        'offset_cannot_rescue_upper_wall',
        'LEFT{{timeDiff::+275760-09-13T01:00:00+01:00::+275760-09-13T00:00:00Z}}RIGHT',
        'LEFTInvalid dateRIGHT',
        'LEFTInvalid dateRIGHT',
      ),
      (
        'offset_cannot_rescue_lower_wall',
        'LEFT{{timeDiff::-271821-04-19T23:00:00-01:00::-271821-04-20T00:00:00Z}}RIGHT',
        'LEFTInvalid dateRIGHT',
        'LEFTInvalid dateRIGHT',
      ),
      (
        'upper_valid_24_hour_rollover',
        'LEFT{{timeDiff::+275760-09-12T24:00:00Z::+275760-09-12T21:00:00Z}}RIGHT',
        'LEFTin 3 hoursRIGHT',
        'LEFT3 小时后RIGHT',
      ),
      (
        'upper_invalid_24_hour_rollover',
        'LEFT{{timeDiff::+275760-09-13T24:00:00Z::+275760-09-12T21:00:00Z}}RIGHT',
        'LEFTInvalid dateRIGHT',
        'LEFTInvalid dateRIGHT',
      ),
      (
        'year_just_above_range',
        'LEFT{{timeDiff::+275761-01-01T00:00:00Z::2024-01-01T00:00:00Z}}RIGHT',
        'LEFTInvalid dateRIGHT',
        'LEFTInvalid dateRIGHT',
      ),
      (
        'year_just_below_range',
        'LEFT{{timeDiff::-271822-01-01T00:00:00Z::2024-01-01T00:00:00Z}}RIGHT',
        'LEFTInvalid dateRIGHT',
        'LEFTInvalid dateRIGHT',
      ),
      (
        'ordinary_invalid_calendar_control',
        'LEFT{{timeDiff::2001-02-29T00:00:00Z::2001-02-28T00:00:00Z}}RIGHT',
        'LEFTInvalid dateRIGHT',
        'LEFTInvalid dateRIGHT',
      ),
      (
        'ordinary_leap_calendar_control',
        'LEFT{{timeDiff::2000-02-29T03:00:00Z::2000-02-29T00:00:00Z}}RIGHT',
        'LEFTin 3 hoursRIGHT',
        'LEFT3 小时后RIGHT',
      ),
    ];
    const modern = MacroEngine();
    const legacy = LegacyMacroEngine();
    for (final locale in ['en', 'zh-cn']) {
      for (final isLegacy in [false, true]) {
        String render(String input) {
          final context = MacroContext(
            now: DateTime.utc(2024, 6, 15, 12),
            timeZoneOffset: Duration.zero,
            locale: locale,
          );
          return isLegacy ? legacy.expand(input, context) : modern.expand(input, context);
        }

        final mode = isLegacy ? 'legacy' : 'modern';
        for (final row in rows) {
          expect(render(row.$2), locale == 'en' ? row.$3 : row.$4, reason: '$mode $locale ${row.$1}');
        }
        // Separate source-derived controls: these two years were NOT run in
        // the ST probe. Dart VM construction can wrap microseconds before its
        // range check; the parsed-year guard must reject them before building.
        for (final input in const [
          'LEFT{{timeDiff::+999999-01-01T00:00:00Z::2024-01-01T00:00:00Z}}RIGHT',
          'LEFT{{timeDiff::-999999-01-01T00:00:00Z::2024-01-01T00:00:00Z}}RIGHT',
        ]) {
          expect(render(input), 'LEFTInvalid dateRIGHT', reason: '$mode $locale source-only year bound');
        }
      }
    }
  });
}

import 'dart:io';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:test/test.dart';

import 'support/t24_engine_harness.dart' show T24Model, t24Card;

void main() {
  test('both time macro engines preserve unavailable derived day and week values', () {
    // Saved actual: two DDD observations from 119, then sixteen derived rows.
    // The latter original probe exited 1: its numerical w| / W| predictions
    // were wrong. Preserve its actual literal lexemes and original failure.
    // Modern source measured handler scalars; legacy measured full replacement.
    const rows = <(String, int, String, String, String)>[
      ('lower_DDD_excluded_derived_boundary', -8639999954703211, 'DDD', 'LEFTNaNRIGHT', 'LEFTNaNRIGHT'),
      ('ordinary_day_ordinal_control', 1709230028123, 'DDDD|DDDo', 'LEFT060|60thRIGHT', 'LEFT060|60日RIGHT'),
      ('lower_day_padding_and_ordinal', -8639999954703211, 'DDDD|DDDo', 'LEFT-NaN|NaNthRIGHT', 'LEFT-NaN|NaN日RIGHT'),
      (
        'ordinary_week_year_boundary_control',
        1609459500000,
        'w|ww|wo|W|WW|Wo|gg|gggg|GG|GGGG',
        'LEFTw|01|1st|W|53|53rd|21|2021|20|2020RIGHT',
        'LEFTw|53|53周|W|53|53周|20|2020|20|2020RIGHT',
      ),
      (
        'lower_nan_week_finite_year',
        -8639999954703211,
        'w|ww|wo|W|WW|Wo|gg|gggg|GG|GGGG',
        'LEFTw|-NaN|NaNth|W|-NaN|NaNth|-21|-271821|-21|-271821RIGHT',
        'LEFTw|-NaN|NaN周|W|-NaN|NaN周|-21|-271821|-21|-271821RIGHT',
      ),
      (
        'adjacent_year_january1_prior_nan_total',
        -8639977881600000,
        'w|ww|wo|W|WW|Wo|gg|gggg|GG|GGGG',
        'LEFTw|01|1st|W|-NaN|NaNth|-20|-271820|-21|-271821RIGHT',
        'LEFTw|-NaN|NaN周|W|-NaN|NaN周|-21|-271821|-21|-271821RIGHT',
      ),
      (
        'adjacent_year_january2_locale_week2',
        -8639977795200000,
        'w|ww|wo|W|WW|Wo|gg|gggg|GG|GGGG',
        'LEFTw|02|2nd|W|-NaN|NaNth|-20|-271820|-21|-271821RIGHT',
        'LEFTw|-NaN|NaN周|W|-NaN|NaN周|-21|-271821|-21|-271821RIGHT',
      ),
      (
        'adjacent_year_january3_finite_recovery',
        -8639977708800000,
        'w|ww|wo|W|WW|Wo|gg|gggg|GG|GGGG',
        'LEFTw|02|2nd|W|01|1st|-20|-271820|-20|-271820RIGHT',
        'LEFTw|01|1周|W|01|1周|-20|-271820|-20|-271820RIGHT',
      ),
      (
        'upper_finite_week_nan_year_total',
        8640000000000000,
        'w|ww|wo|W|WW|Wo|gg|gggg|GG|GGGG',
        'LEFTw|37|37th|W|37|37th|60|275760|60|275760RIGHT',
        'LEFTw|37|37周|W|37|37周|60|275760|60|275760RIGHT',
      ),
    ];
    const modern = MacroEngine();
    const legacy = LegacyMacroEngine();
    for (final locale in ['en', 'zh-cn']) {
      for (final isLegacy in [false, true]) {
        for (final (id, epoch, format, en, zh) in rows) {
          final context = MacroContext(
            now: DateTime.fromMillisecondsSinceEpoch(epoch, isUtc: true),
            timeZoneOffset: Duration.zero,
            locale: locale,
            random: () => throw StateError('Unexpected random draw.'),
          );
          final input = isLegacy ? 'LEFT{{datetimeformat $format}}RIGHT' : 'LEFT{{datetimeformat::$format}}RIGHT';
          final actual = isLegacy ? legacy.expand(input, context) : modern.expand(input, context);
          expect(actual, locale == 'en' ? en : zh, reason: '$id locale=$locale legacy=$isLegacy');
        }
      }
    }
  });

  test('modern sendOnly preserves derived day boundary through export and reopen', () async {
    final root = await Directory.systemTemp.createTemp('dsh-t12-derived-time-boundary-');
    TavernEngine? ownedEngine;
    addTearDown(() async {
      try {
        await ownedEngine?.close();
      } finally {
        if (await root.exists()) await root.delete(recursive: true);
      }
      expect(await root.exists(), isFalse);
      stdout.writeln('DATETIMEFORMAT_DERIVED_CLEANUP');
    });
    final model = T24Model();
    var keyReads = 0;
    var now = DateTime.utc(2024, 2, 29, 18, 7, 8, 123);
    final config = TavernModelConfig(
      apiKey: () async {
        keyReads++;
        return 'fixture-key';
      },
      model: 'derived-time-boundary-oracle',
    );
    Future<TavernEngine> open() =>
        TavernEngine.openDirectory(root, config: config, modelClient: model, clock: () => now);
    var engine = await open();
    ownedEngine = engine;
    Tavern facade = engine;
    await facade.setSettings({'macroEngine': 'modern', 'locale': 'en', 'globalRegexScripts': <Object?>[]});
    final character = await facade.importCard(t24Card());
    final chatId = await facade.createChat(character.id);
    final greeting = (await facade.path(chatId)).single;
    expect((greeting.role, greeting.text, greeting.parentId), (TavernRole.character, 'G', null));
    const input = 'LEFT{{datetimeformat::DDDD|DDDo}}RIGHT';
    const ordinaryBody = 'LEFT060|60thRIGHT';
    final ordinary = await facade.sendOnly(chatId, input);
    expect(ordinary.text, ordinaryBody);
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

    now = DateTime.utc(-271821, 4, 20, 12, 34, 56, 789);
    stdout.writeln('DATETIMEFORMAT_DERIVED_READY');
    final boundary = await facade.sendOnly(chatId, input);
    // First target assertion. The accepted 117-119+121 parent still derives
    // an unavailable January 1 and returns the complete raw input; not run here.
    const targetBody = 'LEFT-NaN|NaNthRIGHT';
    expect(boundary.text, targetBody);
    const targetEpoch = -8639999954703211;
    const targetIso = '-271821-04-20T12:34:56.789Z';
    expect(
      (boundary.at.isUtc, boundary.at.millisecondsSinceEpoch, boundary.at.toIso8601String()),
      (true, targetEpoch, targetIso),
    );
    final expected = [...beforeTarget, (boundary.nodeId, ordinary.nodeId, TavernRole.user, targetBody)];
    Future<void> checkSaved() async {
      final path = await facade.path(chatId);
      expect(path.map((node) => (node.nodeId, node.parentId, node.role, node.text)), expected);
      final at = path.last.at;
      expect((at.isUtc, at.millisecondsSinceEpoch, at.toIso8601String()), (true, targetEpoch, targetIso));
      final file = (await facade.exportChat(chatId)).single;
      final document = StChatDocument.decode(file.fileName, file.bytes);
      expect(document.messages.map((message) => message['mes']), ['G', ordinaryBody, targetBody]);
      expect(document.messages.last['send_date'], targetIso);
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

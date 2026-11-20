import 'dart:io';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:test/test.dart';

import 'support/t24_engine_harness.dart' show T24Model, t24Card;

void main() {
  test('datetimeformat ordinary tokens avoid unused day-of-year work at valid clock boundaries', () {
    // Eight literal inputs from the sole fixed-ST/Moment 2.30.1 probe.
    // Its separate lower-bound DDD/NaN observations are not this fix's oracle.
    const rows = <(String, int, String, String, String)>[
      ('ordinary_clock_control', 1704112496789, 'MM-DD HH:mm:ss', '01-01 12:34:56', '01-01 12:34:56'),
      ('lower_exact_instant', -8640000000000000, 'MM-DD HH:mm:ss', '04-20 00:00:00', '04-20 00:00:00'),
      ('lower_valid_noon_core', -8639999954703211, 'MM-DD HH:mm:ss', '04-20 12:34:56', '04-20 12:34:56'),
      ('lower_fractional_token', -8639999954703211, 'SSS', '789', '789'),
      ('lower_locale_alias', -8639999954703211, 'LT', '12:34 PM', '12:34'),
      ('lower_bracket_literal_control', -8639999954703211, '[KEEP]', 'KEEP', 'KEEP'),
      ('lower_plain_separator', -8639999954703211, '[KEEP]-', 'KEEP-', 'KEEP-'),
      ('upper_exact_instant_control', 8640000000000000, 'MM-DD HH:mm:ss', '09-13 00:00:00', '09-13 00:00:00'),
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
          final expected = locale == 'en' ? en : zh;
          final actual = isLegacy ? legacy.expand(input, context) : modern.expand(input, context);
          expect(actual, 'LEFT${expected}RIGHT', reason: '$id locale=$locale legacy=$isLegacy');
        }
      }
    }
  });

  test('modern sendOnly preserves lower boundary datetimeformat through export and reopen', () async {
    final root = await Directory.systemTemp.createTemp('dsh-t12-datetimeformat-boundary-');
    TavernEngine? ownedEngine;
    addTearDown(() async {
      try {
        await ownedEngine?.close();
      } finally {
        if (await root.exists()) await root.delete(recursive: true);
      }
      expect(await root.exists(), isFalse);
      stdout.writeln('DATETIMEFORMAT_BOUNDARY_CLEANUP');
    });
    final model = T24Model();
    var keyReads = 0;
    var now = DateTime.utc(2024, 1, 1, 12, 34, 56, 789);
    final config = TavernModelConfig(
      apiKey: () async {
        keyReads++;
        return 'fixture-key';
      },
      model: 'datetimeformat-boundary-oracle',
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
    const input = 'LEFT{{datetimeformat::MM-DD HH:mm:ss}}RIGHT';
    const ordinaryBody = 'LEFT01-01 12:34:56RIGHT';
    final ordinary = await facade.sendOnly(chatId, input);
    expect(ordinary.text, ordinaryBody);
    expect(ordinary.at.millisecondsSinceEpoch, 1704112496789);
    final beforeTarget = [
      (greeting.nodeId, null, TavernRole.character, 'G'),
      (ordinary.nodeId, greeting.nodeId, TavernRole.user, ordinaryBody),
    ];
    expect(
      (await facade.path(chatId)).map((message) => (message.nodeId, message.parentId, message.role, message.text)),
      beforeTarget,
    );
    final ordinaryFile = (await facade.exportChat(chatId)).single;
    final ordinaryDocument = StChatDocument.decode(ordinaryFile.fileName, ordinaryFile.bytes);
    expect(ordinaryDocument.messages.map((message) => message['mes']), ['G', ordinaryBody]);
    expect(ordinaryDocument.messages.last['send_date'], '2024-01-01T12:34:56.789Z');
    final settings = await facade.readSettings(chatId: chatId);
    expect(settings['macroEngine'], 'modern');
    expect(settings['locale'], 'en');
    expect(settings['globalRegexScripts'], isEmpty);
    expect(await facade.readVariables(chatId), isEmpty);
    expect(await facade.inspectTurn(chatId), isNull);
    expect(model.generated, 0);
    expect(keyReads, 0);

    now = DateTime.utc(-271821, 4, 20, 12, 34, 56, 789);
    stdout.writeln('DATETIMEFORMAT_BOUNDARY_READY');
    final boundary = await facade.sendOnly(chatId, input);
    // First target assertion. Raw097 source predicts the complete unchanged
    // input after its unused January 1 construction throws; no Dart run yet.
    const targetBody = 'LEFT04-20 12:34:56RIGHT';
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
      expect(path.map((message) => (message.nodeId, message.parentId, message.role, message.text)), expected);
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

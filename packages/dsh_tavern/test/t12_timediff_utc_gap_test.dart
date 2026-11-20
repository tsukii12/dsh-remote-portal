import 'dart:io';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:test/test.dart';

import 'support/t24_engine_harness.dart' show T24Model, t24Card;

void main() {
  test('timeDiff accepts ISO calendar whitespace before Z without widening other date spellings', () {
    const modern = MacroEngine();
    const legacy = LegacyMacroEngine();
    const zero = '2024-01-01T00:00:00Z';
    // Literal three-hour oracles from the actual fixed-ST handlers and Moment
    // 2.30.1. Each accepted operand used its ISO branch, without host fallback.
    const futureRows = <(String, String, String)>[
      ('ordinary Z', '2024-01-01T03:00:00Z', zero),
      ('space', '2024-01-01T03:00:00 Z', zero),
      ('tab', '2024-01-01T03:00:00\tZ', zero),
      ('NBSP', '2024-01-01T03:00:00\u00a0Z', zero),
      ('BOM', '2024-01-01T03:00:00\ufeffZ', zero),
      ('mixed gap', '2024-01-01T03:00:00 \t\u00a0\ufeffZ', zero),
      ('basic', '20240101T030000 Z', '20240101T000000Z'),
      ('comma fraction', '2024-01-01T03:00:00,123 Z', '2024-01-01T00:00:00,123Z'),
      ('numeric offset', '2024-01-01T05:00:00+02:00', zero),
      ('extended hour', '2024-01-01T03 Z', '2024-01-01T00Z'),
      ('extended minute', '2024-01-01T03:00 Z', '2024-01-01T00:00Z'),
      ('basic hour', '20240101T03 Z', '20240101T00Z'),
      ('basic minute', '20240101T0300 Z', '20240101T0000Z'),
    ];
    // Scope controls for the new ISO branch, not host-Date fallback oracles.
    const rejected = [
      '2024-01-01t03:00:00 Z',
      '2024-01-01T03:00:00 z',
      '20240101T03:00:00 Z',
      '2024-01-01T030000 Z',
      '2024-01T03:00:00 Z',
      '2024-01-01T03.5 Z',
      '2024-01-01T03:00.5 Z',
      '2024-01-01T05:00:00 +02:00',
      '2024-01-01T03:00:00\u0085Z',
      '\u00852024-01-01T03:00:00 Z',
      '2024-02-30T03:00:00 Z',
      '2024-01-01T24:01:00 Z',
    ];
    // These no-gap forms were already accepted. Preserve that local behavior;
    // this does not claim Moment's host fallback accepts the same spellings.
    const retained = [
      '2024-01-01t03:00:00z',
      '20240101T03:00:00Z',
      '2024-01T03:00:00Z',
      '\u00852024-01-01T03:00:00Z\u0085',
    ];
    for (final locale in ['en', 'zh-cn']) {
      for (final isLegacy in [false, true]) {
        final context = MacroContext(
          now: DateTime.utc(2024, 6, 15, 12),
          timeZoneOffset: const Duration(hours: 9),
          locale: locale,
        );
        String render(String left, String right) {
          final input = '{{timeDiff::$left::$right}}';
          return isLegacy ? legacy.expand(input, context) : modern.expand(input, context);
        }

        final mode = isLegacy ? 'legacy' : 'modern';
        final future = locale == 'en' ? 'in 3 hours' : '3 小时后';
        for (final row in futureRows) {
          expect(render(row.$2, row.$3), future, reason: '$mode $locale ${row.$1}');
        }
        expect(
          render(zero, '2024-01-01T03:00:00 Z'),
          locale == 'en' ? '3 hours ago' : '3 小时前',
          reason: '$mode $locale past',
        );
        for (final left in rejected) {
          expect(render(left, zero), 'Invalid date', reason: '$mode $locale rejected $left');
        }
        for (final left in retained) {
          expect(render(left, zero), future, reason: '$mode $locale retained $left');
        }
        // Modern argument slicing removes the trailing space before dispatch;
        // legacy passes it through. Only the former reaches the new ISO form.
        expect(
          render('2024-01-01T03:00:00 Z ', zero),
          isLegacy ? 'Invalid date' : future,
          reason: '$mode $locale trailing space is not an ISO promotion',
        );
      }
    }
  });

  test('modern sendOnly preserves ISO timeDiff UTC whitespace through export and reopen', () async {
    final root = await Directory.systemTemp.createTemp('dsh-t12-timediff-utc-gap-');
    TavernEngine? ownedEngine;
    addTearDown(() async {
      try {
        await ownedEngine?.close();
      } finally {
        if (await root.exists()) await root.delete(recursive: true);
      }
      expect(await root.exists(), isFalse);
      stdout.writeln('TIMEDIFF_UTC_GAP_CLEANUP');
    });
    final model = T24Model();
    var keyReads = 0;
    final config = TavernModelConfig(
      apiKey: () async {
        keyReads++;
        return 'fixture-key';
      },
      model: 'timediff-utc-gap-oracle',
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
    const body = 'LEFTin 3 hoursRIGHT';
    final ordinary = await facade.sendOnly(chatId, 'LEFT{{timeDiff::2024-01-01T03:00:00Z::2024-01-01T00:00:00Z}}RIGHT');
    expect(ordinary.text, body);
    expect(ordinary.parentId, greeting.nodeId);
    final beforeTarget = [(greeting.nodeId, 'G'), (ordinary.nodeId, body)];
    expect((await facade.path(chatId)).map((message) => (message.nodeId, message.text)), beforeTarget);
    final ordinaryFile = (await facade.exportChat(chatId)).single;
    final ordinaryDocument = StChatDocument.decode(ordinaryFile.fileName, ordinaryFile.bytes);
    expect(ordinaryDocument.messages.map((message) => message['mes']), ['G', body]);
    final settings = await facade.readSettings(chatId: chatId);
    expect(settings['macroEngine'], 'modern');
    expect(settings['locale'], 'en');
    expect(settings['globalRegexScripts'], isEmpty);
    expect(await facade.readVariables(chatId), isEmpty);
    expect(await facade.inspectTurn(chatId), isNull);
    expect(model.generated, 0);
    expect(keyReads, 0);
    stdout.writeln('TIMEDIFF_UTC_GAP_READY');

    final boundary = await facade.sendOnly(
      chatId,
      'LEFT{{timeDiff::2024-01-01T03:00:00 Z::2024-01-01T00:00:00Z}}RIGHT',
    );
    // First target assertion. Raw097 predicts LEFTInvalid dateRIGHT because
    // its ISO regex rejects the internal space (not a prior Dart run).
    expect(boundary.text, body);
    expect(boundary.role, TavernRole.user);
    expect(boundary.parentId, ordinary.nodeId);
    final expected = [...beforeTarget, (boundary.nodeId, body)];
    Future<void> checkSaved() async {
      final path = await facade.path(chatId);
      expect(path.map((message) => (message.nodeId, message.text)), expected);
      expect(path.last.role, TavernRole.user);
      expect(path.last.parentId, ordinary.nodeId);
      expect(await facade.readVariables(chatId), isEmpty);
      final file = (await facade.exportChat(chatId)).single;
      final document = StChatDocument.decode(file.fileName, file.bytes);
      expect(document.messages.map((message) => message['mes']), expected.map((row) => row.$2));
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

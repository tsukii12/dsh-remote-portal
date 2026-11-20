import 'dart:io';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:test/test.dart';

import 'support/t24_engine_harness.dart';

String _expand(String input, MacroContext context, bool legacy) =>
    legacy ? const LegacyMacroEngine().expand(input, context) : const MacroEngine().expand(input, context);

void main() {
  test('timeDiff preserves finite long spans and existing submillisecond contexts in both modes', () {
    // Fixed ST 7e8663cd + Moment 2.30.1: four pairs, en/zh-cn, both original
    // entry points. All operands are valid ISO dates with zero host fallback.
    const sourceCases = [
      ('+200000-01-01T00:00:00Z', '-200000-01-01T00:00:00Z', 'in 400000 years', '400000 年后'),
      ('-200000-01-01T00:00:00Z', '+200000-01-01T00:00:00Z', '400000 years ago', '400000 年前'),
      ('+146138-01-01T00:00:00Z', '-146138-01-01T00:00:00Z', 'in 292276 years', '292276 年后'),
      ('+146139-01-01T00:00:00Z', '-146139-01-01T00:00:00Z', 'in 292278 years', '292278 年后'),
    ];
    // These protect the existing public MacroContext extension. Their literal
    // expectations come from the old product, not another ST/Node experiment.
    const contextCases = [
      (-500, '2024-01-01T00:00:00', '2024-01-01T00:00:00Z', 'in a few seconds'),
      (-500, '2024-01-01T00:00:00Z', '2024-01-01T00:00:00', 'a few seconds ago'),
      (500, '2024-01-01T00:00:44.499Z', '2024-01-01T00:00:00', 'in a few seconds'),
      (500, '2024-01-01T00:00:00', '2024-01-01T00:00:44.499Z', 'a few seconds ago'),
    ];
    final now = DateTime.utc(2024, 6, 15, 12);
    for (final legacy in [false, true]) {
      for (final locale in ['en', 'zh-cn']) {
        for (final (left, right, en, zh) in sourceCases) {
          final context = MacroContext(
            now: now,
            timeZoneOffset: Duration.zero,
            locale: locale,
            random: () => throw StateError('Unexpected random draw.'),
          );
          final expected = locale == 'en' ? en : zh;
          expect(
            _expand('LEFT{{timeDiff::$left::$right}}RIGHT', context, legacy),
            'LEFT${expected}RIGHT',
            reason: 'fixed ST: legacy=$legacy locale=$locale left=$left right=$right',
          );
        }
      }
      for (final (offset, left, right, expected) in contextCases) {
        final context = MacroContext(
          now: now,
          timeZoneOffset: Duration(microseconds: offset),
          locale: 'en',
          random: () => throw StateError('Unexpected random draw.'),
        );
        expect(
          _expand('LEFT{{timeDiff::$left::$right}}RIGHT', context, legacy),
          'LEFT${expected}RIGHT',
          reason: 'existing Context: legacy=$legacy offsetUs=$offset left=$left right=$right',
        );
      }
    }
  });

  test('modern sendOnly preserves long timeDiff spans through export and reopen', () async {
    final root = await Directory.systemTemp.createTemp('dsh-t12-timediff-span-');
    TavernEngine? ownedEngine;
    addTearDown(() async {
      try {
        await ownedEngine?.close();
      } finally {
        if (await root.exists()) await root.delete(recursive: true);
      }
      expect(await root.exists(), isFalse);
      stdout.writeln('TIMEDIFF_SPAN_CLEANUP');
    });
    final model = T24Model();
    var keyReads = 0;
    final config = TavernModelConfig(
      apiKey: () async {
        keyReads++;
        return 'fixture-key';
      },
      model: 'timediff-span-oracle',
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
    const ordinaryBody = 'LEFTin 3 hoursRIGHT';
    final ordinary = await facade.sendOnly(chatId, 'LEFT{{timeDiff::2024-01-01T03:00:00Z::2024-01-01T00:00:00Z}}RIGHT');
    expect(ordinary.text, ordinaryBody);
    expect(ordinary.role, TavernRole.user);
    expect(ordinary.parentId, greeting.nodeId);
    final beforeTarget = [
      (greeting.nodeId, null, TavernRole.character, 'G'),
      (ordinary.nodeId, greeting.nodeId, TavernRole.user, ordinaryBody),
    ];
    expect((await facade.path(chatId)).map((node) => (node.nodeId, node.parentId, node.role, node.text)), beforeTarget);
    final ordinaryFile = (await facade.exportChat(chatId)).single;
    final ordinaryDocument = StChatDocument.decode(ordinaryFile.fileName, ordinaryFile.bytes);
    expect(ordinaryDocument.messages.map((message) => message['mes']), ['G', ordinaryBody]);
    final settings = await facade.readSettings(chatId: chatId);
    expect(settings['macroEngine'], 'modern');
    expect(settings['locale'], 'en');
    expect(settings['globalRegexScripts'], isEmpty);
    expect(await facade.readVariables(chatId), isEmpty);
    expect(await facade.inspectTurn(chatId), isNull);
    expect(model.generated, 0);
    expect(keyReads, 0);
    stdout.writeln('TIMEDIFF_SPAN_READY');

    final boundary = await facade.sendOnly(
      chatId,
      'LEFT{{timeDiff::+200000-01-01T00:00:00Z::-200000-01-01T00:00:00Z}}RIGHT',
    );
    // First target assertion. Raw097 VM source predicts LEFT184554 years agoRIGHT
    // after its microsecond difference wraps; this is not a prior Dart run.
    const targetBody = 'LEFTin 400000 yearsRIGHT';
    expect(boundary.text, targetBody);
    final expected = [...beforeTarget, (boundary.nodeId, ordinary.nodeId, TavernRole.user, targetBody)];
    Future<void> checkSaved() async {
      final path = await facade.path(chatId);
      expect(path.map((node) => (node.nodeId, node.parentId, node.role, node.text)), expected);
      final file = (await facade.exportChat(chatId)).single;
      final document = StChatDocument.decode(file.fileName, file.bytes);
      expect(document.messages.map((message) => message['mes']), ['G', ordinaryBody, targetBody]);
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

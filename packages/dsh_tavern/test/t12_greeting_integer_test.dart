import 'dart:io';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:test/test.dart';

import 'support/t24_engine_harness.dart';

void main() {
  test('greeting accepts decimal integer indexes beyond int64 and preserves lazy effects', () {
    const engine = MacroEngine();
    const card = <String, Object?>{
      'first_mes': 'FIRST {{incvar::first}}',
      'alternate_greetings': ['A {{incvar::alt}}', 'B {{incvar::alt}}'],
    };
    const aboveInt64 = '9223372036854775808';
    const belowInt64 = '-9223372036854775809';
    final bigFinite = '1${List.filled(308, '0').join()}';
    final infinity = '${bigFinite}0';

    for (final index in <String?>[null, '0', '-0', '0000']) {
      final context = MacroContext(card: card);
      final source = index == null ? '{{greeting}}' : '{{greeting::$index}}';
      expect(engine.expand(source, context), 'FIRST 1', reason: source);
      expect(context.localVariables, {'first': 1}, reason: source);
    }
    for (final row in [
      ('1', 'A 1'),
      ('2', 'B 2'),
      ('0001', 'A 1'),
      ('  0002 \t', 'B 2'),
      ('3', ''),
      ('-1', ''),
      ('9223372036854775807', ''),
      (aboveInt64, ''),
      (belowInt64, ''),
      (bigFinite, ''),
      (infinity, ''),
      ('-$infinity', ''),
    ]) {
      final context = MacroContext(card: card);
      final source = '{{greeting::${row.$1}}}';
      expect(engine.expand(source, context), row.$2, reason: source);
      // Even an out-of-bounds index resolves the whole alternate list once.
      expect(context.localVariables, {'alt': 2}, reason: source);
    }
    for (final index in ['+1', '1.5', '1e0', '0x1', 'Infinity']) {
      final context = MacroContext(card: card);
      final source = '{{greeting::$index}}';
      expect(engine.expand(source, context), source, reason: source);
      expect(context.localVariables, isEmpty, reason: source);
    }

    final context = MacroContext(card: card);
    expect(
      engine.expand(
        '{{charFirstMessage::$aboveInt64}}|{{getvar::alt}}|'
        '{{greeting::1}}|{{greeting::2}}|{{greeting::$belowInt64}}|{{getvar::alt}}',
        context,
      ),
      '|2|A 1|B 2||2',
    );
    expect(context.localVariables, {'alt': 2});
    final baseContext = MacroContext(card: card, replaceCharacterCard: false);
    expect(engine.expand('{{charFirstMessage::$infinity}}', baseContext), '');
    expect(baseContext.localVariables, isEmpty);
  });

  test('modern sendOnly greeting preserves oversized-index effects through export and reopen', () async {
    final root = await Directory.systemTemp.createTemp('dsh-t12-greeting-integer-');
    TavernEngine? ownedEngine;
    addTearDown(() async {
      try {
        await ownedEngine?.close();
      } finally {
        if (await root.exists()) await root.delete(recursive: true);
      }
      expect(await root.exists(), isFalse);
      stdout.writeln('GREETING_INTEGER_CLEANUP');
    });
    final model = T24Model();
    var keyReads = 0;
    final config = TavernModelConfig(
      apiKey: () async {
        keyReads++;
        return 'fixture-key';
      },
      model: 'greeting-oracle',
    );
    Future<TavernEngine> open() => TavernEngine.openDirectory(root, config: config, modelClient: model);
    var engine = await open();
    ownedEngine = engine;
    Tavern facade = engine;
    await facade.setSettings({'macroEngine': 'modern', 'globalRegexScripts': <Object?>[]});
    final character = await facade.importCard(t24Card());
    final chatId = await facade.createChat(character.id);
    await facade.updateCharacterFields(character.id, {
      'alternate_greetings': ['A {{incvar::greet}}', 'B {{incvar::greet}}'],
    });
    final settings = await facade.readSettings(chatId: chatId);
    expect(settings['macroEngine'], 'modern');
    expect(settings['globalRegexScripts'], isEmpty);
    final greeting = (await facade.path(chatId)).single;
    expect(greeting.text, 'G');
    final ordinary = await facade.sendOnly(chatId, '{{greeting::1}}|{{greeting::2}}|{{getvar::greet}}');
    expect(ordinary.text, 'A 1|B 2|2');
    expect(ordinary.parentId, greeting.nodeId);
    expect(await facade.readVariables(chatId), {'greet': 2});
    expect(model.generated, 0);
    expect(keyReads, 0);
    expect(await facade.inspectTurn(chatId), isNull);
    stdout.writeln('GREETING_INTEGER_READY');

    final boundary = await facade.sendOnly(
      chatId,
      'LEFT{{greeting::9223372036854775808}}RIGHT|{{getvar::greet}}|'
      '{{charFirstMessage::1}}|{{greeting::-9223372036854775809}}|{{getvar::greet}}',
    );
    // First target assertion is the complete public returned message. Old
    // int64 parsing leaves both oversized calls literal and the first count 2.
    expect(boundary.text, 'LEFTRIGHT|4|A 3||4');
    expect(boundary.role, TavernRole.user);
    expect(boundary.parentId, ordinary.nodeId);
    final expected = [(greeting.nodeId, 'G'), (ordinary.nodeId, 'A 1|B 2|2'), (boundary.nodeId, 'LEFTRIGHT|4|A 3||4')];
    Future<void> checkSaved() async {
      expect((await facade.path(chatId)).map((message) => (message.nodeId, message.text)), expected);
      expect(await facade.readVariables(chatId), {'greet': 4});
      final file = (await facade.exportChat(chatId)).single;
      final document = StChatDocument.decode(file.fileName, file.bytes);
      expect(document.messages.map((message) => message['mes']), expected.map((row) => row.$2));
      final metadata = document.header['chat_metadata']! as Map<String, Object?>;
      expect(metadata['variables'], {'greet': 4});
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
    expect((await facade.readSettings(chatId: chatId))['macroEngine'], 'modern');
    await checkSaved();
  });
}

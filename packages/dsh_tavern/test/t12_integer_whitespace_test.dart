import 'dart:io';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:test/test.dart';

import 'support/t24_engine_harness.dart';

void main() {
  test('integer macros use JavaScript whitespace and keep invalid NEL arguments literal', () {
    const engine = MacroEngine();
    const card = <String, Object?>{
      'first_mes': 'FIRST {{incvar::first}}',
      'alternate_greetings': ['A {{incvar::alt}}', 'B {{incvar::alt}}'],
    };
    final defaults = MacroContext(card: card);
    expect(engine.expand('{{space}}|{{newline}}|{{greeting}}', defaults), ' |\n|FIRST 1');
    expect(defaults.localVariables, {'first': 1});

    for (final row in [
      ('0', '', '', 'FIRST 1', {'first': 1}),
      ('-0', '', '', 'FIRST 1', {'first': 1}),
      ('1', ' ', '\n', 'A 1', {'alt': 2}),
      ('0002', '  ', '\n\n', 'B 2', {'alt': 2}),
    ]) {
      final context = MacroContext(card: card);
      final source = 'S[{{space::${row.$1}}}]N[{{newline::${row.$1}}}]G[{{greeting::${row.$1}}}]';
      expect(engine.expand(source, context), 'S[${row.$2}]N[${row.$3}]G[${row.$4}]', reason: row.$1);
      expect(context.localVariables, row.$5, reason: row.$1);
    }
    final negative = MacroContext(card: card);
    expect(engine.expand('{{space::-1}}|{{newline::-1}}|{{greeting::-1}}', negative), '{{space::-1}}|{{newline::-1}}|');
    expect(negative.localVariables, {'alt': 2});

    for (final value in ['', '+1', '1.0', '\u00851', '1\u0085', '\u00851\u0085', '\u0085', '\u200b1']) {
      final context = MacroContext(card: card);
      final source = 'S[{{space::$value}}]N[{{newline::$value}}]G[{{greeting::$value}}]';
      expect(engine.expand(source, context), source, reason: value.codeUnits.toString());
      expect(context.localVariables, isEmpty, reason: value.codeUnits.toString());
    }

    // An override supplies whitespace after parsing the outer argument, so
    // the INTEGER consumer itself must apply JavaScript's trim semantics.
    final padded = MacroContext(card: card);
    expect(
      engine.expand(
        'S[{{space::{{countvalue}}}}]N[{{newline::{{countvalue}}}}]G[{{greeting::{{countvalue}}}}]',
        padded,
        overrides: {'countvalue': ' \t\u00a02\ufeff\u2028'},
      ),
      'S[  ]N[\n\n]G[B 2]',
    );
    expect(padded.localVariables, {'alt': 2});

    // Nested arguments run before the parent's type check. Invalid greeting
    // arguments do not load alternatives; the later valid alias loads once.
    final nested = MacroContext(card: card);
    expect(
      engine.expand(
        '{{space::{{incvar::seen}}\u0085}}|{{greeting::{{incvar::seen}}\u0085}}|'
        '{{getvar::alt}}|{{charFirstMessage::1}}|{{greeting::2}}|{{getvar::alt}}',
        nested,
      ),
      '{{space::1\u0085}}|{{greeting::2\u0085}}||A 1|B 2|2',
    );
    expect(nested.localVariables, {'seen': 2, 'alt': 2});
    final base = MacroContext(card: card, replaceCharacterCard: false);
    expect(engine.expand('{{charFirstMessage::\u00851}}', base), '{{charFirstMessage::\u00851}}');
    expect(base.localVariables, isEmpty);
  });

  test('modern sendOnly keeps NEL integer fallbacks and variables through reopen', () async {
    final root = await Directory.systemTemp.createTemp('dsh-t12-integer-whitespace-');
    TavernEngine? ownedEngine;
    addTearDown(() async {
      try {
        await ownedEngine?.close();
      } finally {
        if (await root.exists()) await root.delete(recursive: true);
      }
      expect(await root.exists(), isFalse);
      stdout.writeln('INTEGER_WHITESPACE_CLEANUP');
    });
    final model = T24Model();
    var keyReads = 0;
    final config = TavernModelConfig(
      apiKey: () async {
        keyReads++;
        return 'fixture-key';
      },
      model: 'integer-whitespace-oracle',
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
    final greeting = (await facade.path(chatId)).single;
    expect(greeting.text, 'G');
    const ordinaryBody = 'S[  ]N[\n]G[A 1]|2';
    final ordinary = await facade.sendOnly(
      chatId,
      'S[{{space::2}}]N[{{newline::1}}]G[{{greeting::1}}]|{{getvar::greet}}',
    );
    expect(ordinary.text, ordinaryBody);
    expect(ordinary.parentId, greeting.nodeId);
    expect(await facade.readVariables(chatId), {'greet': 2});
    const invalidCount = '\u00851';
    final seed = await facade.sendOnly(chatId, '{{setvar::count::$invalidCount}}READY');
    expect(seed.text, 'READY');
    expect(seed.parentId, ordinary.nodeId);
    final beforeTarget = [(greeting.nodeId, 'G'), (ordinary.nodeId, ordinaryBody), (seed.nodeId, 'READY')];
    expect(await facade.readVariables(chatId), {'greet': 2, 'count': invalidCount});
    expect(model.generated, 0);
    expect(keyReads, 0);
    expect(await facade.inspectTurn(chatId), isNull);

    await facade.close();
    ownedEngine = null;
    engine = await open();
    ownedEngine = engine;
    facade = engine;
    final settings = await facade.readSettings(chatId: chatId);
    expect(settings['macroEngine'], 'modern');
    expect(settings['globalRegexScripts'], isEmpty);
    expect((await facade.path(chatId)).map((message) => (message.nodeId, message.text)), beforeTarget);
    expect(await facade.readVariables(chatId), {'greet': 2, 'count': invalidCount});
    expect(model.generated, 0);
    expect(keyReads, 0);
    stdout.writeln('INTEGER_WHITESPACE_READY');

    final boundary = await facade.sendOnly(
      chatId,
      'S[{{space::{{getvar::count}}}}]N[{{newline::{{getvar::count}}}}]'
      'G[{{greeting::{{getvar::count}}}}]|{{getvar::greet}}',
    );
    const boundaryBody =
        'S[{{space::$invalidCount}}]N[{{newline::$invalidCount}}]'
        'G[{{greeting::$invalidCount}}]|2';
    // First target assertion: the complete public result. Native Dart trim
    // instead yields S[ ]N[LF]G[A 3]|4 and executes the alternatives early.
    expect(boundary.text, boundaryBody);
    expect(boundary.role, TavernRole.user);
    expect(boundary.parentId, seed.nodeId);
    final expected = [...beforeTarget, (boundary.nodeId, boundaryBody)];
    Future<void> checkSaved() async {
      expect((await facade.path(chatId)).map((message) => (message.nodeId, message.text)), expected);
      expect(await facade.readVariables(chatId), {'greet': 2, 'count': invalidCount});
      final file = (await facade.exportChat(chatId)).single;
      final document = StChatDocument.decode(file.fileName, file.bytes);
      expect(document.messages.map((message) => message['mes']), expected.map((row) => row.$2));
      final metadata = document.header['chat_metadata']! as Map<String, Object?>;
      expect(metadata['variables'], {'greet': 2, 'count': invalidCount});
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

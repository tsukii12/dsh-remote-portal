import 'dart:io';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:test/test.dart';

import 'support/t24_engine_harness.dart';

void main() {
  test('scoped content uses JavaScript whitespace for trim and dedent without changing lazy branches', () {
    const engine = MacroEngine();
    // Literal oracles from the original fixed-ST trimScopedContent method.
    // Runtime inputs and expected strings contain actual whitespace code units.
    const rows = <(String, String, String)>[
      ('empty', '', ''),
      ('ordinary trim', ' \t X \t\n', 'X'),
      ('ordinary dedent', '\n    first\n      second\n  last\n', 'first\n  second\nlast'),
      ('NEL outer', '\u0085X\u0085', '\u0085X\u0085'),
      ('NEL only', '\u0085', '\u0085'),
      ('NEL first nonempty', '\n\u0085\n    A\n  B\n', '\u0085\n    A\n  B'),
      ('indented NEL first nonempty', '\n  \u0085\n    A\n  B\n', '\u0085\n  A\nB'),
      ('short indent NEL', '\n    A\n \u0085 B \n    C\n', 'A\n\u0085 B \nC'),
      ('dedented tail NEL', '\n    A\n    \u0085\n', 'A\n\u0085'),
      ('JS whitespace blank line', '\n\u00a0\n    A\n  B\n', 'A\nB'),
      ('JS trimStart keeps line tail', '\n    A\n\u00a0 B \n    C\n', 'A\nB \nC'),
      ('BOM and NBSP edges', '\u00a0\ufeffX\ufeff\u00a0', 'X'),
      ('zero width space retained', '\u200bX\u200b', '\u200bX\u200b'),
      ('Unicode payload', '\u0085鲸🙂\u0085', '\u0085鲸🙂\u0085'),
    ];
    for (final row in rows) {
      expect(engine.expand('{{trim}}${row.$2}{{/trim}}', MacroContext()), row.$3, reason: '${row.$1}: trim');
      expect(engine.expand('{{if::true}}${row.$2}{{/if}}', MacroContext()), row.$3, reason: '${row.$1}: if');
    }
    const preserved = '\n  \u0085 A \n';
    expect(engine.expand('{{#trim}}$preserved{{/trim}}', MacroContext()), preserved);
    expect(engine.expand('{{#if::true}}$preserved{{else}}wrong{{/if}}', MacroContext()), preserved);
    expect(engine.expand('{{#if::false}}wrong{{else}}$preserved{{/if}}', MacroContext()), preserved);
    final context = MacroContext();
    expect(
      engine.expand(
        '{{trim}}\u0085{{incvar::ordinary}}\u0085{{/trim}}|'
        '{{if::false}}{{incvar::untaken}}{{else}}\u0085{{incvar::chosen}}\u0085{{/if}}|'
        '{{#if::true}} \u0085{{incvar::preserved}} {{else}}{{incvar::untaken}}{{/if}}|'
        '{{getvar::untaken}}',
        context,
      ),
      '\u00851\u0085|\u00851\u0085| \u00851 |',
    );
    expect(context.localVariables, {'ordinary': 1, 'chosen': 1, 'preserved': 1});
  });

  test('modern sendOnly preserves scoped NEL content and chosen variables through export and reopen', () async {
    final root = await Directory.systemTemp.createTemp('dsh-t12-scoped-whitespace-');
    TavernEngine? ownedEngine;
    addTearDown(() async {
      try {
        await ownedEngine?.close();
      } finally {
        if (await root.exists()) await root.delete(recursive: true);
      }
      expect(await root.exists(), isFalse);
      stdout.writeln('SCOPED_WHITESPACE_CLEANUP');
    });
    final model = T24Model();
    var keyReads = 0;
    final config = TavernModelConfig(
      apiKey: () async {
        keyReads++;
        return 'fixture-key';
      },
      model: 'scoped-whitespace-oracle',
    );
    Future<TavernEngine> open() => TavernEngine.openDirectory(root, config: config, modelClient: model);
    var engine = await open();
    ownedEngine = engine;
    Tavern facade = engine;
    await facade.setSettings({'macroEngine': 'modern', 'globalRegexScripts': <Object?>[]});
    final character = await facade.importCard(t24Card());
    final chatId = await facade.createChat(character.id);
    final greeting = (await facade.path(chatId)).single;
    expect(greeting.text, 'G');
    const ordinaryBody = 'T[A\n  B]|I[C]|P[ K ]';
    final ordinary = await facade.sendOnly(
      chatId,
      'T[{{trim}}\n    A\n      B\n{{/trim}}]|'
      'I[{{if::true}} \t C \n{{else}}{{incvar::untaken}}{{/if}}]|P[{{#trim}} K {{/trim}}]',
    );
    expect(ordinary.text, ordinaryBody);
    expect(ordinary.parentId, greeting.nodeId);
    final beforeTarget = [(greeting.nodeId, 'G'), (ordinary.nodeId, ordinaryBody)];
    expect((await facade.path(chatId)).map((message) => (message.nodeId, message.text)), beforeTarget);
    final ordinaryFile = (await facade.exportChat(chatId)).single;
    final ordinaryDocument = StChatDocument.decode(ordinaryFile.fileName, ordinaryFile.bytes);
    expect(ordinaryDocument.messages.map((message) => message['mes']), ['G', ordinaryBody]);
    final settings = await facade.readSettings(chatId: chatId);
    expect(settings['macroEngine'], 'modern');
    expect(settings['globalRegexScripts'], isEmpty);
    expect(await facade.readVariables(chatId), isEmpty);
    expect(await facade.inspectTurn(chatId), isNull);
    expect(model.generated, 0);
    expect(keyReads, 0);
    stdout.writeln('SCOPED_WHITESPACE_READY');

    final boundary = await facade.sendOnly(
      chatId,
      'T[{{trim}}\u0085T{{/trim}}]|'
      'I[{{if::true}}\u0085{{incvar::selected}}{{else}}{{incvar::untaken}}{{/if}}]|'
      'P[{{#trim}}\u0085K{{/trim}}]|{{getvar::selected}}/{{getvar::untaken}}',
    );
    const boundaryBody = 'T[\u0085T]|I[\u00851]|P[\u0085K]|1/';
    // First target assertion. Raw097 instead returns T[T]|I[1]|P[\u0085K]|1/
    // (escaped NEL; source prediction, not a Dart run).
    expect(boundary.text, boundaryBody);
    expect(boundary.role, TavernRole.user);
    expect(boundary.parentId, ordinary.nodeId);
    final expected = [...beforeTarget, (boundary.nodeId, boundaryBody)];
    Future<void> checkSaved() async {
      final path = await facade.path(chatId);
      expect(path.map((message) => (message.nodeId, message.text)), expected);
      expect(path.last.role, TavernRole.user);
      expect(path.last.parentId, ordinary.nodeId);
      expect(await facade.readVariables(chatId), {'selected': 1});
      final file = (await facade.exportChat(chatId)).single;
      final document = StChatDocument.decode(file.fileName, file.bytes);
      expect(document.messages.map((message) => message['mes']), expected.map((row) => row.$2));
      final metadata = document.header['chat_metadata']! as Map<String, Object?>;
      expect(metadata['variables'], {'selected': 1});
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
    expect(reopenedSettings['globalRegexScripts'], isEmpty);
    await checkSaved();
  });
}

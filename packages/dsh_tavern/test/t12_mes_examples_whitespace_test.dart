import 'dart:io';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:test/test.dart';

import 'support/t24_engine_harness.dart';

void main() {
  test('both macro engines format example blocks with JavaScript whitespace and preserve raw fields', () {
    // Literal oracles from the original fixed-ST card-field preparation and
    // parseMesExamples functions. The last value is the optional chat override.
    const rows = <(String, String, String, String, String?)>[
      ('empty', '', '', '', null),
      ('exact START', '<START>', '<START>', '', null),
      ('whitespace around START', ' \t<START>\n', '<START>', '', null),
      ('ordinary no header', ' \tU: hello \n', 'U: hello', '<START>\nU: hello\n', null),
      ('NEL with header', '<START>\n\u0085X\u0085', '<START>\n\u0085X\u0085', '<START>\n\u0085X\u0085\n', null),
      ('NEL without header', '\u0085X\u0085', '\u0085X\u0085', '<START>\n\u0085X\u0085\n', null),
      ('NEL only', '\u0085', '\u0085', '<START>\n\u0085\n', null),
      (
        'NEL at internal block edges',
        'A\u0085<START>\n\u0085B\u0085',
        'A\u0085<START>\n\u0085B\u0085',
        '<START>\nA\u0085\n<START>\n\u0085B\u0085\n',
        null,
      ),
      (
        'case sensitive prefix and insensitive split',
        '<start>\n\u0085X\u0085',
        '<start>\n\u0085X\u0085',
        '<START>\n\n<START>\n\u0085X\u0085\n',
        null,
      ),
      (
        'adjacent and trailing separators',
        '<START>A<start><START>',
        '<START>A<start><START>',
        '<START>\nA\n<START>\n\n<START>\n\n',
        null,
      ),
      (
        'CRLF preparation before format',
        '<START>\r\n\u0085X\u0085\r\n',
        '<START>\n\u0085X\u0085',
        '<START>\n\u0085X\u0085\n',
        null,
      ),
      ('NBSP and BOM trim normally', '\u00a0\ufeffX\ufeff\u00a0', 'X', '<START>\nX\n', null),
      ('ZWSP retained', '\u200bX\u200b', '\u200bX\u200b', '<START>\n\u200bX\u200b\n', null),
      ('Unicode payload', '\u0085鲸🙂\u0085', '\u0085鲸🙂\u0085', '<START>\n\u0085鲸🙂\u0085\n', null),
      ('truthy chat override', 'ignored', '\u0085O\u0085', '<START>\n\u0085O\u0085\n', '\u0085O\u0085'),
      ('empty override falls back', 'plain', 'plain', '<START>\nplain\n', ''),
    ];
    for (final legacy in [false, true]) {
      for (final row in rows) {
        MacroContext context() => MacroContext(card: {'mes_example': row.$2}, mesExamplesOverride: row.$5);
        String expand(String text) =>
            legacy ? const LegacyMacroEngine().expand(text, context()) : const MacroEngine().expand(text, context());
        final mode = legacy ? 'legacy' : 'modern';
        expect(expand('{{mesExamples}}'), row.$4, reason: '$mode ${row.$1}: formatted');
        expect(expand('{{mesExamplesRaw}}'), row.$3, reason: '$mode ${row.$1}: raw');
      }
    }
  });

  test('modern sendOnly preserves formatted example NEL and raw fields through export and reopen', () async {
    final root = await Directory.systemTemp.createTemp('dsh-t12-mes-examples-whitespace-');
    TavernEngine? ownedEngine;
    addTearDown(() async {
      try {
        await ownedEngine?.close();
      } finally {
        if (await root.exists()) await root.delete(recursive: true);
      }
      expect(await root.exists(), isFalse);
      stdout.writeln('MES_EXAMPLES_FORMAT_CLEANUP');
    });
    final model = T24Model();
    var keyReads = 0;
    final config = TavernModelConfig(
      apiKey: () async {
        keyReads++;
        return 'fixture-key';
      },
      model: 'mes-examples-whitespace-oracle',
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
    const template = 'F[{{mesExamples}}]|R[{{mesExamplesRaw}}]';
    const ordinaryRaw = ' \tA \n';
    await facade.updateCharacterFields(character.id, {'mes_example': ordinaryRaw});
    expect((await facade.characterFields(character.id))?['mes_example'], ordinaryRaw);
    final ordinary = await facade.sendOnly(chatId, template);
    const ordinaryBody = 'F[<START>\nA\n]|R[A]';
    expect(ordinary.text, ordinaryBody);
    expect(ordinary.role, TavernRole.user);
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

    const boundaryRaw = '<START>\n\u0085X\u0085';
    await facade.updateCharacterFields(character.id, {'mes_example': boundaryRaw});
    expect((await facade.characterFields(character.id))?['mes_example'], boundaryRaw);
    stdout.writeln('MES_EXAMPLES_FORMAT_READY');

    final boundary = await facade.sendOnly(chatId, template);
    const boundaryBody = 'F[<START>\n\u0085X\u0085\n]|R[<START>\n\u0085X\u0085]';
    // First target assertion. Raw097 instead returns (escaped NEL):
    // F[<START>\nX\n]|R[<START>\n\u0085X\u0085]. This is a source prediction.
    expect(boundary.text, boundaryBody);
    expect(boundary.role, TavernRole.user);
    expect(boundary.parentId, ordinary.nodeId);
    final expected = [...beforeTarget, (boundary.nodeId, boundaryBody)];
    Future<void> checkSaved() async {
      final path = await facade.path(chatId);
      expect(path.map((message) => (message.nodeId, message.text)), expected);
      expect(path.last.role, TavernRole.user);
      expect(path.last.parentId, ordinary.nodeId);
      expect((await facade.characterFields(character.id))?['mes_example'], boundaryRaw);
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
    expect(reopenedSettings['globalRegexScripts'], isEmpty);
    await checkSaved();
  });
}

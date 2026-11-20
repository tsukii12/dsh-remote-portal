import 'dart:convert';
import 'dart:io';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:test/test.dart';

import 'support/t24_engine_harness.dart';

void main() {
  test('modern conditions and lazy defaults use JavaScript boolean whitespace', () {
    const macros = MacroEngine();
    // Fixed ST 7e8663cd uses utils.isFalseBoolean for both if and the
    // variable walker's || / ||= operations. NEL is not JavaScript trim.
    for (final row in const <(String, bool)>[
      ('false', false),
      ('OFF', false),
      ('0', false),
      ('', false),
      ('\tFALSE\u00a0', false),
      ('\ufeffoff\u202f', false),
      ('true', true),
      ('\u0085false', true),
      ('off\u0085', true),
      ('\u00850\u0085', true),
      ('\u0085', true),
    ]) {
      final context = MacroContext(localVariables: {'flag': row.$1, 'chosen': 0, 'rejected': 0, 'fallback': 0});
      final reason = row.$1.codeUnits.toString();
      expect(
        macros.expand('{{if .flag}}T{{incvar::chosen}}{{else}}F{{incvar::rejected}}{{/if}}', context),
        row.$2 ? 'T1' : 'F1',
        reason: reason,
      );
      expect(context.localVariables['chosen'], row.$2 ? 1 : 0, reason: reason);
      expect(context.localVariables['rejected'], row.$2 ? 0 : 1, reason: reason);
      expect(macros.expand('{{.flag || {{incvar::fallback}}}}', context), row.$2 ? row.$1 : '1', reason: reason);
      expect(context.localVariables['flag'], row.$1, reason: reason);
      expect(macros.expand('{{.flag ||= {{incvar::fallback}}}}', context), row.$2 ? row.$1 : '2', reason: reason);
      expect(context.localVariables['flag'], row.$2 ? row.$1 : '2', reason: reason);
      expect(context.localVariables['fallback'], row.$2 ? 0 : 2, reason: reason);
    }
  });

  test('modern sendOnly default assignment preserves a NEL boolean value through reopen', () async {
    final root = await Directory.systemTemp.createTemp('dsh-t12-boolean-whitespace-');
    TavernEngine? ownedEngine;
    addTearDown(() async {
      await ownedEngine?.close();
      if (await root.exists()) await root.delete(recursive: true);
      expect(await root.exists(), isFalse);
      stdout.writeln('BOOLEAN_WHITESPACE_CLEANUP');
    });
    final model = T24Model();
    var keyReads = 0;
    final config = TavernModelConfig(
      apiKey: () async {
        keyReads++;
        return 'fixture-key';
      },
      model: 'boolean-whitespace-oracle',
    );
    Future<TavernEngine> open() => TavernEngine.openDirectory(root, config: config, modelClient: model);
    var engine = await open();
    ownedEngine = engine;
    Tavern facade = engine;
    await facade.setSettings({'macroEngine': 'modern', 'globalRegexScripts': <Object?>[]});
    final character = await facade.importCard(t24Card());
    final chatId = await facade.createChat(character.id);
    final settings = await facade.readSettings(chatId: chatId);
    expect(settings['macroEngine'], 'modern');
    expect(settings['globalRegexScripts'], isEmpty);
    final greeting = (await facade.path(chatId)).single;
    expect(greeting.text, 'G');
    final ordinary = await facade.sendOnly(chatId, '{{setvar::ordinary::false}}{{.ordinary ||= NORMAL}}');
    expect(ordinary.text, 'NORMAL');
    expect((await facade.readVariables(chatId))['ordinary'], 'NORMAL');
    final ready = await facade.sendOnly(chatId, '{{setvar::flag::\u0085false}}READY');
    expect(ready.text, 'READY');
    expect((await facade.readVariables(chatId))['flag'], '\u0085false');
    expect(model.generated, 0);
    expect(keyReads, 0);
    expect(await facade.inspectTurn(chatId), isNull);

    await facade.close();
    ownedEngine = null;
    engine = await open();
    ownedEngine = engine;
    facade = engine;
    expect((await facade.readVariables(chatId))['flag'], '\u0085false');
    expect((await facade.path(chatId)).map((message) => (message.nodeId, message.text)), [
      (greeting.nodeId, 'G'),
      (ordinary.nodeId, 'NORMAL'),
      (ready.nodeId, 'READY'),
    ]);
    expect((await facade.readSettings(chatId: chatId))['macroEngine'], 'modern');
    expect(model.generated, 0);
    expect(keyReads, 0);
    stdout.writeln('BOOLEAN_WHITESPACE_READY');

    final result = await facade.sendOnly(chatId, 'KEPT[{{.flag ||= CHANGED}}]');
    // First target assertion is the whole public message. The old helper
    // trims NEL, treats the saved value as false, and returns KEPT[CHANGED].
    expect(result.text, 'KEPT[\u0085false]');
    expect(result.role, TavernRole.user);
    expect(result.parentId, ready.nodeId);
    expect((await facade.readVariables(chatId))['flag'], '\u0085false');
    final expected = [
      (greeting.nodeId, 'G'),
      (ordinary.nodeId, 'NORMAL'),
      (ready.nodeId, 'READY'),
      (result.nodeId, 'KEPT[\u0085false]'),
    ];
    expect((await facade.path(chatId)).map((message) => (message.nodeId, message.text)), expected);
    expect(model.generated, 0);
    expect(keyReads, 0);

    await facade.close();
    ownedEngine = null;
    engine = await open();
    ownedEngine = engine;
    facade = engine;
    expect((await facade.readVariables(chatId))['flag'], '\u0085false');
    expect((await facade.path(chatId)).map((message) => (message.nodeId, message.text)), expected);
    final exported = (await facade.exportChat(chatId)).single;
    final rows = const LineSplitter()
        .convert(utf8.decode(exported.bytes))
        .where((line) => line.isNotEmpty)
        .map((line) => jsonDecode(line) as Map<String, Object?>);
    expect(rows.where((row) => row['mes'] == 'KEPT[\u0085false]'), hasLength(1));
    expect(model.generated, 0);
    expect(keyReads, 0);
    expect(await facade.inspectTurn(chatId), isNull);
  });
}

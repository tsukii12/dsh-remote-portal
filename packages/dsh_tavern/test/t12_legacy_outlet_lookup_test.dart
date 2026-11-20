import 'dart:convert';
import 'dart:io';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:test/test.dart';

import 'support/t24_engine_harness.dart' show t24Card, t24Preset;

void main() {
  test('legacy outlet lookup preserves JavaScript whitespace and exact key identity', () {
    // Literal outcomes from the original fixed-ST outlet routing and replacement.
    // This pure macro matrix supplies already-joined outlet values, not WI scans.
    const rows = <(String, Map<String, String>, String, String)>[
      ('ordinary slot', {'slot': 'OUTLET'}, 'LEFT{{outlet::slot}}RIGHT', 'LEFTOUTLETRIGHT'),
      (
        'JS whitespace',
        {'slot': 'OUTLET'},
        'LEFT{{outlet:: \t\u00a0\ufeffslot\ufeff\u00a0\t }}RIGHT',
        'LEFTOUTLETRIGHT',
      ),
      ('NEL suffix excludes plain key', {'slot': 'OUTLET'}, 'LEFT{{outlet::slot\u0085}}RIGHT', 'LEFTRIGHT'),
      ('NEL prefix excludes plain key', {'slot': 'OUTLET'}, 'LEFT{{outlet::\u0085slot}}RIGHT', 'LEFTRIGHT'),
      ('NEL both edges exclude plain key', {'slot': 'OUTLET'}, 'LEFT{{outlet::\u0085slot\u0085}}RIGHT', 'LEFTRIGHT'),
      ('NEL exact independent name', {'slot\u0085': 'EDGE'}, 'LEFT{{outlet::slot\u0085}}RIGHT', 'LEFTEDGERIGHT'),
      (
        'plain and NEL names remain distinct',
        {'slot': 'BASE', 'slot\u0085': 'EDGE'},
        'LEFT{{outlet::slot\u0085}}RIGHT',
        'LEFTEDGERIGHT',
      ),
      ('macro name insensitive', {'slot': 'OUTLET'}, 'LEFT{{OuTlEt::slot}}RIGHT', 'LEFTOUTLETRIGHT'),
      ('key name sensitive', {'slot': 'OUTLET'}, 'LEFT{{outlet::SLOT}}RIGHT', 'LEFTRIGHT'),
      ('missing key', {'slot': 'OUTLET'}, 'LEFT{{outlet::missing}}RIGHT', 'LEFTRIGHT'),
      ('empty capture does not match', {'slot': 'OUTLET'}, 'LEFT{{outlet::}}RIGHT', 'LEFT{{outlet::}}RIGHT'),
      ('space capture matches then empties', {'slot': 'OUTLET'}, 'LEFT{{outlet:: }}RIGHT', 'LEFTRIGHT'),
      ('LF is not dot', {'slot': 'OUTLET'}, 'LEFT{{outlet::slot\n}}RIGHT', 'LEFT{{outlet::slot\n}}RIGHT'),
      ('CR is not dot', {'slot': 'OUTLET'}, 'LEFT{{outlet::slot\r}}RIGHT', 'LEFT{{outlet::slot\r}}RIGHT'),
      ('LS is not dot', {'slot': 'OUTLET'}, 'LEFT{{outlet::slot\u2028}}RIGHT', 'LEFT{{outlet::slot\u2028}}RIGHT'),
      ('PS is not dot', {'slot': 'OUTLET'}, 'LEFT{{outlet::slot\u2029}}RIGHT', 'LEFT{{outlet::slot\u2029}}RIGHT'),
      ('late placeholder is not revisited', {'slot': '{{trim}}'}, 'LEFT{{outlet::slot}}RIGHT', 'LEFT{{trim}}RIGHT'),
      ('same outlet joins in order', {'slot': 'ONE\nTWO'}, 'LEFT{{outlet::slot}}RIGHT', 'LEFTONE\nTWORIGHT'),
    ];
    for (final row in rows) {
      final context = MacroContext(outlets: row.$2, random: () => 0.25);
      expect(const LegacyMacroEngine().expand(row.$3, context), row.$4, reason: row.$1);
    }
  });

  test('public legacy outlet lookup preserves complete model messages through imports and reopen', () async {
    final root = await Directory.systemTemp.createTemp('dsh-t12-legacy-outlet-');
    TavernEngine? ownedEngine;
    addTearDown(() async {
      try {
        await ownedEngine?.close();
      } finally {
        if (await root.exists()) await root.delete(recursive: true);
      }
      expect(await root.exists(), isFalse);
      stdout.writeln('LEGACY_OUTLET_LOOKUP_CLEANUP');
    });
    final model = _Model();
    var keyReads = 0;
    var randomReads = 0;
    final config = TavernModelConfig(
      apiKey: () async {
        keyReads++;
        return 'fixture-key';
      },
      baseUrl: 'https://fixture.invalid/v1',
      model: 'legacy-outlet-oracle',
      deepseek: false,
    );
    Future<TavernEngine> open() => TavernEngine.openDirectory(
      root,
      config: config,
      modelClient: model,
      clock: () => DateTime.utc(2026, 11, 10, 12),
      random: () {
        randomReads++;
        return 0.25;
      },
    );
    var engine = await open();
    ownedEngine = engine;
    Tavern facade = engine;
    await facade.setSettings({'macroEngine': 'legacy', 'globalRegexScripts': <Object?>[], 'worldInfo': _settings});
    final character = await facade.importCard(t24Card());
    final ordinaryChat = await facade.createChat(character.id);
    final targetChat = await facade.createChat(character.id);
    final ordinaryGreeting = (await facade.path(ordinaryChat)).single;
    final targetGreeting = (await facade.path(targetChat)).single;
    expect([ordinaryGreeting.text, targetGreeting.text], ['G', 'G']);

    final bookImport = await facade.importLorebook(jsonEncode(_bookRaw), fileName: 'outlet-key.json');
    expect(bookImport.diagnostics, isEmpty);
    expect(bookImport.book.raw, _bookRaw);
    final bookId = bookImport.book.id;
    await facade.bindLorebooks([bookId], chatId: ordinaryChat);
    await facade.bindLorebooks([bookId], chatId: targetChat);
    final ordinaryRaw = _preset('LEFT{{outlet::slot}}RIGHT');
    final targetRaw = _preset('LEFT{{outlet::slot\u0085}}RIGHT');
    final ordinarySource = jsonEncode(ordinaryRaw);
    final targetSource = jsonEncode(targetRaw);
    final ordinaryImport = await facade.importPreset(ordinarySource, fileName: 'ordinary.json');
    final targetImport = await facade.importPreset(targetSource, fileName: 'boundary.json');
    expect(ordinaryImport.issues, isEmpty);
    expect(targetImport.issues, isEmpty);
    final ordinaryPresetId = ordinaryImport.preset.id;
    final targetPresetId = targetImport.preset.id;
    await facade.bindPreset(ordinaryChat, ordinaryPresetId);
    await facade.bindPreset(targetChat, targetPresetId);

    Future<void> checkSources(String chatId, String presetId, Map<String, Object?> raw, String source) async {
      expect(await facade.lorebook(bookId), _bookRaw);
      expect(jsonDecode(await facade.exportLorebook(bookId)), _bookRaw);
      final preset = (await facade.preset(presetId))!;
      expect(preset.raw, raw);
      expect(preset.sourceText, source);
      expect(jsonDecode(await facade.exportPreset(presetId)), raw);
      final selection = await facade.presetSelection(chatId: chatId);
      expect(
        (selection.source, selection.boundPresetId, selection.effectivePresetId),
        (PresetSelectionSource.chat, presetId, presetId),
      );
      final settings = await facade.readSettings(chatId: chatId);
      expect((settings['lorebooks']! as Map<String, Object?>)['global'], [bookId]);
      expect(settings['macroEngine'], 'legacy');
      expect(settings['globalRegexScripts'], isEmpty);
      expect(settings['worldInfo'], _settings);
    }

    Future<void> checkSaved(
      String chatId,
      String greetingId,
      String userId,
      String replyId,
      Map<String, Object?> body,
    ) async {
      final path = await facade.path(chatId);
      expect(path.map((message) => (message.nodeId, message.parentId, message.role, message.text)).toList(), [
        (greetingId, null, TavernRole.character, 'G'),
        (userId, greetingId, TavernRole.user, 'H'),
        (replyId, userId, TavernRole.character, 'OK'),
      ]);
      final file = (await facade.exportChat(chatId)).single;
      final document = StChatDocument.decode(file.fileName, file.bytes);
      expect(document.messages.map((message) => message['mes']), ['G', 'H', 'OK']);
      expect(await facade.readVariables(chatId), isEmpty);
      final inspection = (await facade.inspectTurn(chatId))!;
      expect(inspection.status, TavernInspectionStatus.completed);
      expect((inspection.contextNodeId, inspection.nodeId), (greetingId, replyId));
      expect(inspection.failure, isNull);
      expect(inspection.prompt!.body, body);
      final hits = (inspection.worldInfo['activated']! as List<Object?>).cast<Map<String, Object?>>();
      expect(
        hits
            .map(
              (hit) => (
                hit['bookId'],
                hit['uid'],
                hit['content'],
                hit['position'],
                hit['outlet'],
                hit['reason'],
                hit['phase'],
              ),
            )
            .toList(),
        [(bookId, '0', 'OUTLET', 7, 'slot', 'constant', 'initial')],
      );
    }

    await checkSources(ordinaryChat, ordinaryPresetId, ordinaryRaw, ordinarySource);
    await checkSources(targetChat, targetPresetId, targetRaw, targetSource);
    const ordinaryMessages = <Map<String, Object?>>[
      {'role': 'system', 'content': 'LEFTOUTLETRIGHT'},
      {'role': 'assistant', 'content': 'G'},
      {'role': 'user', 'content': 'H'},
    ];
    const targetMessages = <Map<String, Object?>>[
      {'role': 'system', 'content': 'LEFTRIGHT'},
      {'role': 'assistant', 'content': 'G'},
      {'role': 'user', 'content': 'H'},
    ];
    final ordinary = await facade.send(ordinaryChat, 'H').toList();
    expect(ordinary.whereType<TavernTurnFailed>(), isEmpty);
    expect(ordinary.whereType<TavernTurnDone>(), hasLength(1));
    final ordinaryDone = ordinary.whereType<TavernTurnDone>().single;
    expect(model.bodies, hasLength(1));
    // Independent snapshot: a later request cannot mutate the ordinary oracle.
    final ordinaryBody = _copy(model.bodies.single);
    expect(ordinaryBody['messages'], ordinaryMessages);
    final ordinaryUserId = (await facade.path(ordinaryChat))[1].nodeId;
    await checkSaved(ordinaryChat, ordinaryGreeting.nodeId, ordinaryUserId, ordinaryDone.message.nodeId, ordinaryBody);
    expect((await facade.path(targetChat)).map((message) => (message.nodeId, message.text)).toList(), [
      (targetGreeting.nodeId, 'G'),
    ]);
    expect(randomReads, 0);
    expect(keyReads, 0);
    stdout.writeln('LEGACY_OUTLET_LOOKUP_READY');

    final target = await facade.send(targetChat, 'H').toList();
    // First target assertion: complete messages for both calls, before any target
    // success or indexing. Raw097 instead inserts OUTLET in the second main.
    expect(model.bodies.map((body) => body['messages']).toList(), [ordinaryBody['messages'], targetMessages]);
    expect(target.whereType<TavernTurnFailed>(), isEmpty);
    expect(target.whereType<TavernTurnDone>(), hasLength(1));
    final targetDone = target.whereType<TavernTurnDone>().single;
    final targetBody = {..._copy(ordinaryBody), 'messages': targetMessages};
    expect(model.bodies, [ordinaryBody, targetBody]);
    final targetUserId = (await facade.path(targetChat))[1].nodeId;
    await checkSaved(targetChat, targetGreeting.nodeId, targetUserId, targetDone.message.nodeId, targetBody);
    await checkSources(ordinaryChat, ordinaryPresetId, ordinaryRaw, ordinarySource);
    await checkSources(targetChat, targetPresetId, targetRaw, targetSource);
    expect(randomReads, 0);
    expect(keyReads, 0);

    await facade.close();
    ownedEngine = null;
    engine = await open();
    ownedEngine = engine;
    facade = engine;
    await checkSources(ordinaryChat, ordinaryPresetId, ordinaryRaw, ordinarySource);
    await checkSources(targetChat, targetPresetId, targetRaw, targetSource);
    await checkSaved(ordinaryChat, ordinaryGreeting.nodeId, ordinaryUserId, ordinaryDone.message.nodeId, ordinaryBody);
    await checkSaved(targetChat, targetGreeting.nodeId, targetUserId, targetDone.message.nodeId, targetBody);
    expect(model.bodies, [ordinaryBody, targetBody]);
    expect(randomReads, 0);
    expect(keyReads, 0);
  });
}

const _settings = <String, Object?>{'world_info_depth': 1, 'world_info_budget': 100, 'world_info_recursive': false};
const _bookRaw = <String, Object?>{
  'name': 'Outlet key identity',
  'entries': {
    '0': {
      'uid': 0,
      'key': <String>[],
      'keysecondary': <String>[],
      'constant': true,
      'disable': false,
      'selective': false,
      'useProbability': false,
      'content': 'OUTLET',
      'position': 7,
      'outletName': 'slot',
      'order': 100,
    },
  },
};

Map<String, Object?> _preset(String content) {
  final raw = _copy(t24Preset().raw);
  final prompts = (raw['prompts']! as List<Object?>).cast<Map<String, Object?>>();
  prompts.singleWhere((prompt) => prompt['identifier'] == 'main')['content'] = content;
  return raw;
}

Map<String, Object?> _copy(Map<String, Object?> value) => jsonDecode(jsonEncode(value)) as Map<String, Object?>;

class _Model extends TavernModelClient {
  final bodies = <Map<String, Object?>>[];

  @override
  Stream<ModelDelta> generate({
    required TavernModelConfig config,
    required Map<String, Object?> body,
    required ModelCancellation cancellation,
    void Function(int attempt)? onRequestStarted,
  }) {
    bodies.add(_copy(body));
    return Stream<ModelDelta>.fromIterable(const [ModelText('OK'), ModelFinished('stop')]);
  }
}

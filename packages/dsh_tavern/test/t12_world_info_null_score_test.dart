import 'dart:convert';
import 'dart:io';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:test/test.dart';

import 'support/t24_engine_harness.dart';

void main() {
  test('world info group scoring separates native nullish logic from activation and V3 defaults', () async {
    final worker = RegexWorker();
    addTearDown(worker.close);
    final engine = WorldInfoEngine(worker: worker);
    final rows = <(String, Map<String, Object?>, String, String, int)>[
      ('native AND_ANY, also the result of ST editor backfilling missing logic', _nativeBook(0), '0', 'BODY_A', 0),
      ('native explicit null survives ST editor backfill', _nativeBook(null), '1', 'BODY_B', 0),
      ('native missing before ST editor backfill', _nativeBook(null, omitLogic: true), '1', 'BODY_B', 0),
      ('native AND_ALL', _nativeBook(3), '0', 'BODY_A', 3),
      ('native NOT_ALL rejects the fully matched secondary set', _nativeBook(1), '1', 'BODY_B', 1),
      ('native NOT_ANY rejects the matching secondary set', _nativeBook(2), '1', 'BODY_B', 2),
      ('V3 null is converted to AND_ANY before scoring', _v3Book(null), '0', 'BODY_A', 0),
      ('V3 missing is converted to AND_ANY before scoring', _v3Book(null, omitLogic: true), '0', 'BODY_A', 0),
    ];
    for (final row in rows) {
      final before = _copy(row.$2);
      final book = WorldInfoBook.fromJson(
        id: 'book',
        source: row.$2['entries'] is List<Object?> ? WorldInfoSource.character : WorldInfoSource.global,
        json: row.$2,
      );
      var randomReads = 0;
      final result = await engine.evaluate(
        WorldInfoInput(
          books: [book],
          messages: const [WorldInfoMessage('a b c')],
          maxContext: 10000,
          tokenCount: (text) => text.length, // Explicit toy UTF-16 counter; budget is deliberately ample.
          settings: WorldInfoSettings.fromJson(_settings),
          random: () {
            randomReads++;
            throw StateError('The unique score winner must not draw random.');
          },
        ),
      );
      expect(result.activated.map((hit) => (hit.uid, hit.content)).toList(), [(row.$3, row.$4)], reason: row.$1);
      expect(result.beforeText, row.$4, reason: row.$1);
      expect(result.afterText, isEmpty, reason: row.$1);
      expect(result.activated.map((hit) => hit.reason), ['keywords'], reason: row.$1);
      expect(result.overflowed, isFalse, reason: row.$1);
      expect(result.regexDiagnostics, isEmpty, reason: row.$1);
      expect(randomReads, 0, reason: row.$1);
      // Activation retains its existing getter default without rewriting raw.
      expect(book.entries.first.selectiveLogic, row.$5, reason: row.$1);
      expect(book.raw, before, reason: row.$1);
      expect(row.$2, before, reason: row.$1);
    }
  });

  test('public native lorebook null logic selects the complete model messages through import and reopen', () async {
    final root = await Directory.systemTemp.createTemp('dsh-t12-wi-null-score-');
    TavernEngine? ownedEngine;
    addTearDown(() async {
      try {
        await ownedEngine?.close();
      } finally {
        if (await root.exists()) await root.delete(recursive: true);
      }
      expect(await root.exists(), isFalse);
      stdout.writeln('WI_NULL_SCORE_CLEANUP');
    });
    final model = _Model();
    var randomReads = 0;
    var keyReads = 0;
    final config = TavernModelConfig(
      apiKey: () async {
        keyReads++;
        return 'fixture-key';
      },
      baseUrl: 'https://fixture.invalid/v1',
      model: 'wi-null-score-oracle',
      deepseek: false,
    );
    Future<TavernEngine> open() => TavernEngine.openDirectory(
      root,
      config: config,
      modelClient: model,
      clock: () => T24Harness.at,
      random: () {
        randomReads++;
        throw StateError('The unique score winner must not draw random.');
      },
    );
    var engine = await open();
    ownedEngine = engine;
    Tavern facade = engine;
    await facade.setSettings({'macroEngine': 'modern', 'globalRegexScripts': <Object?>[], 'worldInfo': _settings});
    final preset = (await facade.importPreset(jsonEncode(t24Preset().raw))).preset;
    final character = await facade.importCard(t24Card());
    final ordinaryChat = await facade.createChat(character.id);
    final targetChat = await facade.createChat(character.id);
    await facade.bindPreset(ordinaryChat, preset.id);
    await facade.bindPreset(targetChat, preset.id);
    final ordinaryRaw = _nativeBook(0);
    final targetRaw = _nativeBook(null);
    final ordinaryImport = await facade.importLorebook(jsonEncode(ordinaryRaw), fileName: 'ordinary.json');
    final targetImport = await facade.importLorebook(jsonEncode(targetRaw), fileName: 'null-logic.json');
    expect(ordinaryImport.diagnostics, isEmpty);
    expect(targetImport.diagnostics, isEmpty);
    final ordinaryBookId = ordinaryImport.book.id;
    final targetBookId = targetImport.book.id;
    expect(ordinaryImport.book.raw, ordinaryRaw);
    expect(targetImport.book.raw, targetRaw);
    await facade.bindLorebooks([ordinaryBookId], chatId: ordinaryChat);
    await facade.bindLorebooks([targetBookId], chatId: targetChat);
    final ordinaryGreeting = (await facade.path(ordinaryChat)).single;
    final targetGreeting = (await facade.path(targetChat)).single;
    expect([ordinaryGreeting.text, targetGreeting.text], ['G', 'G']);

    Future<void> checkBook(String chatId, String bookId, Map<String, Object?> raw) async {
      expect(await facade.lorebook(bookId), raw);
      expect(jsonDecode(await facade.exportLorebook(bookId)), raw);
      final settings = await facade.readSettings(chatId: chatId);
      expect((settings['lorebooks']! as Map<String, Object?>)['global'], [bookId]);
      expect(settings['worldInfo'], _settings);
    }

    Future<void> checkSaved(
      String chatId,
      String greetingId,
      String replyId,
      Map<String, Object?> body,
      String bookId,
      String uid,
      String content,
    ) async {
      final path = await facade.path(chatId);
      expect(path.map((message) => (message.role, message.text)).toList(), [
        (TavernRole.character, 'G'),
        (TavernRole.user, 'a b c'),
        (TavernRole.character, 'OK'),
      ]);
      expect((path.first.nodeId, path.last.nodeId), (greetingId, replyId));
      final inspection = (await facade.inspectTurn(chatId))!;
      expect(inspection.status, TavernInspectionStatus.completed);
      expect((inspection.contextNodeId, inspection.nodeId), (greetingId, replyId));
      expect(inspection.failure, isNull);
      expect(inspection.prompt!.body, body);
      final hits = (inspection.worldInfo['activated']! as List<Object?>).cast<Map<String, Object?>>();
      expect(hits.map((hit) => (hit['bookId'], hit['uid'], hit['content'], hit['reason'], hit['phase'])).toList(), [
        (bookId, uid, content, 'keywords', 'initial'),
      ]);
    }

    await checkBook(ordinaryChat, ordinaryBookId, ordinaryRaw);
    await checkBook(targetChat, targetBookId, targetRaw);
    final storedTarget = WorldInfoBook.fromJson(
      id: targetBookId,
      source: WorldInfoSource.global,
      json: (await facade.lorebook(targetBookId))!,
    );
    expect(storedTarget.entries.first.raw.containsKey('selectiveLogic'), isTrue);
    expect(storedTarget.entries.first.raw['selectiveLogic'], isNull);
    expect(storedTarget.entries.first.selectiveLogic, 0);
    expect(storedTarget.raw, targetRaw);

    const ordinaryMessages = <Map<String, Object?>>[
      {'role': 'system', 'content': 'BODY_A'},
      {'role': 'assistant', 'content': 'G'},
      {'role': 'user', 'content': 'a b c'},
    ];
    const targetMessages = <Map<String, Object?>>[
      {'role': 'system', 'content': 'BODY_B'},
      {'role': 'assistant', 'content': 'G'},
      {'role': 'user', 'content': 'a b c'},
    ];
    final ordinary = await facade.send(ordinaryChat, 'a b c').toList();
    expect(ordinary.whereType<TavernTurnFailed>(), isEmpty);
    expect(ordinary.whereType<TavernTurnDone>(), hasLength(1));
    final ordinaryDone = ordinary.whereType<TavernTurnDone>().single;
    expect(model.bodies, hasLength(1));
    // Independent deep copy; the second generation cannot rewrite this oracle.
    final ordinaryBody = _copy(model.bodies.single);
    expect(ordinaryBody['messages'], ordinaryMessages);
    await checkSaved(
      ordinaryChat,
      ordinaryGreeting.nodeId,
      ordinaryDone.message.nodeId,
      ordinaryBody,
      ordinaryBookId,
      '0',
      'BODY_A',
    );
    expect((await facade.path(targetChat)).map((message) => (message.nodeId, message.text)).toList(), [
      (targetGreeting.nodeId, 'G'),
    ]);
    expect(randomReads, 0);
    expect(keyReads, 0);
    stdout.writeln('WI_NULL_SCORE_READY');

    final target = await facade.send(targetChat, 'a b c').toList();
    // First target assertion: all complete model messages, before success or indexing.
    // Raw097 instead sends BODY_A in the second request's first system message.
    expect(model.bodies.map((body) => body['messages']).toList(), [ordinaryBody['messages'], targetMessages]);
    expect(target.whereType<TavernTurnFailed>(), isEmpty);
    expect(target.whereType<TavernTurnDone>(), hasLength(1));
    final targetDone = target.whereType<TavernTurnDone>().single;
    final targetBody = {..._copy(ordinaryBody), 'messages': targetMessages};
    expect(model.bodies, [ordinaryBody, targetBody]);
    expect(randomReads, 0);
    expect(keyReads, 0);
    await checkSaved(
      targetChat,
      targetGreeting.nodeId,
      targetDone.message.nodeId,
      targetBody,
      targetBookId,
      '1',
      'BODY_B',
    );
    await checkBook(ordinaryChat, ordinaryBookId, ordinaryRaw);
    await checkBook(targetChat, targetBookId, targetRaw);

    await facade.close();
    ownedEngine = null;
    engine = await open();
    ownedEngine = engine;
    facade = engine;
    await checkBook(ordinaryChat, ordinaryBookId, ordinaryRaw);
    await checkBook(targetChat, targetBookId, targetRaw);
    await checkSaved(
      ordinaryChat,
      ordinaryGreeting.nodeId,
      ordinaryDone.message.nodeId,
      ordinaryBody,
      ordinaryBookId,
      '0',
      'BODY_A',
    );
    await checkSaved(
      targetChat,
      targetGreeting.nodeId,
      targetDone.message.nodeId,
      targetBody,
      targetBookId,
      '1',
      'BODY_B',
    );
    expect(model.bodies, [ordinaryBody, targetBody]);
    expect(randomReads, 0);
    expect(keyReads, 0);
  });
}

const _settings = <String, Object?>{
  'world_info_depth': 1,
  'world_info_budget': 50,
  'world_info_include_names': false,
  'world_info_recursive': false,
  'world_info_case_sensitive': true,
  'world_info_match_whole_words': false,
  'world_info_use_group_scoring': true,
};

Map<String, Object?> _nativeBook(Object? logic, {bool omitLogic = false}) => {
  'name': 'Group score null',
  'entries': {
    for (var uid = 0; uid < 2; uid++)
      '$uid': {
        'uid': uid,
        'key': uid == 0 ? ['a'] : ['a', 'b'],
        'keysecondary': uid == 0 ? ['b', 'c'] : <String>[],
        'content': uid == 0 ? 'BODY_A' : 'BODY_B',
        'constant': false,
        'disable': false,
        'selective': true,
        if (uid != 0 || !omitLogic) 'selectiveLogic': uid == 0 ? logic : 0,
        'position': 0,
        'order': 100,
        'group': 'g',
        'groupWeight': 100,
        'useProbability': true,
        'probability': 100,
      },
  },
};

Map<String, Object?> _v3Book(Object? logic, {bool omitLogic = false}) => {
  'name': 'V3 group score defaults',
  'entries': [
    for (var uid = 0; uid < 2; uid++)
      {
        'id': uid,
        'keys': uid == 0 ? ['a'] : ['a', 'b'],
        'secondary_keys': uid == 0 ? ['b', 'c'] : <String>[],
        'content': uid == 0 ? 'BODY_A' : 'BODY_B',
        'enabled': true,
        'constant': false,
        'selective': true,
        'position': 'before_char',
        'insertion_order': 100,
        'extensions': {'group': 'g', if (uid != 0 || !omitLogic) 'selectiveLogic': uid == 0 ? logic : 0},
      },
  ],
};

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

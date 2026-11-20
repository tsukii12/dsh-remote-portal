import 'dart:convert';
import 'dart:io';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

import 'support/t24_engine_harness.dart' show T24Harness, t24Card, t24Preset;

void main() {
  test('world info group weights use Number accumulation and preserve raw numeric types', () async {
    final worker = RegexWorker();
    addTearDown(worker.close);
    final engine = WorldInfoEngine(worker: worker);
    // Literal winners and draw counts from the fixed-ST original group functions.
    // A/B map to numeric uid 0/1; each row remains one part of this registration.
    const rows = <(String, List<String>, double, bool, List<String>, String, int)>[
      ('ordinary integer pair', ['100', '100'], 0.75, false, ['1'], 'BODY_B', 1),
      ('two exact powers cross int64 sum', [_largeJson, _largeJson], 0.75, false, ['1'], 'BODY_B', 1),
      ('lower quarter', [_largeJson, _largeJson], 0.25, false, ['0'], 'BODY_A', 1),
      ('inclusive half boundary', [_largeJson, _largeJson], 0.5, false, ['0'], 'BODY_A', 1),
      ('first representable value above half', [_largeJson, _largeJson], 0.5000000000000001, false, ['1'], 'BODY_B', 1),
      ('explicit decimal spelling control', ['4611686018427387904.0', _largeJson], 0.75, false, ['1'], 'BODY_B', 1),
      ('ordinary positive fractions', ['1.5', '2.5'], 0.75, false, ['1'], 'BODY_B', 1),
      ('priority bypass', [_largeJson, _largeJson], 0.75, true, ['0'], 'BODY_A', 0),
      ('singleton bypass', [_largeJson], 0.75, false, ['0'], 'BODY_A', 0),
      ('finite weights infinite aggregate', ['1e308', '1e308'], 0.75, false, ['1'], 'BODY_B', 1),
      ('zero roll with infinite aggregate keeps both', ['1e308', '1e308'], 0.0, false, ['0', '1'], 'BODY_B\nBODY_A', 1),
    ];
    for (final row in rows) {
      final raw = _book(row.$2, priority: row.$4);
      final before = jsonEncode(raw);
      final book = WorldInfoBook.fromJson(id: 'weight', source: WorldInfoSource.global, json: raw);
      final numbers = [for (final value in row.$2) jsonDecode(value) as num];
      final integers = [for (final value in row.$2) !value.contains('.') && !value.contains('e')];
      expect(book.entries.map((entry) => entry.groupWeight), numbers, reason: row.$1);
      expect(book.entries.map((entry) => entry.groupWeight is int), integers, reason: row.$1);
      var draws = 0;
      final result = await engine.evaluate(
        WorldInfoInput(
          books: [book],
          messages: const [WorldInfoMessage('H')],
          maxContext: 10000,
          tokenCount: (text) => text.length, // Explicit UTF-16 toy counter with ample budget.
          settings: WorldInfoSettings.fromJson(_settings),
          random: () {
            draws++;
            return row.$3;
          },
        ),
      );
      expect(result.activated.map((hit) => hit.uid), row.$5, reason: row.$1);
      expect(result.activated.map((hit) => hit.content), [
        for (final uid in row.$5) uid == '0' ? 'BODY_A' : 'BODY_B',
      ], reason: row.$1);
      expect(result.activated.map((hit) => hit.reason), [for (final _ in row.$5) 'constant']);
      expect(result.before.map((hit) => hit.uid), row.$5.reversed, reason: row.$1);
      expect(result.beforeText, row.$6, reason: row.$1);
      expect(result.after, isEmpty);
      expect(result.overflowed, isFalse);
      expect(result.regexDiagnostics, isEmpty);
      expect(draws, row.$7, reason: row.$1);
      expect(jsonEncode(book.raw), before);
      expect(jsonEncode(raw), before);
      expect(book.entries.map((entry) => entry.groupWeight), numbers);
      expect(book.entries.map((entry) => entry.groupWeight is int), integers);
    }
  });

  test('public imported integer group weights preserve complete wire choice through reopen', () async {
    final root = await Directory.systemTemp.createTemp('dsh-t12-wi-weight-number-');
    TavernEngine? ownedEngine;
    final peers = <_Peer>[];
    final requests = <_Request>[];
    addTearDown(() async {
      try {
        await ownedEngine?.close();
      } finally {
        if (await root.exists()) await root.delete(recursive: true);
      }
      expect(await root.exists(), isFalse);
      expect(peers.every((peer) => peer.closed), isTrue);
      stdout.writeln('WI_WEIGHT_NUMBER_CLEANUP');
    });
    var keyReads = 0;
    var randomReads = 0;
    final config = TavernModelConfig(
      apiKey: () async {
        keyReads++;
        return 'wi-weight-fixture-key';
      },
      baseUrl: 'https://wi-weight.invalid/v1',
      model: 'wi-weight-oracle',
      deepseek: false,
    );
    final model = TavernModelClient(
      clientFactory: () {
        if (peers.length == 2) throw StateError('Unexpected additional HTTP client.');
        final peer = _Peer(requests);
        peers.add(peer);
        return peer;
      },
    );
    Future<TavernEngine> open() => TavernEngine.openDirectory(
      root,
      config: config,
      modelClient: model,
      clock: () => T24Harness.at,
      random: () {
        randomReads++;
        return 0.75;
      },
    );
    var engine = await open();
    ownedEngine = engine;
    Tavern facade = engine;
    await facade.setSettings({
      'macroEngine': 'modern',
      'userName': 'User',
      'globalRegexScripts': <Object?>[],
      'worldInfo': _settings,
    });
    final presetRaw = t24Preset().raw..['stream_openai'] = false;
    final preset = (await facade.importPreset(jsonEncode(presetRaw))).preset;
    final character = await facade.importCard(t24Card());
    final bindings = <_Binding>[];
    for (final large in [false, true]) {
      final value = large ? _largeJson : '100';
      final raw = _book([value, value]);
      final imported = await facade.importLorebook(jsonEncode(raw), fileName: 'weight-$large.json');
      expect(imported.diagnostics, isEmpty);
      final chatId = await facade.createChat(character.id);
      await facade.bindPreset(chatId, preset.id);
      await facade.bindLorebooks([imported.book.id], chatId: chatId);
      final greeting = (await facade.path(chatId)).single;
      expect((greeting.role, greeting.text, greeting.parentId), (TavernRole.character, 'G', null));
      bindings.add((
        chatId: chatId,
        bookId: imported.book.id,
        greetingId: greeting.nodeId,
        raw: raw,
        weight: large ? _largeWeight : 100,
      ));
    }
    Future<void> checkBook(_Binding binding) async {
      final stored = (await facade.lorebook(binding.bookId))!;
      final exported = jsonDecode(await facade.exportLorebook(binding.bookId)) as Map<String, Object?>;
      expect(stored, binding.raw);
      expect(exported, binding.raw);
      for (final value in [stored, exported]) {
        final parsed = WorldInfoBook.fromJson(id: binding.bookId, source: WorldInfoSource.global, json: value);
        expect(parsed.entries.map((entry) => entry.groupWeight is int), [true, true]);
        expect(parsed.entries.map((entry) => entry.groupWeight), [binding.weight, binding.weight]);
        expect(parsed.entries.map((entry) => entry.order), [100, 99]);
      }
      final settings = await facade.readSettings(chatId: binding.chatId);
      expect((settings['lorebooks']! as Map<String, Object?>)['global'], [binding.bookId]);
      expect(settings['worldInfo'], _settings);
      expect(settings['macroEngine'], 'modern');
      expect(settings['globalRegexScripts'], isEmpty);
      expect((await facade.presetSelection(chatId: binding.chatId)).effectivePresetId, preset.id);
    }

    final savedPaths = <String, List<(String, String?, TavernRole, String)>>{};
    Future<void> checkSaved(_Binding binding, String replyId, Map<String, Object?> body) async {
      final path = await facade.path(binding.chatId);
      expect(path.map((message) => (message.role, message.text)), [
        (TavernRole.character, 'G'),
        (TavernRole.user, 'H'),
        (TavernRole.character, 'OK'),
      ]);
      expect((path.first.nodeId, path.last.nodeId), (binding.greetingId, replyId));
      expect(path.map((message) => message.parentId), [null, path.first.nodeId, path[1].nodeId]);
      final identity = path.map((message) => (message.nodeId, message.parentId, message.role, message.text)).toList();
      savedPaths.putIfAbsent(binding.chatId, () => identity);
      expect(identity, savedPaths[binding.chatId]);
      final file = (await facade.exportChat(binding.chatId)).single;
      expect(StChatDocument.decode(file.fileName, file.bytes).messages.map((row) => row['mes']), ['G', 'H', 'OK']);
      final inspection = (await facade.inspectTurn(binding.chatId))!;
      expect(inspection.status, TavernInspectionStatus.completed);
      expect((inspection.contextNodeId, inspection.nodeId), (binding.greetingId, replyId));
      expect(inspection.failure, isNull);
      expect(inspection.prompt!.body, body);
      final hits = (inspection.worldInfo['activated']! as List<Object?>).cast<Map<String, Object?>>();
      expect(hits.map((hit) => (hit['bookId'], hit['uid'], hit['position'], hit['reason'], hit['order'])), [
        (binding.bookId, '1', 0, 'constant', 99),
      ]);
      expect(await facade.readVariables(binding.chatId), isEmpty);
      await checkBook(binding);
    }

    final ordinary = bindings[0];
    final target = bindings[1];
    for (final binding in bindings) {
      await checkBook(binding);
    }
    expect((requests.length, peers.length, keyReads, randomReads), (0, 0, 0, 0));
    final events = await facade.send(ordinary.chatId, 'H').toList();
    expect(events.whereType<TavernTurnFailed>(), isEmpty);
    final done = events.whereType<TavernTurnDone>().single;
    expect((done.message.text, done.finishReason), ('OK', 'stop'));
    expect(requests, hasLength(1));
    // Independent deep copy of the full finalized body from the ordinary positive control.
    final ordinaryBody = _copy(requests.single.body);
    expect(ordinaryBody['messages'], const [
      {'role': 'system', 'content': 'BODY_B'},
      {'role': 'assistant', 'content': 'G'},
      {'role': 'user', 'content': 'H'},
    ]);
    expect(ordinaryBody['model'], 'wi-weight-oracle');
    expect(ordinaryBody['stream'], isFalse);
    expect((requests.length, peers.length, keyReads, randomReads), (1, 1, 1, 1));
    expect(peers.every((peer) => peer.closed && peer.sends == 1), isTrue);
    await checkSaved(ordinary, done.message.nodeId, ordinaryBody);
    await facade.close();
    ownedEngine = null;
    engine = await open();
    ownedEngine = engine;
    facade = engine;
    await checkSaved(ordinary, done.message.nodeId, ordinaryBody);
    await checkBook(target); // Both imported weights must still be int 2^62 after a real reopen.
    expect((await facade.path(target.chatId)).map((message) => (message.nodeId, message.text)), [
      (target.greetingId, 'G'),
    ]);
    expect((requests.length, peers.length, keyReads, randomReads), (1, 1, 1, 1));
    stdout.writeln('WI_WEIGHT_NUMBER_READY');

    final targetEvents = await facade.send(target.chatId, 'H').toList();
    // First target assertion: all finalized bodies, before any target count/index/success check.
    expect(requests.map((request) => request.body).toList(), [ordinaryBody, ordinaryBody]);
    expect(targetEvents.whereType<TavernTurnFailed>(), isEmpty);
    final targetDone = targetEvents.whereType<TavernTurnDone>().single;
    expect((targetDone.message.text, targetDone.finishReason), ('OK', 'stop'));
    expect((requests.length, peers.length, keyReads, randomReads), (2, 2, 2, 2));
    expect(peers.every((peer) => peer.closed && peer.sends == 1), isTrue);
    expect(requests.map((request) => (request.method, request.url)), [
      for (var i = 0; i < 2; i++) ('POST', Uri.parse('https://wi-weight.invalid/v1/chat/completions')),
    ]);
    await checkSaved(target, targetDone.message.nodeId, ordinaryBody);
    await facade.close();
    ownedEngine = null;
    engine = await open();
    ownedEngine = engine;
    facade = engine;
    await checkSaved(ordinary, done.message.nodeId, ordinaryBody);
    await checkSaved(target, targetDone.message.nodeId, ordinaryBody);
    expect(requests.map((request) => request.body).toList(), [ordinaryBody, ordinaryBody]);
    expect((requests.length, peers.length, keyReads, randomReads), (2, 2, 2, 2));
  });
}

const _largeJson = '4611686018427387904';
const _largeWeight = 4611686018427387904;
const _settings = <String, Object?>{
  'world_info_depth': 1,
  'world_info_budget': 50,
  'world_info_include_names': false,
  'world_info_recursive': false,
  'world_info_use_group_scoring': false,
};

Map<String, Object?> _book(List<String> weights, {bool priority = false}) => {
  'name': 'Number group weights',
  'entries': {
    for (var uid = 0; uid < weights.length; uid++)
      '$uid': {
        'uid': uid,
        'key': <String>[],
        'keysecondary': <String>[],
        'constant': true,
        'disable': false,
        'content': uid == 0 ? 'BODY_A' : 'BODY_B',
        'position': 0,
        'order': 100 - uid,
        'groupWeight': jsonDecode(weights[uid]),
        'group': 'g',
        'groupOverride': priority && uid == 0,
        'useGroupScoring': false,
        'useProbability': false,
      },
  },
};

Map<String, Object?> _copy(Map<String, Object?> value) => jsonDecode(jsonEncode(value)) as Map<String, Object?>;
typedef _Binding = ({String chatId, String bookId, String greetingId, Map<String, Object?> raw, int weight});
typedef _Request = ({String method, Uri url, Map<String, Object?> body});

class _Peer extends http.BaseClient {
  _Peer(this.requests);
  final List<_Request> requests;
  var sends = 0;
  var closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final body = jsonDecode(utf8.decode(await request.finalize().toBytes())) as Map<String, Object?>;
    sends++;
    requests.add((method: request.method, url: request.url, body: body));
    const response = '{"choices":[{"message":{"role":"assistant","content":"OK"},"finish_reason":"stop"}]}';
    return http.StreamedResponse(
      Stream.value(utf8.encode(response)),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );
  }

  @override
  void close() {
    closed = true;
  }
}

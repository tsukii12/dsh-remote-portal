import 'dart:convert';
import 'dart:io';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

import 'support/t24_engine_harness.dart' show T24Harness, t24Card, t24Preset;

void main() {
  test('world info signed zeros preserve stable order transformation and priority', () async {
    final worker = RegexWorker();
    addTearDown(worker.close);
    final engine = WorldInfoEngine(worker: worker);
    // Literal order/winner oracles from fixed-ST sortFn and inclusion groups.
    // Original A/B are the native numeric uid 0/1 here; no candidate helper builds an oracle.
    const rows = <(String, String, String, List<String>, String)>[
      ('negative zero first', '-0.0', '0', ['0', '1'], '0'),
      ('negative zero second', '0', '-0.0', ['0', '1'], '0'),
      ('both negative zero', '-0.0', '-0.0', ['0', '1'], '0'),
      ('both positive zero', '0.0', '0', ['0', '1'], '0'),
      ('integer and double equal', '1', '1.0', ['0', '1'], '0'),
      ('ordinary descending', '-3', '7', ['1', '0'], '1'),
      ('fraction descending', '0.75', '0.25', ['0', '1'], '0'),
      ('negative zero above negative', '-0.0', '-1', ['0', '1'], '0'),
      ('large finite descending', '-1e308', '1e308', ['1', '0'], '1'),
    ];
    for (final row in rows) {
      for (final grouped in [false, true]) {
        final raw = _book(row.$2, row.$3, grouped: grouped);
        final before = jsonEncode(raw);
        final book = WorldInfoBook.fromJson(id: 'order', source: WorldInfoSource.global, json: raw);
        expect(worldInfoExecutionEntries([book]).map((entry) => entry.uid), row.$4, reason: row.$1);
        final signs = [(jsonDecode(row.$2) as num).isNegative, (jsonDecode(row.$3) as num).isNegative];
        expect(book.entries.map((entry) => entry.order.isNegative), signs, reason: row.$1);
        final transformed = <String>[];
        var draws = 0;
        final result = await engine.evaluate(
          WorldInfoInput(
            books: [book],
            messages: const [WorldInfoMessage('H')],
            maxContext: 10000,
            tokenCount: (text) => text.length, // Explicit UTF-16 toy counter, with ample budget.
            settings: WorldInfoSettings.fromJson(_settings),
            random: () {
              draws++;
              throw StateError('Priority and constant entries must not draw random.');
            },
            postProcessContent: (entry, content, depth) {
              transformed.add(entry.uid);
              return content;
            },
          ),
        );
        final selected = grouped ? [row.$5] : row.$4;
        expect(result.activated.map((hit) => hit.uid), selected, reason: '${row.$1}, grouped=$grouped');
        expect(transformed, selected, reason: row.$1);
        expect(result.before.map((hit) => hit.uid), selected.reversed, reason: row.$1);
        expect(result.beforeText, selected.reversed.map((uid) => uid == '0' ? 'NEG' : 'POS').join('\n'));
        expect(result.activated.map((hit) => hit.reason), [for (final _ in selected) 'constant']);
        expect(result.after, isEmpty);
        expect(result.overflowed, isFalse);
        expect(result.regexDiagnostics, isEmpty);
        expect(draws, 0);
        expect(jsonEncode(book.raw), before);
        expect(jsonEncode(raw), before);
        expect(book.entries.map((entry) => entry.order.isNegative), signs);
      }
    }
  });

  test('public imported signed zero world examples keep the complete wire order through reopen', () async {
    final root = await Directory.systemTemp.createTemp('dsh-t12-wi-signed-zero-');
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
      stdout.writeln('WI_SIGNED_ZERO_CLEANUP');
    });
    var keyReads = 0;
    var randomReads = 0;
    final config = TavernModelConfig(
      apiKey: () async {
        keyReads++;
        return 'wi-order-fixture-key';
      },
      baseUrl: 'https://wi-order.invalid/v1',
      model: 'wi-order-oracle',
      deepseek: false,
    );
    final model = TavernModelClient(
      clientFactory: () {
        if (peers.length == 4) throw StateError('Unexpected additional HTTP client.');
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
        throw StateError('Constant ungrouped entries must not draw random.');
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
      'stripExamples': false,
      'pinExamples': true,
    });
    final presetRaw = t24Preset().raw..['stream_openai'] = false;
    final preset = (await facade.importPreset(jsonEncode(presetRaw))).preset;
    final character = await facade.importCard(t24Card());
    await facade.updateCharacterFields(character.id, {'mes_example': '<START>\nUser: CARD'});
    final pairs = <int, List<_Binding>>{};
    for (final position in [5, 6]) {
      final pair = <_Binding>[];
      for (final negative in [false, true]) {
        final raw = _book(negative ? '-0.0' : '0.0', '0', position: position, examples: true);
        final source = jsonEncode(raw);
        if (negative) expect(source, contains('"order":-0.0'));
        final imported = await facade.importLorebook(source, fileName: 'order-$position-$negative.json');
        expect(imported.diagnostics, isEmpty);
        final chatId = await facade.createChat(character.id);
        await facade.bindPreset(chatId, preset.id);
        await facade.bindLorebooks([imported.book.id], chatId: chatId);
        final greeting = (await facade.path(chatId)).single;
        expect((greeting.role, greeting.text, greeting.parentId), (TavernRole.character, 'G', null));
        pair.add((
          chatId: chatId,
          bookId: imported.book.id,
          greetingId: greeting.nodeId,
          raw: raw,
          negative: negative,
          position: position,
        ));
      }
      pairs[position] = pair;
    }
    Future<void> checkBook(_Binding binding) async {
      final stored = (await facade.lorebook(binding.bookId))!;
      final exported = jsonDecode(await facade.exportLorebook(binding.bookId)) as Map<String, Object?>;
      expect(stored, binding.raw);
      expect(exported, binding.raw);
      for (final value in [stored, exported]) {
        final parsed = WorldInfoBook.fromJson(id: binding.bookId, source: WorldInfoSource.global, json: value);
        expect(parsed.entries.map((entry) => entry.order.isNegative), [binding.negative, false]);
        expect(parsed.entries.map((entry) => entry.order), [0, 0]);
      }
      final settings = await facade.readSettings(chatId: binding.chatId);
      expect((settings['lorebooks']! as Map<String, Object?>)['global'], [binding.bookId]);
      expect(settings['worldInfo'], _settings);
      expect(settings['stripExamples'], isFalse);
      expect(settings['pinExamples'], isTrue);
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
      expect(hits.map((hit) => (hit['bookId'], hit['uid'], hit['position'], hit['reason'])), [
        (binding.bookId, '0', binding.position, 'constant'),
        (binding.bookId, '1', binding.position, 'constant'),
      ]);
      expect(hits.map((hit) => (hit['order']! as num).isNegative), [binding.negative, false]);
      expect(await facade.readVariables(binding.chatId), isEmpty);
      await checkBook(binding);
    }

    for (final pair in pairs.values) {
      for (final binding in pair) {
        await checkBook(binding);
      }
    }
    final expectedBodies = <Map<String, Object?>>[];
    final saved = <(_Binding, String, Map<String, Object?>)>[];
    for (final position in [5, 6]) {
      final ordinary = pairs[position]![0];
      final target = pairs[position]![1];
      final events = await facade.send(ordinary.chatId, 'H').toList();
      expect(events.whereType<TavernTurnFailed>(), isEmpty);
      final done = events.whereType<TavernTurnDone>().single;
      expect((done.message.text, done.finishReason), ('OK', 'stop'));
      expect(requests, hasLength(expectedBodies.length + 1));
      // Deep-copy a complete ordinary wire body; the second chat differs only in zero sign.
      final ordinaryBody = _copy(requests.last.body);
      expect(ordinaryBody['messages'], _messages(position));
      expect(ordinaryBody['model'], 'wi-order-oracle');
      expect(ordinaryBody['stream'], isFalse);
      expectedBodies.add(ordinaryBody);
      expect(requests.map((request) => request.body), expectedBodies);
      expect(keyReads, expectedBodies.length);
      expect(randomReads, 0);
      expect(peers.every((peer) => peer.closed && peer.sends == 1), isTrue);
      await checkSaved(ordinary, done.message.nodeId, ordinaryBody);
      saved.add((ordinary, done.message.nodeId, ordinaryBody));
      await facade.close();
      ownedEngine = null;
      engine = await open();
      ownedEngine = engine;
      facade = engine;
      await checkSaved(ordinary, done.message.nodeId, ordinaryBody);
      await checkBook(target); // The imported -0.0 remains negative after a real reopen.
      expect((await facade.path(target.chatId)).map((message) => (message.nodeId, message.text)), [
        (target.greetingId, 'G'),
      ]);
      expect(keyReads, expectedBodies.length);
      expect(randomReads, 0);
      if (position == 5) stdout.writeln('WI_SIGNED_ZERO_READY');

      final targetEvents = await facade.send(target.chatId, 'H').toList();
      // First target assertion: complete finalized HTTP bodies. Raw097 swaps NEG/POS.
      expect(requests.map((request) => request.body).toList(), [...expectedBodies, ordinaryBody]);
      expect(targetEvents.whereType<TavernTurnFailed>(), isEmpty);
      final targetDone = targetEvents.whereType<TavernTurnDone>().single;
      expect((targetDone.message.text, targetDone.finishReason), ('OK', 'stop'));
      expectedBodies.add(_copy(ordinaryBody));
      expect(keyReads, expectedBodies.length);
      expect(randomReads, 0);
      expect(peers.every((peer) => peer.closed && peer.sends == 1), isTrue);
      expect(requests.map((request) => (request.method, request.url)), [
        for (final _ in expectedBodies) ('POST', Uri.parse('https://wi-order.invalid/v1/chat/completions')),
      ]);
      await checkSaved(target, targetDone.message.nodeId, ordinaryBody);
      saved.add((target, targetDone.message.nodeId, _copy(ordinaryBody)));
    }
    await facade.close();
    ownedEngine = null;
    engine = await open();
    ownedEngine = engine;
    facade = engine;
    for (final row in saved) {
      await checkSaved(row.$1, row.$2, row.$3);
    }
    expect(requests.map((request) => request.body), expectedBodies);
    expect((requests.length, peers.length, keyReads, randomReads), (4, 4, 4, 0));
  });
}

const _settings = <String, Object?>{
  'world_info_depth': 1,
  'world_info_budget': 50,
  'world_info_include_names': false,
  'world_info_recursive': false,
  'world_info_use_group_scoring': false,
};

Map<String, Object?> _book(String a, String b, {int position = 0, bool grouped = false, bool examples = false}) => {
  'name': 'Signed zero order',
  'entries': {
    for (var uid = 0; uid < 2; uid++)
      '$uid': {
        'uid': uid,
        'key': <String>[],
        'keysecondary': <String>[],
        'constant': true,
        'disable': false,
        'content': '${examples ? '<START>\nUser: ' : ''}${uid == 0 ? 'NEG' : 'POS'}',
        'position': position,
        'order': jsonDecode(uid == 0 ? a : b),
        'useProbability': false,
        'group': grouped ? 'g' : '',
        'groupOverride': grouped,
        'useGroupScoring': false,
      },
  },
};

List<Map<String, Object?>> _messages(int position) => [
  for (final text in position == 5 ? ['NEG', 'POS', 'CARD'] : ['CARD', 'POS', 'NEG'])
    {'role': 'system', 'content': text, 'name': 'example_user'},
  {'role': 'assistant', 'content': 'G'},
  {'role': 'user', 'content': 'H'},
];

Map<String, Object?> _copy(Map<String, Object?> value) => jsonDecode(jsonEncode(value)) as Map<String, Object?>;

typedef _Binding = ({
  String chatId,
  String bookId,
  String greetingId,
  Map<String, Object?> raw,
  bool negative,
  int position,
});
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

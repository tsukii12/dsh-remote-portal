import 'dart:convert';
import 'dart:io';

import 'package:dsh_tavern/src/regex/regex_worker.dart';
import 'package:dsh_tavern/src/worldinfo/world_info.dart';
import 'package:test/test.dart';

late RegexWorker _worker;

void main() {
  setUpAll(() {
    _worker = RegexWorker();
  });
  tearDownAll(() => _worker.close());
  final fixtures = jsonDecode(File('test/fixtures/worldinfo-timed-oracle.json').readAsStringSync()) as List<Object?>;
  for (final raw in fixtures) {
    final fixture = raw! as Map<String, Object?>;
    test('actual ST timed source: ${fixture['name']}', () async {
      final books = [for (final value in fixture['books']! as List<Object?>) _book(value! as Map<String, Object?>)];
      final metadata = fixture['metadata'] as Map<String, Object?>? ?? {};
      final state = metadata['timedWorldInfo'] as Map<String, Object?>? ?? {};
      final original = jsonEncode({'books': books.map((book) => book.raw).toList(), 'state': state});
      final random = fixture['random'] as List<Object?>? ?? [];
      var randomUsed = 0;
      final expansions = <String>[];
      final result = await WorldInfoEngine(worker: _worker).evaluate(
        WorldInfoInput(
          books: books,
          messages: [
            for (final value in fixture['messages']! as List<Object?>) _message(value! as Map<String, Object?>),
          ],
          maxContext: fixture['maxContext'] as int? ?? 10000,
          tokenCount: (text) => text.length, // Same explicit UTF-16 toy counter as source harness.
          random: () {
            expect(randomUsed, lessThan(random.length));
            return (random[randomUsed++]! as num).toDouble();
          },
          expand: (text) {
            expansions.add(text);
            return text;
          },
          settings: WorldInfoSettings.fromJson(fixture['settings'] as Map<String, Object?>? ?? {}),
          timedWorldInfo: state,
          dryRun: fixture['dryRun'] == true,
        ),
      );
      final expected = Map<String, Object?>.of(fixture['expected']! as Map<String, Object?>);
      final hashes = expected.remove('hashes')! as List<Object?>;
      final expectedHashes = <String, Object?>{};
      for (final value in hashes) {
        final item = value! as Map<String, Object?>;
        expectedHashes['${item['world']}.${item['uid']}'] = item['hash'];
      }
      expect({
        for (final book in books)
          for (final entry in book.entries) '${book.stWorldName}.${entry.uid}': entry.stHash,
      }, expectedHashes);
      expect({
        'activated': [for (final hit in result.activated) '${hit.entry.book.stWorldName}.${hit.uid}'],
        'before': result.beforeText,
        'after': result.afterText,
        'examplesBefore': result.examplesBefore.map((hit) => hit.content).toList(),
        'examplesAfter': result.examplesAfter.map((hit) => hit.content).toList(),
        'authorNoteBefore': result.authorNoteBefore.map((hit) => hit.content).toList(),
        'authorNoteAfter': result.authorNoteAfter.map((hit) => hit.content).toList(),
        'depths': [
          for (final group in result.depths)
            {'depth': group.depth, 'role': group.role, 'entries': group.entries.map((hit) => hit.content).toList()},
        ],
        'outlets': {for (final item in result.outlets.entries) item.key: item.value.map((hit) => hit.content).toList()},
        'budget': result.budget,
        'overflowed': result.overflowed,
        'scanRounds': result.scanRounds,
        'randomUsed': randomUsed,
        'expandCalls': expansions,
        'timedWorldInfo': result.timedWorldInfo,
      }, expected);
      expect(jsonEncode({'books': books.map((book) => book.raw).toList(), 'state': state}), original);
    });
  }

  test('local book ID can differ from the explicitly retained ST world name', () {
    final json = <String, Object?>{
      'entries': {
        '0': {'uid': 0, 'content': 'x', 'constant': true, 'position': 0, 'sticky': 2},
      },
    };
    final source = WorldInfoBook.fromJson(id: '原名字', source: WorldInfoSource.global, json: json);
    final local = WorldInfoBook.fromJson(id: 'local-123', stWorldName: '原名字', source: WorldInfoSource.chat, json: json);
    expect(local.entries.single.stHash, source.entries.single.stHash);
    final renamed = WorldInfoBook.fromJson(id: 'local-123', source: WorldInfoSource.chat, json: json);
    expect(renamed.entries.single.stHash, isNot(source.entries.single.stHash));
  });

  final edgeOracle =
      jsonDecode(File('test/fixtures/worldinfo-timed-edge-oracle.json').readAsStringSync()) as Map<String, Object?>;
  for (final raw in edgeOracle['vectors']! as List<Object?>) {
    final fixture = raw! as Map<String, Object?>;
    test('actual ST timed edge source: ${fixture['name']}', () async {
      // Decode the original JSON text here: pre-decoding/reserializing in the
      // JavaScript harness would erase unsafe-integer UID conversion cases.
      final book = WorldInfoBook.fromJson(
        id: fixture['bookId']! as String,
        source: WorldInfoSource.values.byName(fixture['source']! as String),
        json: jsonDecode(fixture['bookJsonText']! as String) as Map<String, Object?>,
      );
      final metadata = fixture['metadata']! as Map<String, Object?>;
      final state = metadata['timedWorldInfo'] as Map<String, Object?>? ?? {};
      final before = jsonEncode({'book': book.raw, 'state': state});
      final draws = fixture['random']! as List<Object?>;
      var used = 0;
      final result = await WorldInfoEngine(worker: _worker).evaluate(
        WorldInfoInput(
          books: [book],
          messages: [for (final item in fixture['messages']! as List<Object?>) _message(item! as Map<String, Object?>)],
          maxContext: fixture['maxContext']! as int,
          tokenCount: (text) => text.length,
          timedWorldInfo: state,
          random: () {
            expect(used, lessThan(draws.length));
            return (draws[used++]! as num).toDouble();
          },
        ),
      );
      final expected = fixture['expected']! as Map<String, Object?>;
      final hashes = expected['hashes']! as List<Object?>;
      expect(book.entries.map((entry) => entry.stHash).toList(), [
        for (final item in hashes) (item! as Map<String, Object?>)['hash'],
      ]);
      expect(result.timedWorldInfo, expected['timedWorldInfo']);
      expect(result.activated.map((hit) => hit.entry.stKey).toList(), expected['activatedTimerKeys']);
      expect(result.activated.length, expected['activatedCount']);
      expect(result.beforeText, expected['before']);
      expect(result.afterText, expected['after']);
      expect(used, expected['randomUsed']);
      expect(jsonEncode({'book': book.raw, 'state': state}), before);
    });
  }
}

WorldInfoBook _book(Map<String, Object?> value) => WorldInfoBook.fromJson(
  id: value['id']! as String,
  source: WorldInfoSource.values.byName(value['source']! as String),
  json: value['json']! as Map<String, Object?>,
);

WorldInfoMessage _message(Map<String, Object?> value) =>
    WorldInfoMessage(value['text']! as String, speaker: value['speaker'] as String? ?? '');

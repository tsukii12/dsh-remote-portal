import 'dart:convert';
import 'dart:io';

import 'package:dsh_tavern/src/regex/regex_worker.dart';
import 'package:dsh_tavern/src/worldinfo/world_info.dart';
import 'package:test/test.dart';

late RegexWorker _worker;

void main() {
  late WorldInfoEngine engine;
  setUpAll(() {
    _worker = RegexWorker();
    engine = WorldInfoEngine(worker: _worker);
  });
  tearDownAll(() => _worker.close());
  final cases = jsonDecode(File('test/fixtures/worldinfo-oracle.json').readAsStringSync()) as List<Object?>;
  for (final item in cases) {
    final fixture = item as Map<String, Object?>;
    test('ST source oracle: ${fixture['name']}', () async {
      final books = [for (final value in fixture['books'] as List<Object?>) _book(value as Map<String, Object?>)];
      final original = jsonEncode(books.map((book) => book.raw).toList());
      final random = fixture['random'] as List<Object?>? ?? [];
      final macros = fixture['macros'] as Map<String, Object?>? ?? {};
      final expansions = <String>[];
      var randomUsed = 0;
      final result = await engine.evaluate(
        WorldInfoInput(
          books: books,
          messages: [for (final value in fixture['messages'] as List<Object?>) _message(value as Map<String, Object?>)],
          maxContext: fixture['maxContext'] as int? ?? 10000,
          tokenCount: (text) => text.length, // Explicit toy tokenizer, JS/Dart UTF-16 units.
          random: () {
            expect(randomUsed, lessThan(random.length), reason: 'An extra random draw changes ST selection semantics');
            return (random[randomUsed++] as num).toDouble();
          },
          expand: (text) {
            expansions.add(text);
            for (final item in macros.entries) {
              text = text.replaceAll(item.key, item.value as String);
            }
            return text;
          },
          settings: WorldInfoSettings.fromJson(fixture['settings'] as Map<String, Object?>? ?? {}),
          scanInjections: (fixture['scanInjections'] as List<Object?>? ?? []).cast<String>(),
          personaDescription: fixture['personaDescription'] as String? ?? '',
          characterDescription: fixture['characterDescription'] as String? ?? '',
          characterPersonality: fixture['characterPersonality'] as String? ?? '',
          characterDepthPrompt: fixture['characterDepthPrompt'] as String? ?? '',
          scenario: fixture['scenario'] as String? ?? '',
          creatorNotes: fixture['creatorNotes'] as String? ?? '',
          trigger: fixture['trigger'] as String? ?? 'normal',
          characterName: fixture['characterName'] as String? ?? 'current',
          characterTags: (fixture['characterTags'] as List<Object?>?)?.cast<String>(),
        ),
      );
      expect({..._result(result), 'randomUsed': randomUsed, 'expandCalls': expansions}, fixture['expected']);
      expect(
        jsonEncode(books.map((book) => book.raw).toList()),
        original,
        reason: 'Evaluation, including overlapping group removal, must not mutate any raw book',
      );
    });
  }

  test('V3 raw documents remain detached and retain unused fields', () async {
    final source = <String, Object?>{
      'name': '原书',
      'unknown': {
        'x': [null, '鲸鱼 🐳'],
      },
      'entries': [
        {
          'keys': ['beacon'],
          'content': '{{line}}',
          'enabled': true,
          'insertion_order': 10,
          'use_regex': true,
          'extensions': {
            'sticky': 5,
            'delay': 1,
            'future': {'raw': true},
          },
        },
      ],
    };
    final original = jsonEncode(source);
    final book = WorldInfoBook.fromJson(id: 'card', source: WorldInfoSource.character, json: source);
    final result = await engine.evaluate(_input([book], expand: (text) => text.replaceAll('{{line}}', '展开')));
    expect(result.afterText, '展开');
    expect(result.activated.single.originalContent, '{{line}}');
    expect(result.activated.single.uid, '0');
    expect(result.activated.single.reason, 'keywords');
    expect(result.activated.single.primaryKey, 'beacon');
    expect(result.activated.single.phase, WorldInfoScanPhase.initial);
    expect(jsonEncode(book.raw), original);
    expect(jsonEncode(source), original);
    source['name'] = '外部修改';
    expect(book.name, '原书');
  });

  test('ST object-key order is independent from the entries uid order', () async {
    final book = WorldInfoBook.fromJson(
      id: 'order',
      source: WorldInfoSource.character,
      json: {
        'entries': {'z': _entry(1), 'a': _entry(0)},
      },
    );
    final result = await engine.evaluate(_input([book]));
    expect(result.activated.map((hit) => hit.uid), ['1', '0']);
    expect(result.before.map((hit) => hit.uid), ['0', '1']);
  });

  test('numeric JS object keys precede other keys and remain stable at equal order', () async {
    final book = WorldInfoBook.fromJson(
      id: 'order',
      source: WorldInfoSource.character,
      json: {
        'entries': {'10': _entry(10), '2': _entry(2), '01': _entry(1), 'a': _entry(99)},
      },
    );
    expect((await engine.evaluate(_input([book]))).activated.map((hit) => hit.uid), ['2', '10', '1', '99']);
  });

  test('V3 duplicate ids follow ST conversion while preserving the original array', () async {
    final book = WorldInfoBook.fromJson(
      id: 'duplicate',
      source: WorldInfoSource.character,
      json: {
        'entries': [
          {
            'id': 2,
            'keys': ['beacon'],
            'content': 'first',
            'enabled': true,
          },
          {
            'id': 2,
            'keys': ['beacon'],
            'content': 'last',
            'enabled': true,
          },
        ],
      },
    );
    expect((await engine.evaluate(_input([book]))).afterText, 'last');
    expect(book.raw['entries'] as List<Object?>, hasLength(2));
  });

  test('memory participates in the character strategy with its own trace source', () async {
    final memory = WorldInfoBook.fromJson(
      id: 'memory',
      source: WorldInfoSource.memory,
      json: {
        'entries': {'0': _entry(0)..['order'] = 200},
      },
    );
    final character = WorldInfoBook.fromJson(
      id: 'character',
      source: WorldInfoSource.character,
      json: {
        'entries': {'0': _entry(0)},
      },
    );
    final result = await engine.evaluate(_input([character, memory]));
    expect(result.activated.map((hit) => hit.bookId), ['memory', 'character']);
    expect(result.activated.first.source, WorldInfoSource.memory);
  });

  test('duplicate book bindings use global source before scanning priorities', () async {
    final json = <String, Object?>{
      'entries': {'0': _entry(0)},
    };
    final books = [
      for (final source in [WorldInfoSource.character, WorldInfoSource.chat, WorldInfoSource.global])
        WorldInfoBook.fromJson(id: 'same', source: source, json: json),
    ];
    final result = await engine.evaluate(_input(books));
    expect(result.activated.single.source, WorldInfoSource.global);
  });

  test('same input has the same result and empty books perform no random work', () async {
    final book = WorldInfoBook.fromJson(
      id: 'one',
      source: WorldInfoSource.character,
      json: {
        'entries': {'0': _entry(0)},
      },
    );
    final input = _input([book]);
    expect(_result(await engine.evaluate(input)), _result(await engine.evaluate(input)));
    final empty = await engine.evaluate(_input([]));
    expect(empty.activated, isEmpty);
    expect(empty.scanRounds, 0);
  });

  test('invalid books and dependency return values fail visibly', () async {
    expect(() => WorldInfoBook.fromJson(id: 'bad', source: WorldInfoSource.global, json: {}), throwsFormatException);
    expect(
      () => WorldInfoBook.fromJson(
        id: 'bad',
        source: WorldInfoSource.global,
        json: {
          'entries': [null],
        },
      ),
      throwsFormatException,
    );
    final book = WorldInfoBook.fromJson(
      id: 'roll',
      source: WorldInfoSource.character,
      json: {
        'entries': {'0': _entry(0)..['probability'] = 50},
      },
    );
    await expectLater(
      engine.evaluate(
        WorldInfoInput(
          books: [book],
          messages: const [WorldInfoMessage('beacon')],
          maxContext: 10000,
          tokenCount: (text) => text.length,
          random: () => 1,
        ),
      ),
      throwsArgumentError,
    );
    await expectLater(
      engine.evaluate(
        WorldInfoInput(
          books: [book],
          messages: const [WorldInfoMessage('beacon')],
          maxContext: 10000,
          tokenCount: (text) => -1,
          random: () => 0,
        ),
      ),
      throwsArgumentError,
    );
  });
}

WorldInfoBook _book(Map<String, Object?> input) => WorldInfoBook.fromJson(
  id: input['id'] as String,
  source: WorldInfoSource.values.byName(input['source'] as String),
  json: input['json'] as Map<String, Object?>,
);

WorldInfoMessage _message(Map<String, Object?> input) =>
    WorldInfoMessage(input['text'] as String, speaker: input['speaker'] as String? ?? '');

WorldInfoInput _input(List<WorldInfoBook> books, {String Function(String)? expand}) => WorldInfoInput(
  books: books,
  messages: const [WorldInfoMessage('beacon')],
  maxContext: 10000,
  tokenCount: (text) => text.length,
  random: () => throw StateError('Unexpected random draw'),
  expand: expand ?? (text) => text,
);

Map<String, Object?> _entry(int uid) => {
  'uid': uid,
  'key': ['beacon'],
  'content': 'entry $uid',
  'position': 0,
  'order': 100,
  'selective': true,
  'probability': 100,
  'useProbability': true,
};

Map<String, Object?> _result(WorldInfoResult result) => {
  'activated': [for (final hit in result.activated) '${hit.bookId}.${hit.uid}'],
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
};

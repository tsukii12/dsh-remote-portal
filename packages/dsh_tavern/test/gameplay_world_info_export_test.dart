import 'dart:convert';

import 'package:dsh_tavern/src/regex/regex_worker.dart';
import 'package:dsh_tavern/src/worldinfo/world_info.dart';
import 'package:test/test.dart';

typedef Json = Map<String, Object?>;

void main() {
  test('WI export keeps real loader gates and rejects an unrepresentable cross-form entry', () async {
    final worker = RegexWorker();
    addTearDown(worker.close);
    final nativeRow = <String, Object?>{
      'uid': 7, 'key': ['Signal'], 'keysecondary': ['tag'],
      'content': '@@additional_keys aux\npayload',
      'position': 4, 'depth': 2, 'role': 2,
      'selective': true, 'selectiveLogic': 0,
      'group': 'choice', 'useGroupScoring': true,
      'use_regex': true, 'case_sensitive': false, 'caseSensitive': true,
      'matchScenario': true, 'probability': 0,
      'sticky': ['2'], 'cooldown': '3', 'delay': '1',
      // These V3-shaped fields are inert in a native map entry.
      'enabled': false, 'keys': ['shadow'], 'insertion_order': -1,
      'vendor': {'unknown': null},
      'extensions': {'vendor_flag': false, 'useProbability': true},
    };
    final native = _book(false, [nativeRow]);
    final original = jsonEncode(native.raw);
    final exported = exportGameplayWorldInfoEntry(native.entries.single, id: 'exported', characterBook: true);
    final character = _book(true, [exported]);
    expect(exported['enabled'], isTrue);
    expect(exported['keys'], ['Signal']);
    expect(_map(exported['extensions'])['useProbability'], isFalse);
    expect(exported['vendor'], {'unknown': null});
    expect(_map(exported['extensions'])['vendor_flag'], isFalse);
    expect(character.entries.single.timerDeclarations, {
      'sticky': ['2'],
      'cooldown': '3',
    });
    expect(character.entries.single.delayDeclaration, {'delay': '1'});
    expect(character.entries.single.caseSensitive, isFalse);
    expect(character.entries.single.useRegex, isTrue);
    expect(worldInfoRegexInputs(character).first.dialect.name, 'v3Keyword');

    var nativeDraws = 0;
    var characterDraws = 0;
    final before = await _run(
      worker,
      native,
      random: () {
        nativeDraws++;
        return 0.5;
      },
    );
    final after = await _run(
      worker,
      character,
      random: () {
        characterDraws++;
        return 0.5;
      },
    );
    expect(before.activated.single.content, 'payload');
    expect(_outcome(after), _outcome(before));
    expect(after.depths.single.depth, 2);
    expect(after.depths.single.role, 2);
    expect(nativeDraws, 0);
    expect(characterDraws, 0);
    expect(_timerWindow(after, 'sticky'), [2, 4]);
    expect(_timerWindow(after, 'cooldown'), [2, 5]);
    expect(jsonEncode(native.raw), original);
    expect(exportGameplayWorldInfoEntry(native.entries.single, id: 'same-form', characterBook: false), {
      ...native.entries.single.raw,
      'uid': 'same-form',
    });

    final v3 = _book(true, [
      {
        'id': 'missing-enabled',
        'constant': true,
        'content': 'must stay disabled',
        'disable': false,
        'vendor': {'missing': true},
      },
      {
        'id': 'visible',
        'enabled': true,
        'constant': true,
        'content': '@@role assistant\nvisible',
        'use_regex': true,
        'case_sensitive': false,
        'keys': ['not a key'],
        'key': ['ignored native shadow'],
        'characterFilter': {
          'names': ['Never'],
        },
        'extensions': {'position': 0, 'case_sensitive': true, 'vendor_flag': null},
        'vendor': {'kept': false},
      },
    ]);
    final v3Original = jsonEncode(v3.raw);
    final stRows = [
      for (final entry in v3.entries)
        exportGameplayWorldInfoEntry(entry, id: 'copy-${entry.uid}', characterBook: false),
    ];
    final st = _book(false, stRows);
    expect(st.entries.first.disabled, isTrue);
    expect(stRows.last.containsKey('characterFilter'), isFalse);
    expect(stRows.last['vendor'], {'kept': false});
    expect(_map(stRows.last['extensions'])['vendor_flag'], isNull);
    final v3Result = await _run(worker, v3);
    final stResult = await _run(worker, st);
    expect(stResult.beforeText, 'visible');
    expect(stResult.activated.single.role, 2);
    expect(_outcome(stResult), _outcome(v3Result));
    expect(jsonEncode(v3.raw), v3Original);
    expect(exportGameplayWorldInfoEntry(v3.entries.first, id: 'same-form', characterBook: true), {
      ...v3.entries.first.raw,
      'id': 'same-form',
    });

    // The native scorer distinguishes nullish logic from numeric zero even
    // though activation's selectiveLogic getter returns zero for both.
    final nullish = _book(false, [
      {...nativeRow, 'selectiveLogic': null},
    ]);
    expect(nullish.entries.single.selectiveLogic, 0);
    expect(
      () => exportGameplayWorldInfoEntry(nullish.entries.single, id: 'cannot-copy', characterBook: true),
      throwsA(isA<FormatException>().having((error) => error.message, 'gate', contains('secondaryScoringHasLogic'))),
    );
    final filtered = _book(false, [
      {
        ...nativeRow,
        'characterFilter': {
          'names': ['Chosen'],
          'isExclude': false,
        },
      },
    ]);
    expect((await _run(worker, filtered)).activated, isEmpty);
    expect((await _run(worker, filtered, characterName: 'Chosen')).activated, hasLength(1));
    expect(
      () => exportGameplayWorldInfoEntry(filtered.entries.single, id: 'cannot-copy', characterBook: true),
      throwsA(isA<FormatException>().having((error) => error.message, 'gate', contains('characterFilter'))),
    );
  });
}

WorldInfoBook _book(bool characterBook, List<Json> entries) => WorldInfoBook.fromJson(
  id: 'source',
  source: WorldInfoSource.character,
  stWorldName: 'source',
  json: {
    'entries': characterBook
        ? entries
        : {for (var index = 0; index < entries.length; index++) '$index': entries[index]},
  },
);

Future<WorldInfoResult> _run(
  RegexWorker worker,
  WorldInfoBook book, {
  double Function()? random,
  String characterName = 'Current',
}) => WorldInfoEngine(worker: worker).evaluate(
  WorldInfoInput(
    books: [book],
    messages: const [WorldInfoMessage('not a key')],
    messageCount: 2,
    maxContext: 10000,
    tokenCount: (text) => text.length,
    random: random ?? () => 0.5,
    settings: const WorldInfoSettings(budgetPercent: 100, useGroupScoring: true),
    scenario: 'signal tag aux',
    characterName: characterName,
  ),
);

List<Object?> _outcome(WorldInfoResult result) => [
  for (final hit in result.activated)
    [hit.content, hit.reason, hit.position, hit.depth, hit.role, hit.primaryKey, hit.secondaryMatches],
];

List<Object?> _timerWindow(WorldInfoResult result, String type) {
  final row = _map(_map(result.timedWorldInfo[type]).values.single);
  return [row['start'], row['end']];
}

Json _map(Object? value) => value! as Json;

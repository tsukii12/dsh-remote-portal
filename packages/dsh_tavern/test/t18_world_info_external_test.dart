import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:dsh_tavern/src/regex/regex_worker.dart';
import 'package:dsh_tavern/src/worldinfo/world_info.dart';
import 'package:test/test.dart';

late RegexWorker _worker;

void main() {
  setUpAll(() {
    _worker = RegexWorker();
  });
  tearDownAll(() => _worker.close());

  test('external references use local book identity and leave the raw entry intact', () async {
    final first = _native(
      [
        {'uid': 'a:b', 'content': 'selected'},
      ],
      id: 'local',
      name: 'other',
      stWorldName: 'native-source',
    );
    final other = _native(
      [
        {'uid': 'a:b', 'content': 'not selected'},
      ],
      id: 'other',
      name: 'local',
    );
    final before = jsonEncode([first.raw, other.raw]);
    final result = await _evaluate([first, other], external: {('local', 'a:b')});
    expect(result.activated.map((hit) => hit.entry.identity), [('local', 'a:b')]);
    expect(result.activated.single.reason, 'external');
    expect(result.activated.single.primaryKey, isNull);
    expect(result.externalActivations.single.toJson(), {
      'bookId': 'local',
      'uid': 'a:b',
      'resolved': true,
      'admitted': true,
      'retained': true,
      'reason': 'external',
      'phase': 'initial',
      'round': 1,
    });
    expect(jsonEncode([first.raw, other.raw]), before);
    expect(() => result.externalActivations.clear(), throwsUnsupportedError);
  });

  test('the shared execution view uses source precedence and preserves native ambiguity', () async {
    final global = _native([
      {'uid': 9, 'content': 'global'},
    ], id: 'same');
    final chat = _native(
      [
        {'uid': 9, 'content': 'chat'},
      ],
      id: 'same',
      source: WorldInfoSource.chat,
    );
    final duplicate = _native([
      {'uid': 7},
      {'uid': 7},
    ], id: 'duplicates');
    final v3 = _v3([
      {'id': 3, 'content': 'old'},
      {'id': 3, 'content': 'last'},
    ]);
    final view = worldInfoExecutionEntries([chat, global, duplicate, v3]);
    expect(view.where((entry) => entry.book.id == 'same').single.content, 'global');
    expect(view.where((entry) => entry.book.id == 'duplicates'), hasLength(2));
    expect(view.where((entry) => entry.book.id == 'v3').single.content, 'last');
    expect(() => view.clear(), throwsUnsupportedError);
    final result = await _evaluate([chat, global, duplicate, v3], external: {('same', '9'), ('v3', '3')});
    expect(
      {for (final hit in result.activated) hit.entry.identity: hit.content},
      {('same', '9'): 'global', ('v3', '3'): 'last'},
    );
    expect(result.externalActivations.every((row) => row.resolved && row.admitted), isTrue);
  });

  test('ambiguous native uid gets no external privilege while ordinary matching survives', () async {
    final book = _native([
      {
        'uid': 7,
        'key': ['key'],
        'content': 'first',
      },
      {
        'uid': 7,
        'key': ['key'],
        'content': 'second',
      },
    ]);
    final absent = await _evaluate([book], text: 'absent', external: {('book', '7')});
    expect(absent.activated, isEmpty);
    expect(absent.externalActivations.single.toJson(), {
      'bookId': 'book',
      'uid': '7',
      'resolved': false,
      'admitted': false,
      'retained': false,
      'code': 'ambiguous-reference',
      'stage': 'resolution',
    });
    final ordinary = await _evaluate([book]);
    final requested = await _evaluate([book], external: {('book', '7')});
    expect(requested.activated.map((hit) => hit.content), ordinary.activated.map((hit) => hit.content));
    expect(requested.activated.single.reason, 'keywords');
    expect(requested.externalActivations.single.code, 'ambiguous-reference');
    expect(requested.externalActivations.single.admitted, isFalse);
  });

  test('V3 external checks all regex syntax but accepts nonmatches and empty key lists', () async {
    final book = _v3([
      {
        'keys': ['not-present'],
        'use_regex': true,
        'content': 'valid',
      },
      {'keys': <String>[], 'use_regex': true, 'content': 'empty'},
      {
        'keys': ['key', '['],
        'use_regex': true,
        'content': 'invalid',
      },
    ]);
    final result = await _evaluate([book], external: {('v3', '0'), ('v3', '1'), ('v3', '2')});
    expect(result.activated.map((hit) => hit.content), ['valid', 'empty']);
    expect(result.regexDiagnostics.single.code, 'incompatible-pattern');
    expect(result.regexDiagnostics.single.keyPath, 'keys[1]');
    expect(_row(result, '2', bookId: 'v3').code, 'incompatible-pattern');
    expect(_row(result, '2', bookId: 'v3').stage, 'regex');
  });

  test('disabled trigger and character filters remain external gates', () async {
    final book = _native([
      {'disable': true},
      {
        'triggers': ['continue'],
      },
      {
        'characterFilter': {
          'names': ['other'],
          'isExclude': false,
        },
      },
      {
        'characterFilter': {
          'tags': ['wanted'],
          'isExclude': false,
        },
      },
      {'content': 'allowed'},
    ]);
    final result = await _evaluate([book], external: _refs(book), characterName: 'current', characterTags: const []);
    expect(result.activated.map((hit) => hit.uid), ['4']);
    expect(result.externalActivations.map((row) => row.code), [
      'disabled',
      'trigger',
      'character-filter',
      'character-filter',
      null,
    ]);
    final unknownTags = await _evaluate([book], external: {('book', '3')}, characterName: 'current');
    expect(unknownTags.activated.single.uid, '3');
  });

  test('delay and cooldown block external while native sticky exemptions remain', () async {
    final book = _native([
      {'delay': 3},
      {'cooldown': 3},
      {'sticky': 3, 'cooldown': 3, 'useProbability': true, 'probability': 0},
    ]);
    final timed = <String, Object?>{
      'sticky': {_timerKey(book, 2): _timer(book, 2)},
      'cooldown': {_timerKey(book, 1): _timer(book, 1), _timerKey(book, 2): _timer(book, 2)},
    };
    final before = jsonEncode(timed);
    final result = await _evaluate(
      [book],
      external: _refs(book),
      timed: timed,
      random: () => throw StateError('sticky must not draw probability'),
    );
    expect(result.activated.single.uid, '2');
    expect(result.activated.single.reason, 'external');
    expect(result.externalActivations.map((row) => row.code), ['delay', 'cooldown', null]);
    expect(jsonEncode(timed), before);
  });

  test('ordinary header conditions and native fallback still constrain requests', () async {
    final book = _native([
      {'content': '@@activate_only_after 3\nlate'},
      {'content': '@@activate_only_every 2\nevery'},
      {'content': '@@is_greeting 2\ngreeting'},
      {'content': '@@is_user_icon another\nicon'},
      {'content': '@@ignore_on_max_context\ncapacity'},
      {'content': '@@additional_keys absent\nadditional'},
      {'content': '@@exclude_keys key\nexcluded'},
      {'content': '@@future\n@@@additional_keys key\nfallback'},
    ]);
    final result = await _evaluate(
      [book],
      external: _refs(book),
      assistantMessageCount: 1,
      greetingIndex: 0,
      userIconName: 'current',
      contextAtCapacity: true,
    );
    expect(result.activated.map((hit) => hit.uid), ['7']);
    expect(result.externalActivations.take(7).every((row) => row.code == 'decorator-condition'), isTrue);
    expect(result.activated.single.content, 'fallback');
  });

  test('activate keep and dont retain their established force priority', () async {
    final book = _v3([
      {
        'use_regex': true,
        'keys': ['['],
        'content': '@@activate\n@@dont_activate\n@@additional_keys absent\nforced',
      },
      {
        'use_regex': true,
        'keys': ['['],
        'content': '@@keep_activate_after_match\nkept',
      },
      {'content': '@@dont_activate\nblocked'},
      {'content': '@@dont_activate_after_match\n@@keep_activate_after_match\nblocked after'},
    ]);
    final history = <String, Object?>{
      '${book.entries[1].stHash}': {'matches': 2, 'lastMessageCount': 0},
      '${book.entries[3].stHash}': {'matches': 2, 'lastMessageCount': 0},
    };
    final result = await _evaluate([book], external: _refs(book), decoratorState: history);
    expect(result.activated.map((hit) => hit.reason), ['decorator-activate', 'decorator-keep']);
    expect(result.regexDiagnostics, isEmpty);
    expect(result.externalActivations.map((row) => row.code), [null, null, 'decorator-block', 'decorator-block']);
  });

  test('an incompatible exclusion cannot become a successful external match', () async {
    final book = _native([
      {'content': '@@exclude_keys /[/\nblocked'},
      {'content': 'survivor'},
    ]);
    final result = await _evaluate([book], external: _refs(book));
    expect(result.activated.single.uid, '1');
    expect(_row(result, '0').code, 'incompatible-pattern');
    expect(result.regexDiagnostics.single.keyPath, 'content.@@exclude_keys[0]');
  });

  test('a real worker input limit in a negative header remains indeterminate', () async {
    final worker = RegexWorker(limits: const RegexLimits(maxInputBytes: 8));
    addTearDown(worker.close);
    final book = _native([
      {'content': '@@exclude_keys /key/\nblocked'},
    ]);
    final result = await _evaluate([book], worker: worker, external: _refs(book), text: 'key and a long input');
    expect(result.activated, isEmpty);
    expect(result.regexDiagnostics.single.code, 'input-limit');
    expect(result.externalActivations.single.code, 'input-limit');
  });

  test('external group scoring still rejects invalid programs instead of assigning zero', () async {
    final book = _native([
      {
        'key': ['/[/'],
        'group': 'g',
        'content': 'invalid',
      },
      {
        'key': ['/key/'],
        'group': 'g',
        'content': 'valid',
      },
    ]);
    final result = await _evaluate(
      [book],
      external: _refs(book),
      settings: const WorldInfoSettings(includeNames: false, useGroupScoring: true),
    );
    expect(result.activated.single.uid, '1');
    expect(_row(result, '0').code, 'incompatible-pattern');
    expect(_row(result, '1').admitted, isTrue);
  });

  test('external candidates still lose group score override and weighted selection', () async {
    final scored = _native([
      {
        'key': ['absent'],
        'group': 'score',
      },
      {
        'key': ['key'],
        'group': 'score',
      },
    ]);
    final first = await _evaluate(
      [scored],
      external: _refs(scored),
      settings: const WorldInfoSettings(includeNames: false, useGroupScoring: true),
    );
    expect(first.activated.single.uid, '1');
    expect(_row(first, '0').code, 'group-score');
    final overridden = _native([
      {'group': 'override'},
      {'group': 'override', 'groupOverride': true},
    ]);
    final second = await _evaluate(
      [overridden],
      external: _refs(overridden),
      random: () => throw StateError('override must not draw'),
    );
    expect(second.activated.single.uid, '1');
    expect(_row(second, '0').code, 'group-override');
    var draws = 0;
    final weighted = _native([
      {'group': 'weight'},
      {'group': 'weight'},
    ]);
    final third = await _evaluate(
      [weighted],
      external: _refs(weighted),
      random: () {
        draws++;
        return 0.75;
      },
    );
    expect(third.activated.single.uid, '1');
    expect(_row(third, '0').code, 'group-weight');
    expect(draws, 1);
  });

  test('group-specific cooldown still removes a sticky external candidate', () async {
    final book = _native([
      {'group': 'g', 'sticky': 3, 'cooldown': 3},
      {'group': 'g'},
    ]);
    final result = await _evaluate(
      [book],
      external: _refs(book),
      timed: {
        'sticky': {_timerKey(book, 0): _timer(book, 0)},
        'cooldown': {_timerKey(book, 0): _timer(book, 0)},
      },
    );
    expect(result.activated, isEmpty);
    expect(_row(result, '0').code, 'group-cooldown');
    expect(_row(result, '1').code, 'group-sticky');
  });

  test('overlapping groups report the actual splice-minus-one victim', () async {
    final book = _native([
      {'group': 'a,b'},
      {'group': 'a', 'groupOverride': true},
      {'group': 'b', 'groupOverride': true},
      {'content': 'unrelated tail'},
    ]);
    final result = await _evaluate([book], external: _refs(book));
    expect(result.activated.map((hit) => hit.uid), ['1', '2']);
    expect(_row(result, '0').code, 'group-override');
    expect(_row(result, '3').code, 'group-override');
    expect(_row(result, '3').stage, 'group');
  });

  test('probability failure is not retried when another external item reaches recursion', () async {
    final book = _native([
      {'probability': 0, 'useProbability': true},
      {'constant': true, 'content': 'seed'},
      {'delayUntilRecursion': 1, 'content': 'later'},
      {'delayUntilRecursion': 1, 'excludeRecursion': true},
    ]);
    var draws = 0;
    final result = await _evaluate(
      [book],
      external: {('book', '0'), ('book', '2'), ('book', '3')},
      settings: const WorldInfoSettings(includeNames: false, recursive: true),
      random: () {
        draws++;
        return 0.5;
      },
    );
    expect(result.activated.map((hit) => hit.uid), ['1', '2']);
    expect(_row(result, '0').code, 'probability');
    expect(_row(result, '0').round, 1);
    expect(_row(result, '2').phase, WorldInfoScanPhase.recursion);
    expect(_row(result, '2').round, 2);
    expect(_row(result, '2').code, isNull);
    expect(_row(result, '3').code, 'exclude-recursion');
    expect(draws, 1);
  });

  test('world budget overflow explains the skipped tail without expanding it', () async {
    final book = _native([
      {'content': '12345'},
      {'content': 'tail one'},
      {'content': 'tail two'},
    ]);
    final calls = <String>[];
    final result = await _evaluate(
      [book],
      external: _refs(book),
      settings: const WorldInfoSettings(includeNames: false, budgetCap: 5),
      expand: (text) {
        calls.add(text);
        return text;
      },
    );
    expect(result.activated, isEmpty);
    expect(result.overflowed, isTrue);
    expect(calls, ['12345']);
    expect(result.externalActivations.every((row) => row.code == 'world-budget'), isTrue);
  });

  test('ignoreBudget still admits its external entry after ordinary overflow', () async {
    final book = _native([
      {'content': '12345'},
      {'content': 'not expanded'},
      {'content': 'free', 'ignoreBudget': true},
    ]);
    final calls = <String>[];
    final result = await _evaluate(
      [book],
      external: _refs(book),
      settings: const WorldInfoSettings(includeNames: false, budgetCap: 5),
      expand: (text) {
        calls.add(text);
        return text;
      },
    );
    expect(result.activated.single.uid, '2');
    expect(calls, ['12345', 'free']);
    expect(result.externalActivations.map((row) => row.code), ['world-budget', 'world-budget', null]);
  });

  test('external content participates in normal recursion and preventRecursion is respected', () async {
    final recursive = _native([
      {'content': 'seed'},
      {
        'key': ['seed'],
        'content': 'child',
      },
    ]);
    final result = await _evaluate(
      [recursive],
      external: {('book', '0')},
      settings: const WorldInfoSettings(includeNames: false, recursive: true),
    );
    expect(result.activated.map((hit) => hit.uid), ['0', '1']);
    expect(result.activated.last.reason, 'keywords');
    expect(result.activated.last.phase, WorldInfoScanPhase.recursion);
    final stopped = _native([
      {'content': 'seed', 'preventRecursion': true},
      {
        'key': ['seed'],
        'content': 'child',
      },
    ]);
    final noRecursion = await _evaluate(
      [stopped],
      external: {('book', '0')},
      settings: const WorldInfoSettings(includeNames: false, recursive: true),
    );
    expect(noRecursion.activated.map((hit) => hit.uid), ['0']);
  });

  test('V3 external compilation and group matching share one logical rule slot', () async {
    final worker = RegexWorker(limits: const RegexLimits(maxRules: 1));
    addTearDown(worker.close);
    final book = _v3([
      {
        'use_regex': true,
        'keys': ['absent'],
        'extensions': {'group': 'only'},
      },
    ]);
    final result = await _evaluate(
      [book],
      worker: worker,
      external: _refs(book),
      settings: const WorldInfoSettings(includeNames: false, useGroupScoring: true),
    );
    expect(result.activated.single.reason, 'external');
    expect(result.regexDiagnostics, isEmpty);
    final tooMany = _v3([
      {
        'use_regex': true,
        'keys': ['same', 'same'],
      },
    ]);
    final limited = await _evaluate([tooMany], worker: worker, external: _refs(tooMany));
    expect(limited.activated, isEmpty);
    expect(limited.regexDiagnostics.single.keyPath, 'keys[1]');
    expect(limited.externalActivations.single.code, 'rule-limit');
  });

  test('the real default worker enforces the two-hundred-rule limit on external V3 keys', () async {
    final book = _v3([
      {'use_regex': true, 'keys': List<String>.filled(201, 'absent')},
    ]);
    final result = await _evaluate([book], external: _refs(book));
    expect(result.activated, isEmpty);
    expect(result.regexDiagnostics.single.keyPath, 'keys[200]');
    expect(result.externalActivations.single.code, 'rule-limit');
  });

  test('external native keys stay unused and final filtering does not replay side effects', () async {
    final book = _native([
      {
        'key': ['{{unused-primary}}'],
        'keysecondary': ['{{unused-secondary}}'],
        'selective': true,
        'content': '{{body}}',
        'sticky': 3,
        'cooldown': 2,
      },
    ]);
    final calls = <String>[];
    var transformed = 0;
    final before = jsonEncode(book.raw);
    final result = await _evaluate(
      [book],
      external: _refs(book),
      expand: (text) {
        calls.add(text);
        if (text != '{{body}}') throw StateError('unused keys must not expand');
        return 'expanded';
      },
      postProcessContent: (entry, content, depth) {
        transformed++;
        return '$content!';
      },
    );
    expect(result.activated.single.content, 'expanded!');
    expect(result.timedWorldInfo['sticky'], isNotEmpty);
    final filtered = result.withoutEntries({('book', '0')});
    expect(filtered.activated, isEmpty);
    expect(filtered.timedWorldInfo['sticky'], isEmpty);
    expect(filtered.timedWorldInfo['cooldown'], isEmpty);
    expect(filtered.decoratorState, isEmpty);
    expect(filtered.externalActivations.single.admitted, isTrue);
    expect(filtered.externalActivations.single.retained, isFalse);
    expect(filtered.externalActivations.single.code, 'final-filter');
    expect(result.externalActivations.single.retained, isTrue);
    expect(calls, ['{{body}}']);
    expect(transformed, 1);
    expect(jsonEncode(book.raw), before);
  });

  test('V3 external expands every primary once before validating its first failure', () async {
    final book = _v3([
      {
        'use_regex': true,
        'keys': ['{{first}}', '{{bad}}', '{{last}}'],
        'content': 'body',
      },
    ]);
    final calls = <String>[];
    final result = await _evaluate(
      [book],
      external: _refs(book),
      expand: (text) {
        calls.add(text);
        return const {'{{first}}': 'absent', '{{bad}}': '[', '{{last}}': 'last'}[text] ?? text;
      },
    );
    expect(result.activated, isEmpty);
    expect(calls, ['{{first}}', '{{bad}}', '{{last}}']);
    expect(result.externalActivations.single.code, 'incompatible-pattern');
  });

  test('external references are snapshotted before a real worker startup await', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    final worker = _gatedWorker(entered, release);
    addTearDown(() async {
      if (!release.isCompleted) release.complete();
      await worker.close();
    });
    final book = _v3([
      {
        'use_regex': true,
        'keys': ['absent'],
        'content': 'first',
      },
      {
        'use_regex': true,
        'keys': ['also-absent'],
        'content': 'second',
      },
    ]);
    final refs = <WorldInfoEntryRef>{('v3', '0')};
    final running = _evaluate([book], worker: worker, external: refs);
    await entered.future;
    refs
      ..clear()
      ..add(('v3', '1'));
    release.complete();
    final result = await running;
    expect(result.activated.single.content, 'first');
    expect(result.externalActivations.single.identity, ('v3', '0'));
    final next = await _evaluate([book]);
    expect(next.activated, isEmpty);
    expect(next.externalActivations, isEmpty);
  });

  test('cancellation across a real worker await prevents external content and timers', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    final worker = _gatedWorker(entered, release);
    addTearDown(() async {
      if (!release.isCompleted) release.complete();
      await worker.close();
    });
    final book = _v3([
      {
        'use_regex': true,
        'keys': ['absent'],
        'content': 'body',
        'extensions': {'sticky': 3},
      },
    ]);
    final original = jsonEncode(book.raw);
    final failure = StateError('cancelled by owner');
    var cancelled = false;
    final calls = <String>[];
    var tokens = 0;
    final running = _evaluate(
      [book],
      worker: worker,
      external: _refs(book),
      checkCancelled: () {
        if (cancelled) throw failure;
      },
      expand: (text) {
        calls.add(text);
        return text;
      },
      tokenCount: (text) {
        tokens++;
        return text.length;
      },
    );
    final checked = expectLater(running, throwsA(same(failure)));
    await entered.future;
    cancelled = true;
    release.complete();
    await checked;
    expect(calls, ['absent']);
    expect(tokens, 0);
    expect(jsonEncode(book.raw), original);
  });

  test('external result rows and activation privileges are bounded to sixty-four requests', () async {
    final book = _native([
      for (var i = 0; i < 65; i++) {'uid': i, 'content': 'row-$i'},
    ]);
    final result = await _evaluate([book], external: _refs(book));
    expect(result.externalActivations, hasLength(worldInfoExternalActivationLimit));
    expect(result.externalActivationsOmitted, 1);
    expect(result.activated.map((hit) => hit.uid), [for (var i = 0; i < 64; i++) '$i']);
    final unknown = await _evaluate([], external: {for (var i = 0; i < 1000; i++) ('missing', '$i')});
    expect(unknown.externalActivations, hasLength(64));
    expect(unknown.externalActivationsOmitted, 936);
    expect(unknown.externalActivations.every((row) => !row.resolved && row.code == 'unresolved-reference'), isTrue);
  });

  test('omitted external input preserves ordinary reasons and has no extra result rows', () async {
    final book = _native([
      {
        'key': ['key'],
        'content': 'matched',
      },
      {'constant': true, 'content': 'constant'},
    ]);
    final result = await _evaluate([book]);
    expect(result.activated.map((hit) => hit.reason), ['keywords', 'constant']);
    expect(result.activated.map((hit) => hit.content), ['matched', 'constant']);
    expect(result.externalActivations, isEmpty);
    expect(result.externalActivationsOmitted, 0);
    expect(result.regexDiagnostics, isEmpty);
    expect(result.withoutEntries({('book', '1')}).externalActivations, isEmpty);
  });

  test('owner macro failures propagate instead of becoming external exclusions', () async {
    final book = _native([
      {'content': 'body'},
    ]);
    final failure = StateError('owner expansion');
    await expectLater(
      _evaluate([book], external: _refs(book), expand: (text) => throw failure),
      throwsA(same(failure)),
    );
  });
}

WorldInfoBook _native(
  List<Map<String, Object?>> entries, {
  String id = 'book',
  String? name,
  String? stWorldName,
  WorldInfoSource source = WorldInfoSource.global,
}) => WorldInfoBook.fromJson(
  id: id,
  source: source,
  stWorldName: stWorldName,
  json: {
    'name': ?name,
    'entries': {
      for (var index = 0; index < entries.length; index++)
        '$index': <String, Object?>{
          'uid': index,
          'key': <String>['absent'],
          'keysecondary': <String>[],
          'content': 'body-$index',
          'position': 0,
          'order': 100 - index,
          'probability': 100,
          'useProbability': true,
          ...entries[index],
        },
    },
  },
);

WorldInfoBook _v3(List<Map<String, Object?>> entries) => WorldInfoBook.fromJson(
  id: 'v3',
  source: WorldInfoSource.character,
  json: {
    'entries': [
      for (var index = 0; index < entries.length; index++)
        <String, Object?>{
          'id': index,
          'keys': <String>['absent'],
          'content': 'body-$index',
          'enabled': true,
          'insertion_order': 100 - index,
          'position': 'before_char',
          ...entries[index],
        },
    ],
  },
);

Set<WorldInfoEntryRef> _refs(WorldInfoBook book) => {for (final entry in book.entries) entry.identity};

WorldInfoExternalActivation _row(WorldInfoResult result, String uid, {String bookId = 'book'}) =>
    result.externalActivations.singleWhere((row) => row.identity == (bookId, uid));

String _timerKey(WorldInfoBook book, int index) => book.entries[index].stKey;
Map<String, Object?> _timer(WorldInfoBook book, int index) => {
  'hash': book.entries[index].stHash,
  'start': 0,
  'end': 4,
  'protected': false,
};

RegexWorker _gatedWorker(Completer<void> entered, Completer<void> release) => RegexWorker(
  spawner: (entryPoint, replies, errors, exits) async {
    entered.complete();
    await release.future;
    return Isolate.spawn<SendPort>(entryPoint, replies, onError: errors, onExit: exits);
  },
);

Future<WorldInfoResult> _evaluate(
  List<WorldInfoBook> books, {
  RegexWorker? worker,
  Set<WorldInfoEntryRef> external = const {},
  String text = 'key',
  WorldInfoSettings settings = const WorldInfoSettings(includeNames: false),
  String Function(String)? expand,
  int Function(String)? tokenCount,
  double Function()? random,
  String characterName = '',
  List<String>? characterTags,
  Map<String, Object?> timed = const {},
  Map<String, Object?> decoratorState = const {},
  int? assistantMessageCount,
  int? greetingIndex,
  String? userIconName,
  bool? contextAtCapacity,
  String Function(WorldInfoEntry, String, int?)? postProcessContent,
  void Function()? checkCancelled,
}) => WorldInfoEngine(worker: worker ?? _worker).evaluate(
  WorldInfoInput(
    books: books,
    messages: [WorldInfoMessage(text)],
    maxContext: 10000,
    tokenCount: tokenCount ?? (value) => value.length,
    random: random ?? () => 0,
    expand: expand ?? (value) => value,
    settings: settings,
    externalActivations: external,
    characterName: characterName,
    characterTags: characterTags,
    timedWorldInfo: timed,
    decoratorState: decoratorState,
    assistantMessageCount: assistantMessageCount,
    greetingIndex: greetingIndex,
    userIconName: userIconName,
    contextAtCapacity: contextAtCapacity,
    postProcessContent: postProcessContent,
    checkCancelled: checkCancelled,
  ),
);

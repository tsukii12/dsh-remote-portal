import 'dart:convert';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import 'support/t24_engine_harness.dart';

typedef Json = Map<String, Object?>;
typedef _Directed = ({TavernDirectorRun run, List<Json> catalog});

// Real facade, files, SQLite, WI loader, worker and prompt assembly. The model
// only supplies controlled deltas. Positive references come from the actual
// helper request; deliberately forged references are marked in their tests.
void main() {
  test('the sent catalog contains bound books and the real embedded identity but excludes an unbound book', () async {
    final h = await _open();
    await h.engine.putLorebook('bound', _book([_native('1', 'BOUND_BODY', title: 'BOUND')]));
    await h.engine.putLorebook('unbound', _book([_native('1', 'UNBOUND_BODY', title: 'UNBOUND')]));
    await h.engine.bindLorebooks(['bound']);
    await h.engine.bindLorebooks(['bound'], source: WorldInfoSource.chat, chatId: h.chatId);
    await h.engine.addCharacterBookEntry(h.characterId, {
      'keys': ['never-match-this'],
      'content': 'EMBEDDED_BODY',
      'comment': 'EMBEDDED',
    });
    final directed = await _direct(
      h,
      pick: (catalog) => [
        _reference(catalog, 'BOUND'),
        _reference(catalog, 'EMBEDDED'),
        // This local file exists, but its identity was not authorized by the catalog.
        {'kind': 'worldInfo', 'bookId': 'unbound', 'uid': '1'},
      ],
    );
    expect(directed.catalog.map((row) => row['title']), unorderedEquals(['BOUND', 'EMBEDDED']));
    expect(directed.run.issues.where((issue) => issue['code'] == 'prefetch_not_in_sent_catalog').single['index'], 2);
    final body = _bodyText(await _main(h));
    expect(body, contains('BOUND_BODY'));
    expect(body, contains('EMBEDDED_BODY'));
    expect(body, isNot(contains('UNBOUND_BODY')));
    final rows = await _references(h);
    expect(rows.take(2).every((row) => row['resolved'] == true && row['finalSourceObserved'] == true), isTrue);
    expect(rows.last['inSentCatalog'], isFalse);
    expect(rows.last['reason'], 'not_in_sent_catalog');
    expect(rows.last['finalSourceObserved'], isFalse);
    expect(h.engine.inspect(h.chatId)!.worldInfo.activated, hasLength(2));
  });

  test('the 512 item directory cap is explicit and guessing an omitted existing entry grants no access', () async {
    final h = await _open();
    final entries = [
      for (var index = 0; index < 513; index++) _native('$index', 'CAP_BODY_$index', title: 'CAP_TITLE_$index'),
    ];
    await h.engine.putLorebook('capped', _book(entries));
    await h.engine.bindLorebooks(['capped']);
    late final String omitted;
    late final String admitted;
    final directed = await _direct(
      h,
      pick: (catalog) {
        expect(catalog, hasLength(512));
        final refs = [for (final row in catalog) _map(row['reference'])];
        final sent = {for (final ref in refs) ref['uid']! as String};
        omitted = {for (var index = 0; index < 513; index++) '$index'}.difference(sent).single;
        admitted = refs.first['uid']! as String;
        return [
          refs.first,
          {'kind': 'worldInfo', 'bookId': refs.first['bookId'], 'uid': omitted},
        ];
      },
    );
    expect(directed.run.issues.singleWhere((issue) => issue['code'] == 'director_catalog_truncated')['omitted'], 1);
    final body = _bodyText(await _main(h));
    expect(body, contains('CAP_BODY_$admitted'));
    expect(body, isNot(contains('CAP_BODY_$omitted')));
    final rows = await _references(h);
    expect(rows.first['finalSourceObserved'], isTrue);
    expect(rows.last['inSentCatalog'], isFalse);
    expect(rows.last['resolved'], isFalse);
    expect(rows.last['reason'], 'not_in_sent_catalog');
    expect(h.engine.inspect(h.chatId)!.worldInfo.activated.single.uid, admitted);
  });

  test('native uid ambiguity is omitted while V3 duplicate ids expose and execute only the loader winner', () async {
    final h = await _open();
    final native = _book([
      _native('7', 'NATIVE_FIRST', title: 'NATIVE_FIRST'),
      _native('7', 'NATIVE_SECOND', title: 'NATIVE_SECOND'),
    ]);
    final v3 = <String, Object?>{
      'name': 'V3',
      'entries': [_v3(11, 'V3_OLD_BODY', title: 'V3_OLD'), _v3(11, 'V3_LAST_BODY', title: 'V3_LAST')],
    };
    await h.engine.putLorebook('native-ambiguous', native);
    await h.engine.putLorebook('v3-last', v3);
    await h.engine.bindLorebooks(['native-ambiguous', 'v3-last']);
    final directed = await _direct(
      h,
      pick: (catalog) => [
        {'kind': 'worldInfo', 'bookId': 'native-ambiguous', 'uid': '7'},
        _reference(catalog, 'V3_LAST'),
      ],
    );
    expect(directed.catalog.map((row) => row['title']), ['V3_LAST']);
    expect(directed.run.issues.where((issue) => issue['code'] == 'catalog_reference_ambiguous'), hasLength(1));
    final body = _bodyText(await _main(h));
    expect(body, contains('V3_LAST_BODY'));
    expect(body, isNot(contains('V3_OLD_BODY')));
    expect(body, isNot(contains('NATIVE_FIRST')));
    expect(body, isNot(contains('NATIVE_SECOND')));
    final rows = await _references(h);
    expect(rows.first['reason'], 'not_in_sent_catalog');
    expect(rows.last['resolved'], isTrue);
    expect(rows.last['finalSourceObserved'], isTrue);
    expect(await h.engine.lorebook('native-ambiguous'), native);
    expect(await h.engine.lorebook('v3-last'), v3);
  });

  test(
    'same uid in separate books remains distinct and duplicate requests preserve audit without repeating side effects',
    () async {
      final h = await _open();
      await h.engine.putLorebook(
        'first-book',
        _book([_native('shared', 'FIRST_ONCE={{incvar::prefetchOnce}}', title: 'FIRST')]),
      );
      await h.engine.putLorebook('second-book', _book([_native('shared', 'SECOND_BODY', title: 'SECOND')]));
      await h.engine.bindLorebooks(['first-book', 'second-book']);
      final directed = await _direct(
        h,
        pick: (catalog) => [_reference(catalog, 'FIRST'), _reference(catalog, 'SECOND'), _reference(catalog, 'FIRST')],
      );
      expect(directed.run.prefetch, hasLength(3));
      final body = _bodyText(await _main(h));
      expect(body.split('FIRST_ONCE=1').length - 1, 1);
      expect(body, contains('SECOND_BODY'));
      expect(h.engine.variables(h.chatId)['prefetchOnce'], 1);
      final world = h.engine.inspect(h.chatId)!.worldInfo;
      expect(
        world.activated.map((hit) => hit.entry.identity),
        unorderedEquals([('first-book', 'shared'), ('second-book', 'shared')]),
      );
      expect(world.externalActivations, hasLength(2));
      final rows = await _references(h);
      expect(rows, hasLength(3));
      expect(rows.first.containsKey('duplicateOf'), isFalse);
      expect(rows[1].containsKey('duplicateOf'), isFalse);
      expect(rows.last['duplicateOf'], 0);
      expect(rows.every((row) => row['resolved'] == true && row['finalSourceObserved'] == true), isTrue);
    },
  );

  test(
    'unbinding and deleting books after publication invalidate references without making up a new catalog',
    () async {
      final h = await _open();
      await h.engine.putLorebook('to-unbind', _book([_native('a', 'UNBOUND_LATER', title: 'UNBIND')]));
      await h.engine.putLorebook('to-delete', _book([_native('b', 'DELETED_LATER', title: 'DELETE')]));
      await h.engine.bindLorebooks(['to-unbind', 'to-delete']);
      await _direct(h, pick: (catalog) => [for (final row in catalog) _map(row['reference'])]);
      await h.engine.bindLorebooks(['to-delete']);
      await h.engine.deleteLorebook('to-delete');
      expect(await h.engine.lorebook('to-unbind'), isNotNull);
      expect(await h.engine.lorebook('to-delete'), isNull);
      final body = _bodyText(await _main(h));
      expect(body, isNot(contains('UNBOUND_LATER')));
      expect(body, isNot(contains('DELETED_LATER')));
      final inspection = (await h.engine.inspectTurn(h.chatId))!;
      expect(inspection.director['eligible'], isTrue);
      final rows = _rows(inspection.director['prefetch']);
      expect(rows, hasLength(2));
      for (final row in rows) {
        expect(row['inSentCatalog'], isTrue);
        expect(row['resolved'], isFalse);
        expect(row['reason'], 'entry_not_available');
        expect(row['finalSourceObserved'], isFalse);
      }
      expect(_rows(inspection.worldInfo['missing']).single['bookId'], 'to-delete');
    },
  );

  test('a newly ambiguous uid and a removed entry are rechecked against the current execution view', () async {
    final h = await _open();
    await h.engine.putLorebook(
      'changed',
      _book([_native('7', 'ORIGINAL', title: 'ORIGINAL'), _native('8', 'REMOVED', title: 'REMOVED')]),
    );
    await h.engine.bindLorebooks(['changed']);
    await _direct(h, pick: (catalog) => [_reference(catalog, 'ORIGINAL'), _reference(catalog, 'REMOVED')]);
    await h.engine.putLorebook(
      'changed',
      _book([_native('7', 'AMBIGUOUS_FIRST', title: 'FIRST'), _native('7', 'AMBIGUOUS_SECOND', title: 'SECOND')]),
    );
    final body = _bodyText(await _main(h));
    expect(body, isNot(contains('AMBIGUOUS_')));
    expect(body, isNot(contains('REMOVED')));
    final rows = await _references(h);
    expect(rows.map((row) => row['reason']), ['entry_ambiguous', 'entry_not_available']);
    expect(rows.every((row) => row['inSentCatalog'] == true && row['resolved'] == false), isTrue);
    expect(h.engine.inspect(h.chatId)!.worldInfo.externalActivations, isEmpty);
  });

  test('catalog membership does not bypass disabled probability or V3 regex validity gates', () async {
    final h = await _open();
    await h.engine.putLorebook(
      'native-gates',
      _book([
        _native('disabled', 'DISABLED_BODY', title: 'DISABLED', fields: {'disable': true}),
        _native(
          'probability',
          'ZERO_PROBABILITY_BODY',
          title: 'ZERO',
          fields: {'useProbability': true, 'probability': 0},
        ),
        _native('allowed', 'ALLOWED_BODY', title: 'ALLOWED'),
      ]),
    );
    await h.engine.putLorebook('regex-gate', {
      'entries': [
        _v3(
          1,
          'BAD_REGEX_BODY',
          title: 'BAD_REGEX',
          fields: {
            'keys': ['['],
            'use_regex': true,
          },
        ),
      ],
    });
    await h.engine.bindLorebooks(['native-gates', 'regex-gate']);
    final directed = await _direct(h, pick: (catalog) => [for (final row in catalog) _map(row['reference'])]);
    expect(directed.catalog.singleWhere((row) => row['title'] == 'DISABLED')['disabled'], isTrue);
    final body = _bodyText(await _main(h));
    expect(body, contains('ALLOWED_BODY'));
    for (final absent in ['DISABLED_BODY', 'ZERO_PROBABILITY_BODY', 'BAD_REGEX_BODY']) {
      expect(body, isNot(contains(absent)));
    }
    final rows = await _references(h);
    expect(rows.every((row) => row['inSentCatalog'] == true && row['resolved'] == true), isTrue);
    final decisions = {for (final row in rows) _map(row['worldInfo'])['uid']: _map(row['worldInfo'])};
    expect(decisions['disabled']!['code'], 'disabled');
    expect(decisions['probability']!['code'], 'probability');
    expect(decisions['1']!['code'], 'incompatible-pattern');
    expect(decisions['allowed']!['admitted'], isTrue);
    expect(rows.where((row) => row['finalSourceObserved'] == true), hasLength(1));
  });

  test('memory aliases are fallbacks and native fields plus the original row identity take precedence', () async {
    final h = await _open();
    _memory(
      h,
      'alias-key',
      _memoryEntry(
        'ALIAS_KEY_BODY',
        fields: {
          'keywords': ['signal'],
        },
      ),
    );
    _memory(
      h,
      'native-key',
      _memoryEntry(
        'NATIVE_KEY_BLOCKED',
        fields: {
          'key': ['never-match-this'],
          'keywords': ['signal'],
          'constant': false,
          'pinned': true,
        },
      ),
    );
    _memory(h, 'alias-pinned', _memoryEntry('PINNED_BODY', fields: {'pinned': true}));
    _memory(h, 'native-false', _memoryEntry('NATIVE_FALSE_BLOCKED', fields: {'constant': false, 'pinned': true}));
    _memory(
      h,
      'real-row',
      _memoryEntry(
        'REAL_ROW_BODY',
        fields: {
          'key': ['signal'],
          'uid': 'forged-uid',
          'world': 'forged-world',
        },
      ),
    );
    final before = _memoryBytes(h);
    final directed = await _direct(h);
    expect(
      directed.catalog.map((row) => _map(row['reference'])['id']),
      unorderedEquals(['alias-key', 'native-key', 'alias-pinned', 'native-false', 'real-row']),
    );
    final body = _bodyText(await _main(h, text: 'signal'));
    for (final present in ['ALIAS_KEY_BODY', 'PINNED_BODY', 'REAL_ROW_BODY']) {
      expect(body, contains(present));
    }
    expect(body, isNot(contains('NATIVE_KEY_BLOCKED')));
    expect(body, isNot(contains('NATIVE_FALSE_BLOCKED')));
    final hits = h.engine.inspect(h.chatId)!.worldInfo.activated;
    expect(hits.map((hit) => hit.uid), unorderedEquals(['alias-key', 'alias-pinned', 'real-row']));
    expect(
      hits.every((hit) => hit.bookId == 'dshgo:memory:${h.chatId}' && hit.source == WorldInfoSource.memory),
      isTrue,
    );
    expect(hits.singleWhere((hit) => hit.uid == 'real-row').entry.stKey, 'dshgo:memory:${h.chatId}.real-row');
    expect(_memoryBytes(h), before);
  });

  test(
    'memory expiry uses strict captured Unix milliseconds and invalid JSON cannot hide valid sentinel-shaped data',
    () async {
      final h = await _open();
      final now = T24Harness.at.millisecondsSinceEpoch;
      for (final item in <(String, Json)>[
        ('missing', {}),
        ('null', {'expiresAt': null}),
        ('future', {'expiresAt': now + 1}),
        ('boundary', {'expiresAt': now}),
        ('past', {'expiresAt': now - 1}),
        ('date-string', {'expiresAt': T24Harness.at.toIso8601String()}),
        ('double', {'expiresAt': now.toDouble()}),
        ('boolean', {'expiresAt': true}),
        (
          'sentinel',
          {
            '_dshgoInvalidMemoryJson': true,
            'unknown': {'literal': 'keep'},
          },
        ),
      ]) {
        _memory(h, item.$1, _memoryEntry('MEMORY_${item.$1}_BODY', fields: {'constant': true, ...item.$2}));
      }
      _memoryRaw(h, 'broken', '{private-invalid-json');
      _memoryRaw(h, 'nonfinite', '{"content":"NONFINITE_BODY","future":1e999}');
      final before = _memoryBytes(h);
      final directed = await _direct(h);
      expect(
        directed.catalog.map((row) => _map(row['reference'])['id']),
        unorderedEquals(['missing', 'null', 'future', 'sentinel']),
      );
      final issue = {for (final row in directed.run.issues) row['id']: row['code']};
      expect(issue['boundary'], 'memory_expired');
      expect(issue['past'], 'memory_expired');
      for (final id in ['date-string', 'double', 'boolean']) {
        expect(issue[id], 'memory_expiry_invalid');
      }
      expect(issue['broken'], 'memory_json_unavailable');
      expect(issue['nonfinite'], 'memory_json_unavailable');
      expect(issue.containsKey('sentinel'), isFalse);
      final body = _bodyText(await _main(h));
      for (final id in ['missing', 'null', 'future', 'sentinel']) {
        expect(body, contains('MEMORY_${id}_BODY'));
      }
      for (final id in ['boundary', 'past', 'date-string', 'double', 'boolean']) {
        expect(body, isNot(contains('MEMORY_${id}_BODY')));
      }
      expect(body, isNot(contains('NONFINITE_BODY')));
      expect(_memoryBytes(h), before);
    },
  );

  test(
    'all valid memories keep ordinary keyword and group behavior while only a picked row receives external admission',
    () async {
      final h = await _open();
      _memory(
        h,
        'picked',
        _memoryEntry(
          'PICKED_LOSER',
          title: 'PICKED',
          fields: {
            'key': ['never-match-this'],
            'group': 'contest',
          },
        ),
      );
      _memory(
        h,
        'winner',
        _memoryEntry(
          'KEYWORD_WINNER',
          fields: {
            'key': ['signal'],
            'group': 'contest',
            'groupOverride': true,
          },
        ),
      );
      _memory(
        h,
        'plain',
        _memoryEntry(
          'ORDINARY_KEYWORD',
          fields: {
            'key': ['signal'],
          },
        ),
      );
      _memory(
        h,
        'unpicked',
        _memoryEntry(
          'UNPICKED_NONMATCH',
          fields: {
            'key': ['never-match-this'],
          },
        ),
      );
      await _direct(h, pick: (catalog) => [_reference(catalog, 'PICKED')]);
      final body = _bodyText(await _main(h, text: 'signal'));
      expect(body, contains('KEYWORD_WINNER'));
      expect(body, contains('ORDINARY_KEYWORD'));
      expect(body, isNot(contains('PICKED_LOSER')));
      expect(body, isNot(contains('UNPICKED_NONMATCH')));
      final world = h.engine.inspect(h.chatId)!.worldInfo;
      expect(world.activated.map((hit) => hit.uid), unorderedEquals(['winner', 'plain']));
      expect(world.activated.every((hit) => hit.reason == 'keywords'), isTrue);
      expect(world.externalActivations.single.uid, 'picked');
      final row = (await _references(h)).single;
      expect(row['resolved'], isTrue);
      expect(_map(row['worldInfo'])['admitted'], isFalse);
      expect(_map(row['worldInfo'])['code'], 'group-override');
      expect(row['finalSourceObserved'], isFalse);
    },
  );

  test('missing and stale director results load no memory even when a stored entry is constant', () async {
    final h = await _open();
    _memory(h, 'constant', _memoryEntry('MEMORY_AFTER_DIRECTOR', fields: {'constant': true}));
    final first = _bodyText(await _main(h));
    expect(first, isNot(contains('MEMORY_AFTER_DIRECTOR')));
    expect(h.engine.inspect(h.chatId)!.worldInfo.activated, isEmpty);
    expect((await h.engine.inspectTurn(h.chatId))!.director, isEmpty);
    final sourceId = (await h.engine.path(h.chatId)).last.nodeId;
    await _direct(h);
    final second = _bodyText(await _main(h));
    expect(second, contains('MEMORY_AFTER_DIRECTOR'));
    expect(h.engine.inspect(h.chatId)!.worldInfo.activated.single.uid, 'constant');
    await h.engine.edit(h.chatId, sourceId, 'EDITED_SOURCE');
    final third = _bodyText(await _main(h));
    expect(third, isNot(contains('MEMORY_AFTER_DIRECTOR')));
    expect(h.engine.inspect(h.chatId)!.worldInfo.activated, isEmpty);
    final stale = (await h.engine.inspectTurn(h.chatId))!.director;
    expect(stale['eligible'], isFalse);
    expect(_rows(stale['issues']).any((row) => row['code'] == 'director_source_changed'), isTrue);
  });

  test('memory pseudo books remain chat scoped and use current SQLite rows without a file-book cache', () async {
    final h = await _open();
    final other = await h.engine.createChat(h.characterId);
    _memory(h, 'first-memory', _memoryEntry('FIRST_OLD', title: 'FIRST_MEMORY'));
    _memory(h, 'other-memory', _memoryEntry('OTHER_ONLY', title: 'OTHER_MEMORY'), chatId: other);
    final first = await _direct(h, pick: (catalog) => [_reference(catalog, 'FIRST_MEMORY')]);
    final second = await _direct(h, chatId: other, pick: (catalog) => [_reference(catalog, 'OTHER_MEMORY')]);
    expect(first.catalog.map((row) => _map(row['reference'])['id']), ['first-memory']);
    expect(second.catalog.map((row) => _map(row['reference'])['id']), ['other-memory']);
    _db(
      h,
      (db) => db.execute('UPDATE memories SET entry_json = ? WHERE id = ?', [
        jsonEncode(_memoryEntry('FIRST_CURRENT', title: 'FIRST_MEMORY')),
        'first-memory',
      ]),
    );
    final firstBody = _bodyText(await _main(h));
    expect(firstBody, contains('FIRST_CURRENT'));
    expect(firstBody, isNot(contains('FIRST_OLD')));
    expect(firstBody, isNot(contains('OTHER_ONLY')));
    expect(h.engine.inspect(h.chatId)!.worldInfo.activated.single.bookId, 'dshgo:memory:${h.chatId}');
    final otherBody = _bodyText(await _main(h, chatId: other));
    expect(otherBody, contains('OTHER_ONLY'));
    expect(otherBody, isNot(contains('FIRST_CURRENT')));
    expect(h.engine.inspect(other)!.worldInfo.activated.single.bookId, 'dshgo:memory:$other');
  });

  test('memory catalog preparation is inert while selected memory content runs the standard WI macro pass', () async {
    final h = await _open();
    _memory(
      h,
      'macro',
      _memoryEntry('MEMORY={{incvar::memoryPass}}|{{getvar::memoryPass}}', title: '{{incvar::catalogPass}}'),
    );
    final before = _memoryBytes(h);
    final directed = await _direct(h, pick: (catalog) => [_map(catalog.single['reference'])]);
    expect(directed.catalog.single['title'], '{{incvar::catalogPass}}');
    expect(h.engine.variables(h.chatId).containsKey('catalogPass'), isFalse);
    expect(h.engine.variables(h.chatId).containsKey('memoryPass'), isFalse);
    final body = _bodyText(await _main(h));
    expect(body, contains('MEMORY=1|1'));
    expect(body, isNot(contains('{{incvar::memoryPass}}')));
    expect(h.engine.variables(h.chatId)['memoryPass'], 1);
    expect(h.engine.variables(h.chatId).containsKey('catalogPass'), isFalse);
    expect(_map((await _references(h)).single['worldInfo'])['reason'], 'external');
    expect(_memoryBytes(h), before);
  });

  test('final source evidence traverses author-note and grouped-depth origins after real assembly', () async {
    final h = await _open();
    await h.engine.putLorebook(
      'nested-origins',
      _book([
        _native('before', 'AN_BEFORE_BODY', title: 'AN_BEFORE', fields: {'position': 2}),
        _native('after', 'AN_AFTER_BODY', title: 'AN_AFTER', fields: {'position': 3}),
        _native('depth', 'DEPTH_BODY', title: 'DEPTH', fields: {'position': 4, 'depth': 1, 'role': 0}),
      ]),
    );
    await h.engine.bindLorebooks(['nested-origins']);
    await h.engine.setSettings({
      'authorNote': {'content': 'AN_BASE', 'depth': 1, 'role': 'system'},
    }, chatId: h.chatId);
    await _direct(h, pick: (catalog) => [for (final row in catalog) _map(row['reference'])]);
    final body = _bodyText(await _main(h));
    for (final text in ['AN_BEFORE_BODY', 'AN_BASE', 'AN_AFTER_BODY', 'DEPTH_BODY']) {
      expect(body, contains(text));
    }
    final rows = await _references(h);
    expect(rows, hasLength(3));
    expect(rows.every((row) => row['finalSourceObserved'] == true), isTrue);
    final sources = h.engine
        .inspect(h.chatId)!
        .prompt
        .afterPostProcessing
        .expand((segment) => segment.sources)
        .toList();
    expect(
      sources.any((source) => source.kind == 'authorNote' && _rows(source.details['worldInfo']).length == 2),
      isTrue,
    );
    expect(sources.any((source) => source.kind == 'worldInfo' && _rows(source.details['entries']).length == 1), isTrue);
    final stored = (await h.engine.inspectTurn(h.chatId))!.director;
    await h.reopen();
    expect((await h.engine.inspectTurn(h.chatId))!.director, stored);
  });

  test('outlet availability and disabled marker admission never masquerade as an observed final WI source', () async {
    final h = await _open();
    final preset = t24Preset().raw;
    _rows(preset['prompts']).singleWhere((row) => row['identifier'] == 'main')['content'] = 'HOST={{outlet::slot}}';
    final order = _rows(_rows(preset['prompt_order']).single['order']);
    order.singleWhere((row) => row['identifier'] == 'worldInfoBefore')['enabled'] = false;
    await h.engine.setPreset(ChatPreset(preset));
    await h.engine.putLorebook(
      'non-direct-origins',
      _book([
        _native('outlet', 'OUTLET_BODY', title: 'OUTLET', fields: {'position': 7, 'outletName': 'slot'}),
        _native('hidden-marker', 'DISABLED_MARKER_BODY', title: 'HIDDEN_MARKER'),
      ]),
    );
    await h.engine.bindLorebooks(['non-direct-origins']);
    await _direct(h, pick: (catalog) => [for (final row in catalog) _map(row['reference'])]);
    final body = _bodyText(await _main(h));
    expect(body, contains('HOST=OUTLET_BODY'));
    expect(body, isNot(contains('DISABLED_MARKER_BODY')));
    final rows = await _references(h);
    expect(rows, hasLength(2));
    for (final row in rows) {
      expect(row['resolved'], isTrue);
      expect(_map(row['worldInfo'])['admitted'], isTrue);
      expect(_map(row['worldInfo'])['retained'], isTrue);
      expect(row['finalSourceObserved'], isFalse);
      expect(row['finalReason'], 'source_not_observed_in_final_messages');
    }
    // The outlet text really appears through the host macro, but this field
    // reports provenance, not an inference made by searching matching text.
    expect(h.engine.inspect(h.chatId)!.worldInfo.outlets['slot']!.single.uid, 'outlet');
  });
}

Future<T24Harness> _open() async {
  final h = await T24Harness.open(thinking: false);
  addTearDown(h.dispose);
  await h.engine.setSettings({
    'worldInfo': {
      'world_info_depth': 20,
      'world_info_budget': 100,
      'world_info_include_names': false,
      'world_info_recursive': false,
      'world_info_match_whole_words': false,
    },
  });
  return h;
}

Json _native(String uid, String content, {String? title, Json fields = const {}}) => {
  'uid': uid,
  'key': ['never-match-this'],
  'keysecondary': <String>[],
  'content': content,
  'comment': title ?? uid,
  'constant': false,
  'disable': false,
  'position': 0,
  'order': 100,
  ...fields,
};

Json _v3(int id, String content, {String? title, Json fields = const {}}) => {
  'id': id,
  'keys': ['never-match-this'],
  'secondary_keys': <String>[],
  'content': content,
  'comment': title ?? '$id',
  'constant': false,
  'enabled': true,
  'position': 'before_char',
  'insertion_order': 100,
  ...fields,
};

Json _book(List<Json> entries) => {
  'name': 'Display title',
  'entries': {for (var index = 0; index < entries.length; index++) '$index': entries[index]},
};

Json _memoryEntry(String content, {String title = '', Json fields = const {}}) => {
  'content': content,
  'comment': title,
  'position': 0,
  'order': 100,
  ...fields,
};

Json _map(Object? value) => value! as Json;
List<Json> _rows(Object? value) => value == null ? [] : (value as List<Object?>).cast<Json>();
Json _reference(List<Json> catalog, String title) =>
    _map(catalog.singleWhere((row) => row['title'] == title)['reference']);
String _bodyText(Json body) => _rows(body['messages']).map((message) => message['content'] ?? '').join('\n');

Future<_Directed> _direct(T24Harness h, {List<Json> Function(List<Json>)? pick, String? chatId}) async {
  final call = h.model.prepare();
  final pending = h.engine.runDirector(chatId ?? h.chatId);
  await call.listening.future;
  final input = _map(jsonDecode(_rows(call.body!['messages']).last['content']! as String));
  final catalog = _rows(input['catalog']);
  final prefetch = pick?.call(catalog) ?? <Json>[];
  call.add(
    ModelToolFragment(
      index: 0,
      id: 'prefetch-direct',
      type: 'function',
      name: 'direct',
      arguments: jsonEncode({
        'notes': '',
        'beat': '',
        'prefetch': prefetch,
        'suggestions': [
          for (final text in ['First option', 'Second option', 'Third option']) {'text': text, 'risk': ''},
        ],
        'events': <Object?>[],
      }),
    ),
  );
  await call.finish('tool_calls');
  final run = await pending;
  expect(run.success, isTrue, reason: run.failure);
  return (run: run, catalog: catalog);
}

Future<Json> _main(T24Harness h, {String text = 'quiet', String? chatId}) async {
  final call = h.model.prepare();
  final events = T24Events(h.engine.send(chatId ?? h.chatId, text));
  await call.listening.future;
  final body = _map(jsonDecode(jsonEncode(call.body)));
  call.add(const ModelText('REPLY'));
  await call.finish();
  await events.done.future;
  expect(events.values.whereType<TavernTurnFailed>(), isEmpty);
  expect(events.values.whereType<TavernTurnDone>(), hasLength(1));
  return body;
}

Future<List<Json>> _references(T24Harness h) async =>
    _rows((await h.engine.inspectTurn(h.chatId))!.director['prefetch']);

T _db<T>(T24Harness h, T Function(Database) action) {
  final db = sqlite3.open('${h.root.path}/tavern.sqlite3');
  try {
    return action(db);
  } finally {
    db.close();
  }
}

void _memory(T24Harness h, String id, Json entry, {String? chatId}) =>
    _memoryRaw(h, id, jsonEncode(entry), chatId: chatId);
void _memoryRaw(T24Harness h, String id, String raw, {String? chatId}) => _db(
  h,
  (db) => db.execute("INSERT INTO memories(id, chat_id, entry_json, origin) VALUES (?, ?, ?, 'legacy')", [
    id,
    chatId ?? h.chatId,
    raw,
  ]),
);

String _memoryBytes(T24Harness h) => _db(
  h,
  (db) => jsonEncode([
    for (final row in db.select('SELECT id, chat_id, entry_json FROM memories ORDER BY rowid'))
      Map<String, Object?>.from(row),
  ]),
);

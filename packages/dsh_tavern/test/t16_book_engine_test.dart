import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:test/test.dart';

// Real facade, files, JSONL, macros, regex, WI and SQLite; synthetic model
// output and clock/random only. No model account is contacted.
void main() {
  test('public book preview matches Cherokee Mtavruli and Adlam uppercase text', () async {
    const families = <(String, String, String)>[
      ('\u13a0', '\uab70', 'CHEROKEE_MARKER'),
      ('\u1c90', '\u10d0', 'MTAVRULI_MARKER'),
      ('\u{1e900}', '\u{1e922}', 'ADLAM_MARKER'),
    ];
    for (final (upper, lower, content) in families) {
      final (h, characterId) = await _plainCaseBook(lower, content);
      expect(_hits(await h.engine.previewCharacterBook(characterId, lower)).map((hit) => hit['content']), [content]);
      final preview = await h.engine.previewCharacterBook(characterId, upper);
      expect(preview['scope'], 'character-book');
      expect(preview['stage'], 'world-info');
      expect(preview['overflowed'], isFalse);
      expect(preview['regexDiagnostics'], isNull);
      // First behavioral oracle after the common lowercase/public prerequisites.
      expect(_hits(preview).map((hit) => hit['content']), [content]);
      final hit = _hits(preview).single;
      expect(
        {
          'bookId': hit['bookId'],
          'source': hit['source'],
          'reason': hit['reason'],
          'phase': hit['phase'],
          'primaryKey': hit['primaryKey'],
        },
        {
          'bookId': '$characterId:card',
          'source': 'character',
          'reason': 'keywords',
          'phase': 'initial',
          'primaryKey': lower,
        },
      );
      if (upper == '\u13a0') {
        await h.engine.updateCharacterBookEntry(characterId, 0, {
          'keys': [upper],
        });
        final reverse = await h.engine.previewCharacterBook(characterId, lower);
        expect(_hits(reverse).map((value) => value['content']), [content]);
        expect(_hits(reverse).single['primaryKey'], upper);
        expect((await _entries(h.engine, characterId)).single['keys'], [upper]);
        await h.engine.updateCharacterBookEntry(characterId, 0, {'case_sensitive': true});
        expect(_hits(await h.engine.previewCharacterBook(characterId, lower)), isEmpty);
        expect(_hits(await h.engine.previewCharacterBook(characterId, upper)).map((value) => value['content']), [
          content,
        ]);
      }
      expect(h.model.bodies, isEmpty);
      expect(await h.engine.watchChats().first, isEmpty);
    }
  });

  test('public book preview applies final sigma without a nonfinal false positive', () async {
    final (h, characterId) = await _plainCaseBook('\u03bf\u03c2', 'SIGMA_MARKER');
    expect(_hits(await h.engine.previewCharacterBook(characterId, '\u03bf\u03c2')).map((hit) => hit['content']), [
      'SIGMA_MARKER',
    ]);
    final preview = await h.engine.previewCharacterBook(characterId, '\u039f\u03a3');
    expect(preview['scope'], 'character-book');
    expect(preview['stage'], 'world-info');
    expect(preview['overflowed'], isFalse);
    expect(preview['regexDiagnostics'], isNull);
    // Fixed ST default lowercase: ΟΣ -> ος; old native simple mapping gives οσ.
    expect(_hits(preview).map((hit) => hit['content']), ['SIGMA_MARKER']);
    final hit = _hits(preview).single;
    expect(
      {
        'bookId': hit['bookId'],
        'source': hit['source'],
        'reason': hit['reason'],
        'phase': hit['phase'],
        'primaryKey': hit['primaryKey'],
      },
      {
        'bookId': '$characterId:card',
        'source': 'character',
        'reason': 'keywords',
        'phase': 'initial',
        'primaryKey': '\u03bf\u03c2',
      },
    );
    await h.engine.updateCharacterBookEntry(characterId, 0, {
      'keys': ['\u03bf\u03c3'],
    });
    expect(_hits(await h.engine.previewCharacterBook(characterId, '\u039f\u03a3')), isEmpty);
    await h.engine.updateCharacterBookEntry(characterId, 0, {
      'keys': ['\u03bf\u03c2'],
      'case_sensitive': true,
    });
    expect(_hits(await h.engine.previewCharacterBook(characterId, '\u039f\u03a3')), isEmpty);
    expect(_hits(await h.engine.previewCharacterBook(characterId, '\u03bf\u03c2')).map((value) => value['content']), [
      'SIGMA_MARKER',
    ]);
    expect(h.model.bodies, isEmpty);
    expect(await h.engine.watchChats().first, isEmpty);
  });

  test('public book preview expands dotted I without an ASCII i false positive', () async {
    final (h, characterId) = await _plainCaseBook('i\u0307', 'DOTTED_I_MARKER');
    expect(_hits(await h.engine.previewCharacterBook(characterId, 'i\u0307')).map((hit) => hit['content']), [
      'DOTTED_I_MARKER',
    ]);
    final preview = await h.engine.previewCharacterBook(characterId, '\u0130');
    expect(preview['scope'], 'character-book');
    expect(preview['stage'], 'world-info');
    expect(preview['overflowed'], isFalse);
    expect(preview['regexDiagnostics'], isNull);
    // A bare i key would also match the JS expansion and would not detect loss.
    expect(_hits(preview).map((hit) => hit['content']), ['DOTTED_I_MARKER']);
    expect(_hits(preview).single['primaryKey'], 'i\u0307');
    await h.engine.updateCharacterBookEntry(characterId, 0, {
      'keys': ['\u0130'],
    });
    expect(_hits(await h.engine.previewCharacterBook(characterId, 'i')), isEmpty);
    expect(_hits(await h.engine.previewCharacterBook(characterId, '\u0130')).map((hit) => hit['content']), [
      'DOTTED_I_MARKER',
    ]);
    expect(h.model.bodies, isEmpty);
    expect(await h.engine.watchChats().first, isEmpty);
  });

  test('public book edits notify selectors and preserve unknown fields across reopen', () async {
    final h = await _open();
    final character = await h.engine.importCard(_card());
    final Tavern facade = h.engine;
    final changed = facade.watchCharacters().firstWhere(
      (cards) => cards.any((card) => card.id == character.id && card.hasLorebook),
    );
    final added = await facade.addCharacterBookEntry(character.id, {
      'keys': ['beacon'],
      'content': 'FOUND',
      'enabled': true,
      'extensions': {
        'unknown': {'kept': 1, 'changed': 2},
      },
      'foreignEntry': ['鲸', null],
    });
    expect(added.hasLorebook, isTrue);
    await changed.timeout(const Duration(seconds: 5));
    final id = (await _entries(h.engine, character.id)).single['id'];
    expect(id, isA<int>());
    await facade.updateCharacterBookEntry(character.id, 0, {
      'content': 'UPDATED',
      'extensions': {
        'unknown': {'changed': 3},
        'group': 'probe',
      },
    });
    final edited = (await _entries(h.engine, character.id)).single;
    expect(edited['id'], id);
    expect(edited['keys'], ['beacon']);
    expect(edited['content'], 'UPDATED');
    expect(edited['foreignEntry'], ['鲸', null]);
    expect(_map(edited['extensions'])['unknown'], {'kept': 1, 'changed': 3});
    await h.reopen();
    expect((await _entries(h.engine, character.id)).single, edited);
    await h.engine.deleteCharacterBookEntry(character.id, 0);
    expect(await _entries(h.engine, character.id), isEmpty);
    expect((await h.engine.watchCharacters().first).single.hasLorebook, isTrue);
  });

  test('book edits refresh only their own cached detail and failed edits retain the last committed book', () async {
    final h = await _open();
    final first = await h.engine.importCard(_card());
    final second = await h.engine.importCard(
      _card({
        'name': 'Other',
        'character_book': {
          'entries': [_entry(7, 'OTHER', constant: true)],
        },
      }),
    );
    await h.reopen();
    await h.engine.character(first.id);
    await h.engine.character(second.id);
    await File('${h.directory.path}/characters/${second.id}/original.json').delete();
    await h.engine.addCharacterBookEntry(first.id, {'content': 'FIRST', 'constant': true});
    expect((await h.engine.character(first.id))!.hasLorebook, isTrue);
    expect(_hits(await h.engine.previewCharacterBook(first.id, '')).single['content'], 'FIRST');
    await h.engine.updateCharacterBookEntry(first.id, 0, {'content': 'UPDATED'});
    expect(_hits(await h.engine.previewCharacterBook(first.id, '')).single['content'], 'UPDATED');
    final pending = await Directory('${h.directory.path}/characters/${first.id}/card.json.writing').create();
    await expectLater(
      h.engine.updateCharacterBookEntry(first.id, 0, {'content': 'NOT COMMITTED'}),
      throwsA(
        isA<TavernAuthoringException>()
            .having((error) => error.code, 'code', 'resource_write_failed')
            .having((error) => error.receipt?.committed, 'committed', isFalse)
            .having((error) => error.cause, 'cause', isA<FileSystemException>()),
      ),
    );
    expect(_hits(await h.engine.previewCharacterBook(first.id, '')).single['content'], 'UPDATED');
    await pending.delete();
    expect((await h.engine.character(second.id))!.name, 'Other');
    expect(_hits(await h.engine.previewCharacterBook(second.id, '')).single['content'], 'OTHER');
    final summary = (await h.engine.watchCharacters().first).singleWhere((item) => item.id == first.id);
    expect(summary.hasLorebook, isTrue);
    expect(summary.description, isEmpty);
    expect(h.model.bodies, isEmpty);
  });

  test('book edits preserve the report until explicit recheck and empty or invalid patches keep it current', () async {
    final h = await _open();
    final character = await h.engine.importCard(_card());
    final file = File('${h.directory.path}/characters/${character.id}/import-report.json');
    final originalBytes = await file.readAsBytes();
    final original = (await h.engine.readImportReport(TavernImportKind.character, character.id))!;
    expect(original.stale, isFalse);
    await h.engine.addCharacterBookEntry(character.id, {'content': '{{banned::x}}'});
    expect(await file.readAsBytes(), orderedEquals(originalBytes));
    final stale = (await h.engine.readImportReport(TavernImportKind.character, character.id))!;
    expect(stale.stale, isTrue);
    expect(stale.checkedAt, original.checkedAt);
    expect(stale.fingerprint, original.fingerprint);
    final rawBeforeRecheck = await File('${h.directory.path}/characters/${character.id}/card.json').readAsBytes();
    final checked = await h.engine.recheckImport(TavernImportKind.character, character.id);
    expect(checked.counts['entriesStored'], 1);
    expect(checked.verdict, TavernImportVerdict.partial);
    expect(
      checked.findings.any(
        (finding) =>
            finding.code == 'macro-banned-no-effect' && finding.path == r'$.data.character_book.entries[0].content',
      ),
      isTrue,
    );
    expect(
      await File('${h.directory.path}/characters/${character.id}/card.json').readAsBytes(),
      orderedEquals(rawBeforeRecheck),
    );
    final checkedBytes = await file.readAsBytes();
    await h.engine.updateCharacterBookEntry(character.id, 0, {});
    await expectLater(
      h.engine.updateCharacterBookEntry(character.id, 0, {'enabled': 'wrong type'}),
      throwsArgumentError,
    );
    expect(await file.readAsBytes(), orderedEquals(checkedBytes));
    expect((await h.engine.readImportReport(TavernImportKind.character, character.id))!.stale, isFalse);
    await h.engine.deleteCharacterBookEntry(character.id, 0);
    expect((await h.engine.readImportReport(TavernImportKind.character, character.id))!.stale, isTrue);
    final empty = await h.engine.recheckImport(TavernImportKind.character, character.id);
    expect(empty.counts['entriesStored'], 0);
    expect(empty.findings.any((finding) => finding.code == 'macro-banned-no-effect'), isFalse);
    expect((await h.engine.readImportReport(TavernImportKind.character, character.id))!.stale, isFalse);
    expect(h.model.bodies, isEmpty);
  });

  test('entry mutations capture nested caller values before library IO', () async {
    final h = await _open();
    final character = await h.engine.importCard(_card());
    final entry = <String, Object?>{
      'keys': <String>['original'],
      'content': 'BODY',
      'extensions': <String, Object?>{'group': 'original'},
    };
    final adding = h.engine.addCharacterBookEntry(character.id, entry);
    (entry['keys']! as List<String>)[0] = 'mutated';
    (entry['extensions']! as Map<String, Object?>)['group'] = 'mutated';
    await adding;
    expect((await _entries(h.engine, character.id)).single['keys'], ['original']);
    final patch = <String, Object?>{
      'extensions': <String, Object?>{'group': 'captured'},
    };
    final updating = h.engine.updateCharacterBookEntry(character.id, 0, patch);
    (patch['extensions']! as Map<String, Object?>)['group'] = 'mutated-again';
    await updating;
    expect(_map((await _entries(h.engine, character.id)).single['extensions'])['group'], 'captured');
  });
  test('editing keys secondary logic and placement changes the actual match trace', () async {
    final h = await _open();
    final character = await h.engine.importCard(_card());
    await h.engine.addCharacterBookEntry(character.id, {
      'keys': ['dragon'],
      'secondary_keys': ['gold'],
      'selective': true,
      'enabled': true,
      'content': 'TREASURE',
      'insertion_order': 123,
      'extensions': {'selectiveLogic': 0, 'position': 4, 'depth': 2, 'role': 1},
    });
    expect(_hits(await h.engine.previewCharacterBook(character.id, 'dragon')), isEmpty);
    final preview = await h.engine.previewCharacterBook(character.id, 'dragon with gold', seed: 7);
    expect(preview['scope'], 'character-book');
    expect(preview['stage'], 'world-info');
    expect(preview['seed'], 7);
    final hit = _hits(preview).single;
    expect(hit['reason'], 'keywords');
    expect(hit['primaryKey'], 'dragon');
    expect(hit['secondaryMatches'], ['gold']);
    expect(hit['position'], 4);
    expect(hit['depth'], 2);
    expect(hit['role'], 1);
    expect(hit['order'], 123);
    await h.engine.updateCharacterBookEntry(character.id, 0, {'enabled': false});
    expect(_hits(await h.engine.previewCharacterBook(character.id, 'dragon with gold')), isEmpty);
    await h.engine.updateCharacterBookEntry(character.id, 0, {
      'enabled': true,
      'constant': true,
      'selective': false,
      'keys': <String>[],
    });
    expect(_hits(await h.engine.previewCharacterBook(character.id, 'unrelated')).single['reason'], 'constant');
    expect(h.model.bodies, isEmpty);
  });

  test('deleting freezes implicit IDs without moving the remaining matching identity', () async {
    final h = await _open();
    final character = await h.engine.importCard(
      _card({
        'character_book': {
          'entries': [
            {
              'keys': ['a'],
              'content': 'A',
              'enabled': true,
              'extensions': <String, Object?>{},
            },
            {
              'keys': ['b'],
              'content': 'B',
              'enabled': true,
              'extensions': <String, Object?>{},
            },
          ],
          'foreignBook': {'kept': true},
        },
      }),
    );
    expect(_hits(await h.engine.previewCharacterBook(character.id, 'b')).single['uid'], '1');
    await h.engine.deleteCharacterBookEntry(character.id, 0);
    expect(_map((await h.engine.characterFields(character.id))!['character_book'])['foreignBook'], {'kept': true});
    expect((await _entries(h.engine, character.id)).single['id'], 1);
    expect(_hits(await h.engine.previewCharacterBook(character.id, 'b')).single['uid'], '1');
  });

  test('preview copies variables and random state and leaves storage and inspections unchanged', () async {
    var draws = 0;
    final h = await _open(
      random: () {
        draws++;
        return 0.25;
      },
    );
    final character = await h.engine.importCard(
      _card({
        'character_book': {
          'entries': [_entry(7, '{{incvar::local}}|{{incglobalvar::global}}|{{random::A::B}}', constant: true)],
        },
      }),
    );
    final chat = await h.importChat(character.id, [_row('G')], variables: {'local': 10});
    await h.engine.setGlobalVariables({'global': 20});
    final before = await _snapshot(h.engine, chat);
    final settingsBefore = await File('${h.directory.path}/settings.json').readAsString();
    expect(await h.engine.inspectTurn(chat), isNull);
    final first = await h.engine.previewCharacterBook(character.id, 'Q', chatId: chat, seed: 9);
    final second = await h.engine.previewCharacterBook(character.id, 'Q', chatId: chat, seed: 9);
    expect(first, second);
    expect(_hits(first).single['content'], startsWith('11|21|'));
    expect(first['chatId'], chat);
    expect(first['contextNodeId'], (await h.engine.path(chat)).single.nodeId);
    expect(h.engine.variables(chat), {'local': 10});
    expect(h.engine.globalVariables, {'global': 20});
    expect(draws, 0);
    expect(h.model.bodies, isEmpty);
    expect(await h.engine.inspectTurn(chat), isNull);
    expect(await _snapshot(h.engine, chat), before);
    expect(await File('${h.directory.path}/settings.json').readAsString(), settingsBefore);
    final returnedHit = (first['activated']! as List<Object?>).single! as Map<String, Object?>;
    (returnedHit['secondaryMatches']! as List<Object?>).add('caller-change');
    expect(await h.engine.previewCharacterBook(character.id, 'Q', chatId: chat, seed: 9), second);
    final events = await h.engine.send(chat, 'Q').toList();
    expect(events.whereType<TavernTurnFailed>(), isEmpty);
    expect(events.whereType<TavernTurnDone>(), hasLength(1));
    expect(h.engine.variables(chat)['local'], 11);
    expect(h.engine.globalVariables['global'], 21);
    expect(draws, greaterThan(0));
  });

  test('preview honors current sticky and cooldown without advancing them', () async {
    var draws = 0;
    var rejectDraws = false;
    final h = await _open(
      random: () {
        if (rejectDraws) {
          throw StateError('Preview or a sticky entry consumed the live RNG.');
        }
        draws++;
        return 0;
      },
    );
    final character = await h.engine.importCard(
      _card({
        'character_book': {
          'entries': [
            _entry(8, 'STICKY', keys: ['FIRST'], extensions: {'sticky': 3, 'useProbability': true, 'probability': 50}),
            _entry(9, 'COOLING', constant: true, extensions: {'cooldown': 3}),
          ],
        },
      }),
    );
    final chat = await h.engine.createChat(character.id);
    final first = await h.engine.send(chat, 'FIRST').toList();
    expect(first.whereType<TavernTurnFailed>(), isEmpty);
    expect(h.engine.inspect(chat)!.worldInfo.activated.map((hit) => hit.uid), containsAll(['8', '9']));
    final before = await _snapshot(h.engine, chat);
    final inspection = (await h.engine.inspectTurn(chat))!.toJson();
    final beforeDraws = draws;
    rejectDraws = true;
    for (var attempt = 0; attempt < 2; attempt++) {
      final preview = await h.engine.previewCharacterBook(character.id, 'NEXT', chatId: chat, seed: 91);
      final hits = _hits(preview);
      expect(hits.map((hit) => hit['uid']), ['8']);
      expect(hits.single['reason'], 'sticky');
      expect(hits.single['probabilityRoll'], isNull);
    }
    expect(draws, beforeDraws);
    expect(await _snapshot(h.engine, chat), before);
    expect((await h.engine.inspectTurn(chat))!.toJson(), inspection);
    final second = await h.engine.send(chat, 'NEXT').toList();
    expect(second.whereType<TavernTurnFailed>(), isEmpty);
    expect(h.engine.inspect(chat)!.worldInfo.activated.map((hit) => hit.uid), ['8']);
  });

  test('preview uses visible chat context and rejects a different character chat', () async {
    final h = await _open();
    final character = await h.engine.importCard(
      _card({
        'character_book': {
          'entries': [
            _entry(1, '{{getvar::state}}', keys: ['beacon']),
            _entry(2, 'HIDDEN_MATCH', keys: ['secret']),
          ],
        },
      }),
    );
    final chat = await h.importChat(
      character.id,
      [_row('beacon', user: true), _row('secret', hidden: true)],
      variables: {'state': 'VALUE'},
    );
    final preview = await h.engine.previewCharacterBook(character.id, 'plain', chatId: chat);
    expect(_hits(preview).map((hit) => hit['uid']), ['1']);
    expect(_hits(preview).single['content'], 'VALUE');
    final other = await h.engine.importCard(_card({'name': 'Other'}));
    final otherChat = await h.engine.createChat(other.id);
    await expectLater(h.engine.previewCharacterBook(character.id, 'beacon', chatId: otherChat), throwsArgumentError);
    expect(h.engine.variables(chat), {'state': 'VALUE'});
    final beforeDelete = await h.engine.path(chat);
    final token = await h.engine.deleteFrom(chat, beforeDelete.first.nodeId);
    expect(_hits(await h.engine.previewCharacterBook(character.id, 'plain', chatId: chat)), isEmpty);
    expect(await h.engine.path(chat), isEmpty);
    expect(await h.engine.undoDeleteFrom(chat, token), isTrue);
    expect((await h.engine.path(chat)).map((message) => message.nodeId), beforeDelete.map((message) => message.nodeId));
    expect(_hits(await h.engine.previewCharacterBook(character.id, 'plain', chatId: chat)).single['uid'], '1');
    expect(h.model.bodies, isEmpty);
  });

  test('preview resolves the bound preset before user regex macros and keeps managed preset character order', () async {
    for (final mode in ['new', 'legacy']) {
      final h = await _open();
      final character = await h.engine.importCard(
        _card({
          'description': '{{incvar::prepares}}',
          'extensions': {
            'regex_scripts': [
              _script('character', r'^2048$', 'beacon', [1]),
            ],
          },
          'character_book': {
            'entries': [
              _entry(1, '{{maxContext}}|{{maxResponse}}|{{maxPrompt}}|{{getvar::prepares}}', keys: ['beacon']),
            ],
          },
        }),
      );
      final chat = await h.engine.createChat(character.id);
      final global = (await h.engine.importPreset(
        jsonEncode({
          'name': 'Global',
          'openai_max_context': 8192,
          'openai_max_tokens': 512,
          'extensions': {
            'regex_scripts': [
              _script('global-preset', r'^managed$', '{{maxContext}}', [1]),
            ],
          },
        }),
      )).preset;
      final bound = (await h.engine.importPreset(
        jsonEncode({
          'name': 'Bound',
          'openai_max_context': 4096,
          'openai_max_tokens': 128,
          'extensions': {
            'regex_scripts': [
              _script('bound-preset', r'^managed$', '{{maxContext}}', [1]),
            ],
          },
        }),
      )).preset;
      await h.engine.importRegexScripts(jsonEncode(_script('managed', r'^token$', 'managed', [1])));
      await h.engine.setDefaultPreset(global.id);
      await h.engine.bindPreset(chat, bound.id);
      await h.engine.setSettings({'macroEngine': mode});
      await h.engine.setSettings({
        'presetOverrides': {'openai_max_context': 2048, 'openai_max_tokens': 64},
      }, chatId: chat);
      final variablesBefore = _map(h.engine.variables(chat));
      final preview = await h.engine.previewCharacterBook(character.id, 'token', chatId: chat);
      final content = _hits(preview).single['content']! as String;
      expect(content, startsWith('2048|64|1984|'), reason: mode);
      expect(int.parse(content.split('|').last), greaterThan(0), reason: mode);
      expect(_hits(await h.engine.previewCharacterBook(character.id, 'token')), isEmpty);
      expect(h.engine.variables(chat), variablesBefore, reason: mode);
      expect(h.model.bodies, isEmpty);
      final events = await h.engine.send(chat, 'token').toList();
      expect(events.whereType<TavernTurnFailed>(), isEmpty, reason: mode);
      expect(_hits(_map(h.engine.inspect(chat)!.toJson()['worldInfo'])), _hits(preview), reason: mode);
      expect((await h.engine.path(chat))[1].text, 'beacon', reason: mode);
    }
  });

  test(
    'a skipped keyword cannot activate NOT and the same worker handles the repaired book without state writes',
    () async {
      final h = await _open();
      // CCV3 use_regex matches primary keys only: both a matching secondary
      // and an invalid secondary are ignored, without entering NOT logic.
      final v3Character = await h.engine.importCard(
        _card({
          'character_book': {
            'entries': [
              {
                ..._entry(3, 'V3-PRIMARY', keys: ['Q']),
                'use_regex': true,
                'secondary_keys': ['Q', '['],
                'selective': true,
                'extensions': {'selectiveLogic': 2},
              },
            ],
          },
        }),
      );
      final v3Preview = await h.engine.previewCharacterBook(v3Character.id, 'Q');
      expect(_hits(v3Preview).map((hit) => hit['uid']), ['3']);
      expect(_hits(v3Preview).single['content'], 'V3-PRIMARY');
      expect(v3Preview['regexDiagnostics'], isNull);

      // Native selective logic recognizes /[/ as a literal shape, then T21
      // protection treats its compile failure as indeterminate, never false.
      final character = await h.engine.importCard(
        _card({
          'character_book': {
            'entries': [
              {
                ..._entry(1, 'MUST-NOT-ACTIVATE', keys: ['Q']),
                'use_regex': false,
                'secondary_keys': ['/[/'],
                'selective': true,
                'extensions': {'selectiveLogic': 2},
              },
              {
                ..._entry(2, 'SAFE {{incvar::n}}', keys: ['Q']),
                'use_regex': true,
              },
            ],
          },
        }),
      );
      final chat = await h.importChat(character.id, [_row('G')], variables: {'n': 4});
      final before = await _snapshot(h.engine, chat);
      final report = File('${h.directory.path}/characters/${character.id}/import-report.json');
      final reportBefore = await report.readAsBytes();
      final preview = await h.engine.previewCharacterBook(character.id, 'Q', chatId: chat);
      expect(_hits(preview).map((hit) => hit['uid']), ['2']);
      expect(_hits(preview).single['content'], 'SAFE 5');
      final warnings = (preview['regexDiagnostics']! as List<Object?>).map(_map).toList();
      expect(warnings.single['uid'], '1');
      expect(warnings.single['keyPath'], 'secondary_keys[0]');
      expect(warnings.single['code'], 'incompatible-pattern');
      expect(await _snapshot(h.engine, chat), before);
      expect(h.engine.variables(chat), {'n': 4});
      expect(await report.readAsBytes(), orderedEquals(reportBefore));
      await h.engine.updateCharacterBookEntry(character.id, 0, {
        'secondary_keys': ['/absent/'],
      });
      final repaired = await h.engine.previewCharacterBook(character.id, 'Q', chatId: chat);
      expect(_hits(repaired).map((hit) => hit['uid']), unorderedEquals(['1', '2']));
      expect(repaired['regexDiagnostics'], isNull);
      expect(await _snapshot(h.engine, chat), before);
      expect(h.engine.variables(chat), {'n': 4});
      expect(await report.readAsBytes(), orderedEquals(reportBefore));
      expect(await h.engine.inspectTurn(chat), isNull);
      expect(h.model.bodies, isEmpty);
    },
  );

  test('preview keeps card-only scope when a bound world book competes for the same group', () async {
    final h = await _open();
    final character = await h.engine.importCard(
      _card({
        'character_book': {
          'entries': [
            _entry(1, 'CARD', constant: true, extensions: {'group': 'collision'}),
          ],
        },
      }),
    );
    await h.engine.putLorebook('bound', {
      'entries': {
        '0': {
          'uid': 0,
          'constant': true,
          'content': 'BOUND',
          'position': 0,
          'group': 'collision',
          'group_override': true,
          'order': 1,
        },
      },
    });
    await h.engine.bindLorebooks(['bound']);
    final chat = await h.engine.createChat(character.id);
    final preview = await h.engine.previewCharacterBook(character.id, 'Q', chatId: chat);
    expect(preview['scope'], 'character-book');
    expect(_hits(preview).single['content'], 'CARD');
    expect(_hits(preview).single['bookId'], '${character.id}:card');
    expect(h.model.bodies, isEmpty);
  });

  test('failed preview discards macro effects even when a later regex throws', () async {
    final h = await _open();
    final character = await h.engine.importCard(
      _card({
        'character_book': {
          'entries': [_entry(1, '{{incvar::n}}{{incglobalvar::g}}x', constant: true)],
        },
      }),
    );
    final chat = await h.importChat(character.id, [_row('G')], variables: {'n': 4});
    await h.engine.setGlobalVariables({'g': 7});
    await h.engine.setSettings({
      'globalRegexScripts': [
        _script('bad', '(?<n>x)', r'$4', [5], prompt: true),
      ],
    });
    final before = await _snapshot(h.engine, chat);
    await expectLater(h.engine.previewCharacterBook(character.id, 'Q', chatId: chat), throwsStateError);
    expect(h.engine.variables(chat), {'n': 4});
    expect(h.engine.globalVariables, {'g': 7});
    expect(await _snapshot(h.engine, chat), before);
    expect(await h.engine.inspectTurn(chat), isNull);
    expect(h.model.bodies, isEmpty);
  });

  test('preview runs user regex before matching and WI regex after recursion like a real turn', () async {
    final h = await _open();
    final character = await h.engine.importCard(
      _card({
        'character_book': {
          'entries': [
            _entry(1, 'RAW', keys: ['beacon']),
            _entry(2, 'UNEXPECTED', keys: ['POST']),
          ],
        },
      }),
    );
    await h.engine.setSettings({
      'worldInfo': {'world_info_recursive': true},
      'globalRegexScripts': [
        _script('input', r'^token$', 'beacon', [1]),
        _script('world', r'^RAW$', 'POST', [5], prompt: true),
      ],
    });
    final preview = await h.engine.previewCharacterBook(character.id, 'token');
    expect(_hits(preview).map((hit) => hit['uid']), ['1']);
    expect(_hits(preview).single['content'], 'POST');
    expect(await h.engine.watchChats().first, isEmpty);
    expect(h.model.bodies, isEmpty);
    final chat = await h.engine.createChat(character.id);
    final events = await h.engine.send(chat, 'token').toList();
    expect(events.whereType<TavernTurnFailed>(), isEmpty);
    final actualTrace = _map(h.engine.inspect(chat)!.toJson()['worldInfo']);
    expect(_hits(actualTrace), _hits(preview));
    expect((await h.engine.path(chat))[1].text, 'beacon');
  });

  test('preview during a streamed turn neither cancels it nor overwrites its inspection', () async {
    final h = await _open();
    final character = await h.engine.importCard(
      _card({
        'character_book': {
          'entries': [_entry(1, 'WORLD', constant: true)],
        },
      }),
    );
    final chat = await h.engine.createChat(character.id);
    final held = h.model.hold();
    final running = h.engine.send(chat, 'Q').toList();
    await held.listening.future;
    final before = (await h.engine.inspectTurn(chat))!.toJson();
    await h.engine.updateCharacterBookEntry(character.id, 0, {'content': 'NEXT-WORLD'});
    final preview = await h.engine.previewCharacterBook(character.id, 'NEXT', chatId: chat);
    expect(_hits(preview).single['content'], 'NEXT-WORLD');
    expect(h.model.bodies, hasLength(1));
    expect(h.model.cancellations.single.isCancelled, isFalse);
    expect((await h.engine.inspectTurn(chat))!.toJson(), before);
    held.source.add(const ModelText('DONE'));
    held.source.add(const ModelFinished('stop'));
    await held.source.close();
    final events = await running;
    expect(events.whereType<TavernTurnFailed>(), isEmpty);
    expect(events.whereType<TavernTurnDone>().single.message.text, 'DONE');
    expect(h.engine.inspect(chat)!.worldInfo.activated.single.content, 'WORLD');
    final next = await h.engine.send(chat, 'Q again').toList();
    expect(next.whereType<TavernTurnFailed>(), isEmpty);
    expect(h.engine.inspect(chat)!.worldInfo.activated.single.content, 'NEXT-WORLD');
  }, timeout: const Timeout(Duration(seconds: 15)));
}

final _at = DateTime.utc(2026, 11, 10, 12);

Future<(_Harness, String)> _plainCaseBook(String key, String content) async {
  final h = await _open();
  final character = await h.engine.importCard(_card());
  await h.engine.setPreset(
    ChatPreset({...ChatPreset.stDefault().raw, 'openai_max_context': 4096, 'openai_max_tokens': 256}),
  );
  await h.engine.setSettings({
    'worldInfo': {
      'world_info_depth': 1,
      'world_info_budget': 50,
      'world_info_include_names': false,
      'world_info_recursive': false,
      'world_info_case_sensitive': false,
      'world_info_match_whole_words': false,
    },
  });
  await h.engine.addCharacterBookEntry(character.id, {
    'keys': [key],
    'content': content,
    'enabled': true,
    'constant': false,
    'selective': false,
    'use_regex': false,
    'case_sensitive': false,
    'extensions': {'useProbability': false, 'match_whole_words': false},
  });
  return (h, character.id);
}

Future<_Harness> _open({double Function()? random}) async {
  final directory = await Directory.systemTemp.createTemp('dsh-t16-book-');
  final model = _Model();
  final config = TavernModelConfig(apiKey: () async => 'fixture-only', model: 'fixture');
  final draw = random ?? () => 0.25;
  final engine = await TavernEngine.openDirectory(
    directory,
    config: config,
    modelClient: model,
    clock: () => _at,
    random: draw,
  );
  final h = _Harness(directory, config, model, engine, draw);
  addTearDown(h.dispose);
  return h;
}

class _Harness {
  _Harness(this.directory, this.config, this.model, this.engine, this.random);
  final Directory directory;
  final TavernModelConfig config;
  final _Model model;
  TavernEngine engine;
  final double Function() random;

  Future<String> importChat(
    String characterId,
    List<Map<String, Object?>> rows, {
    Map<String, Object?> variables = const {},
  }) async {
    final document = StChatDocument(
      fileName: 'main.jsonl',
      header: {
        'user_name': 'User',
        'character_name': 'Guide',
        'chat_metadata': {'variables': variables},
      },
      messages: rows,
    );
    return (await engine.importChats(characterId, [
      TavernChatFile(fileName: document.fileName, bytes: document.encode()),
    ])).chatIds.single;
  }

  Future<void> reopen() async {
    await engine.close();
    engine = await TavernEngine.openDirectory(
      directory,
      config: config,
      modelClient: model,
      clock: () => _at,
      random: random,
    );
  }

  Future<void> dispose() async {
    await engine.close();
    for (final value in model.held) {
      if (!value.source.isClosed) {
        unawaited(value.source.close());
      }
    }
    await directory.delete(recursive: true);
  }
}

class _Held {
  _Held() {
    source = StreamController<ModelDelta>(sync: true, onListen: listening.complete);
  }
  final listening = Completer<void>();
  late final StreamController<ModelDelta> source;
}

class _Model extends TavernModelClient {
  final bodies = <Map<String, Object?>>[];
  final cancellations = <ModelCancellation>[];
  final held = <_Held>[];
  _Held? next;

  _Held hold() {
    final value = _Held();
    held.add(value);
    next = value;
    return value;
  }

  @override
  Stream<ModelDelta> generate({
    required TavernModelConfig config,
    required Map<String, Object?> body,
    required ModelCancellation cancellation,
    void Function(int attempt)? onRequestStarted,
  }) {
    bodies.add(_map(body));
    cancellations.add(cancellation);
    final waiting = next;
    next = null;
    return waiting?.source.stream ?? Stream.fromIterable(const [ModelText('OK'), ModelFinished('stop')]);
  }
}

Map<String, Object?> _map(Object? value) =>
    value is Map<String, Object?> ? jsonDecode(jsonEncode(value)) as Map<String, Object?> : {};
Future<Map<String, Object?>> _snapshot(TavernEngine engine, String chat) async {
  final file = (await engine.exportChat(chat, fileName: 'snapshot.jsonl')).first;
  final document = StChatDocument.decode(file.fileName, file.bytes);
  final metadata = _map(document.header['chat_metadata'])..remove('integrity');
  return {'metadata': metadata, 'messages': document.messages};
}

List<Map<String, Object?>> _hits(Map<String, Object?> value) =>
    (value['activated']! as List<Object?>).map(_map).toList();
Future<List<Map<String, Object?>>> _entries(TavernEngine engine, String characterId) async =>
    (_map((await engine.characterFields(characterId))!['character_book'])['entries']! as List<Object?>)
        .map(_map)
        .toList();
Map<String, Object?> _entry(
  int id,
  String content, {
  List<String> keys = const [],
  bool constant = false,
  Map<String, Object?> extensions = const {},
}) => {
  'id': id,
  'keys': keys,
  'content': content,
  'enabled': true,
  'constant': constant,
  'insertion_order': 100,
  'position': 'before_char',
  'extensions': extensions,
};
Map<String, Object?> _row(String text, {bool user = false, bool hidden = false}) => {
  'name': user ? 'User' : 'Guide',
  'is_user': user,
  'is_system': hidden,
  'send_date': _at.toIso8601String(),
  'mes': text,
};
Map<String, Object?> _script(
  String id,
  String pattern,
  String replacement,
  List<int> placements, {
  bool prompt = false,
}) => {
  'id': id,
  'scriptName': id,
  'findRegex': pattern,
  'replaceString': replacement,
  'placement': placements,
  'promptOnly': prompt,
  'markdownOnly': false,
  'disabled': false,
  'runOnEdit': false,
  'substituteRegex': 0,
  'trimStrings': <String>[],
};
Uint8List _card([Map<String, Object?> fields = const {}]) => Uint8List.fromList(
  utf8.encode(
    jsonEncode({
      'spec': 'chara_card_v3',
      'spec_version': '3.0',
      'data': {
        'name': 'Guide',
        'description': '',
        'personality': '',
        'scenario': '',
        'first_mes': 'G',
        'mes_example': '',
        'creator_notes': '',
        'system_prompt': '',
        'post_history_instructions': '',
        'alternate_greetings': <String>[],
        'tags': <String>[],
        'creator': '',
        'character_version': '',
        'extensions': <String, Object?>{},
        ...fields,
      },
    }),
  ),
);

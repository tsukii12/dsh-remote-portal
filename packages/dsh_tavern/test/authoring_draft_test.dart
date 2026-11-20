import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import 'support/t24_engine_harness.dart' show T24Model, t24Card;

// Real engine, SQLite, resource files and regex worker. The lifecycle cases
// delay one genuine File read; no authoring implementation or worker is faked.
const _deadline = Duration(seconds: 10);
const _regexTarget = TavernAuthoringTarget(kind: TavernAuthoringTargetKind.regexLibrary, id: 'global');

void main() {
  test('saved card and book bases retain raw BOM, complete envelopes, missing fields and media on reopen', () async {
    final h = await _open();
    final character = await h.engine.importCard(t24Card());
    final cardFile = h.cardFile(character.id);
    final card = _map(jsonDecode(await cardFile.readAsString()));
    final data = _map(card['data'])..remove('description');
    data['character_book'] = {
      'entries': [
        {
          'keys': ['harbor'],
          'content': 'A quiet harbor.',
          'vendorEntry': {'keep': null},
        },
      ],
      'vendorBook': [1, 'kept'],
    };
    card['vendorEnvelope'] = {
      'nested': [null, true, '保留'],
    };
    final cardText = '\uFEFF${jsonEncode(card)}';
    await cardFile.writeAsBytes(utf8.encode(cardText));
    final directory = cardFile.parent;
    final identityFile = File('${directory.path}/library.json');
    final identity = _map(jsonDecode(await identityFile.readAsString()))..['resources'] = ['notes.txt'];
    final identityText = '\uFEFF${jsonEncode(identity)}';
    await identityFile.writeAsBytes(utf8.encode(identityText));
    final asset = File('${directory.path}/resources/notes.txt');
    await asset.parent.create(recursive: true);
    await asset.writeAsString('Retained media reference.');
    final original = File('${directory.path}/original.json');
    final originalBytes = await original.readAsBytes();

    await h.engine.putLorebook('harbor', {'entries': <String, Object?>{}});
    final bookFile = File('${h.root.path}/lorebooks/harbor.json');
    final book = <String, Object?>{
      'format': 'dshgo-lorebook',
      'version': 1,
      'stWorldName': 'Harbor',
      'book': {
        'entries': {
          '7': {
            'key': ['dock'],
            'content': 'Wooden piers.',
            'vendorEntry': 9,
          },
        },
      },
      'vendorEnvelope': {
        'keep': [false, null],
      },
    };
    final bookText = '\uFEFF${jsonEncode(book)}';
    await bookFile.writeAsBytes(utf8.encode(bookText));
    final draft = await h.engine.createAuthoringDraft([
      _character(character.id),
      const TavernAuthoringTarget(kind: TavernAuthoringTargetKind.lorebook, id: 'harbor'),
    ]);
    final resource = 'character:${character.id}';
    expect(_source(draft, resource).base, card);
    expect(_source(draft, resource).mediaRefs, ['notes.txt']);
    expect(_source(draft, resource).sourceFormat, 'json');
    expect(_source(draft, 'lorebook:harbor').base, book);
    expect(_source(draft, 'lorebook:harbor').sourceFormat, 'dshgo-lorebook');
    for (final source in draft.sources) {
      expect(source.applySupported, isTrue);
      expect(source.authorityRevision, isNotNull);
    }

    final edited = await h.engine.editAuthoringDraft(
      draft.id,
      draftRevision: draft.draftRevision,
      changes: [_set('name', resource, '/data/name', 'Harbor guide')],
    );
    await h.reopen();
    final restored = (await h.engine.readAuthoringDraft(draft.id))!;
    expect(restored.draftRevision, edited.draftRevision);
    expect(_source(restored, resource).base, card);
    expect(_source(restored, 'lorebook:harbor').base, book);
    expect(_source(restored, resource).authorityRevision, _source(draft, resource).authorityRevision);
    expect(_source(restored, 'lorebook:harbor').authorityRevision, _source(draft, 'lorebook:harbor').authorityRevision);
    expect(_map(_source(restored, resource).base['data']).containsKey('description'), isFalse);
    final savedSources = _savedAuthoringSources(h.root, draft.id);
    expect(_map(savedSources.first)['rawText'], cardText);
    expect(_map(savedSources.first)['identityText'], identityText);
    expect(_map(savedSources.last)['rawText'], bookText);
    final preview = await h.engine.previewAuthoringDraft(
      restored.id,
      draftRevision: restored.draftRevision,
      changeIds: ['name'],
    );
    final expected = _map(jsonDecode(jsonEncode(card)));
    _map(expected['data'])['name'] = 'Harbor guide';
    expect(preview.candidates[resource], expected);
    expect(preview.candidates['lorebook:harbor'], book);
    expect(preview.issues, isEmpty);
    expect(await cardFile.readAsBytes(), utf8.encode(cardText));
    expect(await bookFile.readAsBytes(), utf8.encode(bookText));
    expect(await identityFile.readAsBytes(), utf8.encode(identityText));
    expect(await original.readAsBytes(), originalBytes);
    expect(await asset.readAsString(), 'Retained media reference.');
  });

  test('preset and regex drafts capture current raw while preserving archived source and unknown fields', () async {
    final h = await _open();
    final wrapper = <String, Object?>{
      'format': 'dsh-preset-enhance',
      'version': 1,
      'metadata': {'name': 'Package', 'unknown': 7},
      'preset': {
        'format': 'sillytavern',
        'data': {'temperature': 0.2},
        'wrapperUnknown': 3,
      },
      'prefill': {
        'enabled': false,
        'toolCalls': true,
        'removeNonOfficialTools': false,
        'postToolPrefix': {'mode': 'inherit', 'text': ''},
        'foreign': 8,
      },
      'tools': {
        'version': 99,
        'future': [true, null],
      },
      'outerUnknown': {
        'keep': [1, 2],
      },
    };
    final sourceText = jsonEncode(wrapper);
    final preset = (await h.engine.importPreset(sourceText)).preset;
    await h.engine.updatePreset(preset.id, {'temperature': 0.8, 'foreign': 'current'});
    final scriptText = jsonEncode(_script('Original', r'/^cat$/i'));
    final script = (await h.engine.importRegexScripts(scriptText)).scripts.single;
    await h.engine.updateRegexScript(script.id, {'findRegex': r'/^dog$/i'});
    final regexFile = File('${h.root.path}/regex-library.json');
    final regex = _map(jsonDecode(await regexFile.readAsString()))..['outerUnknown'] = {'keep': true};
    final regexText = '\uFEFF${jsonEncode(regex)}';
    await regexFile.writeAsBytes(utf8.encode(regexText));
    final database = sqlite3.open('${h.root.path}/tavern.sqlite3');
    late final Map<String, Object?> report;
    try {
      final row = database.select('SELECT import_report_json FROM presets WHERE id = ?', [preset.id]).single;
      report = _map(jsonDecode(row['import_report_json'] as String))..['futureReportField'] = [null, 'kept'];
      database.execute('UPDATE presets SET import_report_json = ? WHERE id = ?', [jsonEncode(report), preset.id]);
    } finally {
      database.close();
    }

    final draft = await h.engine.createAuthoringDraft([
      TavernAuthoringTarget(kind: TavernAuthoringTargetKind.preset, id: preset.id),
      _regexTarget,
    ]);
    await h.reopen();
    final restored = (await h.engine.readAuthoringDraft(draft.id))!;
    final current = _source(restored, 'preset:${preset.id}');
    expect(current.sourceFormat, 'dsh-preset-enhance');
    expect(_map(current.base['raw']), {
      'temperature': 0.8,
      'foreign': 'current',
      'extensions': {
        'dshgo': {
          'prefill': {'enabled': false, 'target': 'content'},
        },
      },
    });
    expect(current.base['sourceText'], sourceText);
    expect(_map(current.base['envelope'])['outerUnknown'], wrapper['outerUnknown']);
    expect(_map(_map(current.base['envelope'])['preset'])['wrapperUnknown'], 3);
    expect(current.base['importReport'], report);
    final regexSource = _source(restored, 'regex-library');
    expect(regexSource.base, regex);
    expect(_map(_savedAuthoringSources(h.root, draft.id).last)['rawText'], regexText);
    final record = _map((regexSource.base['scripts']! as List<Object?>).single);
    expect(_map(record['raw'])['findRegex'], r'/^dog$/i');
    expect(record['sourceText'], scriptText);
    final preview = await h.engine.previewAuthoringDraft(
      restored.id,
      draftRevision: restored.draftRevision,
      changeIds: [],
    );
    expect(preview.candidates['regex-library'], regex);
    expect(preview.candidates['preset:${preset.id}'], current.base);
    expect(preview.diffs, isEmpty);
    expect(await regexFile.readAsBytes(), utf8.encode(regexText));
  });

  test('entry captures mutable inputs and stale edit or delete cannot replace a newer draft', () async {
    final h = await _open();
    final character = await h.engine.importCard(t24Card());
    final targets = [_character(character.id)];
    final creating = h.engine.createAuthoringDraft(targets);
    targets.clear();
    final draft = await creating;
    expect(draft.sources.single.target.id, character.id);
    final resource = 'character:${character.id}';
    final value = <String, Object?>{
      'nested': <String, Object?>{'saved': 1},
    };
    final changes = [_set('extension', resource, '/data/extensions/vendor', value)];
    final editing = h.engine.editAuthoringDraft(draft.id, draftRevision: draft.draftRevision, changes: changes);
    _map(value['nested'])['saved'] = 999;
    changes.clear();
    final stale = h.engine.editAuthoringDraft(
      draft.id,
      draftRevision: draft.draftRevision,
      changes: [_set('stale', resource, '/data/name', 'stale')],
    );
    final rejected = expectLater(stale, _authoringFailure('revision_conflict'));
    final edited = await editing;
    await rejected;
    expect(edited.draftRevision, draft.draftRevision + 1);
    expect(edited.changes.single.value, {
      'nested': {'saved': 1},
    });
    _map(_map(edited.changes.single.value)['nested'])['saved'] = 888;
    final reread = (await h.engine.readAuthoringDraft(draft.id))!;
    expect(reread.changes.single.value, {
      'nested': {'saved': 1},
    });
    final listed = (await h.engine.listAuthoringDrafts()).single;
    expect(listed.id, draft.id);
    expect(listed.draftRevision, edited.draftRevision);
    expect(listed.targets.single.physicalResourceId, resource);
    await expectLater(
      h.engine.deleteAuthoringDraft(draft.id, draftRevision: draft.draftRevision),
      _authoringFailure('revision_conflict'),
    );
    expect(await h.engine.readAuthoringDraft(draft.id), isNotNull);
    await h.engine.deleteAuthoringDraft(draft.id, draftRevision: edited.draftRevision);
    expect(await h.engine.readAuthoringDraft(draft.id), isNull);
    expect(await h.engine.listAuthoringDrafts(), isEmpty);
  });

  test('a stored forward dependency is rejected at decode even when every change is selected', () async {
    final h = await _open();
    final character = await h.engine.importCard(t24Card());
    final resource = 'character:${character.id}';
    final cardText = await h.cardFile(character.id).readAsString();
    final draft = await h.engine.createAuthoringDraft([_character(character.id)]);
    final edited = await h.engine.editAuthoringDraft(
      draft.id,
      draftRevision: draft.draftRevision,
      changes: [
        _set('first', resource, '/data/description', 'Draft description'),
        _set('later', resource, '/data/name', 'Draft name'),
      ],
    );
    await h.engine.close();
    final database = sqlite3.open('${h.root.path}/tavern.sqlite3');
    try {
      final row = database.select('SELECT data_json FROM authoring_drafts WHERE id = ?', [draft.id]).single;
      final data = _map(jsonDecode(row['data_json'] as String));
      _map((data['changes']! as List<Object?>).first)['dependsOn'] = ['later'];
      database.execute('UPDATE authoring_drafts SET data_json = ? WHERE id = ?', [jsonEncode(data), draft.id]);
    } finally {
      database.close();
    }
    await h.open();
    await expectLater(h.engine.readAuthoringDraft(draft.id), _authoringFailure('invalid_change'));
    await expectLater(
      h.engine.previewAuthoringDraft(draft.id, draftRevision: edited.draftRevision, changeIds: ['first', 'later']),
      _authoringFailure('invalid_change'),
    );
    expect(await h.cardFile(character.id).readAsString(), cardText);
  });

  test('rebase is explicit and loses its CAS when an edit wins during the real source read', () async {
    final h = await _open();
    final character = await h.engine.importCard(t24Card());
    final resource = 'character:${character.id}';
    final draft = await h.engine.createAuthoringDraft([_character(character.id)]);
    await h.engine.updateCharacterFields(character.id, {'name': 'Current name'});
    expect(_map(_source((await h.engine.readAuthoringDraft(draft.id))!, resource).base['data'])['name'], 'Guide');
    final gate = _ReadGate();
    await _withReadGate(h.cardFile(character.id), gate, () async {
      final rebasing = h.engine.rebaseAuthoringDraft(
        draft.id,
        draftRevision: draft.draftRevision,
        changes: [_set('loser', resource, '/data/name', 'Losing rebase')],
      );
      final rejected = expectLater(rebasing, _authoringFailure('revision_conflict'));
      await gate.entered.future.timeout(_deadline);
      final winner = await h.engine.editAuthoringDraft(
        draft.id,
        draftRevision: draft.draftRevision,
        changes: [_set('winner', resource, '/data/name', 'Saved edit')],
      );
      gate.release();
      await rejected;
      final saved = (await h.engine.readAuthoringDraft(draft.id))!;
      expect(saved.draftRevision, winner.draftRevision);
      expect(saved.changes.single.id, 'winner');
      expect(_map(_source(saved, resource).base['data'])['name'], 'Guide');
      final rebased = await h.engine.rebaseAuthoringDraft(draft.id, draftRevision: saved.draftRevision, changes: []);
      expect(rebased.draftRevision, saved.draftRevision + 1);
      expect(rebased.changes, isEmpty);
      expect(_map(_source(rebased, resource).base['data'])['name'], 'Current name');
    });
  });

  test('selection respects saved dependency order and diffs distinguish missing keys from null', () async {
    final h = await _open();
    final character = await h.engine.importCard(
      _cardWithExtensions({
        'removeMe': null,
        'a/b': {'~key': 'old'},
      }),
    );
    final original = await h.cardFile(character.id).readAsString();
    final resource = 'character:${character.id}';
    final draft = await h.engine.createAuthoringDraft([_character(character.id)]);
    final parent = _set('parent', resource, '/data/extensions/branch', {'leaf': 0});
    await expectLater(
      h.engine.editAuthoringDraft(
        draft.id,
        draftRevision: draft.draftRevision,
        changes: [parent, _set('child', resource, '/data/extensions/branch/leaf', 1)],
      ),
      _authoringFailure('invalid_change'),
    );
    expect((await h.engine.readAuthoringDraft(draft.id))!.draftRevision, draft.draftRevision);
    final edited = await h.engine.editAuthoringDraft(
      draft.id,
      draftRevision: draft.draftRevision,
      changes: [
        parent,
        _set('child', resource, '/data/extensions/branch/leaf', 1, dependsOn: ['parent']),
        TavernAuthoringChange(
          id: 'remove',
          physicalResourceId: resource,
          path: '/data/extensions/removeMe',
          operation: TavernAuthoringChangeKind.remove,
        ),
        _set('null', resource, '/data/extensions/nullable', null),
        _set('escaped', resource, '/data/extensions/a~1b/~0key', 'new'),
      ],
    );
    await expectLater(
      h.engine.previewAuthoringDraft(edited.id, draftRevision: edited.draftRevision, changeIds: ['child']),
      _authoringFailure('missing_dependency'),
    );
    final selection = ['escaped', 'null', 'remove', 'child', 'parent'];
    final previewing = h.engine.previewAuthoringDraft(
      edited.id,
      draftRevision: edited.draftRevision,
      changeIds: selection,
    );
    selection.clear();
    final preview = await previewing;
    expect(preview.changeIds, ['parent', 'child', 'remove', 'null', 'escaped']);
    final extensions = _map(_map(preview.candidates[resource]!['data'])['extensions']);
    expect(extensions, {
      'branch': {'leaf': 1},
      'nullable': null,
      'a/b': {'~key': 'new'},
    });
    final diffs = {for (final diff in preview.diffs) diff.changeId: diff};
    expect(diffs['parent']!.beforeExists, isFalse);
    expect(diffs['parent']!.after, {'leaf': 0}, reason: 'The later child change must not rewrite an earlier diff.');
    expect(diffs['child']!.before, 0);
    expect(diffs['child']!.after, 1);
    expect(diffs['remove']!.beforeExists, isTrue);
    expect(diffs['remove']!.before, isNull);
    expect(diffs['remove']!.afterExists, isFalse);
    expect(diffs['null']!.beforeExists, isFalse);
    expect(diffs['null']!.afterExists, isTrue);
    expect(diffs['null']!.after, isNull);
    expect(await h.cardFile(character.id).readAsString(), original);
  });

  test('static preview keeps malformed drafts editable and never adopts content or evaluates macros', () async {
    final h = await _open();
    final character = await h.engine.importCard(t24Card());
    final chat = await h.engine.createChat(character.id);
    await h.engine.setGlobalVariables({'counter': 3});
    final nodes = (await h.engine.path(chat)).map((message) => message.nodeId).toList();
    final cardFile = h.cardFile(character.id);
    final reportFile = File('${cardFile.parent.path}/import-report.json');
    final cardText = await cardFile.readAsString();
    final reportText = await reportFile.readAsString();
    final resource = 'character:${character.id}';
    final draft = await h.engine.createAuthoringDraft([_character(character.id)]);
    final macro = _set('description', resource, '/data/description', '{{incglobalvar::counter}}');
    final valid = await h.engine.editAuthoringDraft(draft.id, draftRevision: draft.draftRevision, changes: [macro]);
    final checked = await h.engine.previewAuthoringDraft(
      valid.id,
      draftRevision: valid.draftRevision,
      changeIds: ['description'],
    );
    expect(_map(checked.candidates[resource]!['data'])['description'], '{{incglobalvar::counter}}');
    expect(checked.issues, isEmpty);
    expect(checked.reports[resource], hasLength(1));
    final malformed = await h.engine.editAuthoringDraft(
      draft.id,
      draftRevision: valid.draftRevision,
      changes: [macro, _set('spec', resource, '/spec', 'unfinished-spec')],
    );
    final lint = await h.engine.previewAuthoringDraft(
      malformed.id,
      draftRevision: malformed.draftRevision,
      changeIds: ['description', 'spec'],
    );
    expect(lint.candidates[resource]!['spec'], 'unfinished-spec');
    expect(lint.issues[resource]!.single.code, 'invalid-source');
    expect((await h.engine.readAuthoringDraft(draft.id))!.changes, hasLength(2));
    expect(await cardFile.readAsString(), cardText);
    expect(await reportFile.readAsString(), reportText);
    expect(h.engine.globalVariables, {'counter': 3});
    expect((await h.engine.path(chat)).map((message) => message.nodeId), nodes);
    expect(await h.engine.inspectTurn(chat), isNull);
  });

  test('regex samples compile and match the selected draft pattern without changing the live library', () async {
    final h = await _open();
    await h.engine.importRegexScripts(jsonEncode(_script('Pattern', r'/^cat$/i')));
    final file = File('${h.root.path}/regex-library.json');
    final original = await file.readAsString();
    final draft = await h.engine.createAuthoringDraft([_regexTarget]);
    final edited = await h.engine.editAuthoringDraft(
      draft.id,
      draftRevision: draft.draftRevision,
      changes: [_set('pattern', 'regex-library', '/scripts/0/raw/findRegex', r'/^dog$/i')],
    );
    final matched = await h.engine.testAuthoringRegex(
      edited.id,
      draftRevision: edited.draftRevision,
      changeIds: ['pattern'],
      physicalResourceId: 'regex-library',
      scriptPath: '/scripts/0/raw',
      text: 'DOG',
    );
    final missed = await h.engine.testAuthoringRegex(
      edited.id,
      draftRevision: edited.draftRevision,
      changeIds: ['pattern'],
      physicalResourceId: 'regex-library',
      scriptPath: '/scripts/0/raw',
      text: 'cat',
    );
    expect(matched.compilation.status, RegexCompileStatus.compatible);
    expect(matched.match!.status, RegexMatchStatus.matched);
    expect(missed.compilation.status, RegexCompileStatus.compatible);
    expect(missed.match!.status, RegexMatchStatus.notMatched);
    expect(await file.readAsString(), original);
  });

  test('regex compile failure and runtime-macro skip both remain distinct from an executed non-match', () async {
    final h = await _open();
    await h.engine.setGlobalVariables({'counter': 3});
    await h.engine.importRegexScripts(jsonEncode([_script('Invalid', 'cat'), _script('Runtime', 'dog')]));
    final file = File('${h.root.path}/regex-library.json');
    final original = await file.readAsString();
    final draft = await h.engine.createAuthoringDraft([_regexTarget]);
    final edited = await h.engine.editAuthoringDraft(
      draft.id,
      draftRevision: draft.draftRevision,
      changes: [
        _set('invalid', 'regex-library', '/scripts/0/raw/findRegex', '/[/'),
        _set('macro', 'regex-library', '/scripts/1/raw/findRegex', '{{incglobalvar::counter}}'),
        _set('runtime', 'regex-library', '/scripts/1/raw/substituteRegex', 1),
      ],
    );
    final invalid = await h.engine.testAuthoringRegex(
      edited.id,
      draftRevision: edited.draftRevision,
      changeIds: ['invalid'],
      physicalResourceId: 'regex-library',
      scriptPath: '/scripts/0/raw',
      text: 'cat',
    );
    final skipped = await h.engine.testAuthoringRegex(
      edited.id,
      draftRevision: edited.draftRevision,
      changeIds: ['macro', 'runtime'],
      physicalResourceId: 'regex-library',
      scriptPath: '/scripts/1/raw',
      text: '3',
    );
    expect(invalid.compilation.status, RegexCompileStatus.incompatible);
    expect(invalid.match, isNull);
    expect(skipped.compilation.status, RegexCompileStatus.skipped);
    expect(skipped.compilation.code, 'runtime-check');
    expect(skipped.match, isNull);
    expect(h.engine.globalVariables, {'counter': 3});
    expect(await file.readAsString(), original);
  });

  test('close retains ownership until an admitted authoring read and its draft commit finish', () async {
    final h = await _open();
    final character = await h.engine.importCard(t24Card());
    final gate = _ReadGate();
    await _withReadGate(h.cardFile(character.id), gate, () async {
      final creating = _handled(h.engine.createAuthoringDraft([_character(character.id)]));
      await gate.entered.future.timeout(_deadline);
      var closed = false;
      final closing = _handled(
        h.engine.close().then((_) {
          closed = true;
          expect(gate.finished.isCompleted, isTrue);
        }),
      );
      await _expectReserved(h.root);
      expect(closed, isFalse);
      gate.release();
      final draft = await creating.timeout(_deadline);
      await closing.timeout(_deadline);
      expect(closed, isTrue);
      await h.reopen();
      expect((await h.engine.readAuthoringDraft(draft.id))!.sources.single.target.id, character.id);
    });
  });

  test('backup waits for an admitted source read and restores the resulting persisted draft', () async {
    final h = await _open();
    final character = await h.engine.importCard(t24Card());
    final gate = _ReadGate();
    final copiedAfterRead = <bool>[];
    gate.onCopy = () => copiedAfterRead.add(gate.finished.isCompleted);
    final archive = File('${h.work.path}/draft.zip');
    await _withReadGate(h.cardFile(character.id), gate, () async {
      final creating = _handled(h.engine.createAuthoringDraft([_character(character.id)]));
      await gate.entered.future.timeout(_deadline);
      final backingUp = _handled(h.engine.backup(archive.path));
      expect(gate.finished.isCompleted, isFalse);
      gate.release();
      final draft = await creating.timeout(_deadline);
      final backup = await backingUp.timeout(_deadline);
      expect(copiedAfterRead, [true], reason: 'The actual snapshot copy must follow the admitted read.');
      expect(backup.fileCount, greaterThan(0));
      final restoredRoot = Directory('${h.work.path}/restored');
      await restoreTavernDirectory(archive.path, restoredRoot.path);
      final restored = await TavernEngine.openDirectory(restoredRoot);
      try {
        final saved = (await restored.readAuthoringDraft(draft.id))!;
        expect(saved.draftRevision, draft.draftRevision);
        expect(saved.sources.single.base, draft.sources.single.base);
        expect((await restored.listAuthoringDrafts()).single.id, draft.id);
      } finally {
        await restored.close();
      }
    });
  });
}

Map<String, Object?> _map(Object? value) => value! as Map<String, Object?>;

List<Object?> _savedAuthoringSources(Directory root, String draftId) {
  final database = sqlite3.open('${root.path}/tavern.sqlite3');
  try {
    final row = database.select('SELECT data_json FROM authoring_drafts WHERE id = ?', [draftId]).single;
    return _map(jsonDecode(row['data_json'] as String))['sources']! as List<Object?>;
  } finally {
    database.close();
  }
}

TavernAuthoringTarget _character(String id) => TavernAuthoringTarget(kind: TavernAuthoringTargetKind.character, id: id);

TavernAuthoringSource _source(TavernAuthoringDraft draft, String resource) =>
    draft.sources.singleWhere((source) => source.physicalResourceId == resource);

TavernAuthoringChange _set(
  String id,
  String resource,
  String path,
  Object? value, {
  List<String> dependsOn = const [],
}) => TavernAuthoringChange(
  id: id,
  physicalResourceId: resource,
  path: path,
  operation: TavernAuthoringChangeKind.set,
  value: value,
  dependsOn: dependsOn,
);

Matcher _authoringFailure(String code) =>
    throwsA(isA<TavernAuthoringException>().having((error) => error.code, 'code', code));

Map<String, Object?> _script(String name, String pattern) => {
  'scriptName': name,
  'findRegex': pattern,
  'replaceString': 'kept',
  'placement': [2],
  'substituteRegex': 0,
  'vendor': {'unknown': true},
};

Uint8List _cardWithExtensions(Map<String, Object?> extensions) {
  final card = _map(jsonDecode(utf8.decode(t24Card())));
  _map(card['data'])['extensions'] = extensions;
  return Uint8List.fromList(utf8.encode(jsonEncode(card)));
}

Future<_Harness> _open() async {
  final work = await Directory.systemTemp.createTemp('dsh-authoring-draft-');
  final h = _Harness(work);
  await h.open();
  addTearDown(() async {
    await h.engine.close();
    await h.work.delete(recursive: true);
    expect(h.model.generated, 0);
    expect(h.keyReads, 0);
  });
  return h;
}

class _Harness {
  _Harness(this.work) : root = Directory('${work.path}/tavern');
  final Directory work;
  final Directory root;
  final model = T24Model();
  late TavernEngine engine;
  var keyReads = 0;

  Future<void> open() async {
    engine = await TavernEngine.openDirectory(
      root,
      modelClient: model,
      config: TavernModelConfig(
        apiKey: () async {
          keyReads++;
          return 'fixture-key';
        },
      ),
      clock: () => DateTime.utc(2026, 11, 13, 12),
      random: () => 0.25,
    );
  }

  Future<void> reopen() async {
    await engine.close();
    await open();
  }

  File cardFile(String id) => File('${root.path}/characters/$id/card.json');
}

Future<T> _handled<T>(Future<T> future) {
  unawaited(future.then<void>((_) {}, onError: (Object _, StackTrace _) {}));
  return future;
}

Future<void> _expectReserved(Directory root) async {
  late final TavernEngine unexpected;
  try {
    unexpected = await TavernEngine.openDirectory(root);
  } on StateError {
    return;
  }
  await unexpected.close();
  fail('Close released the root while an admitted authoring read was still pending.');
}

Future<void> _withReadGate(File file, _ReadGate gate, Future<void> Function() body) async {
  final parent = Zone.current;
  final aliases = {file.absolute.uri, File(await file.resolveSymbolicLinks()).absolute.uri};
  try {
    await IOOverrides.runZoned(
      body,
      createFile: (path) {
        final real = parent.run(() => File(path));
        return aliases.contains(parent.run(() => real.absolute.uri)) ? _GatedFile(real, gate) : real;
      },
    );
  } finally {
    gate.release();
    if (gate.entered.isCompleted) await gate.finished.future;
  }
}

class _ReadGate {
  final entered = Completer<void>();
  final finished = Completer<void>();
  final _released = Completer<void>();
  void Function()? onCopy;

  void release() {
    if (!_released.isCompleted) _released.complete();
  }

  Future<T> read<T>(Future<T> Function() action) async {
    if (entered.isCompleted) return action();
    entered.complete();
    try {
      await _released.future;
      return await action();
    } finally {
      finished.complete();
    }
  }
}

class _GatedFile implements File {
  _GatedFile(this.real, this.gate);
  final File real;
  final _ReadGate gate;
  @override
  String get path => real.path;
  @override
  Uri get uri => real.uri;
  @override
  bool get isAbsolute => real.isAbsolute;
  @override
  File get absolute => real.absolute;
  @override
  Directory get parent => real.parent;
  @override
  Future<bool> exists() => real.exists();
  @override
  bool existsSync() => real.existsSync();
  @override
  Future<File> copy(String path) {
    gate.onCopy?.call();
    return real.copy(path);
  }

  @override
  Future<Uint8List> readAsBytes() => gate.read(real.readAsBytes);
  @override
  Future<String> readAsString({Encoding encoding = utf8}) => gate.read(() => real.readAsString(encoding: encoding));
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:dsh_tavern/src/io/tavern_backup.dart' as backup_io;
import 'package:test/test.dart';

import 'p2_slash_test_support.dart';

// Real engine, resource files, SQLite and existing script bridge. Faults act
// at actual file returns or SQL statements; no adoption result is supplied.
const _deadline = Duration(seconds: 10);

void main() {
  test('legacy saved bases require explicit rebase while regex and preset adoption stays unsupported', () async {
    final h = await slashFixture();
    const target = TavernAuthoringTarget(kind: TavernAuthoringTargetKind.lorebook, id: 'legacy');
    await h.engine.putLorebook(target.id, {'name': 'Before', 'entries': <String, Object?>{}});
    final draft = await _draft(h.engine, [target], [_set('name', target, '/name', 'After')]);
    final previousToken = _source(draft, target).authorityRevision!;
    // The exact version-1 source shape written by 2A had no authority token.
    await h.reopen(
      whileClosed: () async {
        h.inspect((db) {
          final row = db.select('SELECT data_json FROM authoring_drafts WHERE id = ?', [draft.id]).single;
          final data = scriptMap(jsonDecode(row['data_json'] as String));
          for (final source in data['sources']! as List<Object?>) {
            scriptMap(source).remove('authorityRevision');
          }
          db.execute('UPDATE authoring_drafts SET data_json = ? WHERE id = ?', [jsonEncode(data), draft.id]);
        }, writable: true);
      },
    );
    final legacy = (await h.engine.readAuthoringDraft(draft.id))!;
    expect(_source(legacy, target).applySupported, isFalse);
    expect(_source(legacy, target).authorityRevision, isNull);
    await expectLater(
      h.engine.applyAuthoringChanges(
        legacy.id,
        draftRevision: legacy.draftRevision,
        physicalResourceId: target.physicalResourceId,
        changeIds: ['name'],
        expectedAuthorityRevision: previousToken,
        operationId: 'legacy-denied',
      ),
      throwsA(_authoringError('unsupported_apply')),
    );
    expect(await h.engine.readAuthoringOperation('legacy-denied', domainId: previousToken.domainId), isNull);
    final rebased = await h.engine.rebaseAuthoringDraft(
      legacy.id,
      draftRevision: legacy.draftRevision,
      changes: legacy.changes,
    );
    expect(rebased.draftRevision, legacy.draftRevision + 1);
    expect(_source(rebased, target).applySupported, isTrue);
    expect((await _apply(h.engine, rebased, target, 'legacy-rebased')).committed, isTrue);
    expect((await h.engine.lorebook(target.id))!['name'], 'After');

    final preset = (await h.engine.importPreset(jsonEncode(scriptPreset().raw))).preset;
    final unsupported = [
      const TavernAuthoringTarget(kind: TavernAuthoringTargetKind.regexLibrary, id: 'global'),
      TavernAuthoringTarget(kind: TavernAuthoringTargetKind.preset, id: preset.id),
    ];
    final staticDraft = await h.engine.createAuthoringDraft(unsupported);
    for (final source in staticDraft.sources) {
      expect(source.applySupported, isFalse);
      expect(source.authorityRevision, isNull);
      await expectLater(
        h.engine.applyAuthoringChanges(
          staticDraft.id,
          draftRevision: staticDraft.draftRevision,
          physicalResourceId: source.physicalResourceId,
          changeIds: [],
          expectedAuthorityRevision: previousToken,
          operationId: 'unsupported-${source.target.kind.name}',
        ),
        throwsA(_authoringError('unsupported_apply')),
      );
    }
    h.expectNoGeneration();
  });

  test('all character writers advance durable authority and managed ABA still conflicts after reopen', () async {
    final h = await slashFixture();
    final id = await h.card('Card writers');
    final target = _character(id);
    expect(await h.engine.listAuthoringRevisions(target.physicalResourceId), hasLength(1));
    await _advance(h.engine, target, () => h.engine.updateCharacterFields(id, {'description': 'Field'}));
    await _advance(h.engine, target, () => h.engine.addCharacterBookEntry(id, {'content': 'Entry'}));
    await _advance(h.engine, target, () => h.engine.updateCharacterBookEntry(id, 0, {'content': 'Changed'}));
    await _advance(h.engine, target, () => h.engine.deleteCharacterBookEntry(id, 0));
    final chat = await h.emptyChat(id);
    final context = await h.context(chat, characterId: id);
    await _advance(h.engine, target, () => h.bridge.replaceVariables(context.id, scriptCharacter, {'x': 1}));
    final embedded = TavernScriptBookRef.embedded(characterId: id);
    await _advance(
      h.engine,
      target,
      () => h.bridge.replaceBook(context.id, embedded, {'entries': <Object?>[], 'vendor': null}),
    );
    final raw = scriptMap((await _json(_cardFile(h, id)))['data']);
    await _advance(h.engine, target, () => h.bridge.replaceCharacterData(context.id, id, raw));
    final draft = await _draft(h.engine, [target], [_set('name', target, '/data/name', 'Stale')]);
    final before = await _cardFile(h, id).readAsBytes();
    await _advance(h.engine, target, () => h.bridge.replaceCharacterData(context.id, id, {...raw, 'name': 'B'}));
    await _advance(h.engine, target, () => h.bridge.replaceCharacterData(context.id, id, raw));
    expect(await _cardFile(h, id).readAsBytes(), before);
    await h.reopen();
    await expectLater(_apply(h.engine, draft, target, 'stale-card'), throwsA(_authoringError('authority_conflict')));
    expect(await _cardFile(h, id).readAsBytes(), before);
    h.expectNoGeneration();
  });

  test('book put report raw Slash and delete-recreate writers share one durable resource', () async {
    final h = await slashFixture();
    final actor = await h.card('Book writers');
    final context = await h.context(await h.emptyChat(actor), characterId: actor);
    final imported = (await h.engine.importLorebook('{"name":"Book","entries":{}}', fileName: 'LedgerBook.json')).book;
    final target = _book(imported.id);
    expect(await h.engine.listAuthoringRevisions(target.physicalResourceId), hasLength(1));
    const raw = <String, Object?>{'name': 'Book', 'entries': <String, Object?>{}};
    await _advance(h.engine, target, () => h.engine.putLorebook(target.id, raw));
    await _advance(h.engine, target, () => h.engine.recheckImport(TavernImportKind.lorebook, target.id));
    await _advance(
      h.engine,
      target,
      () => h.bridge.replaceBook(context.id, TavernScriptBookRef.standalone(bookId: target.id), raw),
    );
    await _advance(h.engine, target, () => slashRun(h, context.id, '/createentry file=LedgerBook key=one BODY'));
    await _advance(
      h.engine,
      target,
      () => slashRun(h, context.id, '/setentryfield file=LedgerBook uid=0 field=content CHANGED'),
    );
    final beforeDelete = await _token(h.engine, target);
    await h.engine.deleteLorebook(target.id);
    final deleted = (await h.engine.listAuthoringRevisions(target.physicalResourceId)).first;
    expect(deleted.revision, beforeDelete.revision + 1);
    expect(
      (await h.engine.readAuthoringOperation(deleted.operationId, domainId: deleted.domainId))!.after['present'],
      isFalse,
    );
    await h.engine.deleteLorebook(target.id);
    expect((await h.engine.listAuthoringRevisions(target.physicalResourceId)).first.revision, deleted.revision);
    await h.engine.putLorebook(target.id, raw);
    expect((await _token(h.engine, target)).revision, deleted.revision + 1);

    final chatBook = await slashRun(h, context.id, '/getchatbook name=NewLedgerBook');
    expect(chatBook.effects.committed, isTrue);
    final created = (await h.engine.listLorebooks()).singleWhere((book) => book.stWorldName == 'NewLedgerBook');
    expect(await h.engine.listAuthoringRevisions('lorebook:${created.id}'), hasLength(1));
    h.expectNoGeneration();
  });

  test('one-group selection preserves exact envelopes and replays the original receipt after draft deletion', () async {
    final h = await slashFixture();
    final card = _character(await h.card('Before'));
    final cardFile = _cardFile(h, card.id);
    final cardDocument = await _json(cardFile);
    scriptMap(cardDocument['data'])
      ..remove('personality')
      ..remove('modification_date');
    cardDocument['vendorEnvelope'] = {
      'keep': [null, true],
    };
    await cardFile.writeAsString(jsonEncode(cardDocument));
    final imported = (await h.engine.importLorebook('{"name":"Before","entries":{}}', fileName: 'Before.json')).book;
    final book = _book(imported.id);
    final bookFile = _bookFile(h, book.id);
    final bookDocument = (await _json(bookFile))..['vendorEnvelope'] = [1, null];
    await bookFile.writeAsString(jsonEncode(bookDocument));
    await h.engine.lorebook(book.id); // The exact writer must also replace these warm caches.
    final draft = await _draft(
      h.engine,
      [card, book],
      [
        _set('card-name', card, '/data/name', 'Chosen'),
        _set('card-extra', card, '/data/extensions/added', 7),
        _set('book-name', book, '/book/name', 'Chosen book'),
        _remove('report', book, '/importReport'),
        _remove('source-name', book, '/stWorldName'),
        _set('entry', book, '/book/entries/0', {'content': 'Initial'}),
        _set('entry-detail', book, '/book/entries/0/content', 'Dependent', dependsOn: ['entry']),
      ],
    );
    await expectLater(
      _apply(h.engine, draft, book, 'missing-dependency', changes: ['entry-detail']),
      throwsA(_authoringError('missing_dependency')),
    );
    await expectLater(
      _apply(h.engine, draft, card, 'cross-group', changes: ['card-name', 'book-name']),
      throwsA(_authoringError('invalid_change')),
    );
    expect(await _json(cardFile), cardDocument);
    expect(await _json(bookFile), bookDocument);
    final first = await _apply(h.engine, draft, card, 'chosen-card', changes: ['card-name']);
    expect(first.committed, isTrue);
    expect((await h.engine.readAuthoringDraft(draft.id))!.draftRevision, draft.draftRevision);
    final chosenBook = await _apply(
      h.engine,
      draft,
      book,
      'chosen-book',
      changes: ['source-name', 'book-name', 'report'],
    );
    expect(chosenBook.committed, isTrue);
    final actualCard = await _json(cardFile);
    final expectedCard = scriptMap(jsonDecode(jsonEncode(cardDocument)));
    scriptMap(expectedCard['data'])['name'] = 'Chosen';
    expect(actualCard, expectedCard);
    final expectedBook = {...bookDocument}
      ..remove('importReport')
      ..remove('stWorldName');
    expectedBook['book'] = {...scriptMap(bookDocument['book']), 'name': 'Chosen book'};
    expect(await _json(bookFile), expectedBook);
    expect((await h.engine.listLorebooks()).single.stWorldName, isNull);
    expect(await h.engine.readImportReport(TavernImportKind.lorebook, book.id), isNull);
    await expectLater(
      _apply(h.engine, draft, card, 'old-remainder', changes: ['card-extra']),
      throwsA(_authoringError('authority_conflict')),
    );
    final rebased = await h.engine.rebaseAuthoringDraft(
      draft.id,
      draftRevision: draft.draftRevision,
      changes: [draft.changes.singleWhere((change) => change.id == 'card-extra')],
    );
    expect((await _apply(h.engine, rebased, card, 'rebased-remainder')).committed, isTrue);
    await h.engine.deleteAuthoringDraft(draft.id, draftRevision: rebased.draftRevision);
    final replay = await _apply(h.engine, draft, card, 'chosen-card', changes: ['card-name']);
    expect(replay.adoptedRevision, first.adoptedRevision);
    expect(
      (await _apply(
        h.engine,
        draft,
        book,
        'chosen-book',
        changes: ['report', 'source-name', 'book-name'],
      )).adoptedRevision,
      chosenBook.adoptedRevision,
    );
    await expectLater(
      _apply(h.engine, draft, card, 'chosen-card', changes: ['card-extra']),
      throwsA(_authoringError('operation_conflict')),
    );
    expect(scriptMap((await _json(cardFile))['data'])['extensions'], containsPair('added', 7));
  });

  test('noChange preserves BOM and formatting and a queued edit rechecks the draft at prepare', () async {
    final h = await slashFixture();
    final target = _book('queue');
    await h.engine.putLorebook(target.id, {'name': 'Same', 'entries': <String, Object?>{}});
    final file = _bookFile(h, target.id);
    const raw = '\uFEFF\uFEFF{\n  "name": "Same", "entries": {}\n}\n';
    await file.writeAsBytes(utf8.encode(raw));
    final noChange = await _draft(h.engine, [target], [_set('same', target, '/name', 'Same')]);
    final historyLength = (await h.engine.listAuthoringRevisions(target.physicalResourceId)).length;
    var renames = 0;
    await _withFileHooks(
      {
        '${file.path}.writing': _FileHooks(
          rename: (real, path) async {
            renames++;
            return real.rename(path);
          },
        ),
      },
      () async {
        final receipt = await _apply(h.engine, noChange, target, 'no-change');
        expect(receipt.state, TavernAuthoringOperationState.noChange);
        expect(receipt.committed, isFalse);
        expect(receipt.adoptedRevision, isNull);
      },
    );
    expect(renames, 0);
    expect(await file.readAsBytes(), utf8.encode(raw));
    expect(await h.engine.listAuthoringRevisions(target.physicalResourceId), hasLength(historyLength));

    await file.writeAsString('{"broken":');
    await expectLater(h.engine.createAuthoringDraft([target]), throwsFormatException);
    await file.writeAsBytes(utf8.encode(raw));
    await expectLater(
      _apply(h.engine, noChange, target, 'observed-malformed-aba'),
      throwsA(_authoringError('authority_conflict')),
    );

    final beforeAbsent = await h.engine.createAuthoringDraft([target]);
    await file.delete();
    await expectLater(h.engine.createAuthoringDraft([target]), throwsA(_authoringError('not_found')));
    await file.writeAsBytes(utf8.encode(raw));
    await expectLater(
      _apply(h.engine, beforeAbsent, target, 'observed-absent-aba'),
      throwsA(_authoringError('authority_conflict')),
    );

    final queued = await _draft(h.engine, [target], [_set('name', target, '/name', 'Queued')]);
    final gate = _Gate();
    addTearDown(gate.release);
    await _withFileHooks(
      {
        file.path: _FileHooks(
          readBytes: (real) async {
            await gate.wait();
            return real.readAsBytes();
          },
        ),
      },
      () async {
        final applying = _handled(_apply(h.engine, queued, target, 'edited-during-read'));
        try {
          await Future.any([
            gate.entered.future,
            applying.then<void>((_) => throw TestFailure('The adoption completed before its actual source read.')),
          ]).timeout(_deadline);
          await h.engine.editAuthoringDraft(
            queued.id,
            draftRevision: queued.draftRevision,
            changes: [_set('name', target, '/name', 'New draft')],
          );
        } finally {
          gate.release();
        }
        await expectLater(applying, throwsA(_authoringError('revision_conflict')));
      },
    );
    expect(await file.readAsBytes(), utf8.encode(raw));
    expect(
      await h.engine.readAuthoringOperation(
        'edited-during-read',
        domainId: _source(queued, target).authorityRevision!.domainId,
      ),
      isNull,
    );
  });

  test('historical JSON restoration creates a new version without rewriting identity or imported media', () async {
    final h = await slashFixture();
    final imported = await h.engine.importCard(await File('test/fixtures/card-assets.charx').readAsBytes());
    final target = _character(imported.id);
    final directory = _cardFile(h, target.id).parent;
    final identity = File('${directory.path}/library.json');
    final original = File('${directory.path}/original.charx');
    final media = File('${directory.path}/resources/unknown-app.bin');
    final identityBytes = await identity.readAsBytes();
    final originalBytes = await original.readAsBytes();
    final mediaBytes = await media.readAsBytes();
    final firstDraft = await _draft(h.engine, [target], [_set('name', target, '/data/name', 'Historical')]);
    final first = await _apply(h.engine, firstDraft, target, 'historical-name');
    final historical = (await h.engine.readAuthoringOperation(first.operationId, domainId: first.domainId))!;
    final later = await _draft(h.engine, [target], [_set('name', target, '/data/name', 'Later')]);
    final second = await _apply(h.engine, later, target, 'later-name');
    final oldRevision = TavernAuthorityRevision(domainId: first.domainId, revision: first.adoptedRevision!);
    final restored = await h.engine.restoreAuthoringRevision(
      target.physicalResourceId,
      revision: oldRevision,
      expectedAuthorityRevision: await _token(h.engine, target),
      operationId: 'restore-name',
    );
    expect(restored.committed, isTrue);
    expect(restored.adoptedRevision, second.adoptedRevision! + 1);
    expect(await _cardFile(h, target.id).readAsBytes(), utf8.encode(historical.after['rawText']! as String));
    expect(await identity.readAsBytes(), identityBytes);
    expect(await original.readAsBytes(), originalBytes);
    expect(await media.readAsBytes(), mediaBytes);
    expect((await h.engine.character(target.id))!.name, 'Historical');

    final changedIdentity = (await _json(identity))..['sourceFileName'] = 'a-different-source.charx';
    await identity.writeAsString(jsonEncode(changedIdentity));
    final current = await _token(h.engine, target);
    final count = (await h.engine.listAuthoringRevisions(target.physicalResourceId)).length;
    await expectLater(
      h.engine.restoreAuthoringRevision(
        target.physicalResourceId,
        revision: oldRevision,
        expectedAuthorityRevision: current,
        operationId: 'changed-identity',
      ),
      throwsA(_authoringError('authority_conflict')),
    );
    expect(await h.engine.listAuthoringRevisions(target.physicalResourceId), hasLength(count));
    expect(await identity.readAsString(), jsonEncode(changedIdentity));
    expect(await original.readAsBytes(), originalBytes);
    expect(await media.readAsBytes(), mediaBytes);
  });

  test('real marker failures retain adopted content and hot caches and replay only repairs recording', () async {
    final h = await slashFixture();
    final work = await _temporaryDirectory();
    final target = _book('marker');
    await h.engine.putLorebook(target.id, {'name': 'Before', 'entries': <String, Object?>{}});
    expect((await h.engine.lorebook(target.id))!['name'], 'Before');
    final draft = await _draft(h.engine, [target], [_set('name', target, '/name', 'After')]);
    final count = (await h.engine.listAuthoringRevisions(target.physicalResourceId)).length;
    _blockMarker(h, 'adoption_marker_abort', operationId: 'marker-failure', state: 'adopted');
    var renames = 0;
    await _withFileHooks(
      {
        '${_bookFile(h, target.id).path}.writing': _FileHooks(
          rename: (real, path) async {
            renames++;
            return real.rename(path);
          },
        ),
      },
      () async {
        final failedMarker = await _apply(h.engine, draft, target, 'marker-failure');
        expect(failedMarker.committed, isTrue);
        expect(failedMarker.state, TavernAuthoringOperationState.adopted);
        expect(failedMarker.adoptedRevision, isNull);
        expect(failedMarker.historyPending, isTrue);
        expect((await _json(_bookFile(h, target.id)))['name'], 'After');
        expect((await h.engine.lorebook(target.id))!['name'], 'After');
        expect(
          (await h.engine.readAuthoringOperation('marker-failure', domainId: failedMarker.domainId))!.committed,
          isTrue,
        );
        _dropTrigger(h, 'adoption_marker_abort');
        final repaired = await _apply(h.engine, draft, target, 'marker-failure');
        expect(repaired.state, TavernAuthoringOperationState.published);
        expect(repaired.historyPending, isFalse);
        final replay = await _apply(h.engine, draft, target, 'marker-failure');
        expect(replay.adoptedRevision, repaired.adoptedRevision);
        expect(await h.engine.listAuthoringRevisions(target.physicalResourceId), hasLength(count + 1));
        expect(renames, 1);

        final next = await _draft(h.engine, [target], [_set('name', target, '/name', 'Durably adopted')]);
        _blockMarker(h, 'publication_marker_abort', operationId: 'publication-failure', state: 'published');
        final publishedLater = await _apply(h.engine, next, target, 'publication-failure');
        expect(publishedLater.committed, isTrue);
        expect(publishedLater.adoptedRevision, isNotNull);
        expect(publishedLater.historyPending, isTrue);
        final archive = File('${work.path}/adopted-with-pending-publication.zip');
        await h.engine.backup(archive.path);
        expect(await archive.exists(), isTrue);
        await h.reopen(
          whileClosed: () async {
            _dropTrigger(h, 'publication_marker_abort');
          },
        );
        final recovered = (await h.engine.readAuthoringOperation(
          'publication-failure',
          domainId: publishedLater.domainId,
        ))!;
        expect(recovered.state, TavernAuthoringOperationState.published);
        expect(recovered.adoptedRevision, publishedLater.adoptedRevision);
        expect(
          (await _apply(h.engine, next, target, 'publication-failure')).adoptedRevision,
          publishedLater.adoptedRevision,
        );
        expect(renames, 2);
        expect(await h.engine.listAuthoringRevisions(target.physicalResourceId), hasLength(count + 2));
      },
    );
  });

  test(
    'a real helper rename with a lost return stays unknown through host events and before-after reopen observations',
    () async {
      final h = await slashFixture();
      final id = await h.card('Unknown helper');
      final context = await h.context(await h.emptyChat(id), characterId: id);
      final target = _character(id);
      final gate = _Gate();
      addTearDown(gate.release);
      final resourceSql = target.physicalResourceId.replaceAll("'", "''");
      h.inspect(
        (db) => db.execute("""
      CREATE TRIGGER unknown_marker_abort BEFORE UPDATE OF state ON authoring_operations
      WHEN NEW.physical_resource_id = '$resourceSql' AND NEW.state = 'unconfirmed'
      BEGIN SELECT RAISE(ABORT, 'unknown marker fixture'); END
    """),
        writable: true,
      );
      addTearDown(() => _dropTrigger(h, 'unknown_marker_abort'));
      final host = SlashHost()
        ..onInteract = (request, _) async {
          await h.bridge.replaceVariables(context.id, scriptCharacter, {'answer': 'adopted-but-unconfirmed'});
          return TavernScriptUiResult(requestId: request.requestId, status: 'submitted', text: 'unused');
        };
      h.bridge.attachHost(host);
      late TavernAuthoringOperation operation;
      await _withFileHooks(
        {
          '${_cardFile(h, id).path}.writing': _FileHooks(
            rename: (real, path) async {
              await real.rename(path);
              await gate.wait();
              throw FileSystemException('The real rename completed but its return was lost.', path);
            },
          ),
        },
        () async {
          final execution = await h.bridge.triggerSlash(context.id, '/input');
          final hot = execution.events.toList();
          final failing = _handled(slashFailure(execution));
          try {
            await slashSignal(execution, gate.entered.future).timeout(_deadline);
          } finally {
            gate.release();
          }
          final failure = await failing.timeout(_deadline);
          final details = _unknownDetails(failure.issues);
          expect(failure.committed, isFalse);
          expect(details['physicalResourceId'], target.physicalResourceId);
          expect(details['state'], 'unconfirmed');
          expect(details['committed'], isNull);
          expect(details['historyPending'], isTrue);
          final terminal = (await hot.timeout(_deadline)).lastWhere((event) => event.error != null);
          final lateEvent = await execution.events.single.timeout(_deadline);
          expect(_unknownDetails(terminal.error!.issues), details);
          expect(_unknownDetails(lateEvent.error!.issues), details);
          expect(_unknownDetails(lateEvent.issues), details);
          final operationId = details['operationId']! as String;
          final domainId = details['domainId']! as String;
          operation = (await h.engine.readAuthoringOperation(operationId, domainId: domainId))!;
          expect(operation.committed, isNull);
          expect(
            h.inspect(
              (db) => db.select('SELECT state FROM authoring_operations WHERE operation_id = ?', [
                operationId,
              ]).single['state'],
            ),
            'prepared',
          );
          expect(await _cardFile(h, id).readAsBytes(), utf8.encode(operation.after['rawText']! as String));
        },
      );
      await h.reopen(
        whileClosed: () async {
          _dropTrigger(h, 'unknown_marker_abort');
        },
      );
      final after = (await h.engine.readAuthoringOperation(operation.operationId, domainId: operation.domainId))!;
      expect(after.state, TavernAuthoringOperationState.unconfirmed);
      expect(after.committed, isNull);
      await expectLater(
        h.engine.updateCharacterFields(id, {'name': 'Must not retry'}),
        throwsA(
          _authoringError(
            'pending_operation',
          ).having((error) => error.blockedOperationId, 'blocked operation', operation.operationId),
        ),
      );
      await h.reopen(
        whileClosed: () async {
          await _cardFile(h, id).writeAsString(operation.before['rawText']! as String);
        },
      );
      final before = (await h.engine.readAuthoringOperation(operation.operationId, domainId: operation.domainId))!;
      expect(before.state, TavernAuthoringOperationState.unconfirmed);
      expect(before.committed, isNull);
      await expectLater(h.engine.updateCharacterFields(id, {}), throwsA(_authoringError('pending_operation')));
      expect(await _cardFile(h, id).readAsBytes(), utf8.encode(operation.before['rawText']! as String));
      h.expectNoGeneration();
    },
  );

  test(
    'an unknown directory deletion protects its original artifact and blocks bare writes backup and both restore roots',
    () async {
      final h = await slashFixture();
      final id = await h.card('Unconfirmed directory');
      final original = await File('${_cardFile(h, id).parent.path}/original.json').readAsBytes();
      final work = await _temporaryDirectory();
      final clean = File('${work.path}/clean.zip');
      await h.engine.backup(clean.path);
      late TavernAuthoringException failed;
      await _withDirectoryRename(
        _cardFile(h, id).parent,
        (real, path) async {
          await real.rename(path);
          throw FileSystemException('The directory moved but its return was lost.', path);
        },
        () async {
          try {
            await h.engine.deleteCharacter(id);
            fail('Deletion must report an unknown adoption.');
          } on TavernAuthoringException catch (error) {
            failed = error;
          }
        },
      );
      expect(failed.code, 'resource_write_failed');
      expect(failed.receipt!.committed, isNull);
      final trash = (await Directory('${h.root.path}/characters').list().toList()).whereType<Directory>().singleWhere(
        (entry) => entry.uri.pathSegments.where((part) => part.isNotEmpty).last.startsWith('.trash-'),
      );
      expect(await File('${trash.path}/original.json').readAsBytes(), original);
      await expectLater(h.engine.updateCharacterFields(id, {}), throwsA(_authoringError('pending_operation')));
      final rejected = File('${work.path}/rejected.zip');
      await expectLater(h.engine.backup(rejected.path), throwsA(_authoringError('pending_operation')));
      expect(await rejected.exists(), isFalse);
      await h.close();

      final bare = CharacterLibrary(h.root);
      expect(await bare.list(), isEmpty);
      expect(await File('${trash.path}/original.json').readAsBytes(), original);
      var inspected = false;
      await expectLater(
        bare.importCard(
          Uint8List.fromList(utf8.encode('{"name":"bare"}')),
          beforeSave: (_) async {
            inspected = true;
          },
        ),
        throwsA(_authoringError('managed_writer_required')),
      );
      expect(inspected, isFalse);
      await expectLater(restoreTavernDirectory(clean.path, h.root.path), throwsA(_authoringError('pending_operation')));
      expect(await File('${trash.path}/original.json').readAsBytes(), original);

      // Construct a correctly hashed incoming archive below the public facade
      // to verify it rejects an unresolved ledger before any staged library tidy.
      final incomingArchive = File('${work.path}/unresolved.zip');
      final store = ChatStore.open('${h.root.path}/tavern.sqlite3');
      backup_io.TavernBackupSnapshot? snapshot;
      try {
        snapshot = await backup_io.captureTavernBackup(
          h.root,
          backupDatabase: store.backupToFile,
          createdAt: DateTime.utc(2026, 11, 13),
        );
        await snapshot.writeZip(incomingArchive);
      } finally {
        await snapshot?.dispose();
        await store.close();
      }
      final destination = Directory('${work.path}/incoming-target');
      await expectLater(
        restoreTavernDirectory(incomingArchive.path, destination.path),
        throwsA(_authoringError('pending_operation')),
      );
      expect(await destination.exists(), isFalse);
      expect(await File('${trash.path}/original.json').readAsBytes(), original);
    },
  );

  test(
    'backup and close drain an actual adoption and restored drafts keep old tokens while the root gets a new domain',
    () async {
      final h = await slashFixture();
      final engine = h.engine;
      final target = _book('drain');
      await engine.putLorebook(target.id, {'name': 'Before', 'entries': <String, Object?>{}});
      final draft = await _draft(engine, [target], [_set('name', target, '/name', 'Captured')]);
      final work = await _temporaryDirectory();
      final archive = File('${work.path}/drained.zip');
      final gate = _Gate();
      addTearDown(gate.release);
      late TavernAuthoringReceipt adopted;
      await _withFileHooks(
        {
          '${_bookFile(h, target.id).path}.writing': _FileHooks(
            rename: (real, path) async {
              final result = await real.rename(path);
              await gate.wait();
              return result;
            },
          ),
        },
        () async {
          final applying = _handled(_apply(engine, draft, target, 'drained-adoption'));
          await Future.any([
            gate.entered.future,
            applying.then<void>((_) => throw TestFailure('The adoption completed before its actual rename returned.')),
          ]).timeout(_deadline);
          var backedUp = false;
          var closed = false;
          final backingUp = _handled(
            engine.backup(archive.path).then((value) {
              backedUp = true;
              return value;
            }),
          );
          final closing = _handled(
            h.close().then((_) {
              closed = true;
            }),
          );
          try {
            await Future<void>.delayed(Duration.zero);
            expect(backedUp, isFalse);
            expect(closed, isFalse);
          } finally {
            gate.release();
          }
          adopted = await applying.timeout(_deadline);
          await backingUp.timeout(_deadline);
          await closing.timeout(_deadline);
        },
      );
      expect(adopted.committed, isTrue);
      final destination = Directory('${work.path}/restored');
      await restoreTavernDirectory(archive.path, destination.path);
      final restored = await TavernEngine.openDirectory(destination);
      addTearDown(restored.close);
      final saved = (await restored.readAuthoringDraft(draft.id))!;
      expect(_source(saved, target).authorityRevision, _source(draft, target).authorityRevision);
      expect((await restored.lorebook(target.id))!['name'], 'Captured');
      final oldResult = await _apply(restored, draft, target, 'drained-adoption');
      expect(oldResult.adoptedRevision, adopted.adoptedRevision);
      await expectLater(
        _apply(restored, saved, target, 'old-domain-new-operation'),
        throwsA(_authoringError('authority_conflict')),
      );
      final rebased = await restored.rebaseAuthoringDraft(saved.id, draftRevision: saved.draftRevision, changes: []);
      expect(_source(rebased, target).authorityRevision!.domainId, isNot(adopted.domainId));
      expect(
        (await restored.readAuthoringOperation(adopted.operationId, domainId: adopted.domainId))!.committed,
        isTrue,
      );
    },
  );
}

TavernAuthoringTarget _character(String id) => TavernAuthoringTarget(kind: TavernAuthoringTargetKind.character, id: id);
TavernAuthoringTarget _book(String id) => TavernAuthoringTarget(kind: TavernAuthoringTargetKind.lorebook, id: id);

TavernAuthoringChange _set(
  String id,
  TavernAuthoringTarget target,
  String path,
  Object? value, {
  List<String> dependsOn = const [],
}) => TavernAuthoringChange(
  id: id,
  physicalResourceId: target.physicalResourceId,
  path: path,
  operation: TavernAuthoringChangeKind.set,
  value: value,
  dependsOn: dependsOn,
);
TavernAuthoringChange _remove(String id, TavernAuthoringTarget target, String path) => TavernAuthoringChange(
  id: id,
  physicalResourceId: target.physicalResourceId,
  path: path,
  operation: TavernAuthoringChangeKind.remove,
);
TavernAuthoringSource _source(TavernAuthoringDraft draft, TavernAuthoringTarget target) =>
    draft.sources.singleWhere((source) => source.physicalResourceId == target.physicalResourceId);

Future<TavernAuthoringDraft> _draft(
  Tavern engine,
  List<TavernAuthoringTarget> targets,
  List<TavernAuthoringChange> changes,
) async {
  final created = await engine.createAuthoringDraft(targets);
  return engine.editAuthoringDraft(created.id, draftRevision: created.draftRevision, changes: changes);
}

Future<TavernAuthorityRevision> _token(Tavern engine, TavernAuthoringTarget target) async =>
    _source(await engine.createAuthoringDraft([target]), target).authorityRevision!;

Future<void> _advance<T>(Tavern engine, TavernAuthoringTarget target, Future<T> Function() write) async {
  final before = await _token(engine, target);
  await write();
  final after = await _token(engine, target);
  expect(after.domainId, before.domainId);
  expect(after.revision, before.revision + 1);
}

Future<TavernAuthoringReceipt> _apply(
  Tavern engine,
  TavernAuthoringDraft draft,
  TavernAuthoringTarget target,
  String operationId, {
  List<String>? changes,
}) => engine.applyAuthoringChanges(
  draft.id,
  draftRevision: draft.draftRevision,
  physicalResourceId: target.physicalResourceId,
  changeIds:
      changes ??
      [
        for (final change in draft.changes)
          if (change.physicalResourceId == target.physicalResourceId) change.id,
      ],
  expectedAuthorityRevision: _source(draft, target).authorityRevision!,
  operationId: operationId,
);

TypeMatcher<TavernAuthoringException> _authoringError(String code) =>
    isA<TavernAuthoringException>().having((error) => error.code, 'code', code);
File _cardFile(ScriptFixture h, String id) => File('${h.root.path}/characters/$id/card.json');
File _bookFile(ScriptFixture h, String id) => File('${h.root.path}/lorebooks/$id.json');
Future<Map<String, Object?>> _json(File file) async => scriptMap(jsonDecode(await file.readAsString()));

void _blockMarker(ScriptFixture h, String name, {required String operationId, required String state}) {
  final id = operationId.replaceAll("'", "''");
  h.inspect(
    (db) => db.execute("""
    CREATE TRIGGER $name BEFORE UPDATE OF state ON authoring_operations
    WHEN NEW.operation_id = '$id' AND NEW.state = '$state'
    BEGIN SELECT RAISE(ABORT, 'authoring marker fixture'); END
  """),
    writable: true,
  );
  addTearDown(() => _dropTrigger(h, name));
}

void _dropTrigger(ScriptFixture h, String name) =>
    h.inspect((db) => db.execute('DROP TRIGGER IF EXISTS $name'), writable: true);

Map<String, Object?> _unknownDetails(List<TavernScriptIssue> issues) =>
    issues.firstWhere((issue) => issue.code == 'authoring_adoption_unconfirmed').details;

Future<Directory> _temporaryDirectory() async {
  final directory = await Directory.systemTemp.createTemp('dsh-authoring-adoption-');
  addTearDown(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });
  return directory;
}

Future<T> _handled<T>(Future<T> future) {
  unawaited(future.then<void>((_) {}, onError: (Object _, StackTrace _) {}));
  return future;
}

class _Gate {
  final entered = Completer<void>();
  final _released = Completer<void>();
  Future<void> wait() async {
    if (!entered.isCompleted) entered.complete();
    await _released.future;
  }

  void release() {
    if (!_released.isCompleted) _released.complete();
  }
}

class _FileHooks {
  const _FileHooks({this.readBytes, this.rename});
  final Future<Uint8List> Function(File)? readBytes;
  final Future<File> Function(File, String)? rename;
}

Future<void> _withFileHooks(Map<String, _FileHooks> hooks, Future<void> Function() action) async {
  final parent = Zone.current;
  final paths = {for (final entry in hooks.entries) File(entry.key).absolute.uri: entry.value};
  await IOOverrides.runZoned(
    action,
    createFile: (path) {
      final real = parent.run(() => File(path));
      final hook = paths[parent.run(() => real.absolute.uri)];
      return hook == null ? real : _HookedFile(real, hook);
    },
  );
}

class _HookedFile implements File {
  _HookedFile(this.real, this.hooks);
  final File real;
  final _FileHooks hooks;
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
  Future<Uint8List> readAsBytes() => hooks.readBytes?.call(real) ?? real.readAsBytes();
  @override
  Future<String> readAsString({Encoding encoding = utf8}) => real.readAsString(encoding: encoding);
  @override
  Future<File> writeAsString(
    String contents, {
    FileMode mode = FileMode.write,
    Encoding encoding = utf8,
    bool flush = false,
  }) => real.writeAsString(contents, mode: mode, encoding: encoding, flush: flush);
  @override
  Future<File> writeAsBytes(List<int> bytes, {FileMode mode = FileMode.write, bool flush = false}) =>
      real.writeAsBytes(bytes, mode: mode, flush: flush);
  @override
  Future<File> rename(String newPath) => hooks.rename?.call(real, newPath) ?? real.rename(newPath);
  @override
  Future<FileSystemEntity> delete({bool recursive = false}) => real.delete(recursive: recursive);
  @override
  Future<RandomAccessFile> open({FileMode mode = FileMode.read}) => real.open(mode: mode);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _withDirectoryRename(
  Directory directory,
  Future<Directory> Function(Directory, String) rename,
  Future<void> Function() action,
) async {
  final parent = Zone.current;
  final selected = directory.absolute.uri;
  await IOOverrides.runZoned(
    action,
    createDirectory: (path) {
      final real = parent.run(() => Directory(path));
      return parent.run(() => real.absolute.uri) == selected ? _HookedDirectory(real, rename) : real;
    },
  );
}

class _HookedDirectory implements Directory {
  _HookedDirectory(this.real, this.renameEffect);
  final Directory real;
  final Future<Directory> Function(Directory, String) renameEffect;
  @override
  String get path => real.path;
  @override
  Uri get uri => real.uri;
  @override
  bool get isAbsolute => real.isAbsolute;
  @override
  Directory get absolute => real.absolute;
  @override
  Directory get parent => real.parent;
  @override
  Future<bool> exists() => real.exists();
  @override
  bool existsSync() => real.existsSync();
  @override
  Future<Directory> create({bool recursive = false}) => real.create(recursive: recursive);
  @override
  Future<Directory> createTemp([String? prefix]) => real.createTemp(prefix);
  @override
  Future<String> resolveSymbolicLinks() => real.resolveSymbolicLinks();
  @override
  Future<Directory> rename(String newPath) => renameEffect(real, newPath);
  @override
  Future<FileSystemEntity> delete({bool recursive = false}) => real.delete(recursive: recursive);
  @override
  Stream<FileSystemEntity> list({bool recursive = false, bool followLinks = true}) =>
      real.list(recursive: recursive, followLinks: followLinks);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:dsh_tavern/src/store/chat_store.dart' show AuthoringRunStore, AuthoringStore;
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import 'p2_slash_test_support.dart';

const _deadline = Duration(seconds: 10);

void main() {
  test('real author HTTP tools edit only drafts and persist exact exchange usage and replayable receipts', () async {
    final h = await _fixture();
    final card = TavernAuthoringTarget(kind: TavernAuthoringTargetKind.character, id: await h.card('Original'));
    const book = TavernAuthoringTarget(kind: TavernAuthoringTargetKind.lorebook, id: 'author');
    const regex = TavernAuthoringTarget(kind: TavernAuthoringTargetKind.regexLibrary, id: 'global');
    await h.engine.putLorebook(book.id, {'name': 'Original book', 'entries': <String, Object?>{}});
    final presetId = (await h.engine.importPreset(jsonEncode(scriptPreset().raw))).preset.id;
    final preset = TavernAuthoringTarget(kind: TavernAuthoringTargetKind.preset, id: presetId);
    final draft = await h.engine.createAuthoringDraft([card, book, regex, preset]);
    final cardFile = File('${h.root.path}/characters/${card.id}/card.json');
    final bookFile = File('${h.root.path}/lorebooks/${book.id}.json');
    final beforeCard = await cardFile.readAsBytes(), beforeBook = await bookFile.readAsBytes();
    final beforePreset = h.inspect(
      (db) => Map<String, Object?>.of(db.select('SELECT * FROM presets WHERE id = ?', [presetId]).single),
    );
    final beforeBusiness = _businessRows(h);
    final plans = [h.stream(), h.stream(), h.stream()];
    final materials = <String, Object?>{
      'notes': {'title': 'captured'},
    };
    final request = TavernAuthoringRunRequest(
      runId: 'author-complete',
      draftId: draft.id,
      draftRevision: draft.draftRevision,
      instruction: 'Revise the supplied draft and check it.',
      materials: materials,
    );
    final run = h.engine.startAuthoringRun(request);
    final hot = run.events.toList();
    expect(identical(h.engine.startAuthoringRun(request), run), isTrue);
    scriptMap(materials['notes'])['title'] = 'caller changed';
    final first = [
      _call('read', 'draft_read', {}),
      _call('card', 'card_write', _write(card, 'card-name', '/data/name', 'Draft character')),
      _call('book', 'lore_write', _write(book, 'book-name', '/name', 'Draft book')),
      _call(
        'regex',
        'regex_write',
        _write(regex, 'regex-rule', '/scripts', [
          {
            'id': 'draft-regex',
            'raw': {
              'id': 'draft-regex',
              'scriptName': 'Draft regex',
              'findRegex': '/a/g',
              'replaceString': 'b',
              'placement': [2],
              'disabled': false,
            },
          },
        ]),
      ),
      _call('preset', 'preset_write', _write(preset, 'preset-name', '/name', 'Draft preset')),
      _Call('invalid-json', 'card_write', '{"changes":'),
      _call('not-offered', 'apply', {}),
    ];
    await _reply(plans[0], run, calls: first, text: 'Editing. ', prompt: 10, completion: 1);
    await _listening(plans[1], run);
    final during = (await h.engine.readAuthoringRun(run.runId))!;
    expect(during.currentRevision, draft.draftRevision + 4);
    expect(during.receipts.where((receipt) => receipt.status == TavernAuthoringToolStatus.rejected), hasLength(2));
    during.request.materials.clear();
    during.requests.first.body.clear();
    during.receipts.first.result.clear();
    await _reply(
      plans[1],
      run,
      calls: [
        _call('lint', 'lint', {}),
        _call('regex-test', 'regex_test', {
          'physicalResourceId': regex.physicalResourceId,
          'scriptPath': '/scripts/0/raw',
          'text': 'a',
        }),
      ],
      prompt: 20,
      completion: 2,
    );
    await _reply(plans[2], run, text: 'Ready for review.', prompt: 30, completion: 3);
    final result = await run.result.timeout(_deadline);
    expect(result.status, TavernAuthoringRunStatus.completed);
    expect(result.answer, 'Editing. Ready for review.');
    expect(result.requests.map((request) => request.requestIndex), [1, 2, 3]);
    expect(result.requests.every((request) => request.attempts.length == 1 && request.attempts.single == 0), isTrue);
    expect(result.currentRevision, draft.draftRevision + 4);
    final tested = result.receipts.singleWhere((receipt) => receipt.toolName == 'regex_test');
    expect(scriptMap(tested.result['compilation'])['status'], 'compatible');
    expect(scriptMap(tested.result['match'])['status'], 'matched');
    final usage = scriptMap(result.usage['fields']);
    expect(scriptMap(usage['prompt_tokens'])['total'], 60);
    expect(scriptMap(usage['completion_tokens'])['total'], 6);
    expect(scriptMap(usage['cache_hit_tokens'])['total'], 0);
    expect(h.requests, hasLength(3));
    expect(h.keyReads, 3);
    expect(h.requests.first.body, result.requests.first.body);
    final tools = (h.requests.first.body['tools']! as List<Object?>).map(
      (tool) => scriptMap(scriptMap(tool)['function'])['name'],
    );
    expect(
      tools,
      unorderedEquals(['draft_read', 'card_write', 'lore_write', 'regex_write', 'preset_write', 'lint', 'regex_test']),
    );
    final sentInput = scriptMap(
      jsonDecode(scriptMap((h.requests.first.body['messages']! as List<Object?>)[1])['content']! as String),
    );
    expect(scriptMap(scriptMap(sentInput['materials'])['notes'])['title'], 'captured');
    final secondMessages = (h.requests[1].body['messages']! as List<Object?>).map(scriptMap).toList();
    expect(secondMessages[2], {
      'role': 'assistant',
      'content': 'Editing. ',
      'tool_calls': [for (final call in first) call.wire],
    });
    expect(secondMessages.skip(3).map((message) => message['tool_call_id']), first.map((call) => call.id));
    for (final message in secondMessages.skip(3)) {
      final wire = scriptMap(jsonDecode(message['content']! as String));
      final receipt = (await h.engine.readAuthoringToolReceipt(run.runId, wire['receiptId']! as String))!;
      expect(receipt.toJson(), wire);
      expect(receipt.callId, message['tool_call_id']);
    }
    expect((await hot.timeout(_deadline)).last.kind, TavernAuthoringRunEventKind.terminal);
    expect((await run.events.single.timeout(_deadline)).snapshot!.status, TavernAuthoringRunStatus.completed);
    expect(await cardFile.readAsBytes(), beforeCard);
    expect(await bookFile.readAsBytes(), beforeBook);
    expect(await File('${h.root.path}/regex-library.json').exists(), isFalse);
    expect(
      h.inspect((db) => Map<String, Object?>.of(db.select('SELECT * FROM presets WHERE id = ?', [presetId]).single)),
      beforePreset,
    );
    expect(_businessRows(h), beforeBusiness);
    expect(jsonEncode(result.toJson()), isNot(contains('author-secret-header')));
    await h.engine.deleteAuthoringDraft(draft.id, draftRevision: result.currentRevision);
    final savedRequest = result.request;
    result.request.materials.clear();
    final replayInput = TavernAuthoringRunRequest(
      runId: request.runId,
      draftId: draft.id,
      draftRevision: draft.draftRevision,
      instruction: request.instruction,
      materials: {
        'notes': {'title': 'captured'},
      },
    );
    expect(savedRequest.runId, replayInput.runId);
    await h.reopen();
    final replay = await h.engine.startAuthoringRun(replayInput).result;
    expect(replay.status, TavernAuthoringRunStatus.completed);
    expect(replay.request.materials, {
      'notes': {'title': 'captured'},
    });
    expect(replay.currentRevision, draft.draftRevision + 4);
    expect(replay.receipts, hasLength(9));
    expect(h.requests, hasLength(3));
    expect(
      () => h.engine.startAuthoringRun(
        TavernAuthoringRunRequest(
          runId: run.runId,
          draftId: draft.id,
          draftRevision: draft.draftRevision,
          instruction: 'different',
        ),
      ),
      throwsA(_error('run_id_conflict')),
    );
  });

  test(
    'author prompt tool uses the captured context and explicit selection, persists the real preview and replays',
    () async {
      final h = await _fixture();
      final target = TavernAuthoringTarget(
        kind: TavernAuthoringTargetKind.character,
        id: await h.card('Preview', description: 'LIVE_DESCRIPTION'),
      );
      final draft = await h.engine.createAuthoringDraft([target]);
      final cardFile = File('${h.root.path}/characters/${target.id}/card.json');
      final beforeCard = await cardFile.readAsBytes();
      final beforeBusiness = _previewBusinessRows(h);
      final variables = <String, Object?>{'selected': 'CAPTURED_VALUE'};
      final history = <TavernAuthoringSampleMessage>[
        const TavernAuthoringSampleMessage(role: TavernRole.user, text: 'CAPTURED_HISTORY'),
      ];
      final first = h.stream(), second = h.stream();
      final run = h.engine.startAuthoringRun(
        TavernAuthoringRunRequest(
          runId: 'author-preview',
          draftId: draft.id,
          draftRevision: draft.draftRevision,
          instruction: 'Edit then preview the selected changes.',
          previewContext: TavernAuthoringSampleContext(
            characterResourceId: target.physicalResourceId,
            variables: variables,
            history: history,
          ),
        ),
      );
      variables['selected'] = 'CALLER_MUTATION';
      history[0] = const TavernAuthoringSampleMessage(role: TavernRole.user, text: 'CALLER_HISTORY');
      const at = '2026-11-12T05:00:00.123456Z';
      const parameters = <String, Object?>{
        'changeIds': ['selected'],
        'text': 'PREVIEW_USER',
        'at': at,
        'seed': 17,
      };
      await _reply(
        first,
        run,
        calls: [
          _call('write', 'card_write', {
            'physicalResourceId': target.physicalResourceId,
            'changes': [
              {
                'id': 'selected',
                'path': '/data/description',
                'operation': 'set',
                'value': 'SELECTED={{getvar::selected}}',
              },
              {'id': 'omitted', 'path': '/data/personality', 'operation': 'set', 'value': 'UNSELECTED_CHANGE'},
            ],
          }),
          _call('wrong-context', 'prompt_preview', {
            ...parameters,
            'context': {'kind': 'chat', 'chatId': 'model-choice'},
          }),
          _call('preview', 'prompt_preview', parameters),
        ],
      );
      await _listening(second, run);
      final during = (await h.engine.readAuthoringRun(run.runId))!;
      expect(during.currentRevision, draft.draftRevision + 1);
      expect(during.receipts, hasLength(3));
      expect(during.receipts[1].status, TavernAuthoringToolStatus.rejected);
      final receipt = during.receipts.last;
      expect(receipt.status, TavernAuthoringToolStatus.succeeded);
      expect(receipt.result['status'], 'complete');
      expect(receipt.result['changeIds'], ['selected']);
      expect(receipt.result['draftRevision'], during.currentRevision);
      expect(scriptMap(receipt.result['origin'])['at'], at);
      final body = scriptMap(scriptMap(receipt.result['assembly'])['body']);
      final text = jsonEncode(body);
      for (final included in ['SELECTED=CAPTURED_VALUE', 'CAPTURED_HISTORY', 'PREVIEW_USER']) {
        expect(text, contains(included));
      }
      for (final excluded in ['LIVE_DESCRIPTION', 'UNSELECTED_CHANGE', 'CALLER_MUTATION', 'CALLER_HISTORY']) {
        expect(text, isNot(contains(excluded)));
      }
      final direct = await h.engine
          .previewAuthoringPrompt(
            TavernAuthoringPromptRequest(
              requestId: receipt.result['requestId']! as String,
              draftId: draft.id,
              draftRevision: during.currentRevision,
              changeIds: const ['selected'],
              context: during.request.previewContext!,
              at: DateTime.parse(at),
              seed: 17,
              text: 'PREVIEW_USER',
            ),
          )
          .result;
      expect(receipt.result, direct.toJson());
      final tools = (h.requests.first.body['tools']! as List<Object?>).map(
        (tool) => scriptMap(scriptMap(tool)['function'])['name'],
      );
      expect(
        tools,
        unorderedEquals([
          'draft_read',
          'card_write',
          'lore_write',
          'regex_write',
          'preset_write',
          'lint',
          'regex_test',
          'prompt_preview',
        ]),
      );
      final sent = scriptMap(
        jsonDecode(scriptMap((h.requests.first.body['messages']! as List<Object?>)[1])['content']! as String),
      );
      expect(scriptMap(scriptMap(sent['previewContext'])['variables']), {'selected': 'CAPTURED_VALUE'});
      final returned = (h.requests.last.body['messages']! as List<Object?>).map(scriptMap).last;
      expect(jsonDecode(returned['content']! as String), receipt.toJson());
      await _reply(second, run, text: 'Prepared the selected prompt.');
      final result = await run.result.timeout(_deadline);
      expect(result.status, TavernAuthoringRunStatus.completed);
      expect((h.requests.length, h.keyReads), (2, 2));
      expect(_previewBusinessRows(h), beforeBusiness);
      expect(await cardFile.readAsBytes(), beforeCard);
      final replayInput = result.request;
      await h.engine.deleteAuthoringDraft(draft.id, draftRevision: result.currentRevision);
      await h.reopen();
      final replay = await h.engine.startAuthoringRun(replayInput).result;
      expect(replay.receipts.last.toJson(), receipt.toJson());
      expect((await h.engine.readAuthoringToolReceipt(run.runId, receipt.receiptId))!.toJson(), receipt.toJson());
      expect((h.requests.length, h.keyReads), (2, 2));
    },
  );

  test(
    'an admitted author preview starts during backup and cancellation waits for its original resource read',
    () async {
      final h = await _fixture();
      final target = TavernAuthoringTarget(kind: TavernAuthoringTargetKind.character, id: await h.card('Held preview'));
      final chat = await h.emptyChat(target.id);
      await h.engine.putLorebook('preview-gate', {'name': 'Gate', 'entries': <String, Object?>{}});
      await h.engine.bindLorebooks(['preview-gate']);
      final draft = await h.engine.createAuthoringDraft([target]);
      final work = await Directory.systemTemp.createTemp('dsh-author-preview-backup-');
      addTearDown(() async {
        if (await work.exists()) {
          await work.delete(recursive: true);
        }
      });
      final gate = _AuthoringReadGate();
      final plan = h.stream();
      final engine = h.engine;
      final archive = File('${work.path}/author-preview.zip');
      await _withAuthoringReadGate(File('${h.root.path}/lorebooks/preview-gate.json'), gate, () async {
        final run = engine.startAuthoringRun(
          TavernAuthoringRunRequest(
            runId: 'preview-drain',
            draftId: draft.id,
            draftRevision: draft.draftRevision,
            instruction: 'Preview this draft.',
            previewContext: TavernAuthoringChatContext(chatId: chat),
          ),
        );
        var backupDone = false, runDone = false, cancelDone = false, closeDone = false;
        Future<void>? backup, cancelling, closing;
        unawaited(
          run.result.then<void>(
            (_) {
              runDone = true;
            },
            onError: (Object _, StackTrace _) {
              runDone = true;
            },
          ),
        );
        try {
          await _listening(plan, run);
          backup = engine.backup(archive.path).then<void>((_) {
            backupDone = true;
          });
          await Future<void>.delayed(Duration.zero);
          expect(backupDone, isFalse);
          await _reply(
            plan,
            run,
            calls: [
              _call('held-preview', 'prompt_preview', {
                'changeIds': <String>[],
                'text': '',
                'at': '2026-11-12T05:00:00Z',
                'seed': 1,
              }),
            ],
          );
          await Future.any([
            gate.entered.future,
            run.result.then<void>(
              (value) => throw TestFailure('Run ended before its actual preview read: ${value.status.name}'),
            ),
          ]).timeout(_deadline);
          cancelling = engine.cancelAuthoringRun(run.runId).then<void>((_) {
            cancelDone = true;
          });
          closing = h.close().then<void>((_) {
            closeDone = true;
          });
          await Future<void>.delayed(Duration.zero);
          expect((backupDone, runDone, cancelDone, closeDone), (false, false, false, false));
          gate.release();
          await cancelling.timeout(_deadline);
          await backup.timeout(_deadline);
          await closing.timeout(_deadline);
          final result = await run.result.timeout(_deadline);
          expect(result.status, TavernAuthoringRunStatus.cancelled);
          expect(result.receipts, isEmpty);
          expect(result.currentRevision, draft.draftRevision);
          expect((h.requests.length, h.keyReads), (1, 1));
          expect(await archive.exists(), isTrue);
        } finally {
          // Release test-owned I/O before waiting for the original owners, even
          // when an assertion fails before the explicit cancel/close above.
          gate.release();
          await plan.dispose();
          final closeDrain = closing ?? h.close();
          await Future.wait<void>([?cancelling, ?backup, closeDrain]);
        }
      });
    },
  );

  test('a real preview resource decode error remains the run failure instead of an invalid tool argument', () async {
    final h = await _fixture();
    final target = TavernAuthoringTarget(kind: TavernAuthoringTargetKind.character, id: await h.card('Decode failure'));
    final chat = await h.emptyChat(target.id);
    await h.engine.putLorebook('broken-preview', {'name': 'Before', 'entries': <String, Object?>{}});
    await h.engine.bindLorebooks(['broken-preview']);
    final draft = await h.engine.createAuthoringDraft([target]);
    // This is an actual externally malformed dependency, not malformed model
    // arguments or a replacement of the capture implementation.
    await File('${h.root.path}/lorebooks/broken-preview.json').writeAsString('{');
    final plan = h.stream();
    final run = h.engine.startAuthoringRun(
      TavernAuthoringRunRequest(
        runId: 'preview-decode-error',
        draftId: draft.id,
        draftRevision: draft.draftRevision,
        instruction: 'Preview.',
        previewContext: TavernAuthoringChatContext(chatId: chat),
      ),
    );
    final failed = expectLater(run.result, throwsFormatException);
    await _reply(
      plan,
      run,
      calls: [
        _call('decode', 'prompt_preview', {
          'changeIds': <String>[],
          'text': '',
          'at': '2026-11-12T05:00:00Z',
          'seed': 1,
        }),
      ],
    );
    await failed.timeout(_deadline);
    final result = (await h.engine.readAuthoringRun(run.runId))!;
    expect(result.status, TavernAuthoringRunStatus.failed);
    expect(result.receipts, isEmpty);
    expect(result.currentRevision, draft.draftRevision);
    expect((h.requests.length, h.keyReads), (1, 1));
  });

  test('the fourth tool response executes nothing and preserves the first three draft commits', () async {
    final h = await _fixture();
    final target = TavernAuthoringTarget(kind: TavernAuthoringTargetKind.character, id: await h.card('Budget'));
    final draft = await h.engine.createAuthoringDraft([target]);
    final plans = [for (var index = 0; index < 4; index++) h.stream()];
    final run = h.engine.startAuthoringRun(_request('budget', draft));
    for (var index = 0; index < 3; index++) {
      await _reply(
        plans[index],
        run,
        calls: [
          _call('write-$index', 'card_write', _write(target, 'change-$index', '/data/extensions/step$index', index)),
        ],
      );
    }
    await _reply(
      plans[3],
      run,
      calls: [
        _call('never', 'card_write', _write(target, 'never', '/data/name', 'Never committed')),
        const _Call(null, 'card_write', '{}'),
      ],
    );
    final result = await run.result.timeout(_deadline);
    expect(result.status, TavernAuthoringRunStatus.budget);
    expect(result.requests, hasLength(4));
    expect(result.receipts, hasLength(3));
    expect(result.currentRevision, draft.draftRevision + 3);
    expect(result.issues.any((issue) => issue.type == 'budget_exhausted'), isTrue);
    expect((await h.engine.readAuthoringDraft(draft.id))!.changes.map((change) => change.id), [
      'change-0',
      'change-1',
      'change-2',
    ]);
    expect((await h.engine.character(target.id))!.name, 'Budget');
    expect(h.requests, hasLength(4));
  });

  test('an unreturnable tool identity prevents every call in its batch from editing', () async {
    final h = await _fixture();
    final target = TavernAuthoringTarget(kind: TavernAuthoringTargetKind.character, id: await h.card('Protocol'));
    final draft = await h.engine.createAuthoringDraft([target]);
    final plan = h.stream();
    final run = h.engine.startAuthoringRun(_request('bad-identity', draft));
    await _reply(
      plan,
      run,
      calls: [
        _call('valid', 'card_write', _write(target, 'would-write', '/data/name', 'Must not write')),
        const _Call(null, 'draft_read', '{}'),
      ],
    );
    await expectLater(run.result, throwsA(_error('protocol_invalid')));
    final result = (await h.engine.readAuthoringRun(run.runId))!;
    expect(result.status, TavernAuthoringRunStatus.failed);
    expect(result.receipts, isEmpty);
    expect((await h.engine.readAuthoringDraft(draft.id))!.draftRevision, draft.draftRevision);
    expect(h.requests, hasLength(1));
  });

  test('an App edit wins draft CAS while earlier author receipts remain committed', () async {
    final h = await _fixture();
    final target = TavernAuthoringTarget(kind: TavernAuthoringTargetKind.character, id: await h.card('CAS'));
    final draft = await h.engine.createAuthoringDraft([target]);
    final first = h.stream(), second = h.stream();
    final run = h.engine.startAuthoringRun(_request('app-wins', draft));
    await _reply(
      first,
      run,
      calls: [_call('first', 'card_write', _write(target, 'first', '/data/name', 'Author first'))],
    );
    await _listening(second, run);
    final current = (await h.engine.readAuthoringDraft(draft.id))!;
    final app = await h.engine.editAuthoringDraft(
      draft.id,
      draftRevision: current.draftRevision,
      changes: [
        ...current.changes,
        TavernAuthoringChange(
          id: 'app',
          physicalResourceId: target.physicalResourceId,
          path: '/data/name',
          operation: TavernAuthoringChangeKind.set,
          value: 'App choice',
          dependsOn: ['first'],
        ),
      ],
    );
    await _reply(
      second,
      run,
      calls: [
        _call('late', 'card_write', _write(target, 'late', '/data/name', 'Late author', dependsOn: ['first'])),
      ],
    );
    final result = await run.result.timeout(_deadline);
    expect(result.status, TavernAuthoringRunStatus.conflict);
    expect(result.receipts, hasLength(1));
    expect(result.currentRevision, current.draftRevision);
    expect((await h.engine.readAuthoringDraft(draft.id))!.draftRevision, app.draftRevision);
    final preview = await h.engine.previewAuthoringDraft(
      draft.id,
      draftRevision: app.draftRevision,
      changeIds: ['first', 'app'],
    );
    expect(scriptMap(preview.candidates[target.physicalResourceId]!['data'])['name'], 'App choice');
    expect(h.requests, hasLength(2));
  });

  test(
    'cancel stays available during backup and close drains the real response without undoing the saved draft',
    () async {
      final h = await _fixture();
      final target = TavernAuthoringTarget(kind: TavernAuthoringTargetKind.character, id: await h.card('Cancel'));
      final draft = await h.engine.createAuthoringDraft([target]);
      final immediate = h.engine.startAuthoringRun(_request('cancel-before-request', draft));
      await immediate.cancel().timeout(_deadline);
      expect((await immediate.result).status, TavernAuthoringRunStatus.cancelled);
      expect((await immediate.result).requests, isEmpty);
      expect(h.requests, isEmpty);
      final first = h.stream(), second = h.stream();
      final engine = h.engine;
      final run = engine.startAuthoringRun(_request('cancel-drain', draft));
      await _reply(
        first,
        run,
        calls: [_call('saved', 'card_write', _write(target, 'saved', '/data/name', 'Saved draft'))],
      );
      await _listening(second, run);
      final work = await Directory.systemTemp.createTemp('dsh-author-run-backup-');
      addTearDown(() async {
        if (await work.exists()) {
          await work.delete(recursive: true);
        }
      });
      final archive = File('${work.path}/author.zip');
      var backedUp = false, cancelDone = false, closeDone = false, runDone = false;
      Future<void>? backup, cancelling, closing;
      unawaited(
        run.result.then<void>(
          (_) {
            runDone = true;
          },
          onError: (Object _, StackTrace _) {
            runDone = true;
          },
        ),
      );
      try {
        backup = engine.backup(archive.path).then<void>((_) {
          backedUp = true;
        });
        await Future<void>.delayed(Duration.zero);
        expect(backedUp, isFalse);
        cancelling = engine.cancelAuthoringRun(run.runId).then<void>((_) {
          cancelDone = true;
        });
        closing = h.close().then<void>((_) {
          closeDone = true;
        });
        await Future<void>.delayed(Duration.zero);
        // The fixture peer does not implement AbortableRequest. Its accepted
        // SSE body is still real owned work, so none of these may finish yet.
        expect((runDone, cancelDone, backedUp, closeDone), (false, false, false, false));
        expect(h.peers.last.closed, isFalse);
        second.delta('LATE_AFTER_AUTHOR_CANCEL');
        await second.source!.close();
        await cancelling.timeout(_deadline);
        await backup.timeout(_deadline);
        await closing.timeout(_deadline);
        final result = await run.result;
        expect(result.status, TavernAuthoringRunStatus.cancelled);
        expect(result.currentRevision, draft.draftRevision + 1);
        expect(result.receipts.single.changeIds, ['saved']);
        expect(result.requests.last.status, TavernAuthoringRequestStatus.cancelled);
        expect(result.answer, isNot(contains('LATE_AFTER_AUTHOR_CANCEL')));
        expect(result.requests.last.text, isNot(contains('LATE_AFTER_AUTHOR_CANCEL')));
        expect(h.peers.every((peer) => peer.closed), isTrue);
        expect(await archive.exists(), isTrue);
        final destination = Directory('${work.path}/restored');
        await restoreTavernDirectory(archive.path, destination.path);
        final restored = await TavernEngine.openDirectory(destination);
        addTearDown(restored.close);
        expect((await restored.readAuthoringRun(run.runId))!.status, TavernAuthoringRunStatus.cancelled);
        expect((await restored.readAuthoringDraft(draft.id))!.draftRevision, draft.draftRevision + 1);
        expect((await restored.readAuthoringToolReceipt(run.runId, result.receipts.single.receiptId))!.changeIds, [
          'saved',
        ]);
        expect(h.requests, hasLength(2));
      } finally {
        // Release the test-owned body even if an assertion fails. Keep the
        // started backup/close futures ahead of the directory's tearDown.
        await second.dispose();
        final closeDrain = closing ?? h.close();
        await Future.wait<void>([?cancelling, ?backup, closeDrain]);
      }
    },
  );

  test(
    'outer SQL commit preserves admission and tool receipts after publication failure and reopening never resends',
    () async {
      final h = await _fixture();
      const target = TavernAuthoringTarget(kind: TavernAuthoringTargetKind.lorebook, id: 'sql');
      await h.engine.putLorebook(target.id, {'name': 'Before', 'entries': <String, Object?>{}});
      final draft = await h.engine.createAuthoringDraft([target]);
      final input = _request('stored-unfinished', draft);
      await h.close();
      final store = ChatStore.open('${h.root.path}/tavern.sqlite3');
      addTearDown(store.close);
      var admitted = false;
      store.committedObserver = (_, _) {
        throw StateError('Real COMMIT observer failure.');
      };
      expect(
        () => store.admitAuthoringRunData(
          input.toJson(),
          {'provider': 'deepseek', 'model': 'fixture'},
          onCommitted: (_, created) {
            admitted = created;
          },
        ),
        throwsStateError,
      );
      expect(admitted, isTrue);
      store.committedObserver = null;
      var createdAgain = true;
      store.admitAuthoringRunData(
        input.toJson(),
        {'provider': 'deepseek', 'model': 'fixture'},
        onCommitted: (_, created) {
          createdAgain = created;
        },
      );
      expect(createdAgain, isFalse);
      // Exercise the actual storage transaction independently of transport; no
      // HTTP or model adoption is claimed for this registered storage fixture.
      store.registerAuthoringRequestData(input.runId, 1, {'messages': <Object?>[]}, onCommitted: (_) {});
      store.finishAuthoringRequestData(
        input.runId,
        1,
        status: TavernAuthoringRequestStatus.completed,
        response: {'responseComplete': true, 'finishReason': 'tool_calls'},
        answer: '',
        onCommitted: () {},
      );
      final previous = store.readAuthoringDraftData(draft.id)!;
      final data = {
        ...previous.data,
        'changes': [
          {
            'id': 'saved',
            'physicalResourceId': target.physicalResourceId,
            'path': '/name',
            'operation': 'set',
            'value': 'Saved',
            'dependsOn': <String>[],
          },
        ],
      };
      TavernAuthoringToolReceipt? adopted;
      TavernAuthoringToolReceipt commit(int callIndex) => store.commitAuthoringToolData(
        input.runId,
        requestIndex: 1,
        callIndex: callIndex,
        callId: 'call-$callIndex',
        toolName: 'lore_write',
        arguments: '{}',
        revision: callIndex == 0 ? draft.draftRevision : draft.draftRevision + 1,
        status: TavernAuthoringToolStatus.succeeded,
        result: {'saved': true},
        changeIds: ['saved'],
        draftData: data,
        onCommitted: (receipt) {
          adopted = receipt;
        },
      );
      store.committedObserver = (_, _) {
        throw StateError('Real COMMIT observer failure.');
      };
      expect(() => commit(0), throwsStateError);
      expect(adopted!.afterRevision, draft.draftRevision + 1);
      store.committedObserver = null;
      expect(commit(0).toJson(), adopted!.toJson());
      expect(store.readAuthoringDraftData(draft.id)!.revision, draft.draftRevision + 1);
      h.inspect(
        (db) => db.execute("""
      CREATE TRIGGER author_receipt_abort BEFORE INSERT ON authoring_receipts
      WHEN NEW.call_index = 1 BEGIN SELECT RAISE(ABORT, 'receipt fixture'); END
    """),
        writable: true,
      );
      expect(() => commit(1), throwsA(isA<SqliteException>()));
      expect(store.readAuthoringDraftData(draft.id)!.revision, draft.draftRevision + 1);
      expect(store.readAuthoringToolReceiptData(input.runId, '1:1'), isNull);
      expect(store.readAuthoringRunData(input.runId)!.currentRevision, draft.draftRevision + 1);
      await store.close();
      await h.reopen();
      final interrupted = await h.engine.startAuthoringRun(input).result;
      expect(interrupted.status, TavernAuthoringRunStatus.interrupted);
      expect(interrupted.receipts, hasLength(1));
      expect(interrupted.requests.single.attempts, isEmpty);
      expect(h.requests, isEmpty);
      expect((await h.engine.listAuthoringRuns(draftId: draft.id)).single.runId, input.runId);

      h.inspect(
        (db) => db.execute("""
      CREATE TRIGGER author_attempt_abort BEFORE UPDATE OF status ON authoring_requests
      WHEN NEW.run_id = 'attempt-observed' AND NEW.status = 'running'
      BEGIN SELECT RAISE(ABORT, 'attempt fixture'); END
    """),
        writable: true,
      );
      final current = (await h.engine.readAuthoringDraft(draft.id))!;
      final actualSend = h.stream();
      final headers = Completer<void>();
      addTearDown(() {
        if (!headers.isCompleted) {
          headers.complete();
        }
      });
      actualSend.beforeResponse = () => headers.future;
      final failed = h.engine.startAuthoringRun(_request('attempt-observed', current));
      try {
        await actualSend.seen.future.timeout(_deadline);
        await expectLater(failed.result.timeout(_deadline), throwsA(isA<SqliteException>()));
        expect(headers.isCompleted, isFalse);
        final recorded = (await h.engine.readAuthoringRun(failed.runId))!;
        expect(recorded.status, TavernAuthoringRunStatus.failed);
        expect(recorded.requests.single.attempts, [0]);
        expect(recorded.requests.single.status, TavernAuthoringRequestStatus.failed);
        expect(h.requests, hasLength(1));
        expect(h.peers.every((peer) => peer.closed), isTrue);
      } finally {
        headers.complete();
      }

      h.inspect(
        (db) => db.execute("""
      CREATE TRIGGER author_seal_abort BEFORE UPDATE OF status ON authoring_requests
      WHEN NEW.run_id = 'seal-failed' AND NEW.status = 'completed'
      BEGIN SELECT RAISE(ABORT, 'seal fixture'); END
    """),
        writable: true,
      );
      final response = h.stream();
      final unsealed = h.engine.startAuthoringRun(_request('seal-failed', current));
      await _reply(response, unsealed, text: 'A real response before SQL seal failure.', prompt: 9, completion: 2);
      await expectLater(unsealed.result, throwsA(isA<SqliteException>()));
      final live = (await h.engine.readAuthoringRun(unsealed.runId))!;
      expect(live.status, TavernAuthoringRunStatus.failed);
      expect(live.requests.single.attempts, [0]);
      expect(live.requests.single.text, 'A real response before SQL seal failure.');
      expect(live.requests.single.responseComplete, isTrue);
      expect(scriptMap(scriptMap(live.usage['fields'])['prompt_tokens'])['total'], 9);
      expect(live.issues.where((issue) => issue.type == 'request_record_failed'), hasLength(1));
      await h.reopen();
      final durable = (await h.engine.readAuthoringRun(unsealed.runId))!;
      expect(durable.status, TavernAuthoringRunStatus.failed);
      expect(durable.requests.single.text, isEmpty);
      expect(durable.issues.where((issue) => issue.type == 'request_record_failed'), hasLength(1));
    },
  );
}

Future<ScriptFixture> _fixture() async {
  final h = await slashFixture(allowModel: true);
  h.config = TavernModelConfig(
    apiKey: h.config.apiKey,
    baseUrl: 'https://author.invalid/v1',
    model: 'author-fixture',
    deepseek: true,
    thinking: false,
    headers: {'X-Author-Fixture': 'author-secret-header'},
  );
  await h.reopen();
  return h;
}

TavernAuthoringRunRequest _request(String id, TavernAuthoringDraft draft) => TavernAuthoringRunRequest(
  runId: id,
  draftId: draft.id,
  draftRevision: draft.draftRevision,
  instruction: 'Revise this draft.',
);

TypeMatcher<TavernAuthoringException> _error(String code) =>
    isA<TavernAuthoringException>().having((error) => error.code, 'code', code);

Map<String, int> _businessRows(ScriptFixture h) => h.inspect(
  (db) => {
    for (final table in ['chats', 'nodes', 'tool_turns', 'agent_runs'])
      table: db.select('SELECT count(*) AS n FROM $table').single['n'] as int,
  },
);

Map<String, Object?> _previewBusinessRows(ScriptFixture h) => h.inspect(
  (db) => {
    for (final table in ['chats', 'nodes', 'tool_turns', 'agent_runs'])
      table: [for (final row in db.select('SELECT * FROM $table')) Map<String, Object?>.from(row)],
  },
);

Future<void> _withAuthoringReadGate(File file, _AuthoringReadGate gate, Future<void> Function() body) async {
  final parent = Zone.current;
  final aliases = {file.absolute.uri, File(await file.resolveSymbolicLinks()).absolute.uri};
  try {
    await IOOverrides.runZoned(
      body,
      createFile: (path) {
        final real = parent.run(() => File(path));
        return aliases.contains(parent.run(() => real.absolute.uri)) ? _AuthoringGatedFile(real, gate) : real;
      },
    );
  } finally {
    gate.release();
    if (gate.entered.isCompleted) {
      await gate.finished.future;
    }
  }
}

class _AuthoringReadGate {
  final entered = Completer<void>();
  final finished = Completer<void>();
  final _released = Completer<void>();
  void release() {
    if (!_released.isCompleted) {
      _released.complete();
    }
  }

  Future<T> read<T>(Future<T> Function() action) async {
    if (entered.isCompleted) {
      return action();
    }
    entered.complete();
    try {
      await _released.future;
      return await action();
    } finally {
      finished.complete();
    }
  }
}

class _AuthoringGatedFile implements File {
  _AuthoringGatedFile(this.real, this.gate);
  final File real;
  final _AuthoringReadGate gate;
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
  Future<File> copy(String newPath) => real.copy(newPath);
  @override
  Future<Uint8List> readAsBytes() => gate.read(real.readAsBytes);
  @override
  Future<String> readAsString({Encoding encoding = utf8}) => gate.read(() => real.readAsString(encoding: encoding));
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Map<String, Object?> _write(
  TavernAuthoringTarget target,
  String id,
  String path,
  Object? value, {
  List<String> dependsOn = const [],
}) => {
  'physicalResourceId': target.physicalResourceId,
  'changes': [
    {'id': id, 'path': path, 'operation': 'set', 'value': value, 'dependsOn': dependsOn},
  ],
};

final class _Call {
  const _Call(this.id, this.name, this.arguments);
  final String? id;
  final String name, arguments;
  Map<String, Object?> get wire => {
    'id': ?id,
    'type': 'function',
    'function': {'name': name, 'arguments': arguments},
  };
}

_Call _call(String id, String name, Map<String, Object?> parameters) => _Call(id, name, jsonEncode(parameters));

Future<void> _listening(ScriptResponsePlan plan, TavernAuthoringRun run) => Future.any([
  plan.listening.future,
  run.result.then<void>(
    (value) => throw TestFailure('Author run ended before its expected request: ${value.status.name}'),
  ),
]).timeout(_deadline);

Future<void> _reply(
  ScriptResponsePlan plan,
  TavernAuthoringRun run, {
  List<_Call> calls = const [],
  String? text,
  int prompt = 1,
  int completion = 1,
}) async {
  await _listening(plan, run);
  final delta = {
    'role': 'assistant',
    'content': text,
    if (calls.isNotEmpty)
      'tool_calls': [
        for (var i = 0; i < calls.length; i++) {'index': i, ...calls[i].wire},
      ],
  };
  final event = {
    'choices': [
      {'index': 0, 'delta': delta, 'finish_reason': calls.isEmpty ? 'stop' : 'tool_calls'},
    ],
    'usage': {'prompt_tokens': prompt, 'completion_tokens': completion, 'prompt_cache_hit_tokens': 0},
  };
  plan.source!.add(utf8.encode('data: ${jsonEncode(event)}\n\ndata: [DONE]\n\n'));
  await plan.source!.close();
}

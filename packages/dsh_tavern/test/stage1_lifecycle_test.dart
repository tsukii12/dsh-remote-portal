import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:test/test.dart';

import 'p2_script_test_support.dart';
import 'support/stage1_engine_harness.dart';
import 'support/t24_engine_harness.dart' show t24Card;

void main() {
  test('beforeTurn body and local writes advance ownership before the one actual prompt is assembled', () async {
    final h = await ScriptFixture.open(allowModel: true);
    final card = await h.card('Hooks', greeting: 'ORIGINAL_GREETING');
    final chat = await h.engine.createChat(card);
    final greeting = (await h.engine.path(chat)).single;
    final context = await h.context(chat, characterId: card);
    await h.engine.setPreset(scriptPreset(main: 'LOCAL={{getvar::phase}}'));
    final originalVersion = h.inspect(
      (db) =>
          db.select('SELECT content_version FROM nodes WHERE id = ?', [greeting.nodeId]).single['content_version']!
              as int,
    );
    final host = ScriptHost();
    host.onDispatch = (request, cancellation) async {
      if (request.name == 'GENERATION_AFTER_COMMANDS') {
        await h.bridge.setChatMessages(context.id, [
          TavernScriptMessagePatch(
            ref: TavernScriptMessageRef(chatId: chat, nodeId: greeting.nodeId),
            fields: {'message': 'HOOK_GREETING'},
          ),
        ], options: const TavernScriptWriteOptions(refresh: TavernScriptRefresh.none));
        await h.bridge.replaceVariables(context.id, scriptChat, {'phase': 'PREPARED'});
      }
      return TavernScriptDispatchAck(eventId: request.eventId);
    };
    h.bridge.attachHost(host);
    h.reply('ANSWER');
    final events = await h.engine.send(chat, 'QUESTION').toList();
    expect(events.whereType<TavernTurnFailed>(), isEmpty);
    expect(events.whereType<TavernTurnDone>().single.hookIssues, isEmpty);
    expect(h.requests, hasLength(1));
    final wire = jsonEncode(h.requests.single.body['messages']);
    expect(wire, contains('HOOK_GREETING'));
    expect(wire, contains('LOCAL=PREPARED'));
    expect(wire, isNot(contains('ORIGINAL_GREETING')));
    final logical = events.whereType<TavernTurnStarted>().single.logicalTurnId!;
    final turn = (await h.engine.readToolTurn(logical))!;
    expect(turn.admissionAnchor.selectedLeaf!.contentVersion, originalVersion);
    expect(
      h.inspect(
        (db) =>
            db.select('SELECT content_version FROM nodes WHERE id = ?', [greeting.nodeId]).single['content_version'],
      ),
      greaterThan(originalVersion),
    );
    expect(turn.outcome, 'normal');
    expect(turn.normalFinalAdopted, isTrue);
    expect(turn.budgetUsed, 1);
  });

  test('stopping in the Started listener leaves no request budget or empty reply', () async {
    final h = await Stage1Harness.open();
    final before = await h.engine.path(h.chatId);
    final events = await h.engine
        .send(h.chatId, 'cancel before request')
        .map((event) {
          if (event is TavernTurnStarted) h.engine.stop(h.chatId);
          return event;
        })
        .toList()
        .timeout(const Duration(seconds: 5));
    final started = events.whereType<TavernTurnStarted>().single;
    final failed = events.whereType<TavernTurnFailed>().single;
    expect(started.message.text, isEmpty);
    expect(started.logicalTurnId, isNotNull);
    expect(failed.logicalTurnId, started.logicalTurnId);
    expect(failed.kind, TavernFailure.cancelled);
    expect(failed.partial, isNull);
    expect(events.whereType<TavernTurnDone>(), isEmpty);
    expect(h.model.generated, 0);
    final turn = (await h.engine.readToolTurn(started.logicalTurnId!))!;
    expect(turn.status, 'failed');
    expect(turn.outcome, 'cancelled');
    expect(turn.budgetUsed, 0);
    expect(turn.requests, isEmpty);
    expect(turn.replyCommitAdopted, isFalse);
    expect(turn.normalFinalAdopted, isFalse);
    expect(
      h.database((db) => db.select('SELECT id FROM tool_requests WHERE logical_turn_id = ?', [turn.logicalTurnId])),
      isEmpty,
    );
    expect((await h.engine.path(h.chatId)).map((message) => message.nodeId), before.map((message) => message.nodeId));
    expect(
      h
          .database((db) => db.select('SELECT id FROM nodes WHERE chat_id = ? ORDER BY seq', [h.chatId]))
          .map((row) => row['id']),
      before.map((message) => message.nodeId),
    );
  });

  test('a captured beforeTurn write loses its permit when stop wins before its SQL callback', () async {
    final h = await ScriptFixture.open();
    final card = await h.card('Cancelled hooks', greeting: 'UNCHANGED');
    final chat = await h.engine.createChat(card);
    final before = await h.engine.path(chat);
    final context = await h.context(chat, characterId: card);
    final checked = Completer<void>();
    final host = ScriptHost();
    host.onDispatch = (request, cancellation) async {
      if (request.name == 'GENERATION_AFTER_COMMANDS') {
        final write = h.bridge.replaceVariables(context.id, scriptChat, {'late': true});
        checked.complete(
          expectLater(
            write,
            throwsA(scriptError(TavernScriptErrorCode.busy).having((error) => error.committed, 'committed', false)),
          ),
        );
        h.engine.stop(chat);
        await checked.future;
      }
      return TavernScriptDispatchAck(eventId: request.eventId);
    };
    h.bridge.attachHost(host);
    final events = await h.engine.send(chat, 'never append').toList();
    await checked.future;
    final failed = events.whereType<TavernTurnFailed>().single;
    expect(failed.kind, TavernFailure.cancelled);
    expect(events.whereType<TavernTurnStarted>(), isEmpty);
    expect((await h.engine.path(chat)).map((message) => message.nodeId), before.map((message) => message.nodeId));
    expect(await h.engine.readVariables(chat), isEmpty);
    final turn = (await h.engine.readToolTurn(failed.logicalTurnId!))!;
    expect(turn.requests, isEmpty);
    expect(turn.status, 'failed');
    expect(turn.replyCommitAdopted, isFalse);
    h.expectNoGeneration();
    await h.bridge.replaceVariables(context.id, scriptChat, {'fresh': true});
    expect(await h.engine.readVariables(chat), {'fresh': true});
  });

  test('native data writes retain cancellation and drain before independently changing local variables', () async {
    final h = await ScriptFixture.open(allowModel: true);
    final card = await h.card('Native drain', greeting: 'G');
    final chat = await h.engine.createChat(card);
    final context = await h.context(chat, characterId: card);
    await h.engine.setPreset(scriptPreset(streaming: true));
    final response = h.stream();
    final events = ScriptEvents(h.engine.send(chat, 'Q'));
    await events.waitRequest(response);
    await response.listening.future;
    response.delta('PARTIAL');
    await events.until((event) => event is TavernTextDelta);
    await h.bridge.replaceVariables(context.id, scriptChat, {'afterDrain': 7});
    await events.done.future;
    expect(events.values.whereType<TavernTurnFailed>().single.kind, TavernFailure.cancelled);
    expect((await h.engine.path(chat)).last.text, 'PARTIAL');
    expect(await h.engine.readVariables(chat), {'afterDrain': 7});
    expect(h.requests, hasLength(1));
    final turn = (await h.engine.readToolTurn(events.values.whereType<TavernTurnStarted>().single.logicalTurnId!))!;
    expect(turn.replyCommitAdopted, isTrue);
    expect(turn.normalFinalAdopted, isFalse);
    expect(turn.outcome, 'cancelled');
  });

  test('afterMessage observes normal adoption and its later edit invalidates an already accepted source', () async {
    final h = await Stage1Harness.open();
    await h.enableMemory(mode: 'auto');
    final bridge = h.engine.scripts;
    final context = await bridge.openContext(
      TavernScriptContextSpec(instanceId: 'stage1-after-message', chatId: h.chatId, characterId: h.characterId),
    );
    final host = ScriptHost();
    TavernToolTurnSnapshot? observed;
    host.onDispatch = (request, cancellation) async {
      if (request.name == 'MESSAGE_RECEIVED') {
        observed = (await h.engine.readToolTurn(request.generationId!))!;
        expect(observed!.normalFinalAdopted, isTrue);
        expect(observed!.proposals.single.workflow, 'accepted');
        expect(observed!.proposals.single.sourceValidity, 'bound');
        await bridge.setChatMessages(context.id, [
          TavernScriptMessagePatch(ref: request.nodeRef!, fields: {'message': 'HOOK_EDIT'}),
        ], options: const TavernScriptWriteOptions(refresh: TavernScriptRefresh.none));
      }
      return TavernScriptDispatchAck(eventId: request.eventId);
    };
    bridge.attachHost(host);
    final active = await h.start();
    await stage1Finish(
      active.call,
      content: 'MODEL_BODY',
      tools: [
        Stage1Call(0, 'memory', 'remember', {
          'text': 'historical source',
          'keywords': ['history'],
        }),
      ],
    );
    await active.events.done.future;
    expect(active.events.values.whereType<TavernTurnFailed>(), isEmpty);
    final done = active.events.values.whereType<TavernTurnDone>().single;
    expect(done.hookIssues, isEmpty);
    expect(done.message.text, 'HOOK_EDIT');
    expect(observed, isNotNull);
    final turn = await h.turn(active.events);
    expect(turn.normalFinalAdopted, isTrue);
    expect(turn.proposals.single.workflow, 'accepted');
    expect(turn.proposals.single.sourceValidity, 'invalidated');
    expect(turn.proposals.single.version, observed!.proposals.single.version + 1);
    final receipt = (await h.engine.readToolReceipt(turn.receiptIds.single))!;
    expect(receipt.committed, isTrue);
    expect(receipt.sourceValidity, 'invalidated');
    expect(h.model.generated, 1);
    await h.reopen();
    expect((await h.engine.readToolTurn(turn.logicalTurnId))!.proposals.single.sourceValidity, 'invalidated');
  });

  test(
    'empty-turn cleanup CAS loss publishes anchor_changed and preserves the actually visible foreign body',
    () async {
      final h = await Stage1Harness.open();
      final active = await h.start(input: 'KEEP_USER');
      final before = await h.turn(active.events);
      final candidate = before.candidateSource!;
      h.database((db) => db.execute('UPDATE nodes SET text = ? WHERE id = ?', ['FOREIGN_BODY', candidate.nodeId]));
      h.engine.stop(h.chatId);
      await active.events.done.future;
      await active.call.close();
      final failure = active.events.values.whereType<TavernTurnFailed>().single;
      expect(failure.kind, TavernFailure.toolFailure);
      expect(failure.partial!.nodeId, candidate.nodeId);
      expect(failure.partial!.text, 'FOREIGN_BODY');
      final turn = await h.turn(active.events);
      expect(turn.outcome, 'anchor_changed');
      expect(turn.replyCommitAdopted, isFalse);
      expect(turn.normalFinalAdopted, isFalse);
      final inspection = (await h.engine.inspectTurn(h.chatId))!;
      expect(inspection.failure, TavernFailure.toolFailure);
      expect(inspection.detail, contains('tool_anchor_changed'));
      expect(
        (await h.engine.path(h.chatId)).map((message) => message.text),
        containsAllInOrder(['KEEP_USER', 'FOREIGN_BODY']),
      );
      final summary = h.database(
        (db) => stage1Map(
          jsonDecode(
            db.select('SELECT summary_json FROM tool_turns WHERE id = ?', [turn.logicalTurnId]).single['summary_json']!
                as String,
          ),
        ),
      );
      expect(summary['toolFailureCode'], 'anchor_changed');
      expect(h.dice.calls, 0);
    },
  );

  test('a library-queued group mutation cancels an unstarted manual policy job without a wait cycle', () async {
    final h = await Stage1Harness.open();
    final raw = stage1Map(jsonDecode(utf8.decode(t24Card())));
    stage1Map(raw['data'])['name'] = 'Added member';
    final member = await h.engine.importCard(Uint8List.fromList(utf8.encode(jsonEncode(raw))));
    final group = await h.engine.createGroupChat([h.characterId], addGreetings: false);
    // Both calls are admitted in this synchronous stack. addGroupMember enters
    // its library callback later; manual policy is queued behind that callback.
    final adding = h.engine.addGroupMember(group, member.id);
    final manual = h.engine.rollDice(group, actionId: 'queued-policy', dice: 'd6');
    final cancelled = expectLater(
      manual,
      throwsA(
        isA<TavernToolException>()
            .having((error) => error.code, 'code', TavernToolErrorCode.cancelled)
            .having((error) => error.committed, 'committed', false)
            .having((error) => error.executionId, 'executionId', isNull),
      ),
    );
    expect((await adding).members.map((value) => value.characterId), [h.characterId, member.id]);
    await cancelled;
    expect(h.dice.calls, 0);
    expect(h.database((db) => db.select('SELECT id FROM tool_receipts WHERE chat_id = ?', [group])), isEmpty);
    await h.reopen();
    final fresh = await h.engine.rollDice(group, actionId: 'queued-policy', dice: 'd6');
    expect(fresh.committed, isTrue);
    expect(h.dice.calls, 1);
    expect(h.model.generated, 0);
  }, timeout: const Timeout(Duration(seconds: 15)));
}

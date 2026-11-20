import 'dart:convert';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:test/test.dart';

import 'support/stage1_engine_harness.dart';

void main() {
  test('staged decisions stay not_applied on replay after normal activation and another acceptance', () async {
    final h = await Stage1Harness.open();
    await h.enableMemory();
    final active = await h.start();
    final next = h.model.prepare();
    await stage1Finish(
      active.call,
      tools: [
        Stage1Call(0, 'r', 'roll', {'dice': 'd6'}),
        Stage1Call(1, 'm', 'remember', {
          'text': 'A stable fact.',
          'keywords': ['signal'],
        }),
      ],
    );
    await Stage1Harness.listening(next, active.events);
    final staged = (await h.turn(active.events)).proposals.single;
    expect(staged.version, 1);
    expect(staged.workflow, 'staged');
    expect(staged.source, isNull);
    expect(staged.eligible, isFalse);
    final early = await _resolve(h, staged, 'early');
    expect(early.record.outcome, 'not_applied');
    expect(early.record.reason, 'inactive');
    expect(early.record.memoryId, isNull);
    expect(early.current.targetMissing, isNull);
    expect(h.database((db) => db.select('SELECT id FROM memories WHERE chat_id = ?', [h.chatId])), isEmpty);
    await stage1Finish(next, content: 'final source');
    await active.events.done.future;
    final ready = (await h.turn(active.events)).proposals.single;
    expect(ready.version, 2);
    expect(ready.source!.nodeId, ready.candidateNodeId);
    expect(ready.workflow, 'pending_confirmation');
    final accepted = await _resolve(h, ready, 'accept');
    expect(accepted.record.outcome, 'accepted');
    expect(accepted.replayed, isFalse);
    expect(accepted.record.memoryId, isNotNull);
    expect(accepted.current.targetMissing, isFalse);
    expect(accepted.current.proposal.workflow, 'accepted');
    expect(accepted.current.proposal.version, 3);
    final replayedEarly = await _resolve(h, staged, 'early');
    expect(replayedEarly.replayed, isTrue);
    expect(replayedEarly.record.toJson(), early.record.toJson());
    expect(replayedEarly.current.proposal.memoryId, accepted.record.memoryId);
    expect(replayedEarly.current.targetMissing, isNull);
    final receipt = (await h.engine.readToolReceipt(ready.executionId))!;
    expect(receipt.committed, isTrue);
    expect(receipt.decisionRef!.decisionId, 'accept');
    await expectLater(
      _resolve(h, ready, 'early'),
      throwsA(
        isA<TavernToolException>()
            .having((error) => error.code, 'code', TavernToolErrorCode.decisionConflict)
            .having((error) => error.committed, 'adopted', false),
      ),
    );
    await h.reopen();
    expect((await _resolve(h, staged, 'early')).record.toJson(), early.record.toJson());
    expect((await _resolve(h, ready, 'accept')).record.toJson(), accepted.record.toJson());
  });

  test('a deleted accepted target stays missing and an old accepted identity never inserts again', () async {
    final h = await Stage1Harness.open();
    final ready = await _proposal(h);
    final accepted = await _resolve(h, ready, 'accept');
    h.database((db) => db.execute('DELETE FROM memories WHERE id = ?', [accepted.record.memoryId]));
    final replay = await _resolve(h, ready, 'accept');
    expect(replay.replayed, isTrue);
    expect(replay.record.toJson(), accepted.record.toJson());
    expect(replay.current.targetMissing, isTrue);
    expect(replay.current.proposal.memoryId, accepted.record.memoryId);
    final receipt = (await h.engine.readToolReceipt(ready.executionId))!;
    expect(receipt.committed, isTrue);
    expect(receipt.status, 'committed');
    expect(receipt.targetMissing, isTrue);
    expect(h.database((db) => db.select('SELECT id FROM memories WHERE chat_id = ?', [h.chatId])), isEmpty);
    expect(h.database((db) => db.select('PRAGMA foreign_key_check')), isEmpty);
  });

  test('auto activation is a real memory and user decision identity has a separate namespace', () async {
    final h = await Stage1Harness.open();
    final proposal = await _proposal(h, mode: 'auto');
    expect(proposal.workflow, 'accepted');
    expect(proposal.version, 2);
    expect(proposal.memoryId, isNotNull);
    final receipt = (await h.engine.readToolReceipt(proposal.executionId))!;
    expect(receipt.committed, isTrue);
    final record = receipt.decisionRecord!;
    expect(record.decisionRef.origin, 'policy_auto');
    expect(record.expectedVersion, isNull);
    expect(record.expectedContextAnchor, isNull);
    expect(record.parameters['internalActivation'], isNotNull);
    final user = await _resolve(h, proposal, record.decisionRef.decisionId);
    expect(user.record.decisionRef.origin, 'user');
    expect(user.record.outcome, 'not_applied');
    expect(user.record.reason, 'already_resolved');
    expect(user.record.memoryId, isNull);
    expect(user.current.targetMissing, isNull);
    expect((await h.engine.readToolReceipt(proposal.executionId))!.decisionRef!.origin, 'policy_auto');
    expect(h.database((db) => db.select('SELECT id FROM memories WHERE chat_id = ?', [h.chatId])), hasLength(1));
  });

  test('reject is durable and revision failure cannot overwrite the real deciding receipt', () async {
    final h = await Stage1Harness.open();
    final proposal = await _proposal(h);
    final rejected = await _resolve(h, proposal, 'reject', decision: TavernMemoryDecision.reject);
    expect(rejected.record.outcome, 'rejected');
    expect(rejected.record.memoryId, isNull);
    expect(rejected.current.proposal.workflow, 'rejected');
    final later = await _resolve(h, proposal, 'late');
    expect(later.record.outcome, 'not_applied');
    expect(later.record.reason, 'revision_conflict');
    final receipt = (await h.engine.readToolReceipt(proposal.executionId))!;
    expect(receipt.status, 'rejected');
    expect(receipt.committed, isFalse);
    expect(receipt.decisionRef!.decisionId, 'reject');
    expect(
      (await _resolve(h, proposal, 'reject', decision: TavernMemoryDecision.reject)).record.toJson(),
      rejected.record.toJson(),
    );
  });

  test('equal body UPDATE and textual ABA permanently invalidate a bound source', () async {
    final h = await Stage1Harness.open();
    final proposal = await _proposal(h);
    final before = proposal.source!;
    h.database((db) => db.execute('UPDATE nodes SET text = text WHERE id = ?', [before.nodeId]));
    var current = (await h.engine.readToolTurn(proposal.logicalTurnId))!.proposals.single;
    expect(current.sourceValidity, 'invalidated');
    expect(current.workflow, 'pending_confirmation');
    expect(current.version, proposal.version + 1);
    expect(current.eligible, isFalse);
    h.database((db) {
      db.execute('UPDATE nodes SET text = ? WHERE id = ?', ['changed', before.nodeId]);
      db.execute('UPDATE nodes SET text = ? WHERE id = ?', ['', before.nodeId]);
    });
    current = (await h.engine.readToolTurn(proposal.logicalTurnId))!.proposals.single;
    expect(current.source!.toJson(), before.toJson());
    expect(current.version, proposal.version + 1);
    expect(current.sourceValidity, 'invalidated');
    final failed = await _resolve(h, current, 'after-aba');
    expect(failed.record.outcome, 'not_applied');
    expect(failed.record.reason, 'source_changed');
    expect(
      h
          .database((db) => db.select('SELECT content_version FROM nodes WHERE id = ?', [before.nodeId]))
          .single['content_version'],
      before.contentVersion + 3,
    );
  });

  test('source delete and undo keep the old epoch orphaned and never reactivate a memory', () async {
    final h = await Stage1Harness.open();
    final proposal = await _proposal(h, mode: 'auto');
    final before = proposal.source!;
    final token = await h.engine.deleteFrom(h.chatId, before.nodeId);
    expect(await h.engine.undoDeleteFrom(h.chatId, token), isTrue);
    final current = (await h.engine.readToolTurn(proposal.logicalTurnId))!.proposals.single;
    expect(current.workflow, 'accepted');
    expect(current.sourceValidity, 'orphaned');
    expect(current.source!.toJson(), before.toJson());
    expect(
      h
          .database((db) => db.select('SELECT source_epoch FROM nodes WHERE id = ?', [before.nodeId]))
          .single['source_epoch'],
      before.sourceEpoch + 1,
    );
    expect(
      h
          .database((db) => db.select('SELECT source_validity FROM memories WHERE id = ?', [proposal.memoryId]))
          .single['source_validity'],
      'orphaned',
    );
    final active = await h.start(input: 'signal');
    expect(jsonEncode(active.call.body), isNot(contains('SOURCE_BEYOND_60')));
    await stage1Finish(active.call, content: 'done');
    await active.events.done.future;
  });

  test('ordinary memory selection uses the complete requested branch beyond the 60-node UI page', () async {
    final h = await Stage1Harness.open();
    final proposal = await _proposal(h, mode: 'auto');
    for (var i = 0; i < 61; i++) {
      await h.engine.sendOnly(h.chatId, 'filler $i');
    }
    expect((await h.engine.path(h.chatId)).any((message) => message.nodeId == proposal.source!.nodeId), isFalse);
    final active = await h.start(input: 'signal');
    expect(jsonEncode(active.call.body), contains('SOURCE_BEYOND_60'));
    await stage1Finish(active.call, content: 'read old source');
    await active.events.done.future;
    final parent =
        h
                .database((db) => db.select('SELECT parent_id FROM nodes WHERE id = ?', [proposal.source!.nodeId]))
                .single['parent_id']!
            as String;
    await h.engine.selectNode(h.chatId, parent);
    final branch = await h.start(input: 'signal');
    expect(jsonEncode(branch.call.body), isNot(contains('SOURCE_BEYOND_60')));
    await stage1Finish(branch.call, content: 'other branch');
    await branch.events.done.future;
  });

  test('foreign proposal and mismatched decision columns fail without consuming a new decision', () async {
    final h = await Stage1Harness.open();
    final proposal = await _proposal(h);
    final otherChat = await h.engine.createChat(h.characterId);
    final foreign = TavernToolContextAnchor(chatId: otherChat, selectedLeaf: null, treeRevision: 0);
    await expectLater(
      h.engine.resolveMemoryProposal(
        proposal.proposalId,
        decisionId: 'foreign',
        expectedVersion: proposal.version,
        decision: TavernMemoryDecision.accept,
        expectedContextAnchor: foreign,
      ),
      throwsA(isA<TavernToolException>().having((error) => error.code, 'code', TavernToolErrorCode.notFound)),
    );
    final rejected = await _resolve(h, proposal, 'saved', decision: TavernMemoryDecision.reject);
    h.database(
      (db) => db.execute('UPDATE memory_decisions SET decision = ? WHERE decision_origin = ? AND decision_id = ?', [
        'accept',
        'user',
        'saved',
      ]),
    );
    await expectLater(
      _resolve(h, proposal, 'saved', decision: TavernMemoryDecision.reject),
      throwsA(isA<TavernToolException>().having((error) => error.code, 'code', TavernToolErrorCode.storageFailure)),
    );
    expect(rejected.record.decision, TavernMemoryDecision.reject);
    expect(
      h.database((db) => db.select('SELECT decision_id FROM memory_decisions WHERE decision_id = ?', ['foreign'])),
      isEmpty,
    );
  });

  for (final corruption in ['foreign_parent', 'cycle']) {
    test('readToolTurn maps a $corruption in a bound source path to storageFailure without writes', () async {
      final h = await Stage1Harness.open();
      final proposal = await _proposal(h);
      final sourceId = proposal.source!.nodeId;
      final originalParent = h
          .database((db) => db.select('SELECT parent_id FROM nodes WHERE id = ?', [sourceId]))
          .single['parent_id'];
      final receiptBefore = (await h.engine.readToolReceipt(proposal.executionId))!.toJson();
      final otherChat = await h.engine.createChat(h.characterId);
      final replacement = corruption == 'cycle' ? sourceId : (await h.engine.path(otherChat)).last.nodeId;
      h.database((db) => db.execute('UPDATE nodes SET parent_id = ? WHERE id = ?', [replacement, sourceId]));
      try {
        // Both pointers satisfy the physical FK; the corruption is in the
        // same-chat, acyclic path contract, not in a tool identity or body.
        expect(h.database((db) => db.select('PRAGMA foreign_key_check')), isEmpty);
        await expectLater(
          h.engine.readToolTurn(proposal.logicalTurnId),
          throwsA(
            isA<TavernToolException>()
                .having((error) => error.operation, 'operation', 'readToolTurn')
                .having((error) => error.code, 'code', TavernToolErrorCode.storageFailure)
                .having((error) => error.committed, 'adopted', false),
          ),
        );
        expect((await h.engine.readToolReceipt(proposal.executionId))!.toJson(), receiptBefore);
        expect(h.database((db) => db.select('SELECT decision_id FROM memory_decisions')), isEmpty);
        expect(h.model.generated, 1);
        expect(h.dice.calls, 0);
      } finally {
        h.database((db) => db.execute('UPDATE nodes SET parent_id = ? WHERE id = ?', [originalParent, sourceId]));
      }
      expect((await h.engine.readToolTurn(proposal.logicalTurnId))!.proposals.single.toJson(), proposal.toJson());
      await h.engine.close();
      // The repair does not classify the engine lifecycle's programming error
      // as a bad persisted tree merely because it too is a StateError.
      await expectLater(h.engine.readToolTurn(proposal.logicalTurnId), throwsStateError);
    });
  }
}

Future<TavernMemoryProposalSnapshot> _proposal(Stage1Harness h, {String mode = 'ask'}) async {
  await h.enableMemory(mode: mode);
  final active = await h.start();
  await stage1Finish(
    active.call,
    tools: [
      Stage1Call(0, 'remember', 'remember', {
        'text': 'SOURCE_BEYOND_60',
        'keywords': ['signal'],
      }),
    ],
  );
  await active.events.done.future;
  expect(active.events.values.whereType<TavernTurnDone>().single.message.text, isEmpty);
  return (await h.turn(active.events)).proposals.single;
}

Future<TavernMemoryDecisionReceipt> _resolve(
  Stage1Harness h,
  TavernMemoryProposalSnapshot proposal,
  String id, {
  TavernMemoryDecision decision = TavernMemoryDecision.accept,
}) => h.engine.resolveMemoryProposal(
  proposal.proposalId,
  decisionId: id,
  expectedVersion: proposal.version,
  decision: decision,
  expectedContextAnchor: proposal.contextAnchor,
);

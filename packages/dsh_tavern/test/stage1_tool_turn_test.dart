import 'dart:convert';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:test/test.dart';

import 'support/stage1_engine_harness.dart';

void main() {
  test('four real requests share one reply, state baseline, final rules and exact wire exchange', () async {
    final h = await Stage1Harness.open(step: 5, rules: true);
    await h.enableMemory();
    final before = await h.engine.path(h.chatId);
    final active = await h.start();
    final calls = [active.call, h.model.prepare(), h.model.prepare(), h.model.prepare()];
    final first = [
      Stage1Call.raw(4, 'state-a', 'update_state', ' {"ops":[{"op":"add","path":"/n","value":4,"why":"a"}]} '),
      Stage1Call.raw(1, 'roll-a', 'roll', ' { "dice" : "2d6+1", "target" : 3 } '),
      Stage1Call(7, 'memory-a', 'remember', {
        'text': 'A remembered fact.',
        'keywords': ['fact', 'fact'],
      }),
    ];
    for (var i = 0; i < calls.length; i++) {
      await stage1Finish(
        calls[i],
        content: 'part-$i',
        reason: i == 3 ? 'stop' : 'tool_calls',
        tools: i == 0
            ? first
            : i == 3
            ? [
                Stage1Call(0, 'state-last', 'update_state', {
                  'ops': [stage1Add(4)],
                }),
              ]
            : [
                Stage1Call(0, 'state-$i', 'update_state', {
                  'ops': [stage1Add(4)],
                }),
                Stage1Call(1, 'roll-$i', 'roll', {'dice': 'd6'}),
              ],
        usageReport: stage1Usage(index: 0, prompt: 10 + i, completion: 2, cache: 1),
        usage: TavernUsage(promptTokens: 10 + i, completionTokens: 2, cacheHitTokens: 1),
      );
      if (i < calls.length - 1) await Stage1Harness.listening(calls[i + 1], active.events);
    }
    await active.events.done.future;
    expect(active.events.values.whereType<TavernTurnFailed>(), isEmpty);
    final done = active.events.values.whereType<TavernTurnDone>().single;
    expect(active.events.values.whereType<TavernTurnStarted>(), hasLength(1));
    expect(done.message.text, 'part-0part-1part-2part-3');
    expect(h.model.generated, 4);
    expect(h.dice.calls, 4);
    expect((await h.engine.path(h.chatId)).length, before.length + 2);
    expect((await h.engine.readState(h.chatId)).values, {'n': 5, 'ticks': 1});
    final turn = await h.turn(active.events);
    expect(turn.logicalTurnId, done.logicalTurnId);
    expect(turn.outcome, 'normal');
    expect(turn.budgetUsed, 4);
    expect(turn.requests.map((request) => request.requestIndex), [1, 2, 3, 4]);
    expect(turn.replyCommitAdopted, isTrue);
    expect(turn.normalFinalAdopted, isTrue);
    expect(turn.proposals.single.workflow, 'pending_confirmation');
    expect(turn.proposals.single.source!.nodeId, done.message.nodeId);
    expect(turn.proposals.single.sourceValidity, 'bound');
    expect(turn.proposals.single.keywords, ['fact', 'fact']);
    expect(turn.proposals.single.version, 2);
    expect(turn.proposals.single.eligible, isTrue);
    expect(done.message.usage!.promptTokens, 46);
    expect(done.message.usage!.completionTokens, 8);
    expect(done.message.usage!.cacheHitTokens, 4);

    final firstBody = calls.first.body!;
    final secondBody = calls[1].body!;
    expect({...secondBody}..remove('messages'), {...firstBody}..remove('messages'));
    final messages = stage1Rows(secondBody['messages']);
    final initialCount = stage1Rows(firstBody['messages']).length;
    expect(messages.take(initialCount), stage1Rows(firstBody['messages']));
    expect(messages[initialCount], {
      'role': 'assistant',
      'content': 'part-0',
      'tool_calls': [for (final call in first) call.wire],
    });
    final exchange = messages.skip(initialCount + 1).toList();
    expect(exchange.map((message) => message['tool_call_id']), ['roll-a', 'state-a', 'memory-a']);
    for (final message in exchange) {
      expect(message['role'], 'tool');
      final wire = stage1Map(jsonDecode(message['content']! as String));
      final receipt = await h.engine.readToolReceipt(wire['executionId']! as String);
      expect(receipt, isNotNull);
      expect(receipt!.callId, message['tool_call_id']);
      expect(receipt.wireResult, wire);
      expect(receipt.rawArguments, first.singleWhere((call) => call.id == receipt.callId).arguments);
    }
    final rules = (await h.engine.readAgentRuns(h.chatId)).where((run) => run.kind == 'state.rules');
    expect(rules, hasLength(1));
    expect(h.database((db) => db.select('PRAGMA foreign_key_check')), isEmpty);
    await h.reopen();
    expect((await h.engine.readToolTurn(turn.logicalTurnId))!.toJson(), turn.toJson());
  });

  test('fourth needsRoll wins over overflow and discards this whole batch before any intent', () async {
    final h = await Stage1Harness.open(rules: true);
    await h.enableMemory();
    final active = await h.start();
    var current = active.call;
    for (var i = 1; i <= 3; i++) {
      final next = h.model.prepare();
      await stage1Finish(
        current,
        content: 'visible-$i',
        reason: 'tool_calls',
        tools: [
          Stage1Call(0, 'roll-$i', 'roll', {'dice': 'd6'}),
          if (i == 1)
            Stage1Call(1, 'old-state', 'update_state', {
              'ops': [stage1Set(9)],
            }),
          if (i == 1)
            Stage1Call(2, 'old-memory', 'remember', {
              'text': 'Before budget.',
              'keywords': ['before'],
            }),
        ],
      );
      await Stage1Harness.listening(next, active.events);
      current = next;
    }
    await stage1Finish(
      current,
      content: 'visible-4',
      snapshot: false,
      tools: [
        for (var i = 0; i < 64; i++)
          Stage1Call(
            i,
            'fourth-$i',
            i.isEven ? 'update_state' : 'remember',
            i.isEven
                ? {
                    'ops': [stage1Set(99)],
                  }
                : {
                    'text': 'Never activate.',
                    'keywords': ['never'],
                  },
          ),
        Stage1Call(64, 'overflow-roll', 'roll', {'dice': 'd6'}),
      ],
    );
    await active.events.done.future;
    final failed = active.events.values.whereType<TavernTurnFailed>().single;
    expect(failed.kind, TavernFailure.toolFailure);
    expect(failed.toolFailureCode, 'budget_exhausted');
    expect(failed.partial!.text, 'visible-1visible-2visible-3visible-4');
    expect(active.events.values.whereType<TavernTurnDone>(), isEmpty);
    expect(h.model.generated, 4);
    expect(h.dice.calls, 3);
    final turn = await h.turn(active.events);
    expect(turn.outcome, 'budget_exhausted');
    expect(turn.requests.last.receiptIds, isEmpty);
    expect(turn.requests.last.batchDiagnostics['outcome'], 'not_executed_budget');
    expect(turn.proposals, hasLength(1));
    expect(turn.proposals.single.workflow, 'inactive_terminal');
    expect(turn.normalFinalAdopted, isFalse);
    expect(turn.replyCommitAdopted, isTrue);
    expect((await h.engine.readState(h.chatId)).values, {'n': 0, 'ticks': 0});
    final receipts = [for (final id in turn.receiptIds) (await h.engine.readToolReceipt(id))!];
    expect(receipts.where((receipt) => receipt.kind == 'roll').every((receipt) => receipt.committed == true), isTrue);
    expect(receipts.singleWhere((receipt) => receipt.kind == 'update_state').status, 'discarded');
    expect(h.database((db) => db.select('SELECT id FROM memories WHERE chat_id = ?', [h.chatId])), isEmpty);
  });

  for (final broken in ['missing_snapshot', 'identity', 'batch_limit']) {
    test('needsRoll $broken refuses the entire first batch without RNG or executions', () async {
      final h = await Stage1Harness.open(rules: true);
      await h.enableMemory();
      final active = await h.start();
      await stage1Finish(
        active.call,
        content: 'retained',
        snapshot: broken == 'identity',
        tools: [
          Stage1Call(0, broken == 'identity' ? 'duplicate' : 'state', 'update_state', {
            'ops': [stage1Set(7)],
          }),
          Stage1Call(1, broken == 'identity' ? 'duplicate' : 'roll', 'roll', {'dice': 'd6'}),
          Stage1Call(2, 'memory', 'remember', {
            'text': 'Not staged.',
            'keywords': ['never'],
          }),
          if (broken == 'batch_limit')
            for (var i = 3; i < 65; i++)
              Stage1Call(i, 'extra-$i', 'update_state', {
                'ops': [stage1Set(8)],
              }),
        ],
      );
      await active.events.done.future;
      final failed = active.events.values.whereType<TavernTurnFailed>().single;
      expect(failed.toolFailureCode, switch (broken) {
        'missing_snapshot' => 'unsupported_response_snapshot',
        'identity' => 'protocol_invalid',
        _ => 'batch_limit',
      });
      final turn = await h.turn(active.events);
      expect(turn.receiptIds, isEmpty);
      expect(turn.proposals, isEmpty);
      expect(h.dice.calls, 0);
      expect(h.model.generated, 1);
      expect((await h.engine.readState(h.chatId)).values, {'n': 0, 'ticks': 0});
    });
  }

  test('no-roll bad identities remain diagnostics while independent state and memory finish', () async {
    final h = await Stage1Harness.open();
    await h.enableMemory();
    final active = await h.start();
    await stage1Finish(
      active.call,
      snapshot: false,
      tools: [
        Stage1Call(0, 'duplicate', 'update_state', {
          'ops': [stage1Set(1)],
        }),
        Stage1Call(1, 'duplicate', 'update_state', {
          'ops': [stage1Set(2)],
        }),
        Stage1Call.raw(2, 'invalid-json', 'remember', '{"text":'),
        Stage1Call(4, 'good-state', 'update_state', {
          'ops': [stage1Set(7)],
        }),
        Stage1Call(6, 'good-memory', 'remember', {
          'text': 'Independent.',
          'keywords': ['independent'],
        }),
      ],
    );
    await active.events.done.future;
    expect(active.events.values.whereType<TavernTurnDone>(), hasLength(1));
    final turn = await h.turn(active.events);
    final receipts = [for (final id in turn.receiptIds) (await h.engine.readToolReceipt(id))!];
    expect(receipts.map((receipt) => receipt.callId), ['invalid-json', 'good-state', 'good-memory']);
    expect(receipts.first.status, 'rejected');
    expect(turn.proposals.single.workflow, 'pending_confirmation');
    expect(stage1Map((await h.engine.readState(h.chatId)).values)['n'], 7);
    expect(h.model.generated, 1);
    expect(h.dice.calls, 0);
  });

  test('typed invalid custom calls with empty legacy issues cannot apply state or acquire receipts', () async {
    final h = await Stage1Harness.open(rules: true);
    final active = await h.start();
    active.call.add(ModelText('retained'));
    // This valid legacy fragment has unknown provenance, which alone must not
    // acquire a new confirmed-envelope requirement on the no-roll path.
    active.call.add(
      Stage1Call(0, 'legacy-good', 'update_state', {
        'ops': [stage1Add(7)],
      }).fragment,
    );
    active.call.add(
      ModelToolFragment(
        index: 1,
        id: 'bad-identity',
        type: 'function',
        name: 'update_state',
        arguments: jsonEncode({
          'ops': [stage1Add(100)],
        }),
        structure: const ModelToolFragmentStructure(invalidMetadataType: true),
      ),
    );
    active.call.add(
      ModelToolFragment(
        index: 2,
        id: 'bad-arguments',
        type: 'function',
        name: 'update_state',
        arguments: jsonEncode({
          'ops': [stage1Add(200)],
        }),
        structure: const ModelToolFragmentStructure(invalidArgumentsType: true),
      ),
    );
    await active.call.finish();
    await active.events.done.future;
    expect(active.events.values.whereType<TavernTurnFailed>(), isEmpty);
    expect(active.events.values.whereType<TavernTurnDone>(), hasLength(1));
    expect((await h.engine.readState(h.chatId)).values, {'n': 7, 'ticks': 1});
    final turn = await h.turn(active.events);
    expect(turn.outcome, 'normal');
    final calls = stage1Rows(stage1Map(turn.requests.single.batchDiagnostics['batch'])['calls']);
    expect(calls.every((call) => call['valid'] == true), isTrue);
    expect(calls.first['structuralKnowledge'], 'unknown');
    expect(calls[1]['identityComplete'], isFalse);
    expect(calls[2]['originalArgumentsStringComplete'], isFalse);
    expect(turn.receiptIds, hasLength(1));
    final receipt = (await h.engine.readToolReceipt(turn.receiptIds.single))!;
    expect(receipt.callId, 'legacy-good');
    expect(receipt.committed, isTrue);
    final stateRuns = (await h.engine.readAgentRuns(h.chatId)).where((run) => run.kind == 'state.tool').toList();
    expect(stateRuns, hasLength(3));
    for (final entry in {1: 'invalid-tool-identity', 2: 'incomplete-tool-arguments'}.entries) {
      final run = stateRuns.singleWhere((run) => stage1Map(run.result['tool'])['index'] == entry.key);
      expect(run.id, '${turn.requests.single.requestId}:state-diagnostic:${entry.key}');
      expect(run.result['committed'], isFalse);
      expect(run.result['execution'], isNull);
      expect(stage1Rows(run.result['issues']).map((issue) => issue['code']), contains(entry.value));
    }
    expect(h.model.generated, 1);
    expect(h.dice.calls, 0);
    await h.reopen();
    expect((await h.engine.readState(h.chatId)).values, {'n': 7, 'ticks': 1});
  });

  test('state-only unsupported envelope is rejected despite valid identity and arguments', () async {
    final h = await Stage1Harness.open();
    final active = await h.start();
    active.call.add(ModelText('retained'));
    active.call.add(
      ModelToolFragment(
        index: 0,
        id: 'unsupported-state',
        type: 'function',
        name: 'update_state',
        arguments: jsonEncode({
          'ops': [stage1Set(7)],
        }),
        structure: const ModelToolFragmentStructure(unsupportedEnvelope: true),
      ),
    );
    await active.call.finish();
    await active.events.done.future;
    expect(active.events.values.whereType<TavernTurnFailed>(), isEmpty);
    expect(active.events.values.whereType<TavernTurnDone>(), hasLength(1));
    expect((await h.engine.readState(h.chatId)).values, {'n': 0, 'ticks': 0});
    final turn = await h.turn(active.events);
    final call = stage1Rows(stage1Map(turn.requests.single.batchDiagnostics['batch'])['calls']).single;
    expect(call['valid'], isTrue);
    expect(call['identityComplete'], isTrue);
    expect(call['originalArgumentsStringComplete'], isTrue);
    expect(call['unsupportedEnvelope'], isTrue);
    expect(call['issues'], isEmpty);
    final receipt = (await h.engine.readToolReceipt(turn.receiptIds.single))!;
    expect(receipt.status, 'rejected');
    expect(receipt.committed, isFalse);
    expect(receipt.result!['acceptedCount'], 0);
    expect(stage1Rows(receipt.result!['issues']).map((issue) => issue['code']), contains('unsupported-tool-envelope'));
    expect(h.model.generated, 1);
    expect(h.dice.calls, 0);
  });

  for (final reason in <String?>[null, 'length', 'unknown-provider-reason']) {
    test('provider terminal $reason adopts body and retains roll but discards staged effects', () async {
      final h = await Stage1Harness.open(rules: true);
      await h.enableMemory();
      final active = await h.start();
      final next = h.model.prepare();
      await stage1Finish(
        active.call,
        tools: [
          Stage1Call(0, 'r', 'roll', {'dice': 'd6'}),
          Stage1Call(1, 's', 'update_state', {
            'ops': [stage1Set(7)],
          }),
          Stage1Call(2, 'm', 'remember', {
            'text': 'Inactive.',
            'keywords': ['inactive'],
          }),
        ],
      );
      await Stage1Harness.listening(next, active.events);
      await stage1Finish(next, content: 'provider body', reason: reason);
      await active.events.done.future;
      final done = active.events.values.whereType<TavernTurnDone>().single;
      expect(done.finishReason, reason);
      expect(done.message.text, 'provider body');
      final turn = await h.turn(active.events);
      expect(turn.outcome, 'model_terminal');
      expect(turn.replyCommitAdopted, isTrue);
      expect(turn.normalFinalAdopted, isFalse);
      expect(turn.proposals.single.workflow, 'inactive_terminal');
      expect((await h.engine.readState(h.chatId)).values, {'n': 0, 'ticks': 0});
      expect(h.dice.calls, 1);
      final roll = (await h.engine.readToolReceipt(turn.requests.first.receiptIds.first))!;
      expect(roll.committed, isTrue);
    });
  }

  test('second-request admission clears a continued node old usage until every report is complete', () async {
    final h = await Stage1Harness.open();
    final first = await h.start();
    await stage1Finish(
      first.call,
      content: 'old',
      usage: const TavernUsage(promptTokens: 90, completionTokens: 40, cacheHitTokens: 20),
    );
    await first.events.done.future;
    final old = first.events.values.whereType<TavernTurnDone>().single.message;
    final active = await h.start(continueNode: old.nodeId);
    final next = h.model.prepare();
    await stage1Finish(
      active.call,
      tools: [
        Stage1Call(0, 'r', 'roll', {'dice': 'd6'}),
      ],
      usageReport: stage1Usage(index: 0, prompt: 10, completion: 2, cache: 1),
      usage: const TavernUsage(promptTokens: 10, completionTokens: 2, cacheHitTokens: 1),
    );
    await Stage1Harness.listening(next, active.events);
    final visible = (await h.engine.path(h.chatId)).singleWhere((message) => message.nodeId == old.nodeId);
    expect(visible.usage, isNull);
    expect(visible.reportedUsage, isNull);
    expect((await h.turn(active.events)).budgetUsed, 2);
    final files = await h.engine.exportChat(h.chatId);
    final exported = [
      for (final file in files)
        for (final line in utf8.decode(file.bytes).split('\n'))
          if (line.isNotEmpty) stage1Map(jsonDecode(line)),
    ];
    final own = exported
        .where((line) => line['extra'] is Map<String, Object?>)
        .map((line) => stage1Map(stage1Map(stage1Map(line['extra'])['dshgo'])['chatJsonl']))
        .singleWhere((value) => value['nodeId'] == old.nodeId);
    expect(own['usage'], isNull);
    await stage1Finish(next, content: 'new');
    await active.events.done.future;
    final done = active.events.values.whereType<TavernTurnDone>().single;
    expect(done.message.usage, isNull);
    expect(
      stage1Map(
        stage1Map((await h.turn(active.events)).usageSummary['fields'])['prompt_tokens'],
      )['unknownRequestIndexes'],
      [2],
    );
  });
}

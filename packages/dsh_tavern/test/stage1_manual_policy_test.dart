import 'dart:convert';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:test/test.dart';

import 'support/stage1_engine_harness.dart';

void main() {
  test('manual same-intent coalesces and durable replay precedes busy, policy and branch checks', () async {
    final h = await Stage1Harness.open(thinking: true, deepseek: false);
    final leaf = (await h.engine.path(h.chatId)).last.nodeId;
    final one = h.engine.rollDice(
      h.chatId,
      actionId: ' stable ',
      dice: '3d6-1',
      label: '',
      target: 2,
      expectedNodeId: leaf,
    );
    final two = h.engine.rollDice(
      h.chatId,
      actionId: ' stable ',
      dice: '3d6-1',
      label: '',
      target: 2,
      expectedNodeId: leaf,
    );
    await expectLater(
      h.engine.rollDice(h.chatId, actionId: ' stable ', dice: '0d6'),
      throwsA(_toolError(TavernToolErrorCode.actionConflict)),
    );
    final results = await Future.wait([one, two]);
    final receipt = results.first;
    expect(results.last.toJson(), receipt.toJson());
    expect(receipt.status, 'committed');
    expect(receipt.committed, isTrue);
    expect(receipt.origin, 'manual');
    expect(receipt.actionId, ' stable ');
    expect(receipt.logicalTurnId, isNull);
    expect(receipt.requestId, isNull);
    expect(receipt.result, {
      'dice': '3d6-1',
      'count': 3,
      'sides': 6,
      'modifier': -1,
      'label': '',
      'target': 2,
      'values': [1, 1, 1],
      'total': 2,
      'pass': true,
    });
    expect(h.dice.calls, 3);
    expect(h.model.generated, 0);
    await h.engine.setToolPolicy({
      'roll': {'allow': false},
    });
    final active = await h.start();
    final replayed = await h.engine.rollDice(
      h.chatId,
      actionId: ' stable ',
      dice: '3d6-1',
      label: '',
      target: 2,
      expectedNodeId: leaf,
    );
    expect(replayed.toJson(), receipt.toJson());
    await expectLater(
      h.engine.rollDice(h.chatId, actionId: 'new', dice: 'd6'),
      throwsA(_toolError(TavernToolErrorCode.busy)),
    );
    await expectLater(
      h.engine.rollDice(h.chatId, actionId: ' stable ', dice: '3d8-1', label: '', target: 2, expectedNodeId: leaf),
      throwsA(_toolError(TavernToolErrorCode.actionConflict)),
    );
    await expectLater(
      h.engine.rollDice(h.chatId, actionId: ' stable ', dice: 'bad', expectedNodeId: ''),
      throwsA(_toolError(TavernToolErrorCode.actionConflict)),
    );
    await stage1Finish(active.call, content: 'ordinary reply');
    await active.events.done.future;
    final afterBranch = await h.engine.rollDice(
      h.chatId,
      actionId: ' stable ',
      dice: '3d6-1',
      label: '',
      target: 2,
      expectedNodeId: leaf,
    );
    expect(afterBranch.toJson(), receipt.toJson());
    expect(h.dice.calls, 3);
    await expectLater(
      h.engine.rollDice(h.chatId, actionId: 'disabled', dice: 'd6'),
      throwsA(_toolError(TavernToolErrorCode.policyDisabled)),
    );
    await h.reopen();
    expect((await h.engine.readToolReceipt(receipt.executionId))!.toJson(), receipt.toJson());
    expect(
      (await h.engine.rollDice(
        h.chatId,
        actionId: ' stable ',
        dice: '3d6-1',
        label: '',
        target: 2,
        expectedNodeId: leaf,
      )).executionId,
      receipt.executionId,
    );
    expect(h.dice.calls, 3);
  });

  test('pre-intent stop cancels coalesced callers without consuming identity or RNG', () async {
    final h = await Stage1Harness.open();
    final one = h.engine.rollDice(h.chatId, actionId: 'cancel', dice: 'd6');
    final two = h.engine.rollDice(h.chatId, actionId: 'cancel', dice: 'd6');
    final expected = isA<TavernToolException>()
        .having((error) => error.code, 'code', TavernToolErrorCode.cancelled)
        .having((error) => error.committed, 'adopted', false)
        .having((error) => error.chatId, 'chatId', h.chatId)
        .having((error) => error.executionId, 'executionId', isNull);
    final checked = Future.wait([expectLater(one, throwsA(expected)), expectLater(two, throwsA(expected))]);
    h.engine.stop(h.chatId);
    await checked;
    expect(h.dice.calls, 0);
    expect(h.database((db) => db.select('SELECT id FROM tool_receipts WHERE chat_id = ?', [h.chatId])), isEmpty);
    final retry = await h.engine.rollDice(h.chatId, actionId: 'cancel', dice: 'd6');
    expect(retry.committed, isTrue);
    expect(h.dice.calls, 1);
  });

  test('an interrupted dice source becomes durable unresolved and never draws again on replay', () async {
    final dice = Stage1Dice();
    dice.value = (_) {
      if (dice.calls == 2) throw StateError('fixture: second die unavailable');
      return 0;
    };
    final h = await Stage1Harness.open(dice: dice);
    final receipt = await h.engine.rollDice(h.chatId, actionId: 'unknown', dice: '4d6');
    expect(receipt.status, 'unresolved');
    expect(receipt.committed, isNull);
    expect(receipt.result, isNull);
    expect(dice.calls, 2);
    dice.value = (_) => 5;
    expect((await h.engine.rollDice(h.chatId, actionId: 'unknown', dice: '4d6')).toJson(), receipt.toJson());
    await h.reopen();
    expect((await h.engine.rollDice(h.chatId, actionId: 'unknown', dice: '4d6')).toJson(), receipt.toJson());
    expect(dice.calls, 2);
    final fresh = await h.engine.rollDice(h.chatId, actionId: 'new-intent', dice: 'd6');
    expect(fresh.result!['values'], [6]);
    expect(fresh.result!['target'], isNull);
    expect(fresh.result!['pass'], isNull);
    expect(dice.calls, 3);
  });

  test('invalid manual arguments create no receipt and valid boundary expressions are exact', () async {
    final h = await Stage1Harness.open();
    for (final dice in [
      'D6',
      '0d6',
      '01d6',
      'd01',
      'd1',
      '101d6',
      'd1001',
      'd6+01',
      'd6+1000001',
      ' d6',
      'd6 ',
      'd6\n',
      '2d6+1+1',
      '１d6',
    ]) {
      await expectLater(
        h.engine.rollDice(h.chatId, actionId: 'bad-$dice', dice: dice),
        throwsA(_toolError(TavernToolErrorCode.invalidArgument)),
      );
    }
    await expectLater(
      h.engine.rollDice(h.chatId, actionId: '', dice: 'd6'),
      throwsA(_toolError(TavernToolErrorCode.invalidArgument)),
    );
    await expectLater(
      h.engine.rollDice(h.chatId, actionId: 'label', dice: 'd6', label: 'x' * 257),
      throwsA(_toolError(TavernToolErrorCode.invalidArgument)),
    );
    await expectLater(
      h.engine.rollDice(h.chatId, actionId: 'target', dice: 'd6', target: 1000001),
      throwsA(_toolError(TavernToolErrorCode.invalidArgument)),
    );
    expect(h.dice.calls, 0);
    expect(h.database((db) => db.select('SELECT id FROM tool_receipts WHERE chat_id = ?', [h.chatId])), isEmpty);
    final maximum = await h.engine.rollDice(h.chatId, actionId: 'max', dice: '100d1000-1000000', target: -1000000);
    expect(maximum.result!['values'], List<int>.filled(100, 1));
    expect(maximum.result!['total'], -999900);
    expect(maximum.result!['pass'], isTrue);
    final zero = await h.engine.rollDice(h.chatId, actionId: 'zero-modifier', dice: 'd2-0');
    expect(zero.result!['modifier'], 0);
  });

  test('scope patch captures caller data, preserves unrelated fields, and bad containers are not replaced', () async {
    final h = await Stage1Harness.open();
    final initial = await h.engine.readToolPolicy(chatId: h.chatId);
    expect(initial.configuredGlobal, {'present': false, 'raw': null});
    expect(initial.configuredChat, {'present': false, 'raw': null});
    expect(initial.effectiveScope, {'rollAllow': true, 'rememberAllow': false, 'rememberMode': 'ask'});
    final remembered = <String, Object?>{'allow': true, 'mode': 'auto'};
    final patch = <String, Object?>{'remember': remembered};
    final write = h.engine.setToolPolicy(patch);
    remembered['allow'] = false;
    remembered['mode'] = 'ask';
    patch.clear();
    expect((await write).committed, isTrue);
    expect((await h.engine.readToolPolicy()).effectiveScope['rememberMode'], 'auto');
    expect((await h.engine.readToolPolicy()).effectiveScope['rememberAllow'], isTrue);
    await h.engine.setToolPolicy({
      'roll': {'enabled': false},
      'remember': {'mode': 'ask'},
    }, chatId: h.chatId);
    final local = await h.engine.readToolPolicy(chatId: h.chatId);
    expect(local.effectiveScope, {'rollAllow': false, 'rememberAllow': true, 'rememberMode': 'ask'});
    await h.engine.setToolPolicy({
      'roll': {'enabled': null},
    }, chatId: h.chatId);
    expect((await h.engine.readToolPolicy(chatId: h.chatId)).effectiveScope['rollAllow'], isTrue);
    for (final invalid in <Map<String, Object?>>[
      {'unknown': true},
      {
        'roll': {'allow': null},
      },
      {
        'remember': {'mode': 'other'},
      },
    ]) {
      await expectLater(h.engine.setToolPolicy(invalid), throwsA(_toolError(TavernToolErrorCode.invalidArgument)));
    }
    h.database(
      (db) => db.execute('UPDATE chats SET settings = ? WHERE id = ?', [
        jsonEncode({
          'unrelated': {'keep': 7},
          'toolPolicy': {
            'roll': {'enabled': true},
          },
        }),
        h.chatId,
      ]),
    );
    final preserved = await h.engine.setToolPolicy({
      'roll': {'enabled': false},
    }, chatId: h.chatId);
    expect(preserved.committed, isTrue);
    final savedSettings = h.database(
      (db) =>
          jsonDecode(db.select('SELECT settings FROM chats WHERE id = ?', [h.chatId]).single['settings']! as String),
    );
    expect(stage1Map(savedSettings)['unrelated'], {'keep': 7});
    h.database(
      (db) => db.execute('UPDATE chats SET settings = ? WHERE id = ?', [
        jsonEncode({'toolPolicy': 23}),
        h.chatId,
      ]),
    );
    final corrupt = await h.engine.readToolPolicy(chatId: h.chatId);
    expect(corrupt.configuredChat, {'present': true, 'raw': 23});
    expect(corrupt.effectiveScope['rollAllow'], isFalse);
    expect(corrupt.diagnostics, isNotEmpty);
    await expectLater(
      h.engine.setToolPolicy({
        'roll': {'enabled': true},
      }, chatId: h.chatId),
      throwsA(
        isA<TavernToolException>()
            .having((error) => error.code, 'code', TavernToolErrorCode.invalidArgument)
            .having((error) => error.operation, 'operation', 'setToolPolicy')
            .having((error) => error.message, 'message', 'invalid_stored_policy')
            .having((error) => error.committed, 'adopted', false),
      ),
    );
    expect((await h.engine.readToolPolicy(chatId: h.chatId)).configuredChat, corrupt.configuredChat);
  });

  test('card veto restricts scope but manual dice remain independent of model provider gates', () async {
    final h = await Stage1Harness.open(
      cardTools: {
        'roll': {'disabled': true},
      },
    );
    expect((await h.engine.readToolPolicy(chatId: h.chatId)).effectiveScope['rollAllow'], isTrue);
    await expectLater(
      h.engine.rollDice(h.chatId, actionId: 'veto', dice: 'd6'),
      throwsA(_toolError(TavernToolErrorCode.policyDisabled)),
    );
    final active = await h.start();
    final names = stage1Rows(active.call.body!['tools']).map((tool) => stage1Map(tool['function'])['name']);
    expect(names, isNot(contains('roll')));
    await stage1Finish(
      active.call,
      tools: [
        Stage1Call(0, 'unoffered', 'roll', {'dice': 'd6'}),
      ],
    );
    await active.events.done.future;
    final turn = await h.turn(active.events);
    expect((await h.engine.readToolReceipt(turn.receiptIds.single))!.status, 'rejected');
    expect(h.model.generated, 1);
    expect(h.dice.calls, 0);
  });

  test('read absence, invalid identities, missing chat and corrupt receipt are distinct', () async {
    final h = await Stage1Harness.open();
    expect(await h.engine.readToolTurn('missing'), isNull);
    expect(await h.engine.readToolReceipt('missing'), isNull);
    await expectLater(h.engine.readToolTurn(''), throwsA(_toolError(TavernToolErrorCode.invalidArgument)));
    await expectLater(h.engine.readToolReceipt(''), throwsA(_toolError(TavernToolErrorCode.invalidArgument)));
    await expectLater(h.engine.readToolPolicy(chatId: 'missing'), throwsA(_toolError(TavernToolErrorCode.notFound)));
    await expectLater(
      h.engine.rollDice('missing', actionId: 'a', dice: 'd6'),
      throwsA(_toolError(TavernToolErrorCode.notFound)),
    );
    final receipt = await h.engine.rollDice(h.chatId, actionId: 'stored', dice: 'd6');
    h.database(
      (db) => db.execute('UPDATE tool_receipts SET result_json = ? WHERE id = ?', ['[]', receipt.executionId]),
    );
    await expectLater(
      h.engine.readToolReceipt(receipt.executionId),
      throwsA(
        isA<TavernToolException>()
            .having((error) => error.code, 'code', TavernToolErrorCode.storageFailure)
            .having((error) => error.committed, 'read effect', false),
      ),
    );
    expect(h.dice.calls, 1);
  });
}

Matcher _toolError(TavernToolErrorCode code) => isA<TavernToolException>()
    .having((error) => error.code, 'code', code)
    .having((error) => error.committed, 'adopted', false);

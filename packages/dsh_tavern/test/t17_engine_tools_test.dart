import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import 'support/t24_engine_harness.dart';

// Real facade, files, prompt assembly, pure state rules and SQLite. The model
// only supplies controlled deltas; no production hook or API account is used.
void main() {
  for (final reason in ['stop', 'tool_calls']) {
    test('tool-only $reason saves an empty reply and state without another model request', () async {
      final h = await _open();
      final before = await h.engine.path(h.chatId);
      final active = await _reply(h, [
        _tool(0, [_set(7)]),
      ], reason: reason);
      final done = _done(active);
      expect(done.finishReason, reason);
      expect(done.message.text, isEmpty);
      expect(active.events.values.whereType<TavernTextDelta>(), isEmpty);
      expect(active.events.values.whereType<TavernReasoningDelta>(), isEmpty);
      expect((await h.engine.path(h.chatId)).length, before.length + 2);
      expect((await h.engine.path(h.chatId)).last.nodeId, done.message.nodeId);
      final snapshot = await h.engine.readState(h.chatId);
      expect(snapshot.values, {'n': 7, 'ticks': 0});
      final change = snapshot.changes.single;
      expect(change['path'], '/n');
      expect(change['oldExists'], isTrue);
      expect(change['old'], 0);
      expect(change['newExists'], isTrue);
      expect(change['new'], 7);
      expect(change['actor'], 'model');
      final runs = await _toolRuns(h);
      expect(runs, hasLength(1));
      expect(runs.single.nodeId, done.message.nodeId);
      expect(runs.single.result['committed'], isTrue);
      expect(_map(runs.single.result['tool'])['id'], 'provider-0');
      expect(runs.single.id, isNot('provider-0'));
      _expectOffered(active.call.body!);
      expect(h.model.generated, 1);

      // Only an explicit second user turn can cause a second model request.
      // It carries ordinary history plus current state, never tool messages.
      final next = await _reply(h, const [ModelText('next body')]);
      _done(next);
      final messages = _rows(next.call.body!['messages']);
      expect(messages.any((message) => message['role'] == 'tool'), isFalse);
      expect(
        messages.any((message) => message.containsKey('tool_calls') || message.containsKey('tool_call_id')),
        isFalse,
      );
      expect(h.model.generated, 2);
      expect((await h.engine.readState(h.chatId)).values, {'n': 7, 'ticks': 0});
      await h.reopen();
      expect((await h.engine.readState(h.chatId)).values, {'n': 7, 'ticks': 0});
      expect((await _toolRuns(h)).single.result['committed'], isTrue);
    });
  }

  for (final shape in ['partial', 'complete']) {
    test('$shape tool-only cancellation rolls back empty nodes and keeps an unanchored audit', () async {
      final h = await _open();
      final before = await h.engine.path(h.chatId);
      // A fresh greeting stores state in node_states and may have no dshgo
      // carrier. Cancellation must preserve its complete extra JSON verbatim.
      final beforeExtra = _extra(h, before.last.nodeId);
      final active = await _start(h);
      try {
        _expectOffered(active.call.body!);
        active.call.add(
          shape == 'complete'
              ? _tool(0, [_set(9)])
              : ModelToolFragment(
                  index: 0,
                  id: 'provider-0',
                  type: 'function',
                  name: 'update_state',
                  arguments: '{"ops":[',
                ),
        );
        h.engine.stop(h.chatId);
        await active.events.done.future;
      } finally {
        await active.call.close();
      }
      final failure = _failed(active);
      expect(failure.kind, TavernFailure.cancelled);
      expect(failure.partial, isNull);
      expect(active.events.values.whereType<TavernTextDelta>(), isEmpty);
      expect(active.events.values.whereType<TavernReasoningDelta>(), isEmpty);
      expect((await h.engine.path(h.chatId)).map((node) => node.nodeId), before.map((node) => node.nodeId));
      expect(_extra(h, before.last.nodeId), beforeExtra);
      expect((await h.engine.readState(h.chatId)).values, {'n': 0, 'ticks': 0});
      final runs = await _toolRuns(h);
      expect(runs, hasLength(1));
      expect(runs.single.nodeId, isNull);
      expect(runs.single.result['committed'], isFalse);
      expect(runs.single.result['outcome'], 'not-committed');
      expect(await h.engine.readAgentRuns(h.chatId, nodeId: before.last.nodeId), isEmpty);
      expect(_db(h, (db) => db.select('SELECT id FROM nodes WHERE chat_id = ?', [h.chatId]).length), before.length);
      _expectForeignKeys(h);
      expect(h.model.generated, 1);
      await h.reopen();
      expect((await _toolRuns(h)).single.nodeId, isNull);
      expect((await h.engine.path(h.chatId)).map((node) => node.nodeId), before.map((node) => node.nodeId));
      expect(_extra(h, before.last.nodeId), beforeExtra);
    });
  }

  test('bad argument JSON does not reject an independent complete tool call', () async {
    final h = await _open();
    final active = await _reply(h, [
      ModelToolFragment(index: 0, id: 'bad', type: 'function', name: 'update_state', arguments: '{"ops":[}'),
      _tool(4, [_set(7)]),
    ]);
    _done(active);
    expect((await h.engine.readState(h.chatId)).values, {'n': 7, 'ticks': 0});
    final runs = await _toolRuns(h);
    expect(runs, hasLength(2));
    expect(_runAt(runs, 0).result['committed'], isFalse);
    expect(_codes(_runAt(runs, 0).result['issues']), contains('invalid_arguments_json'));
    expect(_runAt(runs, 4).result['committed'], isTrue);
    expect(runs.map((run) => run.result['invocationId']).toSet(), hasLength(1));
    expect(h.model.generated, 1);
  });

  test('duplicate provider ids reject both calls while a third independent call commits', () async {
    final h = await _open();
    final active = await _reply(h, [
      _tool(2, [_set(2)], id: 'same'),
      _tool(0, [_set(1)], id: 'same'),
      _tool(5, [_set(9)]),
    ]);
    _done(active);
    expect((await h.engine.readState(h.chatId)).values, {'n': 9, 'ticks': 0});
    final runs = await _toolRuns(h);
    expect(runs, hasLength(3));
    for (final index in [0, 2]) {
      expect(_runAt(runs, index).result['committed'], isFalse);
      expect(_codes(_runAt(runs, index).result['issues']), contains('duplicate_id'));
    }
    expect(_runAt(runs, 5).result['committed'], isTrue);
    expect(runs.map((run) => run.id).toSet(), hasLength(3));
    expect(h.model.generated, 1);
  });

  test('step uses one baseline across calls and automatic rules run only once after them', () async {
    final h = await _open(step: 5, rules: [_tickRule(once: false)]);
    final active = await _reply(h, [
      _tool(0, [_add(4)]),
      _tool(1, [_add(4)]),
    ]);
    _done(active);
    final snapshot = await h.engine.readState(h.chatId);
    expect(snapshot.values, {'n': 5, 'ticks': 1});
    final n = snapshot.changes.singleWhere((change) => change['path'] == '/n');
    expect(n['old'], 0);
    expect(n['new'], 5);
    expect(n['actor'], 'model');
    expect(snapshot.changes.singleWhere((change) => change['path'] == '/ticks')['actor'], 'rules');
    final runs = await h.engine.readAgentRuns(h.chatId);
    final tools = runs.where((run) => run.kind == 'state.tool').toList();
    expect(tools, hasLength(2));
    expect(tools.every((run) => run.result['committed'] == true), isTrue);
    final receipt = _rows(_map(_runAt(tools, 1).result['execution'])['receipts']).single;
    expect(receipt['accepted'], isTrue);
    expect(receipt['clamps'], isNotEmpty);
    expect(runs.where((run) => run.kind == 'state.rules'), hasLength(1));
    expect(runs.where((run) => run.kind != 'tool.turn').map((run) => run.result['invocationId']).toSet(), hasLength(1));
    expect(runs.where((run) => run.kind == 'tool.turn'), hasLength(1));
  });

  for (final reason in <String?>[null, 'length', 'content_filter']) {
    test('$reason preserves text but cannot commit tools rules or once effects', () async {
      final h = await _open(rules: [_tickRule()]);
      final active = await _reply(h, [
        const ModelText('visible body'),
        _tool(0, [_set(8)]),
      ], reason: reason);
      final done = _done(active);
      expect(done.finishReason, reason);
      expect(done.message.text, 'visible body');
      final snapshot = await h.engine.readState(h.chatId);
      expect(snapshot.values, {'n': 0, 'ticks': 0});
      expect(snapshot.changes, isEmpty);
      expect(snapshot.effects, isEmpty);
      final runtime = _saved(h, done.message.nodeId)['dshgoStateRuntime'];
      final ledger = runtime == null ? <String, Object?>{} : _map(runtime);
      expect(ledger['firedRules'] ?? const <String>[], isEmpty);
      expect(ledger['pendingPrompts'] ?? const <Object?>[], isEmpty);
      final runs = await _toolRuns(h);
      expect(runs.single.result['committed'], isFalse);
      expect(_codes(runs.single.result['issues']), contains('terminal-not-normal'));
      expect((await h.engine.readAgentRuns(h.chatId)).where((run) => run.kind == 'state.rules'), isEmpty);
      expect(h.model.generated, 1);
    });
  }

  test('a network failure after text and complete tools keeps partial body without candidate state', () async {
    final h = await _open(rules: [_tickRule()]);
    final active = await _reply(h, [
      const ModelText('partial body'),
      _tool(0, [_set(8)]),
    ], failure: TavernFailure.network);
    final failed = _failed(active);
    expect(failed.kind, TavernFailure.network);
    expect(failed.partial!.text, 'partial body');
    final snapshot = await h.engine.readState(h.chatId);
    expect(snapshot.values, {'n': 0, 'ticks': 0});
    expect(snapshot.changes, isEmpty);
    expect(snapshot.effects, isEmpty);
    final run = (await _toolRuns(h)).single;
    expect(run.nodeId, failed.partial!.nodeId);
    expect(run.result['committed'], isFalse);
    expect(run.result['outcome'], 'not-committed');
    expect(h.model.generated, 1);
    await h.reopen();
    expect((await h.engine.readState(h.chatId)).values, {'n': 0, 'ticks': 0});
    expect((await h.engine.path(h.chatId)).last.text, 'partial body');
  });

  for (final mode in ['thinking', 'prefill']) {
    test('$mode offers no state tool but a normal reply still settles declared rules', () async {
      final h = await _open(thinking: mode == 'thinking', prefill: mode == 'prefill', rules: [_tickRule()]);
      final active = await _reply(h, [
        const ModelText('body'),
        _tool(0, [_set(90)]),
      ]);
      _done(active);
      expect(active.call.body!.containsKey('tools'), isFalse);
      if (mode == 'prefill') {
        expect(_rows(active.call.body!['messages']).any((message) => message['prefix'] == true), isTrue);
      }
      final snapshot = await h.engine.readState(h.chatId);
      expect(snapshot.values, {'n': 0, 'ticks': 1});
      expect(snapshot.changes.single['path'], '/ticks');
      expect(snapshot.changes.single['actor'], 'rules');
      final runs = await h.engine.readAgentRuns(h.chatId);
      expect(runs.where((run) => run.kind == 'state.rules').single.result['committed'], isTrue);
      final tool = runs.singleWhere((run) => run.kind == 'state.tool');
      expect(tool.result['committed'], isFalse);
      expect(_codes(tool.result['issues']), contains('tool-not-offered'));
      expect(h.model.generated, 1);
    });
  }

  test('stateEnabled false rejects unsolicited tools and does not run automatic rules', () async {
    final h = await _open(rules: [_tickRule()]);
    await h.engine.setSettings({'stateEnabled': false}, chatId: h.chatId);
    final active = await _reply(h, [
      const ModelText('ordinary'),
      _tool(0, [_set(8)]),
    ]);
    _done(active);
    expect(_rows(active.call.body!['tools']).map((tool) => _map(tool['function'])['name']), ['roll']);
    final snapshot = await h.engine.readState(h.chatId);
    expect(snapshot.automaticEnabled, isFalse);
    expect(snapshot.values, {'n': 0, 'ticks': 0});
    expect(snapshot.changes, isEmpty);
    final runs = await h.engine.readAgentRuns(h.chatId);
    expect(runs.where((run) => run.kind == 'state.rules'), isEmpty);
    expect(runs.singleWhere((run) => run.kind == 'state.tool').result['committed'], isFalse);
  });

  test('a real terminal SQL failure cannot leak candidate state once prompts or effects into partial', () async {
    final initialRuntime = <String, Object?>{
      'version': 1,
      'firedRules': <String>[],
      'pendingPrompts': [
        {'id': 'old-prompt', 'text': 'OLD_PENDING_SENTINEL'},
      ],
      'future': {'kept': true},
    };
    final initial = <String, Object?>{
      'variables': {'local': 4},
      'messageVariables': {
        'dshgo': {'n': 0, 'ticks': 0},
        'stat_data': {'keep': 7},
      },
      'dshgoStateRuntime': initialRuntime,
    };
    final h = await _open(rules: [_tickRule(effects: true)], saved: initial);
    _db(
      h,
      (db) => db.execute(r'''CREATE TRIGGER reject_committed_state_tool
      BEFORE INSERT ON agent_runs
      WHEN NEW.kind = 'state.tool' AND json_extract(NEW.result_json, '$.committed') = 1
      BEGIN SELECT RAISE(ABORT, 'terminal_state_commit_failure'); END'''),
    );
    final active = await _reply(h, [
      const ModelText('kept partial'),
      _tool(0, [_set(7)]),
    ]);
    expect(jsonEncode(active.call.body!['messages']), contains('OLD_PENDING_SENTINEL'));
    final failure = _failed(active);
    expect(failure.kind, TavernFailure.server);
    expect(failure.partial!.text, 'kept partial');
    final partialId = failure.partial!.nodeId;
    final snapshot = await h.engine.readState(h.chatId);
    expect(snapshot.values, {'n': 0, 'ticks': 0});
    expect(snapshot.changes, isEmpty);
    expect(snapshot.effects, isEmpty);
    final partialState = _saved(h, partialId);
    expect(partialState['dshgoStateRuntime'], initialRuntime);
    expect(_map(partialState['messageVariables'])['stat_data'], {'keep': 7});
    expect(h.engine.variables(h.chatId), {'local': 4});
    final failedRuns = await h.engine.readAgentRuns(h.chatId);
    final failedStateRuns = failedRuns.where((run) => run.kind != 'tool.turn').toList();
    expect(failedStateRuns.map((run) => run.kind), unorderedEquals(['state.tool', 'state.rules']));
    expect(
      failedStateRuns.every(
        (run) =>
            run.nodeId == partialId && run.result['committed'] == false && run.result['outcome'] == 'not-committed',
      ),
      isTrue,
    );
    expect(failedStateRuns.map((run) => run.result['invocationId']).toSet(), hasLength(1));
    expect(failedRuns.where((run) => run.kind == 'tool.turn'), hasLength(1));
    expect(
      _db(h, (db) => db.select(r"SELECT id FROM agent_runs WHERE json_extract(result_json, '$.committed') = 1")),
      isEmpty,
    );
    _expectForeignKeys(h);
    await h.reopen();
    expect((await h.engine.readState(h.chatId)).values, {'n': 0, 'ticks': 0});
    expect(_saved(h, partialId)['dshgoStateRuntime'], initialRuntime);
    expect((await h.engine.readAgentRuns(h.chatId)).map((run) => run.id), failedRuns.map((run) => run.id));

    _db(h, (db) => db.execute('DROP TRIGGER reject_committed_state_tool'));
    final retry = await _reply(h, [
      const ModelText('success'),
      _tool(0, [_set(7)]),
    ]);
    final success = _done(retry);
    final committed = await h.engine.readState(h.chatId);
    expect(committed.values, {'n': 7, 'ticks': 1});
    expect(committed.effects.map((effect) => effect['type']), unorderedEquals(['prompt', 'notice', 'event', 'unlock']));
    final unlock = committed.effects.singleWhere((effect) => effect['type'] == 'unlock');
    expect(unlock['id'], 'ending-key');
    expect(unlock['effectId'], isNot('ending-key'));
    expect(
      committed.effects.every((effect) => effect['effectId'] is String && (effect['effectId']! as String).isNotEmpty),
      isTrue,
    );
    expect(committed.effects.map((effect) => effect['effectId']).toSet(), hasLength(4));
    final runtime = _map(_saved(h, success.message.nodeId)['dshgoStateRuntime']);
    expect(runtime['firedRules'], ['id:tick']);
    expect(runtime['future'], {'kept': true});
    final prompt = _rows(runtime['pendingPrompts']).single;
    expect(prompt['text'], 'NEW_PENDING_SENTINEL');
    expect(prompt['id'], committed.effects.singleWhere((effect) => effect['type'] == 'prompt')['effectId']);
    expect(_saved(h, partialId)['dshgoStateRuntime'], initialRuntime);
    final allRuns = await h.engine.readAgentRuns(h.chatId);
    expect(allRuns.where((run) => run.kind != 'tool.turn'), hasLength(4));
    expect(allRuns.where((run) => run.kind == 'tool.turn'), hasLength(2));
    final successfulRuns = allRuns.where((run) => run.nodeId == success.message.nodeId).toList();
    expect(successfulRuns.map((run) => run.kind), unorderedEquals(['state.tool', 'state.rules']));
    expect(successfulRuns.every((run) => run.result['committed'] == true), isTrue);
    expect(h.model.generated, 2);
  });

  test('a canceled tool-only continue preserves the original body state and successful own audit', () async {
    final h = await _open();
    final original = _done(
      await _reply(h, [
        const ModelText('BASE'),
        _tool(0, [_set(2)]),
      ]),
    ).message;
    final ownBefore = _own(h, original.nodeId);
    final before = await h.engine.readState(h.chatId);
    final previousRuns = await h.engine.readAgentRuns(h.chatId);
    final active = await _start(h, continueNode: original.nodeId);
    try {
      _expectOffered(active.call.body!);
      active.call.add(_tool(0, [_set(9)]));
      h.engine.stop(h.chatId);
      await active.events.done.future;
    } finally {
      await active.call.close();
    }
    final failed = _failed(active);
    expect(failed.kind, TavernFailure.cancelled);
    expect(failed.partial!.nodeId, original.nodeId);
    expect(failed.partial!.text, 'BASE');
    final after = await h.engine.readState(h.chatId);
    expect(after.values, before.values);
    expect(after.changes, before.changes);
    expect(after.effects, before.effects);
    final ownAfter = _own(h, original.nodeId);
    for (final key in ['stateInvocation', 'stateChanges', 'stateEffects', 'tavernState']) {
      expect(ownAfter[key], ownBefore[key], reason: key);
    }
    final runs = await h.engine.readAgentRuns(h.chatId);
    final freshRuns = runs.where((run) => !previousRuns.any((old) => old.id == run.id)).toList();
    final fresh = freshRuns.where((run) => run.kind != 'tool.turn').single;
    expect(freshRuns.where((run) => run.kind == 'tool.turn'), hasLength(1));
    expect(fresh.kind, 'state.tool');
    expect(fresh.nodeId, original.nodeId);
    expect(fresh.result['committed'], isFalse);
    expect(fresh.result['outcome'], 'not-committed');
    expect((await h.engine.path(h.chatId)).last.text, 'BASE');
    _expectForeignKeys(h);
    await h.reopen();
    expect((await h.engine.readState(h.chatId)).changes, before.changes);
    expect((await h.engine.readState(h.chatId)).values, before.values);
  });

  test('a 65th tool call blocks the whole prefix and records the batch resource refusal', () async {
    final h = await _open();
    final active = await _reply(h, [
      for (var i = 0; i < 65; i++) _tool(i, [_add(1)]),
    ]);
    _done(active);
    final snapshot = await h.engine.readState(h.chatId);
    expect(snapshot.values, {'n': 0, 'ticks': 0});
    expect(snapshot.changes, isEmpty);
    final runs = await h.engine.readAgentRuns(h.chatId, limit: 100);
    final tools = runs.where((run) => run.kind == 'state.tool').toList();
    expect(tools, hasLength(64));
    expect(tools.every((run) => run.result['committed'] == false), isTrue);
    final batch = runs.singleWhere((run) => run.kind == 'state.tool_batch');
    expect(batch.result['eligibleStructure'], isFalse);
    expect(_codes(batch.result['issues']), contains('tool_call_limit'));
    expect(h.model.generated, 1);
  });
}

Future<_Harness> _open({
  int? step,
  bool thinking = false,
  bool prefill = false,
  List<Map<String, Object?>> rules = const [],
  Map<String, Object?>? saved,
}) async {
  final root = await Directory.systemTemp.createTemp('dsh-t17-engine-tools-');
  final model = T24Model();
  final config = TavernModelConfig(apiKey: () async => 'fixture-only', model: 'fixture', thinking: thinking);
  TavernEngine? opened;
  try {
    opened = await TavernEngine.openDirectory(
      root,
      config: config,
      modelClient: model,
      clock: () => T24Harness.at,
      random: () => 0.25,
    );
    final preset = t24Preset().raw;
    preset['openai_max_context'] = 16384;
    preset['continue_prefill'] = false;
    preset['continue_nudge_prompt'] = 'Continue the existing reply.';
    if (prefill) {
      preset['assistant_prefill'] = 'PREFIX';
      preset['extensions'] = {
        'dshgo': {
          'prefill': {'enabled': true, 'target': 'content'},
        },
      };
    }
    await opened.setPreset(ChatPreset(preset));
    final card = _map(jsonDecode(utf8.decode(t24Card())));
    _map(card['data'])['extensions'] = {
      'dshgo': {
        'v': 1,
        'state': {
          'schema': {
            'type': 'object',
            'additionalProperties': false,
            'required': ['n', 'ticks'],
            'properties': {
              'n': {'type': 'integer', 'minimum': 0, 'maximum': 100, 'default': 0, 'x-dsh-step': ?step},
              'ticks': {
                'type': 'integer',
                'default': 0,
                'x-dsh-by': ['rules', 'user'],
              },
            },
          },
          'rules': rules,
        },
      },
    };
    final character = await opened.importCard(Uint8List.fromList(utf8.encode(jsonEncode(card))));
    String chatId;
    if (saved == null) {
      chatId = await opened.createChat(character.id);
    } else {
      final document = StChatDocument(
        fileName: 'saved-state.jsonl',
        header: {
          'user_name': 'User',
          'character_name': 'Guide',
          'chat_metadata': {'variables': saved['variables']},
        },
        messages: [
          {
            'name': 'Guide',
            'is_user': false,
            'is_system': false,
            'mes': 'G',
            'send_date': T24Harness.at.toIso8601String(),
            'extra': {
              'dshgo': {'tavernState': saved},
            },
          },
        ],
      );
      chatId = (await opened.importChats(character.id, [
        TavernChatFile(fileName: document.fileName, bytes: document.encode()),
      ])).chatIds.single;
    }
    final h = _Harness(root, model, config, opened, chatId);
    addTearDown(h.dispose);
    return h;
  } catch (_) {
    await opened?.close();
    await root.delete(recursive: true);
    rethrow;
  }
}

class _Harness {
  _Harness(this.root, this.model, this.config, this.engine, this.chatId);
  final Directory root;
  final T24Model model;
  final TavernModelConfig config;
  TavernEngine engine;
  final String chatId;

  Future<void> reopen() async {
    await engine.close();
    engine = await TavernEngine.openDirectory(
      root,
      config: config,
      modelClient: model,
      clock: () => T24Harness.at,
      random: () => 0.25,
    );
  }

  Future<void> dispose() async {
    await engine.close();
    for (final call in model.allCalls) {
      if (call.cancellation == null) {
        unawaited(call.close());
      } else {
        await call.close();
      }
    }
    await root.delete(recursive: true);
  }
}

class _Active {
  _Active(this.call, this.events);
  final T24Call call;
  final T24Events events;
}

Future<_Active> _start(_Harness h, {String? continueNode}) async {
  final call = h.model.prepare();
  final events = T24Events(
    continueNode == null ? h.engine.send(h.chatId, 'question') : h.engine.continueReply(h.chatId, continueNode),
  );
  // If preparation fails before generate, report that terminal immediately
  // rather than waiting forever for a model onListen that will never happen.
  await Future.any<void>([
    call.listening.future,
    events.done.future.then<void>((_) {
      throw TestFailure('Turn ended before the model listened: ${events.values}');
    }),
  ]);
  return _Active(call, events);
}

Future<_Active> _reply(_Harness h, List<ModelDelta> deltas, {String? reason = 'stop', TavernFailure? failure}) async {
  final active = await _start(h);
  try {
    for (final delta in deltas) {
      active.call.add(delta);
    }
    if (failure == null) {
      active.call.add(ModelFinished(reason));
    } else {
      active.call.fail(failure, 'controlled transport failure');
    }
    await active.events.done.future;
    return active;
  } finally {
    await active.call.close();
  }
}

TavernTurnDone _done(_Active active) {
  expect(active.events.values.whereType<TavernTurnFailed>(), isEmpty);
  return active.events.values.whereType<TavernTurnDone>().single;
}

TavernTurnFailed _failed(_Active active) {
  expect(active.events.values.whereType<TavernTurnDone>(), isEmpty);
  return active.events.values.whereType<TavernTurnFailed>().single;
}

ModelToolFragment _tool(int index, List<Map<String, Object?>> ops, {String? id}) => ModelToolFragment(
  index: index,
  id: id ?? 'provider-$index',
  type: 'function',
  name: 'update_state',
  arguments: jsonEncode({'ops': ops}),
);
Map<String, Object?> _set(int value) => {'op': 'set', 'path': '/n', 'value': value, 'why': 'model fixture'};
Map<String, Object?> _add(int value) => {'op': 'add', 'path': '/n', 'value': value, 'why': 'model fixture'};
Map<String, Object?> _tickRule({bool once = true, bool effects = false}) => {
  'id': 'tick',
  'when': true,
  'once': once,
  'do': [
    {
      'type': 'state',
      'ops': [
        {'op': 'add', 'path': '/ticks', 'value': 1, 'why': 'rule fixture'},
      ],
    },
    if (effects) ...[
      {'type': 'prompt', 'text': 'NEW_PENDING_SENTINEL'},
      {'type': 'notice', 'text': 'NOTICE_SENTINEL'},
      {
        'type': 'event',
        'name': 'plot',
        'data': {'value': 1},
      },
      {'type': 'unlock', 'kind': 'ending', 'id': 'ending-key', 'title': 'Ending'},
    ],
  ],
};

void _expectOffered(Map<String, Object?> body) =>
    expect(_rows(body['tools']).any((tool) => _map(tool['function'])['name'] == 'update_state'), isTrue);
Future<List<TavernAgentRun>> _toolRuns(_Harness h) async =>
    (await h.engine.readAgentRuns(h.chatId)).where((run) => run.kind == 'state.tool').toList();
TavernAgentRun _runAt(List<TavernAgentRun> runs, int index) =>
    runs.singleWhere((run) => _map(run.result['tool'])['index'] == index);
List<Object?> _codes(Object? issues) => [for (final issue in _rows(issues)) issue['code']];
Map<String, Object?> _map(Object? value) => value as Map<String, Object?>;
List<Map<String, Object?>> _rows(Object? value) => value is List<Object?> ? value.map(_map).toList() : [];

T _db<T>(_Harness h, T Function(Database) action) {
  final db = sqlite3.open('${h.root.path}/tavern.sqlite3');
  try {
    return action(db);
  } finally {
    db.close();
  }
}

String _extra(_Harness h, String nodeId) =>
    _db(h, (db) => db.select('SELECT extra FROM nodes WHERE id = ?', [nodeId]).single['extra']! as String);
Map<String, Object?> _own(_Harness h, String nodeId) => _map(_map(jsonDecode(_extra(h, nodeId)))['dshgo']);
Map<String, Object?> _saved(_Harness h, String nodeId) => _map(_own(h, nodeId)['tavernState']);
void _expectForeignKeys(_Harness h) => expect(_db(h, (db) => db.select('PRAGMA foreign_key_check').isEmpty), isTrue);

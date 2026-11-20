import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import 'support/t24_engine_harness.dart';

const _literal = '{{incvar::must_not_run}}{{getglobalvar::must_not_read}}';
const _secret = 'HIDDEN-STATE-SENTINEL';

Map<String, Object?> _definition({List<Object?> rules = const [], int step = 5}) => {
  'schema': {
    'type': 'object',
    'additionalProperties': false,
    'required': ['count', 'label', 'secret'],
    'properties': {
      'count': {
        'type': 'integer',
        'minimum': 0,
        'maximum': 100,
        'default': 0,
        'x-dsh-step': step,
        'x-dsh-show': 'number',
        'x-dsh-pin': true,
        'description': '公开计数',
      },
      'label': {'type': 'string', 'default': _literal},
      'secret': {
        'type': 'string',
        'default': _secret,
        'x-dsh-hidden': true,
        'description': 'HIDDEN-DESCRIPTION-SENTINEL',
        'x-dsh-by': ['rules', 'user'],
      },
    },
  },
  'init': {'count': 0, 'label': _literal, 'secret': _secret},
  'rules': rules,
};

Future<({String characterId, String chatId})> _stateChat(T24Harness h, {Map<String, Object?>? definition}) async {
  final raw = jsonDecode(utf8.decode(t24Card())) as Map<String, Object?>;
  _map(raw['data'])['extensions'] = {
    'dshgo': {'v': 1, 'state': definition ?? _definition()},
  };
  final character = await h.engine.importCard(Uint8List.fromList(utf8.encode(jsonEncode(raw))));
  return (characterId: character.id, chatId: await h.engine.createChat(character.id));
}

Map<String, Object?> _map(Object? value) => value! as Map<String, Object?>;
List<Map<String, Object?>> _maps(Object? value) => (value! as List<Object?>).cast<Map<String, Object?>>();
num _count(TavernStateSnapshot snapshot) => _map(snapshot.values)['count']! as num;

T _db<T>(T24Harness h, T Function(Database db) action) {
  final db = sqlite3.open('${h.root.path}/tavern.sqlite3');
  try {
    return action(db);
  } finally {
    db.close();
  }
}

Map<String, Object?> _rows(T24Harness h) => _db(
  h,
  (db) => {
    for (final table in ['chats', 'nodes', 'node_states', 'agent_runs'])
      table: [for (final row in db.select('SELECT * FROM $table ORDER BY rowid')) Map<String, Object?>.from(row)],
  },
);

Future<Map<String, Object?>> _saved(TavernEngine engine, String chat) async {
  final files = await engine.exportChat(chat);
  final source = StChatDocument.decode(files.first.fileName, files.first.bytes);
  final saved = _map(_map(_map(source.messages.last['extra'])['dshgo'])['tavernState']);
  // The decoded document is deeply read-only; mutation fixtures need their own
  // complete JSON tree, including nested message variables and runtime values.
  return _map(jsonDecode(jsonEncode(saved)));
}

Future<void> _replaceSaved(T24Harness h, String chat, Map<String, Object?> saved) async {
  final leaf = (await h.engine.path(chat)).last.nodeId;
  _db(h, (db) {
    final extra =
        jsonDecode(db.select('SELECT extra FROM nodes WHERE id = ?', [leaf]).single['extra']! as String)
            as Map<String, Object?>;
    final own = extra['dshgo'] is Map<String, Object?> ? _map(extra['dshgo']) : <String, Object?>{};
    extra['dshgo'] = {...own, 'tavernState': saved};
    db.execute('UPDATE nodes SET extra = ? WHERE id = ?', [jsonEncode(extra), leaf]);
  });
}

Future<void> _listening(T24Call call, T24Events events) => Future.any<void>([
  call.listening.future,
  events.done.future.then<void>((_) {
    throw TestFailure('Turn ended before model input: ${events.values}');
  }),
]);

Future<TavernMessage> _reply(
  T24Harness h,
  String chat, {
  String reason = 'stop',
  String text = 'body',
  List<Map<String, Object?>>? ops,
  String input = '',
}) async {
  final call = h.model.prepare();
  final events = T24Events(h.engine.send(chat, input));
  await _listening(call, events);
  if (text.isNotEmpty) {
    call.add(ModelText(text));
  }
  if (ops != null) {
    call.add(
      ModelToolFragment(
        index: 0,
        id: 'state-call',
        type: 'function',
        name: 'update_state',
        arguments: jsonEncode({
          'ops': [
            for (final op in ops) {'why': 'model fixture', ...op},
          ],
        }),
      ),
    );
  }
  await call.finish(reason);
  await events.done.future;
  expect(events.values.whereType<TavernTurnFailed>(), isEmpty);
  return events.values.whereType<TavernTurnDone>().single.message;
}

Future<TavernMessage> _regenerate(
  T24Harness h,
  String chat,
  String node, {
  required int count,
  String reason = 'stop',
}) async {
  final call = h.model.prepare();
  final events = T24Events(h.engine.regenerate(chat, node));
  await _listening(call, events);
  call.add(ModelText('branch $count'));
  call.add(
    ModelToolFragment(
      index: 0,
      id: 'branch-call',
      type: 'function',
      name: 'update_state',
      arguments: jsonEncode({
        'ops': [
          {'op': 'set', 'path': '/count', 'value': count, 'why': 'branch fixture'},
        ],
      }),
    ),
  );
  await call.finish(reason);
  await events.done.future;
  expect(events.values.whereType<TavernTurnFailed>(), isEmpty);
  return events.values.whereType<TavernTurnDone>().single.message;
}

Future<String> _importSaved(
  T24Harness h,
  String characterId,
  Map<String, Object?> saved, {
  String name = 'saved-state.jsonl',
}) async {
  final document = StChatDocument(
    fileName: name,
    header: {
      'user_name': 'User',
      'character_name': 'Guide',
      'chat_metadata': {
        'variables': {'local': 'keep'},
      },
    },
    messages: [
      {
        'name': 'Guide',
        'is_user': false,
        'is_system': false,
        'mes': 'imported',
        'send_date': T24Harness.at.toIso8601String(),
        'variables': [saved['messageVariables']],
        'extra': {
          'dshgo': {'tavernState': saved},
        },
      },
    ],
  );
  return (await h.engine.importChats(characterId, [
    TavernChatFile(fileName: name, bytes: document.encode()),
  ])).chatIds.single;
}

List<Map<String, Object?>> _pending(Map<String, Object?> saved) {
  final runtime = saved['dshgoStateRuntime'];
  if (runtime is! Map<String, Object?>) {
    return [];
  }
  final pending = runtime['pendingPrompts'];
  return pending is List<Object?> ? pending.map(_map).toList() : [];
}

String _requestText(T24Call call) => (call.body!['messages']! as List<Object?>)
    .map((message) => _map(message)['content'])
    .whereType<String>()
    .join('\n');

List<Object?> _promptRules() => [
  {
    'id': 'first-prompt',
    'when': {
      '==': [
        {'var': 'count'},
        1,
      ],
    },
    'once': true,
    'do': [
      {'type': 'prompt', 'text': 'OLD-PENDING-$_literal'},
    ],
  },
  {
    'id': 'second-prompt',
    'when': {
      '==': [
        {'var': 'count'},
        2,
      ],
    },
    'once': true,
    'do': [
      {'type': 'prompt', 'text': 'NEW-PENDING-$_literal'},
    ],
  },
];

void main() {
  test('create initializes defaults without rules and reads return detached raw schema and saved values', () async {
    final h = await T24Harness.open(thinking: false);
    addTearDown(h.dispose);
    final created = await _stateChat(
      h,
      definition: _definition(
        rules: [
          {
            'id': 'not-on-read',
            'when': true,
            'once': true,
            'do': [
              {'type': 'notice', 'text': 'not yet'},
            ],
          },
        ],
      ),
    );
    final before = _rows(h);
    final Tavern facade = h.engine;
    final snapshot = await facade.readState(created.chatId);
    expect(snapshot.legacy, isFalse);
    expect(snapshot.initialized, isTrue);
    expect(snapshot.valueExists, isTrue);
    expect(snapshot.initialValuesAvailable, isFalse);
    expect(_count(snapshot), 0);
    expect(snapshot.hiddenPaths, contains('/secret'));
    expect(snapshot.pinPaths, contains('/count'));
    expect(snapshot.changes, isEmpty);
    expect(snapshot.effects, isEmpty);
    _map(snapshot.values)['count'] = 99;
    _map(_map(_map(snapshot.schema)['properties'])['count'])['description'] = 'caller';
    expect(_count(snapshot), 0);
    expect(_map(_map(_map(snapshot.schema)['properties'])['count'])['description'], '公开计数');
    expect(_count(await facade.readState(created.chatId)), 0);
    expect(await facade.readAgentRuns(created.chatId), isEmpty);
    expect(_rows(h), before);
    expect(h.engine.variables(created.chatId), isEmpty);
    expect(h.engine.globalVariables, isEmpty);
    expect(h.model.generated, 0);
  });

  test(
    'import and reads do not initialize a missing DSH value and manual append preserves foreign neighbors',
    () async {
      final h = await T24Harness.open(thinking: false);
      addTearDown(h.dispose);
      final created = await _stateChat(h);
      final source = StChatDocument(
        fileName: 'missing-state.jsonl',
        header: {
          'user_name': 'User',
          'character_name': 'Guide',
          'chat_metadata': {
            'variables': {'local': 'kept'},
          },
        },
        messages: [
          {
            'name': 'Guide',
            'is_user': false,
            'is_system': false,
            'mes': 'imported',
            'send_date': T24Harness.at.toIso8601String(),
            'variables': [
              {
                'stat_data': {'foreign': 7},
              },
            ],
          },
        ],
      );
      final imported = (await h.engine.importChats(created.characterId, [
        TavernChatFile(fileName: source.fileName, bytes: source.encode()),
      ])).chatIds.single;
      final before = _rows(h);
      final snapshot = await h.engine.readState(imported);
      expect(snapshot.initialized, isFalse);
      expect(snapshot.valueExists, isFalse);
      expect(snapshot.initialValuesAvailable, isTrue);
      expect(_map(snapshot.initialValues)['count'], 0);
      expect(_rows(h), before);
      expect(_map((await _saved(h.engine, imported))['messageVariables']), {
        'stat_data': {'foreign': 7},
      });
      await h.engine.sendOnly(imported, 'manual');
      final saved = await _saved(h.engine, imported);
      expect(_map(saved['messageVariables'])['stat_data'], {'foreign': 7});
      expect(_map(_map(saved['messageVariables'])['dshgo'])['count'], 0);
      expect(await h.engine.readVariables(imported), {'local': 'kept'});
      expect(await h.engine.readAgentRuns(imported), isEmpty);
      expect(h.model.generated, 0);
    },
  );

  test('an explicit saved null is initialized and is not replaced by a default', () async {
    final h = await T24Harness.open(thinking: false);
    addTearDown(h.dispose);
    final created = await _stateChat(
      h,
      definition: {
        'schema': {
          'type': ['null', 'string'],
          'default': 'must not replace null',
        },
        'init': null,
      },
    );
    final snapshot = await h.engine.readState(created.chatId);
    expect(snapshot.valueExists, isTrue);
    expect(snapshot.initialized, isTrue);
    expect(snapshot.values, isNull);
    expect(snapshot.initialValuesAvailable, isFalse);
    await h.reopen();
    expect((await h.engine.readState(created.chatId)).values, isNull);
  });

  test('an explicit invalid schema stays DSH and cannot fall back to editing ST variables', () async {
    final h = await T24Harness.open(thinking: false);
    addTearDown(h.dispose);
    final created = await _stateChat(
      h,
      definition: {
        'schema': null,
        'init': {'count': 0},
      },
    );
    final snapshot = await h.engine.readState(created.chatId);
    expect(snapshot.legacy, isFalse);
    expect(snapshot.issues, isNotEmpty);
    final result = await h.engine.setStateValue(created.chatId, '/x', 4);
    expect(result.applied, isFalse);
    expect(await h.engine.readVariables(created.chatId), isEmpty);
    expect(result.snapshot.changes, isEmpty);
    expect((await h.engine.readAgentRuns(created.chatId)).single.result['committed'], isFalse);
  });

  test('user edits clamp through the shared validator and rejected edits preserve the previous own audit', () async {
    final h = await T24Harness.open(thinking: false);
    addTearDown(h.dispose);
    final created = await _stateChat(h);
    final changed = await h.engine.setStateValue(created.chatId, '/count', 999);
    expect(changed.applied, isTrue);
    expect(changed.changed, isTrue);
    expect(_count(changed.snapshot), 5);
    expect(changed.snapshot.changes.single, containsPair('actor', 'user'));
    expect(changed.snapshot.changes.single['old'], 0);
    expect(changed.snapshot.changes.single['new'], 5);
    final audit = changed.snapshot.changes;
    final rejected = await h.engine.setStateValue(created.chatId, '/count', 'not a number');
    expect(rejected.applied, isFalse);
    expect(rejected.snapshot.changes, audit);
    expect(_count(rejected.snapshot), 5);
    final same = await h.engine.setStateValue(created.chatId, '/count', 5);
    expect(same.applied, isTrue);
    expect(same.changed, isFalse);
    expect(same.snapshot.changes, isEmpty);
    final runs = await h.engine.readAgentRuns(created.chatId);
    expect(runs, hasLength(3));
    expect(runs[1].result['committed'], isFalse);
    runs.last.result['committed'] = false;
    expect(runs.last.result['committed'], isTrue);
    expect(h.model.generated, 0);
  });

  test('legacy edits use JSON Pointer escaping without macros globals or invented intermediate containers', () async {
    final h = await T24Harness.open(thinking: false);
    addTearDown(h.dispose);
    final seeded = await h.engine.setStateValue(h.chatId, '', {
      'a/b': {
        '~x': [1, true],
      },
      '01': 'object key',
      'literal': _literal,
    });
    expect(seeded.applied, isTrue);
    expect(seeded.snapshot.legacy, isTrue);
    expect((await h.engine.setStateValue(h.chatId, '/a~1b/~0x/0', null)).applied, isTrue);
    expect((await h.engine.setStateValue(h.chatId, '/01', 'still object')).applied, isTrue);
    for (final path in ['/a~1b/~0x/00', '/missing/child', '/a~2b']) {
      expect((await h.engine.setStateValue(h.chatId, path, 4)).applied, isFalse, reason: path);
    }
    expect((await h.engine.setStateValue(h.chatId, '', [1])).applied, isFalse);
    expect(await h.engine.readVariables(h.chatId), {
      'a/b': {
        '~x': [null, true],
      },
      '01': 'still object',
      'literal': _literal,
    });
    expect(h.engine.variables(h.chatId), await h.engine.readVariables(h.chatId));
    expect(h.engine.globalVariables, isEmpty);
    await h.reopen();
    expect(_map((await h.engine.readState(h.chatId)).values)['literal'], _literal);
    expect(h.model.generated, 0);
  });

  test('expected node guards and an empty selected path reject without changing saved state', () async {
    final h = await T24Harness.open(thinking: false);
    addTearDown(h.dispose);
    final created = await _stateChat(h);
    final first = (await h.engine.path(created.chatId)).single;
    final second = await h.engine.sendOnly(created.chatId, 'second');
    final rejected = await h.engine.setStateValue(created.chatId, '/count', 3, expectedNodeId: first.nodeId);
    expect(rejected.applied, isFalse);
    expect(rejected.snapshot.nodeId, second.nodeId);
    expect(_count(rejected.snapshot), 0);
    await h.engine.deleteFrom(created.chatId, first.nodeId);
    final empty = await h.engine.setStateValue(created.chatId, '/count', 3);
    expect(empty.applied, isFalse);
    expect(empty.snapshot.nodeId, isNull);
    expect((await h.engine.readAgentRuns(created.chatId)).first.nodeId, isNull);
  });

  test('manual input is copied before cancellation waits and edits the selected leaf after empty rollback', () async {
    final h = await T24Harness.open(thinking: false);
    addTearDown(h.dispose);
    final first = (await h.engine.path(h.chatId)).single;
    final call = h.model.prepare();
    final events = T24Events(h.engine.send(h.chatId, 'question'));
    await _listening(call, events);
    final input = <String, Object?>{
      'items': <Object?>[1, 2],
    };
    final edit = h.engine.setStateValue(h.chatId, '/snapshot', input, expectedNodeId: first.nodeId);
    (input['items']! as List<Object?>).add('caller');
    final result = await edit;
    await events.done.future;
    expect(events.values.whereType<TavernTurnFailed>().single.kind, TavernFailure.cancelled);
    expect(result.applied, isTrue);
    expect(result.snapshot.nodeId, first.nodeId);
    expect(_map(result.snapshot.values)['snapshot'], {
      'items': [1, 2],
    });
    expect(call.cancellation!.isCancelled, isTrue);
  });

  test('a real audit INSERT failure rolls back the manual node chat and cache together', () async {
    final h = await T24Harness.open(thinking: false);
    addTearDown(h.dispose);
    await h.engine.setStateValue(h.chatId, '/x', 1);
    final before = _rows(h);
    _db(
      h,
      (db) => db.execute(
        "CREATE TRIGGER reject_state_edit BEFORE INSERT ON agent_runs "
        "WHEN NEW.kind = 'state.user' BEGIN SELECT RAISE(ABORT, 'fixture audit failure'); END",
      ),
    );
    try {
      await expectLater(h.engine.setStateValue(h.chatId, '/x', 2), throwsA(isA<SqliteException>()));
      expect(_rows(h), before);
      expect(h.engine.variables(h.chatId), {'x': 1});
      expect(_map((await h.engine.readState(h.chatId)).values), {'x': 1});
    } finally {
      _db(h, (db) => db.execute('DROP TRIGGER reject_state_edit'));
    }
    await h.reopen();
    expect(_map((await h.engine.readState(h.chatId)).values), {'x': 1});
    expect(await h.engine.readAgentRuns(h.chatId), hasLength(1));
  });

  test('hidden fields stay editable by permitted users while inherited actor restrictions are enforced', () async {
    final h = await T24Harness.open(thinking: false);
    addTearDown(h.dispose);
    final definition = _definition();
    _map(_map(_map(definition['schema'])['properties'])['count'])['x-dsh-by'] = ['model', 'rules'];
    final created = await _stateChat(h, definition: definition);
    final denied = await h.engine.setStateValue(created.chatId, '/count', 1);
    expect(denied.applied, isFalse);
    expect(_count(denied.snapshot), 0);
    final allowed = await h.engine.setStateValue(created.chatId, '/secret', 'user secret');
    expect(allowed.applied, isTrue);
    expect(_map(allowed.snapshot.values)['secret'], 'user secret');
    expect(allowed.snapshot.hiddenPaths, contains('/secret'));
    expect(allowed.snapshot.changes.single['actor'], 'user');
    expect(allowed.snapshot.changes.single['path'], '/secret');
  });

  test('swipes restore their own state and permanent deletion retains run history with a null anchor', () async {
    final h = await T24Harness.open(thinking: false);
    addTearDown(h.dispose);
    final created = await _stateChat(h);
    final first = await _reply(
      h,
      created.chatId,
      text: 'branch 2',
      ops: [
        {'op': 'set', 'path': '/count', 'value': 2},
      ],
    );
    final second = await _regenerate(h, created.chatId, first.nodeId, count: 4);
    expect(_count(await h.engine.readState(created.chatId)), 4);
    await h.engine.selectSibling(created.chatId, second.nodeId, 0);
    final firstState = await h.engine.readState(created.chatId);
    expect(_count(firstState), 2);
    expect(firstState.changes.single['old'], 0);
    expect(firstState.changes.single['new'], 2);
    await h.engine.selectSibling(created.chatId, first.nodeId, 1);
    final before = await h.engine.readState(created.chatId);
    final firstRuns = await h.engine.readAgentRuns(created.chatId, nodeId: first.nodeId);
    expect(firstRuns, isNotEmpty);
    await h.engine.deleteMessage(created.chatId, first.nodeId);
    expect((await h.engine.readState(created.chatId)).values, before.values);
    expect((await h.engine.readState(created.chatId)).changes, before.changes);
    expect(await h.engine.readAgentRuns(created.chatId, nodeId: first.nodeId), isEmpty);
    final history = await h.engine.readAgentRuns(created.chatId);
    for (final old in firstRuns) {
      final retained = history.singleWhere((run) => run.id == old.id);
      expect(retained.nodeId, isNull);
      expect(retained.result, old.result);
    }
    await h.reopen();
    expect(_count(await h.engine.readState(created.chatId)), 4);
  });

  test(
    'manual append and single-message deletion preserve descendant state and pending prompts without inheriting own audit',
    () async {
      final h = await T24Harness.open(thinking: false);
      addTearDown(h.dispose);
      final created = await _stateChat(h, definition: _definition(rules: _promptRules()));
      final edited = await h.engine.setStateValue(created.chatId, '/count', 1);
      expect(edited.snapshot.effects, hasLength(1));
      final original = await _saved(h.engine, created.chatId);
      final greeting = (await h.engine.path(created.chatId)).single;
      final manual = await h.engine.sendOnly(created.chatId, 'manual');
      final narrator = await h.engine.narrate(created.chatId, 'narrator');
      final panel = await h.engine.readState(created.chatId);
      expect(panel.nodeId, narrator.nodeId);
      expect(_count(panel), 1);
      expect(panel.changes, isEmpty);
      expect(panel.effects, isEmpty);
      expect(_pending(await _saved(h.engine, created.chatId)), _pending(original));
      expect(await h.engine.readAgentRuns(created.chatId), hasLength(1));
      await h.engine.deleteMessage(created.chatId, greeting.nodeId);
      expect((await h.engine.path(created.chatId)).map((node) => node.nodeId), [manual.nodeId, narrator.nodeId]);
      expect(_count(await h.engine.readState(created.chatId)), 1);
      expect(_pending(await _saved(h.engine, created.chatId)), _pending(original));
      await h.reopen();
      expect(_count(await h.engine.readState(created.chatId)), 1);
      expect(_pending(await _saved(h.engine, created.chatId)), _pending(original));
      expect(h.model.generated, 0);
    },
  );

  test('rule effects keep action identities and once consumption survives reopening', () async {
    final h = await T24Harness.open(thinking: false);
    addTearDown(h.dispose);
    final created = await _stateChat(
      h,
      definition: _definition(
        rules: [
          {
            'id': 'reward',
            'when': {
              '>': [
                {'var': 'count'},
                0,
              ],
            },
            'once': true,
            'do': [
              {'type': 'notice', 'text': 'notice'},
              {
                'type': 'event',
                'name': 'milestone',
                'data': {
                  'opaque': [1, true],
                },
              },
              {'type': 'unlock', 'kind': 'achievement', 'id': 'original-achievement', 'title': 'Unlocked'},
              {'type': 'prompt', 'text': _literal},
            ],
          },
        ],
      ),
    );
    final first = await h.engine.setStateValue(created.chatId, '/count', 1);
    final effects = first.snapshot.effects;
    expect(effects, hasLength(4));
    expect(effects.map((effect) => effect['effectId']).toSet(), hasLength(4));
    expect(
      effects.every((effect) => effect['effectId'] is String && (effect['effectId']! as String).isNotEmpty),
      isTrue,
    );
    expect(effects.singleWhere((effect) => effect['type'] == 'unlock')['id'], 'original-achievement');
    expect(effects.every((effect) => effect['source'] == 'rules' && effect['ruleId'] == 'id:reward'), isTrue);
    final saved = await _saved(h.engine, created.chatId);
    expect(_map(saved['dshgoStateRuntime'])['firedRules'], ['id:reward']);
    expect(_pending(saved).single['id'], effects.singleWhere((effect) => effect['type'] == 'prompt')['effectId']);
    await h.reopen();
    final second = await h.engine.setStateValue(created.chatId, '/count', 2);
    expect(second.applied, isTrue);
    expect(second.snapshot.effects, isEmpty);
    expect(_pending(await _saved(h.engine, created.chatId)), _pending(saved));
    final runs = await h.engine.readAgentRuns(created.chatId);
    expect(runs, hasLength(2));
    expect(runs.last.result['effects'], effects);
    expect(runs.first.result['effects'], isEmpty);
  });

  test(
    'actual requests contain public descriptions and literal summaries without hidden values or macro effects',
    () async {
      final h = await T24Harness.open(thinking: false);
      addTearDown(h.dispose);
      final created = await _stateChat(h);
      final call = h.model.prepare();
      final events = T24Events(h.engine.send(created.chatId, ''));
      await _listening(call, events);
      final request = jsonEncode(call.body);
      expect(request, contains('公开计数'));
      expect(request, contains(_literal));
      expect(request, isNot(contains(_secret)));
      expect(request, isNot(contains('HIDDEN-DESCRIPTION-SENTINEL')));
      expect(request, isNot(contains('"secret"')));
      expect(call.body!['tools'], isNotEmpty);
      final rows = _rows(h);
      final inspection = (await h.engine.inspectTurn(created.chatId))!.toJson();
      final panel = await h.engine.readState(created.chatId);
      expect(_count(panel), 0);
      expect(_rows(h), rows);
      expect((await h.engine.inspectTurn(created.chatId))!.toJson(), inspection);
      expect(h.engine.variables(created.chatId), isEmpty);
      expect(h.engine.globalVariables, isEmpty);
      call.add(const ModelText('plain body'));
      await call.finish();
      await events.done.future;
      expect(events.values.whereType<TavernTurnFailed>(), isEmpty);
      expect(_map((await h.engine.readState(created.chatId)).values)['label'], _literal);
      expect(h.engine.variables(created.chatId), isEmpty);
      expect(h.engine.globalVariables, isEmpty);
    },
  );

  test('pending prompts consume only the sent parent set and a new effect remains for the next invocation', () async {
    final h = await T24Harness.open(thinking: false);
    addTearDown(h.dispose);
    final created = await _stateChat(h, definition: _definition(rules: _promptRules()));
    await h.engine.setStateValue(created.chatId, '/count', 1);
    final parent = await _saved(h.engine, created.chatId);
    final oldId = _pending(parent).single['id'];
    final normal = await _reply(
      h,
      created.chatId,
      ops: [
        {'op': 'set', 'path': '/count', 'value': 2},
      ],
    );
    final request = _requestText(h.model.allCalls.last);
    expect(request, contains('OLD-PENDING-$_literal'));
    expect(request, isNot(contains('NEW-PENDING-')));
    final savedNormal = await _saved(h.engine, created.chatId);
    final newPrompt = _pending(savedNormal).single;
    expect(newPrompt['id'], isNot(oldId));
    expect(newPrompt['text'], 'NEW-PENDING-$_literal');
    final trace = (await h.engine.inspectTurn(created.chatId))!.state;
    expect(trace['pendingIncluded'], [oldId]);
    final limited = await _regenerate(h, created.chatId, normal.nodeId, count: 2, reason: 'length');
    expect(_count(await h.engine.readState(created.chatId)), 1);
    expect(_pending(await _saved(h.engine, created.chatId)), _pending(parent));
    await h.engine.selectSibling(created.chatId, limited.nodeId, 0);
    expect(_count(await h.engine.readState(created.chatId)), 2);
    expect(_pending(await _saved(h.engine, created.chatId)), [newPrompt]);
  });

  test('an imported pending ID matching an ST extension is sent once and consumes its original ledger ID', () async {
    final h = await T24Harness.open(thinking: false);
    addTearDown(h.dispose);
    final created = await _stateChat(h);
    final raw = t24Preset().raw;
    (raw['prompts']! as List<Object?>).add({
      'identifier': 'authorsNote',
      'name': 'Authors note',
      'role': 'system',
      'system_prompt': false,
      'marker': false,
      'content': '',
      'injection_position': 1,
      'injection_depth': 0,
      'injection_order': 5,
    });
    (_map((raw['prompt_order']! as List<Object?>).single)['order']! as List<Object?>).add({
      'identifier': 'authorsNote',
      'enabled': true,
    });
    await h.engine.setPreset(ChatPreset(raw));
    final saved = await _saved(h.engine, created.chatId);
    saved['dshgoStateRuntime'] = {
      'version': 1,
      'firedRules': <String>[],
      'pendingPrompts': [
        {'id': '2_floating_prompt', 'text': 'RESERVED-PENDING-SENTINEL'},
      ],
    };
    final imported = await _importSaved(h, created.characterId, saved);
    expect(_pending(await _saved(h.engine, imported)).single['id'], '2_floating_prompt');
    await _reply(h, imported);
    final text = _requestText(h.model.allCalls.last);
    expect('RESERVED-PENDING-SENTINEL'.allMatches(text), hasLength(1));
    expect(_pending(await _saved(h.engine, imported)), isEmpty);
    final trace = (await h.engine.inspectTurn(imported))!.state;
    expect(trace['pendingOffered'], ['2_floating_prompt']);
    expect(trace['pendingIncluded'], ['2_floating_prompt']);
  });

  test('an optional pending prompt excluded by the actual context budget is retained', () async {
    final h = await T24Harness.open(thinking: false);
    addTearDown(h.dispose);
    final created = await _stateChat(h);
    final saved = await _saved(h.engine, created.chatId);
    final large = 'BUDGET-EXCLUDED-${List.filled(40000, 'x').join()}';
    saved['dshgoStateRuntime'] = {
      'version': 1,
      'firedRules': <String>[],
      'pendingPrompts': [
        {
          'id': 'large-prompt',
          'text': large,
          'vendor': {'keep': true},
        },
      ],
    };
    final imported = await _importSaved(h, created.characterId, saved);
    await _reply(h, imported);
    expect(_requestText(h.model.allCalls.last), isNot(contains('BUDGET-EXCLUDED-')));
    final trace = (await h.engine.inspectTurn(imported))!.state;
    expect(trace['pendingOffered'], ['large-prompt']);
    expect(trace['pendingIncluded'], isEmpty);
    expect(_pending(await _saved(h.engine, imported)), _pending(saved));
  });

  test('automatic state can be disabled while an explicit user edit still validates and runs rules', () async {
    final h = await T24Harness.open(thinking: false);
    addTearDown(h.dispose);
    await h.engine.setSettings({'stateEnabled': false});
    final created = await _stateChat(h, definition: _definition(rules: _promptRules()));
    final initial = await h.engine.readState(created.chatId);
    expect(initial.automaticEnabled, isFalse);
    expect(initial.valueExists, isFalse);
    expect(initial.initialValuesAvailable, isTrue);
    await _reply(h, created.chatId);
    expect(_maps(h.model.allCalls.last.body!['tools']).map((tool) => _map(tool['function'])['name']), ['roll']);
    expect(_requestText(h.model.allCalls.last), isNot(contains(_literal)));
    expect((await h.engine.readState(created.chatId)).valueExists, isFalse);
    final disabledRuns = await h.engine.readAgentRuns(created.chatId);
    expect(disabledRuns.where((run) => run.kind != 'tool.turn'), isEmpty);
    expect(disabledRuns.where((run) => run.kind == 'tool.turn'), hasLength(1));
    final explicit = await h.engine.setStateValue(created.chatId, '/count', 1);
    expect(explicit.applied, isTrue);
    expect(_count(explicit.snapshot), 1);
    expect(explicit.snapshot.automaticEnabled, isFalse);
    expect(explicit.snapshot.effects, hasLength(1));
    final pending = _pending(await _saved(h.engine, created.chatId));
    expect(pending, hasLength(1));
    await _reply(h, created.chatId);
    expect(_requestText(h.model.allCalls.last), isNot(contains('OLD-PENDING-')));
    expect(_pending(await _saved(h.engine, created.chatId)), pending);
    final explicitRuns = await h.engine.readAgentRuns(created.chatId);
    expect(explicitRuns.where((run) => run.kind != 'tool.turn'), hasLength(1));
    expect(explicitRuns.where((run) => run.kind == 'tool.turn'), hasLength(2));
  });

  for (final outcome in ['null', 'content_filter', 'cancelled', 'network']) {
    test('$outcome never consumes an old pending prompt that was sent in the actual request', () async {
      final h = await T24Harness.open(thinking: false);
      addTearDown(h.dispose);
      final created = await _stateChat(h, definition: _definition(rules: _promptRules()));
      await h.engine.setStateValue(created.chatId, '/count', 1);
      final pending = _pending(await _saved(h.engine, created.chatId));
      final call = h.model.prepare();
      final events = T24Events(h.engine.send(created.chatId, ''));
      await _listening(call, events);
      expect(_requestText(call), contains('OLD-PENDING-'));
      call.add(const ModelText('kept text'));
      try {
        if (outcome == 'cancelled') {
          h.engine.stop(created.chatId);
        } else if (outcome == 'network') {
          call.fail(TavernFailure.network, 'controlled pending prompt failure');
        } else {
          call.add(ModelFinished(outcome == 'null' ? null : outcome));
        }
        await events.done.future;
      } finally {
        await call.close();
      }
      if (outcome == 'cancelled' || outcome == 'network') {
        expect(events.values.whereType<TavernTurnFailed>(), hasLength(1));
      } else {
        expect(events.values.whereType<TavernTurnDone>(), hasLength(1));
      }
      expect(_count(await h.engine.readState(created.chatId)), 1);
      expect(_pending(await _saved(h.engine, created.chatId)), pending);
      expect((await h.engine.readState(created.chatId)).effects, isEmpty);
      final trace = (await h.engine.inspectTurn(created.chatId))!.state;
      expect(trace['pendingIncluded'], pending.map((prompt) => prompt['id']).toList());
      expect(trace['stateCommitted'], isFalse);
    });
  }

  test('impersonation neither sends state prompts nor consumes or writes state and its own audit', () async {
    final h = await T24Harness.open(thinking: false);
    addTearDown(h.dispose);
    final created = await _stateChat(h, definition: _definition(rules: _promptRules()));
    await h.engine.setStateValue(created.chatId, '/count', 1);
    final before = await h.engine.readState(created.chatId);
    final pending = _pending(await _saved(h.engine, created.chatId));
    final rows = _rows(h);
    final call = h.model.prepare();
    final events = T24Events(h.engine.impersonate(created.chatId));
    await _listening(call, events);
    expect(call.body!.containsKey('tools'), isFalse);
    expect(_requestText(call), isNot(contains(_literal)));
    expect(_requestText(call), isNot(contains('OLD-PENDING-')));
    call.add(const ModelText('suggested user line'));
    await call.finish();
    await events.done.future;
    expect(events.values.whereType<TavernTurnFailed>(), isEmpty);
    final after = await h.engine.readState(created.chatId);
    expect(after.nodeId, before.nodeId);
    expect(after.values, before.values);
    expect(after.changes, before.changes);
    expect(after.effects, before.effects);
    expect(_pending(await _saved(h.engine, created.chatId)), pending);
    final afterRows = _rows(h);
    for (final table in ['nodes', 'node_states', 'agent_runs']) {
      expect(afterRows[table], rows[table], reason: table);
    }
  });

  for (final badRuntime in <({String name, Object? value})>[
    (name: 'null', value: null),
    (name: 'future version', value: {'version': 2, 'vendor': 'kept'}),
    (name: 'bad once ledger', value: {'version': 1, 'firedRules': null}),
    (
      name: 'duplicate pending ids',
      value: {
        'version': 1,
        'pendingPrompts': [
          {'id': 'same', 'text': 'one'},
          {'id': 'same', 'text': 'two'},
        ],
      },
    ),
    (
      name: 'bad pending text',
      value: {
        'version': 1,
        'pendingPrompts': [
          {'id': 'one', 'text': 5},
        ],
      },
    ),
  ]) {
    test(
      'malformed runtime ${badRuntime.name} remains untouched across two replies and cannot rerun once rules',
      () async {
        final h = await T24Harness.open(thinking: false);
        addTearDown(h.dispose);
        final created = await _stateChat(
          h,
          definition: _definition(
            rules: [
              {
                'id': 'never-rerun',
                'when': true,
                'once': true,
                'do': [
                  {'type': 'notice', 'text': 'must not fire'},
                ],
              },
            ],
          ),
        );
        final saved = await _saved(h.engine, created.chatId);
        saved['dshgoStateRuntime'] = badRuntime.value;
        final imported = await _importSaved(h, created.characterId, saved);
        final initial = await h.engine.readState(imported);
        expect(initial.issues, isNotEmpty);
        for (var attempt = 0; attempt < 2; attempt++) {
          await _reply(
            h,
            imported,
            ops: [
              {'op': 'set', 'path': '/count', 'value': 4},
            ],
          );
          expect(_maps(h.model.allCalls.last.body!['tools']).map((tool) => _map(tool['function'])['name']), ['roll']);
          expect(_count(await h.engine.readState(imported)), 0);
          expect((await h.engine.readState(imported)).effects, isEmpty);
          expect((await _saved(h.engine, imported))['dshgoStateRuntime'], badRuntime.value);
        }
        final rejected = await h.engine.setStateValue(imported, '/count', 1);
        expect(rejected.applied, isFalse);
        expect((await _saved(h.engine, imported))['dshgoStateRuntime'], badRuntime.value);
        final runs = await h.engine.readAgentRuns(imported);
        final stateRuns = runs.where((run) => run.kind != 'tool.turn').toList();
        expect(stateRuns, hasLength(3));
        expect(stateRuns.every((run) => run.result['committed'] == false), isTrue);
        expect(runs.where((run) => run.kind == 'tool.turn'), hasLength(2));
      },
    );
  }

  test('JSONL round trips both swipe states own changes once ledgers and opaque message-variable neighbors', () async {
    final h = await T24Harness.open(thinking: false);
    addTearDown(h.dispose);
    final created = await _stateChat(
      h,
      definition: _definition(
        rules: [
          {
            'id': 'branch-once',
            'when': {
              '>': [
                {'var': 'count'},
                0,
              ],
            },
            'once': true,
            'do': [
              {'type': 'prompt', 'text': 'branch prompt'},
            ],
          },
        ],
      ),
    );
    final initial = await _saved(h.engine, created.chatId);
    _map(initial['messageVariables'])['stat_data'] = {
      'external': [null, 7],
    };
    initial['vendorState'] = {'opaque': true};
    await _replaceSaved(h, created.chatId, initial);
    final first = await _reply(
      h,
      created.chatId,
      text: 'branch 2',
      ops: [
        {'op': 'set', 'path': '/count', 'value': 2},
      ],
    );
    await _regenerate(h, created.chatId, first.nodeId, count: 4);
    final before = await h.engine.readState(created.chatId);
    final selectedSaved = await _saved(h.engine, created.chatId);
    final files = await h.engine.exportChat(created.chatId);
    final imported = (await h.engine.importChats(created.characterId, files)).chatIds.single;
    final copied = await h.engine.readState(imported);
    expect(_count(copied), 4);
    expect(copied.changes, before.changes);
    expect(copied.effects, before.effects);
    final savedCopy = await _saved(h.engine, imported);
    expect(savedCopy['dshgoStateRuntime'], selectedSaved['dshgoStateRuntime']);
    expect(_map(savedCopy['messageVariables'])['stat_data'], {
      'external': [null, 7],
    });
    expect(savedCopy['vendorState'], {'opaque': true});
    expect(await h.engine.readAgentRuns(imported), isEmpty);
    final selected = (await h.engine.path(imported)).last;
    expect(selected.siblingCount, 2);
    await h.engine.selectSibling(imported, selected.nodeId, 0);
    final old = await h.engine.readState(imported);
    expect(_count(old), 2);
    expect(old.changes.single['new'], 2);
    expect(_map((await _saved(h.engine, imported))['dshgoStateRuntime'])['firedRules'], ['id:branch-once']);
    await h.reopen();
    expect(_count(await h.engine.readState(imported)), 2);
    expect(await h.engine.readAgentRuns(imported), isEmpty);
  });

  test('a complete backup restores state audit rows and pending prompts in a different directory', () async {
    final h = await T24Harness.open(thinking: false);
    addTearDown(h.dispose);
    final work = await Directory.systemTemp.createTemp('dsh-t17-state-backup-');
    TavernEngine? restored;
    addTearDown(() async {
      await restored?.close();
      await work.delete(recursive: true);
    });
    final created = await _stateChat(h, definition: _definition(rules: _promptRules()));
    await h.engine.setStateValue(created.chatId, '/count', 1);
    final before = await h.engine.readState(created.chatId);
    final runs = await h.engine.readAgentRuns(created.chatId);
    final saved = await _saved(h.engine, created.chatId);
    expect(runs, hasLength(1));
    expect(_pending(saved), hasLength(1));
    final archive = File('${work.path}/state.zip');
    await h.engine.backup(archive.path);
    final target = Directory('${work.path}/restored');
    await restoreTavernDirectory(archive.path, target.path);
    final engine = restored = await TavernEngine.openDirectory(target);
    final copied = await engine.readState(created.chatId);
    expect(copied.nodeId, before.nodeId);
    expect(copied.values, before.values);
    expect(copied.changes, before.changes);
    expect(copied.effects, before.effects);
    expect(_pending(await _saved(engine, created.chatId)), _pending(saved));
    final copiedRuns = await engine.readAgentRuns(created.chatId);
    expect(copiedRuns, hasLength(runs.length));
    expect(copiedRuns.single.id, runs.single.id);
    expect(copiedRuns.single.nodeId, runs.single.nodeId);
    expect(copiedRuns.single.result, runs.single.result);
  });
}

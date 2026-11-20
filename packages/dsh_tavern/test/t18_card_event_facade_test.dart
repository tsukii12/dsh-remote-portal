import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import 'support/t24_engine_harness.dart';

// Real facade, character files, branch state, SQLite, assembly and tool
// accumulator. Only provider deltas, clock and random are controlled.
typedef _Json = Map<String, Object?>;
typedef _Chat = ({String characterId, String chatId});
typedef _Active = ({T24Call call, T24Events events});
typedef _DirectorActive = ({T24Call call, Future<TavernDirectorRun> result});

const _literal = 'EVENT-PROMPT-{{incvar::eventMustStayLiteral}}{{getglobalvar::eventSecret}}';
const _beat = 'EVENT-HELPER-BEAT';

_Json _map(Object? value) => value! as _Json;
List<_Json> _maps(Object? value) => (value! as List<Object?>).map(_map).toList();
List<_Json> _rowsOrEmpty(Object? value) => value is List<Object?> ? value.map(_map).toList() : [];

_Json _handler(
  String id,
  List<_Json> actions, {
  String name = 'fixed',
  Object? when = true,
  bool once = false,
  List<_Json>? expectState,
}) => {'id': id, 'name': name, 'when': when, 'do': actions, 'once': once, 'expect': ?expectState};

_Json _state({List<Object?> rules = const [], int step = 100}) => {
  'schema': {
    'type': 'object',
    'additionalProperties': false,
    'required': ['count'],
    'properties': {
      'count': {'type': 'integer', 'minimum': 0, 'maximum': 100, 'x-dsh-step': step},
    },
  },
  'init': {'count': 0},
  'rules': rules,
};

_Json _increment() => {
  'type': 'state',
  'ops': [
    {'op': 'add', 'path': '/count', 'value': 1, 'why': 'fixed card action'},
  ],
};

Future<T24Harness> _open({bool thinking = false}) async {
  final h = await T24Harness.open(thinking: thinking);
  addTearDown(h.dispose);
  return h;
}

Future<_Chat> _chat(T24Harness h, {required List<_Json> handlers, _Json? state, _Json? story}) async {
  final raw = _map(jsonDecode(utf8.decode(t24Card())));
  _map(raw['data'])['extensions'] = {
    'dshgo': {
      'v': 1,
      'director': {
        'eventRules': {'v': 1, 'rules': handlers},
      },
      'state': ?state,
      'story': ?story,
    },
  };
  final card = await h.engine.importCard(Uint8List.fromList(utf8.encode(jsonEncode(raw))));
  return (characterId: card.id, chatId: await h.engine.createChat(card.id));
}

Future<void> _enable(T24Harness h, [bool enabled = true]) => h.engine.setSettings({
  'director': {'enabled': enabled, 'every': 1000},
});

_Json _output({List<_Json>? events}) => {
  'notes': 'PRIVATE-EVENT-NOTES',
  'beat': _beat,
  'prefetch': <Object?>[],
  'suggestions': [
    for (var i = 0; i < 3; i++) {'text': 'choice-$i', 'risk': ''},
  ],
  'events':
      events ??
      [
        {'name': 'fixed', 'data': 'proposal text'},
      ],
};

Future<_DirectorActive> _startDirector(T24Harness h, String chat) async {
  final call = h.model.prepare();
  final result = h.engine.runDirector(chat);
  await Future.any<void>([
    call.listening.future,
    result.then<void>((value) {
      throw TestFailure('Director ended before its request: ${value.failure}');
    }),
  ]);
  return (call: call, result: result);
}

Future<TavernDirectorRun> _finishDirector(_DirectorActive active, {List<_Json>? events}) async {
  active.call.add(
    ModelToolFragment(
      index: 0,
      id: 'direct-event-call',
      type: 'function',
      name: 'direct',
      arguments: jsonEncode(_output(events: events)),
    ),
  );
  await active.call.finish('tool_calls');
  final result = await active.result;
  expect(result.success, isTrue, reason: result.failure);
  return result;
}

Future<TavernDirectorRun> _direct(T24Harness h, String chat, {List<_Json>? events}) async =>
    _finishDirector(await _startDirector(h, chat), events: events);

Future<_Active> _startMain(T24Harness h, Stream<TavernEvent> stream) async {
  final call = h.model.prepare();
  final events = T24Events(stream);
  await Future.any<void>([
    call.listening.future,
    events.done.future.then<void>((_) {
      throw TestFailure('Main turn ended before its request: ${events.values}');
    }),
  ]);
  return (call: call, events: events);
}

Future<void> _finishMain(_Active active, {String text = 'main body', String? reason = 'stop', List<_Json>? ops}) async {
  if (text.isNotEmpty) {
    active.call.add(ModelText(text));
  }
  if (ops != null) {
    final names = _rowsOrEmpty(active.call.body!['tools']).map((tool) => _map(tool['function'])['name']);
    expect(names, contains('update_state'), reason: 'Never fabricate an unsolicited state tool call.');
    active.call.add(
      ModelToolFragment(
        index: 0,
        id: 'event-state-call',
        type: 'function',
        name: 'update_state',
        arguments: jsonEncode({
          'ops': [
            for (final op in ops) {'why': 'event facade fixture', ...op},
          ],
        }),
      ),
    );
  }
  active.call.add(ModelFinished(reason));
  await active.call.close();
  await active.events.done.future;
}

TavernMessage _success(_Active active) {
  expect(active.events.values.whereType<TavernTurnFailed>(), isEmpty);
  return active.events.values.whereType<TavernTurnDone>().single.message;
}

Future<({T24Call call, TavernMessage message})> _reply(
  T24Harness h,
  String chat, {
  String text = 'main body',
  String? reason = 'stop',
  List<_Json>? ops,
}) async {
  final active = await _startMain(h, h.engine.send(chat, ''));
  await _finishMain(active, text: text, reason: reason, ops: ops);
  return (call: active.call, message: _success(active));
}

String _requestText(T24Call call) =>
    _maps(call.body!['messages']).map((message) => message['content']).whereType<String>().join('\n');

Future<_Json> _view(T24Harness h, String chat) async => (await h.engine.readDirector(chat)).eventRules!;
Future<num> _count(T24Harness h, String chat) async => _map((await h.engine.readState(chat)).values)['count']! as num;

T _db<T>(T24Harness h, T Function(Database) action) {
  final database = sqlite3.open('${h.root.path}/tavern.sqlite3');
  try {
    return action(database);
  } finally {
    database.close();
  }
}

_Json _tables(T24Harness h) => _db(
  h,
  (database) => {
    for (final table in ['chats', 'nodes', 'node_states', 'agent_runs'])
      table: [for (final row in database.select('SELECT * FROM $table ORDER BY rowid')) Map<String, Object?>.from(row)],
  },
);

_Json _runRaw(T24Harness h, String id) => _db(
  h,
  (database) => _map(
    jsonDecode(
      database.select('SELECT result_json FROM agent_runs WHERE id = ?', [id]).single['result_json']! as String,
    ),
  ),
);

void _rewriteRun(T24Harness h, String id, void Function(_Json) mutate) {
  final raw = _runRaw(h, id);
  mutate(raw);
  _db(h, (database) => database.execute('UPDATE agent_runs SET result_json = ? WHERE id = ?', [jsonEncode(raw), id]));
}

Future<List<TavernAgentRun>> _applyRuns(T24Harness h, String chat) async =>
    (await h.engine.readAgentRuns(chat, limit: 1000)).where((run) => run.kind == 'director.event_apply').toList();

Future<_Json> _saved(TavernEngine engine, String chat) async {
  final files = await engine.exportChat(chat);
  final document = StChatDocument.decode(files.first.fileName, files.first.bytes);
  final saved = _map(_map(_map(document.messages.last['extra'])['dshgo'])['tavernState']);
  // The document is deeply read-only; mutation fixtures need detached JSON.
  return _map(jsonDecode(jsonEncode(saved)));
}

List<_Json> _pending(_Json saved) {
  final runtime = saved['dshgoDirectorEventRuntime'];
  return runtime is _Json ? _rowsOrEmpty(runtime['pendingPrompts']) : [];
}

Future<void> _replaceSaved(T24Harness h, String chat, _Json saved) async {
  final leaf = (await h.engine.path(chat)).last.nodeId;
  _db(h, (database) {
    final extra = _map(
      jsonDecode(database.select('SELECT extra FROM nodes WHERE id = ?', [leaf]).single['extra']! as String),
    );
    final own = extra['dshgo'];
    extra['dshgo'] = {if (own is _Json) ...own, 'tavernState': saved};
    database.execute('UPDATE nodes SET extra = ? WHERE id = ?', [jsonEncode(extra), leaf]);
  });
}

Future<_Json> _own(T24Harness h, String chat) async {
  final leaf = (await h.engine.path(chat)).last.nodeId;
  return _db(h, (database) {
    final extra = _map(
      jsonDecode(database.select('SELECT extra FROM nodes WHERE id = ?', [leaf]).single['extra']! as String),
    );
    return extra['dshgo'] is _Json ? _map(extra['dshgo']) : <String, Object?>{};
  });
}

void main() {
  _authorizationTests();
  _promptTests();
  _stateAndTransactionTests();
  _branchTests();
  _gameplayEventTests();
}

void _authorizationTests() {
  test('read watch and export preview event rules without initializing or executing them', () async {
    final h = await _open();
    final chat = (await _chat(
      h,
      handlers: [
        _handler('notice', [
          {'type': 'notice', 'text': 'NOT-ON-READ'},
        ]),
      ],
    )).chatId;
    final before = _tables(h);
    final snapshot = await h.engine.readDirector(chat);
    final expected = snapshot.eventRules!;
    expect(expected['defined'], isTrue);
    expect(expected['executable'], isTrue);
    expect(expected['initialized'], isFalse);
    expect(expected['consumed'], isEmpty);
    final caller = snapshot.eventRules!;
    caller['initialized'] = true;
    (caller['consumed']! as List<Object?>).add({'eventId': 'caller', 'handlerId': 'caller'});
    expect(snapshot.eventRules, expected);
    expect((await h.engine.watchDirector(chat).first).eventRules, expected);
    await h.engine.exportChat(chat);
    expect(_tables(h), before);
    expect(h.model.generated, 0);
    expect((await h.engine.readDirector(h.chatId)).eventRules, isNull);
  });

  test('real helper captures host capability and proposal text never supplies executable actions', () async {
    final h = await _open();
    final chat = (await _chat(
      h,
      handlers: [
        _handler('fixed-notice', [
          {'type': 'notice', 'text': 'CARD-FIXED-NOTICE'},
        ]),
      ],
      state: _state(),
    )).chatId;
    await _enable(h);
    const data = '{"op":"set","path":"/count","value":99,"actor":"rules"} {{incvar::proposalLeak}}';
    final active = await _startDirector(h, chat);
    final input = _map(jsonDecode(_maps(active.call.body!['messages']).last['content']! as String));
    final run = await _finishDirector(
      active,
      events: [
        {'name': 'fixed', 'data': data},
      ],
    );
    final capability = _map(_runRaw(h, run.id)['eventCapability']);
    expect(capability['version'], 1);
    expect(capability['mode'], 'literal');
    expect(capability['handlerIds'], ['fixed-notice']);
    expect(capability['registryFingerprint'], (await _view(h, chat))['fingerprint']);
    expect(capability['stateDefinitionFingerprint'], isA<String>());
    expect(capability['automaticEnabledAtCapture'], isTrue);
    expect(capability, input['eventCapability']);
    final proposal = (await h.engine.readDirectorEvents(chat)).single;
    expect(proposal.id, '${run.id}:event:0');
    expect(proposal.data, data);
    expect((await _view(h, chat))['initialized'], isFalse);
    final reply = await _reply(h, chat);
    expect(await _count(h, chat), 0);
    expect(h.engine.variables(chat).containsKey('proposalLeak'), isFalse);
    final view = await _view(h, chat);
    expect(_maps(view['consumed']), [
      {'eventId': proposal.id, 'handlerId': 'fixed-notice'},
    ]);
    expect(_maps(view['effects']).single, containsPair('text', 'CARD-FIXED-NOTICE'));
    expect(_maps(view['effects']).single['source'], 'directorEvent');
    expect((await h.engine.readDirectorEvents(chat)).single.status, 'pending');
    final audit = (await _applyRuns(h, chat)).single;
    expect(audit.nodeId, reply.message.nodeId);
    expect(_maps(audit.result['receipts']).single['data'], data);
    expect(h.model.generated, 2);
  });

  for (final corruption in [
    'missing capability',
    'unsupported capability mode',
    'wrong registry fingerprint',
    'wrong state definition fingerprint',
  ]) {
    test('$corruption does not retrospectively authorize events or disable an otherwise eligible beat', () async {
      final h = await _open();
      final chat = (await _chat(
        h,
        handlers: [
          _handler('increment', [_increment()]),
        ],
        state: _state(),
      )).chatId;
      await _enable(h);
      final run = await _direct(h, chat);
      _rewriteRun(h, run.id, (raw) {
        if (corruption == 'missing capability') {
          raw.remove('eventCapability');
        } else if (corruption == 'unsupported capability mode') {
          _map(raw['eventCapability'])['mode'] = 'model-authorized';
        } else if (corruption == 'wrong registry fingerprint') {
          _map(raw['eventCapability'])['registryFingerprint'] = 'not-the-captured-registry';
        } else {
          _map(raw['eventCapability'])['stateDefinitionFingerprint'] = null;
        }
      });
      final reply = await _reply(h, chat);
      expect(_requestText(reply.call), contains(_beat));
      expect(await _count(h, chat), 0);
      expect((await _view(h, chat))['consumed'], isEmpty);
      expect((await h.engine.readDirectorEvents(chat)).single.status, 'pending');
    });
  }

  for (final corruption in ['missing proposal', 'mismatched proposal']) {
    test('$corruption cannot be reconstructed from the successful helper output', () async {
      final h = await _open();
      final chat = (await _chat(
        h,
        handlers: [
          _handler('increment', [_increment()]),
        ],
        state: _state(),
      )).chatId;
      await _enable(h);
      final run = await _direct(h, chat);
      final id = '${run.id}:event:0';
      if (corruption == 'missing proposal') {
        _db(h, (database) => database.execute('DELETE FROM agent_runs WHERE id = ?', [id]));
      } else {
        _rewriteRun(h, id, (raw) => raw['data'] = 'not the actual output data');
      }
      final reply = await _reply(h, chat);
      expect(_requestText(reply.call), contains(_beat));
      expect(await _count(h, chat), 0);
      expect((await _view(h, chat))['consumed'], isEmpty);
      expect((await h.engine.readDirector(chat)).latestSuccess!.events, hasLength(1));
      if (corruption == 'missing proposal') {
        expect(await h.engine.readDirectorEvents(chat), isEmpty);
      }
    });
  }

  test('editing a real source invalidates its event authorization before admission', () async {
    final h = await _open();
    final chat = (await _chat(
      h,
      handlers: [
        _handler('increment', [_increment()]),
      ],
      state: _state(),
    )).chatId;
    await _enable(h);
    final source = (await h.engine.path(chat)).single.nodeId;
    await _direct(h, chat);
    await h.engine.edit(chat, source, 'changed source');
    expect((await h.engine.readDirector(chat)).stale, isTrue);
    await _reply(h, chat);
    expect(await _count(h, chat), 0);
    expect((await _view(h, chat))['consumed'], isEmpty);
  });

  test('off-path proposals stay pending and become eligible again on their original branch', () async {
    final h = await _open();
    final chat = (await _chat(
      h,
      handlers: [
        _handler('increment', [_increment()]),
      ],
      state: _state(),
    )).chatId;
    await _enable(h);
    final root = (await h.engine.path(chat)).single.nodeId;
    final source = await h.engine.sendOnly(chat, 'branch A');
    final run = await _direct(h, chat);
    await h.engine.selectNode(chat, root);
    await h.engine.sendOnly(chat, 'branch B');
    await _reply(h, chat);
    expect(await _count(h, chat), 0);
    expect((await _view(h, chat))['consumed'], isEmpty);
    await h.engine.selectNode(chat, source.nodeId);
    await _reply(h, chat);
    expect(await _count(h, chat), 1);
    expect(_maps((await _view(h, chat))['consumed']).single['eventId'], '${run.id}:event:0');
  });

  test('a helper completing during a main turn cannot replace the captured event batch', () async {
    final h = await _open();
    final chat = (await _chat(
      h,
      handlers: [
        _handler('increment', [_increment()]),
      ],
      state: _state(),
    )).chatId;
    await _enable(h);
    final first = await _direct(
      h,
      chat,
      events: [
        {'name': 'fixed', 'data': 'captured A'},
      ],
    );
    final late = await _startDirector(h, chat);
    final active = await _startMain(h, h.engine.send(chat, ''));
    final second = await _finishDirector(
      late,
      events: [
        {'name': 'fixed', 'data': 'late B'},
      ],
    );
    await _finishMain(active);
    _success(active);
    expect(await _count(h, chat), 1);
    expect(_maps((await _view(h, chat))['consumed']), [
      {'eventId': '${first.id}:event:0', 'handlerId': 'increment'},
    ]);
    await _reply(h, chat);
    expect(await _count(h, chat), 2);
    expect(_maps((await _view(h, chat))['consumed']).map((row) => row['eventId']), [
      '${first.id}:event:0',
      '${second.id}:event:0',
    ]);
  });

  test('a turn admitted without success does not search for newly completed helper events at terminal', () async {
    final h = await _open();
    final chat = (await _chat(
      h,
      handlers: [
        _handler('increment', [_increment()]),
      ],
      state: _state(),
    )).chatId;
    await _enable(h);
    final late = await _startDirector(h, chat);
    final active = await _startMain(h, h.engine.send(chat, ''));
    final run = await _finishDirector(late);
    await _finishMain(active);
    _success(active);
    expect(await _count(h, chat), 0);
    expect((await _view(h, chat))['consumed'], isEmpty);
    await _reply(h, chat);
    expect(await _count(h, chat), 1);
    expect(_maps((await _view(h, chat))['consumed']).single['eventId'], '${run.id}:event:0');
  });

  test('a changed story phase rejects an unconsumed old proposal even when its source body is unchanged', () async {
    final h = await _open();
    final chat = (await _chat(
      h,
      handlers: [
        _handler(
          'phase-bound',
          [
            {'type': 'notice', 'text': 'OLD-PHASE-ACTION'},
          ],
          when: {
            '==': [
              {'var': 'count'},
              1,
            ],
          },
        ),
      ],
      state: _state(),
      story: {
        'acts': [
          {'id': 'a', 'when': true},
          {'id': 'b', 'when': false},
        ],
      },
    )).chatId;
    await _enable(h);
    await _direct(h, chat);
    await _reply(h, chat);
    expect((await h.engine.readDirector(chat)).story!['currentActId'], 'b');
    expect((await h.engine.readDirector(chat)).stale, isTrue);
    await _reply(
      h,
      chat,
      ops: [
        {'op': 'set', 'path': '/count', 'value': 1},
      ],
    );
    expect(await _count(h, chat), 1);
    expect((await _view(h, chat))['consumed'], isEmpty);
    expect(_rowsOrEmpty((await _view(h, chat))['effects']), isEmpty);
  });

  test('watch exposes the committed event ledger and receipts through detached snapshots', () async {
    final h = await _open();
    final chat = (await _chat(
      h,
      handlers: [
        _handler('watched', [
          {'type': 'notice', 'text': 'WATCH-COMMITTED'},
        ]),
      ],
    )).chatId;
    await _enable(h);
    final first = Completer<void>();
    final applied = Completer<void>();
    final observations = <TavernDirectorSnapshot>[];
    final subscription = h.engine.watchDirector(chat).listen((snapshot) {
      observations.add(snapshot);
      if (!first.isCompleted) {
        first.complete();
      }
      if (_maps(snapshot.eventRules!['consumed']).isNotEmpty && !applied.isCompleted) {
        applied.complete();
      }
    });
    addTearDown(subscription.cancel);
    await first.future.timeout(const Duration(seconds: 5));
    final initial = observations.first.eventRules!;
    final run = await _direct(h, chat);
    await _reply(h, chat);
    await applied.future.timeout(const Duration(seconds: 5));
    final committed = observations.last.eventRules!;
    expect(_maps(committed['consumed']), [
      {'eventId': '${run.id}:event:0', 'handlerId': 'watched'},
    ]);
    _maps(committed['receipts']).single['data'] = 'caller mutation';
    _maps(committed['effects']).single['text'] = 'caller mutation';
    (committed['consumed']! as List<Object?>).clear();
    expect(observations.last.eventRules!['consumed'], isNotEmpty);
    expect(_maps(observations.last.eventRules!['effects']).single['text'], 'WATCH-COMMITTED');
    expect(observations.first.eventRules, initial);
    expect(initial['initialized'], isFalse);
  });
}

void _promptTests() {
  test('an imported queued prompt is confirmed without any saved director success or fresh proposal', () async {
    final h = await _open();
    final created = await _chat(
      h,
      handlers: [
        _handler('import-prompt', [
          {'type': 'prompt', 'text': _literal},
        ], once: true),
      ],
    );
    await _enable(h);
    await _direct(h, created.chatId);
    await _reply(h, created.chatId);
    final saved = await _saved(h.engine, created.chatId);
    final oldRuntime = _map(saved['dshgoDirectorEventRuntime']);
    final oldPrompt = _pending(saved).single;
    final files = await h.engine.exportChat(created.chatId);
    final imported = (await h.engine.importChats(created.characterId, files)).chatIds.single;
    expect(await h.engine.readAgentRuns(imported), isEmpty);
    expect((await h.engine.readDirector(imported)).latestSuccess, isNull);
    final main = await _reply(h, imported);
    expect(_requestText(main.call), contains(_literal));
    final after = _map((await _saved(h.engine, imported))['dshgoDirectorEventRuntime']);
    expect(after['consumed'], oldRuntime['consumed']);
    expect(after['firedHandlers'], oldRuntime['firedHandlers']);
    expect(after['pendingPrompts'], isEmpty);
    final audit = (await _applyRuns(h, imported)).single;
    expect(audit.result['committed'], isTrue);
    expect(audit.result['receipts'], isEmpty);
    expect(audit.result['effects'], isEmpty);
    expect(audit.result['pendingConsumed'], [oldPrompt['id']]);
    expect((await h.engine.readDirector(imported)).latestSuccess, isNull);
  });

  test('blank prompt sources do not borrow a neighboring nonempty message as delivery evidence', () async {
    final h = await _open();
    final chat = (await _chat(
      h,
      handlers: [
        _handler('mixed-prompts', [
          {'type': 'prompt', 'text': ''},
          {'type': 'prompt', 'text': ' \n '},
          {'type': 'prompt', 'text': 'VISIBLE-EVENT-PROMPT'},
        ]),
      ],
    )).chatId;
    await _enable(h);
    await _direct(h, chat);
    await _reply(h, chat);
    final pending = _pending(await _saved(h.engine, chat));
    expect(pending, hasLength(3));
    final visible = pending.singleWhere((row) => row['text'] == 'VISIBLE-EVENT-PROMPT');
    final main = await _reply(h, chat);
    expect(_requestText(main.call), contains('VISIBLE-EVENT-PROMPT'));
    final after = _pending(await _saved(h.engine, chat));
    expect(after.map((row) => row['id']), pending.where((row) => row['id'] != visible['id']).map((row) => row['id']));
    expect((await _applyRuns(h, chat)).first.result['pendingConsumed'], [visible['id']]);
  });

  test('without a schema conditions use null and a fixed prompt stays literal until the next actual request', () async {
    final h = await _open();
    final chat = (await _chat(
      h,
      handlers: [
        _handler(
          'no-schema',
          [
            {'type': 'prompt', 'text': _literal},
          ],
          when: {
            '===': [
              {'var': ''},
              null,
            ],
          },
        ),
      ],
    )).chatId;
    await h.engine.setGlobalVariables({'eventSecret': 'DO-NOT-READ-GLOBAL'});
    final local = await h.engine.setStateValue(chat, '/count', 99);
    expect(local.applied, isTrue);
    expect((await h.engine.readVariables(chat))['count'], 99);
    await _enable(h);
    final run = await _direct(h, chat);
    final first = await _reply(h, chat);
    expect(_requestText(first.call), isNot(contains('EVENT-PROMPT-')));
    final saved = await _saved(h.engine, chat);
    expect(saved.containsKey('dshgoStateRuntime'), isFalse);
    final prompt = _pending(saved).single;
    expect(prompt['text'], _literal);
    expect(prompt['eventId'], '${run.id}:event:0');
    expect(prompt['handlerId'], 'no-schema');
    expect(prompt['id'], isNot('no-schema'));
    final second = await _reply(h, chat);
    final text = _requestText(second.call);
    expect(_literal.allMatches(text), hasLength(1));
    expect(text, isNot(contains('DO-NOT-READ-GLOBAL')));
    expect(h.engine.variables(chat).containsKey('eventMustStayLiteral'), isFalse);
    expect(_pending(await _saved(h.engine, chat)), isEmpty);
    expect(_maps((await _view(h, chat))['consumed']), [
      {'eventId': '${run.id}:event:0', 'handlerId': 'no-schema'},
    ]);
  });

  test('combined state effects queue an event prompt once and keep it separate from the ordinary rule queue', () async {
    final h = await _open();
    final chat = (await _chat(
      h,
      handlers: [
        _handler('event-prompt', [
          {'type': 'prompt', 'text': _literal},
        ]),
      ],
      state: _state(
        rules: [
          {
            'id': 'ordinary-prompt',
            'when': true,
            'once': true,
            'do': [
              {'type': 'prompt', 'text': 'ORDINARY-PROMPT-{{incvar::ordinaryMustStayLiteral}}'},
            ],
          },
        ],
      ),
    )).chatId;
    await _enable(h);
    await _direct(h, chat);
    await _reply(h, chat);
    final saved = await _saved(h.engine, chat);
    final ordinary = _maps(_map(saved['dshgoStateRuntime'])['pendingPrompts']);
    final events = _pending(saved);
    expect(ordinary, hasLength(1));
    expect(ordinary.single['text'], startsWith('ORDINARY-PROMPT-'));
    expect(events, hasLength(1));
    expect(events.single['text'], _literal);
    expect(events.single['id'], isNot(ordinary.single['id']));
    final stateEffects = (await h.engine.readState(chat)).effects;
    expect(stateEffects.where((effect) => effect['source'] == 'directorEvent'), hasLength(1));
    final next = await _reply(h, chat);
    final text = _requestText(next.call);
    expect('EVENT-PROMPT-'.allMatches(text), hasLength(1));
    expect('ORDINARY-PROMPT-'.allMatches(text), hasLength(1));
    final after = await _saved(h.engine, chat);
    expect(_maps(_map(after['dshgoStateRuntime'])['pendingPrompts']), isEmpty);
    expect(_pending(after), isEmpty);
    expect(h.engine.variables(chat).containsKey('ordinaryMustStayLiteral'), isFalse);
    expect(h.engine.variables(chat).containsKey('eventMustStayLiteral'), isFalse);
  });

  test('closing director after a prompt was sent consumes that prompt but leaves the new handler pending', () async {
    final h = await _open();
    final chat = (await _chat(
      h,
      handlers: [
        _handler('prompt', [
          {'type': 'prompt', 'text': _literal},
        ]),
      ],
    )).chatId;
    await _enable(h);
    final first = await _direct(
      h,
      chat,
      events: [
        {'name': 'fixed', 'data': 'first'},
      ],
    );
    await _reply(h, chat);
    expect(_pending(await _saved(h.engine, chat)), hasLength(1));
    final second = await _direct(
      h,
      chat,
      events: [
        {'name': 'fixed', 'data': 'second'},
      ],
    );
    final active = await _startMain(h, h.engine.send(chat, ''));
    expect(_requestText(active.call), contains(_literal));
    await _enable(h, false);
    await _finishMain(active);
    _success(active);
    final saved = await _saved(h.engine, chat);
    expect(_pending(saved), isEmpty);
    expect(_maps(_map(saved['dshgoDirectorEventRuntime'])['consumed']), [
      {'eventId': '${first.id}:event:0', 'handlerId': 'prompt'},
    ]);
    await _enable(h);
    await _reply(h, chat);
    final after = await _saved(h.engine, chat);
    expect(_pending(after), hasLength(1));
    expect(_pending(after).single['eventId'], '${second.id}:event:0');
  });

  test('disabled admission does not offer queued prompts while a chat override can authorize their delivery', () async {
    final h = await _open();
    final chat = (await _chat(
      h,
      handlers: [
        _handler('prompt', [
          {'type': 'prompt', 'text': _literal},
        ]),
      ],
    )).chatId;
    await _enable(h);
    await _direct(h, chat);
    await _reply(h, chat);
    final pending = _pending(await _saved(h.engine, chat));
    await _enable(h, false);
    final disabled = await _reply(h, chat);
    expect(_requestText(disabled.call), isNot(contains('EVENT-PROMPT-')));
    expect(_pending(await _saved(h.engine, chat)), pending);
    await h.engine.setSettings({
      'director': {'enabled': true},
    }, chatId: chat);
    final overridden = await _reply(h, chat);
    expect(_requestText(overridden.call), contains(_literal));
    expect(_pending(await _saved(h.engine, chat)), isEmpty);
  });

  test('an event prompt excluded by the real context budget remains queued with its original identity', () async {
    final h = await _open();
    final large = 'EVENT-BUDGET-EXCLUDED-${List.filled(40000, 'x').join()}';
    final chat = (await _chat(
      h,
      handlers: [
        _handler('large', [
          {'type': 'prompt', 'text': large},
        ]),
      ],
    )).chatId;
    await _enable(h);
    await _direct(h, chat);
    await _reply(h, chat);
    final pending = _pending(await _saved(h.engine, chat));
    expect(pending.single['text'], large);
    final next = await _reply(h, chat);
    expect(_requestText(next.call), isNot(contains('EVENT-BUDGET-EXCLUDED-')));
    expect(_pending(await _saved(h.engine, chat)), pending);
  });

  for (final outcome in ['cancelled', 'length']) {
    test('$outcome retains actually sent event prompts and does not consume the newly captured proposal', () async {
      final h = await _open();
      final chat = (await _chat(
        h,
        handlers: [
          _handler('prompt', [
            {'type': 'prompt', 'text': _literal},
          ]),
        ],
      )).chatId;
      await _enable(h);
      await _direct(h, chat);
      await _reply(h, chat);
      final saved = await _saved(h.engine, chat);
      await _direct(
        h,
        chat,
        events: [
          {'name': 'fixed', 'data': 'still pending'},
        ],
      );
      final active = await _startMain(h, h.engine.send(chat, ''));
      expect(_requestText(active.call), contains(_literal));
      active.call.add(const ModelText('partial body'));
      if (outcome == 'cancelled') {
        h.engine.stop(chat);
        try {
          await active.events.done.future;
        } finally {
          await active.call.close();
        }
        expect(active.events.values.whereType<TavernTurnFailed>(), hasLength(1));
      } else {
        await _finishMain(active, text: '', reason: 'length');
        _success(active);
      }
      expect((await _saved(h.engine, chat))['dshgoDirectorEventRuntime'], saved['dshgoDirectorEventRuntime']);
      expect((await h.engine.path(chat)).last.text, 'partial body');
    });
  }

  test('manual messages and impersonation neither execute pending events nor consume their queued prompts', () async {
    final h = await _open();
    final chat = (await _chat(
      h,
      handlers: [
        _handler('prompt', [
          {'type': 'prompt', 'text': _literal},
        ]),
      ],
    )).chatId;
    await _enable(h);
    await _direct(h, chat);
    await _reply(h, chat);
    final saved = await _saved(h.engine, chat);
    await _direct(
      h,
      chat,
      events: [
        {'name': 'fixed', 'data': 'not for manual'},
      ],
    );
    await h.engine.sendOnly(chat, 'manual user');
    await h.engine.narrate(chat, 'manual narration');
    expect((await _saved(h.engine, chat))['dshgoDirectorEventRuntime'], saved['dshgoDirectorEventRuntime']);
    final before = _tables(h);
    final beforePath = await h.engine.path(chat);
    final active = await _startMain(h, h.engine.impersonate(chat));
    expect(_requestText(active.call), isNot(contains('EVENT-PROMPT-')));
    await _finishMain(active, text: 'suggested user text');
    _success(active);
    final after = _tables(h);
    for (final table in ['node_states', 'agent_runs']) {
      expect(after[table], before[table], reason: table);
    }
    expect(
      (await h.engine.path(chat)).map((message) => (message.nodeId, message.role, message.text)),
      beforePath.map((message) => (message.nodeId, message.role, message.text)),
    );
    expect((await _saved(h.engine, chat))['dshgoDirectorEventRuntime'], saved['dshgoDirectorEventRuntime']);
  });
}

void _stateAndTransactionTests() {
  for (final mode in ['thinking', 'continue prefill']) {
    test('$mode authorizes fixed rules state without offering a model state tool', () async {
      final h = await _open(thinking: mode == 'thinking');
      final chat = (await _chat(
        h,
        state: _state(),
        handlers: [
          _handler('rules-only', [_increment()]),
        ],
      )).chatId;
      await _enable(h);
      TavernMessage? target;
      if (mode == 'continue prefill') {
        target = (await _reply(h, chat, text: 'original prefix')).message;
      }
      final run = await _direct(h, chat);
      final active = await _startMain(
        h,
        target == null ? h.engine.send(chat, '') : h.engine.continueReply(chat, target.nodeId),
      );
      expect(_rowsOrEmpty(active.call.body!['tools']), isEmpty);
      if (mode == 'continue prefill') {
        expect(_maps(active.call.body!['messages']).any((row) => row['prefix'] == true), isTrue);
      }
      await _finishMain(active, text: ' fixed rules');
      _success(active);
      expect(await _count(h, chat), 1);
      expect(_maps((await _view(h, chat))['consumed']), [
        {'eventId': '${run.id}:event:0', 'handlerId': 'rules-only'},
      ]);
    });
  }

  test(
    'model ordinary rules handlers derive and story share the original step baseline and actor permissions',
    () async {
      final h = await _open();
      final state = <String, Object?>{
        'schema': {
          'type': 'object',
          'additionalProperties': false,
          'required': ['count', 'double', 'ready', 'revisited', 'locked'],
          'properties': {
            'count': {'type': 'integer', 'minimum': 0, 'maximum': 100, 'x-dsh-step': 2},
            'double': {
              'type': 'integer',
              'x-dsh-derive': {
                '*': [
                  {'var': 'count'},
                  2,
                ],
              },
            },
            'ready': {
              'type': 'boolean',
              'x-dsh-by': ['rules', 'user'],
            },
            'revisited': {
              'type': 'boolean',
              'x-dsh-by': ['rules', 'user'],
            },
            'locked': {
              'type': 'integer',
              'x-dsh-by': ['user'],
            },
          },
        },
        'init': {'count': 0, 'double': 0, 'ready': false, 'revisited': false, 'locked': 0},
        'rules': [
          {
            'id': 'ordinary-first',
            'when': {
              '==': [
                {'var': 'count'},
                1,
              ],
            },
            'do': [
              {
                'type': 'state',
                'ops': [
                  {'op': 'set', 'path': '/ready', 'value': true, 'why': 'ordinary ready'},
                ],
              },
            ],
          },
          {
            'id': 'not-revisited',
            'when': {
              '==': [
                {'var': 'count'},
                2,
              ],
            },
            'do': [
              {
                'type': 'state',
                'ops': [
                  {'op': 'set', 'path': '/revisited', 'value': true, 'why': 'must not revisit'},
                ],
              },
            ],
          },
        ],
      };
      final chat = (await _chat(
        h,
        state: state,
        handlers: [
          _handler(
            'after-ordinary',
            [
              {
                'type': 'state',
                'ops': [
                  {'op': 'add', 'path': '/count', 'value': 10, 'why': 'fixed event shared step'},
                  {'op': 'set', 'path': '/locked', 'value': 1, 'why': 'fixed event lacks permission'},
                ],
              },
            ],
            when: {
              'and': [
                {'var': 'ready'},
                {
                  '==': [
                    {'var': 'double'},
                    2,
                  ],
                },
              ],
            },
            expectState: [
              {'path': '/count', 'exists': true, 'value': 1},
              {'path': '/missing', 'exists': false},
            ],
          ),
          _handler(
            'after-derive',
            [
              {'type': 'notice', 'text': 'DERIVED-FOUR'},
            ],
            when: {
              '==': [
                {'var': 'double'},
                4,
              ],
            },
          ),
        ],
        story: {
          'acts': [
            {
              'id': 'a',
              'when': {
                '==': [
                  {'var': 'count'},
                  2,
                ],
              },
            },
            {'id': 'b', 'when': false},
          ],
          'endings': [
            {
              'id': 'event-final',
              'title': 'Final event state',
              'when': {
                '==': [
                  {'var': 'double'},
                  4,
                ],
              },
            },
          ],
        },
      )).chatId;
      await _enable(h);
      final run = await _direct(h, chat);
      await _reply(
        h,
        chat,
        text: '',
        reason: 'tool_calls',
        ops: [
          {'op': 'set', 'path': '/count', 'value': 1},
        ],
      );
      final values = _map((await h.engine.readState(chat)).values);
      expect(values, {'count': 2, 'double': 4, 'ready': true, 'revisited': false, 'locked': 0});
      final view = await _view(h, chat);
      expect(_maps(view['consumed']), [
        {'eventId': '${run.id}:event:0', 'handlerId': 'after-ordinary'},
        {'eventId': '${run.id}:event:0', 'handlerId': 'after-derive'},
      ]);
      expect(_maps(view['effects']).single['text'], 'DERIVED-FOUR');
      final story = (await h.engine.readDirector(chat)).story!;
      expect(story['currentActId'], 'b');
      expect(story['unlockedEndings'], ['event-final']);
      final changes = (await h.engine.readState(chat)).changes;
      expect(changes.where((change) => change['path'] == '/count').map((change) => change['actor']), contains('rules'));
      expect(await _applyRuns(h, chat), hasLength(1));
    },
  );

  test(
    'state-disabled mixed handlers stay wholly pending while an independent effects-only handler can consume',
    () async {
      final h = await _open();
      final chat = (await _chat(
        h,
        state: _state(),
        handlers: [
          _handler('mixed', [
            {'type': 'notice', 'text': 'MIXED-NOTICE'},
            _increment(),
          ]),
          _handler('effect-only', [
            {'type': 'notice', 'text': 'INDEPENDENT-NOTICE'},
          ]),
        ],
      )).chatId;
      await _enable(h);
      await h.engine.setSettings({'stateEnabled': false});
      final run = await _direct(h, chat);
      final first = await _reply(h, chat);
      expect(_maps(first.call.body!['tools']).map((tool) => _map(tool['function'])['name']), ['roll']);
      expect(await _count(h, chat), 0);
      final disabled = await _view(h, chat);
      expect(_maps(disabled['effects']).map((effect) => effect['text']), ['INDEPENDENT-NOTICE']);
      expect(_maps(disabled['consumed']), [
        {'eventId': '${run.id}:event:0', 'handlerId': 'effect-only'},
      ]);
      await h.engine.setSettings({'stateEnabled': true});
      await _reply(h, chat);
      expect(await _count(h, chat), 1);
      expect(_maps((await _view(h, chat))['effects']).map((effect) => effect['text']), ['MIXED-NOTICE']);
      expect(_maps((await _view(h, chat))['consumed']), hasLength(2));
    },
  );

  test('event state needs both the original session authorization and the terminal state switch', () async {
    final h = await _open();
    final chat = (await _chat(
      h,
      state: _state(),
      handlers: [
        _handler('increment', [_increment()]),
      ],
    )).chatId;
    await _enable(h);
    await _direct(h, chat);
    final revoked = await _startMain(h, h.engine.send(chat, ''));
    await h.engine.setSettings({'stateEnabled': false});
    await _finishMain(revoked);
    _success(revoked);
    expect(await _count(h, chat), 0);
    expect((await _view(h, chat))['consumed'], isEmpty);
    final notOriginallyAuthorized = await _startMain(h, h.engine.send(chat, ''));
    expect(_maps(notOriginallyAuthorized.call.body!['tools']).map((tool) => _map(tool['function'])['name']), ['roll']);
    await h.engine.setSettings({'stateEnabled': true});
    await _finishMain(notOriginallyAuthorized);
    _success(notOriginallyAuthorized);
    expect(await _count(h, chat), 0);
    expect((await _view(h, chat))['consumed'], isEmpty);
    await _reply(h, chat);
    expect(await _count(h, chat), 1);
  });

  test(
    'turning director on before normal terminal can admit its already captured batch without looking up a new one',
    () async {
      final h = await _open();
      final chat = (await _chat(
        h,
        handlers: [
          _handler('notice', [
            {'type': 'notice', 'text': 'ENABLED-AT-TERMINAL'},
          ]),
        ],
      )).chatId;
      await _enable(h, false);
      final run = await _direct(h, chat);
      expect(_map(_runRaw(h, run.id)['eventCapability'])['automaticEnabledAtCapture'], isFalse);
      final active = await _startMain(h, h.engine.send(chat, ''));
      await _enable(h);
      await _finishMain(active);
      _success(active);
      final view = await _view(h, chat);
      expect(_maps(view['consumed']), [
        {'eventId': '${run.id}:event:0', 'handlerId': 'notice'},
      ]);
      expect(_maps(view['effects']).single['text'], 'ENABLED-AT-TERMINAL');
    },
  );

  test('a future event ledger is preserved without discarding an independently valid model state candidate', () async {
    final h = await _open();
    final chat = (await _chat(
      h,
      state: _state(),
      handlers: [
        _handler('increment', [_increment()]),
      ],
    )).chatId;
    final saved = await _saved(h.engine, chat);
    final unsupported = <String, Object?>{
      'version': 99,
      'vendor': {
        'keep': [null, 'future'],
      },
    };
    saved['dshgoDirectorEventRuntime'] = unsupported;
    await _replaceSaved(h, chat, saved);
    await _enable(h);
    await _direct(h, chat);
    await _reply(
      h,
      chat,
      ops: [
        {'op': 'set', 'path': '/count', 'value': 1},
      ],
    );
    expect(await _count(h, chat), 1);
    expect((await _saved(h.engine, chat))['dshgoDirectorEventRuntime'], unsupported);
    final view = await _view(h, chat);
    expect(view['valid'], isFalse);
    expect(view['issues'], isNotEmpty);
    expect(_rowsOrEmpty(view['effects']), isEmpty);
  });

  test(
    'a real terminal audit failure rolls back event state story and queues and retains the prior continue own audit',
    () async {
      final h = await _open();
      await h.engine.setPreset(ChatPreset({...t24Preset().raw, 'continue_prefill': false}));
      final chat = (await _chat(
        h,
        state: _state(
          rules: [
            {
              'id': 'ordinary-on-two',
              'when': {
                '==': [
                  {'var': 'count'},
                  2,
                ],
              },
              'once': true,
              'do': [
                {'type': 'prompt', 'text': 'UNCOMMITTED-ORDINARY-PROMPT'},
              ],
            },
          ],
        ),
        handlers: [
          _handler('increment-and-prompt', [
            _increment(),
            {'type': 'prompt', 'text': _literal},
          ]),
        ],
        story: {
          'acts': [
            {
              'id': 'a',
              'when': {
                '>=': [
                  {'var': 'count'},
                  2,
                ],
              },
            },
            {'id': 'b', 'when': false},
          ],
        },
      )).chatId;
      await _enable(h);
      await _direct(h, chat);
      final first = await _reply(h, chat, text: 'original');
      final saved = await _saved(h.engine, chat);
      final own = await _own(h, chat);
      final oldEventAudit = <String, Object?>{
        for (final key in [
          'directorEventInvocation',
          'directorEventReceipts',
          'directorEventEffects',
          'directorEventIssues',
        ])
          key: own[key],
      };
      expect(oldEventAudit['directorEventInvocation'], isNotNull);
      expect(await _count(h, chat), 1);
      await _direct(
        h,
        chat,
        events: [
          {'name': 'fixed', 'data': 'new continue proposal'},
        ],
      );
      _db(
        h,
        (database) => database.execute(
          "CREATE TRIGGER reject_event_commit BEFORE INSERT ON agent_runs "
          r"WHEN NEW.kind = 'director.event_apply' AND json_extract(NEW.result_json, '$.committed') = 1 "
          "BEGIN SELECT RAISE(ABORT, 'controlled event audit rejection'); END",
        ),
      );
      try {
        final active = await _startMain(h, h.engine.continueReply(chat, first.message.nodeId));
        expect(_requestText(active.call), contains(_literal));
        await _finishMain(
          active,
          text: ' partial',
          ops: [
            {'op': 'set', 'path': '/count', 'value': 2},
          ],
        );
        expect(active.events.values.whereType<TavernTurnDone>(), isEmpty);
        expect(active.events.values.whereType<TavernTurnFailed>(), hasLength(1));
        expect((await h.engine.path(chat)).last.text, 'original partial');
        expect(await _count(h, chat), 1);
        final after = await _saved(h.engine, chat);
        for (final key in ['dshgoStateRuntime', 'dshgoDirectorEventRuntime', 'dshgoStoryRuntime']) {
          expect(after[key], saved[key], reason: key);
        }
        final newOwn = await _own(h, chat);
        expect({for (final key in oldEventAudit.keys) key: newOwn[key]}, oldEventAudit);
        expect((await _applyRuns(h, chat)).where((run) => run.result['committed'] == true), hasLength(1));
        expect((await h.engine.readDirector(chat)).story!['currentActId'], 'a');
      } finally {
        _db(h, (database) => database.execute('DROP TRIGGER reject_event_commit'));
      }
      await h.reopen();
      expect(await _count(h, chat), 1);
      expect((await _saved(h.engine, chat))['dshgoDirectorEventRuntime'], saved['dshgoDirectorEventRuntime']);
    },
  );
}

void _branchTests() {
  test(
    'pair consumption is inherited by continue but regeneration from its parent has an independent branch ledger',
    () async {
      final h = await _open();
      final chat = (await _chat(
        h,
        state: _state(),
        handlers: [
          _handler('increment', [_increment()]),
        ],
      )).chatId;
      await _enable(h);
      final run = await _direct(h, chat);
      final first = await _reply(h, chat, text: 'first');
      final original = (await _saved(h.engine, chat))['dshgoDirectorEventRuntime'];
      expect(await _count(h, chat), 1);
      final continued = await _startMain(h, h.engine.continueReply(chat, first.message.nodeId));
      await _finishMain(continued, text: ' continued');
      expect(_success(continued).nodeId, first.message.nodeId);
      expect(await _count(h, chat), 1);
      expect((await _saved(h.engine, chat))['dshgoDirectorEventRuntime'], original);
      final regenerated = await _startMain(h, h.engine.regenerate(chat, first.message.nodeId));
      await _finishMain(regenerated, text: 'independent sibling');
      final second = _success(regenerated);
      expect(second.nodeId, isNot(first.message.nodeId));
      expect(await _count(h, chat), 1);
      expect(_maps((await _view(h, chat))['consumed']), [
        {'eventId': '${run.id}:event:0', 'handlerId': 'increment'},
      ]);
      final secondAudit = (await _own(h, chat))['directorEventInvocation'];
      await h.engine.selectNode(chat, first.message.nodeId);
      expect(await _count(h, chat), 1);
      expect((await _own(h, chat))['directorEventInvocation'], isNot(secondAudit));
      await h.reopen();
      expect((await _saved(h.engine, chat))['dshgoDirectorEventRuntime'], original);
      expect((await h.engine.readDirectorEvents(chat)).single.status, 'pending');
    },
  );

  test(
    'portable branch state preserves once and unknown runtime fields across import and a fresh helper run',
    () async {
      final h = await _open();
      final created = await _chat(
        h,
        handlers: [
          _handler('portable-once', [
            {'type': 'prompt', 'text': _literal},
          ], once: true),
        ],
      );
      await _enable(h);
      await _direct(h, created.chatId);
      await _reply(h, created.chatId);
      final saved = await _saved(h.engine, created.chatId);
      final runtime = _map(saved['dshgoDirectorEventRuntime']);
      runtime['vendor'] = {
        'keep': [null, 'portable'],
      };
      await _replaceSaved(h, created.chatId, saved);
      final files = await h.engine.exportChat(created.chatId);
      final imported = (await h.engine.importChats(created.characterId, files)).chatIds.single;
      expect((await _saved(h.engine, imported))['dshgoDirectorEventRuntime'], runtime);
      final pending = _pending(await _saved(h.engine, imported));
      final run = await _direct(
        h,
        imported,
        events: [
          {'name': 'fixed', 'data': 'fresh event, stable once id'},
        ],
      );
      final main = await _reply(h, imported);
      expect(_requestText(main.call), contains(_literal));
      final after = _map((await _saved(h.engine, imported))['dshgoDirectorEventRuntime']);
      expect(after['vendor'], runtime['vendor']);
      expect(after['firedHandlers'], ['portable-once']);
      expect(after['consumed'], runtime['consumed']);
      expect(_maps(after['consumed']).any((row) => row['eventId'] == '${run.id}:event:0'), isFalse);
      expect(after['pendingPrompts'], isEmpty);
      expect(pending.single['id'], isNotNull);
      expect(_rowsOrEmpty((await _view(h, imported))['effects']), isEmpty);
      await h.reopen();
      expect((await _view(h, imported))['firedHandlers'], ['portable-once']);
    },
  );

  test(
    'backup restores branch ledger queued prompts proposal rows and event application audit without executing them',
    () async {
      final h = await _open();
      final work = await Directory.systemTemp.createTemp('dsh-t18-card-event-backup-');
      TavernEngine? restored;
      addTearDown(() async {
        await restored?.close();
        await work.delete(recursive: true);
      });
      final chat = (await _chat(
        h,
        handlers: [
          _handler('backup-once', [
            {'type': 'prompt', 'text': _literal},
          ], once: true),
        ],
      )).chatId;
      await _enable(h);
      await _direct(h, chat);
      await _reply(h, chat);
      final before = await _saved(h.engine, chat);
      final applies = await _applyRuns(h, chat);
      final proposals = await h.engine.readDirectorEvents(chat);
      expect(_pending(before), hasLength(1));
      final archive = File('${work.path}/events.zip');
      await h.engine.backup(archive.path);
      final target = Directory('${work.path}/restored');
      await restoreTavernDirectory(archive.path, target.path);
      final engine = restored = await TavernEngine.openDirectory(target);
      expect((await _saved(engine, chat))['dshgoDirectorEventRuntime'], before['dshgoDirectorEventRuntime']);
      final copied = (await engine.readAgentRuns(
        chat,
        limit: 1000,
      )).where((run) => run.kind == 'director.event_apply').toList();
      expect(copied.map((run) => run.id), applies.map((run) => run.id));
      expect(copied.map((run) => run.result), applies.map((run) => run.result));
      expect((await engine.readDirectorEvents(chat)).map((event) => event.id), proposals.map((event) => event.id));
      final view = (await engine.readDirector(chat)).eventRules!;
      expect(view['firedHandlers'], ['backup-once']);
      expect(_maps(view['pendingPrompts']), _pending(before));
    },
  );
}

Future<TavernPackVersionRef> _eventPack(
  T24Harness h, {
  required String packId,
  required String version,
  required List<_Json> handlers,
  bool withRule = false,
  List<_Json>? ruleActions,
  List<_Json> references = const [],
}) async {
  final manifest = <String, Object?>{
    'formatVersion': 1,
    'packId': packId,
    'packVersion': version,
    'resources': <Object?>[],
    if (references.isNotEmpty) 'references': references,
    'dshgo': {
      'v': 1,
      if (withRule)
        'state': {
          'rules': [
            {
              'id': 'shared',
              'when': true,
              'once': true,
              'do': ruleActions ?? [_increment()],
            },
          ],
        },
      'director': {
        'eventRules': {'v': 1, 'rules': handlers},
      },
    },
  };
  final bytes = Uint8List.fromList(utf8.encode(jsonEncode(manifest)));
  final archive = Archive()..addFile(ArchiveFile('pack.json', bytes.length, bytes));
  return (await h.engine.importGameplayPack(Uint8List.fromList(ZipEncoder().encode(archive)))).ref;
}

_Json _eventCapabilityFromCall(T24Call call) {
  final input = _map(jsonDecode(_maps(call.body!['messages']).last['content']! as String));
  return _map(input['eventCapability']);
}

String _packEventWire(_Json capability, String bindingId) =>
    _maps(capability['eventMap']).singleWhere((row) => _map(row['source'])['bindingId'] == bindingId)['wireName']!
        as String;

_Json _packEventBinding(_Json saved, String bindingId) =>
    _map(_map(_map(saved['dshgoPackRuntime'])['bindings'])[bindingId]);

void _gameplayEventTests() {
  test('pack event names and once domains remain separate in one real state settlement', () async {
    final h = await _open();
    final created = await _chat(
      h,
      state: _state(),
      handlers: [
        _handler('shared', [
          _increment(),
          {'type': 'prompt', 'text': 'LEGACY-EVENT-LITERAL'},
        ], once: true),
      ],
    );
    final ref = await _eventPack(
      h,
      packId: 'event-domains',
      version: 'one',
      withRule: true,
      handlers: [
        _handler('shared', [
          _increment(),
          {'type': 'prompt', 'text': _literal},
        ], once: true),
      ],
    );
    const scope = TavernPackScopeTarget(kind: TavernGameplayScope.global);
    final initial = await h.engine.readGameplayBindings(scope);
    final adopted = await h.engine.updateGameplayBindings(
      scope,
      expected: initial.token,
      operationId: 'two-event-bindings',
      edits: [
        TavernPackBindingCreate(clientKey: 'a', packRef: ref),
        TavernPackBindingCreate(clientKey: 'b', packRef: ref),
      ],
    );
    final a = adopted.createdBindings['a']!;
    final b = adopted.createdBindings['b']!;
    await _enable(h);
    final helper = await _startDirector(h, created.chatId);
    final capability = _eventCapabilityFromCall(helper.call);
    expect(capability['version'], 2);
    final aWire = _packEventWire(capability, a);
    final bWire = _packEventWire(capability, b);
    expect(aWire, isNot('fixed'));
    expect(bWire, isNot(anyOf('fixed', aWire)));
    expect(
      _maps(capability['eventMap']).singleWhere((row) => _map(row['source'])['kind'] == 'legacy')['wireName'],
      'fixed',
    );
    final run = await _finishDirector(
      helper,
      events: [
        {'name': 'fixed', 'data': 'legacy proposal'},
        {'name': aWire, 'data': 'only binding a'},
      ],
    );
    final proposal = _runRaw(h, '${run.id}:event:1');
    expect(proposal['name'], aWire);
    expect(_map(_map(proposal['eventTarget'])['source'])['bindingId'], a);
    expect(_map(proposal['eventTarget'])['name'], 'fixed');
    await _reply(h, created.chatId);
    expect(
      await _count(h, created.chatId),
      4,
      reason: 'Two distinct once rules and exactly the legacy/a handlers share the final state session.',
    );
    final first = await _saved(h.engine, created.chatId);
    final aRow = _packEventBinding(first, a);
    final bRow = _packEventBinding(first, b);
    expect(aRow['rules'], ['shared']);
    expect(bRow['rules'], ['shared']);
    expect(_map(aRow['events'])['once'], ['shared']);
    expect(_maps(_map(aRow['events'])['consumed']), [
      {'eventId': '${run.id}:event:1', 'handlerId': 'shared'},
    ]);
    expect(bRow.containsKey('events'), isFalse);
    expect(_maps(_map(aRow['events'])['pendingPrompts']).single['text'], _literal);
    expect(_pending(first).single['text'], 'LEGACY-EVENT-LITERAL');

    // Removing the current handler does not erase an already adopted prompt
    // from this still-active binding/epoch.
    final withoutHandler = await _eventPack(
      h,
      packId: 'event-domains',
      version: 'two',
      withRule: true,
      handlers: const [],
    );
    await h.engine.updateGameplayBindings(
      scope,
      expected: adopted.snapshot.token,
      operationId: 'remove-current-handler',
      edits: [TavernPackBindingSelectVersion(bindingId: a, packVersion: withoutHandler.packVersion)],
    );
    final next = await _reply(h, created.chatId);
    expect(_literal.allMatches(_requestText(next.call)), hasLength(1));
    expect('LEGACY-EVENT-LITERAL'.allMatches(_requestText(next.call)), hasLength(1));
    expect(h.engine.variables(created.chatId).containsKey('eventMustStayLiteral'), isFalse);
    expect(await _count(h, created.chatId), 4);
    final after = await _saved(h.engine, created.chatId);
    expect(_maps(_map(_packEventBinding(after, a)['events'])['pendingPrompts']), isEmpty);
    expect(_map(_packEventBinding(after, a)['events'])['consumed'], _map(aRow['events'])['consumed']);
    expect(_packEventBinding(after, b)['rules'], ['shared']);
    expect(_packEventBinding(after, b).containsKey('events'), isFalse);
    expect(_pending(after), isEmpty);
    final audit = (await _applyRuns(h, created.chatId)).first.result;
    expect(_maps(audit['packPendingConsumed']).single['source'], _map(proposal['eventTarget'])['source']);
    expect(
      _runRaw(h, '${run.id}:event:1'),
      proposal,
      reason: 'Consumption never rewrites the original durable proposal or its target.',
    );
  });

  test('version and explicit epoch changes do not re-sign an old pack wire proposal', () async {
    final h = await _open();
    final created = await _chat(h, state: _state(), handlers: const []);
    final firstRef = await _eventPack(
      h,
      packId: 'event-version',
      version: 'one',
      handlers: [
        _handler('shared', [
          _increment(),
          {'type': 'prompt', 'text': 'VERSION-ONE'},
        ], once: true),
      ],
    );
    const scope = TavernPackScopeTarget(kind: TavernGameplayScope.global);
    final initial = await h.engine.readGameplayBindings(scope);
    final createdBinding = await h.engine.updateGameplayBindings(
      scope,
      expected: initial.token,
      operationId: 'create-versioned-event',
      edits: [TavernPackBindingCreate(clientKey: 'event', packRef: firstRef)],
    );
    final binding = createdBinding.createdBindings['event']!;
    await _enable(h);
    final oldHelper = await _startDirector(h, created.chatId);
    final oldWire = _packEventWire(_eventCapabilityFromCall(oldHelper.call), binding);
    final oldRun = await _finishDirector(
      oldHelper,
      events: [
        {'name': oldWire, 'data': 'captured one'},
      ],
    );
    final oldProposal = _runRaw(h, '${oldRun.id}:event:0');
    final secondRef = await _eventPack(
      h,
      packId: 'event-version',
      version: 'two',
      handlers: [
        _handler('shared', [
          _increment(),
          {'type': 'prompt', 'text': 'VERSION-TWO'},
        ], once: true),
      ],
    );
    final upgraded = await h.engine.updateGameplayBindings(
      scope,
      expected: createdBinding.snapshot.token,
      operationId: 'select-event-two',
      edits: [TavernPackBindingSelectVersion(bindingId: binding, packVersion: secondRef.packVersion)],
    );
    final stale = await _reply(h, created.chatId);
    expect(_requestText(stale.call), isNot(contains('VERSION-ONE')));
    expect(await _count(h, created.chatId), 0);
    final staleSaved = await _saved(h.engine, created.chatId);
    final stalePack = staleSaved['dshgoPackRuntime'];
    expect(stalePack is _Json && _map(stalePack['bindings']).containsKey(binding), isFalse);

    final freshHelper = await _startDirector(h, created.chatId);
    final freshWire = _packEventWire(_eventCapabilityFromCall(freshHelper.call), binding);
    expect(freshWire, oldWire, reason: 'Version changes capability, not the stable local event name.');
    final freshRun = await _finishDirector(
      freshHelper,
      events: [
        {'name': freshWire, 'data': 'captured two'},
      ],
    );
    await _reply(h, created.chatId);
    expect(await _count(h, created.chatId), 1);
    final beforeReset = _packEventBinding(await _saved(h.engine, created.chatId), binding);
    expect(beforeReset['onceEpoch'], 1);
    expect(_maps(_map(beforeReset['events'])['pendingPrompts']).single['text'], 'VERSION-TWO');

    await h.engine.updateGameplayBindings(
      scope,
      expected: upgraded.snapshot.token,
      operationId: 'reset-event-once',
      edits: [TavernPackBindingResetOnce(bindingId: binding)],
    );
    final resetReply = await _reply(h, created.chatId);
    expect(_requestText(resetReply.call), isNot(contains('VERSION-TWO')));
    expect(await _count(h, created.chatId), 1);
    expect(
      _packEventBinding(await _saved(h.engine, created.chatId), binding),
      beforeReset,
      reason: 'The old epoch is preserved until an action in the explicit new epoch is accepted.',
    );
    final resetHelper = await _startDirector(h, created.chatId);
    final resetCapability = _eventCapabilityFromCall(resetHelper.call);
    final resetWire = _packEventWire(resetCapability, binding);
    expect(resetWire, isNot(freshWire));
    final resetRun = await _finishDirector(
      resetHelper,
      events: [
        {'name': resetWire, 'data': 'new epoch'},
      ],
    );
    await _reply(h, created.chatId);
    expect(await _count(h, created.chatId), 2);
    final resetRow = _packEventBinding(await _saved(h.engine, created.chatId), binding);
    expect(resetRow['onceEpoch'], 2);
    expect(_map(resetRow['events'])['once'], ['shared']);
    expect(_maps(_map(resetRow['events'])['consumed']), [
      {'eventId': '${resetRun.id}:event:0', 'handlerId': 'shared'},
    ]);
    expect(_runRaw(h, '${oldRun.id}:event:0'), oldProposal);
    expect(_map(_map(_runRaw(h, '${freshRun.id}:event:0')['eventTarget'])['source'])['onceEpoch'], 1);
    expect(_map(_map(_runRaw(h, '${resetRun.id}:event:0')['eventTarget'])['source'])['onceEpoch'], 2);
  });

  test('a host director proposal retains its definition identity for a nonhost group continuation', () async {
    final h = await _open();
    Future<String> card(String name, int initial) async {
      final raw = _map(jsonDecode(utf8.decode(t24Card())));
      final data = _map(raw['data']);
      data['name'] = name;
      data['first_mes'] = '$name greeting';
      data['extensions'] = {
        'dshgo': {
          'v': 1,
          'state': {
            ..._state(),
            'init': {'count': initial},
          },
          'director': {'every': 1000},
        },
      };
      return (await h.engine.importCard(Uint8List.fromList(utf8.encode(jsonEncode(raw))))).id;
    }

    final host = await card('Definition host', 0);
    final actor = await card('Actual speaker', 91);
    final chat = await h.engine.createGroupChat([actor], hostCharacterId: host);
    final greeting = (await h.engine.path(chat)).single;
    expect(greeting.speakerCharacterId, actor);
    expect(await _count(h, chat), 0);
    final ref = await _eventPack(
      h,
      packId: 'group-definition',
      version: 'one',
      handlers: [
        _handler('group-handler', [_increment()], once: true),
      ],
    );
    const scope = TavernPackScopeTarget(kind: TavernGameplayScope.global);
    final initial = await h.engine.readGameplayBindings(scope);
    final adopted = await h.engine.updateGameplayBindings(
      scope,
      expected: initial.token,
      operationId: 'group-event-definition',
      edits: [TavernPackBindingCreate(clientKey: 'group', packRef: ref)],
    );
    final binding = adopted.createdBindings['group']!;
    final hostView = await h.engine.resolveGameplayConfig(TavernGameplayContext(characterId: host, chatId: chat));
    final actorView = await h.engine.resolveGameplayConfig(
      TavernGameplayContext(characterId: actor, chatId: chat),
      validateCurrentState: true,
    );
    expect(actorView.effectiveConfigId, hostView.effectiveConfigId);
    expect(
      actorView.sources.singleWhere((source) => source['kind'] == 'card' && source['characterId'] == actor)['roles'],
      contains('actor'),
    );
    expect(
      hostView.sources.singleWhere((source) => source['kind'] == 'card' && source['characterId'] == host)['roles'],
      contains('actor'),
    );

    await _enable(h);
    final helper = await _startDirector(h, chat);
    final capability = _eventCapabilityFromCall(helper.call);
    final wire = _packEventWire(capability, binding);
    final run = await _finishDirector(
      helper,
      events: [
        {'name': wire, 'data': 'host authorized'},
      ],
    );
    final continued = await _startMain(h, h.engine.continueReply(chat, greeting.nodeId));
    await _finishMain(continued, text: ' continued as actor');
    expect(_success(continued).nodeId, greeting.nodeId);
    expect((await h.engine.path(chat)).last.speakerCharacterId, actor);
    expect(
      await _count(h, chat),
      1,
      reason: 'The host proposal is executable under the identical host definition used by this actor.',
    );
    final saved = await _saved(h.engine, chat);
    expect(saved['dshgoPackDefinitionConfigId'], actorView.effectiveConfigId);
    expect(_maps(_map(_packEventBinding(saved, binding)['events'])['consumed']), [
      {'eventId': '${run.id}:event:0', 'handlerId': 'group-handler'},
    ]);
    expect((await h.engine.inspectTurn(chat))!.state['admissionConfigId'], actorView.effectiveConfigId);

    final regenerated = await _startMain(h, h.engine.regenerate(chat, greeting.nodeId));
    await _finishMain(regenerated, text: 'actor sibling');
    final sibling = _success(regenerated);
    expect(sibling.nodeId, isNot(greeting.nodeId));
    expect(sibling.speakerCharacterId, actor);
    expect((await h.engine.inspectTurn(chat))!.state['admissionConfigId'], actorView.effectiveConfigId);
  });

  test('enabling the first pack revokes an already admitted legacy response before state adoption', () async {
    final h = await _open();
    final created = await _chat(h, state: _state(), handlers: const []);
    final ref = await _eventPack(
      h,
      packId: 'first-pack-revocation',
      version: 'one',
      withRule: true,
      handlers: const [],
    );
    const scope = TavernPackScopeTarget(kind: TavernGameplayScope.global);
    final empty = await h.engine.readGameplayBindings(scope);
    final active = await _startMain(h, h.engine.send(created.chatId, ''));
    await h.engine.updateGameplayBindings(
      scope,
      expected: empty.token,
      operationId: 'enable-during-legacy-response',
      edits: [TavernPackBindingCreate(clientKey: 'first', packRef: ref)],
    );
    await _finishMain(
      active,
      text: 'body already received',
      ops: [
        {'op': 'set', 'path': '/count', 'value': 4},
      ],
    );
    expect(active.events.values.whereType<TavernTurnDone>(), isEmpty);
    expect(active.events.values.whereType<TavernTurnFailed>().single.kind, TavernFailure.cancelled);
    expect(await _count(h, created.chatId), 0);
    final saved = await _saved(h.engine, created.chatId);
    expect(saved.containsKey('dshgoPackDefinitionConfigId'), isFalse);
    expect(
      saved.containsKey('dshgoPackRuntime'),
      isFalse,
      reason: 'The failed old admission cannot consume the newly enabled rule.',
    );
  });

  test('malformed or ambiguous references at real event positions never fall back to an unqualified action', () async {
    final h = await _open();
    final created = await _chat(h, state: _state(), handlers: const []);
    const pointer = '/state/rules/0/do/1/name';
    final valid = <String, Object?>{'pointer': pointer, 'kind': 'event', 'source': 'self', 'localId': 'fixed'};
    final cases = <({String version, List<_Json> references, int count})>[
      (
        version: 'malformed',
        references: [
          {...valid, 'source': null},
        ],
        count: 0,
      ),
      (version: 'ambiguous', references: [valid, valid], count: 0),
      (
        version: 'opaque-position',
        references: [
          {...valid, 'pointer': '/unsupported/name'},
        ],
        count: 1,
      ),
    ];
    const scope = TavernPackScopeTarget(kind: TavernGameplayScope.global);
    var snapshot = await h.engine.readGameplayBindings(scope);
    String? binding;
    for (final item in cases) {
      final ref = await _eventPack(
        h,
        packId: 'reference-position',
        version: item.version,
        withRule: true,
        handlers: [_handler('vocabulary', const [])],
        ruleActions: [
          _increment(),
          {'type': 'event', 'name': 'fixed', 'data': null},
        ],
        references: item.references,
      );
      final receipt = await h.engine.updateGameplayBindings(
        scope,
        expected: snapshot.token,
        operationId: 'reference-${item.version}',
        edits: [
          if (binding == null)
            TavernPackBindingCreate(clientKey: 'rule', packRef: ref)
          else
            TavernPackBindingSelectVersion(bindingId: binding, packVersion: ref.packVersion),
        ],
      );
      binding ??= receipt.createdBindings['rule']!;
      snapshot = receipt.snapshot;
      final resolved = await h.engine.resolveGameplayConfig(
        TavernGameplayContext(characterId: created.characterId, chatId: created.chatId),
      );
      expect(resolved.conflicts.map((issue) => issue['code']), contains('unsupported_reference'));
      final references = _maps(resolved.definitions.singleWhere((row) => row['path'] == '/references')['items']);
      expect(references.any((row) => row['kind'] == 'event' && row['resolved'] == false), item.count == 0);
      await _reply(h, created.chatId);
      expect(await _count(h, created.chatId), item.count);
      final saved = await _saved(h.engine, created.chatId);
      if (item.count == 0) {
        expect(
          saved.containsKey('dshgoPackRuntime'),
          isFalse,
          reason: 'The unresolved supported action cannot execute or consume its once rule.',
        );
      } else {
        expect(_packEventBinding(saved, binding)['rules'], [
          'shared',
        ], reason: 'A declaration at an unsupported position is only diagnostic and cannot disable unrelated rules.');
      }
    }
  });
}

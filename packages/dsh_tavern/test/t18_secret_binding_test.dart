import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import 'support/t24_engine_harness.dart';

// Real facade, files, SQLite transactions and automatic helper jobs. The only
// provider replacement is the existing controlled delta stream. SQL triggers
// reject genuine product writes; late-admission fixtures move byte-identical
// rows produced by genuine helper jobs, never invent a capability or receipt.
typedef _Json = Map<String, Object?>;
typedef _Active = ({T24Call call, T24Events events});

const _deadline = Duration(seconds: 10);
const _fact = 'B: the sealed original alibi';
const _laterFact = 'P2: a distinct later proposal';
const _body = 'ORIGINAL REPLY';

_Json _map(Object? value) => value! as _Json;
List<_Json> _maps(Object? value) => (value! as List<Object?>).map(_map).toList();

_Json _definition() => {
  'schema': {
    'type': 'object',
    'additionalProperties': false,
    'required': ['entity', 'count', 'private'],
    'properties': {
      'entity': {'type': 'string'},
      'count': {'type': 'integer', 'minimum': 0, 'maximum': 100},
      'private': {
        'type': 'object',
        'additionalProperties': false,
        'required': ['fact'],
        'x-dsh-hidden': true,
        'x-dsh-by': ['rules', 'user'],
        'properties': {
          'fact': {
            'type': ['string', 'null'],
          },
        },
      },
    },
  },
  'init': {
    'entity': 'entity-one',
    'count': 0,
    'private': {'fact': null},
  },
  'rules': <Object?>[],
};

_Json _slots({bool release = false}) => {
  'v': 1,
  'slots': [
    {
      'id': 'alibi',
      'path': '/private/fact',
      'entityPath': '/entity',
      'unbound': {'exists': true, 'value': null},
      'bindWhen': true,
      'release': {'id': 'alibi-release', 'audience': 'currentCharacter', 'when': release, 'template': 'Fact: {{fact}}'},
    },
  ],
};

_Json _ordinaryOutput() => {
  'notes': 'ordinary fixture notes',
  'beat': 'ordinary fixture beat',
  'prefetch': <Object?>[],
  'suggestions': [
    for (var i = 0; i < 3; i++) {'text': 'choice-$i', 'risk': ''},
  ],
  'events': <Object?>[],
};

class _Fixture {
  _Fixture(this.h, this.characterId, this.chatId, this.sourceId);
  final _BindingHarness h;
  final String characterId;
  final String chatId;
  final String sourceId;
  late final TavernAgentRun proposal;
}

// The first test observes SQLite synchronously at generate() entry. Waiting
// only for stream onListen could miss an implementation that commits too late.
class _BindingModel extends T24Model {
  void Function()? atEntry;

  @override
  Stream<ModelDelta> generate({
    required TavernModelConfig config,
    required Map<String, Object?> body,
    required ModelCancellation cancellation,
    void Function(int attempt)? onRequestStarted,
  }) {
    atEntry?.call();
    return super.generate(config: config, body: body, cancellation: cancellation, onRequestStarted: onRequestStarted);
  }
}

class _BindingHarness {
  _BindingHarness(this.root, this.model, this.config, this.engine);
  final Directory root;
  final _BindingModel model;
  final TavernModelConfig config;
  TavernEngine engine;

  static Future<_BindingHarness> open() async {
    final root = await Directory.systemTemp.createTemp('dsh-t18-secret-binding-');
    final model = _BindingModel();
    final config = TavernModelConfig(
      apiKey: () async => 'fixture-key',
      model: 'fixture-model',
      deepseek: true,
      thinking: false,
    );
    final engine = await TavernEngine.openDirectory(
      root,
      config: config,
      modelClient: model,
      clock: () => T24Harness.at,
      random: () => 0.25,
    );
    return _BindingHarness(root, model, config, engine);
  }

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
      if (call.cancellation != null) {
        await call.close();
      } else {
        unawaited(call.close());
      }
    }
    if (await root.exists()) await root.delete(recursive: true);
  }
}

Future<void> _settings(_Fixture f, int every) => f.h.engine.setSettings({
  'director': {'enabled': true, 'secretsEnabled': true, 'every': every},
});

Future<_Fixture> _ready({bool release = false}) async {
  final h = await _BindingHarness.open();
  addTearDown(h.dispose);
  // A continuation must actually offer update_state in the terminal SQL case.
  await h.engine.setPreset(ChatPreset({...t24Preset().raw, 'continue_prefill': false}));
  final card = _map(jsonDecode(utf8.decode(t24Card())));
  _map(card['data'])['extensions'] = {
    'dshgo': {
      'v': 1,
      'state': _definition(),
      'director': {'secretSlots': _slots(release: release)},
    },
  };
  final character = await h.engine.importCard(Uint8List.fromList(utf8.encode(jsonEncode(card))));
  final value = _map(_definition()['init']);
  final saved = <String, Object?>{
    'variables': {'keptLocal': 7},
    'messageVariables': {
      'dshgo': value,
      'foreign': {
        'nested': [null, 'keep'],
      },
    },
    'dshgoStateRuntime': {'version': 1, 'firedRules': <Object?>[], 'pendingPrompts': <Object?>[]},
    'vendorState': {'keep': true},
  };
  final source = StChatDocument(
    fileName: 'secret-binding-source.jsonl',
    header: {
      'user_name': 'User',
      'character_name': 'Guide',
      'chat_metadata': {
        'variables': {'keptLocal': 7},
      },
    },
    messages: [
      {
        'name': 'Guide',
        'is_user': false,
        'is_system': false,
        'mes': _body,
        'send_date': T24Harness.at.toIso8601String(),
        'variables': [saved['messageVariables']],
        'extra': {
          'vendorExtra': {
            'nested': [false, 'keep'],
          },
          'dshgo': {
            'vendorOwn': {'keep': 19},
            'tavernState': saved,
          },
        },
      },
    ],
  );
  final chat = (await h.engine.importChats(character.id, [
    TavernChatFile(fileName: source.fileName, bytes: source.encode()),
  ])).chatIds.single;
  final node = (await h.engine.path(chat)).single;
  final f = _Fixture(h, character.id, chat, node.nodeId);
  f.proposal = await _proposeFromTick(f, _fact);
  await _settings(f, 1000);
  expect((await h.engine.path(chat)).single.text, _body);
  expect(_map((await h.engine.readState(chat)).values), value);
  expect(
    _saved(f).containsKey('dshgoSecretRuntime'),
    isFalse,
    reason: 'Publishing a real helper proposal must not bind it.',
  );
  expect(await _bindRuns(f), isEmpty);
  return f;
}

Future<_Active> _start(_Fixture f, Stream<TavernEvent> stream) async {
  final call = f.h.model.prepare();
  final events = T24Events(stream);
  await _listening(call, events);
  return (call: call, events: events);
}

Future<void> _listening(T24Call call, T24Events events) => Future.any<void>([
  call.listening.future,
  events.done.future.then<void>((_) {
    throw TestFailure('Main turn ended before its provider request: ${events.values}');
  }),
]).timeout(_deadline);

Future<void> _finish(_Active active, {String text = '', List<_Json>? ops}) async {
  if (text.isNotEmpty) active.call.add(ModelText(text));
  if (ops != null) {
    final tools = active.call.body!['tools'];
    expect(tools, isA<List<Object?>>());
    expect(_maps(tools).map((tool) => _map(tool['function'])['name']), contains('update_state'));
    active.call.add(
      ModelToolFragment(
        index: 0,
        id: 'binding-state-call',
        type: 'function',
        name: 'update_state',
        arguments: jsonEncode({
          'ops': [
            for (final op in ops) {'why': 'binding fixture', ...op},
          ],
        }),
      ),
    );
  }
  await active.call.finish(ops == null ? 'stop' : 'tool_calls');
  await active.events.done.future.timeout(_deadline);
}

TavernMessage _success(_Active active) {
  expect(active.events.values.whereType<TavernTurnFailed>(), isEmpty);
  return active.events.values.whereType<TavernTurnDone>().single.message;
}

Future<TavernTurnFailed> _failed(T24Events events) async {
  await events.done.future.timeout(_deadline);
  expect(events.values.whereType<TavernTurnDone>(), isEmpty);
  return events.values.whereType<TavernTurnFailed>().single;
}

Future<TavernAgentRun> _proposeFromTick(_Fixture f, String fact) async {
  await _settings(f, 1);
  final active = await _start(f, f.h.engine.continueReply(f.chatId, f.sourceId));
  final ordinary = f.h.model.prepare();
  final secret = f.h.model.prepare();
  await _finish(active);
  expect(_success(active).nodeId, f.sourceId);
  await ordinary.listening.future.timeout(_deadline);
  expect(_map(_map(ordinary.body!['tool_choice'])['function'])['name'], 'direct');
  ordinary.add(
    ModelToolFragment(
      index: 0,
      id: 'ordinary-before-secret',
      type: 'function',
      name: 'direct',
      arguments: jsonEncode(_ordinaryOutput()),
    ),
  );
  await ordinary.finish('tool_calls');
  await secret.listening.future.timeout(_deadline);
  expect(_map(_map(secret.body!['tool_choice'])['function'])['name'], 'propose_secrets');
  final idle = f.h.engine
      .watchDirector(f.chatId)
      .firstWhere((snapshot) => snapshot.pendingJobs == 0 && !snapshot.running)
      .timeout(_deadline);
  secret.add(
    ModelToolFragment(
      index: 0,
      id: 'actual-secret-proposal',
      type: 'function',
      name: 'propose_secrets',
      arguments: jsonEncode({
        'notes': 'private fixture proposal',
        'facts': [
          {'slotId': 'alibi', 'value': fact},
        ],
      }),
    ),
  );
  await secret.finish('tool_calls');
  await idle;
  final proposals = (await f.h.engine.readAgentRuns(
    f.chatId,
    limit: 1000,
  )).where((run) => run.kind == 'director.secret_proposal').toList();
  final newest = _db(
    f,
    (db) => db.select(
      "SELECT id FROM agent_runs WHERE chat_id = ? AND kind = 'director.secret_proposal' ORDER BY rowid DESC LIMIT 1",
      [f.chatId],
    ).single['id'],
  );
  final proposal = proposals.singleWhere((run) => run.id == newest);
  expect(proposal.result['success'], isTrue);
  expect(_maps(_map(proposal.result['output'])['facts']).single['value'], fact);
  return proposal;
}

// This genuine ordinary request obtains the product's full source/card/persona
// fingerprint without admitting a main turn or publishing a secret proposal.
Future<TavernDirectorRun> _manualSnapshot(_Fixture f) async {
  final call = f.h.model.prepare();
  final result = f.h.engine.runDirector(f.chatId);
  await call.listening.future.timeout(_deadline);
  expect(_map(_map(call.body!['tool_choice'])['function'])['name'], 'direct');
  final output = _ordinaryOutput()..['beat'] = '';
  call.add(
    ModelToolFragment(
      index: 0,
      id: 'same-fingerprint-control',
      type: 'function',
      name: 'direct',
      arguments: jsonEncode(output),
    ),
  );
  await call.finish('tool_calls');
  final run = await result.timeout(_deadline);
  expect(run.success, isTrue, reason: run.failure);
  return run;
}

T _db<T>(_Fixture f, T Function(Database) action) {
  final db = sqlite3.open('${f.h.root.path}/tavern.sqlite3');
  try {
    return action(db);
  } finally {
    db.close();
  }
}

_Json _node(_Fixture f, [String? nodeId]) => _db(
  f,
  (db) => Map<String, Object?>.from(
    db.select('SELECT * FROM nodes WHERE chat_id = ? AND id = ?', [f.chatId, nodeId ?? f.sourceId]).single,
  ),
);
_Json _extra(_Fixture f, [String? nodeId]) => _map(jsonDecode(_node(f, nodeId)['extra']! as String));
_Json _own(_Fixture f, [String? nodeId]) => _map(_extra(f, nodeId)['dshgo']);
_Json _saved(_Fixture f, [String? nodeId]) => _map(_own(f, nodeId)['tavernState']);
_Json _value(_Fixture f, [String? nodeId]) => _map(_map(_saved(f, nodeId)['messageVariables'])['dshgo']);
Object? _factAt(_Fixture f, [String? nodeId]) => _map(_value(f, nodeId)['private'])['fact'];
_Json _physical(_Fixture f) => _db(
  f,
  (db) => Map<String, Object?>.from(
    db.select('SELECT delta_json, full_json FROM node_states WHERE node_id = ?', [f.sourceId]).single,
  ),
);
_Json _runRow(_Fixture f, String id) => _db(
  f,
  (db) => Map<String, Object?>.from(
    db.select('SELECT id, chat_id, node_id, kind, at, usage, result_json FROM agent_runs WHERE id = ?', [id]).single,
  ),
);
void _removeRun(_Fixture f, String id) => _db(f, (db) => db.execute('DELETE FROM agent_runs WHERE id = ?', [id]));

void _restoreRun(_Fixture f, _Json row) => _db(
  f,
  (db) => db.execute(
    'INSERT INTO agent_runs(id, chat_id, node_id, kind, at, usage, result_json) VALUES(?, ?, ?, ?, ?, ?, ?)',
    [
      for (final key in ['id', 'chat_id', 'node_id', 'kind', 'at', 'usage', 'result_json']) row[key],
    ],
  ),
);

Future<List<TavernAgentRun>> _bindRuns(_Fixture f) async =>
    (await f.h.engine.readAgentRuns(f.chatId, limit: 1000)).where((run) => run.kind == 'director.secret_bind').toList();

Future<TavernAgentRun> _expectBound(_Fixture f) async {
  expect(_factAt(f), _fact);
  expect(_map((await f.h.engine.readState(f.chatId)).values)['private'], {'fact': _fact});
  final saved = _saved(f);
  final ledger = _map(saved['dshgoSecretRuntime']);
  expect(ledger['version'], 1);
  final binding = _maps(ledger['bindings']).single;
  expect(binding['slotId'], 'alibi');
  expect(binding['entityId'], 'entity-one');
  expect(binding['path'], '/private/fact');
  expect(binding['sourceNodeId'], f.sourceId);
  expect(binding['boundNodeId'], f.sourceId);
  expect(binding['proposalRunId'], f.proposal.id);
  final run = (await _bindRuns(f)).single;
  expect(run.id, binding['bindReceiptId']);
  expect(run.nodeId, f.sourceId);
  expect(run.result['committed'], isTrue);
  expect(run.result['bindings'], [binding]);
  expect(run.result['beforeStateFingerprint'], _map(f.proposal.result['capability'])['baselineFingerprint']);
  expect(_map(saved['messageVariables'])['foreign'], {
    'nested': [null, 'keep'],
  });
  expect(saved['vendorState'], {'keep': true});
  expect(_extra(f)['vendorExtra'], {
    'nested': [false, 'keep'],
  });
  expect(_own(f)['vendorOwn'], {'keep': 19});
  return run;
}

void main() {
  test('authoring adopts scoped B and releases it without writing live proof or changing source eligibility', () async {
    final f = await _ready(release: true);
    final base = await f.h.engine.createAuthoringDraft([
      TavernAuthoringTarget(kind: TavernAuthoringTargetKind.character, id: f.characterId),
    ]);
    final draft = await f.h.engine.editAuthoringDraft(
      base.id,
      draftRevision: base.draftRevision,
      changes: [
        TavernAuthoringChange(
          id: 'different-source',
          physicalResourceId: 'character:${f.characterId}',
          path: '/data/description',
          operation: TavernAuthoringChangeKind.set,
          value: 'A different captured character.',
        ),
      ],
    );
    final before = _db(
      f,
      (db) => {
        for (final table in [
          'chats',
          'nodes',
          'node_states',
          'agent_runs',
          'authoring_drafts',
          'authoring_resources',
          'authoring_operations',
        ])
          table: [for (final row in db.select('SELECT * FROM $table ORDER BY rowid')) Map<String, Object?>.from(row)],
      },
    );
    final generated = f.h.model.generated;
    final preview = await f.h.engine
        .previewAuthoringPrompt(
          TavernAuthoringPromptRequest(
            requestId: 'local-bind-release',
            draftId: draft.id,
            draftRevision: draft.draftRevision,
            changeIds: const [],
            at: T24Harness.at,
            seed: 7,
            context: TavernAuthoringChatContext(chatId: f.chatId, nodeId: f.sourceId, generationType: 'continue'),
          ),
        )
        .result;
    expect(preview.status, TavernAuthoringPreviewStatus.complete);
    final text = _maps(preview.assembly!.body['messages']).map((row) => row['content']).whereType<String>().join('\n');
    expect(text, contains('Fact: $_fact'));
    final trace = preview.secretTrace;
    expect(trace['scope'], 'preview');
    expect(trace['captureId'], preview.captureId);
    expect(trace['origin'], {'kind': 'chat', 'chatId': f.chatId, 'nodeId': f.sourceId});
    expect(trace['adoptedLocally'], isTrue);
    expect(trace['afterStateFingerprint'], isNot(trace['beforeStateFingerprint']));
    expect(_maps(trace['changes']).map((change) => change['path']), ['/private/fact']);
    final offered = _maps(trace['offered']).single;
    expect(offered['text'], 'Fact: $_fact');
    expect(trace['included'], [offered['sourceId']]);
    expect(trace['attempted'], isFalse);
    expect(jsonEncode(trace), isNot(contains('bindReceiptId')));
    expect(jsonEncode(trace), isNot(contains('"committed"')));

    // A selected candidate changes the authenticated card. It must not
    // rewrite the old proposal fingerprint merely to obtain a local proof.
    final changed = await f.h.engine
        .previewAuthoringPrompt(
          TavernAuthoringPromptRequest(
            requestId: 'local-bind-source-mismatch',
            draftId: draft.id,
            draftRevision: draft.draftRevision,
            changeIds: const ['different-source'],
            at: T24Harness.at,
            seed: 7,
            context: TavernAuthoringChatContext(chatId: f.chatId, nodeId: f.sourceId, generationType: 'continue'),
          ),
        )
        .result;
    expect(changed.status, TavernAuthoringPreviewStatus.complete);
    expect(changed.secretTrace['adoptedLocally'], isFalse);
    expect(changed.secretTrace['offered'], isEmpty);
    expect(changed.issues.map((issue) => issue.type), contains('secret_source_changed'));
    expect(
      _db(
        f,
        (db) => {
          for (final table in before.keys)
            table: [for (final row in db.select('SELECT * FROM $table ORDER BY rowid')) Map<String, Object?>.from(row)],
        },
      ),
      before,
    );
    expect(f.h.model.generated, generated);
    expect(await _bindRuns(f), isEmpty);
    expect(_factAt(f), isNull);
    final native = await _start(f, f.h.engine.continueReply(f.chatId, f.sourceId));
    expect(
      _maps(native.call.body!['messages']).map((row) => row['content']).whereType<String>().join('\n'),
      contains('Fact: $_fact'),
    );
    await _expectBound(f);
    await _finish(native);
    expect(_success(native).nodeId, f.sourceId);
    expect(await _bindRuns(f), hasLength(1), reason: 'Only the later native turn writes a real bind audit.');
  });

  test('a published proposal commits portable B and its independent bind run before the main provider entry', () async {
    final f = await _ready();
    final physical = _physical(f);
    final before = _node(f);
    final priorInspection = _own(f)['inspection'];
    expect(priorInspection, isA<_Json>());
    final generated = f.h.model.generated;
    var providerEntries = 0;
    f.h.model.atEntry = () {
      providerEntries++;
      expect(_factAt(f), _fact, reason: 'A second real SQLite connection must already see B at generate() entry.');
      final ledger = _map(_saved(f)['dshgoSecretRuntime']);
      final persisted = _db(
        f,
        (db) => db.select("SELECT result_json FROM agent_runs WHERE chat_id = ? AND kind = 'director.secret_bind'", [
          f.chatId,
        ]),
      );
      expect(persisted, hasLength(1));
      final audit = _map(jsonDecode(persisted.single['result_json']! as String));
      expect(audit['committed'], isTrue);
      expect(audit['bindings'], ledger['bindings']);
      expect(_physical(f), physical);
      expect(_own(f)['inspection'], priorInspection);
    };
    final active = await _start(f, f.h.engine.continueReply(f.chatId, f.sourceId));
    f.h.model.atEntry = null;
    expect(providerEntries, 1);
    expect(f.h.model.generated, generated + 1);
    expect(active.events.values.whereType<TavernTurnDone>(), isEmpty);
    final bind = await _expectBound(f);
    expect(_physical(f), physical, reason: 'Portable B must not rewrite the physical checkpoint/delta.');
    final live = _node(f);
    for (final key in ['text', 'reasoning', 'usage', 'reported_usage', 'original', 'at']) {
      expect(live[key], before[key], reason: key);
    }
    expect(
      _own(f)['inspection'],
      priorInspection,
      reason: 'Binding and continuation preparation must preserve the old raw inspection until terminal commit.',
    );
    await _finish(
      active,
      text: ' continued',
      ops: [
        {'op': 'set', 'path': '/count', 'value': 1},
      ],
    );
    expect(_success(active).text, '$_body continued');
    await _expectBound(f);
    expect(_value(f)['count'], 1);
    final terminal = (await f.h.engine.readAgentRuns(f.chatId, limit: 1000)).singleWhere(
      (run) => run.kind == 'state.rules' && run.result['invocationId'] == bind.result['generationInvocationId'],
    );
    expect(terminal.result['committed'], isTrue);
    expect(_maps(terminal.result['changes']).map((change) => change['path']), [
      '/count',
    ], reason: 'Terminal reporting must describe B to C, excluding the independently committed A to B secret.');
    expect(_physical(f), physical);
    await f.h.reopen();
    await _expectBound(f);
    expect(_value(f)['count'], 1, reason: 'The committed terminal C must survive reopening together with B.');
    expect((await f.h.engine.path(f.chatId)).single.text, '$_body continued');
  });

  test(
    'empty continuation transport failure restores the committed B target with detached old body and extra',
    () async {
      final f = await _ready();
      final physical = _physical(f);
      final bExtra = _extra(f);
      await f.h.engine.setPreset(_macroPreset(), chatId: f.chatId);
      final active = await _start(f, f.h.engine.continueReply(f.chatId, f.sourceId));
      final bind = await _expectBound(f);
      final bindRow = _runRow(f, bind.id);
      final bOwn = _map(bExtra['dshgo']);
      final bSaved = _map(bOwn['tavernState']);
      _map(_map(_map(bSaved['messageVariables'])['dshgo'])['private'])['fact'] = _fact;
      bSaved['dshgoSecretRuntime'] = _saved(f)['dshgoSecretRuntime'];
      bOwn['secretBinding'] = _own(f)['secretBinding'];
      expect(
        _map(_saved(f)['variables'])['keptLocal'],
        'mutated-during-preparation',
        reason: 'The real macro must mutate G after B was committed.',
      );
      // DTO getters are detached; mutating them must not mutate the B fallback.
      final exposed = await f.h.engine.readState(f.chatId);
      _map(_map(exposed.values)['private'])['fact'] = 'caller mutation';
      active.call.fail(TavernFailure.network, 'controlled empty continuation failure');
      final failure = await _failed(active.events);
      expect(failure.kind, TavernFailure.network);
      expect(failure.partial!.nodeId, f.sourceId);
      expect(failure.partial!.text, _body);
      expect((await f.h.engine.path(f.chatId)).single.text, _body);
      expect(_extra(f), bExtra, reason: 'The recovery target is B, not the later mutable generation G.');
      expect(_map(_saved(f)['variables'])['keptLocal'], 7);
      expect(_physical(f), physical);
      expect(_runRow(f, bind.id), bindRow);
      await _expectBound(f);
      await f.h.reopen();
      await _expectBound(f);
    },
  );

  test('empty normal send rollback deletes only its new nodes and retains B on the original anchor', () async {
    final f = await _ready();
    final physical = _physical(f);
    final active = await _start(f, f.h.engine.send(f.chatId, 'new question'));
    final bind = await _expectBound(f);
    final bindRow = _runRow(f, bind.id);
    expect((await f.h.engine.path(f.chatId)).map((message) => message.role), [
      TavernRole.character,
      TavernRole.user,
      TavernRole.character,
    ]);
    expect(_physical(f), physical);
    active.call.fail(TavernFailure.network, 'controlled empty normal send failure');
    final failure = await _failed(active.events);
    expect(failure.kind, TavernFailure.network);
    expect(failure.partial, isNull);
    expect((await f.h.engine.path(f.chatId)).single.nodeId, f.sourceId);
    expect(_db(f, (db) => db.select('SELECT id FROM nodes WHERE chat_id = ?', [f.chatId])), hasLength(1));
    expect(_runRow(f, bind.id), bindRow);
    expect(_physical(f), physical);
    await _expectBound(f);
    await f.h.reopen();
    await _expectBound(f);
  });

  for (final failAtNode in [true, false]) {
    final stage = failAtNode ? 'node UPDATE' : 'bind-run INSERT';
    test('a real $stage failure rolls the whole binding back to A and prevents the main request', () async {
      final f = await _ready();
      final extra = _extra(f);
      final physical = _physical(f);
      final proposal = _runRow(f, f.proposal.id);
      final generated = f.h.model.generated;
      final sql = failAtNode
          ? "CREATE TRIGGER reject_secret_binding BEFORE UPDATE OF extra ON nodes "
                r"WHEN json_extract(NEW.extra, '$.dshgo.tavernState.dshgoSecretRuntime.version') = 1 "
                r"AND json_type(OLD.extra, '$.dshgo.tavernState.dshgoSecretRuntime') IS NULL "
                "BEGIN SELECT RAISE(ABORT, 'controlled secret node update failure'); END"
          : "CREATE TRIGGER reject_secret_binding BEFORE INSERT ON agent_runs "
                "WHEN NEW.kind = 'director.secret_bind' "
                "BEGIN SELECT RAISE(ABORT, 'controlled secret bind audit failure'); END";
      _db(f, (db) => db.execute(sql));
      try {
        // Do not prepare a provider call: reaching generate is itself a failure.
        final events = T24Events(f.h.engine.continueReply(f.chatId, f.sourceId));
        final failure = await _failed(events);
        expect(failure.kind, TavernFailure.server);
        expect(failure.detail, contains('SqliteException'));
        expect(events.values.whereType<TavernTurnStarted>(), isEmpty);
        expect(f.h.model.generated, generated);
        expect(_extra(f), extra);
        expect(_physical(f), physical);
        expect(_factAt(f), isNull);
        expect(await _bindRuns(f), isEmpty);
        expect(_runRow(f, f.proposal.id), proposal);
        expect((await f.h.engine.path(f.chatId)).single.nodeId, f.sourceId);
      } finally {
        _db(f, (db) => db.execute('DROP TRIGGER reject_secret_binding'));
      }
      // Same unchanged real proposal succeeds after removing only the SQL fault.
      final retry = await _start(f, f.h.engine.continueReply(f.chatId, f.sourceId));
      await _expectBound(f);
      await _finish(retry, text: ' retried');
      expect(_success(retry).text, '$_body retried');
      expect(_physical(f), physical);
    });
  }

  for (final partial in [false, true]) {
    final outcome = partial ? 'partial text' : 'an empty continuation rollback';
    test('terminal SQL failure retains independent B with $outcome', () async {
      final f = await _ready();
      final physical = _physical(f);
      final active = await _start(f, f.h.engine.continueReply(f.chatId, f.sourceId));
      final bind = await _expectBound(f);
      final bindRow = _runRow(f, bind.id);
      _db(
        f,
        (db) => db.execute(
          "CREATE TRIGGER reject_secret_terminal BEFORE INSERT ON agent_runs "
          r"WHEN NEW.kind = 'state.rules' AND json_extract(NEW.result_json, '$.committed') = 1 "
          "BEGIN SELECT RAISE(ABORT, 'controlled terminal state audit failure'); END",
        ),
      );
      try {
        await _finish(
          active,
          text: partial ? ' partial' : '',
          ops: [
            {'op': 'set', 'path': '/count', 'value': 1},
          ],
        );
        final failure = await _failed(active.events);
        expect(failure.kind, TavernFailure.server);
        expect(failure.detail, contains('SqliteException'));
        expect(failure.partial!.nodeId, f.sourceId);
        expect(failure.partial!.text, partial ? '$_body partial' : _body);
        expect(_value(f)['count'], 0, reason: 'Uncommitted C must not replace B.');
        expect(_physical(f), physical);
        expect(_runRow(f, bind.id), bindRow);
        await _expectBound(f);
        final tools = (await f.h.engine.readAgentRuns(
          f.chatId,
          limit: 1000,
        )).where((run) => run.kind == 'state.tool').toList();
        expect(tools, hasLength(1));
        expect(tools.single.result['committed'], isFalse);
        expect(
          _map(tools.single.result['execution'])['acceptedCount'],
          1,
          reason: 'The real model operation reached a C candidate before the SQL fault.',
        );
        expect((await f.h.engine.inspectTurn(f.chatId))!.state['stateCommitted'], isFalse);
      } finally {
        _db(f, (db) => db.execute('DROP TRIGGER reject_secret_terminal'));
      }
      await f.h.reopen();
      await _expectBound(f);
      expect(_value(f)['count'], 0);
      expect((await f.h.engine.path(f.chatId)).single.text, partial ? '$_body partial' : _body);
    });
  }

  test('a real preparation budget failure after binding keeps B without making a main request', () async {
    final f = await _ready();
    final physical = _physical(f);
    await f.h.engine.setPreset(_overflowPreset(), chatId: f.chatId);
    final generated = f.h.model.generated;
    final draft = await f.h.engine.createAuthoringDraft([
      TavernAuthoringTarget(kind: TavernAuthoringTargetKind.character, id: f.characterId),
    ]);
    final before = _node(f);
    final preview = await f.h.engine
        .previewAuthoringPrompt(
          TavernAuthoringPromptRequest(
            requestId: 'local-bind-before-budget-failure',
            draftId: draft.id,
            draftRevision: draft.draftRevision,
            changeIds: const [],
            at: T24Harness.at,
            seed: 7,
            context: TavernAuthoringChatContext(chatId: f.chatId, nodeId: f.sourceId, generationType: 'continue'),
          ),
        )
        .result;
    expect(preview.status, TavernAuthoringPreviewStatus.failed);
    expect(preview.assembly, isNull);
    expect(preview.issues.single.type, 'prompt_budget_exceeded');
    expect(preview.secretTrace['adoptedLocally'], isTrue);
    expect(preview.secretTrace['attempted'], isFalse);
    expect(_maps(preview.secretTrace['changes']).map((change) => change['path']), ['/private/fact']);
    expect(_node(f), before);
    expect(await _bindRuns(f), isEmpty);
    expect(f.h.model.generated, generated);
    final events = T24Events(f.h.engine.continueReply(f.chatId, f.sourceId));
    final failure = await _failed(events);
    expect(failure.kind, TavernFailure.contextTooLong);
    expect(events.values.whereType<TavernTurnStarted>(), isEmpty);
    expect(f.h.model.generated, generated);
    expect(failure.partial!.text, _body);
    await _expectBound(f);
    expect(_physical(f), physical);
    expect((await f.h.engine.path(f.chatId)).single.text, _body);
    await f.h.reopen();
    await _expectBound(f);
  });

  for (final softDeleted in [false, true]) {
    final visibility = softDeleted ? 'soft-deleted' : 'visible';
    test('a $visibility physical child blocks binding without blocking continuation', () async {
      final f = await _ready();
      final child = await f.h.engine.sendOnly(f.chatId, 'retained physical future');
      final token = softDeleted ? await f.h.engine.deleteFrom(f.chatId, child.nodeId) : null;
      await f.h.engine.selectNode(f.chatId, f.sourceId);
      final childRow = _node(f, child.nodeId);
      expect(childRow['parent_id'], f.sourceId);
      expect(childRow['deleted_by'], softDeleted ? isNotNull : isNull);
      final active = await _start(f, f.h.engine.continueReply(f.chatId, f.sourceId));
      expect(_factAt(f), isNull);
      expect(await _bindRuns(f), isEmpty);
      await _finish(active);
      expect(_success(active).nodeId, f.sourceId);
      expect(_node(f, child.nodeId)['parent_id'], f.sourceId);
      // Remove the real future through public APIs; the unchanged source and
      // unchanged proposal then become eligible, making the child guard decisive.
      if (token != null) expect(await f.h.engine.undoDeleteFrom(f.chatId, token), isTrue);
      await f.h.engine.deleteMessage(f.chatId, child.nodeId);
      await f.h.engine.selectNode(f.chatId, f.sourceId);
      final retry = await _start(f, f.h.engine.continueReply(f.chatId, f.sourceId));
      await _expectBound(f);
      await _finish(retry, text: ' after removing future');
      _success(retry);
    });
  }

  test('regeneration and an inactive continuation do not bind until the original source is current', () async {
    final f = await _ready();
    final regenerated = await _start(f, f.h.engine.regenerate(f.chatId, f.sourceId));
    expect(_factAt(f), isNull);
    expect(await _bindRuns(f), isEmpty);
    await _finish(regenerated, text: 'sibling branch');
    final sibling = _success(regenerated);
    expect(sibling.nodeId, isNot(f.sourceId));
    expect(_factAt(f, sibling.nodeId), isNull);
    expect((await f.h.engine.path(f.chatId)).single.nodeId, sibling.nodeId);
    final inactive = await _start(f, f.h.engine.continueReply(f.chatId, f.sourceId));
    expect(_factAt(f), isNull);
    expect(await _bindRuns(f), isEmpty);
    await _finish(inactive);
    expect(_success(inactive).nodeId, f.sourceId);
    expect(_node(f, sibling.nodeId)['text'], 'sibling branch');
    final current = await _start(f, f.h.engine.continueReply(f.chatId, f.sourceId));
    await _expectBound(f);
    await _finish(current, text: ' current again');
    _success(current);
    expect(_factAt(f, sibling.nodeId), isNull);
  });

  test('a cold admission queued behind a public same-description edit does not bind across its revision', () async {
    final f = await _ready();
    // Empty beat/prefetch leaves ordinary main generation available even when
    // the old helper's knowledge authorization is rejected before sending.
    final before = await _manualSnapshot(f);
    expect(before.sourceFingerprint, f.proposal.result['sourceFingerprint']);
    final fields = (await f.h.engine.characterFields(f.characterId))!;
    final description = fields['description']! as String;
    final proposal = _runRow(f, f.proposal.id);
    await f.h.reopen();
    final gate = _QueuedEditGate();
    await _withReadGate(f, gate, () async {
      // A nonempty public patch performs a real publication and revision bump
      // even when the description string equals its current value. Its first
      // card read owns the library queue; the main's cold _record waits behind.
      final editing = gate.edit(() => f.h.engine.updateCharacterFields(f.characterId, {'description': description}));
      await gate.entered.future.timeout(_deadline);
      final call = f.h.model.prepare();
      final events = T24Events(f.h.engine.continueReply(f.chatId, f.sourceId));
      expect((await f.h.engine.inspectTurn(f.chatId))!.status, TavernInspectionStatus.preparing);
      expect(call.listening.isCompleted, isFalse);
      expect(gate.byteReads, 1);
      gate.releaseEdit();
      // The writer also reads its authority before-image. Identify the queued
      // main by its operation zone, then hold its real new bytes until the
      // public edit future has completed, making the order explicit.
      await gate.mainRead.future.timeout(_deadline);
      expect((await editing.timeout(_deadline)).id, f.characterId);
      expect(call.listening.isCompleted, isFalse);
      gate.releaseMain();
      await _listening(call, events);
      expect(_factAt(f), isNull);
      expect(await _bindRuns(f), isEmpty);
      expect(_runRow(f, f.proposal.id), proposal);
      await call.finish('length');
      await events.done.future.timeout(_deadline);
      expect(_success((call: call, events: events)).text, _body);
      final inspection = (await f.h.engine.inspectTurn(f.chatId))!;
      final issues = _maps(_map(inspection.state['secrets'])['issues']);
      expect(issues.map((issue) => issue['code']).toSet(), {'secret_card_changed'});
      expect(_factAt(f), isNull);
      expect(await _bindRuns(f), isEmpty);
      final currentFields = (await f.h.engine.characterFields(f.characterId))!;
      expect(currentFields['description'], description);
      expect({...currentFields}..remove('modification_date'), {...fields}..remove('modification_date'));
      // This is the product's actual canonical fingerprint, not a copied hash
      // implementation. A changed source/card fingerprint cannot explain denial.
      final current = await _manualSnapshot(f);
      expect(current.sourceFingerprint, before.sourceFingerprint);
      expect(current.sourceFingerprint, f.proposal.result['sourceFingerprint']);
      expect(await _bindRuns(f), isEmpty);
    });
  });

  test('a real proposal inserted during the first preparation await is too late for onListen admission', () async {
    final f = await _ready();
    final proposal = _runRow(f, f.proposal.id);
    _removeRun(f, f.proposal.id);
    await f.h.reopen(); // Force the real character file read after onListen.
    final gate = _ReadGate();
    await _withReadGate(f, gate, () async {
      final call = f.h.model.prepare();
      final events = T24Events(f.h.engine.continueReply(f.chatId, f.sourceId));
      await gate.entered.future.timeout(_deadline);
      expect(call.listening.isCompleted, isFalse);
      _restoreRun(f, proposal);
      gate.release();
      await _listening(call, events);
      expect(_factAt(f), isNull);
      expect(await _bindRuns(f), isEmpty);
      call.fail(TavernFailure.network, 'leave the original source unchanged for a second admission');
      expect((await _failed(events)).partial!.text, _body);
      final retry = await _start(f, f.h.engine.continueReply(f.chatId, f.sourceId));
      await _expectBound(f);
      await _finish(retry, text: ' admitted next time');
      _success(retry);
    });
  });

  test('a later genuine proposal cannot replace the proposal already frozen by onListen', () async {
    final f = await _ready();
    final first = _runRow(f, f.proposal.id);
    _removeRun(f, f.proposal.id);
    final later = await _proposeFromTick(f, _laterFact);
    expect(
      later.result['sourceFingerprint'],
      f.proposal.result['sourceFingerprint'],
      reason: 'Both genuine proposals must authenticate the same unchanged source.',
    );
    final second = _runRow(f, later.id);
    _removeRun(f, later.id);
    _restoreRun(f, first);
    await _settings(f, 1000);
    await f.h.reopen();
    final gate = _ReadGate();
    await _withReadGate(f, gate, () async {
      final call = f.h.model.prepare();
      final events = T24Events(f.h.engine.continueReply(f.chatId, f.sourceId));
      await gate.entered.future.timeout(_deadline);
      _restoreRun(f, second);
      expect(
        _db(
          f,
          (db) => db.select(
            "SELECT id FROM agent_runs WHERE chat_id = ? AND kind = 'director.secret_proposal' ORDER BY rowid DESC LIMIT 1",
            [f.chatId],
          ).single['id'],
        ),
        later.id,
      );
      gate.release();
      await _listening(call, events);
      final bind = await _expectBound(f);
      expect(bind.result['proposalRunId'], f.proposal.id);
      expect(bind.result['proposalRunId'], isNot(later.id));
      final active = (call: call, events: events);
      await _finish(active, text: ' first captured proposal');
      _success(active);
      expect(_factAt(f), _fact);
    });
  });
}

ChatPreset _macroPreset() {
  final raw = t24Preset().raw;
  final prompts = (raw['prompts']! as List<Object?>).cast<_Json>();
  return ChatPreset({
    ...raw,
    'continue_prefill': false,
    'prompts': [
      for (final prompt in prompts)
        if (prompt['identifier'] == 'main')
          {...prompt, 'content': '{{setvar::keptLocal::mutated-during-preparation}}'}
        else
          prompt,
    ],
  });
}

ChatPreset _overflowPreset() {
  final raw = t24Preset().raw;
  final prompts = (raw['prompts']! as List<Object?>).cast<_Json>();
  return ChatPreset({
    ...raw,
    'continue_prefill': false,
    'openai_max_context': 3,
    'openai_max_tokens': 0,
    'prompts': [
      for (final prompt in prompts)
        if (prompt['identifier'] == 'main')
          {...prompt, 'content': List.filled(100, 'mandatory system content').join(' ')}
        else
          prompt,
    ],
  });
}

Future<void> _withReadGate(_Fixture f, _ReadGate gate, Future<void> Function() action) async {
  final parent = Zone.current;
  final target = File('${f.h.root.path}/characters/${f.characterId}/card.json').absolute.uri;
  try {
    await IOOverrides.runZoned(
      action,
      createFile: (path) {
        final real = parent.run(() => File(path));
        return parent.run(() => real.absolute.uri) == target ? _GatedFile(real, gate) : real;
      },
    );
  } finally {
    gate.release();
    await f.h.engine.close();
  }
}

class _ReadGate {
  final entered = Completer<void>();
  final _released = Completer<void>();
  void release() {
    if (!_released.isCompleted) _released.complete();
  }

  Future<T> read<T>(Future<T> Function() operation) async {
    if (!entered.isCompleted) entered.complete();
    await _released.future;
    return operation();
  }

  Future<Uint8List> readBytes(Future<Uint8List> Function() operation) => read(operation);
}

// Hold the public edit's first card read, admit the cold main behind it, and
// then hold the main's first card read. Additional reads within the writer
// (including its authority before-image) retain its zone and cannot be
// mistaken for the queued main or deadlock the shared library queue.
class _QueuedEditGate extends _ReadGate {
  final mainRead = Completer<void>();
  final _editReleased = Completer<void>();
  final _mainReleased = Completer<void>();
  var byteReads = 0;

  Future<T> edit<T>(Future<T> Function() action) => runZoned(action, zoneValues: {this: true});

  void releaseEdit() {
    if (!_editReleased.isCompleted) _editReleased.complete();
  }

  void releaseMain() {
    if (!_mainReleased.isCompleted) _mainReleased.complete();
  }

  @override
  void release() {
    releaseEdit();
    releaseMain();
  }

  @override
  Future<T> read<T>(Future<T> Function() operation) => operation();
  @override
  Future<Uint8List> readBytes(Future<Uint8List> Function() operation) async {
    byteReads++;
    final bytes = await operation();
    if (Zone.current[this] == true) {
      if (!entered.isCompleted) {
        entered.complete();
        await _editReleased.future;
      }
    } else if (!mainRead.isCompleted) {
      mainRead.complete();
      await _mainReleased.future;
    }
    return bytes;
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
  Future<File> copy(String path) => real.copy(path);
  @override
  Future<Uint8List> readAsBytes() => gate.readBytes(real.readAsBytes);
  @override
  Future<String> readAsString({Encoding encoding = utf8}) => gate.read(() => real.readAsString(encoding: encoding));
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

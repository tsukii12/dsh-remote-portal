import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import 'support/t24_engine_harness.dart';

// Real facade, SQLite, character/persona files, assembly and tool accumulator.
// Only provider deltas, clock and random are controlled. SQLite is read only.
typedef _Json = Map<String, Object?>;
typedef _Main = ({_Call call, T24Events events});
typedef _Manual = ({_Call call, Future<TavernDirectorRun> result});
const _main = 'main';
const _direct = 'direct';
const _secret = 'propose_secrets';
const _deadline = Duration(seconds: 10);
const _fact = 'SECRET-FACT-7c28';
const _privateNotes = 'SECRET-NOTES-938a';
const _beat = 'KNOWLEDGE-BEAT-62e3';
const _prefetch = 'KNOWLEDGE-PREFETCH-54d2';

void main() {
  test('secret helper is explicitly off by default and manual directing never adds it', () async {
    // The card also says secretsEnabled:true; only the host setting authorizes
    // the additional billable helper.
    final h = await _Harness.open();
    await h.engine.setSettings({
      'director': {'enabled': true},
    });
    for (final setting in <Object?>[null, 'true']) {
      if (setting != null) {
        await h.engine.setSettings({
          'director': {'secretsEnabled': setting},
        });
      }
      await h.reply('ordinary tick $setting');
      final call = await h.next(_direct);
      expect((await h.engine.readDirector(h.chatId)).pendingJobs, 1);
      final idle = _idle(h);
      await call.tool(_direct, _output('ordinary-$setting'));
      expect((await idle).pendingJobs, 0);
      expect(h.model.ofKind(_secret), isEmpty);
    }
    await h.enable();
    final manual = await h.manual();
    final run = await _finishManual(manual, _output('explicit'));
    expect(run.automatic, isFalse);
    expect((await h.engine.readDirector(h.chatId)).pendingJobs, 0);
    expect(h.model.ofKind(_secret), isEmpty);
    expect(await h.runs('director.secret_proposal'), isEmpty);
    expect(await h.runs('director.tick'), hasLength(2));
  });

  test('due tick sends ordinary then secret and proposal notes never become ordinary notes', () async {
    final h = await _Harness.open();
    await h.enable();
    final source = await h.reply('successful source');
    final ordinary = await h.next(_direct);
    expect(h.model.calls.map((call) => call.kind), [_main, _direct]);
    expect((await h.engine.readDirector(h.chatId)).pendingJobs, 2);
    _expectProtected(_input(ordinary));
    await ordinary.tool(_direct, _output('ordinary-before-secret'));
    final secret = await h.next(_secret);
    expect(h.model.calls.map((call) => call.kind), [_main, _direct, _secret]);
    expect(secret.config.model, 'deepseek-flash');
    expect(secret.config.thinking, isFalse);
    expect(secret.body['stream'], isFalse);
    expect(secret.body['max_tokens'], 4096);
    expect(secret.body['tool_choice'], {
      'type': 'function',
      'function': {'name': _secret},
    });
    final function = _map(_maps(secret.body['tools']).single['function']);
    expect(function['strict'], isTrue);
    final parameters = _map(function['parameters']);
    expect(parameters['additionalProperties'], isFalse);
    expect(parameters['required'], ['notes', 'facts']);
    expect(_map(_input(secret)['card']).containsKey('stateDefinition'), isTrue);
    final slot = _maps(_input(secret)['slots']).single;
    expect(slot['slotId'], 'identity');
    expect(slot['entityId'], 'entity-A');
    expect(_map(slot['declaration'])['path'], '/entity/secret');
    final before = _sourceRow(h, source.nodeId);
    secret.add(const ModelText('IGNORED-SECRET-CHAT-TEXT'));
    secret.add(const ModelReasoning('IGNORED-SECRET-REASONING'));
    secret.add(const ModelUsage(TavernUsage(promptTokens: 9, cacheHitTokens: 1, completionTokens: 3)));
    final idle = _idle(h);
    await secret.tool(_secret, _proposal());
    final view = await idle;
    expect(view.latestSuccess!.notes, 'ordinary-before-secret notes');
    expect(view.latestAttempt!.id, view.latestSuccess!.id);
    expect(_sourceRow(h, source.nodeId), before);
    expect(_map(_map((await h.engine.readState(h.chatId)).values)['entity']).containsKey('secret'), isFalse);
    final proposal = (await h.runs('director.secret_proposal')).single;
    expect(proposal.result['output'], _proposal());
    expect(proposal.result['sourceNodeId'], source.nodeId);
    expect(proposal.result['automatic'], isTrue);
    expect(proposal.usage!['promptTokens'], 9);
    expect(await h.runs('director.secret_bind'), isEmpty);
    expect(
      jsonEncode((await h.engine.path(h.chatId)).map((message) => message.text).toList()),
      isNot(contains('IGNORED-SECRET')),
    );
    final manual = await h.manual();
    expect(_input(manual.call)['previousNotes'], 'ordinary-before-secret notes');
    expect(jsonEncode(manual.call.body), isNot(contains(_privateNotes)));
    expect(jsonEncode(manual.call.body), isNot(contains(_fact)));
    await _finishManual(manual, _output('after-secret'));
    expect(h.model.ofKind(_secret), hasLength(1));
  });

  test('ordinary and secret jobs share all thirty two slots and ordinary owns the last slot', () async {
    final h = await _Harness.open();
    final held = await h.manual();
    await h.enable();
    for (var i = 0; i < 15; i++) {
      await h.reply('queued pair $i');
    }
    expect((await h.engine.readDirector(h.chatId)).pendingJobs, 31);
    final last = await h.reply('one slot remains');
    expect((await h.engine.readDirector(h.chatId)).pendingJobs, 32);
    expect(h.model.helpers, hasLength(1));
    expect(await h.runs('director.tick'), hasLength(16));
    expect(await h.runs('director.failure'), isEmpty);
    final rejected = (await h.runs('director.secret_failure')).single;
    expect(rejected.result['failure'], 'director_queue_full');
    expect(rejected.result['sourceNodeId'], last.nodeId);
    expect(rejected.result['success'], isFalse);
    // Cancel the 31 automatic owners, preserving the already-running manual.
    await h.engine.setSettings({
      'director': {'enabled': false},
    });
    expect((await h.engine.readDirector(h.chatId)).pendingJobs, 1);
    expect(held.call.cancellation.isCancelled, isFalse);
    await _finishManual(held, _output('surviving-manual'));
    expect((await h.engine.readDirector(h.chatId)).pendingJobs, 0);
    expect(h.model.helpers, hasLength(1));
    expect((await h.engine.path(h.chatId)).last.nodeId, last.nodeId);
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('secret wire and local authority failures publish only failure and an empty proposal remains valid', () async {
    final h = await _Harness.open();
    await h.enable();
    for (final fault in ['path', 'tool', 'duplicate', 'terminal']) {
      final source = await h.reply('wire case $fault');
      await (await h.next(_direct)).tool(_direct, _output('ordinary-$fault'));
      final secret = await h.next(_secret);
      final idle = _idle(h);
      final output = _proposal();
      if (fault == 'path') _maps(output['facts']).single['path'] = '/public';
      secret.fragment(fault == 'tool' ? _direct : _secret, output);
      if (fault == 'duplicate') secret.fragment(_secret, output, index: 1);
      await secret.finish(fault == 'terminal' ? 'length' : 'tool_calls');
      await idle;
      final failure = (await h.runs('director.secret_failure')).first;
      expect(failure.result['sourceNodeId'], source.nodeId, reason: fault);
      expect(failure.result['failure'], 'invalid_secret_output', reason: fault);
      expect(failure.result.containsKey('output'), isFalse, reason: fault);
      expect(await h.runs('director.secret_proposal'), isEmpty, reason: fault);
      expect(await h.runs('director.secret_bind'), isEmpty, reason: fault);
    }
    await h.reply('valid omission');
    await (await h.next(_direct)).tool(_direct, _output('ordinary-empty'));
    final secret = await h.next(_secret);
    final idle = _idle(h);
    await secret.tool(_secret, {'notes': _privateNotes, 'facts': <Object?>[]});
    await idle;
    expect((await h.runs('director.secret_proposal')).single.result['success'], isTrue);
    await h.reply('empty proposal creates no binding', reason: 'length');
    expect(await h.runs('director.secret_bind'), isEmpty);
    expect(_map(_map((await h.engine.readState(h.chatId)).values)['entity']).containsKey('secret'), isFalse);
  });

  test('disabling secrets cancels an active secret while preserving an ordinary manual owner', () async {
    final h = await _Harness.open();
    await h.enable();
    await h.reply('source for cancellation');
    await (await h.next(_direct)).tool(_direct, _output('ordinary-before-cancel'));
    final secret = await h.next(_secret);
    final manualResult = h.engine.runDirector(h.chatId);
    expect((await h.engine.readDirector(h.chatId)).pendingJobs, 2);
    await h.engine.setSettings({
      'director': {'secretsEnabled': false},
    });
    final ordinary = await h.next(_direct);
    expect(secret.cancellation.isCancelled, isTrue);
    expect(ordinary.cancellation.isCancelled, isFalse);
    expect((await h.engine.readDirector(h.chatId)).pendingJobs, 1);
    _expectProtected(_input(ordinary));
    // These deltas are emitted after the real subscription was cancelled.
    secret.fragment(_secret, _proposal());
    await secret.finish('tool_calls');
    await ordinary.tool(_direct, _output('manual-after-disable'));
    expect((await manualResult).success, isTrue);
    expect((await h.runs('director.secret_failure')).single.result['failure'], 'cancelled:cancelled');
    expect(await h.runs('director.secret_proposal'), isEmpty);
    expect(await h.runs('director.secret_bind'), isEmpty);
    expect((await h.engine.readDirector(h.chatId)).pendingJobs, 0);
  });

  for (final change in ['card', 'persona']) {
    test('queued protected ordinary and secret jobs reject a current $change change before provider send', () async {
      final h = await _Harness.open();
      final persona = await h.engine.createPersona(name: 'Player', description: 'initial persona');
      await h.engine.bindPersona(h.chatId, persona.id);
      final held = await h.manual();
      await h.enable();
      final source = await h.reply('queued source');
      expect((await h.engine.readDirector(h.chatId)).pendingJobs, 3);
      if (change == 'card') {
        await h.engine.updateCharacterFields(h.characterId, {'description': 'changed current card'});
      } else {
        await h.engine.updatePersona(persona.id, description: 'changed current persona');
      }
      expect(held.call.cancellation.isCancelled, isFalse);
      final drained = _idleWithoutAnotherHelper(h);
      await _finishManual(held, _output('already-sent'));
      await drained;
      expect(h.model.helpers, hasLength(1));
      expect((await h.runs('director.failure')).single.result['failure'], 'invalid_director_output');
      final secretFailure = (await h.runs('director.secret_failure')).single;
      expect(secretFailure.result['sourceNodeId'], source.nodeId);
      expect(secretFailure.result['failure'], 'invalid_secret_output');
      expect(await h.runs('director.secret_proposal'), isEmpty);
    });
  }

  test('automatic jobs retain the card revision captured before an in-flight main card edit', () async {
    final h = await _Harness.open();
    await h.engine.updateCharacterFields(h.characterId, {'description': 'CARD-CAPTURED-BEFORE-MAIN'});
    await h.enable();
    final active = await h.start(h.engine.send(h.chatId, 'main already at the provider'));
    expect(jsonEncode(active.call.body), contains('CARD-CAPTURED-BEFORE-MAIN'));
    await h.engine.updateCharacterFields(h.characterId, {'description': 'CARD-EDITED-DURING-MAIN'});
    expect(active.call.cancellation.isCancelled, isFalse);
    expect((await h.engine.characterFields(h.characterId))!['description'], 'CARD-EDITED-DURING-MAIN');
    // Register the forbidden request observers before completing the main.
    // An idle snapshot taken now would be vacuous: the due jobs do not exist
    // until this main commits. Only start the idle read after its completion.
    final view = await Future.any<TavernDirectorSnapshot>([
      for (final kind in [_direct, _secret])
        h.model.next(kind).then<TavernDirectorSnapshot>((_) {
          throw TestFailure('Automatic $kind sent the old card after an in-flight main card edit.');
        }),
      h.complete(active, 'main committed after the card edit').then<TavernDirectorSnapshot>((_) => _idle(h)),
    ]);
    final source = active.events.values.whereType<TavernTurnDone>().single.message;
    expect((await h.engine.path(h.chatId)).last.nodeId, source.nodeId);
    expect(view.pendingJobs, 0);
    expect(view.running, isFalse);
    expect(h.model.helpers, isEmpty);
    expect(h.model.ofKind(_main), hasLength(1));
    final tick = (await h.runs('director.tick')).single;
    expect(tick.nodeId, source.nodeId);
    expect(tick.result['scheduled'], isTrue);
    final ordinary = (await h.runs('director.failure')).single;
    final secret = (await h.runs('director.secret_failure')).single;
    expect(ordinary.result['sourceNodeId'], source.nodeId);
    expect(ordinary.result['failure'], 'invalid_director_output');
    expect(secret.result['sourceNodeId'], source.nodeId);
    expect(secret.result['failure'], 'invalid_secret_output');
    expect(await h.runs('director.success'), isEmpty);
    expect(await h.runs('director.secret_proposal'), isEmpty);
  });

  test('an unexecutable array slot still protects its value and raw init from ordinary input', () async {
    final h = await _Harness.open(arraySlot: true);
    final panel = await h.engine.readState(h.chatId);
    expect(_map((_map(panel.values)['items']! as List<Object?>).single)['secret'], _fact);
    final active = await h.manual();
    _expectProtected(_input(active.call));
    expect(_map(_input(active.call)['state'])['value'], isNull);
    final run = await _finishManual(active, _output('array-protected'));
    expect(run.success, isTrue);
    expect(jsonEncode((await h.engine.readState(h.chatId)).values), contains(_fact));
    await h.reply('ordinary main with invalid array declaration', reason: 'length');
    expect(jsonEncode(h.model.ofKind(_main).single.body), isNot(contains(_fact)));
    expect(h.model.ofKind(_secret), isEmpty);
  });

  test(
    'a public import with an unsupported state runtime omits automatic value without erasing the saved secret',
    () async {
      final h = await _Harness.open();
      h.chatId = await _importSaved(h, h.characterId, {
        'variables': <String, Object?>{},
        'messageVariables': {'dshgo': _value(fact: _fact)},
        'dshgoStateRuntime': {'version': 2, 'opaque': 'preserve-runtime'},
      });
      final before = await _saved(h);
      final active = await h.manual();
      _expectProtected(_input(active.call));
      final state = _map(_input(active.call)['state']);
      expect(state['valueExists'], isFalse);
      expect(state.containsKey('value'), isFalse);
      final run = await _finishManual(active, _output('runtime-unavailable'));
      expect(run.issues.map((issue) => issue['code']), contains('secret_input_unavailable'));
      expect(await _saved(h), before);
      expect(jsonEncode((await h.engine.readState(h.chatId)).values), contains(_fact));
      expect((await h.engine.readState(h.chatId)).issues.map((issue) => issue['code']), contains('runtime-version'));
    },
  );

  test(
    'portable ledger protection survives declaration removal and an unsupported ledger closes the value carrier',
    () async {
      final h = await _Harness.open();
      await _bind(h);
      final saved = await _saved(h);
      expect(_maps(_map(saved['dshgoSecretRuntime'])['bindings']), hasLength(1));
      final files = await h.engine.exportChat(h.chatId);
      final character = await h.engine.importCard(_card(withSlots: false, hidden: false));
      expect(character.id, isNot(h.characterId));
      h.chatId = (await h.engine.importChats(character.id, files)).chatIds.single;
      await h.engine.setSettings({
        'director': {'secretsEnabled': false},
      });
      final active = await h.manual();
      _expectProtected(_input(active.call));
      expect(_map(_map(_map(_input(active.call)['state'])['value'])['entity']).containsKey('secret'), isFalse);
      expect(_input(active.call)['releasedFacts'], isEmpty);
      await _finishManual(active, _output('ledger-only'));
      expect(jsonEncode((await h.engine.readState(h.chatId)).values), contains(_fact));
      await h.reply('new card no longer marks the ledger path hidden', reason: 'length');
      final body = h.model.ofKind(_main).last.body;
      expect(jsonEncode(body), isNot(contains(_fact)));
      expect(_toolNames(body), isNot(contains('update_state')));
      final broken = _copy(saved)..['dshgoSecretRuntime'] = {'version': 2, 'opaque': 'preserve-ledger'};
      h.chatId = await _importSaved(h, character.id, broken);
      final bad = await h.manual();
      _expectProtected(_input(bad.call));
      expect(_map(_input(bad.call)['state']).containsKey('value'), isFalse);
      final failedClosed = await _finishManual(bad, _output('ledger-unavailable'));
      expect(failedClosed.issues.map((issue) => issue['code']), contains('secret_ledger_unavailable'));
      expect((await _saved(h))['dshgoSecretRuntime'], broken['dshgoSecretRuntime']);
      expect(jsonEncode((await h.engine.readState(h.chatId)).values), contains(_fact));
    },
  );

  test(
    'switching secrets off revokes released knowledge and notes while preserving bound values after reopen',
    () async {
      final h = await _Harness.open();
      await _bind(h);
      final active = await h.manual();
      expect(_input(active.call)['releasedFacts'], ['AUTHORIZED<$_fact>']);
      final known = await _finishManual(active, _output('known', notes: 'ordinary learned $_fact', beat: _beat));
      final source = known.sourceNodeId!;
      final before = _sourceRow(h, source);
      expect((await h.engine.readDirector(h.chatId)).stale, isFalse);
      await h.engine.setSettings({
        'director': {'secretsEnabled': false},
      });
      final disabled = await h.engine.readDirector(h.chatId);
      expect(disabled.latestSuccess!.id, known.id);
      expect(disabled.stale, isTrue);
      expect(disabled.issues.map((issue) => issue['code']), contains('director_secret_knowledge_changed'));
      await h.reopen();
      expect((await h.engine.readDirector(h.chatId)).stale, isTrue);
      expect(_sourceRow(h, source), before);
      final ordinary = await h.manual();
      _expectProtected(_input(ordinary.call));
      expect(_input(ordinary.call)['releasedFacts'], isEmpty);
      expect(_input(ordinary.call)['previousNotes'], '');
      expect(jsonEncode(ordinary.call.body), isNot(contains(_fact)));
      await _finishManual(ordinary, _output('after-revocation'));
      expect(jsonEncode((await h.engine.readState(h.chatId)).values), contains(_fact));
      expect(await h.runs('director.secret_bind'), hasLength(1));
    },
  );

  test(
    'descendant release revocation leaves the old source intact and blocks notes beat prefetch and events',
    () async {
      final h = await _Harness.open(events: true);
      await h.engine.addCharacterBookEntry(h.characterId, {
        'keys': ['NEVER-MATCH-PREFETCH-KEY'],
        'comment': 'known reference',
        'content': _prefetch,
      });
      await _bind(h);
      await h.engine.setSettings({
        'director': {'every': 1000},
      });
      final first = await h.manual();
      expect(_input(first.call)['releasedFacts'], ['AUTHORIZED<$_fact>']);
      final reference = _map(_maps(_input(first.call)['catalog']).single['reference']);
      final knowledge = _output(
        'knowledge',
        notes: 'ordinary learned $_fact',
        beat: _beat,
        prefetch: [reference],
        events: [
          {'name': 'fixed', 'data': 'proposal from authorized knowledge'},
        ],
      );
      await _finishManual(first, knowledge);
      await h.engine.sendOnly(h.chatId, 'same-knowledge descendant');
      expect((await h.engine.readDirector(h.chatId)).stale, isFalse);
      final inherited = await h.manual();
      expect(_input(inherited.call)['previousNotes'], 'ordinary learned $_fact');
      final known = await _finishManual(inherited, knowledge);
      final source = known.sourceNodeId!;
      final before = _sourceRow(h, source);
      // Positive control: the old source remains eligible through a descendant;
      // the same real beat, catalog reference and fixed event rule all execute.
      final allowed = await h.start(h.engine.send(h.chatId, 'authorized descendant'));
      final allowedWire = jsonEncode(allowed.call.body);
      expect(allowedWire, contains(_beat));
      expect(allowedWire, contains(_prefetch));
      expect(allowedWire, contains('AUTHORIZED<$_fact>'));
      await h.complete(allowed, 'authorized response');
      expect(_map((await h.engine.readState(h.chatId)).values)['count'], 1);
      expect((await h.engine.readDirector(h.chatId)).stale, isFalse);
      // Return to the unchanged source before making the revoked descendant.
      // Its event is still unconsumed: deduplication cannot explain a no-op.
      await h.engine.selectNode(h.chatId, source);
      expect(_map((await h.engine.readState(h.chatId)).values)['count'], 0);
      expect((await h.engine.readDirector(h.chatId)).eventRules!['consumed'], isEmpty);
      final descendant = await h.engine.sendOnly(h.chatId, 'different disclosure context');
      final edit = await h.engine.setStateValue(h.chatId, '/reveal', false, expectedNodeId: descendant.nodeId);
      expect(edit.applied, isTrue);
      expect(_sourceRow(h, source), before);
      final revoked = await h.engine.readDirector(h.chatId);
      expect(revoked.latestSuccess!.id, known.id);
      expect(revoked.stale, isTrue);
      expect(revoked.issues.map((issue) => issue['code']), contains('director_secret_knowledge_changed'));
      expect(revoked.issues.map((issue) => issue['code']), isNot(contains('director_source_changed')));
      final blocked = await h.start(h.engine.send(h.chatId, 'context after revocation'));
      final blockedWire = jsonEncode(blocked.call.body);
      for (final text in [_fact, _beat, _prefetch]) {
        expect(blockedWire, isNot(contains(text)), reason: text);
      }
      final message = await h.complete(blocked, 'response without old knowledge');
      final inspection = (await h.engine.inspectTurn(h.chatId, nodeId: message.nodeId))!;
      expect(inspection.director['eligible'], isFalse);
      expect(_map(inspection.director['beat'])['offered'], isFalse);
      expect(inspection.director['prefetch'], isEmpty);
      expect(_map((await h.engine.readState(h.chatId)).values)['count'], 0);
      expect((await h.engine.readDirector(h.chatId)).eventRules!['consumed'], isEmpty);
      final ordinary = await h.manual();
      expect(_input(ordinary.call)['previousNotes'], '');
      expect(_input(ordinary.call)['releasedFacts'], isEmpty);
      expect(jsonEncode(ordinary.call.body), isNot(contains(_fact)));
      await _finishManual(ordinary, _output('revoked-descendant'));
      expect(_sourceRow(h, source), before);
    },
  );

  test('a queued ordinary source intersects its release with the current descendant before sending', () async {
    final h = await _Harness.open();
    await _bind(h);
    final held = await h.manual();
    expect(_input(held.call)['releasedFacts'], ['AUTHORIZED<$_fact>']);
    final source = await h.engine.sendOnly(h.chatId, 'queued ordinary source still authorizes disclosure');
    final queued = h.engine.runDirector(h.chatId);
    expect((await h.engine.readDirector(h.chatId)).pendingJobs, 2);
    final before = _sourceRow(h, source.nodeId);
    final current = await h.engine.sendOnly(h.chatId, 'new current descendant');
    expect((await h.engine.setStateValue(h.chatId, '/reveal', false, expectedNodeId: current.nodeId)).applied, isTrue);
    expect(_sourceRow(h, source.nodeId), before);
    await _finishManual(held, _output('held', notes: 'ordinary learned $_fact'));
    final ordinary = await h.next(_direct);
    expect(_maps(_input(ordinary)['recent']).last['nodeId'], source.nodeId);
    expect(_map(_map(_input(ordinary)['state'])['value'])['reveal'], isTrue);
    expect(_input(ordinary)['releasedFacts'], isEmpty);
    expect(_input(ordinary)['previousNotes'], '');
    expect(jsonEncode(ordinary.body), isNot(contains(_fact)));
    await ordinary.tool(_direct, _output('queued-after-revocation'));
    expect((await queued).success, isTrue);
    expect(_sourceRow(h, source.nodeId), before);
  });
}

_Json _map(Object? value) => value! as _Json;
List<_Json> _maps(Object? value) => (value! as List<Object?>).map(_map).toList();
_Json _copy(_Json value) => _map(jsonDecode(jsonEncode(value)));
_Json _input(_Call call) => _map(jsonDecode(_maps(call.body['messages']).last['content']! as String));
List<String> _toolNames(_Json body) => [
  for (final tool in body['tools'] as List<Object?>? ?? const []) _map(_map(tool)['function'])['name']! as String,
];

void _expectProtected(_Json input) {
  final card = _map(input['card']);
  expect(card.containsKey('stateDefinition'), isFalse);
  expect(_map(card['director']).containsKey('secretSlots'), isFalse);
  expect(jsonEncode(input), isNot(contains(_fact)));
}

_Json _output(
  String label, {
  String? notes,
  String? beat,
  List<_Json> prefetch = const [],
  List<_Json> events = const [],
}) => {
  'notes': notes ?? '$label notes',
  'beat': beat ?? '',
  'prefetch': prefetch,
  'suggestions': [
    for (var i = 0; i < 3; i++) {'text': '$label choice $i', 'risk': ''},
  ],
  'events': events,
};
_Json _proposal() => {
  'notes': _privateNotes,
  'facts': [
    {'slotId': 'identity', 'value': _fact},
  ],
};
_Json _value({String? fact}) => {
  'entity': {'id': 'entity-A', 'secret': ?fact},
  'reveal': true,
  'count': 0,
};

Uint8List _card({bool arraySlot = false, bool withSlots = true, bool hidden = true, bool events = false}) {
  final raw = _map(jsonDecode(utf8.decode(t24Card())));
  final leaf = <String, Object?>{
    'type': 'string',
    'x-dsh-hidden': hidden,
    'x-dsh-by': ['user', 'rules'],
  };
  final entity = <String, Object?>{
    'type': 'object',
    'additionalProperties': false,
    'required': ['id'],
    'properties': {
      'id': {'type': 'string'},
      'secret': leaf,
    },
  };
  final state = <String, Object?>{
    'schema': {
      'type': 'object',
      'additionalProperties': false,
      'required': [arraySlot ? 'items' : 'entity', 'reveal', 'count'],
      'properties': {
        if (arraySlot) 'items': {'type': 'array', 'items': entity} else 'entity': entity,
        'reveal': {'type': 'boolean'},
        'count': {'type': 'integer', 'minimum': 0, 'maximum': 100, 'x-dsh-step': 100},
      },
    },
    'init': arraySlot
        ? {
            'items': [
              {'id': 'entity-A', 'secret': _fact},
            ],
            'reveal': true,
            'count': 0,
          }
        : _value(),
  };
  _map(raw['data'])['extensions'] = {
    'dshgo': {
      'v': 1,
      'state': state,
      'director': {
        'secretsEnabled': true,
        if (withSlots)
          'secretSlots': {
            'v': 1,
            'slots': [
              {
                'id': 'identity',
                'path': arraySlot ? '/items/0/secret' : '/entity/secret',
                'entityPath': arraySlot ? '/items/0/id' : '/entity/id',
                'unbound': {'exists': false},
                'bindWhen': true,
                'release': {
                  'id': 'identity-release',
                  'audience': 'currentCharacter',
                  'when': {'var': 'reveal'},
                  'template': 'AUTHORIZED<{{fact}}>',
                },
              },
            ],
          },
        if (events)
          'eventRules': {
            'v': 1,
            'rules': [
              {
                'id': 'fixed-increment',
                'name': 'fixed',
                'when': true,
                'once': false,
                'do': [
                  {
                    'type': 'state',
                    'ops': [
                      {'op': 'add', 'path': '/count', 'value': 1, 'why': 'authorized event'},
                    ],
                  },
                ],
              },
            ],
          },
      },
    },
  };
  return Uint8List.fromList(utf8.encode(jsonEncode(raw)));
}

Future<TavernDirectorRun> _finishManual(_Manual active, _Json output) async {
  await active.call.tool(_direct, output);
  final result = await active.result.timeout(_deadline);
  expect(result.success, isTrue, reason: result.failure);
  return result;
}

Future<TavernDirectorSnapshot> _idle(_Harness h) =>
    h.engine.watchDirector(h.chatId).firstWhere((snapshot) => snapshot.pendingJobs == 0).timeout(_deadline);

Future<TavernDirectorSnapshot> _idleWithoutAnotherHelper(_Harness h) => Future.any([
  _idle(h),
  for (final kind in [_direct, _secret])
    h.model.next(kind).then<TavernDirectorSnapshot>((_) {
      throw TestFailure('A revoked queued $kind job reached the provider.');
    }),
]);

Future<void> _bind(_Harness h) async {
  await h.enable();
  await h.reply('proposal source');
  await (await h.next(_direct)).tool(_direct, _output('before-binding'));
  final secret = await h.next(_secret);
  final idle = _idle(h);
  await secret.tool(_secret, _proposal());
  await idle;
  expect(await h.runs('director.secret_bind'), isEmpty);
  // The next real main admission creates B. A non-normal main terminal avoids
  // scheduling another helper without disabling binding or the release gate.
  await h.reply('descendant after binding', reason: 'length');
  expect((await h.runs('director.secret_bind')).single.result['committed'], isTrue);
  expect(_map(_map((await h.engine.readState(h.chatId)).values)['entity'])['secret'], _fact);
}

Future<_Json> _saved(_Harness h) async {
  final file = (await h.engine.exportChat(h.chatId)).single;
  final document = StChatDocument.decode(file.fileName, file.bytes);
  return _map(_map(_map(document.messages.last['extra'])['dshgo'])['tavernState']);
}

Future<String> _importSaved(_Harness h, String characterId, _Json saved) async {
  const name = 'secret-protection.jsonl';
  final document = StChatDocument(
    fileName: name,
    header: {'user_name': 'User', 'character_name': 'Guide', 'chat_metadata': <String, Object?>{}},
    messages: [
      {
        'name': 'Guide',
        'is_user': false,
        'is_system': false,
        'mes': 'imported protection source',
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

_Json _sourceRow(_Harness h, String nodeId) {
  final db = sqlite3.open('${h.root.path}/tavern.sqlite3');
  try {
    // selected_child_id legitimately changes when a descendant is appended.
    // Body/visibility/parent and both saved-state carriers authenticate source.
    return {
      'node': Map<String, Object?>.from(
        db.select('SELECT parent_id, role, speaker, text, reasoning, hidden, extra, original FROM nodes WHERE id = ?', [
          nodeId,
        ]).single,
      ),
      'state': [
        for (final row in db.select('SELECT delta_json, full_json FROM node_states WHERE node_id = ?', [nodeId]))
          Map<String, Object?>.from(row),
      ],
    };
  } finally {
    db.close();
  }
}

class _Harness {
  _Harness(this.root);
  final Directory root;
  final model = _Model();
  final config = TavernModelConfig(
    apiKey: () async => 'fixture-only',
    baseUrl: 'https://fixture.invalid/v1',
    model: 'main-reasoner',
    deepseek: true,
    thinking: false,
  );
  late TavernEngine engine;
  late String characterId;
  late String chatId;

  static Future<_Harness> open({bool arraySlot = false, bool events = false}) async {
    final h = _Harness(await Directory.systemTemp.createTemp('dsh-t18-secrets-director-'));
    h.engine = await TavernEngine.openDirectory(
      h.root,
      config: h.config,
      modelClient: h.model,
      clock: () => T24Harness.at,
      random: () => 0.25,
    );
    addTearDown(h.dispose);
    await h.engine.setPreset(t24Preset());
    final character = await h.engine.importCard(_card(arraySlot: arraySlot, events: events));
    h.characterId = character.id;
    h.chatId = await h.engine.createChat(character.id);
    return h;
  }

  Future<void> enable() => engine.setSettings({
    'director': {'enabled': true, 'secretsEnabled': true, 'every': 1},
  });
  Future<List<TavernAgentRun>> runs(String kind) async =>
      (await engine.readAgentRuns(chatId, limit: 1000)).where((run) => run.kind == kind).toList();

  Future<_Call> next(String kind) async {
    final call = await model.next(kind).timeout(_deadline);
    await call.listening.future.timeout(_deadline);
    return call;
  }

  Future<_Manual> manual() async {
    final result = engine.runDirector(chatId);
    final call = await Future.any<_Call>([
      next(_direct),
      result.then<_Call>((run) {
        throw TestFailure('Director ended before provider input: ${run.failure}');
      }),
    ]);
    return (call: call, result: result);
  }

  Future<_Main> start(Stream<TavernEvent> stream) async {
    final events = T24Events(stream);
    final call = await Future.any<_Call>([
      next(_main),
      events.done.future.then<_Call>((_) {
        throw TestFailure('Main ended before provider input: ${events.values}');
      }),
    ]);
    return (call: call, events: events);
  }

  Future<TavernMessage> complete(_Main active, String text, {String reason = 'stop'}) async {
    active.call.add(ModelText(text));
    await active.call.finish(reason);
    await active.events.done.future.timeout(_deadline);
    expect(active.events.values.whereType<TavernTurnFailed>(), isEmpty);
    return active.events.values.whereType<TavernTurnDone>().single.message;
  }

  Future<TavernMessage> reply(String text, {String reason = 'stop'}) async =>
      complete(await start(engine.send(chatId, 'ordinary user line')), text, reason: reason);

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
    for (final call in model.calls) {
      unawaited(call.close());
    }
    try {
      await engine.close();
    } finally {
      for (final call in model.calls) {
        await call.close();
      }
      if (await root.exists()) await root.delete(recursive: true);
    }
  }
}

class _Model extends TavernModelClient {
  final calls = <_Call>[];
  final _ready = {
    for (final kind in [_main, _direct, _secret]) kind: Queue<_Call>(),
  };
  final _waiting = {
    for (final kind in [_main, _direct, _secret]) kind: Queue<Completer<_Call>>(),
  };
  List<_Call> ofKind(String kind) => calls.where((call) => call.kind == kind).toList();
  List<_Call> get helpers => calls.where((call) => call.kind != _main).toList();

  Future<_Call> next(String kind) {
    if (_ready[kind]!.isNotEmpty) return Future.value(_ready[kind]!.removeFirst());
    final ready = Completer<_Call>();
    _waiting[kind]!.add(ready);
    return ready.future;
  }

  @override
  Stream<ModelDelta> generate({
    required TavernModelConfig config,
    required _Json body,
    required ModelCancellation cancellation,
    void Function(int attempt)? onRequestStarted,
  }) {
    final names = _toolNames(body);
    final kind = names.contains(_secret)
        ? _secret
        : names.contains(_direct)
        ? _direct
        : _main;
    final call = _Call(config, _copy(body), cancellation, kind);
    calls.add(call);
    if (_waiting[kind]!.isNotEmpty) {
      _waiting[kind]!.removeFirst().complete(call);
    } else {
      _ready[kind]!.add(call);
    }
    return call.stream;
  }
}

class _Call {
  _Call(this.config, this.body, this.cancellation, this.kind) {
    _source = StreamController<ModelDelta>(sync: true, onListen: listening.complete);
  }
  final TavernModelConfig config;
  final _Json body;
  final ModelCancellation cancellation;
  final String kind;
  final listening = Completer<void>();
  late final StreamController<ModelDelta> _source;
  Stream<ModelDelta> get stream => _source.stream;
  void add(ModelDelta delta) {
    _source.add(delta);
  }

  void fragment(String name, _Json output, {int index = 0}) => add(
    ModelToolFragment(index: index, id: '$name-$index', type: 'function', name: name, arguments: jsonEncode(output)),
  );
  Future<void> tool(String name, _Json output) {
    fragment(name, output);
    return finish('tool_calls');
  }

  Future<void> finish([String reason = 'stop']) {
    add(ModelFinished(reason));
    return close();
  }

  Future<void> close() => _source.close();
}

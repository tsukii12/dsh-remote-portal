import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import 'support/t24_engine_harness.dart';

// Real facade, character/persona files, source tree, SQLite and assembly. Only
// model output, clock and random use the existing deterministic harness.
const _secret = 'T18-HIDDEN-SECRET';
const _outline = 'T18-PRIVATE-OUTLINE';
const _notes = 'T18-PRIVATE-NOTES';
Map<String, Object?> _map(Object? value) => value! as Map<String, Object?>;

Map<String, Object?> _output({
  String notes = _notes,
  String beat = 'T18-NEXT-BEAT',
  List<Map<String, Object?>> events = const [],
}) => {
  'notes': notes,
  'beat': beat,
  'prefetch': <Object?>[],
  'suggestions': [
    for (var i = 0; i < 3; i++) {'text': 'choice-$i', 'risk': ''},
  ],
  'events': events,
};

Future<T24Harness> _open() async {
  final h = await T24Harness.open(thinking: false);
  addTearDown(h.dispose);
  return h;
}

Future<({String chat, String character})> _stateChat(T24Harness h) async {
  final raw = _map(jsonDecode(utf8.decode(t24Card())));
  _map(raw['data'])['extensions'] = {
    'dshgo': {
      'v': 1,
      'story': {'outline': _outline},
      'state': {
        'schema': {
          'type': 'object',
          'additionalProperties': false,
          'required': ['public', 'secret'],
          'properties': {
            'public': {'type': 'integer', 'default': 0},
            'secret': {
              'type': 'string',
              'default': _secret,
              'x-dsh-hidden': true,
              'description': 'T18-HIDDEN-SCHEMA',
              'x-dsh-by': ['user', 'rules'],
            },
          },
        },
        'init': {'public': 0, 'secret': _secret},
      },
    },
  };
  final card = await h.engine.importCard(Uint8List.fromList(utf8.encode(jsonEncode(raw))));
  return (chat: await h.engine.createChat(card.id), character: card.id);
}

T _db<T>(T24Harness h, T Function(Database) action) {
  final db = sqlite3.open('${h.root.path}/tavern.sqlite3');
  try {
    return action(db);
  } finally {
    db.close();
  }
}

Map<String, Object?> _storyRows(T24Harness h) => _db(
  h,
  (db) => {
    for (final table in ['chats', 'nodes', 'node_states', 'summaries', 'memories'])
      table: [for (final row in db.select('SELECT * FROM $table ORDER BY rowid')) Map<String, Object?>.from(row)],
  },
);

Future<({T24Call call, Future<TavernDirectorRun> result})> _start(T24Harness h, String chat) async {
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

Future<TavernDirectorRun> _finish(
  ({T24Call call, Future<TavernDirectorRun> result}) started,
  Map<String, Object?> output,
) async {
  started.call.add(
    ModelToolFragment(index: 0, id: 'direct-call', type: 'function', name: 'direct', arguments: jsonEncode(output)),
  );
  await started.call.finish('tool_calls');
  final result = await started.result;
  expect(result.success, isTrue, reason: result.failure);
  return result;
}

Future<TavernDirectorRun> _direct(T24Harness h, String chat, {Map<String, Object?>? output}) async =>
    _finish(await _start(h, chat), output ?? _output());

Map<String, Object?> _input(T24Call call) =>
    _map(jsonDecode(_map((call.body!['messages']! as List<Object?>).last)['content']! as String));

Future<({TavernMessage message, T24Call call})> _main(T24Harness h, String chat) async {
  final call = h.model.prepare();
  final events = T24Events(h.engine.send(chat, 'next user line'));
  await Future.any<void>([
    call.listening.future,
    events.done.future.then<void>((_) {
      throw TestFailure('Main turn ended before model input: ${events.values}');
    }),
  ]);
  call.add(const ModelText('next main body'));
  await call.finish();
  await events.done.future;
  expect(events.values.whereType<TavernTurnFailed>(), isEmpty);
  return (message: events.values.whereType<TavernTurnDone>().single.message, call: call);
}

void main() {
  test(
    'helper input uses saved hidden state story latest twelve bodies and newest twenty eligible summaries',
    () async {
      final h = await _open();
      final context = await _stateChat(h);
      for (var i = 0; i < 14; i++) {
        await h.engine.sendOnly(context.chat, 'visible-$i');
      }
      final path = await h.engine.path(context.chat);
      final foreign = (await h.engine.path(h.chatId)).single.nodeId;
      _db(h, (db) {
        db.execute('UPDATE nodes SET reasoning = ? WHERE id = ?', ['T18-PRIVATE-REASONING', path.last.nodeId]);
        for (var i = 0; i < 25; i++) {
          db.execute(
            'INSERT INTO summaries(id,chat_id,from_node_id,to_node_id,text,manually_edited) VALUES(?,?,?,?,?,1)',
            [
              's-$i',
              context.chat,
              path.first.nodeId,
              path.last.nodeId,
              'summary-$i {{incvar::summaryMustStayLiteral}}',
            ],
          );
        }
        db.execute(
          'INSERT INTO summaries(id,chat_id,from_node_id,to_node_id,text,manually_edited) VALUES(?,?,?,?,?,1)',
          ['foreign', context.chat, foreign, path.last.nodeId, 'T18-FOREIGN-SUMMARY'],
        );
      });
      final before = _storyRows(h);
      final started = await _start(h, context.chat);
      final input = _input(started.call);
      expect(_map(input['card'])['story'], {'outline': _outline});
      expect(_map(_map(input['state'])['value'])['secret'], _secret);
      final recent = (input['recent']! as List<Object?>).map(_map).toList();
      expect(recent, hasLength(12));
      expect(recent.first['text'], 'visible-2');
      expect(recent.last['text'], 'visible-13');
      final summaries = (input['summaries']! as List<Object?>).map(_map).toList();
      expect(summaries, hasLength(20));
      expect(summaries.first['id'], 's-5');
      expect(summaries.last['id'], 's-24');
      expect(jsonEncode(input), contains('{{incvar::summaryMustStayLiteral}}'));
      expect(jsonEncode(input), isNot(contains('T18-PRIVATE-REASONING')));
      expect(jsonEncode(input), isNot(contains('T18-FOREIGN-SUMMARY')));
      final run = await _finish(started, _output());
      expect(run.issues.any((issue) => issue['code'] == 'summary_catalog_truncated'), isTrue);
      expect(_storyRows(h), before);
    },
  );

  test(
    'next main whole body excludes private fields and retains literal sanitized beat without macro effects',
    () async {
      final h = await _open();
      final context = await _stateChat(h);
      await h.engine.setGlobalVariables({'privateGlobal': 'T18-GLOBAL-SECRET'});
      const literal = '风声 {{incvar::directorMustStayLiteral}}{{getglobalvar::privateGlobal}}';
      final output = _output(
        notes: '$_notes {{incvar::notesMustStayLiteral}}',
        beat: 'User: chooses an answer. $literal',
      );
      (output['suggestions']! as List<Object?>)[0] = {'text': 'T18-PRIVATE-SUGGESTION {{incvar::never}}', 'risk': ''};
      final run = await _direct(h, context.chat, output: output);
      expect(run.beat, ' $literal');
      final main = await _main(h, context.chat);
      final wire = jsonEncode(main.call.body);
      expect(wire, contains(literal));
      for (final secret in [
        _notes,
        _secret,
        _outline,
        'T18-HIDDEN-SCHEMA',
        'T18-GLOBAL-SECRET',
        'T18-PRIVATE-SUGGESTION',
        'User: chooses an answer.',
      ]) {
        expect(wire, isNot(contains(secret)), reason: secret);
      }
      expect(h.engine.variables(context.chat).containsKey('directorMustStayLiteral'), isFalse);
      expect(h.engine.variables(context.chat).containsKey('notesMustStayLiteral'), isFalse);
      final inspection = (await h.engine.inspectTurn(context.chat, nodeId: main.message.nodeId))!;
      expect(_map(inspection.director['beat'])['offered'], isTrue);
      expect(_map(inspection.director['beat'])['finalSourceObserved'], isTrue);
      expect(jsonEncode(inspection.director), isNot(contains(_notes)));
      expect(run.notesSpoiler, isTrue);
    },
  );

  test('normal descendants retain source eligibility while a sibling branch excludes the old beat', () async {
    final h = await _open();
    final root = (await h.engine.path(h.chatId)).single.nodeId;
    final a = await h.engine.sendOnly(h.chatId, 'branch A');
    final run = await _direct(h, h.chatId);
    final descendant = await _main(h, h.chatId);
    expect(jsonEncode(descendant.call.body), contains('T18-NEXT-BEAT'));
    expect((await h.engine.readDirector(h.chatId)).stale, isFalse);
    await h.engine.selectNode(h.chatId, root);
    await h.engine.sendOnly(h.chatId, 'branch B');
    expect((await h.engine.readDirector(h.chatId)).stale, isTrue);
    expect((await h.engine.readDirector(h.chatId)).latestSuccess!.id, run.id);
    final other = await _main(h, h.chatId);
    expect(jsonEncode(other.call.body), isNot(contains('T18-NEXT-BEAT')));
    final inspection = (await h.engine.inspectTurn(h.chatId, nodeId: other.message.nodeId))!;
    expect(inspection.director['eligible'], isFalse);
    await h.engine.selectNode(h.chatId, a.nodeId);
    expect((await h.engine.readDirector(h.chatId)).stale, isFalse);
  });

  test('editing an ancestor outside the twelve sent bodies invalidates its captured source revision', () async {
    final h = await _open();
    final root = (await h.engine.path(h.chatId)).single.nodeId;
    for (var i = 0; i < 14; i++) {
      await h.engine.sendOnly(h.chatId, 'message-$i');
    }
    await _direct(h, h.chatId);
    final watched = h.engine.watchDirector(h.chatId).firstWhere((value) => value.stale);
    await h.engine.edit(h.chatId, root, 'edited old ancestor');
    expect(
      (await watched.timeout(
        const Duration(seconds: 5),
      )).issues.any((issue) => issue['code'] == 'director_source_changed'),
      isTrue,
    );
    final main = await _main(h, h.chatId);
    expect(jsonEncode(main.call.body), isNot(contains('T18-NEXT-BEAT')));
  });

  test('a hidden state edit invalidates the source without revealing the changed secret to the main body', () async {
    final h = await _open();
    final context = await _stateChat(h);
    await _direct(h, context.chat);
    final edit = await h.engine.setStateValue(context.chat, '/secret', 'T18-CHANGED-HIDDEN');
    expect(edit.applied, isTrue);
    expect((await h.engine.readDirector(context.chat)).stale, isTrue);
    final main = await _main(h, context.chat);
    expect(jsonEncode(main.call.body), isNot(contains('T18-NEXT-BEAT')));
    expect(jsonEncode(main.call.body), isNot(contains('T18-CHANGED-HIDDEN')));
  });

  test('deleting the source preserves its original anchor in the result and pending proposals', () async {
    final h = await _open();
    final source = (await h.engine.path(h.chatId)).single.nodeId;
    final run = await _direct(
      h,
      h.chatId,
      output: _output(
        events: [
          {'name': 'proposal', 'data': 'pending only'},
        ],
      ),
    );
    await h.engine.deleteMessage(h.chatId, source);
    final read = await h.engine.readDirector(h.chatId);
    expect(read.stale, isTrue);
    expect(read.latestSuccess!.sourceKind, 'node');
    expect(read.latestSuccess!.sourceNodeId, source);
    final event = (await h.engine.readDirectorEvents(h.chatId)).single;
    expect(event.available, isTrue);
    expect(event.sourceNodeId, source);
    expect(event.status, 'pending');
    expect(
      _db(h, (db) => db.select('SELECT node_id FROM agent_runs WHERE id = ?', [run.id]).single['node_id']),
      isNull,
    );
    await h.reopen();
    expect((await h.engine.readDirector(h.chatId)).stale, isTrue);
    expect((await h.engine.readDirectorEvents(h.chatId)).single.sourceKind, 'node');
  });

  test('an intentional empty source includes saved chat variables and only applies while context is empty', () async {
    final h = await _open();
    final source = (await h.engine.path(h.chatId)).single.nodeId;
    await h.engine.deleteFrom(h.chatId, source);
    _db(
      h,
      (db) => db.execute('UPDATE chats SET variables = ? WHERE id = ?', [
        jsonEncode({'emptySaved': '{{incvar::mustNotRun}}'}),
        h.chatId,
      ]),
    );
    final started = await _start(h, h.chatId);
    expect(_map(_input(started.call)['state'])['variables'], {'emptySaved': '{{incvar::mustNotRun}}'});
    final run = await _finish(started, _output());
    expect(run.sourceKind, 'empty');
    expect(run.sourceNodeId, isNull);
    expect((await h.engine.readDirector(h.chatId)).stale, isFalse);
    final main = await _main(h, h.chatId);
    expect(jsonEncode(main.call.body), contains('T18-NEXT-BEAT'));
    expect((await h.engine.readDirector(h.chatId)).stale, isTrue);
  });

  for (final emptySelection in [false, true]) {
    test('first-root regenerate does not reuse an empty source with empty selection $emptySelection', () async {
      final h = await _open();
      final root = (await h.engine.path(h.chatId)).single.nodeId;
      final deletion = await h.engine.deleteFrom(h.chatId, root);
      final run = await _direct(h, h.chatId);
      expect(run.sourceKind, 'empty');
      expect(await h.engine.undoDeleteFrom(h.chatId, deletion), isTrue);
      if (emptySelection) {
        // A valid persisted empty selected path can retain visible roots, e.g.
        // after a JSONL emptySelectedPath import. Keep that state explicit here.
        _db(
          h,
          (db) =>
              db.execute('UPDATE chats SET selected_root_id = NULL, current_leaf_id = NULL WHERE id = ?', [h.chatId]),
        );
        expect(await h.engine.path(h.chatId), isEmpty);
        expect((await h.engine.readDirector(h.chatId)).stale, isFalse);
      }
      final call = h.model.prepare();
      final events = T24Events(h.engine.regenerate(h.chatId, root));
      await Future.any<void>([
        call.listening.future,
        events.done.future.then<void>((_) {
          throw TestFailure('Regenerate ended before model input: ${events.values}');
        }),
      ]);
      expect(jsonEncode(call.body), isNot(contains('T18-NEXT-BEAT')));
      call.add(const ModelText('new root'));
      await call.finish();
      await events.done.future;
      expect(events.values.whereType<TavernTurnFailed>(), isEmpty);
      final message = events.values.whereType<TavernTurnDone>().single.message;
      final inspection = (await h.engine.inspectTurn(h.chatId, nodeId: message.nodeId))!;
      expect(inspection.contextNodeId, isNull);
      expect(inspection.director['eligible'], isFalse);
      expect(jsonEncode(inspection.director), contains('director_source_not_on_path'));
    });
  }

  test('invalid empty-node anchors mismatched kinds and future successes are unavailable without repair', () async {
    final h = await _open();
    final run = await _direct(h, h.chatId);
    final saved =
        _db(h, (db) => db.select('SELECT result_json FROM agent_runs WHERE id = ?', [run.id]).single['result_json'])!
            as String;
    for (final patch in <Map<String, Object?>>[
      {'sourceKind': 'empty'},
      {'success': false},
      {'version': 99},
      {'allowedReferences': null},
    ]) {
      final changed = {..._map(jsonDecode(saved)), ...patch};
      final raw = jsonEncode(changed);
      _db(h, (db) => db.execute('UPDATE agent_runs SET result_json = ? WHERE id = ?', [raw, run.id]));
      final read = await h.engine.readDirector(h.chatId);
      expect(read.latestSuccess, isNull);
      expect(read.stale, isTrue);
      expect(read.issues.any((issue) => issue['code'] == 'saved_director_run_unavailable'), isTrue);
      final main = await _main(h, h.chatId);
      expect(jsonEncode(main.call.body), isNot(contains('T18-NEXT-BEAT')));
      expect(
        _db(h, (db) => db.select('SELECT result_json FROM agent_runs WHERE id = ?', [run.id]).single['result_json']),
        raw,
      );
    }
    _db(h, (db) => db.execute('UPDATE agent_runs SET result_json = ? WHERE id = ?', [saved, run.id]));
    expect((await h.engine.readDirector(h.chatId)).latestSuccess!.id, run.id);
    expect((await h.engine.readDirector(h.chatId)).stale, isFalse);
  });

  test('bad and future event rows remain explicit usable cursors next to valid proposals', () async {
    final h = await _open();
    final run = await _direct(
      h,
      h.chatId,
      output: _output(
        events: [
          {'name': 'first', 'data': 'literal {{incvar::noEventExecution}}'},
          {'name': 'second', 'data': '{"op":"set","path":"/secret"}'},
        ],
      ),
    );
    _db(h, (db) {
      for (final row in [('bad-json', '{"x":1e999}'), ('future', '{"version":99}')]) {
        db.execute('INSERT INTO agent_runs(id,chat_id,kind,at,result_json) VALUES(?,?,?,?,?)', [
          row.$1,
          h.chatId,
          'director.event',
          T24Harness.at.millisecondsSinceEpoch,
          row.$2,
        ]);
      }
    });
    final before = _db(
      h,
      (db) => [for (final row in db.select('SELECT * FROM agent_runs ORDER BY rowid')) Map<String, Object?>.from(row)],
    );
    final first = await h.engine.readDirectorEvents(h.chatId, limit: 2);
    expect(first.map((event) => event.id), ['future', 'bad-json']);
    for (final event in first) {
      expect(event.available, isFalse);
      expect(event.status, 'unavailable');
      expect(event.unavailableReason, 'invalid_or_unsupported_saved_director_event');
      expect(event.name, isNull);
      expect(event.data, isNull);
      expect(event.runId, isNull);
    }
    final next = await h.engine.readDirectorEvents(h.chatId, beforeEventId: first.last.id, limit: 2);
    expect(next.map((event) => event.name), ['second', 'first']);
    expect(next.every((event) => event.available && event.runId == run.id), isTrue);
    expect(next.last.data, 'literal {{incvar::noEventExecution}}');
    expect(h.engine.variables(h.chatId).containsKey('noEventExecution'), isFalse);
    expect(
      _db(
        h,
        (db) => [
          for (final row in db.select('SELECT * FROM agent_runs ORDER BY rowid')) Map<String, Object?>.from(row),
        ],
      ),
      before,
    );
    expect((await h.engine.readDirector(h.chatId)).latestAttempt!.id, run.id);
  });

  test('run output issues and inspection director documents are detached at construction and each read', () async {
    final h = await _open();
    final run = await _direct(h, h.chatId, output: _output(beat: 'User: does something. wind'));
    final original = run.output;
    run.output!.clear();
    run.suggestions.first['text'] = 'changed';
    run.issues.clear();
    expect(run.output, original);
    expect(run.suggestions.first['text'], 'choice-0');
    expect(run.issues, isNotEmpty);
    final main = await _main(h, h.chatId);
    final inspection = (await h.engine.inspectTurn(h.chatId, nodeId: main.message.nodeId))!;
    final json = _map(jsonDecode(jsonEncode(inspection.toJson())));
    final restored = TavernTurnInspection.fromJson(json);
    _map(json['director']).clear();
    expect(restored.director['runId'], run.id);
    expect(restored.toJson()['director'], inspection.toJson()['director']);
    final read = await h.engine.readDirector(h.chatId);
    read.issues.add({'caller': 'changed'});
    read.latestSuccess!.output!.clear();
    expect((await h.engine.readDirector(h.chatId)).issues, isEmpty);
    expect((await h.engine.readDirector(h.chatId)).latestSuccess!.output, original);
  });

  test('character and persona edits notify stale watchers and a later run uses the new inputs', () async {
    final h = await _open();
    final persona = await h.engine.createPersona(name: 'Player', description: 'before');
    await h.engine.setDefaultPersona(persona.id);
    await _direct(h, h.chatId);
    final cardChanged = h.engine.watchDirector(h.chatId).firstWhere((value) => value.stale);
    await h.engine.updateCharacterFields(h.characterId, {'description': 'new description'});
    expect((await cardChanged.timeout(const Duration(seconds: 5))).stale, isTrue);
    await _direct(h, h.chatId);
    final personaChanged = h.engine.watchDirector(h.chatId).firstWhere((value) => value.stale);
    await h.engine.updatePersona(persona.id, description: 'after');
    expect((await personaChanged.timeout(const Duration(seconds: 5))).stale, isTrue);
    final started = await _start(h, h.chatId);
    expect(_map(_input(started.call)['card'])['description'], 'new description');
    expect(_map(_input(started.call)['persona'])['description'], 'after');
    await _finish(started, _output());
    final defaultChanged = h.engine.watchDirector(h.chatId).firstWhere((value) => value.stale);
    await h.engine.setDefaultPersona(null);
    expect((await defaultChanged.timeout(const Duration(seconds: 5))).stale, isTrue);
  });

  test('manual admission after a card edit does not reuse an already loaded older-card job', () async {
    final h = await _open();
    final first = await _start(h, h.chatId);
    expect(_map(_input(first.call)['card'])['description'], '');
    await h.engine.updateCharacterFields(h.characterId, {'description': 'changed while helper active'});
    final secondCall = h.model.prepare();
    final secondResult = h.engine.runDirector(h.chatId);
    expect((await h.engine.readDirector(h.chatId)).pendingJobs, 2);
    final firstRun = await _finish(first, _output(notes: 'older'));
    await secondCall.listening.future;
    expect(_map(_input(secondCall)['card'])['description'], 'changed while helper active');
    expect(_input(secondCall)['previousNotes'], 'older');
    final secondRun = await _finish((call: secondCall, result: secondResult), _output(notes: 'newer'));
    expect(secondRun.id, isNot(firstRun.id));
    expect((await h.engine.readDirector(h.chatId)).latestSuccess!.id, secondRun.id);
    expect((await h.engine.readDirector(h.chatId)).stale, isFalse);
  });

  test('input exceeding one MiB fails before model dispatch and keeps the prior success readable', () async {
    final h = await _open();
    final previous = await _direct(h, h.chatId);
    final generated = h.model.generated;
    await h.engine.updateCharacterFields(h.characterId, {'description': 'x' * (1024 * 1024 + 1)});
    final run = await h.engine.runDirector(h.chatId);
    expect(run.success, isFalse);
    expect(run.failure, 'contextTooLong:director_input_limit');
    expect(h.model.generated, generated);
    final read = await h.engine.readDirector(h.chatId);
    expect(read.pendingJobs, 0);
    expect(read.latestSuccess!.id, previous.id);
    expect(read.latestAttempt!.id, run.id);
  });

  test('provider failure text cannot copy private input into the persistent failure record', () async {
    final h = await _open();
    final started = await _start(h, h.chatId);
    started.call.fail(TavernFailure.server, 'PROVIDER-ECHO-SECRET key=PRIVATE-KEY');
    final run = await started.result;
    expect(run.success, isFalse);
    expect(run.failure, 'server:director_model_failed');
    final raw =
        _db(h, (db) => db.select('SELECT result_json FROM agent_runs WHERE id = ?', [run.id]).single['result_json'])!
            as String;
    expect(raw, isNot(contains('PROVIDER-ECHO-SECRET')));
    expect(raw, isNot(contains('PRIVATE-KEY')));
    expect((await h.engine.readDirector(h.chatId)).pendingJobs, 0);
  });
}

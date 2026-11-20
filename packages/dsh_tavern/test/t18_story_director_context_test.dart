import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import 'support/t24_engine_harness.dart';

typedef Json = Map<String, Object?>;
typedef _ActiveDirector = ({T24Call call, Future<TavernDirectorRun> result});

const _outline = 'T18B-PRIVATE-OUTLINE';
const _goal = 'T18B-PRIVATE-GOAL';
const _endingTitle = 'T18B-UNREVEALED-ENDING';
const _notes = 'T18B-PRIVATE-NOTES';
const _beat = 'T18B-CAPTURED-BEAT';

Json _map(Object? value) => value! as Json;

Json _story({Object? when = false, List<Json> endings = const []}) => {
  'outline': _outline,
  'acts': [
    {'id': 'a', 'title': 'A', 'goal': _goal, 'when': when, 'minTurns': 0},
    {'id': 'b', 'title': 'B', 'goal': 'T18B-PRIVATE-NEXT-GOAL', 'when': false},
  ],
  'tension': [3, 7.5],
  'endings': endings,
};

Json _output({String beat = _beat}) => {
  'notes': _notes,
  'beat': beat,
  'prefetch': <Object?>[],
  'suggestions': [
    for (var i = 0; i < 3; i++) {'text': 'Choice $i', 'risk': ''},
  ],
  'events': <Object?>[],
};

Future<T24Harness> _open() async {
  final h = await T24Harness.open(thinking: false);
  addTearDown(h.dispose);
  // Settle real main turns without scheduling additional uncontrolled helpers.
  await h.engine.setSettings({
    'director': {'enabled': true, 'every': 1000},
  });
  return h;
}

Future<({String chat, String character})> _storyChat(T24Harness h, Json story) async {
  final raw = _map(jsonDecode(utf8.decode(t24Card())));
  _map(raw['data'])['extensions'] = {
    'dshgo': {'v': 1, 'story': story},
  };
  final character = await h.engine.importCard(Uint8List.fromList(utf8.encode(jsonEncode(raw))));
  return (chat: await h.engine.createChat(character.id), character: character.id);
}

Future<_ActiveDirector> _startDirector(T24Harness h, String chat) async {
  final call = h.model.prepare();
  final result = h.engine.runDirector(chat);
  await Future.any<void>([
    call.listening.future,
    result.then<void>((value) {
      throw TestFailure('Director completed before model input: ${value.failure}');
    }),
  ]);
  return (call: call, result: result);
}

Future<TavernDirectorRun> _finishDirector(_ActiveDirector active, {String beat = _beat}) async {
  active.call.add(
    ModelToolFragment(
      index: 0,
      id: 'direct-call',
      type: 'function',
      name: 'direct',
      arguments: jsonEncode(_output(beat: beat)),
    ),
  );
  await active.call.finish('tool_calls');
  final result = await active.result;
  expect(result.success, isTrue, reason: result.failure);
  return result;
}

Json _input(T24Call call) =>
    _map(jsonDecode(_map((call.body!['messages']! as List<Object?>).last)['content']! as String));

Future<({TavernMessage message, T24Call call})> _main(T24Harness h, String chat, String text) async {
  final call = h.model.prepare();
  final events = T24Events(h.engine.send(chat, 'next question'));
  await Future.any<void>([
    call.listening.future,
    events.done.future.then<void>((_) {
      throw TestFailure('Main completed before model input: ${events.values}');
    }),
  ]);
  call.add(ModelText(text));
  await call.finish();
  await events.done.future;
  expect(events.values.whereType<TavernTurnFailed>(), isEmpty);
  return (message: events.values.whereType<TavernTurnDone>().single.message, call: call);
}

T _db<T>(T24Harness h, T Function(Database) action) {
  final db = sqlite3.open('${h.root.path}/tavern.sqlite3');
  try {
    return action(db);
  } finally {
    db.close();
  }
}

String _runJson(T24Harness h, String id) =>
    _db(h, (db) => db.select('SELECT result_json FROM agent_runs WHERE id = ?', [id]).single['result_json']! as String);

List<Json> _nodeExtras(T24Harness h, String chat) => _db(
  h,
  (db) => [
    for (final row in db.select('SELECT id, extra FROM nodes WHERE chat_id = ? ORDER BY rowid', [chat]))
      Map<String, Object?>.from(row),
  ],
);

List<Object?> _codes(TavernDirectorSnapshot snapshot) => snapshot.issues.map((issue) => issue['code']).toList();

void main() {
  test('helper gets initial and saved story progress while private declarations stay out of main', () async {
    final h = await _open();
    final declaration = _story(
      endings: [
        {'id': 'e', 'title': _endingTitle, 'when': false},
      ],
    );
    final context = await _storyChat(h, declaration);
    final chat = context.chat;
    final originalNodes = _nodeExtras(h, chat);
    final initial = await h.engine.readDirector(chat);
    expect(initial.story!['initialized'], isFalse);
    expect(initial.story!['currentActId'], 'a');
    expect(initial.story!['actTurns'], 0);
    final first = await _startDirector(h, chat);
    final input = _input(first.call);
    expect(_map(input['card'])['story'], declaration);
    final progress = _map(input['storyProgress']);
    expect(progress['initialized'], isFalse);
    expect(progress['currentActId'], 'a');
    expect(progress['actTurns'], 0);
    expect(progress['unlockedEndings'], isEmpty);
    expect(_map(progress['currentAct'])['goal'], _goal);
    expect(_map(progress['currentAct'])['tension'], 3);
    expect(progress.containsKey('outline'), isFalse);
    final run = await _finishDirector(first);
    expect(_nodeExtras(h, chat), originalNodes);
    final phase = _map(_map(jsonDecode(_runJson(h, run.id)))['storyPhase']);
    expect(phase['currentActId'], 'a');
    expect(phase['completed'], isFalse);
    expect(phase.containsKey('actTurns'), isFalse);

    final main = await _main(h, chat, 'ordinary body');
    final wire = jsonEncode(main.call.body);
    expect(wire, contains(_beat));
    for (final private in [_outline, _goal, _endingTitle, _notes, 'T18B-PRIVATE-NEXT-GOAL']) {
      expect(wire, isNot(contains(private)), reason: private);
    }
    expect((await h.engine.readDirector(chat)).story!['actTurns'], 1);
    final second = await _startDirector(h, chat);
    final savedProgress = _map(_input(second.call)['storyProgress']);
    expect(savedProgress['initialized'], isTrue);
    expect(savedProgress['currentActId'], 'a');
    expect(savedProgress['actTurns'], 1);
    await _finishDirector(second, beat: 'T18B-NEW-BEAT');
  });

  test('late A remains usable after B only increments the same act and C uses A', () async {
    final h = await _open();
    final context = await _storyChat(h, _story());
    final chat = context.chat;
    final a = await _startDirector(h, chat);
    expect(_map(_input(a.call)['storyProgress'])['actTurns'], 0);
    final b = await _main(h, chat, 'B body while A is pending');
    expect(jsonEncode(b.call.body), isNot(contains(_beat)));
    final afterB = await h.engine.readDirector(chat);
    expect(afterB.story!['currentActId'], 'a');
    expect(afterB.story!['actTurns'], 1);
    final nodeSnapshot = _nodeExtras(h, chat);
    final run = await _finishDirector(a);
    final afterA = await h.engine.readDirector(chat);
    expect(afterA.latestSuccess!.id, run.id);
    expect(afterA.stale, isFalse);
    expect(afterA.story!['actTurns'], 1);
    expect(_nodeExtras(h, chat), nodeSnapshot);
    final c = await _main(h, chat, 'C body using A');
    expect(jsonEncode(c.call.body), contains(_beat));
    final inspection = (await h.engine.inspectTurn(chat, nodeId: c.message.nodeId))!;
    expect(inspection.director['eligible'], isTrue);
    expect(inspection.director['runId'], run.id);
    expect((await h.engine.readDirector(chat)).story!['actTurns'], 2);
    expect((await h.engine.readDirector(chat)).stale, isFalse);
    expect(h.model.generated, 3);
  });

  test('a chapter transition makes late A readable but ineligible for C', () async {
    await _phaseChange(ending: false);
  });

  test('an ending unlock invalidates late A even when the current act is unchanged', () async {
    await _phaseChange(ending: true);
  });

  test('legacy story success without captured phase stays readable and is never retroactively injected', () async {
    final h = await _open();
    final context = await _storyChat(h, _story());
    final chat = context.chat;
    final run = await _finishDirector(await _startDirector(h, chat));
    final legacy = _map(jsonDecode(_runJson(h, run.id)))..remove('storyPhase');
    final encoded = jsonEncode(legacy);
    _db(h, (db) => db.execute('UPDATE agent_runs SET result_json = ? WHERE id = ?', [encoded, run.id]));
    final beforeRead = _nodeExtras(h, chat);
    final read = await h.engine.readDirector(chat);
    expect(read.latestSuccess!.id, run.id);
    expect(read.latestSuccess!.notes, _notes);
    expect(read.stale, isTrue);
    expect(_codes(read), contains('director_story_context_missing'));
    expect(read.story!['initialized'], isFalse);
    expect(read.story!['currentActId'], 'a');
    expect(_nodeExtras(h, chat), beforeRead);
    expect(_runJson(h, run.id), encoded);
    await h.reopen();
    final reopened = await h.engine.readDirector(chat);
    expect(reopened.latestSuccess!.id, run.id);
    expect(_codes(reopened), contains('director_story_context_missing'));
    final main = await _main(h, chat, 'legacy suggestion not injected');
    expect(jsonEncode(main.call.body), isNot(contains(_beat)));
    expect(jsonEncode(main.call.body), isNot(contains(_outline)));
    final inspection = (await h.engine.inspectTurn(chat, nodeId: main.message.nodeId))!;
    expect(inspection.director['eligible'], isFalse);
    expect(_runJson(h, run.id), encoded);
  });

  test('legacy non-story success needs no phase and retains its old injection behavior', () async {
    final h = await _open();
    final active = await _startDirector(h, h.chatId);
    expect(_input(active.call).containsKey('storyProgress'), isFalse);
    final run = await _finishDirector(active);
    final saved = _runJson(h, run.id);
    expect(_map(jsonDecode(saved)).containsKey('storyPhase'), isFalse);
    expect((await h.engine.readDirector(h.chatId)).story, isNull);
    await h.reopen();
    final read = await h.engine.readDirector(h.chatId);
    expect(read.latestSuccess!.id, run.id);
    expect(read.stale, isFalse);
    final main = await _main(h, h.chatId, 'old non-story compatibility');
    expect(jsonEncode(main.call.body), contains(_beat));
    expect((await h.engine.readDirector(h.chatId)).story, isNull);
    expect(_runJson(h, run.id), saved);
  });

  test('changing only the outer DSH version rejects a formerly usable story run', () async {
    final h = await _open();
    final context = await _storyChat(h, _story());
    final run = await _finishDirector(await _startDirector(h, context.chat));
    expect((await h.engine.readDirector(context.chat)).stale, isFalse);
    final savedRun = _runJson(h, run.id);
    // Public field editing intentionally excludes extensions. Model a closed
    // library migration without changing the story or the projected card.
    await h.engine.close();
    final file = File('${h.root.path}/characters/${context.character}/card.json');
    final raw = _map(jsonDecode(await file.readAsString()));
    final own = _map(_map(_map(raw['data'])['extensions'])['dshgo']);
    own['v'] = 2;
    await file.writeAsString(jsonEncode(raw), flush: true);
    await h.reopen();
    final read = await h.engine.readDirector(context.chat);
    expect(read.latestSuccess!.id, run.id);
    expect(read.latestSuccess!.notes, _notes);
    expect(read.stale, isTrue);
    expect(read.story!['defined'], isTrue);
    expect(read.story!['executable'], isFalse);
    expect(_codes(read), contains('director_story_unavailable'));
    expect(_codes(read), isNot(contains('director_source_changed')));
    final main = await _main(h, context.chat, 'future story is preserved without injection');
    expect(jsonEncode(main.call.body), isNot(contains(_beat)));
    expect((await h.engine.readDirector(context.chat)).story!['initialized'], isFalse);
    expect(_runJson(h, run.id), savedRun);
    final reread = _map(jsonDecode(await file.readAsString()));
    expect(_map(_map(_map(reread['data'])['extensions'])['dshgo'])['v'], 2);
  });

  test('malformed or future captured phases remain readable without phase repair or injection', () async {
    final h = await _open();
    final context = await _storyChat(h, _story());
    final chat = context.chat;
    final run = await _finishDirector(await _startDirector(h, chat));
    final original = _map(jsonDecode(_runJson(h, run.id)));
    final phase = _map(original['storyPhase']);
    for (final badPhase in <Object?>[
      {...phase, 'version': 2},
      {...phase, 'valid': 'true'},
      'unrecognized phase',
    ]) {
      final encoded = jsonEncode({...original, 'storyPhase': badPhase});
      _db(h, (db) => db.execute('UPDATE agent_runs SET result_json = ? WHERE id = ?', [encoded, run.id]));
      final read = await h.engine.readDirector(chat);
      expect(read.latestSuccess!.id, run.id);
      expect(read.latestSuccess!.notes, _notes);
      expect(read.stale, isTrue);
      final main = await _main(h, chat, 'bad phase was not used');
      expect(jsonEncode(main.call.body), isNot(contains(_beat)));
      expect(_runJson(h, run.id), encoded);
    }
  });
}

Future<void> _phaseChange({required bool ending}) async {
  final h = await _open();
  final declaration = _story(
    when: !ending,
    endings: ending
        ? [
            {'id': 'e', 'title': _endingTitle, 'when': true},
          ]
        : [],
  );
  final context = await _storyChat(h, declaration);
  final chat = context.chat;
  final a = await _startDirector(h, chat);
  final b = await _main(h, chat, 'B changes the story phase');
  expect(jsonEncode(b.call.body), isNot(contains(_beat)));
  final progress = (await h.engine.readDirector(chat)).story!;
  expect(progress['currentActId'], ending ? 'a' : 'b');
  expect(progress['unlockedEndings'], ending ? ['e'] : isEmpty);
  final run = await _finishDirector(a);
  final read = await h.engine.readDirector(chat);
  expect(read.latestSuccess!.id, run.id);
  expect(read.latestSuccess!.notes, _notes);
  expect(read.stale, isTrue);
  expect(_codes(read), contains('director_story_changed'));
  final c = await _main(h, chat, 'C omits obsolete A');
  expect(jsonEncode(c.call.body), isNot(contains(_beat)));
  final inspection = (await h.engine.inspectTurn(chat, nodeId: c.message.nodeId))!;
  expect(inspection.director['eligible'], isFalse);
  final fresh = await _finishDirector(await _startDirector(h, chat), beat: 'T18B-FRESH-PHASE');
  expect((await h.engine.readDirector(chat)).stale, isFalse);
  final d = await _main(h, chat, 'D uses refreshed phase');
  expect(jsonEncode(d.call.body), contains('T18B-FRESH-PHASE'));
  expect((await h.engine.inspectTurn(chat, nodeId: d.message.nodeId))!.director['runId'], fresh.id);
}

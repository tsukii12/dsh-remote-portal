import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import 'support/t24_engine_harness.dart';

typedef _Json = Map<String, Object?>;
typedef _Active = ({T24Call call, T24Events events});

_Json _map(Object? value) => value! as _Json;
List<_Json> _maps(Object? value) => (value! as List<Object?>).map(_map).toList();

_Json _counterStory() => {
  'acts': [
    {'id': 'waiting', 'title': 'Waiting', 'when': false},
  ],
};

_Json _stateDefinition({List<Object?> rules = const []}) => {
  'schema': {
    'type': 'object',
    'additionalProperties': false,
    'required': ['count', 'ready'],
    'properties': {
      'count': {'type': 'integer', 'minimum': 0, 'maximum': 100},
      'ready': {
        'type': 'boolean',
        'x-dsh-by': ['rules', 'user'],
      },
    },
  },
  'init': {'count': 0, 'ready': false},
  'rules': rules,
};

List<Object?> _readyRule() => [
  {
    'id': 'ready-after-model',
    'when': {
      '==': [
        {'var': 'count'},
        1,
      ],
    },
    'once': true,
    'do': [
      {
        'type': 'state',
        'ops': [
          {'op': 'set', 'path': '/ready', 'value': true, 'why': 'final rule result'},
        ],
      },
    ],
  },
];

Future<({String characterId, String chatId})> _storyChat(
  T24Harness h, {
  _Json? story,
  _Json? state,
  bool cardEnabled = false,
}) async {
  final raw = _map(jsonDecode(utf8.decode(t24Card())));
  _map(raw['data'])['extensions'] = {
    'dshgo': {
      'v': 1,
      'story': story ?? _counterStory(),
      'state': ?state,
      if (cardEnabled) 'director': {'enabled': true, 'every': 1},
    },
  };
  final card = await h.engine.importCard(Uint8List.fromList(utf8.encode(jsonEncode(raw))));
  return (characterId: card.id, chatId: await h.engine.createChat(card.id));
}

Future<void> _enable(T24Harness h) => h.engine.setSettings({
  'director': {'enabled': true, 'every': 1000},
});

Future<_Json> _story(T24Harness h, String chat) async => (await h.engine.readDirector(chat)).story!;

Future<_Active> _start(T24Harness h, Stream<TavernEvent> stream) async {
  final call = h.model.prepare();
  final events = T24Events(stream);
  await Future.any<void>([
    call.listening.future,
    events.done.future.then<void>((_) {
      throw TestFailure('Turn ended before model input: ${events.values}');
    }),
  ]);
  return (call: call, events: events);
}

Future<void> _finish(_Active active, {String text = 'body', String? reason = 'stop', List<_Json>? ops}) async {
  if (text.isNotEmpty) {
    active.call.add(ModelText(text));
  }
  if (ops != null) {
    active.call.add(
      ModelToolFragment(
        index: 0,
        id: 'story-state-call',
        type: 'function',
        name: 'update_state',
        arguments: jsonEncode({
          'ops': [
            for (final op in ops) {'why': 'story facade fixture', ...op},
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

Future<TavernMessage> _reply(
  T24Harness h,
  String chat, {
  String text = 'body',
  String? reason = 'stop',
  List<_Json>? ops,
}) async {
  final active = await _start(h, h.engine.send(chat, ''));
  await _finish(active, text: text, reason: reason, ops: ops);
  return _success(active);
}

Future<List<TavernAgentRun>> _storyRuns(T24Harness h, String chat) async =>
    (await h.engine.readAgentRuns(chat, limit: 1000)).where((run) => run.kind == 'story.rules').toList();

T _db<T>(T24Harness h, T Function(Database database) read) {
  final database = sqlite3.open('${h.root.path}/tavern.sqlite3');
  try {
    return read(database);
  } finally {
    database.close();
  }
}

_Json _rows(T24Harness h) => _db(
  h,
  (database) => {
    for (final table in ['chats', 'nodes', 'node_states', 'agent_runs'])
      table: [for (final row in database.select('SELECT * FROM $table ORDER BY rowid')) Map<String, Object?>.from(row)],
  },
);

Future<_Json> _saved(T24Harness h, String chat) async {
  final files = await h.engine.exportChat(chat);
  final document = StChatDocument.decode(files.first.fileName, files.first.bytes);
  final saved = _map(_map(_map(document.messages.last['extra'])['dshgo'])['tavernState']);
  // The document is deeply read-only; mutation fixtures need detached JSON.
  return _map(jsonDecode(jsonEncode(saved)));
}

Future<_Json> _own(T24Harness h, String chat) async {
  final leaf = (await h.engine.path(chat)).last.nodeId;
  return _db(
    h,
    (database) => _map(
      _map(
        jsonDecode(database.select('SELECT extra FROM nodes WHERE id = ?', [leaf]).single['extra']! as String),
      )['dshgo'],
    ),
  );
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

String _requestText(T24Call call) =>
    _maps(call.body!['messages']).map((message) => message['content']).whereType<String>().join('\n');

void main() {
  _progressTests();
  _lifecycleTests();
  _integrityTests();
}

void _progressTests() {
  test('story is off by default and reading watching or exporting never initializes true conditions', () async {
    final h = await T24Harness.open(thinking: false);
    addTearDown(h.dispose);
    final chat = (await _storyChat(
      h,
      cardEnabled: true,
      story: {
        'acts': [
          {'id': 'start', 'when': true},
        ],
        'endings': [
          {'id': 'already-true', 'title': 'True but not executed', 'when': true},
        ],
      },
    )).chatId;
    final before = _rows(h);
    final view = await _story(h, chat);
    expect(view['defined'], isTrue);
    expect(view['executable'], isTrue);
    expect(view['initialized'], isFalse);
    expect(view['automaticEnabled'], isFalse);
    expect(view['unlockedEndings'], isEmpty);
    expect((await h.engine.watchDirector(chat).first).story, view);
    await h.engine.exportChat(chat);
    expect(await _story(h, chat), view);
    expect(_rows(h), before);
    expect(h.model.generated, 0);
    expect((await h.engine.readDirector(h.chatId)).story, isNull);
    await _reply(h, chat);
    expect((await _story(h, chat))['initialized'], isFalse);
    expect(await _storyRuns(h, chat), isEmpty);
    expect(h.model.generated, 1);
    expect((await h.engine.readDirector(chat)).pendingJobs, 0);
  });

  test('counts precede min and inclusive max gates and a normal invocation advances at most one act', () async {
    final h = await T24Harness.open(thinking: false);
    addTearDown(h.dispose);
    final chat = (await _storyChat(
      h,
      story: {
        'outline': 'PRIVATE-OUTLINE-{{incvar::outlineLeak}}',
        'acts': [
          {'id': 'a', 'title': 'PRIVATE-A', 'when': true, 'minTurns': 2},
          {'id': 'b', 'goal': 'PRIVATE-B-GOAL', 'when': false, 'minTurns': 1, 'maxTurns': 2},
          {'id': 'c', 'when': true},
        ],
        'tension': [-4, 150.5, 0],
      },
    )).chatId;
    await _enable(h);
    await _reply(h, chat);
    var view = await _story(h, chat);
    expect(view['currentActId'], 'a');
    expect(view['actTurns'], 1);
    expect(_map(view['currentAct'])['tension'], -4);
    await _reply(h, chat);
    view = await _story(h, chat);
    expect(view['currentActId'], 'b');
    expect(view['actTurns'], 0);
    expect(view['completed'], isFalse);
    expect(_map(view['currentAct'])['tension'], 150.5);
    expect(_maps(view['effects']).single['reason'], 'condition');
    await _reply(h, chat);
    expect((await _story(h, chat))['actTurns'], 1);
    await _reply(h, chat);
    view = await _story(h, chat);
    expect(view['currentActId'], 'c');
    expect(view['actTurns'], 0);
    expect(view['completed'], isFalse);
    expect(_maps(view['effects']).single['reason'], 'maximum');
    await _reply(h, chat);
    expect((await _story(h, chat))['completed'], isTrue);
    for (final call in h.model.allCalls) {
      expect(_requestText(call), isNot(contains('PRIVATE-')));
    }
    expect(h.engine.variables(chat).containsKey('outlineLeak'), isFalse);
    expect(await _storyRuns(h, chat), hasLength(5));
    expect(h.model.generated, 5);
  });

  test('all matching endings unlock once and their branch ledger survives reopening', () async {
    final h = await T24Harness.open(thinking: false);
    addTearDown(h.dispose);
    final chat = (await _storyChat(
      h,
      story: {
        ..._counterStory(),
        'endings': [
          {'id': 'one', 'title': 'ONE', 'when': true},
          {'id': 'two', 'title': 'TWO', 'when': true},
        ],
      },
    )).chatId;
    await _enable(h);
    final firstMessage = await _reply(h, chat);
    final first = await _story(h, chat);
    expect(first['unlockedEndings'], ['one', 'two']);
    final effects = _maps(first['effects']);
    expect(effects.map((effect) => effect['id']), ['one', 'two']);
    expect(effects.map((effect) => effect['effectId']).toSet(), hasLength(2));
    await h.reopen();
    expect((await _story(h, chat))['unlockedEndings'], ['one', 'two']);
    await _reply(h, chat);
    final second = await _story(h, chat);
    expect(second['actTurns'], 2);
    expect(second['unlockedEndings'], ['one', 'two']);
    expect(second['effects'], isEmpty);
    final runs = await _storyRuns(h, chat);
    expect(runs.expand((run) => _maps(run.result['effects'])), hasLength(2));
    final sibling = await _start(h, h.engine.regenerate(chat, firstMessage.nodeId));
    await _finish(sibling, text: 'independent ending branch');
    _success(sibling);
    final branch = await _story(h, chat);
    expect(branch['actTurns'], 1);
    expect(branch['unlockedEndings'], ['one', 'two']);
    expect(_maps(branch['effects']).map((effect) => effect['id']), ['one', 'two']);
  });

  test('chapter and ending conditions see the final T17 rule result after model state tools', () async {
    final h = await T24Harness.open(thinking: false);
    addTearDown(h.dispose);
    final chat = (await _storyChat(
      h,
      state: _stateDefinition(rules: _readyRule()),
      story: {
        'acts': [
          {
            'id': 'before',
            'when': {'var': 'ready'},
          },
          {'id': 'after', 'when': false},
        ],
        'endings': [
          {
            'id': 'ready',
            'title': 'READY',
            'when': {'var': 'ready'},
          },
        ],
      },
    )).chatId;
    await _enable(h);
    expect(_map((await h.engine.readState(chat)).values)['ready'], isFalse);
    final reply = await _reply(
      h,
      chat,
      text: '',
      reason: 'tool_calls',
      ops: [
        {'op': 'set', 'path': '/count', 'value': 1},
      ],
    );
    expect(reply.text, isEmpty);
    final state = await h.engine.readState(chat);
    expect(_map(state.values)['count'], 1);
    expect(_map(state.values)['ready'], isTrue);
    final view = await _story(h, chat);
    expect(view['currentActId'], 'after');
    expect(view['actTurns'], 0);
    expect(view['unlockedEndings'], ['ready']);
    final run = (await _storyRuns(h, chat)).single;
    expect(run.nodeId, reply.nodeId);
    expect(run.result['committed'], isTrue);
    expect(_map((await _saved(h, chat))['dshgoStateRuntime'])['firedRules'], ['id:ready-after-model']);
    expect(_map((await h.engine.inspectTurn(chat))!.director['story'])['committed'], isTrue);
  });

  test('a story without state schema receives null and never treats ST variables as DSH data', () async {
    final h = await T24Harness.open(thinking: false);
    addTearDown(h.dispose);
    final chat = (await _storyChat(
      h,
      story: {
        'acts': [
          {
            'id': 'waiting',
            'when': {'var': 'flag'},
          },
        ],
        'endings': [
          {
            'id': 'null-data',
            'title': 'NULL',
            'when': {
              '===': [
                {'var': ''},
                null,
              ],
            },
          },
          {
            'id': 'not-legacy',
            'title': 'NEVER',
            'when': {'var': 'flag'},
          },
        ],
      },
    )).chatId;
    await h.engine.setStateValue(chat, '/flag', true);
    expect(h.engine.variables(chat)['flag'], isTrue);
    await _enable(h);
    await _reply(h, chat);
    final view = await _story(h, chat);
    expect(view['currentActId'], 'waiting');
    expect(view['actTurns'], 1);
    expect(view['completed'], isFalse);
    expect(view['unlockedEndings'], ['null-data']);
    expect(h.engine.variables(chat)['flag'], isTrue);
  });

  test('continue counts new invocations while regenerate and selected branches retain their own counters', () async {
    final h = await T24Harness.open(thinking: false);
    addTearDown(h.dispose);
    final chat = (await _storyChat(h)).chatId;
    await _enable(h);
    final first = await _reply(h, chat, text: 'A');
    for (final reason in ['stop', 'tool_calls']) {
      final active = await _start(h, h.engine.continueReply(chat, first.nodeId));
      await _finish(active, text: ' plus', reason: reason);
      expect(_success(active).nodeId, first.nodeId);
    }
    expect((await _story(h, chat))['actTurns'], 3);
    final firstRuns = (await _storyRuns(h, chat)).where((run) => run.nodeId == first.nodeId).toList();
    expect(firstRuns, hasLength(3));
    expect(firstRuns.map((run) => run.result['invocationId']).toSet(), hasLength(3));
    final branch = await _start(h, h.engine.regenerate(chat, first.nodeId));
    await _finish(branch, text: 'B');
    final alternative = _success(branch);
    expect(alternative.nodeId, isNot(first.nodeId));
    expect((await _story(h, chat))['actTurns'], 1);
    await h.engine.selectNode(chat, first.nodeId);
    expect((await _story(h, chat))['actTurns'], 3);
    await _reply(h, chat, text: 'A child');
    expect((await _story(h, chat))['actTurns'], 4);
    await h.engine.selectNode(chat, alternative.nodeId);
    await h.reopen();
    expect((await _story(h, chat))['nodeId'], alternative.nodeId);
    expect((await _story(h, chat))['actTurns'], 1);
    expect(await _storyRuns(h, chat), hasLength(5));
  });
}

void _lifecycleTests() {
  test('manual user narrator and impersonation paths preserve the saved story without settling', () async {
    final h = await T24Harness.open(thinking: false);
    addTearDown(h.dispose);
    final chat = (await _storyChat(h)).chatId;
    await _enable(h);
    await _reply(h, chat);
    final saved = _map((await _saved(h, chat))['dshgoStoryRuntime']);
    await h.engine.sendOnly(chat, 'manual user');
    await h.engine.narrate(chat, 'manual narrator');
    final beforeImpersonation = (await h.engine.path(chat)).map((message) => message.nodeId).toList();
    final active = await _start(h, h.engine.impersonate(chat));
    await _finish(active, text: 'a possible user line');
    _success(active);
    expect((await h.engine.path(chat)).map((message) => message.nodeId), beforeImpersonation);
    expect((await _saved(h, chat))['dshgoStoryRuntime'], saved);
    expect((await _story(h, chat))['actTurns'], 1);
    expect(await _storyRuns(h, chat), hasLength(1));
    expect(h.model.generated, 2);
  });

  for (final reason in <String?>['length', 'content_filter', null]) {
    test('finish=$reason preserves body but cannot count or advance a story', () async {
      final h = await T24Harness.open(thinking: false);
      addTearDown(h.dispose);
      final chat = (await _storyChat(
        h,
        story: {
          'acts': [
            {'id': 'first', 'when': true, 'minTurns': 2},
            {'id': 'second'},
          ],
        },
      )).chatId;
      await _enable(h);
      await _reply(h, chat);
      final before = (await _saved(h, chat))['dshgoStoryRuntime'];
      final reply = await _reply(h, chat, text: 'kept abnormal body', reason: reason);
      expect(reply.text, 'kept abnormal body');
      expect((await _saved(h, chat))['dshgoStoryRuntime'], before);
      expect((await _story(h, chat))['currentActId'], 'first');
      expect((await _story(h, chat))['actTurns'], 1);
      expect(await _storyRuns(h, chat), hasLength(1));
    });
  }

  for (final outcome in ['cancelled', 'network']) {
    test('$outcome preserves partial text but neither active reads nor failure settle story', () async {
      final h = await T24Harness.open(thinking: false);
      addTearDown(h.dispose);
      final chat = (await _storyChat(h)).chatId;
      await _enable(h);
      await _reply(h, chat);
      final before = (await _saved(h, chat))['dshgoStoryRuntime'];
      final active = await _start(h, h.engine.send(chat, ''));
      active.call.add(const ModelText('PARTIAL'));
      expect((await _story(h, chat))['actTurns'], 1);
      expect((await h.engine.watchDirector(chat).first).story!['actTurns'], 1);
      try {
        if (outcome == 'cancelled') {
          h.engine.stop(chat);
        } else {
          active.call.fail(TavernFailure.network, 'controlled story network failure');
        }
        await active.events.done.future;
      } finally {
        await active.call.close();
      }
      expect(active.events.values.whereType<TavernTurnDone>(), isEmpty);
      expect(
        active.events.values.whereType<TavernTurnFailed>().single.kind,
        outcome == 'cancelled' ? TavernFailure.cancelled : TavernFailure.network,
      );
      expect((await h.engine.path(chat)).last.text, 'PARTIAL');
      expect((await _saved(h, chat))['dshgoStoryRuntime'], before);
      expect(await _storyRuns(h, chat), hasLength(1));
    });
  }

  test('a global disable during an active main removes terminal story authorization', () async {
    final h = await T24Harness.open(thinking: false);
    addTearDown(h.dispose);
    final chat = (await _storyChat(h)).chatId;
    await _enable(h);
    final active = await _start(h, h.engine.send(chat, ''));
    await h.engine.setSettings({
      'director': {'enabled': false},
    });
    expect(active.call.cancellation!.isCancelled, isFalse);
    await _finish(active);
    _success(active);
    expect((await _story(h, chat))['initialized'], isFalse);
    expect((await _story(h, chat))['automaticEnabled'], isFalse);
    expect(await _storyRuns(h, chat), isEmpty);
  });

  test('terminal current authorization respects chat true over global false and can enable an admitted turn', () async {
    final h = await T24Harness.open(thinking: false);
    addTearDown(h.dispose);
    final chat = (await _storyChat(h)).chatId;
    final initiallyOff = await _start(h, h.engine.send(chat, ''));
    await _enable(h);
    await _finish(initiallyOff);
    _success(initiallyOff);
    expect((await _story(h, chat))['actTurns'], 1);
    await h.engine.setSettings({
      'director': {'enabled': true, 'every': 1000},
    }, chatId: chat);
    final overridden = await _start(h, h.engine.send(chat, ''));
    await h.engine.setSettings({
      'director': {'enabled': false},
    });
    expect(overridden.call.cancellation!.isCancelled, isFalse);
    await _finish(overridden);
    _success(overridden);
    expect((await _story(h, chat))['actTurns'], 2);
    expect((await _story(h, chat))['automaticEnabled'], isTrue);
    expect(await _storyRuns(h, chat), hasLength(2));
  });

  test('read and watch story maps are detached and a main commit emits fresh progress without a helper', () async {
    final h = await T24Harness.open(thinking: false);
    addTearDown(h.dispose);
    final chat = (await _storyChat(
      h,
      story: {
        ..._counterStory(),
        'endings': [
          {'id': 'one', 'title': 'Original ending', 'when': true},
        ],
      },
    )).chatId;
    await _enable(h);
    await _reply(h, chat);
    final snapshot = await h.engine.readDirector(chat);
    final original = snapshot.story!;
    final caller = snapshot.story!;
    _map(caller['currentAct'])['title'] = 'caller mutation';
    (caller['unlockedEndings']! as List<Object?>).clear();
    _maps(caller['effects']).single['title'] = 'caller effect mutation';
    expect(snapshot.story, original);
    expect(await _story(h, chat), original);
    final ready = Completer<void>();
    final changed = Completer<void>();
    final observations = <TavernDirectorSnapshot>[];
    final subscription = h.engine.watchDirector(chat).listen((value) {
      observations.add(value);
      if (!ready.isCompleted) {
        ready.complete();
      }
      if (value.story?['actTurns'] == 2 && !changed.isCompleted) {
        changed.complete();
      }
    });
    addTearDown(subscription.cancel);
    await ready.future;
    final oldWatchMap = observations.first.story!;
    oldWatchMap['actTurns'] = 100;
    _map(oldWatchMap['currentAct'])['title'] = 'watch mutation';
    expect(observations.first.story, original);
    final beforeReads = _rows(h);
    await h.engine.readDirector(chat);
    await h.engine.exportChat(chat);
    expect(_rows(h), beforeReads);
    await _reply(h, chat);
    await changed.future.timeout(const Duration(seconds: 5));
    expect(observations.last.story!['actTurns'], 2);
    expect(observations.first.story, original);
    expect(observations.every((value) => value.latestSuccess == null && value.pendingJobs == 0), isTrue);
    expect(h.model.generated, 2);
  });
}

void _integrityTests() {
  test('real terminal story audit failure rolls back both story and T17 candidate before partial fallback', () async {
    final h = await T24Harness.open(thinking: false);
    addTearDown(h.dispose);
    final chat = (await _storyChat(
      h,
      state: _stateDefinition(rules: _readyRule()),
      story: {
        'acts': [
          {
            'id': 'first',
            'when': {'var': 'ready'},
          },
          {'id': 'second'},
        ],
        'endings': [
          {
            'id': 'ready',
            'title': 'READY',
            'when': {'var': 'ready'},
          },
        ],
      },
    )).chatId;
    await _enable(h);
    _db(
      h,
      (database) => database.execute(
        "CREATE TRIGGER reject_story_commit BEFORE INSERT ON agent_runs "
        r"WHEN NEW.kind = 'story.rules' AND json_extract(NEW.result_json, '$.committed') = 1 "
        "BEGIN SELECT RAISE(ABORT, 'controlled story audit rejection'); END",
      ),
    );
    late TavernTurnInspection failedInspection;
    try {
      final active = await _start(h, h.engine.send(chat, ''));
      await _finish(
        active,
        text: 'partial survives failed terminal',
        ops: [
          {'op': 'set', 'path': '/count', 'value': 1},
        ],
      );
      expect(active.events.values.whereType<TavernTurnDone>(), isEmpty);
      expect(active.events.values.whereType<TavernTurnFailed>(), hasLength(1));
      expect((await h.engine.path(chat)).last.text, 'partial survives failed terminal');
      expect(_map((await h.engine.readState(chat)).values), {'count': 0, 'ready': false});
      final saved = await _saved(h, chat);
      expect(saved.containsKey('dshgoStoryRuntime'), isFalse);
      expect((await _story(h, chat))['unlockedEndings'], isEmpty);
      final failureRun = (await _storyRuns(h, chat)).single;
      expect(failureRun.result['committed'], isFalse);
      expect(failureRun.result['countTurn'], isFalse);
      expect(failureRun.result['changes'], isEmpty);
      expect(failureRun.result['effects'], isEmpty);
      final inspection = (await h.engine.inspectTurn(chat))!;
      expect(inspection.status, TavernInspectionStatus.failed);
      expect(_map(inspection.director['story'])['committed'], isFalse);
      final nodeId = (await h.engine.path(chat)).last.nodeId;
      final storedInspection = (await h.engine.inspectTurn(chat, nodeId: nodeId))!;
      expect(storedInspection.toJson(), inspection.toJson());
      failedInspection = inspection;
    } finally {
      _db(h, (database) => database.execute('DROP TRIGGER reject_story_commit'));
    }
    await h.reopen();
    expect((await h.engine.inspectTurn(chat))!.toJson(), failedInspection.toJson());
    expect((await _story(h, chat))['initialized'], isFalse);
    expect(_map((await h.engine.readState(chat)).values)['ready'], isFalse);
    await _reply(
      h,
      chat,
      ops: [
        {'op': 'set', 'path': '/count', 'value': 1},
      ],
    );
    expect((await _story(h, chat))['currentActId'], 'second');
    expect((await _story(h, chat))['unlockedEndings'], ['ready']);
  });

  test(
    'a continue condition domain error keeps the previous successful story audit and records its rejection separately',
    () async {
      final h = await T24Harness.open(thinking: false);
      addTearDown(h.dispose);
      await h.engine.setPreset(ChatPreset({...t24Preset().raw, 'continue_prefill': false}));
      final chat = (await _storyChat(
        h,
        state: {
          'schema': {
            'type': 'object',
            'additionalProperties': false,
            'required': ['denominator'],
            'properties': {
              'denominator': {'type': 'integer', 'minimum': 0, 'maximum': 10},
            },
          },
          'init': {'denominator': 1},
        },
        story: {
          'acts': [
            {
              'id': 'hold',
              'when': {
                '/': [
                  0,
                  {'var': 'denominator'},
                ],
              },
            },
          ],
          'endings': [
            {'id': 'old-success', 'title': 'Existing unlock', 'when': true},
          ],
        },
      )).chatId;
      await _enable(h);
      final first = await _reply(h, chat, text: 'valid body');
      final before = await _own(h, chat);
      final runtime = _map(before['tavernState'])['dshgoStoryRuntime'];
      expect(_maps(before['storyEffects']).single['id'], 'old-success');
      final active = await _start(h, h.engine.continueReply(chat, first.nodeId));
      expect(_maps(active.call.body!['tools']).map((tool) => _map(tool['function'])['name']), contains('update_state'));
      await _finish(
        active,
        text: ' continued',
        reason: 'tool_calls',
        ops: [
          {'op': 'set', 'path': '/denominator', 'value': 0},
        ],
      );
      expect(_success(active).nodeId, first.nodeId);
      expect(_map((await h.engine.readState(chat)).values)['denominator'], 0);
      final after = await _own(h, chat);
      expect(_map(after['tavernState'])['dshgoStoryRuntime'], runtime);
      for (final key in ['storyInvocation', 'storyChanges', 'storyEffects', 'storyIssues']) {
        expect(after[key], before[key], reason: key);
      }
      final runs = await _storyRuns(h, chat);
      expect(runs, hasLength(2));
      expect(runs.first.result['committed'], isFalse);
      expect(runs.first.result['issues'], isNotEmpty);
      expect(runs.first.result['effects'], isEmpty);
      expect(runs.last.result['committed'], isTrue);
      final inspection = (await h.engine.inspectTurn(chat))!;
      expect(inspection.status, TavernInspectionStatus.completed);
      expect(_map(inspection.director['story'])['committed'], isFalse);
      expect(_map(inspection.director['story'])['issues'], isNotEmpty);
      expect((await _story(h, chat))['effects'], before['storyEffects']);
      await h.reopen();
      expect((await _own(h, chat))['storyInvocation'], before['storyInvocation']);
    },
  );

  for (final corruption in ['null', 'future version', 'different definition']) {
    test('saved story runtime $corruption is preserved and diagnosed instead of restarting its ledger', () async {
      final h = await T24Harness.open(thinking: false);
      addTearDown(h.dispose);
      final chat = (await _storyChat(h)).chatId;
      await _enable(h);
      await _reply(h, chat);
      final saved = await _saved(h, chat);
      final runtime = _map(saved['dshgoStoryRuntime']);
      runtime['vendor'] = {
        'kept': [1, null],
      };
      if (corruption == 'null') {
        saved['dshgoStoryRuntime'] = null;
      } else if (corruption == 'future version') {
        runtime['version'] = 99;
      } else {
        runtime['definitionFingerprint'] = 'different-definition';
      }
      final before = jsonDecode(jsonEncode(saved['dshgoStoryRuntime']));
      await _replaceSaved(h, chat, saved);
      expect((await _story(h, chat))['valid'], isFalse);
      await _reply(h, chat);
      expect((await _saved(h, chat))['dshgoStoryRuntime'], before);
      final view = await _story(h, chat);
      expect(view['initialized'], isTrue);
      expect(view['valid'], isFalse);
      expect(view['issues'], isNotEmpty);
      expect(view['effects'], isEmpty);
      expect((await _storyRuns(h, chat)).first.result['committed'], isFalse);
      await h.reopen();
      expect((await _saved(h, chat))['dshgoStoryRuntime'], before);
    });
  }

  for (final corruption in ['invalid DSH value', 'future DSH runtime']) {
    test('$corruption cannot feed story conditions or initialize story runtime', () async {
      final h = await T24Harness.open(thinking: false);
      addTearDown(h.dispose);
      final chat = (await _storyChat(
        h,
        state: _stateDefinition(),
        story: {
          'acts': [
            {'id': 'must-not-run', 'when': true},
          ],
          'endings': [
            {'id': 'must-not-unlock', 'title': 'NO', 'when': true},
          ],
        },
      )).chatId;
      final saved = await _saved(h, chat);
      if (corruption == 'invalid DSH value') {
        _map(saved['messageVariables'])['dshgo'] = 17;
      } else {
        saved['dshgoStateRuntime'] = {'version': 99, 'vendor': 'preserve'};
      }
      await _replaceSaved(h, chat, saved);
      await _enable(h);
      await _reply(h, chat);
      final after = await _saved(h, chat);
      expect(after['messageVariables'], saved['messageVariables']);
      expect(after['dshgoStateRuntime'], saved['dshgoStateRuntime']);
      expect(after.containsKey('dshgoStoryRuntime'), isFalse);
      final view = await _story(h, chat);
      expect(view['initialized'], isFalse);
      expect(view['unlockedEndings'], isEmpty);
      final rejected = (await _storyRuns(h, chat)).single.result;
      expect(rejected['committed'], isFalse);
      expect(rejected['issues'], isNotEmpty);
      expect(_map((await h.engine.inspectTurn(chat))!.director['story'])['issues'], isNotEmpty);
    });
  }
}

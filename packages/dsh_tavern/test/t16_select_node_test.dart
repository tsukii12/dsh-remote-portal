import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import 'support/t24_engine_harness.dart';

// Real facade/files/SQLite. Only model deltas are controlled; damaged-link
// cases use a real connection, without disabling SQLite foreign keys.
void main() {
  test('a deep inactive node rewrites every ancestor and stops exactly there across reopening', () async {
    final h = await _open();
    final branch = await _branches(h);
    final payload = _payload(h);
    final latest = (await h.engine.inspectTurn(h.chatId))!.toJson();
    final calls = h.model.generated;
    final notified = h.engine.pathChanges(h.chatId).first;
    final Tavern facade = h.engine;
    await facade.selectNode(h.chatId, branch.a2);
    await notified;
    final wanted = [branch.root, branch.shared, branch.a, branch.a1, branch.a2];
    expect(_ids(await facade.path(h.chatId)), wanted);
    final choices = _choices(h, h.chatId);
    for (var index = 0; index + 1 < wanted.length; index++) {
      expect(choices[wanted[index]], wanted[index + 1]);
    }
    expect(choices[branch.a2], isNull);
    expect(choices[branch.b], branch.b1);
    expect(choices[branch.b1], branch.b2);
    expect((await facade.tree(h.chatId)).where((node) => node.isCurrentPath).map((node) => node.nodeId), wanted);
    expect((await facade.tree(h.chatId)).any((node) => node.nodeId == branch.a3), isTrue);
    expect(await facade.readVariables(h.chatId), {'route': 'A2'});
    expect(h.engine.variables(h.chatId), {'route': 'A2'});
    expect(h.engine.globalVariables, {'global_route': 'keep'});
    expect(_payload(h), payload);
    expect((await facade.inspectTurn(h.chatId))!.toJson(), latest);
    expect(h.model.generated, calls);
    await h.reopen();
    expect(_ids(await h.engine.path(h.chatId)), wanted);
    expect(await h.engine.readVariables(h.chatId), {'route': 'A2'});
    expect(_choices(h, h.chatId), choices);
  });

  test('restoreDescendants uses current memory and cannot resurrect a cleared first edge', () async {
    final h = await _open();
    final branch = await _branches(h);
    await h.engine.selectNode(h.chatId, branch.a, restoreDescendants: true);
    expect((await h.engine.path(h.chatId)).last.nodeId, branch.a3);
    expect(await h.engine.readVariables(h.chatId), {'route': 'A3'});
    await h.engine.selectNode(h.chatId, branch.a);
    expect((await h.engine.path(h.chatId)).last.nodeId, branch.a);
    expect(_choices(h, h.chatId)[branch.a], isNull);
    expect(_choices(h, h.chatId)[branch.a1], branch.a2);
    await h.engine.selectNode(h.chatId, branch.b, restoreDescendants: true);
    expect((await h.engine.path(h.chatId)).last.nodeId, branch.b2);
    await h.reopen();
    await h.engine.selectNode(h.chatId, branch.a, restoreDescendants: true);
    expect((await h.engine.path(h.chatId)).last.nodeId, branch.a);
    // Explicitly selecting the retained descendant can establish that edge
    // again; the stop never removed any message or deeper remembered choice.
    await h.engine.selectNode(h.chatId, branch.a1, restoreDescendants: true);
    expect((await h.engine.path(h.chatId)).last.nodeId, branch.a3);
    expect(_choices(h, h.chatId)[branch.a], branch.a1);
  });

  test('legacy sibling regeneration and continuation keep their remembered-path and rollback semantics', () async {
    final h = await _open();
    final branch = await _branches(h);
    await h.engine.selectSibling(h.chatId, branch.otherRoot, 0);
    expect((await h.engine.path(h.chatId)).last.nodeId, branch.b2);
    await h.engine.selectSibling(h.chatId, branch.b, 0);
    expect((await h.engine.path(h.chatId)).last.nodeId, branch.a3);
    final continued = await _run(h, h.engine.continueReply(h.chatId, branch.a), ' plus');
    expect(continued.nodeId, branch.a);
    expect(continued.text, 'A plus');
    expect((await h.engine.path(h.chatId)).last.nodeId, branch.a);
    expect(_choices(h, h.chatId)[branch.a], isNull);
    expect((await h.engine.tree(h.chatId)).any((node) => node.nodeId == branch.a3), isTrue);
    final regenerated = await _run(h, h.engine.regenerate(h.chatId, branch.a), 'C');
    expect(regenerated.parentId, branch.shared);
    await h.engine.selectSibling(h.chatId, regenerated.nodeId, 1);
    expect((await h.engine.path(h.chatId)).last.nodeId, branch.b2);
    final choices = _choices(h, h.chatId);
    final path = _ids(await h.engine.path(h.chatId));
    final call = h.model.prepare();
    final events = T24Events(h.engine.continueReply(h.chatId, branch.a));
    await _listening(call, events);
    call.fail(TavernFailure.server, 'empty continuation fixture');
    await call.close();
    await events.done.future;
    expect(events.values.whereType<TavernTurnFailed>().single.kind, TavernFailure.server);
    expect(_ids(await h.engine.path(h.chatId)), path);
    expect(_choices(h, h.chatId), choices);
    expect(await h.engine.readVariables(h.chatId), {'route': 'B2'});
  });

  test('selection restores local and DSH state without rerunning once rules or changing sibling audits', () async {
    final h = await _open(thinking: false);
    final chat = await _stateChat(h);
    final a = await _run(h, h.engine.send(chat, '{{setvar::route::A}}Q'), 'A');
    final editedA = await h.engine.setStateValue(chat, '/count', 1);
    expect(editedA.applied, isTrue);
    expect(editedA.snapshot.effects, hasLength(2));
    final savedA = await _saved(h.engine, chat);
    final aChild = await h.engine.sendOnly(chat, '{{setvar::route::A-child}}A child');
    final b = await _run(h, h.engine.regenerate(chat, a.nodeId), 'B');
    final editedB = await h.engine.setStateValue(chat, '/count', 2);
    expect(editedB.applied, isTrue);
    final bChild = await h.engine.narrate(chat, '{{setvar::route::B-child}}B child');
    final savedBChild = await _saved(h.engine, chat);
    // A retained physical checkpoint can differ from the portable effective
    // override. Selection must use the override without rewriting either.
    final physical = {
      'variables': {'physical': 'sentinel'},
      'messageVariables': {
        'dshgo': {'count': 77},
      },
      'foreign': ['physical'],
    };
    _db(
      h,
      (db) => db.execute('UPDATE node_states SET full_json = ?, delta_json = ? WHERE node_id = ?', [
        jsonEncode(physical),
        '[]',
        a.nodeId,
      ]),
    );
    final before = _payload(h);
    final calls = h.model.generated;
    await h.engine.selectNode(chat, a.nodeId);
    final selectedA = await h.engine.readState(chat);
    expect(selectedA.values, {'count': 1});
    expect(selectedA.changes, editedA.snapshot.changes);
    expect(selectedA.effects, editedA.snapshot.effects);
    expect(await h.engine.readVariables(chat), {'route': 'A'});
    expect(h.engine.variables(chat), {'route': 'A'});
    expect(await _saved(h.engine, chat), savedA);
    expect(_map(savedA['dshgoStateRuntime'])['firedRules'], ['id:branch-reward']);
    expect(_map(savedA['dshgoStateRuntime'])['pendingPrompts'], hasLength(1));
    await h.engine.selectNode(chat, bChild.nodeId);
    final selectedBChild = await h.engine.readState(chat);
    expect(selectedBChild.values, {'count': 2});
    expect(selectedBChild.changes, isEmpty);
    expect(selectedBChild.effects, isEmpty);
    expect(await h.engine.readAgentRuns(chat, nodeId: bChild.nodeId), isEmpty);
    expect(await h.engine.readVariables(chat), {'route': 'B-child'});
    expect(await _saved(h.engine, chat), savedBChild);
    expect(_choices(h, chat)[a.nodeId], isNull);
    expect((await h.engine.tree(chat)).any((node) => node.nodeId == aChild.nodeId), isTrue);
    expect((await h.engine.tree(chat)).any((node) => node.nodeId == b.nodeId), isTrue);
    expect(_payload(h), before);
    expect(h.model.generated, calls);
    await h.reopen();
    expect((await h.engine.readState(chat)).values, {'count': 2});
    expect(await _saved(h.engine, chat), savedBChild);
    expect(_payload(h), before);
  });

  test('an empty selected path with retained branches can select a node and round-trip an explicit stop', () async {
    final h = await _open();
    final branch = await _branches(h);
    await h.engine.deleteMessage(h.chatId, branch.otherRoot);
    expect(await h.engine.path(h.chatId), isEmpty);
    expect(await h.engine.tree(h.chatId), isNotEmpty);
    expect(await h.engine.readVariables(h.chatId), isEmpty);
    final emptyExport = await h.engine.exportChat(h.chatId);
    expect(StChatDocument.decode(emptyExport.first.fileName, emptyExport.first.bytes).messages, isEmpty);
    final imported = (await h.engine.importChats(h.characterId, emptyExport)).chatIds.single;
    expect(await h.engine.path(imported), isEmpty);
    final nodes = await h.engine.tree(imported);
    final target = nodes.singleWhere((node) => node.preview == 'A2');
    await h.engine.selectNode(imported, target.nodeId);
    expect((await h.engine.path(imported)).last.text, 'A2');
    expect(await h.engine.readVariables(imported), {'route': 'A2'});
    final stoppedExport = await h.engine.exportChat(imported);
    final restored = (await h.engine.importChats(h.characterId, stoppedExport)).chatIds.single;
    expect((await h.engine.path(restored)).last.text, 'A2');
    expect((await h.engine.tree(restored)).any((node) => node.preview == 'A3'), isTrue);
    final restoredTarget = (await h.engine.path(restored)).last.nodeId;
    await h.engine.selectNode(restored, restoredTarget, restoreDescendants: true);
    expect((await h.engine.path(restored)).last.nodeId, restoredTarget);
    await h.reopen();
    expect((await h.engine.path(restored)).last.nodeId, restoredTarget);
  });

  test('missing foreign and soft-deleted nodes fail unchanged while ST-hidden nodes remain selectable', () async {
    final h = await _open();
    final branch = await _branches(h);
    final otherChat = await h.engine.createChat(h.characterId);
    final foreign = (await h.engine.path(otherChat)).single.nodeId;
    final token = await h.engine.deleteFrom(h.chatId, branch.a1);
    final before = _db(h, _databaseRows);
    final values = h.engine.variables(h.chatId);
    for (final (chat, node) in [
      (h.chatId, 'missing-node'),
      (h.chatId, foreign),
      (otherChat, branch.b2),
      (h.chatId, branch.a2),
      ('missing-chat', branch.root),
    ]) {
      await expectLater(h.engine.selectNode(chat, node), throwsStateError);
      expect(_db(h, _databaseRows), before);
      expect(h.engine.variables(h.chatId), values);
    }
    expect(await h.engine.undoDeleteFrom(h.chatId, token), isTrue);
    expect((await h.engine.path(h.chatId)).single.nodeId, branch.otherRoot);
    await h.engine.setHidden(h.chatId, branch.b1, true);
    await h.engine.selectNode(h.chatId, branch.b1);
    expect((await h.engine.path(h.chatId)).last.nodeId, branch.b1);
    expect((await h.engine.path(h.chatId)).last.hidden, isTrue);
    expect(await h.engine.readVariables(h.chatId), {'route': 'B1'});
  });

  test('selecting waits for partial cancellation before restoring the requested path and live cache', () async {
    final h = await _open();
    final branch = await _branches(h);
    final call = h.model.prepare();
    final events = T24Events(h.engine.send(h.chatId, '{{setvar::route::RUNNING}}Q'));
    await _listening(call, events);
    final textSeen = h.engine.resumeTurn(h.chatId).where((event) => event is TavernTextDelta).first;
    call.add(const ModelText('PARTIAL'));
    await textSeen;
    final reply = events.values.whereType<TavernTurnStarted>().single.message;
    await h.engine.selectNode(h.chatId, branch.a2);
    await events.done.future;
    final failed = events.values.whereType<TavernTurnFailed>().single;
    expect(failed.kind, TavernFailure.cancelled);
    expect(failed.partial!.nodeId, reply.nodeId);
    expect(failed.partial!.text, 'PARTIAL');
    expect(call.cancellation!.isCancelled, isTrue);
    expect((await h.engine.path(h.chatId)).last.nodeId, branch.a2);
    expect(await h.engine.readVariables(h.chatId), {'route': 'A2'});
    expect(h.engine.variables(h.chatId), {'route': 'A2'});
    expect((await h.engine.inspectTurn(h.chatId, nodeId: reply.nodeId))!.status, TavernInspectionStatus.failed);
    expect((await h.engine.tree(h.chatId)).singleWhere((node) => node.nodeId == reply.nodeId).preview, 'PARTIAL');
    await h.reopen();
    expect((await h.engine.path(h.chatId)).last.nodeId, branch.a2);
    expect(h.engine.variables(h.chatId), {'route': 'A2'});
  });

  test('tool-only cancellation rolls back its empty nodes before selecting another state branch', () async {
    final h = await _open(thinking: false);
    final chat = await _stateChat(h);
    final root = (await h.engine.path(chat)).single.nodeId;
    final other = await _run(h, h.engine.regenerate(chat, root), 'OTHER');
    expect((await h.engine.setStateValue(chat, '/count', 2)).applied, isTrue);
    final before = (await h.engine.tree(chat)).map((node) => node.nodeId).toList();
    final call = h.model.prepare();
    final events = T24Events(h.engine.send(chat, '{{setvar::route::ROLLBACK}}Q'));
    await _listening(call, events);
    call.add(
      ModelToolFragment(
        index: 0,
        id: 'cancelled-call',
        type: 'function',
        name: 'update_state',
        arguments: jsonEncode({
          'ops': [
            {'op': 'set', 'path': '/count', 'value': 9, 'why': 'cancel fixture'},
          ],
        }),
      ),
    );
    await h.engine.selectNode(chat, root);
    await events.done.future;
    final failed = events.values.whereType<TavernTurnFailed>().single;
    expect(failed.kind, TavernFailure.cancelled);
    expect(failed.partial, isNull);
    expect(call.cancellation!.isCancelled, isTrue);
    expect((await h.engine.tree(chat)).map((node) => node.nodeId), before);
    expect(_ids(await h.engine.path(chat)), [root]);
    expect((await h.engine.readState(chat)).values, {'count': 0});
    expect(h.engine.variables(chat), isEmpty);
    final run = (await h.engine.readAgentRuns(chat)).singleWhere((run) => run.kind == 'state.tool');
    expect(run.nodeId, isNull);
    expect(run.result['committed'], isFalse);
    await h.engine.selectNode(chat, other.nodeId);
    expect((await h.engine.readState(chat)).values, {'count': 2});
  });

  test('a late variable SQL failure rolls back cleared edges ancestors leaf metadata revision and cache', () async {
    final h = await _open();
    final branch = await _branches(h);
    await h.engine.sendOnly(h.chatId, '{{setvar::route::CURRENT}}CURRENT');
    final before = _db(h, _databaseRows);
    final path = _ids(await h.engine.path(h.chatId));
    final values = h.engine.variables(h.chatId);
    _db(
      h,
      (db) => db.execute('''CREATE TRIGGER reject_select_node_runtime
      BEFORE UPDATE OF variables ON chats
      BEGIN SELECT RAISE(ABORT, 'select_node_runtime'); END'''),
    );
    try {
      await expectLater(h.engine.selectNode(h.chatId, branch.a2), throwsA(isA<SqliteException>()));
      expect(_db(h, _databaseRows), before);
      expect(_ids(await h.engine.path(h.chatId)), path);
      expect(await h.engine.readVariables(h.chatId), values);
      expect(h.engine.variables(h.chatId), values);
      expect(h.engine.globalVariables, {'global_route': 'keep'});
    } finally {
      _db(h, (db) => db.execute('DROP TRIGGER reject_select_node_runtime'));
    }
    await h.engine.selectNode(h.chatId, branch.a2);
    expect((await h.engine.path(h.chatId)).last.nodeId, branch.a2);
    expect(h.engine.variables(h.chatId), {'route': 'A2'});
    await h.reopen();
    expect((await h.engine.path(h.chatId)).last.nodeId, branch.a2);
    expect(h.engine.variables(h.chatId), {'route': 'A2'});
  });

  test('store default memory and arbitrary long ancestor activation remain unbounded by path pagination', () {
    final (_, store) = _store();
    final chat = store.createChat(characterId: 'card');
    final nodes = <String>[];
    store.transaction(() {
      for (var index = 0; index < 1200; index++) {
        nodes.add(_append(store, chat, '$index', parent: nodes.isEmpty ? null : nodes.last));
      }
    });
    final other = _append(store, chat, 'other root');
    store.selectNode(chat, nodes.first);
    expect(store.chat(chat).currentLeafId, nodes.last);
    store.selectNode(chat, nodes[600], restoreDescendants: false);
    expect(store.path(chat, limit: 1300), hasLength(601));
    expect(store.node(chat, nodes[601]).selectedChildId, nodes[602]);
    store.selectSibling(chat, other, 1);
    expect(store.path(chat).single.nodeId, other);
    store.selectSibling(chat, other, 0);
    expect(store.chat(chat).currentLeafId, nodes[600]);
    final deep = _append(store, chat, 'new deep leaf', parent: nodes[900]);
    expect(store.historyTo(chat, deep), hasLength(902));
    expect(store.node(chat, nodes[600]).selectedChildId, nodes[601]);
    expect(store.node(chat, nodes[900]).selectedChildId, deep);
    expect(store.node(chat, nodes[901]).selectedChildId, nodes[902]);
  });

  for (final damage in ['foreign', 'cycle', 'deleted']) {
    test('a $damage ancestor rejects selection and rolls back the target edge clear', () {
      final (database, store) = _store();
      final chat = store.createChat(characterId: 'card');
      final root = _append(store, chat, 'root');
      final middle = _append(store, chat, 'middle', parent: root);
      final leaf = _append(store, chat, 'leaf', parent: middle);
      final otherChat = store.createChat(characterId: 'foreign');
      final foreign = _append(store, otherChat, 'foreign root');
      final deleted = _append(store, chat, 'deleted root', makeCurrent: false);
      store.softDeleteFrom(chat, deleted);
      final parent = switch (damage) {
        'foreign' => foreign,
        'cycle' => leaf,
        _ => deleted,
      };
      database.execute('UPDATE nodes SET parent_id = ? WHERE id = ?', [parent, middle]);
      expect(database.select('PRAGMA foreign_key_check'), isEmpty);
      final before = _databaseRows(database);
      expect(() => store.selectNode(chat, middle, restoreDescendants: false), throwsStateError);
      expect(_databaseRows(database), before);
      expect(store.node(chat, middle).selectedChildId, leaf);
    });
  }

  for (final damage in ['foreign', 'not-child', 'cycle', 'deleted']) {
    test('a $damage remembered child fails atomically without cleaning unrelated branches', () {
      final (database, store) = _store();
      final chat = store.createChat(characterId: 'card');
      final root = _append(store, chat, 'root');
      final middle = _append(store, chat, 'middle', parent: root);
      final leaf = _append(store, chat, 'leaf', parent: middle);
      final spare = _append(store, chat, 'spare root', makeCurrent: false);
      final otherChat = store.createChat(characterId: 'foreign');
      final foreign = _append(store, otherChat, 'foreign root');
      final deleted = _append(store, chat, 'deleted child', parent: middle, makeCurrent: false);
      store.softDeleteFrom(chat, deleted);
      final child = switch (damage) {
        'foreign' => foreign,
        'not-child' => spare,
        'cycle' => middle,
        _ => deleted,
      };
      database.execute('UPDATE nodes SET selected_child_id = ? WHERE id = ?', [child, middle]);
      expect(database.select('PRAGMA foreign_key_check'), isEmpty);
      final before = _databaseRows(database);
      expect(() => store.selectNode(chat, root), throwsStateError);
      expect(_databaseRows(database), before);
      // An explicit stop only clears the root's first edge; it need not repair
      // or even traverse the now-inactive damaged remembered branch.
      store.selectNode(chat, root, restoreDescendants: false);
      expect(store.path(chat).single.nodeId, root);
      expect(store.node(chat, middle).selectedChildId, child);
      expect(store.node(chat, leaf).message.parentId, middle);
      expect(store.chat(otherChat).currentLeafId, foreign);
    });
  }
}

Future<T24Harness> _open({bool thinking = true}) async {
  final h = await T24Harness.open(thinking: thinking);
  addTearDown(h.dispose);
  return h;
}

Future<void> _listening(T24Call call, T24Events events) => Future.any<void>([
  call.listening.future,
  events.done.future.then<void>((_) {
    throw TestFailure('Turn ended before model input: ${events.values}');
  }),
]);

Future<TavernMessage> _run(T24Harness h, Stream<TavernEvent> stream, String text) async {
  final call = h.model.prepare();
  final events = T24Events(stream);
  await _listening(call, events);
  call.add(ModelText(text));
  await call.finish();
  await events.done.future;
  expect(events.values.whereType<TavernTurnFailed>(), isEmpty);
  return events.values.whereType<TavernTurnDone>().single.message;
}

typedef _Branches = ({
  String root,
  String shared,
  String a,
  String a1,
  String a2,
  String a3,
  String b,
  String b1,
  String b2,
  String otherRoot,
});

Future<_Branches> _branches(T24Harness h) async {
  final root = (await h.engine.path(h.chatId)).single.nodeId;
  final a = await _run(h, h.engine.send(h.chatId, '{{setvar::route::A}}{{setglobalvar::global_route::keep}}Q'), 'A');
  final a1 = await h.engine.sendOnly(h.chatId, '{{setvar::route::A1}}A1');
  final a2 = await h.engine.narrate(h.chatId, '{{setvar::route::A2}}A2');
  final a3 = await h.engine.sendOnly(h.chatId, '{{setvar::route::A3}}A3');
  final b = await _run(h, h.engine.regenerate(h.chatId, a.nodeId), 'B');
  final b1 = await h.engine.sendOnly(h.chatId, '{{setvar::route::B1}}B1');
  final b2 = await h.engine.narrate(h.chatId, '{{setvar::route::B2}}B2');
  final other = await _run(h, h.engine.regenerate(h.chatId, root), 'OTHER');
  return (
    root: root,
    shared: a.parentId!,
    a: a.nodeId,
    a1: a1.nodeId,
    a2: a2.nodeId,
    a3: a3.nodeId,
    b: b.nodeId,
    b1: b1.nodeId,
    b2: b2.nodeId,
    otherRoot: other.nodeId,
  );
}

Future<String> _stateChat(T24Harness h) async {
  final raw = _map(jsonDecode(utf8.decode(t24Card())));
  _map(raw['data'])['extensions'] = {
    'dshgo': {
      'v': 1,
      'state': {
        'schema': {
          'type': 'object',
          'additionalProperties': false,
          'required': ['count'],
          'properties': {
            'count': {'type': 'integer', 'default': 0},
          },
        },
        'init': {'count': 0},
        'rules': [
          {
            'id': 'branch-reward',
            'when': {
              '>': [
                {'var': 'count'},
                0,
              ],
            },
            'once': true,
            'do': [
              {'type': 'notice', 'text': 'branch reward'},
              {'type': 'prompt', 'text': 'pending branch prompt'},
            ],
          },
        ],
      },
    },
  };
  final character = await h.engine.importCard(Uint8List.fromList(utf8.encode(jsonEncode(raw))));
  return h.engine.createChat(character.id);
}

Map<String, Object?> _map(Object? value) => value! as Map<String, Object?>;
List<String> _ids(Iterable<TavernMessage> messages) => messages.map((message) => message.nodeId).toList();

T _db<T>(T24Harness h, T Function(Database db) action) {
  final database = sqlite3.open('${h.root.path}/tavern.sqlite3');
  try {
    return action(database);
  } finally {
    database.close();
  }
}

Map<String, Object?> _databaseRows(Database database) => {
  for (final table in ['chats', 'nodes', 'node_states', 'agent_runs', 'deleted_subtrees'])
    table: [for (final row in database.select('SELECT * FROM $table ORDER BY rowid')) Map<String, Object?>.from(row)],
};

Map<String, Object?> _payload(T24Harness h) => _db(
  h,
  (database) => {
    'nodes': [
      for (final row in database.select('SELECT * FROM nodes ORDER BY seq'))
        Map<String, Object?>.from(row)..remove('selected_child_id'),
    ],
    for (final table in ['node_states', 'agent_runs'])
      table: [for (final row in database.select('SELECT * FROM $table ORDER BY rowid')) Map<String, Object?>.from(row)],
  },
);

Map<String, String?> _choices(T24Harness h, String chat) => _db(
  h,
  (database) => {
    for (final row in database.select('SELECT id, selected_child_id FROM nodes WHERE chat_id = ? ORDER BY seq', [chat]))
      row['id']! as String: row['selected_child_id'] as String?,
  },
);

Future<Map<String, Object?>> _saved(TavernEngine engine, String chat) async {
  final files = await engine.exportChat(chat);
  final document = StChatDocument.decode(files.first.fileName, files.first.bytes);
  return _map(_map(_map(document.messages.last['extra'])['dshgo'])['tavernState']);
}

(Database, ChatStore) _store() {
  final database = sqlite3.openInMemory();
  final store = ChatStore.fromDatabase(database, clock: () => T24Harness.at);
  addTearDown(store.close);
  return (database, store);
}

String _append(ChatStore store, String chat, String text, {String? parent, bool makeCurrent = true}) => store
    .append(chat, parentId: parent, role: TavernRole.character, speaker: 'Guide', text: text, makeCurrent: makeCurrent)
    .nodeId;

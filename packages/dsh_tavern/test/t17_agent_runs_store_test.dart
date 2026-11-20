import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  test('agent runs snapshot nested usage and result at construction and on every read', () async {
    await _withStore((h) {
      final chat = h.chat('chat');
      h.node(chat, 'node');
      final usage = <String, Object?>{
        'tokens': 2,
        'future': <Object?>[null, '原文'],
      };
      final result = <String, Object?>{
        'version': 1,
        'invocationId': 'invocation',
        'elapsedMs': 7,
        'unknown': <String, Object?>{
          'literal': <Object?>['{{keep}}', '\uFEFF海🐋', null],
        },
      };
      final run = _run('run', chat, node: 'node', usage: usage, result: result);
      (usage['future']! as List<Object?>).clear();
      (result['unknown']! as Map<String, Object?>).clear();
      run.usage!.clear();
      run.result.clear();
      h.store.writeAgentRun(run);
      final saved = h.store.agentRuns(chat).single;
      expect(saved.id, 'run');
      expect(saved.nodeId, 'node');
      expect(saved.kind, 'state.tool');
      expect(saved.at, _at);
      expect(saved.usage, {
        'tokens': 2,
        'future': [null, '原文'],
      });
      expect(saved.result['unknown'], {
        'literal': ['{{keep}}', '\uFEFF海🐋', null],
      });
      (saved.result['unknown']! as Map<String, Object?>).clear();
      saved.usage!.clear();
      expect(h.store.agentRuns(chat).single.result, saved.result);
      expect(saved.usage, {
        'tokens': 2,
        'future': [null, '原文'],
      });
    });
  });

  test('timestamps sort newest first with reverse insertion order for equal milliseconds', () async {
    await _withStore((h) {
      final chat = h.chat('chat');
      h.store.writeAgentRun(_run('z-first', chat));
      h.store.writeAgentRun(_run('a-second', chat));
      h.store.writeAgentRun(_run('newer', chat, at: _at.add(const Duration(milliseconds: 1))));
      h.store.writeAgentRun(_run('m-third', chat));
      expect(h.store.agentRuns(chat).map((run) => run.id), ['newer', 'm-third', 'a-second', 'z-first']);
      expect(h.store.agentRuns(chat, limit: 2).map((run) => run.id), ['newer', 'm-third']);
      expect(h.store.agentRuns(chat, limit: 0), isEmpty);
      expect(() => h.store.agentRuns(chat, limit: -1), throwsArgumentError);
    });
  });

  test('the default result limit is 50 and an explicit limit can read the remaining history', () async {
    await _withStore((h) {
      final chat = h.chat('chat');
      for (var i = 0; i < 51; i++) {
        h.store.writeAgentRun(_run('run-$i', chat));
      }
      expect(h.store.agentRuns(chat), hasLength(50));
      expect(h.store.agentRuns(chat).first.id, 'run-50');
      expect(h.store.agentRuns(chat, limit: 51).last.id, 'run-0');
    });
  });

  test('node filters never merge unanchored records or another branch into the requested node', () async {
    await _withStore((h) {
      final chat = h.chat('chat');
      h.node(chat, 'root');
      h.node(chat, 'left', parent: 'root');
      h.node(chat, 'right', parent: 'root');
      h.store.writeAgentRun(_run('root-run', chat, node: 'root'));
      h.store.writeAgentRun(_run('left-run', chat, node: 'left'));
      h.store.writeAgentRun(_run('right-run', chat, node: 'right'));
      h.store.writeAgentRun(_run('unanchored', chat));
      expect(h.store.agentRuns(chat, nodeId: 'left').map((run) => run.id), ['left-run']);
      expect(h.store.agentRuns(chat, nodeId: 'right').map((run) => run.id), ['right-run']);
      expect(h.store.agentRuns(chat, nodeId: 'missing'), isEmpty);
      expect(h.store.agentRuns(chat), hasLength(4));
    });
  });

  test('a run requires an existing chat and a physical node belonging to that chat', () async {
    await _withStore((h) {
      final first = h.chat('first');
      final second = h.chat('second');
      h.node(first, 'first-node');
      h.node(second, 'second-node');
      expect(() => h.store.writeAgentRun(_run('wrong-chat', 'absent')), throwsStateError);
      expect(() => h.store.writeAgentRun(_run('wrong-node', first, node: 'absent')), throwsStateError);
      expect(() => h.store.writeAgentRun(_run('cross-chat', first, node: 'second-node')), throwsStateError);
      expect(h.database.select('SELECT * FROM agent_runs'), isEmpty);
      h.store.writeAgentRun(_run('valid', first, node: 'first-node'));
      expect(h.store.agentRuns(second, nodeId: 'first-node'), isEmpty);
      expect(h.store.agentRuns(first).single.id, 'valid');
    });
  });

  test('a soft-deleted physical node can anchor a run without invalidating undo', () async {
    await _withStore((h) {
      final chat = h.chat('chat');
      h.node(chat, 'root');
      h.node(chat, 'child', parent: 'root');
      final token = h.store.softDeleteFrom(chat, 'child');
      expect(h.store.allNodes(chat).map((node) => node.message.nodeId), ['root']);
      h.store.writeAgentRun(_run('rejected', chat, node: 'child', result: {'version': 1, 'accepted': false}));
      expect(h.store.agentRuns(chat, nodeId: 'child').single.id, 'rejected');
      expect(h.store.undoDeleteFrom(chat, token), isTrue);
      expect(h.store.path(chat).last.nodeId, 'child');
    });
  });

  test('duplicate run ids fail with ordinary INSERT and leave the first record intact', () async {
    await _withStore((h) {
      final chat = h.chat('chat');
      h.store.writeAgentRun(_run('run', chat, result: {'marker': 'original'}));
      expect(
        () => h.store.writeAgentRun(_run('run', chat, result: {'marker': 'replacement'})),
        throwsA(isA<SqliteException>()),
      );
      expect(h.store.agentRuns(chat).single.result, {'marker': 'original'});
      expect(h.database.select('PRAGMA foreign_key_check'), isEmpty);
    });
  });

  test('a late real SQL constraint failure rolls back the outer node state audit and run together', () async {
    await _withStore((h) {
      final chat = h.chat('chat');
      h.node(
        chat,
        'root',
        state: {
          'variables': {'old': 1},
        },
      );
      final beforeChats = _rows(h.database, 'SELECT * FROM chats');
      final beforeNodes = _rows(h.database, 'SELECT * FROM nodes');
      final beforeStates = _rows(h.database, 'SELECT * FROM node_states');
      expect(
        () => h.store.transaction(() {
          h.store.append(
            chat,
            id: 'candidate',
            parentId: 'root',
            role: TavernRole.character,
            speaker: '鲸',
            text: 'candidate',
            state: {
              'variables': {'old': 1},
              'messageVariables': {
                'dshgo': {'score': 5},
              },
            },
            extra: {
              'dshgo': {
                'stateChanges': [
                  {'path': '/score', 'new': 5},
                ],
              },
            },
          );
          h.store.writeAgentRun(_run('run', chat, node: 'candidate', result: {'accepted': true}));
          h.store.writeAgentRun(_run('run', chat, node: 'candidate', result: {'duplicate': true}));
        }),
        throwsA(isA<SqliteException>()),
      );
      expect(_rows(h.database, 'SELECT * FROM chats'), beforeChats);
      expect(_rows(h.database, 'SELECT * FROM nodes'), beforeNodes);
      expect(_rows(h.database, 'SELECT * FROM node_states'), beforeStates);
      expect(h.store.agentRuns(chat), isEmpty);
      expect(h.store.searchChat(chat, 'candidate'), isEmpty);
    });
  });

  test('node state and tool run commit successfully inside one caller-owned transaction', () async {
    await _withStore((h) {
      final chat = h.chat('chat');
      h.store.transaction(() {
        h.node(
          chat,
          'node',
          state: {
            'messageVariables': {
              'stat_data': {'keep': 8},
              'dshgo': {'score': 1},
            },
          },
        );
        h.store.writeAgentRun(_run('run', chat, node: 'node', result: {'version': 1, 'accepted': true}));
      });
      expect(h.store.nodeState(chat, 'node'), {
        'messageVariables': {
          'stat_data': {'keep': 8},
          'dshgo': {'score': 1},
        },
      });
      expect(h.store.agentRuns(chat, nodeId: 'node').single.result['accepted'], isTrue);
    });
  });

  test('audit-only writes leave selection revision state timestamps and change notifications alone', () async {
    await _withStore((h) async {
      final chat = h.chat('chat');
      h.node(
        chat,
        'root',
        state: {
          'messageVariables': {
            'dshgo': {'n': 1},
          },
        },
      );
      h.node(chat, 'child', parent: 'root');
      final beforeChats = _rows(h.database, 'SELECT * FROM chats');
      final beforeNodes = _rows(h.database, 'SELECT * FROM nodes');
      final beforeStates = _rows(h.database, 'SELECT * FROM node_states');
      final changes = <String>[];
      final subscription = h.store.changes.listen(changes.add);
      try {
        h.store.writeAgentRun(_run('run', chat, node: 'root'));
        await Future<void>(() {});
        expect(changes, isEmpty);
        expect(_rows(h.database, 'SELECT * FROM chats'), beforeChats);
        expect(_rows(h.database, 'SELECT * FROM nodes'), beforeNodes);
        expect(_rows(h.database, 'SELECT * FROM node_states'), beforeStates);
      } finally {
        await subscription.cancel();
      }
    });
  });

  test('permanent single-node deletion leaves its run unanchored without moving it onto a child', () async {
    await _withStore((h) {
      final chat = h.chat('chat');
      h.node(chat, 'root');
      h.node(chat, 'child', parent: 'root');
      h.store.writeAgentRun(_run('root-run', chat, node: 'root'));
      h.store.writeAgentRun(_run('child-run', chat, node: 'child'));
      h.store.deleteMessage(chat, 'root');
      final runs = h.store.agentRuns(chat);
      expect(runs.singleWhere((run) => run.id == 'root-run').nodeId, isNull);
      expect(h.store.agentRuns(chat, nodeId: 'child').map((run) => run.id), ['child-run']);
      expect(h.store.agentRuns(chat, nodeId: 'root'), isEmpty);
      expect(h.store.path(chat).single.nodeId, 'child');
    });
  });

  test('deleting a chat cascades anchored and unanchored runs without touching another chat', () async {
    await _withStore((h) {
      final first = h.chat('first');
      final second = h.chat('second');
      h.node(first, 'node');
      h.store.writeAgentRun(_run('anchored', first, node: 'node'));
      h.store.writeAgentRun(_run('unanchored', first));
      h.store.writeAgentRun(_run('other', second));
      h.store.deleteChat(first);
      expect(h.database.select('SELECT id FROM agent_runs').single['id'], 'other');
      expect(h.store.agentRuns(second).single.id, 'other');
      expect(() => h.store.agentRuns(first), throwsStateError);
    });
  });

  test('reopening preserves unknown audit fields and next-open purge only clears a deleted node anchor', () async {
    await _withStore((h) async {
      final chat = h.chat('chat');
      h.node(chat, 'root');
      h.node(chat, 'child', parent: 'root');
      final result = <String, Object?>{
        'version': 1,
        'invocationId': 'same-reply',
        'future': {
          'opaque': [null, 3, '海'],
        },
      };
      h.store.writeAgentRun(_run('visible', chat, node: 'root', result: result));
      h.store.writeAgentRun(_run('purged', chat, node: 'child', result: result));
      h.store.softDeleteFrom(chat, 'child');
      await h.reopen();
      final runs = h.store.agentRuns(chat);
      expect(runs, hasLength(2));
      expect(runs.every((run) => jsonEncode(run.result) == jsonEncode(result)), isTrue);
      expect(runs.singleWhere((run) => run.id == 'visible').nodeId, 'root');
      expect(runs.singleWhere((run) => run.id == 'purged').nodeId, isNull);
      expect(h.database.select('PRAGMA user_version').single['user_version'], ChatStore.schemaVersion);
      expect(h.database.select('PRAGMA foreign_key_check'), isEmpty);
    });
  });

  test('invalid JSON is rejected before writing and closed-store methods reject access', () async {
    await _withStore((h) async {
      final chat = h.chat('chat');
      expect(() => _run('bad', chat, result: {'notJson': double.infinity}), throwsA(isA<JsonUnsupportedObjectError>()));
      expect(h.store.agentRuns(chat), isEmpty);
      await h.store.close();
      expect(() => h.store.writeAgentRun(_run('closed', chat)), throwsStateError);
      expect(() => h.store.agentRuns(chat), throwsStateError);
    });
  });
}

final _at = DateTime.utc(2026, 11, 10, 12, 3, 4, 567);

StoredAgentRun _run(
  String id,
  String chat, {
  String? node,
  DateTime? at,
  Map<String, Object?>? usage,
  Map<String, Object?> result = const {'version': 1},
}) =>
    StoredAgentRun(id: id, chatId: chat, nodeId: node, kind: 'state.tool', at: at ?? _at, usage: usage, result: result);

Future<void> _withStore(FutureOr<void> Function(_StoreFixture) body) async {
  final directory = await Directory.systemTemp.createTemp('dsh-t17-agent-runs-');
  try {
    final h = _StoreFixture('${directory.path}/tavern.sqlite3');
    try {
      await body(h);
    } finally {
      await h.store.close();
    }
  } finally {
    await directory.delete(recursive: true);
  }
}

class _StoreFixture {
  _StoreFixture(this.path) {
    _open();
  }
  final String path;
  late Database database;
  late ChatStore store;

  void _open() {
    database = sqlite3.open(path);
    store = ChatStore.fromDatabase(database, clock: () => _at);
  }

  Future<void> reopen() async {
    await store.close();
    _open();
  }

  String chat(String id) => store.createChat(id: id, characterId: 'card');

  void node(String chat, String id, {String? parent, Map<String, Object?>? state}) {
    store.append(chat, id: id, parentId: parent, role: TavernRole.character, speaker: '鲸', text: id, state: state);
  }
}

List<Map<String, Object?>> _rows(Database database, String sql) => [
  for (final row in database.select(sql)) Map<String, Object?>.from(row),
];

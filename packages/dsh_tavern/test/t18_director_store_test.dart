import 'dart:convert';
import 'dart:io';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

// Real SQLite files and production queries. Reads neither generate nor repair
// content; publication order must not inherit wall-clock ordering.
void main() {
  test('kind queries use insertion order through clock rollback and more than fifty interleaved state runs', () async {
    final h = await _open();
    final chat = h.chat('chat');
    h.run('old-success', chat, 'director.success', at: _at.add(const Duration(days: 1)));
    h.run('new-success', chat, 'director.success', at: _at.subtract(const Duration(days: 1)));
    h.run('tick', chat, 'director.tick');
    h.run('event', chat, 'director.event');
    for (var index = 0; index < 75; index++) {
      h.run('state-$index', chat, 'state.tool', at: _at.add(const Duration(days: 2)));
    }
    h.run('failed', chat, 'director.failure', at: _at.subtract(const Duration(days: 2)));
    final before = h.rows();
    expect(h.store.agentRunsByKind(chat, {'director.success'}, limit: 1).single.id, 'new-success');
    expect(h.store.agentRunsByKind(chat, {'director.success', 'director.failure'}).map((run) => run.id), [
      'failed',
      'new-success',
      'old-success',
    ]);
    expect(h.store.agentRuns(chat).first.id, 'state-74');
    expect(h.store.agentRuns(chat), hasLength(50));
    expect(h.rows(), before);
  });

  test('rowid cursors page the selected kinds without duplicates when newer proposals arrive', () async {
    final h = await _open();
    final chat = h.chat('chat');
    h.run('event-0', chat, 'director.event');
    h.run('success', chat, 'director.success');
    h.run('event-1', chat, 'director.event');
    h.run('tick', chat, 'director.tick');
    h.run('event-2', chat, 'director.event');
    final first = h.store.agentRunsByKind(chat, {'director.event'}, limit: 2);
    expect(first.map((run) => run.id), ['event-2', 'event-1']);
    h.run('event-3', chat, 'director.event', at: _at.subtract(const Duration(days: 3)));
    final second = h.store.agentRunsByKind(chat, {'director.event'}, beforeId: first.last.id, limit: 2);
    expect(second.map((run) => run.id), ['event-0']);
    expect(h.store.agentRunsByKind(chat, {'director.event'}, beforeId: 'event-0'), isEmpty);
    expect(h.store.agentRunsByKind(chat, {'director.event'}).first.id, 'event-3');
  });

  test('missing foreign and different-kind cursors reject without broadening the requested history', () async {
    final h = await _open();
    final chat = h.chat('chat');
    final other = h.chat('other');
    h.run('local-event', chat, 'director.event');
    h.run('foreign-event', other, 'director.event');
    h.run('local-success', chat, 'director.success');
    final before = h.rows();
    for (final cursor in ['missing', 'foreign-event', 'local-success']) {
      expect(() => h.store.agentRunsByKind(chat, {'director.event'}, beforeId: cursor), throwsStateError);
    }
    expect(h.store.agentRunsByKind(chat, {}), isEmpty);
    expect(h.store.agentRunsByKind(chat, {'director.event'}, limit: 0), isEmpty);
    expect(() => h.store.agentRunsByKind(chat, {'director.event'}, limit: -1), throwsArgumentError);
    expect(() => h.store.agentRunsByKind('missing-chat', {'director.event'}), throwsStateError);
    expect(h.rows(), before);
  });

  test('valid future result objects and nested usage are preserved as detached raw documents', () async {
    final h = await _open();
    final chat = h.chat('chat');
    final result = <String, Object?>{
      'version': 99,
      'future': {
        'literal': <Object?>['{{incvar::never}}', null, true],
      },
    };
    final usage = <String, Object?>{
      'promptTokens': 3,
      'unknown': <Object?>[
        {'x': 'keep'},
      ],
    };
    h.run('future', chat, 'director.success', result: result, usage: usage);
    _map(result['future']).clear();
    (usage['unknown']! as List<Object?>).clear();
    final raw = h.rows();
    final saved = h.store.agentRunsByKind(chat, {'director.success'}).single;
    expect(saved.result, {
      'version': 99,
      'future': {
        'literal': ['{{incvar::never}}', null, true],
      },
    });
    expect(saved.usage, {
      'promptTokens': 3,
      'unknown': [
        {'x': 'keep'},
      ],
    });
    _map(saved.result['future']).clear();
    saved.usage!.clear();
    expect(h.store.agentRunsByKind(chat, {'director.success'}).single.result, saved.result);
    expect(h.rows(), raw);
  });

  test('invalid result or usage JSON is unavailable without rewriting the saved bytes', () async {
    final h = await _open();
    final chat = h.chat('chat');
    final malformed = ['{broken', '[]', 'null', '7', '"text"', '{"overflow":1e999}'];
    for (var index = 0; index < malformed.length; index++) {
      h.run('result-$index', chat, 'director.success');
      h.database.execute('UPDATE agent_runs SET result_json = ? WHERE id = ?', [malformed[index], 'result-$index']);
    }
    h.run('bad-usage', chat, 'director.failure');
    h.database.execute('UPDATE agent_runs SET usage = ? WHERE id = ?', ['{secret-invalid-usage', 'bad-usage']);
    h.run('nonfinite-usage', chat, 'director.success');
    h.database.execute('UPDATE agent_runs SET usage = ? WHERE id = ?', ['{"tokens":1e999}', 'nonfinite-usage']);
    final before = h.rows();
    final rows = h.store.agentRunsByKind(chat, {'director.success', 'director.failure'});
    expect(rows, hasLength(8));
    for (final row in rows) {
      expect(row.result, {'version': 0, 'unavailable': 'invalid_saved_director_json'});
    }
    expect(h.rows(), before);
  });

  test('deleted source anchors stay distinguishable from an intentional empty source after reopening', () async {
    final h = await _open();
    final chat = h.chat('chat');
    h.node(chat, 'root');
    h.node(chat, 'source', parent: 'root');
    h.run(
      'from-node',
      chat,
      'director.success',
      node: 'source',
      result: {'version': 1, 'sourceKind': 'node', 'sourceNodeId': 'source', 'sourceFingerprint': 'retained'},
    );
    h.run(
      'from-empty',
      chat,
      'director.success',
      result: {'version': 1, 'sourceKind': 'empty', 'sourceNodeId': null, 'sourceFingerprint': 'empty'},
    );
    h.store.softDeleteFrom(chat, 'source');
    expect(h.store.agentRunsByKind(chat, {'director.success'}).last.nodeId, 'source');
    await h.reopen();
    final runs = h.store.agentRunsByKind(chat, {'director.success'});
    final node = runs.singleWhere((run) => run.id == 'from-node');
    final empty = runs.singleWhere((run) => run.id == 'from-empty');
    expect(node.nodeId, isNull);
    expect(node.result['sourceKind'], 'node');
    expect(node.result['sourceNodeId'], 'source');
    expect(empty.nodeId, isNull);
    expect(empty.result['sourceKind'], 'empty');
    expect(empty.result['sourceNodeId'], isNull);
    expect(h.database.select('PRAGMA foreign_key_check'), isEmpty);
    expect(h.database.select('PRAGMA user_version').single['user_version'], ChatStore.schemaVersion);
  });

  test('summaries require both endpoints in source order and exclude other branches and chats', () async {
    final h = await _open();
    final chat = h.chat('chat');
    final other = h.chat('other');
    h.node(chat, 'root');
    h.node(chat, 'a', parent: 'root');
    h.node(chat, 'b', parent: 'a');
    h.node(chat, 'c', parent: 'b');
    h.node(chat, 'side', parent: 'root');
    h.node(other, 'foreign');
    h.summary('old', chat, 'root', 'a', '{{incvar::do-not-expand}} old');
    h.summary('reversed', chat, 'b', 'a', 'excluded');
    h.summary('other-branch', chat, 'side', 'b', 'excluded');
    h.summary('later-descendant', chat, 'a', 'c', 'excluded');
    h.summary('null-from', chat, null, 'a', 'excluded');
    h.summary('null-to', chat, 'a', null, 'excluded');
    h.summary('foreign-node', chat, 'foreign', 'b', 'excluded');
    h.summary('other-chat', other, 'root', 'a', 'excluded');
    h.summary('recent', chat, 'a', 'b', 'recent');
    h.summary('point', chat, 'b', 'b', 'point');
    final before = h.rows();
    final result = h.store.directorSummaries(chat, ['root', 'a', 'b']);
    expect(result.map((row) => row['id']), ['old', 'recent', 'point']);
    expect(result.first, {'id': 'old', 'fromNodeId': 'root', 'toNodeId': 'a', 'text': '{{incvar::do-not-expand}} old'});
    expect(h.store.directorSummaries(chat, ['root', 'a', 'b'], limit: 2).map((row) => row['id']), ['recent', 'point']);
    expect(h.store.directorSummaries(chat, []), isEmpty);
    expect(h.rows(), before);
  });

  test('summary reads bound the newest twenty matching rows and return detached maps', () async {
    final h = await _open();
    final chat = h.chat('chat');
    h.node(chat, 'root');
    for (var index = 0; index < 25; index++) {
      h.summary('summary-$index', chat, 'root', 'root', 'text-$index');
    }
    final before = h.rows();
    final summaries = h.store.directorSummaries(chat, ['root']);
    expect(summaries, hasLength(20));
    expect(summaries.first['id'], 'summary-5');
    expect(summaries.last['id'], 'summary-24');
    summaries.first['text'] = 'caller edit';
    expect(h.store.directorSummaries(chat, ['root']).first['text'], 'text-5');
    expect(h.store.directorSummaries(chat, ['root'], limit: 0), isEmpty);
    expect(() => h.store.directorSummaries(chat, ['root'], limit: -1), throwsArgumentError);
    expect(() => h.store.directorSummaries('missing-chat', ['root']), throwsStateError);
    expect(h.rows(), before);
  });

  test('memory reads retain insertion order native fields aliases and unknown JSON without executing macros', () async {
    final h = await _open();
    final chat = h.chat('chat');
    final other = h.chat('other');
    final first = <String, Object?>{
      'key': ['native'],
      'keywords': ['alias'],
      'constant': false,
      'pinned': true,
      '_dshgoInvalidMemoryJson': true,
      'content': '{{incvar::not-run}}',
      'future': {
        'nested': <Object?>[null, '海'],
      },
    };
    h.memory('z-first', chat, jsonEncode(first));
    h.memory('foreign', other, '{"content":"not this chat"}');
    h.memory('a-second', chat, '{"comment":"second","expiresAt":0}');
    final before = h.rows();
    final memories = h.store.directorMemories(chat);
    expect(memories.map((row) => row.id), ['z-first', 'a-second']);
    expect(memories.every((row) => row.valid), isTrue);
    expect(memories.first.entry, first);
    expect(memories.last.entry, {'comment': 'second', 'expiresAt': 0});
    _map(memories.first.entry['future']).clear();
    memories.last.entry.clear();
    expect(h.store.directorMemories(chat).first.entry, first);
    expect(h.store.directorMemories(chat).last.entry['expiresAt'], 0);
    expect(() => h.store.directorMemories('missing-chat'), throwsStateError);
    expect(h.rows(), before);
  });

  test(
    'malformed memory JSON has independent invalid status while original rows and valid neighbors survive',
    () async {
      final h = await _open();
      final chat = h.chat('chat');
      h.memory('valid-first', chat, ' {"content":" first "} ');
      final malformed = ['{bad', '[]', 'null', 'false', '"text"', '{"overflow":1e999}'];
      for (var index = 0; index < malformed.length; index++) {
        h.memory('bad-$index', chat, malformed[index]);
      }
      h.memory('valid-last', chat, '{"content":"last"}');
      final before = h.rows();
      final memories = h.store.directorMemories(chat);
      expect(memories, hasLength(8));
      expect(memories.first.entry, {'content': ' first '});
      expect(memories.last.entry, {'content': 'last'});
      expect(memories.first.valid, isTrue);
      expect(memories.last.valid, isTrue);
      for (final memory in memories.skip(1).take(6)) {
        expect(memory.valid, isFalse);
        expect(memory.entry, isEmpty);
      }
      expect(h.rows(), before);
    },
  );

  test('a real later event INSERT failure rolls the success and all its proposals back together', () async {
    final h = await _open();
    final chat = h.chat('chat');
    h.run('previous-success', chat, 'director.success', result: {'version': 1, 'notes': 'previous'});
    h.run('previous-event', chat, 'director.event');
    final before = h.rows();
    h.database.execute(
      "CREATE TRIGGER reject_late_director_event BEFORE INSERT ON agent_runs "
      "WHEN NEW.id = 'candidate-event-2' BEGIN SELECT RAISE(ABORT, 'director_event_fixture'); END",
    );
    try {
      expect(
        () => h.store.transaction(() {
          h.run('candidate-success', chat, 'director.success');
          h.run('candidate-event-1', chat, 'director.event');
          h.run('candidate-event-2', chat, 'director.event');
        }),
        throwsA(isA<SqliteException>()),
      );
      expect(h.rows(), before);
      expect(h.store.agentRunsByKind(chat, {'director.success'}, limit: 1).single.id, 'previous-success');
      expect(h.store.agentRunsByKind(chat, {'director.event'}).single.id, 'previous-event');
    } finally {
      h.database.execute('DROP TRIGGER reject_late_director_event');
    }
    h.store.transaction(() {
      h.run('candidate-success', chat, 'director.success');
      h.run('candidate-event-1', chat, 'director.event');
      h.run('candidate-event-2', chat, 'director.event');
    });
    expect(h.store.agentRunsByKind(chat, {'director.event'}).map((run) => run.id), [
      'candidate-event-2',
      'candidate-event-1',
      'previous-event',
    ]);
    expect(h.database.select('PRAGMA foreign_key_check'), isEmpty);
  });

  test(
    'reopening preserves publication cursors and raw summaries memories and future runs without migration',
    () async {
      final h = await _open();
      final chat = h.chat('chat');
      h.node(chat, 'root');
      h.run('first', chat, 'director.event', at: _at.add(const Duration(days: 2)));
      h.run('second', chat, 'director.event', at: _at.subtract(const Duration(days: 2)));
      h.run(
        'future',
        chat,
        'director.success',
        result: {
          'version': 90,
          'opaque': [1, null],
        },
      );
      h.summary('summary', chat, 'root', 'root', ' literal {{keep}} ');
      h.memory('memory', chat, ' {"content":" keep ","unknown":[null,1]} ');
      h.memory('bad-memory', chat, 'not-json');
      final before = h.rows();
      await h.reopen();
      expect(h.rows(), before);
      expect(h.store.agentRunsByKind(chat, {'director.event'}).map((run) => run.id), ['second', 'first']);
      expect(h.store.agentRunsByKind(chat, {'director.event'}, beforeId: 'second').single.id, 'first');
      expect(h.store.agentRunsByKind(chat, {'director.success'}).single.result, {
        'version': 90,
        'opaque': [1, null],
      });
      expect(h.store.directorSummaries(chat, ['root']).single['text'], ' literal {{keep}} ');
      expect(h.store.directorMemories(chat).last.valid, isFalse);
      expect(h.store.directorMemories(chat).last.entry, isEmpty);
      expect(h.rows(), before);
      expect(h.database.select('PRAGMA user_version').single['user_version'], ChatStore.schemaVersion);
    },
  );
}

final _at = DateTime.utc(2026, 11, 10, 15);
Map<String, Object?> _map(Object? value) => value! as Map<String, Object?>;

Future<_Store> _open() async {
  final directory = await Directory.systemTemp.createTemp('dsh-t18-director-store-');
  final fixture = _Store(directory);
  addTearDown(() async {
    await fixture.store.close();
    await directory.delete(recursive: true);
  });
  return fixture;
}

class _Store {
  _Store(this.directory) {
    _open();
  }
  final Directory directory;
  late Database database;
  late ChatStore store;

  void _open() {
    database = sqlite3.open('${directory.path}/tavern.sqlite3');
    store = ChatStore.fromDatabase(database, clock: () => _at);
  }

  Future<void> reopen() async {
    await store.close();
    _open();
  }

  String chat(String id) => store.createChat(id: id, characterId: 'card');
  void node(String chat, String id, {String? parent}) {
    store.append(chat, id: id, parentId: parent, role: TavernRole.character, speaker: 'Guide', text: id);
  }

  void run(
    String id,
    String chat,
    String kind, {
    String? node,
    DateTime? at,
    Map<String, Object?> result = const {'version': 1},
    Map<String, Object?>? usage,
  }) {
    store.writeAgentRun(
      StoredAgentRun(id: id, chatId: chat, nodeId: node, kind: kind, at: at ?? _at, result: result, usage: usage),
    );
  }

  void summary(String id, String chat, String? from, String? to, String text) {
    database.execute(
      'INSERT INTO summaries(id,chat_id,from_node_id,to_node_id,text,manually_edited) VALUES(?,?,?,?,?,1)',
      [id, chat, from, to, text],
    );
  }

  void memory(String id, String chat, String raw) {
    database.execute("INSERT INTO memories(id,chat_id,entry_json,origin) VALUES(?,?,?,'legacy')", [id, chat, raw]);
  }

  Map<String, Object?> rows() => {
    for (final table in ['chats', 'nodes', 'node_states', 'agent_runs', 'summaries', 'memories'])
      table: [for (final row in database.select('SELECT * FROM $table ORDER BY rowid')) Map<String, Object?>.from(row)],
  };
}

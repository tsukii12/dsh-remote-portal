import 'dart:io';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

// Exact proposal lookup is used after asynchronous turn preparation. Its
// authority must not depend on the current first page of newer publications.
void main() {
  test('an admitted proposal remains exactly readable beyond the newest page', () async {
    final h = await _open();
    final chat = h.store.createChat(id: 'chat', characterId: 'card');
    h.run(chat, 'captured:event:0', result: {'version': 1, 'name': 'open', 'data': 'original'});
    for (var index = 0; index < 96; index++) {
      h.run(chat, 'newer:event:$index', result: {'version': 1, 'data': index});
    }
    expect(h.store.agentRunsByKind(chat, {'director.event'}).any((row) => row.id == 'captured:event:0'), isFalse);
    final before = h.rows();
    final old = h.store.agentRunById(chat, 'captured:event:0');
    expect(old?.id, 'captured:event:0');
    expect(old?.kind, 'director.event');
    expect(old?.result, {'version': 1, 'name': 'open', 'data': 'original'});
    expect(h.rows(), before);
  });

  test('missing and foreign identities cannot broaden a lookup into another chat', () async {
    final h = await _open();
    final chat = h.store.createChat(id: 'chat', characterId: 'card');
    final other = h.store.createChat(id: 'other', characterId: 'card');
    h.run(other, 'foreign');
    h.run(chat, 'different-kind', kind: 'director.success');
    final before = h.rows();
    expect(h.store.agentRunById(chat, 'missing'), isNull);
    expect(h.store.agentRunById(chat, 'foreign'), isNull);
    expect(h.store.agentRunById(other, 'foreign')?.chatId, other);
    // The caller must still verify kind; exact lookup never relabels the row.
    expect(h.store.agentRunById(chat, 'different-kind')?.kind, 'director.success');
    expect(() => h.store.agentRunById('missing-chat', 'foreign'), throwsStateError);
    expect(h.rows(), before);
  });

  test('malformed exact rows are inert placeholders and their raw bytes survive reads', () async {
    final h = await _open();
    final chat = h.store.createChat(id: 'chat', characterId: 'card');
    final bad = ['{broken', 'null', '[]', '{"number":1e999}'];
    for (var index = 0; index < bad.length; index++) {
      h.run(chat, 'bad-$index');
      h.database.execute('UPDATE agent_runs SET result_json = ? WHERE id = ?', [bad[index], 'bad-$index']);
    }
    h.run(chat, 'bad-usage');
    h.database.execute('UPDATE agent_runs SET usage = ? WHERE id = ?', ['{bad-usage', 'bad-usage']);
    final before = h.rows();
    for (final id in [for (var index = 0; index < bad.length; index++) 'bad-$index', 'bad-usage']) {
      final row = h.store.agentRunById(chat, id)!;
      expect(row.id, id);
      expect(row.kind, 'director.event');
      expect(row.result, {'version': 0, 'unavailable': 'invalid_saved_director_json'});
    }
    expect(h.rows(), before);
  });

  test('future and unknown nested fields stay detached without repairing the record', () async {
    final h = await _open();
    final chat = h.store.createChat(id: 'chat', characterId: 'card');
    h.run(
      chat,
      'future',
      result: {
        'version': 99,
        'opaque': {
          'values': [null, true, '{{literal}}'],
        },
      },
    );
    final before = h.rows();
    final row = h.store.agentRunById(chat, 'future')!;
    final first = row.result;
    (first['opaque']! as Map<String, Object?>).clear();
    expect(row.result, {
      'version': 99,
      'opaque': {
        'values': [null, true, '{{literal}}'],
      },
    });
    expect(h.store.agentRunById(chat, 'future')!.result, row.result);
    expect(h.rows(), before);
  });

  test('a deleted physical source stays unanchored while exact original identity survives reopening', () async {
    final h = await _open();
    final chat = h.store.createChat(id: 'chat', characterId: 'card');
    h.store.append(chat, id: 'root', parentId: null, role: TavernRole.character, speaker: 'Guide', text: 'root');
    h.store.append(chat, id: 'source', parentId: 'root', role: TavernRole.character, speaker: 'Guide', text: 'source');
    h.run(
      chat,
      'source:event:0',
      node: 'source',
      result: {'version': 1, 'sourceKind': 'node', 'sourceNodeId': 'source', 'sourceFingerprint': 'retained'},
    );
    h.store.softDeleteFrom(chat, 'source');
    expect(h.store.agentRunById(chat, 'source:event:0')!.nodeId, 'source');
    await h.reopen();
    final before = h.rows();
    final row = h.store.agentRunById(chat, 'source:event:0')!;
    expect(row.nodeId, isNull);
    expect(row.result['sourceKind'], 'node');
    expect(row.result['sourceNodeId'], 'source');
    expect(row.result['sourceFingerprint'], 'retained');
    expect(h.database.select('PRAGMA foreign_key_check'), isEmpty);
    expect(h.rows(), before);
  });
}

Future<_Fixture> _open() async {
  final directory = await Directory.systemTemp.createTemp('dsh-t18-event-identity-');
  final fixture = _Fixture(directory);
  addTearDown(() async {
    await fixture.store.close();
    await directory.delete(recursive: true);
  });
  return fixture;
}

class _Fixture {
  _Fixture(this.directory) {
    _connect();
  }
  final Directory directory;
  late Database database;
  late ChatStore store;

  void _connect() {
    database = sqlite3.open('${directory.path}/tavern.sqlite3');
    store = ChatStore.fromDatabase(database, clock: () => DateTime.utc(2026, 11, 10));
  }

  Future<void> reopen() async {
    await store.close();
    _connect();
  }

  void run(
    String chat,
    String id, {
    String kind = 'director.event',
    String? node,
    Map<String, Object?> result = const {'version': 1},
  }) {
    store.writeAgentRun(
      StoredAgentRun(id: id, chatId: chat, nodeId: node, kind: kind, at: DateTime.utc(2026, 11, 10), result: result),
    );
  }

  List<Map<String, Object?>> rows() => [
    for (final row in database.select('SELECT * FROM agent_runs ORDER BY rowid')) Map<String, Object?>.from(row),
  ];
}

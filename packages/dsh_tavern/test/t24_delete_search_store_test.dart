import 'dart:io';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  late Directory directory;
  late String file;
  late Database database;
  late ChatStore store;
  late String chat;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('dsh-t24-delete-search-');
    file = '${directory.path}/chat.sqlite3';
    database = sqlite3.open(file);
    var serial = 0;
    store = ChatStore.fromDatabase(database, clock: () => DateTime.utc(2026, 11, 10), createId: () => 'id-${++serial}');
    chat = store.createChat(characterId: 'card');
  });
  tearDown(() async {
    await store.close();
    await directory.delete(recursive: true);
  });

  test('soft deletion hides the entire subtree and undo preserves its identity state and original data', () {
    final root = _add(store, chat, null, 'root');
    final a = _add(store, chat, root, 'lostword A', state: {'n': 1});
    final leaf = _add(
      store,
      chat,
      a,
      'lostword child',
      state: {
        'n': 2,
        'nested': [
          1,
          null,
          {'x': true},
        ],
      },
      extra: {
        'foreign': {
          'unknown': [3, 4],
        },
      },
      original: {'unrecognized': 'preserved'},
    );
    final b = _add(store, chat, root, 'replacement', makeCurrent: false);
    final bLeaf = _add(store, chat, b, 'replacement child', makeCurrent: false);
    store.selectNode(chat, bLeaf);
    store.selectNode(chat, leaf);
    final nodes = _contents(database, [a, leaf]);
    // Deletion invalidates remembered sources permanently; undo restores the
    // rows and state but must not revive their previous source epoch.
    final afterDelete = [
      for (final node in nodes) {...node, 'source_epoch': (node['source_epoch']! as int) + 1},
    ];
    final state = store.nodeState(chat, leaf);
    late String token;
    store.transaction(() {
      token = store.softDeleteFrom(chat, a);
      // Facade runtime/inspection cleanup must not invalidate this undo.
      store.updateChat(chat, variables: {'after': true}, metadata: {'foreign': 'new metadata'});
    });
    expect(_path(store, chat), [root, b, bLeaf]);
    expect(store.children(chat, root).single.message.nodeId, b);
    expect(store.message(chat, b).siblingIndex, 0);
    expect(store.message(chat, b).siblingCount, 1);
    expect(store.allNodes(chat).map((node) => node.message.nodeId), [root, b, bLeaf]);
    expect(store.search('lostword', chatId: chat), isEmpty);
    expect(store.searchChat(chat, 'lostword'), isEmpty);
    expect(_fts(database, 'lostword'), [a, leaf]);
    expect(_contents(database, [a, leaf]), afterDelete);
    for (final read in <void Function()>[
      () {
        store.message(chat, a);
      },
      () {
        store.node(chat, leaf);
      },
      () {
        store.nodeState(chat, leaf);
      },
      () {
        store.historyTo(chat, leaf);
      },
      () {
        store.children(chat, a);
      },
      () {
        store.selectNode(chat, a);
      },
      () {
        store.edit(chat, a, 'forbidden');
      },
      () {
        _add(store, chat, a, 'forbidden child');
      },
    ]) {
      expect(read, throwsStateError);
    }
    _integrity(database);
    expect(store.undoDeleteFrom(chat, token), isTrue);
    expect(_path(store, chat), [root, a, leaf]);
    expect(store.children(chat, root).map((node) => node.message.nodeId), [a, b]);
    expect(store.message(chat, b).siblingIndex, 1);
    expect(store.message(chat, b).siblingCount, 2);
    expect(store.nodeState(chat, leaf), state);
    expect(_contents(database, [a, leaf]), afterDelete);
    expect(store.chat(chat).metadata, {'foreign': 'new metadata'});
    expect(store.undoDeleteFrom(chat, token), isFalse);
    _integrity(database);
  });

  test('inactive remembered choices and explicit null stops survive deletion and undo', () {
    final root = _add(store, chat, null, 'root');
    final left = _add(store, chat, root, 'left');
    final a = _add(store, chat, left, 'A');
    final tail = _add(store, chat, a, 'stored tail');
    final other = _add(store, chat, left, 'other', makeCurrent: false);
    store.selectNode(chat, a, restoreDescendants: false);
    final right = _add(store, chat, root, 'right');
    final token = store.softDeleteFrom(chat, a);
    expect(_path(store, chat), [root, right]);
    expect(store.node(chat, left).selectedChildId, other);
    expect(store.undoDeleteFrom(chat, token), isTrue);
    expect(_path(store, chat), [root, right]);
    expect(store.node(chat, left).selectedChildId, a);
    expect(store.node(chat, a).selectedChildId, isNull);
    expect(store.node(chat, tail).message.parentId, a);
    store.selectNode(chat, left);
    expect(_path(store, chat), [root, left, a]);
  });

  test('new replies after deletion keep their current path when the old branch is restored', () {
    final root = _add(store, chat, null, 'root');
    final old = _add(store, chat, root, 'old reply', state: {'n': 1});
    final token = store.softDeleteFrom(chat, old);
    final fresh = _add(store, chat, root, 'new reply', state: {'n': 8});
    expect(store.undoDeleteFrom(chat, token), isTrue);
    expect(_path(store, chat), [root, fresh]);
    expect(store.nodeState(chat, fresh), {'n': 8});
    expect(store.children(chat, root).map((node) => node.message.nodeId), [old, fresh]);
    store.selectNode(chat, old);
    expect(store.nodeState(chat, old), {'n': 1});
  });

  test('branch ABA does not trick undo into replacing a later selection', () {
    final root = _add(store, chat, null, 'root');
    final old = _add(store, chat, root, 'old');
    final b = _add(store, chat, root, 'B', makeCurrent: false);
    final c = _add(store, chat, root, 'C', makeCurrent: false);
    final token = store.softDeleteFrom(chat, old);
    expect(_path(store, chat), [root, b]);
    store.selectNode(chat, c);
    store.selectNode(chat, b);
    expect(store.undoDeleteFrom(chat, token), isTrue);
    expect(_path(store, chat), [root, b]);
  });

  test('editing the same replacement node counts as newer work even with an unchanged clock', () {
    final root = _add(store, chat, null, 'root');
    final old = _add(store, chat, root, 'old');
    final b = _add(store, chat, root, 'B', makeCurrent: false);
    final token = store.softDeleteFrom(chat, old);
    store.updateMessage(chat, b, text: 'continued B', extra: {'state': 'new'});
    expect(store.undoDeleteFrom(chat, token), isTrue);
    expect(_path(store, chat), [root, b]);
    expect(store.node(chat, b).message.text, 'continued B');
    expect(store.node(chat, b).extra, {'state': 'new'});
  });

  test('a body-only checkpoint also keeps its active path when undo restores an older branch', () {
    final root = _add(store, chat, null, 'root');
    final old = _add(store, chat, root, 'old');
    final active = _add(store, chat, root, 'active', makeCurrent: false);
    final token = store.softDeleteFrom(chat, old);
    store.beginStreamingWrites();
    store.writeStreamingBody(chat, active, text: 'pending continuation');
    expect(store.undoDeleteFrom(chat, token), isTrue);
    expect(_path(store, chat), [root, active]);
    expect(store.message(chat, active).text, 'pending continuation');
    store.endStreamingWrites();
  });

  test('root deletion can select an empty path and can recover an explicit empty selection', () {
    final root = _add(store, chat, null, 'root');
    final leaf = _add(store, chat, root, 'leaf');
    final token = store.softDeleteFrom(chat, root);
    expect(store.path(chat), isEmpty);
    expect(store.listChats().single.messageCount, 0);
    expect(store.listChats().single.lastText, isNull);
    expect(store.undoDeleteFrom(chat, token), isTrue);
    expect(_path(store, chat), [root, leaf]);
    store.restoreSelection(chat, selectedRootId: null, selectedChildren: {root: leaf, leaf: null});
    final second = store.softDeleteFrom(chat, root);
    expect(store.undoDeleteFrom(chat, second), isTrue);
    expect(store.path(chat), isEmpty);
    expect(store.allNodes(chat), hasLength(2));
  });

  test('overlapping batches retain their tokens and require the deleted ancestor to be restored first', () {
    final root = _add(store, chat, null, 'root');
    final a = _add(store, chat, root, 'A');
    final b = _add(store, chat, a, 'B');
    final tail = _add(store, chat, b, 'tail');
    final childToken = store.softDeleteFrom(chat, b);
    final parentToken = store.softDeleteFrom(chat, a);
    expect(store.undoDeleteFrom(chat, childToken), isFalse);
    expect(database.select('SELECT id FROM deleted_subtrees'), hasLength(2));
    expect(store.undoDeleteFrom(chat, parentToken), isTrue);
    expect(_path(store, chat), [root, a]);
    expect(() => store.node(chat, b), throwsStateError);
    expect(store.undoDeleteFrom(chat, childToken), isTrue);
    expect(_path(store, chat), [root, a]);
    store.selectNode(chat, b);
    expect(_path(store, chat), [root, a, b, tail]);
    expect(database.select('SELECT id FROM deleted_subtrees'), isEmpty);
    _integrity(database);
  });

  test('hard subtree deletion still removes rows immediately including older pending batches', () {
    final root = _add(store, chat, null, 'root');
    final a = _add(store, chat, root, 'hardword');
    final b = _add(store, chat, a, 'hardword child');
    final token = store.softDeleteFrom(chat, b);
    store.deleteFrom(chat, a);
    expect(_path(store, chat), [root]);
    expect(database.select('SELECT id FROM nodes WHERE id IN (?, ?)', [a, b]), isEmpty);
    expect(database.select('SELECT id FROM deleted_subtrees'), isEmpty);
    expect(store.undoDeleteFrom(chat, token), isFalse);
    expect(_fts(database, 'hardword'), isEmpty);
    _integrity(database);
  });

  test('tokens are chat scoped and visible snapshots never require deleted nodes', () {
    final root = _add(store, chat, null, 'root');
    final child = _add(store, chat, root, 'child');
    final token = store.softDeleteFrom(chat, child);
    final otherChat = store.createChat(characterId: 'other');
    final before = _snapshot(database);
    expect(store.undoDeleteFrom(otherChat, token), isFalse);
    expect(store.undoDeleteFrom(chat, 'missing'), isFalse);
    expect(_snapshot(database), before);
    store.restoreSelection(chat, selectedRootId: root, selectedChildren: {root: null});
    expect(_path(store, chat), [root]);
  });

  for (final stage in ['mark', 'choice', 'touch']) {
    test('soft deletion rolls back every row and notification when $stage fails', () async {
      final root = _add(store, chat, null, 'root');
      final target = _add(store, chat, root, 'failword');
      final replacement = _add(store, chat, root, 'replacement', makeCurrent: false);
      final clause = switch (stage) {
        'mark' => "BEFORE UPDATE OF deleted_by ON nodes WHEN NEW.id = '$target' AND NEW.deleted_by IS NOT NULL",
        'choice' =>
          "BEFORE UPDATE OF selected_child_id ON nodes WHEN NEW.id = '$root' AND NEW.selected_child_id = '$replacement'",
        _ => 'BEFORE UPDATE OF tree_revision ON chats WHEN NEW.tree_revision > OLD.tree_revision',
      };
      database.execute("CREATE TRIGGER reject_delete $clause BEGIN SELECT RAISE(ABORT, 'fixture_delete'); END");
      final before = _snapshot(database);
      final notifications = <String>[];
      final subscription = store.changes.listen(notifications.add);
      addTearDown(subscription.cancel);
      expect(() => store.softDeleteFrom(chat, target), throwsA(isA<SqliteException>()));
      await Future<void>.delayed(Duration.zero);
      expect(_snapshot(database), before);
      expect(_path(store, chat), [root, target]);
      expect(notifications, isEmpty);
      expect(database.autocommit, isTrue);
      _integrity(database);
      database.execute('DROP TRIGGER reject_delete');
      store.softDeleteFrom(chat, target);
      await Future<void>.delayed(Duration.zero);
      expect(notifications, [chat]);
    });
  }

  test('failed undo preserves its token and can be retried atomically', () async {
    final root = _add(store, chat, null, 'root');
    final target = _add(store, chat, root, 'target');
    final token = store.softDeleteFrom(chat, target);
    database.execute('''CREATE TRIGGER reject_undo BEFORE UPDATE OF deleted_by ON nodes
      WHEN OLD.deleted_by IS NOT NULL AND NEW.deleted_by IS NULL
      BEGIN SELECT RAISE(ABORT, 'fixture_undo'); END''');
    final before = _snapshot(database);
    final notifications = <String>[];
    final subscription = store.changes.listen(notifications.add);
    addTearDown(subscription.cancel);
    expect(() => store.undoDeleteFrom(chat, token), throwsA(isA<SqliteException>()));
    await Future<void>.delayed(Duration.zero);
    expect(_snapshot(database), before);
    expect(notifications, isEmpty);
    database.execute('DROP TRIGGER reject_undo');
    expect(store.undoDeleteFrom(chat, token), isTrue);
    await Future<void>.delayed(Duration.zero);
    expect(notifications, [chat]);
    expect(_path(store, chat), [root, target]);
  });

  test('next open purges all hidden batches but preserves later selected work', () async {
    final root = _add(store, chat, null, 'root');
    final old = _add(store, chat, root, 'purgeword');
    final tail = _add(store, chat, old, 'purgeword tail');
    final token = store.softDeleteFrom(chat, old);
    final fresh = _add(store, chat, root, 'fresh', state: {'n': 9});
    await store.close();
    database = sqlite3.open(file);
    expect(database.select('SELECT id FROM nodes WHERE id IN (?, ?)', [old, tail]), hasLength(2));
    store = ChatStore.fromDatabase(database);
    expect(database.select('SELECT id FROM nodes WHERE id IN (?, ?)', [old, tail]), isEmpty);
    expect(database.select('SELECT * FROM deleted_subtrees'), isEmpty);
    expect(_path(store, chat), [root, fresh]);
    expect(store.nodeState(chat, fresh), {'n': 9});
    expect(store.undoDeleteFrom(chat, token), isFalse);
    expect(_fts(database, 'purgeword'), isEmpty);
    _integrity(database);
  });

  test('purge failure rolls back open and keeps every pending row for a later retry', () async {
    final root = _add(store, chat, null, 'root');
    final target = _add(store, chat, root, 'purgefailure');
    store.softDeleteFrom(chat, target);
    database.execute(
      "CREATE TRIGGER reject_purge BEFORE DELETE ON nodes WHEN OLD.id = '$target' BEGIN SELECT RAISE(ABORT, 'fixture_purge'); END",
    );
    final before = _snapshot(database);
    await store.close();
    expect(() => ChatStore.open(file), throwsA(isA<SqliteException>()));
    database = sqlite3.open(file);
    expect(_snapshot(database), before);
    expect(_fts(database, 'purgefailure'), [target]);
    database.execute('DROP TRIGGER reject_purge');
    store = ChatStore.fromDatabase(database);
    expect(store.allNodes(chat).map((node) => node.message.nodeId), [root]);
    _integrity(database);
  });

  test('chat search treats Chinese punctuation and wildcard characters as literal text', () {
    final target = _add(store, chat, null, '中华人民共和国 100%_done !marker a"b path\\x [box] 🙂', speaker: '说话人');
    _add(store, chat, null, '人民公园 100ZZdone marker ab path/x box', makeCurrent: false);
    final otherChat = store.createChat(characterId: 'other');
    _add(store, otherChat, null, '中华人民共和国 100%_done !marker a"b path\\x [box] 🙂', speaker: '说话人');
    for (final query in ['华', '共和', '人民共和国', '%', '_', '!', 'a"b', 'path\\x', '[box]', '🙂', '说话人']) {
      expect(store.searchChat(chat, query).map((node) => node.nodeId), [target], reason: query);
    }
    expect(store.searchChat(chat, '" OR ('), isEmpty);
  });

  test('literal search includes inactive hidden messages but excludes deleted and pending bodies', () {
    final current = _add(store, chat, null, 'oldword');
    final inactive = _add(store, chat, null, 'oldword hidden', makeCurrent: false);
    store.setHidden(chat, inactive, true);
    expect(store.searchChat(chat, 'oldword').map((node) => node.nodeId), [inactive, current]);
    final token = store.softDeleteFrom(chat, inactive);
    expect(store.searchChat(chat, 'oldword').map((node) => node.nodeId), [current]);
    expect(store.undoDeleteFrom(chat, token), isTrue);
    store.beginStreamingWrites();
    store.writeStreamingBody(chat, current, text: 'newword');
    expect(store.searchChat(chat, 'oldword').map((node) => node.nodeId), [inactive]);
    expect(store.searchChat(chat, 'newword'), isEmpty);
    store.updateMessage(chat, current, text: 'newword');
    store.endStreamingWrites();
    expect(store.searchChat(chat, 'newword').single.nodeId, current);
    _integrity(database);
  });

  test('new search validates scope and limit while old search retains full-text expressions', () {
    final first = _add(store, chat, null, 'alpha marker');
    final second = _add(store, chat, null, 'beta marker');
    final third = _add(store, chat, null, 'gamma marker');
    final other = store.createChat(characterId: 'other');
    final foreign = _add(store, other, null, 'alpha outside');
    expect(store.searchChat(chat, 'marker', limit: 2).map((node) => node.nodeId), [third, second]);
    expect(store.searchChat(chat, '  '), isEmpty);
    expect(store.searchChat(chat, 'marker', limit: 0), isEmpty);
    expect(() => store.searchChat(chat, 'marker', limit: -1), throwsArgumentError);
    expect(() => store.searchChat('missing', ''), throwsStateError);
    expect(store.search('alpha OR beta').map((node) => node.nodeId).toSet(), {first, second, foreign});
    expect(store.search('alpha', chatId: chat).single.nodeId, first);
  });
}

String _add(
  ChatStore store,
  String chat,
  String? parent,
  String text, {
  bool makeCurrent = true,
  String speaker = 'Guide',
  Map<String, Object?>? state,
  Map<String, Object?> extra = const {},
  Map<String, Object?> original = const {},
}) => store
    .append(
      chat,
      parentId: parent,
      role: TavernRole.character,
      speaker: speaker,
      text: text,
      state: state,
      makeCurrent: makeCurrent,
      extra: extra,
      original: original,
    )
    .nodeId;

List<String> _path(ChatStore store, String chat) => store.path(chat, limit: 10000).map((node) => node.nodeId).toList();

List<Map<String, Object?>> _rows(Database database, String sql, [List<Object?> parameters = const []]) => [
  for (final row in database.select(sql, parameters)) Map<String, Object?>.from(row),
];

List<Map<String, Object?>> _contents(Database database, List<String> ids) => [
  for (final row in _rows(
    database,
    'SELECT * FROM nodes WHERE id IN (${List.filled(ids.length, '?').join(',')}) ORDER BY seq',
    ids,
  ))
    Map<String, Object?>.of(row)..remove('deleted_by'),
];

Map<String, Object?> _snapshot(Database database) => {
  'chats': _rows(database, 'SELECT * FROM chats ORDER BY id'),
  'nodes': _rows(database, 'SELECT * FROM nodes ORDER BY seq'),
  'states': _rows(database, 'SELECT * FROM node_states ORDER BY node_id'),
  'deletions': _rows(database, 'SELECT * FROM deleted_subtrees ORDER BY id'),
};

List<String> _fts(Database database, String word) => [
  for (final row in database.select(
    'SELECT n.id FROM nodes_fts JOIN nodes n ON n.seq=nodes_fts.rowid WHERE nodes_fts MATCH ? ORDER BY n.seq',
    [word],
  ))
    row['id'] as String,
];

void _integrity(Database database) {
  expect(database.select('PRAGMA foreign_key_check'), isEmpty);
  database.execute("INSERT INTO nodes_fts(nodes_fts,rank) VALUES('integrity-check',1)");
}

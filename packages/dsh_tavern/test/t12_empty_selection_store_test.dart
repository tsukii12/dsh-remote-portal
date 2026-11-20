import 'package:dsh_tavern/src/api.dart';
import 'package:dsh_tavern/src/store/chat_store.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  const chat = 'chat';
  const other = 'other';
  late Database database;
  late ChatStore store;
  var now = 1000;
  var clockReads = 0;

  setUp(() {
    now = 1000;
    clockReads = 0;
    database = sqlite3.openInMemory();
    store = ChatStore.fromDatabase(
      database,
      clock: () {
        clockReads++;
        return DateTime.fromMillisecondsSinceEpoch(now, isUtc: true);
      },
    );
    for (final id in [chat, other]) {
      store.createChat(
        id: id,
        characterId: 'card',
        variables: {
          'kept': [id, null],
        },
        metadata: {
          'unknown': ['海', id],
        },
        settings: {'foreign': true},
      );
    }
  });
  tearDown(() async {
    await store.close();
  });

  String add(String id, {String chatId = chat, String? parent, bool makeCurrent = true}) => store
      .append(
        chatId,
        id: id,
        parentId: parent,
        role: TavernRole.character,
        speaker: 'Guide',
        text: 'body-$id',
        reasoning: 'reasoning-$id',
        makeCurrent: makeCurrent,
        usage: const TavernUsage(promptTokens: 3, cacheHitTokens: 1, completionTokens: 2),
        extra: {
          'foreign': [null, id],
          'dshgo': {
            'branchName': id,
            'unknown': {'kept': true},
          },
        },
        original: {
          'untouched': [id, false],
        },
        state: {
          'variables': {'branch': id},
          'opaque': [1, null],
        },
      )
      .nodeId;
  List<String> path(String chatId) => store.path(chatId).map((node) => node.nodeId).toList();

  test('clearing the active path preserves remembered branches raw payloads and other chats', () {
    final root = add('root');
    final left = add('left', parent: root);
    final leftLeaf = add('left-leaf', parent: left);
    final right = add('right', parent: root);
    final rightLeaf = add('right-leaf', parent: right);
    final stopped = add('stopped-root', makeCurrent: false);
    final marked = add('marked', parent: stopped, makeCurrent: false);
    store.softDeleteFrom(chat, marked);
    final foreign = add('foreign', chatId: other);
    final foreignLeaf = add('foreign-leaf', chatId: other, parent: foreign);
    store.writeAgentRun(
      StoredAgentRun(
        id: 'kept-audit',
        chatId: chat,
        nodeId: rightLeaf,
        kind: 'state.user',
        at: DateTime.utc(2026, 11, 10),
        result: {
          'future': [null, true],
        },
      ),
    );
    final payload = _payload(database);
    final oldChat = _chat(database, chat);
    final otherChat = _chat(database, other);
    now = 9000;

    store.clearSelection(chat);

    expect(path(chat), isEmpty);
    expect(_payload(database), payload);
    expect(_chat(database, other), otherChat);
    expect(path(other), [foreign, foreignLeaf]);
    final cleared = _chat(database, chat);
    for (final column in oldChat.keys.where(
      (column) => !{'selected_root_id', 'current_leaf_id', 'updated_at', 'tree_revision'}.contains(column),
    )) {
      expect(cleared[column], oldChat[column], reason: column);
    }
    expect(cleared['selected_root_id'], isNull);
    expect(cleared['current_leaf_id'], isNull);
    expect(cleared['updated_at'], 9000);
    expect(cleared['tree_revision'], (oldChat['tree_revision']! as int) + 1);
    expect(store.node(chat, root).selectedChildId, right);
    expect(store.node(chat, left).selectedChildId, leftLeaf);
    expect(store.node(chat, stopped).selectedChildId, isNull);
    expect(database.select('PRAGMA foreign_key_check'), isEmpty);

    store.selectNode(chat, root);
    expect(path(chat), [root, right, rightLeaf]);
    store.selectNode(chat, left);
    expect(path(chat), [root, left, leftLeaf]);
    store.selectNode(chat, stopped);
    expect(path(chat), [stopped]);
  });

  test('already empty selections do not change rows clock revision or notifications', () async {
    final retained = add('retained');
    add('retained-leaf', parent: retained);
    store.clearSelection(chat);
    // The second chat has no nodes; the first keeps visible unselected roots.
    final before = _snapshot(database);
    final reads = clockReads;
    now = 9000;
    await Future<void>.delayed(Duration.zero);
    final changes = <String>[];
    final subscription = store.changes.listen(changes.add);
    try {
      store.clearSelection(chat);
      store.clearSelection(other);
      store.clearSelection(chat);
      await Future<void>.delayed(Duration.zero);
      expect(_snapshot(database), before);
      expect(clockReads, reads);
      expect(changes, isEmpty);
    } finally {
      await subscription.cancel();
    }
  });

  test('a later SQL failure rolls back the outer selection change and publishes no partial notification', () async {
    final root = add('root');
    final leaf = add('leaf', parent: root);
    database.execute('''CREATE TRIGGER reject_clear_followup BEFORE UPDATE OF variables ON chats
      WHEN NEW.id = 'chat' BEGIN SELECT RAISE(ABORT, 'clear followup'); END''');
    final before = _snapshot(database);
    await Future<void>.delayed(Duration.zero);
    final changes = <String>[];
    final subscription = store.changes.listen(changes.add);
    try {
      expect(
        () => store.transaction(() {
          store.clearSelection(chat);
          store.updateChat(chat, variables: {'mustRollBack': true});
        }),
        throwsA(isA<SqliteException>()),
      );
      await Future<void>.delayed(Duration.zero);
      expect(_snapshot(database), before);
      expect(path(chat), [root, leaf]);
      expect(store.node(chat, root).selectedChildId, leaf);
      expect(changes, isEmpty);
      expect(database.autocommit, isTrue);
      database.execute('DROP TRIGGER reject_clear_followup');

      store.transaction(() {
        store.clearSelection(chat);
        store.updateChat(chat, variables: {'committed': true});
      });
      await Future<void>.delayed(Duration.zero);
      expect(path(chat), isEmpty);
      expect(store.node(chat, root).selectedChildId, leaf);
      expect(store.chat(chat).variables, {'committed': true});
      expect(changes, [chat]);
      expect(database.select('PRAGMA foreign_key_check'), isEmpty);
    } finally {
      await subscription.cancel();
    }
  });

  test('missing chats and closed stores are rejected before clearing any selection', () async {
    final root = add('root');
    final before = _snapshot(database);
    expect(() => store.clearSelection('missing'), throwsStateError);
    expect(_snapshot(database), before);
    expect(path(chat), [root]);
    await store.close();
    expect(() => store.clearSelection(chat), throwsStateError);
    expect(() => store.clearSelection('missing'), throwsStateError);
  });
}

Map<String, Object?> _chat(Database database, String id) =>
    Map<String, Object?>.from(database.select('SELECT * FROM chats WHERE id = ?', [id]).single);

Map<String, Object?> _payload(Database database) => {
  for (final table in ['nodes', 'node_states', 'deleted_subtrees', 'agent_runs'])
    table: [
      for (final row in database.select('SELECT rowid AS storage_rowid, * FROM $table ORDER BY rowid'))
        Map<String, Object?>.from(row),
    ],
};

Map<String, Object?> _snapshot(Database database) => {
  ..._payload(database),
  'chats': [for (final row in database.select('SELECT * FROM chats ORDER BY id')) Map<String, Object?>.from(row)],
};

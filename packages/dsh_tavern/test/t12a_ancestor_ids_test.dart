import 'package:dsh_tavern/src/api.dart';
import 'package:dsh_tavern/src/store/chat_store.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

// Identity membership intentionally does not decode message documents. Full
// history and source/leaf reads retain their existing decoding obligations.
void main() {
  late Database database;
  late ChatStore store;
  setUp(() {
    database = sqlite3.openInMemory();
    store = ChatStore.fromDatabase(database, clock: () => DateTime.utc(2026, 1, 2));
  });
  tearDown(() async {
    await store.close();
  });

  String chat(String id) => store.createChat(id: id, characterId: 'card');
  TavernMessage append(String chatId, String id, {String? parent, bool hidden = false, bool makeCurrent = true}) =>
      store.append(
        chatId,
        id: id,
        parentId: parent,
        role: TavernRole.character,
        speaker: 'Guide',
        text: id,
        hidden: hidden,
        makeCurrent: makeCurrent,
      );

  test('identity traversal returns the complete ordered chain beyond both history window sizes', () {
    final id = chat('long');
    store.transaction(() {
      for (var i = 0; i < 2049; i++) {
        _insert(database, id, 'n$i', parent: i == 0 ? null : 'n${i - 1}', depth: i + 1);
      }
      _select(database, id, 'n0', 'n2048');
    });
    final before = _rows(database);
    expect(store.ancestorIds(id, 'n2048'), List.generate(2049, (i) => 'n$i'));
    expect(store.ancestorIds(id, 'n12'), List.generate(13, (i) => 'n$i'));
    expect(store.path(id).map((message) => message.nodeId), List.generate(60, (i) => 'n${1989 + i}'));
    expect(_rows(database), before);
  });

  test('inactive and hidden nodes belong to their own ancestry without moving remembered selections', () {
    final id = chat('branches');
    append(id, 'root');
    append(id, 'a', parent: 'root', hidden: true);
    append(id, 'a-leaf', parent: 'a');
    append(id, 'b', parent: 'root');
    append(id, 'b-leaf', parent: 'b');
    append(id, 'other-root', makeCurrent: false);
    final before = _rows(database);
    final ids = store.ancestorIds(id, 'a-leaf');
    expect(ids, ['root', 'a', 'a-leaf']);
    expect(store.ancestorIds(id, 'other-root'), ['other-root']);
    expect(store.historyTo(id, 'a-leaf')[1].message.hidden, isTrue);
    ids.clear();
    expect(store.ancestorIds(id, 'a-leaf'), ['root', 'a', 'a-leaf']);
    expect(store.chat(id).currentLeafId, 'b-leaf');
    expect(store.node(id, 'root').selectedChildId, 'b');
    expect(_rows(database), before);
  });

  test('parent links determine root-to-leaf order independently of seq timestamp and stored depth', () {
    final id = chat('unordered');
    store.transaction(() {
      _insert(database, id, 'leaf', parent: 'middle', depth: 9, at: 1);
      _insert(database, id, 'root', depth: 5, at: 300);
      _insert(database, id, 'middle', parent: 'root', depth: 99, at: 10);
      _select(database, id, 'root', 'leaf');
    });
    expect(store.ancestorIds(id, 'leaf'), ['root', 'middle', 'leaf']);
    expect(store.historyTo(id, 'leaf').map((node) => node.depth), [5, 99, 9]);
    expect(store.path(id).map((message) => message.nodeId), ['root', 'middle', 'leaf']);
  });

  test('null leaf keeps an empty result but does not bypass missing chat or closed store validation', () async {
    final id = chat('empty');
    expect(store.ancestorIds(id, null), isEmpty);
    expect(() => store.ancestorIds('missing-chat', null), throwsStateError);
    expect(() => store.ancestorIds(id, 'missing-node'), throwsStateError);
    append(id, 'root');
    expect(store.ancestorIds(id, null), isEmpty);
    expect(store.ancestorIds(id, 'root'), ['root']);
    await store.close();
    expect(() => store.ancestorIds(id, null), throwsStateError);
    expect(() => store.ancestorIds(id, 'root'), throwsStateError);
  });

  test('foreign leaves and cross-chat parent pointers reject rather than leaking another chat', () {
    final first = chat('first');
    final second = chat('second');
    append(first, 'local');
    append(second, 'foreign');
    final before = _rows(database);
    expect(() => store.ancestorIds(first, 'foreign'), throwsStateError);
    expect(_rows(database), before);
    // Physical foreign keys are global; ancestry must also check chat_id.
    database.execute("UPDATE nodes SET parent_id = 'foreign' WHERE id = 'local'");
    final corrupt = _rows(database);
    expect(() => store.ancestorIds(first, 'local'), throwsStateError);
    expect(() => store.historyTo(first, 'local'), throwsStateError);
    expect(store.ancestorIds(second, 'foreign'), ['foreign']);
    expect(_rows(database), corrupt);
  });

  test('a missing parent rejects a full identity chain while the old finite page boundary remains unchanged', () {
    final id = chat('orphan');
    database.execute('PRAGMA foreign_keys = OFF');
    _insert(database, id, 'leaf', parent: 'missing');
    _select(database, id, 'leaf', 'leaf');
    database.execute('PRAGMA foreign_keys = ON');
    final before = _rows(database);
    expect(() => store.ancestorIds(id, 'leaf'), throwsStateError);
    expect(() => store.historyTo(id, 'leaf'), throwsStateError);
    expect(store.path(id, limit: 1).single.nodeId, 'leaf');
    expect(_rows(database), before);
  });

  test('stable recursive identities terminate self and two-node cycles before reconstruction rejects them', () {
    final first = chat('self-cycle');
    append(first, 'self');
    database.execute("UPDATE nodes SET parent_id = id WHERE id = 'self'");
    final second = chat('pair-cycle');
    append(second, 'a');
    append(second, 'b', parent: 'a');
    database.execute("UPDATE nodes SET parent_id = 'b' WHERE id = 'a'");
    final before = _rows(database);
    expect(() => store.ancestorIds(first, 'self'), throwsStateError);
    expect(() => store.ancestorIds(second, 'b'), throwsStateError);
    expect(() => store.historyTo(second, 'b'), throwsStateError);
    expect(store.path(first, limit: 1).single.nodeId, 'self');
    expect(store.path(second, limit: 2).map((message) => message.nodeId), ['a', 'b']);
    expect(_rows(database), before);
  });

  test('soft-deleted identities are excluded and undo restores the same branch without deleting its state', () {
    final id = chat('visibility');
    append(id, 'root');
    append(id, 'a', parent: 'root');
    append(id, 'a-leaf', parent: 'a', hidden: true);
    append(id, 'b', parent: 'root');
    final delta = database.select("SELECT delta_json FROM node_states WHERE node_id = 'a-leaf'").single['delta_json'];
    database.execute('UPDATE node_states SET full_json = ? WHERE node_id = ?', ['{"kept":3}', 'a-leaf']);
    final token = store.softDeleteFrom(id, 'a');
    final before = _rows(database);
    expect(() => store.ancestorIds(id, 'a'), throwsStateError);
    expect(() => store.ancestorIds(id, 'a-leaf'), throwsStateError);
    expect(store.ancestorIds(id, 'b'), ['root', 'b']);
    expect(_rows(database), before);
    expect(store.undoDeleteFrom(id, token), isTrue);
    expect(store.ancestorIds(id, 'a-leaf'), ['root', 'a', 'a-leaf']);
    expect(
      database.select("SELECT full_json FROM node_states WHERE node_id = 'a-leaf'").single['full_json'],
      '{"kept":3}',
    );
    expect(database.select("SELECT delta_json FROM node_states WHERE node_id = 'a-leaf'").single['delta_json'], delta);
    expect(store.nodeState(id, 'a-leaf'), {'kept': 3});
  });

  test('a visible child behind a deleted ancestor cannot produce a silently truncated membership path', () {
    final id = chat('deleted-parent');
    append(id, 'root');
    append(id, 'parent', parent: 'root');
    append(id, 'leaf', parent: 'parent');
    store.softDeleteFrom(id, 'parent');
    database.execute("UPDATE nodes SET deleted_by = NULL WHERE id = 'leaf'");
    final before = _rows(database);
    expect(() => store.ancestorIds(id, 'leaf'), throwsStateError);
    expect(() => store.historyTo(id, 'leaf'), throwsStateError);
    expect(store.ancestorIds(id, 'root'), ['root']);
    expect(_rows(database), before);
  });

  test('irrelevant malformed documents do not block membership and full source or leaf reads still validate them', () {
    final id = chat('documents');
    append(id, 'source');
    append(id, 'middle', parent: 'source');
    append(id, 'leaf', parent: 'middle');
    for (final position in ['middle', 'source', 'leaf']) {
      for (final column in ['extra', 'original']) {
        database.execute('UPDATE nodes SET $column = ? WHERE id = ?', ['{broken-$position-$column', position]);
        final before = _rows(database);
        expect(store.ancestorIds(id, 'leaf'), ['source', 'middle', 'leaf']);
        expect(() => store.historyTo(id, 'leaf'), throwsFormatException);
        expect(() => store.node(id, position), throwsFormatException);
        if (position == 'middle') {
          expect(store.node(id, 'source').message.text, 'source');
          expect(store.node(id, 'leaf').message.text, 'leaf');
        }
        expect(_rows(database), before);
        database.execute('UPDATE nodes SET $column = ? WHERE id = ?', ['{}', position]);
      }
    }
    expect(store.historyTo(id, 'leaf').map((node) => node.message.nodeId), ['source', 'middle', 'leaf']);
  });

  test('full history keeps streaming body sibling and stored document projections alongside narrow identities', () {
    final id = chat('projection');
    append(id, 'root');
    store.append(
      id,
      id: 'reply',
      parentId: 'root',
      role: TavernRole.character,
      speaker: 'Guide',
      text: 'old',
      reasoning: 'old reasoning',
      hidden: true,
      usage: const TavernUsage(promptTokens: 7, completionTokens: 2),
      extra: {
        'dshgo': {
          'inspection': {'status': 'completed'},
          'keep': 1,
        },
        'opaque': [1, null],
      },
      original: {'source': 'retained'},
    );
    append(id, 'sibling', parent: 'root', makeCurrent: false);
    store.beginStreamingWrites();
    try {
      store.writeStreamingBody(id, 'reply', text: 'streamed', reasoning: null);
    } finally {
      store.endStreamingWrites();
    }
    final before = _rows(database);
    expect(store.ancestorIds(id, 'reply'), ['root', 'reply']);
    final reply = store.historyTo(id, 'reply').last;
    expect(reply.message.text, 'streamed');
    expect(reply.message.reasoning, isNull);
    expect(reply.message.usage, isNull);
    expect(reply.message.hidden, isTrue);
    expect(reply.message.siblingCount, 2);
    expect(reply.message.siblingIndex, 0);
    expect(reply.extra, {
      'dshgo': {'keep': 1},
      'opaque': [1, null],
    });
    expect(reply.original, {'source': 'retained'});
    expect(_rows(database), before);
  });

  test('shared helper still supports sibling memory exact stops and exclusive full-path pages', () {
    final id = chat('selection');
    append(id, 'root');
    append(id, 'a', parent: 'root');
    append(id, 'a-leaf', parent: 'a');
    append(id, 'b', parent: 'root');
    append(id, 'b-leaf', parent: 'b');
    expect(store.ancestorIds(id, 'a-leaf'), ['root', 'a', 'a-leaf']);
    store.selectSibling(id, 'b', 0);
    expect(store.chat(id).currentLeafId, 'a-leaf');
    expect(store.path(id, limit: 1).single.nodeId, 'a-leaf');
    expect(store.path(id, beforeNodeId: 'a-leaf').map((message) => message.nodeId), ['root', 'a']);
    expect(() => store.path(id, beforeNodeId: 'b'), throwsStateError);
    store.selectNode(id, 'b');
    expect(store.chat(id).currentLeafId, 'b-leaf');
    store.selectNode(id, 'a', restoreDescendants: false);
    expect(store.chat(id).currentLeafId, 'a');
    expect(store.path(id).map((message) => message.nodeId), ['root', 'a']);
    expect(store.ancestorIds(id, 'a-leaf'), ['root', 'a', 'a-leaf']);
    expect(store.node(id, 'a').selectedChildId, isNull);
  });
}

void _insert(Database database, String chatId, String id, {String? parent, int depth = 1, int at = 1000}) {
  database.execute(
    '''INSERT INTO nodes(id, chat_id, parent_id, depth, role, speaker, text, at)
    VALUES (?, ?, ?, ?, 'character', 'Guide', ?, ?)''',
    [id, chatId, parent, depth, 'body-$id', at],
  );
}

void _select(Database database, String chatId, String root, String leaf) {
  database.execute('UPDATE chats SET selected_root_id = ?, current_leaf_id = ? WHERE id = ?', [root, leaf, chatId]);
}

Map<String, Object?> _rows(Database database) => {
  for (final table in ['chats', 'nodes', 'node_states', 'deleted_subtrees'])
    table: [for (final row in database.select('SELECT * FROM $table ORDER BY rowid')) Map<String, Object?>.from(row)],
};

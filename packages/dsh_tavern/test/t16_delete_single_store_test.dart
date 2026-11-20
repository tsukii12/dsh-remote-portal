import 'dart:convert';
import 'dart:io';

import 'package:dsh_tavern/src/api.dart';
import 'package:dsh_tavern/src/store/chat_store.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

// Real SQLite, deterministic clock/data, no model or macro replay.
void main() {
  const chat = 'chat';
  late ChatStore store;
  late Database database;
  var milliseconds = 1000;

  ChatStore open(Database connection) =>
      ChatStore.fromDatabase(connection, clock: () => DateTime.fromMillisecondsSinceEpoch(milliseconds, isUtc: true));
  void createChat() {
    store.createChat(
      id: chat,
      characterId: 'card',
      metadata: {
        'unknown': ['keep', null],
      },
      variables: {'chatLevel': 'facade-owned'},
      settings: {'future': true},
    );
  }

  setUp(() {
    milliseconds = 1000;
    database = sqlite3.openInMemory();
    store = open(database);
    createChat();
  });
  tearDown(() async {
    await store.close();
  });

  String add(String id, {String? parent, Map<String, Object?>? state, bool makeCurrent = true, bool hidden = false}) {
    milliseconds += 10;
    return store
        .append(
          chat,
          id: id,
          parentId: parent,
          role: TavernRole.character,
          speaker: 'whale',
          text: id,
          reasoning: 'reasoning $id',
          at: DateTime.fromMillisecondsSinceEpoch(milliseconds, isUtc: true),
          hidden: hidden,
          makeCurrent: makeCurrent,
          usage: const TavernUsage(promptTokens: 12, cacheHitTokens: 3, completionTokens: 4, model: 'fixture'),
          extra: {
            'future': {
              'name': id,
              'values': [null, 1, '海'],
            },
          },
          original: {'unknown': id, 'futureNull': null},
          state: state,
        )
        .nodeId;
  }

  List<String> path() => store.path(chat, limit: 2000).map((message) => message.nodeId).toList();
  Map<String, Map<String, Object?>> states() => {
    for (final node in store.allNodes(chat)) node.message.nodeId: store.nodeState(chat, node.message.nodeId),
  };
  List<Map<String, Object?>> rows(String query) => [
    for (final row in database.select(query)) Map<String, Object?>.from(row),
  ];
  Map<String, Object?> contents() => {
    for (final row in rows('''SELECT seq, id, chat_id, role, speaker, text, reasoning,
        at, hidden, usage, extra, original, stream_text, stream_reasoning, deleted_by, reported_usage
        FROM nodes ORDER BY seq'''))
      row['id'] as String: row,
  };
  String snapshot() => jsonEncode({
    'chats': rows('SELECT * FROM chats ORDER BY id'),
    'nodes': rows('SELECT * FROM nodes ORDER BY seq'),
    'states': rows('SELECT * FROM node_states ORDER BY node_id'),
    'deletions': rows('SELECT * FROM deleted_subtrees ORDER BY id'),
  });
  void checkDepths() {
    final nodes = {for (final node in store.allNodes(chat)) node.message.nodeId: node};
    for (final node in nodes.values) {
      final parent = node.message.parentId;
      expect(node.depth, parent == null ? 1 : nodes[parent]!.depth + 1, reason: node.message.nodeId);
    }
    expect(database.select('PRAGMA foreign_key_check'), isEmpty);
  }

  int deltaSteps(String nodeId) {
    String? cursor = nodeId;
    var steps = 0;
    while (cursor != null) {
      final row = database
          .select(
            '''SELECT n.parent_id, s.full_json FROM nodes n
        JOIN node_states s ON s.node_id = n.id WHERE n.id = ?''',
            [cursor],
          )
          .single;
      if (row['full_json'] != null) {
        break;
      }
      steps++;
      cursor = row['parent_id'] as String?;
    }
    return steps;
  }

  void checkDeltaBound() {
    for (final node in store.allNodes(chat)) {
      expect(deltaSteps(node.message.nodeId), lessThanOrEqualTo(19), reason: node.message.nodeId);
    }
  }

  test('internal deletion preserves every child and merges siblings in original sequence order', () {
    final root = add('root', state: {'n': 0});
    final before = add('before', parent: root, makeCurrent: false, state: {'n': -1});
    final target = add('targetneedle', parent: root, state: {'n': 1, 'remove': true});
    final a = add('alpha', parent: target, state: {'n': 2, 'stChatId': 'A', 'stChatIdHash': 0});
    final aLeaf = add('alphaleaf', parent: a, state: {'n': 3, 'stChatId': 'A', 'stChatIdHash': null});
    final after = add('after', parent: root, makeCurrent: false, state: {'n': 8});
    final b = add('beta', parent: target, state: {'n': 20, 'stChatId': 'B', 'stChatIdHash': 12.5});
    final bLeaf = add(
      'betaleaf',
      parent: b,
      state: {
        'n': 21,
        'nested': [
          1,
          {'x': null},
        ],
      },
    );
    store.selectNode(chat, a);
    final oldPath = path();
    final oldStates = states()..remove(target);
    final oldContents = contents()..remove(target);
    final oldChat = store.chat(chat);
    milliseconds = 5000;

    store.deleteMessage(chat, target);

    expect(path(), oldPath.where((id) => id != target));
    expect(store.chat(chat).currentLeafId, aLeaf);
    expect(store.node(chat, root).selectedChildId, a);
    expect(store.node(chat, a).selectedChildId, aLeaf);
    expect(store.node(chat, b).selectedChildId, bLeaf);
    final siblings = store.children(chat, root);
    expect(siblings.map((node) => node.message.nodeId), [before, a, after, b]);
    expect(siblings.map((node) => node.message.siblingIndex), [0, 1, 2, 3]);
    expect(siblings.map((node) => node.message.siblingCount), [4, 4, 4, 4]);
    expect(states(), oldStates);
    expect(contents(), oldContents);
    expect(store.chat(chat).metadata, oldChat.metadata);
    expect(store.chat(chat).variables, oldChat.variables);
    expect(store.chat(chat).settings, oldChat.settings);
    expect(store.chat(chat).updatedAt.millisecondsSinceEpoch, 5000);
    expect(store.search('targetneedle'), isEmpty);
    expect(store.search('alphaleaf').single.nodeId, aLeaf);
    expect(store.search('betaleaf').single.nodeId, bLeaf);
    expect(() => store.nodeState(chat, target), throwsStateError);
    for (final child in [a, b]) {
      final row = database.select('SELECT * FROM node_states WHERE node_id = ?', [child]).single;
      expect(row['delta_json'], '[]');
      expect(jsonDecode(row['full_json'] as String), oldStates[child]);
    }
    checkDepths();
  });

  test('deleting a selected root promotes its children without choosing another root', () {
    final other = add('other');
    final otherLeaf = add('otherleaf', parent: other);
    final target = add('target');
    final a = add('alpha', parent: target, state: {'n': 1});
    final leaf = add('leaf', parent: a, state: {'n': 2});
    final later = add('later');
    final b = add('beta', parent: target, state: {'n': 3});
    store.selectNode(chat, a);
    final oldStates = states()..remove(target);

    store.deleteMessage(chat, target);

    expect(path(), [a, leaf]);
    expect(store.chat(chat).selectedRootId, a);
    expect(store.chat(chat).currentLeafId, leaf);
    expect(store.children(chat, null).map((node) => node.message.nodeId), [other, a, later, b]);
    expect(store.node(chat, other).selectedChildId, otherLeaf);
    expect(states(), oldStates);
    checkDepths();
  });

  test('deleting the active stop returns to its parent and leaves all children inactive', () {
    final root = add('root', state: {'n': 7});
    final sibling = add('sibling', parent: root);
    final target = add('target', parent: root, state: {'n': 8});
    final child = add('child', parent: target, state: {'n': 9});
    store.selectNode(chat, target, restoreDescendants: false);
    store.deleteMessage(chat, target);
    expect(path(), [root]);
    expect(store.chat(chat).currentLeafId, root);
    expect(store.node(chat, root).selectedChildId, isNull);
    expect(store.children(chat, root).map((node) => node.message.nodeId), [sibling, child]);
    expect(store.nodeState(chat, root), {'n': 7});
    expect(store.nodeState(chat, child), {'n': 9});
    store.selectNode(chat, root);
    expect(path(), [root]);
    checkDepths();
  });

  test('deleting the sole root leaves an empty chat and removes its state and search hit', () {
    final root = add('soleneedle', state: {'n': 1});
    store.deleteMessage(chat, root);
    expect(path(), isEmpty);
    expect(store.allNodes(chat), isEmpty);
    expect(store.chat(chat).selectedRootId, isNull);
    expect(store.chat(chat).currentLeafId, isNull);
    expect(database.select('SELECT * FROM node_states'), isEmpty);
    expect(store.search('soleneedle'), isEmpty);
    expect(store.listChats().single.messageCount, 0);
    checkDepths();
  });

  test('a terminal leaf returns to its parent even when sibling branches have descendants', () {
    final root = add('root', state: {'n': 1});
    final sibling = add('sibling', parent: root, state: {'n': 10});
    final otherLeaf = add('otherleaf', parent: sibling, state: {'n': 11});
    final target = add('target', parent: root, state: {'n': 2});
    store.deleteMessage(chat, target);
    expect(path(), [root]);
    expect(store.node(chat, root).selectedChildId, isNull);
    expect(store.node(chat, sibling).selectedChildId, otherLeaf);
    expect(store.nodeState(chat, root), {'n': 1});
    expect(store.nodeState(chat, otherLeaf), {'n': 11});
    checkDepths();
  });

  test('deleting a root stop selects an empty path while retaining promoted alternatives', () {
    final target = add('target');
    final child = add('child', parent: target, state: {'kept': true});
    final alternative = add('alternative');
    store.selectNode(chat, target, restoreDescendants: false);
    store.deleteMessage(chat, target);
    expect(path(), isEmpty);
    expect(store.chat(chat).selectedRootId, isNull);
    expect(store.chat(chat).currentLeafId, isNull);
    expect(store.children(chat, null).map((node) => node.message.nodeId), [child, alternative]);
    expect(store.nodeState(chat, child), {'kept': true});
    checkDepths();
  });

  test('inactive remembered selection follows the deleted nodes remembered child', () {
    final root = add('root');
    final inactive = add('inactive', parent: root);
    final target = add('target', parent: inactive);
    final chosen = add('chosen', parent: target);
    final leaf = add('leaf', parent: chosen);
    add('unchosen', parent: target, makeCurrent: false);
    final active = add('active', parent: root);
    final activeLeaf = add('activeleaf', parent: active);
    final oldPath = path();
    store.deleteMessage(chat, target);
    expect(path(), oldPath);
    expect(store.chat(chat).currentLeafId, activeLeaf);
    expect(store.node(chat, inactive).selectedChildId, chosen);
    expect(store.node(chat, chosen).selectedChildId, leaf);
    store.selectNode(chat, inactive);
    expect(path(), [root, inactive, chosen, leaf]);
    checkDepths();
  });

  test('inactive null stop is transferred to the parent rather than an arbitrary child', () {
    final root = add('root');
    final inactive = add('inactive', parent: root);
    final sibling = add('sibling', parent: inactive);
    final target = add('target', parent: inactive);
    final hidden = add('hidden', parent: target, hidden: true);
    store.selectNode(chat, target, restoreDescendants: false);
    final active = add('active', parent: root);
    final before = path();
    store.deleteMessage(chat, target);
    expect(path(), before);
    expect(store.chat(chat).currentLeafId, active);
    expect(store.node(chat, inactive).selectedChildId, isNull);
    expect(store.children(chat, inactive).map((node) => node.message.nodeId), [sibling, hidden]);
    expect(store.message(chat, hidden).hidden, isTrue);
    store.selectNode(chat, inactive);
    expect(path(), [root, inactive]);
    checkDepths();
  });

  test('deleting an unselected child leaves the parents other selection unchanged', () {
    final root = add('root');
    final target = add('target', parent: root);
    final child = add('child', parent: target);
    final descendant = add('descendant', parent: child);
    final selected = add('selected', parent: root);
    final selectedLeaf = add('selectedleaf', parent: selected);
    store.deleteMessage(chat, target);
    expect(path(), [root, selected, selectedLeaf]);
    expect(store.node(chat, root).selectedChildId, selected);
    expect(store.node(chat, child).selectedChildId, descendant);
    store.selectNode(chat, child);
    expect(path(), [root, child, descendant]);
    checkDepths();
  });

  test('a deliberately empty current path stays empty when an inactive root is removed', () {
    final target = add('target');
    final child = add('child', parent: target);
    final leaf = add('leaf', parent: child);
    store.restoreSelection(chat, selectedRootId: null, selectedChildren: {target: child, child: leaf, leaf: null});
    store.deleteMessage(chat, target);
    expect(path(), isEmpty);
    expect(store.chat(chat).selectedRootId, isNull);
    expect(store.chat(chat).currentLeafId, isNull);
    expect(store.node(chat, child).selectedChildId, leaf);
    store.selectNode(chat, child);
    expect(path(), [child, leaf]);
    checkDepths();
  });

  test('append bounds the actual delta gap after deletion moves a checkpoint to depth 19', () {
    final chain = <String>[];
    for (var depth = 1; depth <= 21; depth++) {
      chain.add(add('initial$depth', parent: chain.isEmpty ? null : chain.last, state: {'n': depth}));
    }
    final expected = states()..remove(chain.first);
    store.deleteMessage(chat, chain.first);
    expect(store.node(chat, chain[19]).depth, 19);
    expect(deltaSteps(chain[19]), 0);
    var leaf = chain.last;
    for (var index = 0; index < 19; index++) {
      final state = <String, Object?>{'n': 100 + index};
      leaf = add('appended$index', parent: leaf, state: state);
      expected[leaf] = state;
    }
    expect(store.node(chat, leaf).depth, 39);
    // The old depth % 20 rule leaves 20 intervening deltas here.
    expect(deltaSteps(leaf), lessThanOrEqualTo(19));
    final beforeFork = path();
    final forkParent = store.allNodes(chat).singleWhere((node) => node.depth == 38).message.nodeId;
    final fork = add('fork', parent: forkParent, makeCurrent: false, state: {'branch': true});
    expected[fork] = {'branch': true};
    expect(path(), beforeFork);
    expect(states(), expected);
    checkDepths();
    checkDeltaBound();
  });

  test('repeated prefix deletion and append cannot grow a non-multiple-depth delta tail', () {
    String? leaf;
    for (var depth = 1; depth <= 39; depth++) {
      leaf = add('initial$depth', parent: leaf, state: {'n': depth});
    }
    final expected = states();
    for (var index = 0; index < 60; index++) {
      final root = store.chat(chat).selectedRootId!;
      store.deleteMessage(chat, root);
      expected.remove(root);
      final state = <String, Object?>{
        'n': 100 + index,
        'nested': [index, null],
      };
      leaf = add('replacement$index', parent: leaf, state: state);
      expected[leaf] = state;
      expect(store.node(chat, leaf).depth, 39);
      expect(deltaSteps(leaf), lessThanOrEqualTo(19), reason: 'replacement $index');
      expect(store.nodeState(chat, leaf), state);
    }
    expect(states(), expected);
    expect(path().length, 39);
    checkDepths();
    checkDeltaBound();
  });

  test('checkpoint and delta deletions preserve all 65-level states across reopening', () async {
    await store.close();
    final directory = Directory.systemTemp.createTempSync('t16-delete-single-');
    final file = '${directory.path}/chat.sqlite3';
    try {
      database = sqlite3.open(file);
      store = open(database);
      createChat();
      final chain = <String>[];
      store.transaction(() {
        for (var depth = 1; depth <= 65; depth++) {
          chain.add(
            add(
              'depth$depth',
              parent: chain.isEmpty ? null : chain.last,
              state: {
                'n': depth,
                'variables': {
                  'number': depth,
                  'nested': [
                    depth,
                    {'x/y': null},
                  ],
                },
                'a/b~c': {
                  'values': [depth, '海', false],
                },
                if (depth % 3 != 0) 'intermittent': depth,
                if (depth.isEven) 'even': true,
                'stChatId': 'source-$depth',
                'stChatIdHash': depth % 5 == 0 ? null : depth / 2,
              },
            ),
          );
        }
      });
      final alternate = add(
        'alternate',
        parent: chain[19],
        makeCurrent: false,
        state: {
          'onlyBranch': [1, null],
        },
      );
      final expected = states();
      final expectedContents = contents();
      final deleted = <String>{};
      for (final target in [chain[19], chain[34], chain.first]) {
        store.deleteMessage(chat, target);
        deleted.add(target);
        expected.remove(target);
        expectedContents.remove(target);
        expect(states(), expected);
        expect(contents(), expectedContents);
        expect(path(), chain.where((id) => !deleted.contains(id)));
        checkDepths();
      }
      expect(store.message(chat, alternate).parentId, chain[18]);
      final selected = store.chat(chat).currentLeafId;
      final choices = {for (final node in store.allNodes(chat)) node.message.nodeId: node.selectedChildId};
      final checkpointIds = database
          .select('SELECT node_id FROM node_states WHERE full_json IS NOT NULL')
          .map((row) => row['node_id'])
          .toSet();
      expect(checkpointIds, containsAll([chain[1], chain[20], chain[35], chain[39], chain[59], alternate]));
      await store.close();
      database = sqlite3.open(file);
      store = open(database);
      expect(store.chat(chat).currentLeafId, selected);
      expect(states(), expected);
      expect(contents(), expectedContents);
      expect({for (final node in store.allNodes(chat)) node.message.nodeId: node.selectedChildId}, choices);
      expect(path(), chain.where((id) => !deleted.contains(id)));
      store.selectNode(chat, alternate);
      expect(store.chat(chat).currentLeafId, alternate);
      expect(store.nodeState(chat, alternate), {
        'onlyBranch': [1, null],
      });
      checkDepths();
    } finally {
      await store.close();
      directory.deleteSync(recursive: true);
    }
  });

  for (final fault in ['checkpoint', 'delete', 'touch']) {
    test('a $fault SQL failure rolls back edges states FTS selection and notifications', () async {
      final root = add('root', state: {'n': 0});
      final target = add('targetneedle', parent: root, state: {'n': 1, 'remove': true});
      final child = add('child', parent: target, state: {'n': 2});
      final leaf = add('leaf', parent: child, state: {'n': 3});
      add('second', parent: target, makeCurrent: false, state: {'second': true});
      final before = snapshot();
      await Future<void>.delayed(Duration.zero);
      final events = <String>[];
      final subscription = store.changes.listen(events.add);
      final trigger = switch (fault) {
        'checkpoint' =>
          '''CREATE TRIGGER reject_delete BEFORE UPDATE OF full_json ON node_states
          WHEN NEW.node_id = 'second' BEGIN SELECT RAISE(ABORT, 'fixture_checkpoint'); END''',
        'delete' =>
          '''CREATE TRIGGER reject_delete BEFORE DELETE ON nodes
          WHEN OLD.id = 'targetneedle' BEGIN SELECT RAISE(ABORT, 'fixture_delete'); END''',
        _ =>
          '''CREATE TRIGGER reject_delete BEFORE UPDATE OF updated_at ON chats
          WHEN NEW.id = 'chat' BEGIN SELECT RAISE(ABORT, 'fixture_touch'); END''',
      };
      database.execute(trigger);
      milliseconds = 9000;
      expect(() => store.deleteMessage(chat, target), throwsA(isA<SqliteException>()));
      expect(snapshot(), before);
      expect(database.autocommit, isTrue);
      expect(store.search('targetneedle').single.nodeId, target);
      expect(store.search('leaf').single.nodeId, leaf);
      await Future<void>.delayed(Duration.zero);
      expect(events, isEmpty);
      database.execute('DROP TRIGGER reject_delete');
      store.deleteMessage(chat, target);
      expect(path(), [root, child, leaf]);
      expect(store.search('targetneedle'), isEmpty);
      await Future<void>.delayed(Duration.zero);
      expect(events, [chat]);
      checkDepths();
      await subscription.cancel();
    });
  }

  test('single deletion joins an outer transaction without publishing a partial edit', () async {
    final root = add('root');
    final target = add('target', parent: root, state: {'n': 1});
    final child = add('child', parent: target, state: {'n': 2});
    final before = snapshot();
    await Future<void>.delayed(Duration.zero);
    final events = <String>[];
    final subscription = store.changes.listen(events.add);
    expect(
      () => store.transaction<void>(() {
        store.deleteMessage(chat, target);
        store.updateChat(chat, variables: {'n': 2});
        throw StateError('fixture facade failure');
      }),
      throwsStateError,
    );
    expect(snapshot(), before);
    await Future<void>.delayed(Duration.zero);
    expect(events, isEmpty);
    store.transaction(() {
      store.deleteMessage(chat, target);
      store.updateChat(chat, variables: {'n': 2});
    });
    expect(path(), [root, child]);
    expect(store.chat(chat).variables, {'n': 2});
    await Future<void>.delayed(Duration.zero);
    expect(events, [chat]);
    await subscription.cancel();
  });

  test('missing and foreign nodes fail without touching either chat', () async {
    final root = add('root');
    final foreignChat = store.createChat(id: 'foreign-chat', characterId: 'card');
    final foreign = store
        .append(
          foreignChat,
          id: 'foreign-node',
          parentId: null,
          role: TavernRole.user,
          speaker: 'user',
          text: 'foreign',
        )
        .nodeId;
    final before = snapshot();
    await Future<void>.delayed(Duration.zero);
    final events = <String>[];
    final subscription = store.changes.listen(events.add);
    expect(() => store.deleteMessage(chat, 'missing'), throwsStateError);
    expect(() => store.deleteMessage(chat, foreign), throwsStateError);
    expect(() => store.deleteMessage('missing-chat', root), throwsStateError);
    expect(snapshot(), before);
    await Future<void>.delayed(Duration.zero);
    expect(events, isEmpty);
    await subscription.cancel();
  });
}

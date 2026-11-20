import 'dart:convert';

import 'package:dsh_tavern/src/api.dart';
import 'package:dsh_tavern/src/store/chat_store.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  late ChatStore store;
  setUp(() {
    store = ChatStore.inMemory();
  });
  tearDown(() async {
    await store.close();
  });

  String append(String chatId, String text, [String? parent]) => store
      .append(chatId, parentId: parent, role: TavernRole.character, speaker: '鲸', text: text, makeCurrent: false)
      .nodeId;
  Map<String, String?> choices(String chatId) => {
    for (final node in store.allNodes(chatId)) node.message.nodeId: node.selectedChildId,
  };
  String snapshot(String chatId) => jsonEncode({
    'root': store.chat(chatId).selectedRootId,
    'leaf': store.chat(chatId).currentLeafId,
    'choices': choices(chatId),
  });

  test('complete selection preserves inactive descendants and explicit stops', () {
    final chat = store.createChat(characterId: 'card');
    final root = append(chat, 'root');
    final a = append(chat, 'A', root);
    final aChild = append(chat, 'A child', a);
    final b = append(chat, 'B', root);
    final bChild = append(chat, 'B child', b);
    final other = append(chat, 'other root');
    final otherChild = append(chat, 'other child', other);
    store.restoreSelection(
      chat,
      selectedRootId: root,
      selectedChildren: {root: a, a: null, aChild: null, b: bChild, bChild: null, other: otherChild, otherChild: null},
    );
    expect(store.path(chat).map((message) => message.text), ['root', 'A']);
    expect(store.node(chat, a).selectedChildId, isNull);
    store.selectNode(chat, b);
    expect(store.chat(chat).currentLeafId, bChild);
    store.selectNode(chat, other);
    expect(store.chat(chat).currentLeafId, otherChild);
    store.selectNode(chat, a);
    expect(store.chat(chat).currentLeafId, a);
    expect(store.children(chat, a).single.message.nodeId, aChild);
  });

  test('all invalid snapshots leave the entire previous selection unchanged', () {
    final chat = store.createChat(characterId: 'card');
    final root = append(chat, 'root');
    final a = append(chat, 'A', root);
    final b = append(chat, 'B', root);
    final child = append(chat, 'child', a);
    final otherChat = store.createChat(characterId: 'other');
    final foreign = append(otherChat, 'foreign');
    final valid = {root: a, a: child, b: null, child: null};
    store.restoreSelection(chat, selectedRootId: root, selectedChildren: valid);
    final before = snapshot(chat);
    for (final invalid in <Map<String, String?>>[
      {...valid}..remove(b),
      {...valid, foreign: null},
      {...valid, root: foreign},
      {...valid, a: b},
      {...valid, child: root},
    ]) {
      expect(() => store.restoreSelection(chat, selectedRootId: root, selectedChildren: invalid), throwsArgumentError);
      expect(snapshot(chat), before);
    }
    for (final invalidRoot in [a, foreign, 'missing']) {
      expect(
        () => store.restoreSelection(chat, selectedRootId: invalidRoot, selectedChildren: valid),
        throwsArgumentError,
      );
      expect(snapshot(chat), before);
    }
  });

  test('null root selects no path without deleting remembered choices', () {
    final chat = store.createChat(characterId: 'card');
    store.restoreSelection(chat, selectedRootId: null, selectedChildren: {});
    final root = append(chat, 'root');
    final child = append(chat, 'child', root);
    store.restoreSelection(chat, selectedRootId: null, selectedChildren: {root: child, child: null});
    expect(store.chat(chat).currentLeafId, isNull);
    expect(store.path(chat), isEmpty);
    expect(store.node(chat, root).selectedChildId, child);
    store.selectNode(chat, root);
    expect(store.chat(chat).currentLeafId, child);
  });

  test('late SQL failure rolls back earlier edges and later restores still work', () async {
    await store.close();
    final database = sqlite3.openInMemory();
    store = ChatStore.fromDatabase(database);
    final chat = store.createChat(characterId: 'card');
    final a = append(chat, 'A');
    final aChild = append(chat, 'A child', a);
    final b = append(chat, 'B');
    final bChild = append(chat, 'B child', b);
    final before = snapshot(chat);
    database.execute('''CREATE TRIGGER reject_selection BEFORE UPDATE OF selected_child_id ON nodes
      WHEN NEW.id = '$b' AND NEW.selected_child_id IS NOT NULL
      BEGIN SELECT RAISE(ABORT, 'fixture_selection'); END''');
    final wanted = {a: aChild, aChild: null, b: bChild, bChild: null};
    expect(
      () => store.restoreSelection(chat, selectedRootId: a, selectedChildren: wanted),
      throwsA(isA<SqliteException>()),
    );
    expect(snapshot(chat), before);
    database.execute('DROP TRIGGER reject_selection');
    store.restoreSelection(chat, selectedRootId: a, selectedChildren: wanted);
    expect(store.chat(chat).currentLeafId, aChild);
    expect(store.node(chat, b).selectedChildId, bChild);
  });

  test('a long imported chain restores without recursive Dart traversal', () {
    final chat = store.createChat(characterId: 'card');
    final nodes = <String>[];
    store.transaction(() {
      for (var index = 0; index < 1200; index++) {
        nodes.add(append(chat, '$index', nodes.isEmpty ? null : nodes.last));
      }
    });
    final all = <String, String?>{
      for (var index = 0; index < nodes.length; index++)
        nodes[index]: index + 1 < nodes.length ? nodes[index + 1] : null,
    };
    store.restoreSelection(chat, selectedRootId: nodes.first, selectedChildren: all);
    expect(store.chat(chat).currentLeafId, nodes.last);
    expect(store.path(chat, limit: 2).map((message) => message.text), ['1198', '1199']);
    all[nodes[700]] = null;
    store.restoreSelection(chat, selectedRootId: nodes.first, selectedChildren: all);
    expect(store.chat(chat).currentLeafId, nodes[700]);
    expect(store.node(chat, nodes[701]).selectedChildId, nodes[702]);
  });
}

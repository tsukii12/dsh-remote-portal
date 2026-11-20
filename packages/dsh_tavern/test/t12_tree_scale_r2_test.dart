import 'dart:convert';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import 'support/t24_engine_harness.dart';

// New r2 regression source. These semantic checks must pass on both the
// recovered parent and the optimization; no timing or old-red requirement.
void main() {
  test('wide facade trees retain sibling order selection and JSONL round trips', () async {
    final h = await T24Harness.open();
    addTearDown(h.dispose);
    final roots = [for (var i = 0; i < 128; i++) 'root-$i'];
    final document = StChatDocument(
      fileName: 'wide.jsonl',
      header: {
        'user_name': 'User',
        'character_name': 'Guide',
        'chat_metadata': {
          'variables': {'kept': 7},
          'vendor_header': [null, '海'],
        },
      },
      messages: [
        _swipes(roots, 0, vendor: true),
        _swipes(['child-0', 'child-1', 'child-2'], 2),
        _swipes(['tail'], 0),
      ],
    );
    final chat = (await h.engine.importChats(h.characterId, [
      TavernChatFile(fileName: document.fileName, bytes: document.encode()),
    ])).chatIds.single;
    var tree = await h.engine.tree(chat);
    expect(tree.map((node) => node.preview), [...roots, 'child-0', 'child-1', 'child-2', 'tail']);
    final rootNodes = tree.where((node) => node.parentId == null).toList();
    expect(rootNodes.map((node) => node.siblingIndex), List.generate(128, (i) => i));
    expect(rootNodes.map((node) => node.siblingCount), everyElement(128));
    expect(rootNodes[1].at.isAfter(rootNodes[2].at), isTrue);
    final first = rootNodes.first.nodeId;
    final last = rootNodes.last.nodeId;
    final children = tree.where((node) => node.parentId == first).toList();
    expect(children.map((node) => node.siblingIndex), [0, 1, 2]);
    expect(children.map((node) => node.siblingCount), [3, 3, 3]);
    expect((await h.engine.path(chat)).map((node) => node.text), ['root-0', 'child-2', 'tail']);

    await h.engine.setHidden(chat, first, true);
    await h.engine.setHidden(chat, children[1].nodeId, true);
    await h.engine.nameBranch(chat, first, 'root label');
    await h.engine.nameBranch(chat, children[1].nodeId, 'child label');
    await h.engine.selectSibling(chat, first, 127);
    final note = await h.engine.narrate(chat, 'note');
    expect((await h.engine.path(chat)).map((node) => node.text), ['root-127', 'note']);
    await h.engine.selectSibling(chat, last, 0);
    expect((await h.engine.path(chat)).map((node) => node.text), ['root-0', 'child-2', 'tail']);
    await h.engine.selectSibling(chat, first, 127);
    final before = await h.engine.tree(chat);
    expect(before, hasLength(133));
    expect(before.singleWhere((node) => node.nodeId == first).hidden, isTrue);
    expect(before.singleWhere((node) => node.nodeId == children[1].nodeId).siblingCount, 3);

    final deletion = await h.engine.deleteFrom(chat, first);
    tree = await h.engine.tree(chat);
    expect(tree, hasLength(128));
    expect(tree.where((node) => node.parentId == null), hasLength(127));
    expect(tree.where((node) => node.parentId == null).map((node) => node.siblingCount), everyElement(127));
    expect(tree.singleWhere((node) => node.nodeId == last).siblingIndex, 126);
    expect((await h.engine.path(chat)).last.nodeId, note.nodeId);
    expect(await h.engine.undoDeleteFrom(chat, deletion), isTrue);
    expect(_treeView(await h.engine.tree(chat)), _treeView(before));

    await h.reopen();
    tree = await h.engine.tree(chat);
    expect(tree.map((node) => node.nodeId), before.map((node) => node.nodeId));
    expect(_treeView(tree), _treeView(before));
    final files = await h.engine.exportChat(chat);
    final decoded = [for (final file in files) StChatDocument.decode(file.fileName, file.bytes)];
    final rootRows = decoded
        .expand((file) => file.messages)
        .where((row) => row['swipes'] is List<Object?> && (row['swipes']! as List<Object?>).length == 128);
    expect(rootRows, isNotEmpty);
    for (final row in rootRows) {
      expect(row['vendor_message'], {
        'keep': [null, '原文'],
      });
    }
    final imported = (await h.engine.importChats(h.characterId, files)).chatIds.single;
    // Import generates new ids and may visit independent branches in a
    // different order. Unique previews identify nodes without erasing their
    // sibling indexes, parent relation, selected path, visibility or labels.
    expect(_treeView(await h.engine.tree(imported)), _treeView(before));
    expect((await h.engine.path(imported)).map((node) => node.text), ['root-127', 'note']);
    expect((await h.engine.path(h.chatId)).single.text, 'G');
    expect(h.model.generated, 0);

    final purge = await h.engine.deleteFrom(chat, first);
    await h.reopen();
    expect(await h.engine.tree(chat), hasLength(128));
    expect(await h.engine.undoDeleteFrom(chat, purge), isFalse);
    expect(await h.engine.tree(imported), hasLength(133));
  });

  test('raw parent identities keep null empty BOM NUL and guard groups distinct', () {
    final store = ChatStore.inMemory(clock: () => T24Harness.at);
    addTearDown(store.close);
    final chat = store.createChat(characterId: 'card');
    final other = store.createChat(characterId: 'card');
    const parents = ['p', '\ufeffp', '', '\ufeff', '\u0001p', '\u0000p', '\ufeff\ufeffp'];
    for (var i = 0; i < parents.length; i++) {
      _append(store, chat, parents[i], text: 'root-$i', makeCurrent: false);
    }
    for (var i = 0; i < parents.length; i++) {
      _append(store, chat, 'child-$i', parent: parents[i], makeCurrent: false);
    }
    _append(store, chat, 'later', parent: 'p', makeCurrent: false);
    _append(store, other, 'other');
    store.setHidden(chat, 'child-1', true);
    final nodes = store.allNodes(chat);
    expect(nodes.map((node) => node.message.text), [
      for (var i = 0; i < parents.length; i++) 'root-$i',
      for (var i = 0; i < parents.length; i++) 'child-$i',
      'later',
    ]);
    final roots = nodes.where((node) => node.message.parentId == null).toList();
    expect(roots.map((node) => node.message.siblingIndex), [0, 1, 2, 3, 4, 5, 6]);
    expect(roots.map((node) => node.message.siblingCount), everyElement(7));
    for (var i = 0; i < parents.length; i++) {
      final child = nodes.singleWhere((node) => node.message.nodeId == 'child-$i').message;
      expect((child.siblingIndex, child.siblingCount), (0, i == 0 ? 2 : 1), reason: 'parent-$i');
    }
    final later = nodes.singleWhere((node) => node.message.nodeId == 'later').message;
    expect((later.siblingIndex, later.siblingCount), (1, 2));
    expect(nodes.singleWhere((node) => node.message.nodeId == 'child-1').message.hidden, isTrue);
    expect(store.chat(chat).currentLeafId, isNull);
    expect(store.path(chat), isEmpty);
    expect(store.allNodes(other).single.message.siblingCount, 1);
    // Arbitrary identities are reachable through public ChatStore.append.
    // Do not assert repaired BOM ids in the old DTO or imply engine JSONL
    // accepts a caller-controlled physical node id.
  });

  test('soft deletion undo and single-node reparenting recompute visible groups in seq order', () {
    final store = ChatStore.inMemory(clock: () => T24Harness.at);
    addTearDown(store.close);
    final chat = store.createChat(characterId: 'card');
    _append(store, chat, 'root', state: {'n': 0});
    _append(store, chat, 'before', parent: 'root', makeCurrent: false, hidden: true);
    _append(store, chat, 'target', parent: 'root', state: {'n': 1});
    _append(store, chat, 'a', parent: 'target', state: {'n': 2});
    _append(store, chat, 'leaf', parent: 'a', state: {'n': 3});
    _append(store, chat, 'after', parent: 'root', makeCurrent: false);
    _append(store, chat, 'b', parent: 'target', state: {'n': 4});
    _append(store, chat, 'other-root', makeCurrent: false);
    store.selectNode(chat, 'leaf');
    expect(store.allNodes(chat).map((node) => node.message.nodeId), [
      'root',
      'before',
      'target',
      'a',
      'leaf',
      'after',
      'b',
      'other-root',
    ]);
    _expectGroup(store.allNodes(chat), 'root', ['before', 'target', 'after']);
    _expectGroup(store.allNodes(chat), 'target', ['a', 'b']);
    final token = store.softDeleteFrom(chat, 'b');
    _expectGroup(store.allNodes(chat), 'target', ['a']);
    expect(store.allNodes(chat).any((node) => node.message.nodeId == 'b'), isFalse);
    expect(store.undoDeleteFrom(chat, token), isTrue);
    _expectGroup(store.allNodes(chat), 'target', ['a', 'b']);

    store.deleteMessage(chat, 'target');
    final nodes = store.allNodes(chat);
    expect(nodes.map((node) => node.message.nodeId), ['root', 'before', 'a', 'leaf', 'after', 'b', 'other-root']);
    _expectGroup(nodes, null, ['root', 'other-root']);
    _expectGroup(nodes, 'root', ['before', 'a', 'after', 'b']);
    _expectGroup(nodes, 'a', ['leaf']);
    expect(nodes.singleWhere((node) => node.message.nodeId == 'before').message.hidden, isTrue);
    expect(nodes.singleWhere((node) => node.message.nodeId == 'a').depth, 2);
    expect(nodes.singleWhere((node) => node.message.nodeId == 'leaf').depth, 3);
    expect(store.nodeState(chat, 'a'), {'n': 2});
    expect(store.nodeState(chat, 'leaf'), {'n': 3});
    expect(store.nodeState(chat, 'b'), {'n': 4});
    expect(store.path(chat).map((message) => message.nodeId), ['root', 'a', 'leaf']);
    expect(store.node(chat, 'root').selectedChildId, 'a');
    // Other read APIs retain their established SQL sibling metadata.
    expect(store.children(chat, 'root').map((node) => node.message.siblingIndex), [0, 1, 2, 3]);
    expect(store.historyTo(chat, 'leaf').map((node) => node.message.siblingCount), [2, 4, 1]);
    expect((store.message(chat, 'b').siblingIndex, store.node(chat, 'b').message.siblingCount), (3, 4));
  });

  test('allNodes preserves full detached payload and pending body projections', () {
    final store = ChatStore.inMemory(clock: () => T24Harness.at);
    addTearDown(store.close);
    final chat = store.createChat(characterId: 'card');
    const body = '\ufeffbody\u0000海🌊\r\n尾';
    const reasoning = '\ufeff\ufeffreason';
    final extra = <String, Object?>{
      'foreign': {
        'list': [
          1,
          {'value': '海'},
        ],
      },
      'dshgo': {
        'other': {'keep': true},
        'inspection': {
          'version': 1,
          'chatId': chat,
          'nodeId': 'full',
          'reportedUsage': {'promptTokens': 12, 'cacheHitTokens': 3, 'completionTokens': 4, 'model': 'report'},
        },
      },
    };
    final original = <String, Object?>{
      'vendor': {'value': body},
      'unknown': [null, true],
    };
    store.append(
      chat,
      id: 'full',
      parentId: null,
      role: TavernRole.character,
      speaker: '\ufeffGuide',
      text: body,
      reasoning: reasoning,
      hidden: true,
      at: T24Harness.at,
      usage: const TavernUsage(promptTokens: 90, cacheHitTokens: 20, completionTokens: 8, model: 'estimate'),
      extra: extra,
      original: original,
    );
    _append(store, chat, 'leaf', parent: 'full');
    final saved = store.allNodes(chat).first;
    expect([saved.depth, saved.selectedChildId], [1, 'leaf']);
    expect(
      [
        saved.message.parentId,
        saved.message.role,
        saved.message.speaker,
        saved.message.text,
        saved.message.reasoning,
        saved.message.at,
        saved.message.hidden,
        saved.message.siblingIndex,
        saved.message.siblingCount,
      ],
      [null, TavernRole.character, '\ufeffGuide', body, reasoning, T24Harness.at, true, 0, 1],
    );
    expect(_usage(saved.message.usage), [90, 20, 8, 'estimate']);
    expect(_usage(saved.message.reportedUsage), [12, 3, 4, 'report']);
    expect(saved.extra, extra);
    expect(saved.original, original);
    final foreign = saved.extra['foreign']! as Map<String, Object?>;
    ((foreign['list']! as List<Object?>)[1]! as Map<String, Object?>)['value'] = 'changed';
    (saved.original['vendor']! as Map<String, Object?>)['value'] = 'changed';
    expect(store.allNodes(chat).first.extra, extra);
    expect(store.allNodes(chat).first.original, original);

    store.beginStreamingWrites();
    try {
      store.writeStreamingBody(chat, 'full', text: '', reasoning: null);
      final pending = store.allNodes(chat).first;
      expect(
        [pending.message.text, pending.message.reasoning, pending.message.usage, pending.message.reportedUsage],
        ['', null, null, null],
      );
      final own = pending.extra['dshgo']! as Map<String, Object?>;
      expect(own.containsKey('inspection'), isFalse);
      expect(own['other'], {'keep': true});
      expect(pending.extra['foreign'], extra['foreign']);
      expect(pending.original, original);
      expect((store.rawNodeExtra(chat, 'full')['dshgo']! as Map<String, Object?>).containsKey('inspection'), isTrue);
      expect(store.path(chat).first.text, '');
      store.writeStreamingBody(chat, 'full', text: '\ufeffdraft', reasoning: '\ufeffthought');
      final next = store.allNodes(chat).first.message;
      expect([next.text, next.reasoning], ['\ufeffdraft', '\ufeffthought']);
      expect(store.message(chat, 'full').siblingCount, 1);
    } finally {
      store.endStreamingWrites();
    }
  });

  test('bad selected extra or original JSON remains an error and can be repaired', () async {
    final database = sqlite3.openInMemory();
    final store = ChatStore.fromDatabase(database);
    addTearDown(store.close);
    final chat = store.createChat(characterId: 'card');
    final empty = store.createChat(characterId: 'card');
    _append(store, chat, 'body');
    expect(store.allNodes(empty), isEmpty);
    expect(() => store.allNodes('missing'), throwsStateError);
    for (final column in ['extra', 'original']) {
      database.execute('UPDATE nodes SET $column = ? WHERE id = ?', ['{broken', 'body']);
      expect(() => store.allNodes(chat), throwsA(isA<FormatException>()), reason: column);
      expect(store.message(chat, 'body').text, 'body');
      expect(database.select('SELECT $column FROM nodes WHERE id = ?', ['body']).single[column], '{broken');
      final restored = {'restored': column};
      database.execute('UPDATE nodes SET $column = ? WHERE id = ?', [jsonEncode(restored), 'body']);
      final node = store.allNodes(chat).single;
      expect(column == 'extra' ? node.extra : node.original, restored);
      expect((node.message.siblingIndex, node.message.siblingCount), (0, 1));
    }
    await store.close();
    expect(() => store.allNodes(chat), throwsStateError);
  });
}

TavernMessage _append(
  ChatStore store,
  String chat,
  String id, {
  String? parent,
  String? text,
  bool makeCurrent = true,
  bool hidden = false,
  Map<String, Object?>? state,
}) => store.append(
  chat,
  id: id,
  parentId: parent,
  role: TavernRole.character,
  speaker: 'Guide',
  text: text ?? id,
  makeCurrent: makeCurrent,
  hidden: hidden,
  at: T24Harness.at,
  state: state,
);

void _expectGroup(List<StoredNode> nodes, String? parent, List<String> ids) {
  final family = nodes.where((node) => node.message.parentId == parent).toList();
  expect(family.map((node) => node.message.nodeId), ids);
  expect(family.map((node) => node.message.siblingIndex), [for (var i = 0; i < ids.length; i++) i]);
  expect(family.map((node) => node.message.siblingCount), everyElement(ids.length));
}

List<Object?>? _usage(TavernUsage? value) =>
    value == null ? null : [value.promptTokens, value.cacheHitTokens, value.completionTokens, value.model];

Map<String, Object?> _swipes(List<String> texts, int selected, {bool vendor = false}) => {
  'name': 'Guide',
  'is_user': false,
  'is_system': false,
  'mes': texts[selected],
  'swipe_id': selected,
  'swipes': texts,
  'send_date': T24Harness.at.toIso8601String(),
  'swipe_info': [
    for (var i = 0; i < texts.length; i++)
      {'send_date': T24Harness.at.subtract(Duration(minutes: i)).toIso8601String(), 'extra': <String, Object?>{}},
  ],
  'extra': <String, Object?>{},
  if (vendor)
    'vendor_message': {
      'keep': [null, '原文'],
    },
};

Map<String, Object?> _treeView(List<TavernTreeNode> nodes) {
  final names = {for (final node in nodes) node.nodeId: node.preview};
  expect(names.values.toSet(), hasLength(nodes.length));
  return {
    for (final node in nodes)
      node.preview: {
        'parent': node.parentId == null ? null : names[node.parentId],
        'role': node.role.name,
        'speaker': node.speaker,
        'at': node.at.toIso8601String(),
        'index': node.siblingIndex,
        'count': node.siblingCount,
        'current': node.isCurrentPath,
        'hidden': node.hidden,
        'label': node.branchName,
      },
  };
}

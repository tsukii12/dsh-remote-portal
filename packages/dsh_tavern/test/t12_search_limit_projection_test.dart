import 'dart:convert';
import 'dart:typed_data';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import 'support/t24_engine_harness.dart';

// Performance-only structure change: these semantic assertions must pass with
// both product versions. No time threshold or expected old-product failure.
void main() {
  test('limited facade search retains full sibling metadata across wide swipes and reopen', () async {
    final h = await T24Harness.open();
    addTearDown(h.dispose);
    final texts = [for (var i = 0; i < 64; i++) i == 2 ? 'quiet root 2' : '\uFEFFneedle root $i 海🌊'];
    const children = ['needle child A', 'quiet child', 'needle child C'];
    final chat = (await h.engine.importChats(h.characterId, [
      _file([
        _swiped(texts, 'root'),
        _swiped(children, 'child', selected: 2),
        _row('needle leaf', reasoning: '\uFEFFleaf\u0000thought'),
      ]),
    ])).chatIds.single;
    final tree = await h.engine.tree(chat);
    expect(tree, hasLength(68));
    final roots = tree.where((node) => node.parentId == null).toList();
    expect(roots.map((node) => node.preview), texts);
    final a = tree.singleWhere((node) => node.preview == children[0]);
    final c = tree.singleWhere((node) => node.preview == children[2]);
    final leaf = tree.singleWhere((node) => node.preview == 'needle leaf');
    expect(_ids(await h.engine.path(chat)), [roots[0].nodeId, c.nodeId, leaf.nodeId]);
    await h.engine.setHidden(chat, roots[63].nodeId, true);
    final first = (await h.engine.searchChat(chat, 'root', limit: 1)).single;
    _expectMessage(
      first,
      id: roots[63].nodeId,
      parent: null,
      text: texts[63],
      reasoning: 'root reasoning 63',
      at: _slotAt(63),
      index: 63,
      count: 64,
      hidden: true,
    );

    // Delete inactive branches. Quiet and hidden siblings still count; deleted
    // siblings do not. The current root -> child C -> leaf path stays selected.
    await h.engine.deleteFrom(chat, roots[61].nodeId);
    await h.engine.deleteFrom(chat, a.nodeId);
    final expected = [
      leaf.nodeId,
      c.nodeId,
      for (var i = 63; i >= 0; i--)
        if (i != 61 && i != 2) roots[i].nodeId,
    ];
    expect(expected, hasLength(64));
    final all = await h.engine.searchChat(chat, 'needle', limit: 100);
    expect(_ids(all), expected);
    expect(_ids(await h.engine.searchChat(chat, 'needle', limit: 1)), [leaf.nodeId]);
    expect(_ids(await h.engine.searchChat(chat, 'needle', limit: 2)), [leaf.nodeId, c.nodeId]);
    expect(_ids(await h.engine.searchChat(chat, 'needle', limit: 5)), expected.take(5).toList());
    final newestRoot = (await h.engine.searchChat(chat, 'root', limit: 1)).single;
    _expectMessage(
      newestRoot,
      id: roots[63].nodeId,
      parent: null,
      text: texts[63],
      reasoning: 'root reasoning 63',
      at: _slotAt(63),
      index: 62,
      count: 63,
      hidden: true,
    );
    _expectMessage(
      all[1],
      id: c.nodeId,
      parent: roots[0].nodeId,
      text: children[2],
      reasoning: 'child reasoning 2',
      at: _slotAt(2),
      index: 1,
      count: 2,
    );
    _expectMessage(
      all[0],
      id: leaf.nodeId,
      parent: c.nodeId,
      text: 'needle leaf',
      reasoning: '\uFEFFleaf\u0000thought',
      at: T24Harness.at,
      index: 0,
      count: 1,
    );
    expect(await h.engine.searchChat(h.chatId, 'needle'), isEmpty);
    final selected = (await h.engine.path(chat)).map(_view).toList();
    final snapshot = all.map(_view).toList();
    expect(h.model.generated, 0);

    // Opening purges soft-deleted rows. The same public results and all message
    // fields must survive, including BOM/NUL channels, IDs and sibling counts.
    await h.reopen();
    expect((await h.engine.searchChat(chat, 'needle', limit: 100)).map(_view).toList(), snapshot);
    expect((await h.engine.path(chat)).map(_view).toList(), selected);
    expect(_ids(await h.engine.searchChat(chat, 'root', limit: 1)), [roots[63].nodeId]);
    expect(h.model.generated, 0);
  });

  test('limited store search preserves selected JSON failures and ignores unselected payloads', () {
    // The store owns this one in-memory connection. Controlled corruption is
    // a storage-error fixture, not data claimed to come from normal JSONL.
    final database = sqlite3.openInMemory();
    final store = ChatStore.fromDatabase(database, clock: () => T24Harness.at);
    addTearDown(store.close);
    final chat = store.createChat(characterId: 'card');
    const text = '\uFEFFneedle old\u0000尾';
    store.append(
      chat,
      id: 'old',
      parentId: null,
      role: TavernRole.narrator,
      speaker: _speaker,
      text: text,
      reasoning: '\uFEFFthought\u0000尾',
      makeCurrent: false,
      usage: const TavernUsage(promptTokens: 7, cacheHitTokens: 2, completionTokens: 3, model: 'original'),
      extra: {
        'foreign': [null, true, '\uFEFFkept'],
        'dshgo': {
          'inspection': {
            'version': 1,
            'chatId': chat,
            'nodeId': 'old',
            'reportedUsage': {'promptTokens': 11, 'cacheHitTokens': 4, 'completionTokens': 5, 'model': 'reported'},
          },
        },
      },
      original: {
        'mes': text,
        'vendor': ['\uFEFForiginal', null],
      },
    );
    store.append(
      chat,
      id: 'new',
      parentId: null,
      role: TavernRole.user,
      speaker: 'User',
      text: 'needle new',
      makeCurrent: false,
    );
    store.append(
      chat,
      id: 'quiet',
      parentId: null,
      role: TavernRole.character,
      speaker: 'Guide',
      text: 'unrelated',
      makeCurrent: false,
    );
    final before = _view(store.message(chat, 'old'));
    final raw = _rawColumns(database, 'old');
    expect(before['siblingIndex'], 0);
    expect(before['siblingCount'], 3);
    expect(before['usage'], [7, 2, 3, 'original']);
    expect(before['reportedUsage'], [11, 4, 5, 'reported']);

    for (final column in ['usage', 'reported_usage']) {
      final broken = '{bad $column';
      database.execute('UPDATE nodes SET $column = ? WHERE id = ?', [broken, 'old']);
      try {
        expect(_ids(store.searchChat(chat, 'needle', limit: 1)), ['new'], reason: column);
        expect(
          () => store.searchChat(chat, 'needle', limit: 2),
          throwsA(isA<FormatException>()),
          reason: 'Selected $column still uses the original decoder.',
        );
        expect(
          () => store.searchChat(chat, 'needle old', limit: 1),
          throwsA(isA<FormatException>()),
          reason: 'Filtering to the bad row cannot silently replace $column.',
        );
        expect(_rawColumns(database, 'old')[column], broken);
      } finally {
        database.execute('UPDATE nodes SET $column = ? WHERE id = ?', [raw[column], 'old']);
      }
      expect(_view(store.searchChat(chat, 'needle old', limit: 1).single), before);
    }

    for (final column in ['extra', 'original']) {
      final broken = '{bad $column';
      database.execute('UPDATE nodes SET $column = ? WHERE id = ?', [broken, 'old']);
      try {
        final found = store.searchChat(chat, 'needle', limit: 2);
        expect(_ids(found), ['new', 'old']);
        expect(_view(found.last), before, reason: 'Search does not decode $column.');
        expect(
          () => store.node(chat, 'old'),
          throwsA(isA<FormatException>()),
          reason: 'The full-node reader still diagnoses bad $column.',
        );
        expect(_rawColumns(database, 'old')[column], broken);
      } finally {
        database.execute('UPDATE nodes SET $column = ? WHERE id = ?', [raw[column], 'old']);
      }
    }
    expect(_rawColumns(database, 'old'), raw);
    expect(_view(store.searchChat(chat, 'needle old', limit: 1).single), before);
    expect(store.node(chat, 'old').original, {
      'mes': text,
      'vendor': ['\uFEFForiginal', null],
    });
  });
}

const _speaker = '\uFEFFGuide\u0000voice';
DateTime _slotAt(int slot) => T24Harness.at.subtract(Duration(seconds: slot));

Map<String, Object?> _row(String text, {required String reasoning}) => {
  'name': _speaker,
  'is_user': false,
  'is_system': false,
  'send_date': T24Harness.at.toIso8601String(),
  'mes': text,
  'extra': {
    'reasoning': reasoning,
    'foreign': [true, null, '\uFEFFkept'],
  },
};

Map<String, Object?> _swiped(List<String> texts, String label, {int selected = 0}) => {
  ..._row(texts[selected], reasoning: '$label reasoning $selected'),
  'send_date': _slotAt(selected).toIso8601String(),
  'swipes': texts,
  'swipe_id': selected,
  'swipe_info': [
    for (var i = 0; i < texts.length; i++)
      {
        'send_date': _slotAt(i).toIso8601String(),
        'extra': {'reasoning': '$label reasoning $i'},
      },
  ],
};

TavernChatFile _file(List<Map<String, Object?>> messages) {
  final text = [
    jsonEncode(<String, Object?>{'chat_metadata': <String, Object?>{}}),
    for (final message in messages) jsonEncode(message),
  ].join('\n');
  return TavernChatFile(fileName: 'limited-search.jsonl', bytes: Uint8List.fromList(utf8.encode('$text\n')));
}

List<String> _ids(Iterable<TavernMessage> messages) => messages.map((message) => message.nodeId).toList();

List<Object?>? _usage(TavernUsage? value) =>
    value == null ? null : <Object?>[value.promptTokens, value.cacheHitTokens, value.completionTokens, value.model];

Map<String, Object?> _view(TavernMessage message) => {
  'nodeId': message.nodeId,
  'parentId': message.parentId,
  'role': message.role,
  'speaker': message.speaker,
  'text': message.text,
  'reasoning': message.reasoning,
  'at': message.at,
  'siblingIndex': message.siblingIndex,
  'siblingCount': message.siblingCount,
  'hidden': message.hidden,
  'usage': _usage(message.usage),
  'reportedUsage': _usage(message.reportedUsage),
};

void _expectMessage(
  TavernMessage message, {
  required String id,
  required String? parent,
  required String text,
  required String reasoning,
  required DateTime at,
  required int index,
  required int count,
  bool hidden = false,
}) {
  expect(_view(message), {
    'nodeId': id,
    'parentId': parent,
    'role': TavernRole.character,
    'speaker': _speaker,
    'text': text,
    'reasoning': reasoning,
    'at': at,
    'siblingIndex': index,
    'siblingCount': count,
    'hidden': hidden,
    'usage': null,
    'reportedUsage': null,
  });
}

Map<String, Object?> _rawColumns(Database database, String id) {
  final row = database.select('SELECT usage, reported_usage, extra, original FROM nodes WHERE id = ?', [id]).single;
  return {
    for (final column in ['usage', 'reported_usage', 'extra', 'original']) column: row[column],
  };
}

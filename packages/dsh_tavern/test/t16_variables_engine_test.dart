import 'dart:convert';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import 'support/t24_engine_harness.dart';

// The public read is deliberately narrower than the old runtime getter:
// only the selected node's saved local snapshot is shown.
void main() {
  test('saved greeting variables exclude globals and survive reopening', () async {
    final h = await T24Harness.open();
    addTearDown(h.dispose);
    final card = await h.engine.importCard(t24Card(greeting: '{{setvar::n::7}}{{setglobalvar::g::9}}G'));
    final chat = await h.engine.createChat(card.id);
    final Tavern facade = h.engine;
    expect(await facade.readVariables(chat), {'n': '7'});
    expect(h.engine.globalVariables, {'g': '9'});
    expect(h.model.generated, 0);
    expect(await facade.inspectTurn(chat), isNull);
    await h.reopen();
    expect(await h.engine.readVariables(chat), {'n': '7'});
    expect(h.engine.globalVariables, {'g': '9'});
  });

  test('nested imported values are detached and macro-shaped text is never evaluated by reads', () async {
    final h = await T24Harness.open();
    addTearDown(h.dispose);
    final expected = <String, Object?>{
      'tree': {
        'list': [
          1,
          {'value': true},
          null,
        ],
      },
      'literal': '{{incglobalvar::unexpected}}{{random::A::B}}',
    };
    final source = StChatDocument(
      fileName: 'variables.jsonl',
      header: {
        'user_name': 'User',
        'character_name': 'Guide',
        'chat_metadata': {'variables': expected},
      },
      messages: [
        {
          'name': 'Guide',
          'is_user': false,
          'is_system': false,
          'send_date': T24Harness.at.toIso8601String(),
          'mes': 'Saved',
        },
      ],
    );
    final chat = (await h.engine.importChats(h.characterId, [
      TavernChatFile(fileName: source.fileName, bytes: source.encode()),
    ])).chatIds.single;
    final first = await h.engine.readVariables(chat);
    final second = await h.engine.readVariables(chat);
    final nested = (first['tree']! as Map<String, Object?>)['list']! as List<Object?>;
    (nested[1]! as Map<String, Object?>)['value'] = false;
    nested.add('caller');
    first['new'] = 'caller';
    expect(second, expected);
    expect(await h.engine.readVariables(chat), expected);
    expect(h.engine.globalVariables, isEmpty);
    expect(h.model.generated, 0);
    final exported = (await h.engine.exportChat(chat)).first;
    final metadata =
        StChatDocument.decode(exported.fileName, exported.bytes).header['chat_metadata']! as Map<String, Object?>;
    expect(metadata['variables'], expected);
  });

  test('saved portable state wins over different runtime chat and physical state without mutating them', () async {
    final h = await T24Harness.open();
    addTearDown(h.dispose);
    final leaf = await h.engine.sendOnly(h.chatId, '{{setvar::saved::runtime}}body');
    // Deliberately distinguish all three persisted/runtime views; a getter
    // that merely returns chat.variables or the live cache must fail here.
    _inspect(h, (db) {
      db.execute('UPDATE chats SET variables = ? WHERE id = ?', [
        jsonEncode({'chatCache': 'different'}),
        h.chatId,
      ]);
      db.execute('UPDATE node_states SET full_json = ?, delta_json = ? WHERE node_id = ?', [
        jsonEncode({
          'variables': {'physical': 'different'},
        }),
        '[]',
        leaf.nodeId,
      ]);
      db.execute('UPDATE nodes SET extra = ? WHERE id = ?', [
        jsonEncode({
          'dshgo': {
            'tavernState': {
              'variables': {'saved': 'portable'},
              'stChatIdHash': null,
            },
          },
        }),
        leaf.nodeId,
      ]);
    });
    final before = _snapshot(h);
    expect(h.engine.variables(h.chatId), {'saved': 'runtime'});
    expect(await h.engine.readVariables(h.chatId), {'saved': 'portable'});
    expect(_snapshot(h), before);
    expect(h.engine.variables(h.chatId), {'saved': 'runtime'});
    _inspect(
      h,
      (db) => db.execute('UPDATE nodes SET extra = ? WHERE id = ?', [
        jsonEncode({
          'dshgo': {
            'tavernState': {'stChatIdHash': null},
          },
        }),
        leaf.nodeId,
      ]),
    );
    expect(await h.engine.readVariables(h.chatId), isEmpty);
    expect(h.engine.variables(h.chatId), {'saved': 'runtime'});
  });

  test('empty selected path returns empty even with inactive roots and stale chat variables', () async {
    final h = await T24Harness.open();
    addTearDown(h.dispose);
    final greeting = (await h.engine.path(h.chatId)).single;
    final call = h.model.prepare();
    final events = T24Events(h.engine.regenerate(h.chatId, greeting.nodeId));
    await call.listening.future;
    call.add(const ModelText('alternative'));
    await call.finish();
    await events.done.future;
    final other = events.values.whereType<TavernTurnDone>().single.message;
    await h.engine.edit(h.chatId, other.nodeId, '{{setvar::branch::other}}alternative');
    await h.engine.deleteMessage(h.chatId, other.nodeId);
    expect(await h.engine.path(h.chatId), isEmpty);
    expect((await h.engine.tree(h.chatId)).single.nodeId, greeting.nodeId);
    _inspect(
      h,
      (db) => db.execute('UPDATE chats SET variables = ? WHERE id = ?', [
        jsonEncode({'stale': 'cache'}),
        h.chatId,
      ]),
    );
    final before = _snapshot(h);
    expect(await h.engine.readVariables(h.chatId), isEmpty);
    expect(_snapshot(h), before);
    expect(h.engine.variables(h.chatId), {'stale': 'cache'});
  });

  test('single deletion soft deletion and undo expose the resulting saved leaf', () async {
    final h = await T24Harness.open();
    addTearDown(h.dispose);
    final first = await h.engine.sendOnly(h.chatId, '{{setvar::n::1}}first');
    final last = await h.engine.sendOnly(h.chatId, '{{setvar::n::2}}last');
    expect(await h.engine.readVariables(h.chatId), {'n': '2'});
    await h.engine.deleteMessage(h.chatId, last.nodeId);
    expect(await h.engine.readVariables(h.chatId), {'n': '1'});
    final token = await h.engine.deleteFrom(h.chatId, first.nodeId);
    expect(await h.engine.readVariables(h.chatId), isEmpty);
    expect(await h.engine.undoDeleteFrom(h.chatId, token), isTrue);
    expect(await h.engine.readVariables(h.chatId), {'n': '1'});
    await h.reopen();
    expect(await h.engine.readVariables(h.chatId), {'n': '1'});
  });

  test('switching alternatives reads separate saved snapshots including a hidden branch', () async {
    final h = await T24Harness.open();
    addTearDown(h.dispose);
    final first = await h.reply('first');
    await h.engine.edit(h.chatId, first.nodeId, '{{setvar::branch::first}}first');
    final call = h.model.prepare();
    final events = T24Events(h.engine.regenerate(h.chatId, first.nodeId));
    await call.listening.future;
    call.add(const ModelText('second'));
    await call.finish();
    await events.done.future;
    final second = events.values.whereType<TavernTurnDone>().single.message;
    await h.engine.edit(h.chatId, second.nodeId, '{{setvar::branch::second}}second');
    await h.engine.setHidden(h.chatId, second.nodeId, true);
    expect(await h.engine.readVariables(h.chatId), {'branch': 'second'});
    await h.engine.selectSibling(h.chatId, first.nodeId, 0);
    expect(await h.engine.readVariables(h.chatId), {'branch': 'first'});
    await h.engine.selectSibling(h.chatId, second.nodeId, 1);
    expect(await h.engine.readVariables(h.chatId), {'branch': 'second'});
    expect(h.model.generated, 2);
  });

  test('reading during streaming preserves the turn inspection and saved SQL state', () async {
    final h = await T24Harness.open();
    addTearDown(h.dispose);
    final call = h.model.prepare();
    final events = T24Events(h.engine.send(h.chatId, '{{setvar::n::2}}question'));
    await call.listening.future;
    final before = _snapshot(h);
    final inspection = (await h.engine.inspectTurn(h.chatId))!.toJson();
    expect(await h.engine.readVariables(h.chatId), {'n': '2'});
    expect(await h.engine.readVariables(h.chatId), {'n': '2'});
    expect(_snapshot(h), before);
    expect((await h.engine.inspectTurn(h.chatId))!.toJson(), inspection);
    expect(call.cancellation!.isCancelled, isFalse);
    expect(h.model.generated, 1);
    call.add(const ModelText('body'));
    await call.finish();
    await events.done.future;
    expect(events.values.whereType<TavernTurnDone>(), hasLength(1));
    expect(await h.engine.readVariables(h.chatId), {'n': '2'});
  });

  test('missing and closed reads return ordinary lifecycle errors without a model request', () async {
    final h = await T24Harness.open();
    addTearDown(h.dispose);
    await expectLater(h.engine.readVariables('missing'), throwsStateError);
    await h.engine.close();
    expect(() => h.engine.readVariables(h.chatId), throwsStateError);
    expect(h.model.generated, 0);
  });
}

T _inspect<T>(T24Harness h, T Function(Database db) inspect) {
  final db = sqlite3.open('${h.root.path}/tavern.sqlite3');
  try {
    return inspect(db);
  } finally {
    db.close();
  }
}

Map<String, Object?> _snapshot(T24Harness h) => _inspect(
  h,
  (db) => {
    for (final table in ['chats', 'nodes', 'node_states'])
      table: db.select('SELECT * FROM $table ORDER BY rowid').map((row) => Map<String, Object?>.from(row)).toList(),
  },
);

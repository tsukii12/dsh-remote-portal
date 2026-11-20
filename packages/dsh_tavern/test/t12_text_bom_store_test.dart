import 'dart:convert';
import 'dart:io';

import 'package:dsh_tavern/src/api.dart';
import 'package:dsh_tavern/src/store/chat_store.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  late Directory directory;
  late String databasePath;
  late Database database;
  late ChatStore store;
  late String chat;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('t12-text-bom-store-');
    databasePath = '${directory.path}/chat.sqlite3';
    database = sqlite3.open(databasePath);
    store = ChatStore.fromDatabase(database);
    chat = store.createChat(characterId: 'card');
  });
  tearDown(() async {
    await store.close();
    await directory.delete(recursive: true);
  });

  Future<void> reopen() async {
    await store.close();
    database = sqlite3.open(databasePath);
    store = ChatStore.fromDatabase(database);
  }

  test('all full message read projections preserve BOM content and original TEXT bytes', () {
    const speaker = '\ufeff\ufeff鲸\u0001';
    const text = '\ufeffbeacon 海🐋\r\n第二行\ufeff';
    const reasoning = '\ufeff\ufeff思考\u0000尾';
    final saved = store.append(
      chat,
      parentId: null,
      role: TavernRole.character,
      speaker: speaker,
      text: text,
      reasoning: reasoning,
      extra: {'unknown': '\ufeffextra'},
      original: {'mes': text, 'vendor': '\ufefforiginal'},
    );
    final before = _nodeBytes(database, saved.nodeId);
    expect(before, _bodyBytes(speaker: speaker, text: text, reasoning: reasoning));
    final reads = <String, TavernMessage>{
      'append': saved,
      'message': store.message(chat, saved.nodeId),
      'node': store.node(chat, saved.nodeId).message,
      'allNodes': store.allNodes(chat).single.message,
      'children': store.children(chat, null).single.message,
      'historyTo': store.historyTo(chat, saved.nodeId).single.message,
      'path': store.path(chat).single,
      'FTS': store.search('beacon', chatId: chat).single,
      'literal search': store.searchChat(chat, 'beacon').single,
    };
    for (final entry in reads.entries) {
      expect(
        [entry.value.speaker, entry.value.text, entry.value.reasoning],
        [speaker, text, reasoning],
        reason: entry.key,
      );
    }
    expect(store.ancestorIds(chat, saved.nodeId), [saved.nodeId]);
    expect(store.listChats().single.lastText, text);
    expect(store.node(chat, saved.nodeId).extra['unknown'], '\ufeffextra');
    expect(store.node(chat, saved.nodeId).original, {'mes': text, 'vendor': '\ufefforiginal'});
    expect(_nodeBytes(database, saved.nodeId), before);
  });

  test('null empty NUL guard and single multiple or internal BOM values remain distinct', () {
    final values = <String?>[
      null,
      '',
      '\ufeff',
      '\ufeff\ufeff',
      'inside\ufefftail',
      '\u0001\ufeffguard',
      '\u0000\ufefftail',
      '\ufeff\u0000tail',
      'plain',
    ];
    for (final value in values) {
      final text = value ?? 'no reasoning';
      final saved = store.append(
        chat,
        parentId: null,
        role: TavernRole.user,
        speaker: text,
        text: text,
        reasoning: value,
      );
      expect([saved.speaker, saved.text, saved.reasoning], [text, text, value]);
      expect(store.listChats().single.lastText, text);
      store.updateMessage(chat, saved.nodeId, extra: {'unrelated': true});
      expect(store.message(chat, saved.nodeId).reasoning, value);
      expect(_nodeBytes(database, saved.nodeId), _bodyBytes(speaker: text, text: text, reasoning: value));
    }
  });

  test('single deletion gives its portable-state callback the exact child text', () {
    final parent = store.append(chat, parentId: null, role: TavernRole.user, speaker: 'User', text: 'parent');
    const text = '\ufeff\ufeffchild 海🐋\r\n';
    const speaker = '\ufeffSpeaker';
    const reasoning = '\ufeffReasoning';
    final child = store.append(
      chat,
      parentId: parent.nodeId,
      role: TavernRole.character,
      speaker: speaker,
      text: text,
      reasoning: reasoning,
      state: {'physical': '\ufeffkept'},
    );
    final before = _nodeBytes(database, child.nodeId);
    var calls = 0;
    store.deleteMessage(
      chat,
      parent.nodeId,
      capturePortableState: (node, state) {
        calls++;
        expect(node.message.nodeId, child.nodeId);
        expect([node.message.speaker, node.message.text, node.message.reasoning], [speaker, text, reasoning]);
        expect(state, {'physical': '\ufeffkept'});
        return {'copiedText': node.message.text};
      },
    );
    expect(calls, 1);
    expect(store.message(chat, child.nodeId).parentId, isNull);
    expect(_nodeBytes(database, child.nodeId), before);
    final own = store.node(chat, child.nodeId).extra['dshgo']! as Map<String, Object?>;
    expect(own['tavernState'], {'copiedText': text});
    expect(store.nodeState(chat, child.nodeId), {'physical': '\ufeffkept'});
  });

  test('stream projection and both promotion fallbacks preserve every original prefix', () {
    const speaker = '\ufeffSpeaker';
    const oldText = '\ufeffoldword';
    const oldReasoning = '\ufeffold reason';
    final saved = store.append(
      chat,
      parentId: null,
      role: TavernRole.character,
      speaker: speaker,
      text: oldText,
      reasoning: oldReasoning,
    );
    const draft = '\ufeff\ufeffdraftword 海🐋\r\n';
    const draftReasoning = '\ufeff\u0001draft reason';
    store.beginStreamingWrites();
    try {
      store.writeStreamingBody(chat, saved.nodeId, text: draft, reasoning: draftReasoning);
      expect(store.path(chat).single.text, draft);
      expect(store.message(chat, saved.nodeId).reasoning, draftReasoning);
      expect(store.listChats().single.lastText, draft);
      expect(
        _nodeBytes(database, saved.nodeId),
        _bodyBytes(
          speaker: speaker,
          text: oldText,
          reasoning: oldReasoning,
          streamText: draft,
          streamReasoning: draftReasoning,
        ),
      );

      // Explicit text promotes the draft reasoning through its internal row fallback.
      const finalText = '\ufefffinalword';
      final first = store.updateMessage(chat, saved.nodeId, text: finalText);
      expect([first.text, first.reasoning], [finalText, draftReasoning]);
      expect(
        _nodeBytes(database, saved.nodeId),
        _bodyBytes(speaker: speaker, text: finalText, reasoning: draftReasoning),
      );

      // Explicit reasoning promotes the draft text through the other fallback.
      store.writeStreamingBody(chat, saved.nodeId, text: draft, reasoning: draftReasoning);
      const finalReasoning = '\ufeff\ufeffedited reason';
      final second = store.updateMessage(chat, saved.nodeId, reasoning: finalReasoning);
      expect([second.text, second.reasoning], [draft, finalReasoning]);
      expect(_nodeBytes(database, saved.nodeId), _bodyBytes(speaker: speaker, text: draft, reasoning: finalReasoning));
      expect(store.search('draftword', chatId: chat).single.text, draft);
      expect(store.search('finalword', chatId: chat), isEmpty);
      database.execute("INSERT INTO nodes_fts(nodes_fts, rank) VALUES('integrity-check', 1)");
    } finally {
      store.endStreamingWrites();
    }
  });

  test('reopening promotes exact pending bytes including empty body and null reasoning', () async {
    const speaker = '\ufeff鲸';
    final first = store.append(
      chat,
      parentId: null,
      role: TavernRole.character,
      speaker: speaker,
      text: '\ufeffoldword',
      reasoning: 'old reasoning',
    );
    final second = store.append(
      chat,
      parentId: null,
      role: TavernRole.character,
      speaker: speaker,
      text: 'secondword',
      reasoning: '\ufeffold reasoning',
    );
    const recoveredText = '\ufeff\ufeffrecoveredword 海🐋\r\n';
    const recoveredReasoning = '\ufeff思考\u0000尾';
    store.beginStreamingWrites();
    try {
      store.writeStreamingBody(chat, first.nodeId, text: recoveredText, reasoning: recoveredReasoning);
      store.writeStreamingBody(chat, second.nodeId, text: '', reasoning: null);
      expect(store.message(chat, second.nodeId).text, '');
      expect(store.message(chat, second.nodeId).reasoning, isNull);
      expect(store.listChats().single.lastText, '');
    } finally {
      store.endStreamingWrites();
    }
    await reopen();
    final recovered = store.message(chat, first.nodeId);
    expect([recovered.speaker, recovered.text, recovered.reasoning], [speaker, recoveredText, recoveredReasoning]);
    expect(
      _nodeBytes(database, first.nodeId),
      _bodyBytes(speaker: speaker, text: recoveredText, reasoning: recoveredReasoning),
    );
    expect(_nodeBytes(database, second.nodeId), _bodyBytes(speaker: speaker, text: '', reasoning: null));
    expect(store.message(chat, second.nodeId).reasoning, isNull);
    expect(store.listChats().single.lastText, '');
    expect(store.search('recoveredword', chatId: chat).single.text, recoveredText);
    database.execute("INSERT INTO nodes_fts(nodes_fts, rank) VALUES('integrity-check', 1)");
  });

  test('titles and preset names survive unrelated edits lists and reopening without stored guards', () async {
    const title = '\ufeff\ufeff标题🐋\r\n\u0001\u0000尾';
    const name = '\ufeff预设🐋\u0001\u0000尾';
    const source = '\ufeff{\r\n"unknown":"海"\r\n}';
    store.updateChat(chat, title: title);
    expect(store.chat(chat).title, title);
    expect(store.listChats().single.title, title);
    expect(store.listChats().single.lastText, isNull);
    store.updateChat(chat, variables: {'unrelated': '\ufeffvalue'});
    expect(store.chat(chat).title, title);
    final saved = store.createPreset(name: name, sourceText: source, raw: {'unknown': '\ufeffnested'});
    expect(saved.name, name);
    expect(store.listPresets().single.name, name);
    final original = store.preset(saved.id)!;
    final edited = store.updatePreset(saved.id, name: original.name, raw: {'edited': true}, envelope: null);
    expect(edited.name, name);
    expect(edited.sourceText, source);
    await reopen();
    expect(store.chat(chat).title, title);
    expect(store.chat(chat).variables, {'unrelated': '\ufeffvalue'});
    expect(store.listChats().single.title, title);
    expect(store.preset(saved.id)!.name, name);
    expect(store.listPresets().single.name, name);
    expect(store.preset(saved.id)!.sourceText, source);
    expect(
      Map<String, Object?>.from(
        database.select('SELECT typeof(title) AS kind, CAST(title AS BLOB) AS bytes FROM chats WHERE id = ?', [
          chat,
        ]).single,
      ),
      {'kind': 'text', 'bytes': utf8.encode(title)},
    );
    expect(
      Map<String, Object?>.from(
        database
            .select(
              '''SELECT typeof(name) AS kind, CAST(name AS BLOB) AS name_bytes,
      CAST(source_text AS BLOB) AS source_bytes FROM presets WHERE id = ?''',
              [saved.id],
            )
            .single,
      ),
      {'kind': 'text', 'name_bytes': utf8.encode(name), 'source_bytes': utf8.encode(source)},
    );
    store.updateChat(chat, title: '');
    expect(store.chat(chat).title, '');
    expect(store.updatePreset(saved.id, name: '', raw: {}, envelope: null).name, '');
    expect(store.listPresets().single.name, '');
  });
}

Map<String, Object?> _nodeBytes(Database database, String id) => Map<String, Object?>.from(
  database
      .select(
        '''
  SELECT typeof(text) AS kind, CAST(speaker AS BLOB) AS speaker, CAST(text AS BLOB) AS text,
    CAST(reasoning AS BLOB) AS reasoning, CAST(stream_text AS BLOB) AS stream_text,
    CAST(stream_reasoning AS BLOB) AS stream_reasoning FROM nodes WHERE id = ?''',
        [id],
      )
      .single,
);

Map<String, Object?> _bodyBytes({
  required String speaker,
  required String text,
  String? reasoning,
  String? streamText,
  String? streamReasoning,
}) => {
  'kind': 'text',
  'speaker': utf8.encode(speaker),
  'text': utf8.encode(text),
  'reasoning': reasoning == null ? null : utf8.encode(reasoning),
  'stream_text': streamText == null ? null : utf8.encode(streamText),
  'stream_reasoning': streamReasoning == null ? null : utf8.encode(streamReasoning),
};

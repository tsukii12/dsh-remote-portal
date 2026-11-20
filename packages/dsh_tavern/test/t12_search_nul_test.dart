import 'dart:convert';
import 'dart:typed_data';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:test/test.dart';

import 'support/t24_engine_harness.dart';

// Real public JSONL import, files, SQLite and reopen. No SQL writes or model
// events create these messages; JSON encodes the embedded NUL as field data.
void main() {
  // Stable owner negative-control name. All premises before the first search
  // assertion hold on the old product; its LIKE query then misses both bodies.
  test('facade literal search finds body and speaker suffixes after NUL', () async {
    final h = await _open();
    final imported = await _import(h, [
      _row('head\u0000NeedleSuffix 海🌊'),
      _row('ordinary content', speaker: 'voice\u0000SpeakerSuffix'),
      _row('\uFEFFprefix\u0000needlesuffix final'),
    ]);
    final chat = imported.chatId;
    final before = imported.messages;
    expect(before.map((message) => message.text), [
      'head\u0000NeedleSuffix 海🌊',
      'ordinary content',
      '\uFEFFprefix\u0000needlesuffix final',
    ]);
    expect(before[1].speaker, 'voice\u0000SpeakerSuffix');
    await h.engine.setHidden(chat, before.first.nodeId, true);

    // The first defect oracle is the public result, not SQL/call instrumentation.
    final bodies = await h.engine.searchChat(chat, 'NEEDLESUFFIX');
    expect(_ids(bodies), [before[2].nodeId, before[0].nodeId]);
    expect(bodies.last.hidden, isTrue);
    expect(bodies.map((message) => message.text), [before[2].text, before[0].text]);
    expect(_ids(await h.engine.searchChat(chat, 'speakersuffix')), [before[1].nodeId]);
    expect(_ids(await h.engine.searchChat(chat, 'needleSuffix', limit: 1)), [before[2].nodeId]);
    expect(_ids(await h.engine.searchChat(chat, 'd\u0000needLE')), [before[0].nodeId]);
    expect(await h.engine.searchChat(h.chatId, 'NEEDLESUFFIX'), isEmpty);
    expect(_ids(await h.engine.path(chat)), _ids(before));
    expect(h.model.generated, 0);

    await h.reopen();
    expect(_ids(await h.engine.path(chat)), _ids(before));
    expect((await h.engine.path(chat)).map((message) => message.text), before.map((message) => message.text));
    expect(_ids(await h.engine.searchChat(chat, 'NEEDLESUFFIX')), [before[2].nodeId, before[0].nodeId]);
    final speakers = await h.engine.searchChat(chat, 'SpeakerSuffix');
    expect(_ids(speakers), [before[1].nodeId]);
    expect(speakers.single.speaker, 'voice\u0000SpeakerSuffix');
    expect(h.model.generated, 0);
  });

  test('facade literal query keeps its NUL suffix instead of matching a shorter prefix', () async {
    final h = await _open();
    final imported = await _import(h, [
      _row('needle'),
      _row('Needle\u0000REAL'),
      _row('unrelated text', speaker: 'Alias\u0000SpeakerKey'),
    ]);
    final chat = imported.chatId;
    final before = imported.messages;
    expect(before.map((message) => message.text), ['needle', 'Needle\u0000REAL', 'unrelated text']);
    // Old LIKE treats this pattern as "%needle" and returns the shorter bodies.
    expect(await h.engine.searchChat(chat, 'needle\u0000absent'), isEmpty);
    expect(_ids(await h.engine.searchChat(chat, 'needle\u0000real')), [before[1].nodeId]);
    expect(_ids(await h.engine.searchChat(chat, 'Alias\u0000speakerkey')), [before[2].nodeId]);
    expect(await h.engine.searchChat(chat, 'Alias\u0000missing'), isEmpty);
    expect(_ids(await h.engine.searchChat(chat, '\u0000rEaL')), [before[1].nodeId]);

    await h.reopen();
    expect(await h.engine.searchChat(chat, 'needle\u0000absent'), isEmpty);
    expect(_ids(await h.engine.searchChat(chat, 'NEEDLE\u0000REAL')), [before[1].nodeId]);
    expect(_ids(await h.engine.searchChat(chat, 'alias\u0000speakerkey')), [before[2].nodeId]);
    expect(h.model.generated, 0);
  });

  test('facade literal search preserves ASCII folding Unicode data and special characters', () async {
    final h = await _open();
    const body = '\uFEFF海🌊 Alpha Beta 100%_done !marker path\\x a"b';
    const speaker = '\uFEFF声🐋';
    final imported = await _import(h, [_row(body, speaker: speaker), _row('Ä')]);
    final chat = imported.chatId;
    final before = imported.messages;
    expect(before.first.text, body);
    expect(before.first.speaker, speaker);
    for (final query in ['\uFEFF海', '海🌊', '\uFEFF声🐋', 'ALPHA BETA', '%', '_', '!', 'path\\x', 'a"b']) {
      expect(_ids(await h.engine.searchChat(chat, query)), [before.first.nodeId], reason: query);
    }
    for (final query in ['alpha OR beta', '" OR (', 'ä']) {
      expect(await h.engine.searchChat(chat, query), isEmpty, reason: query);
    }
    expect(await h.engine.searchChat(chat, ' \t\r\n'), isEmpty);
    expect(await h.engine.searchChat(chat, '海', limit: 0), isEmpty);
    await expectLater(h.engine.searchChat(chat, '海', limit: -1), throwsArgumentError);
    await expectLater(h.engine.searchChat('missing-chat', '海'), throwsStateError);
    expect(_ids(await h.engine.path(chat)), _ids(before));
    expect(h.model.generated, 0);
  });
}

Future<T24Harness> _open() async {
  final h = await T24Harness.open();
  addTearDown(h.dispose);
  return h;
}

Future<({String chatId, List<TavernMessage> messages})> _import(
  T24Harness h,
  List<Map<String, Object?>> messages,
) async {
  final text = [
    jsonEncode(<String, Object?>{'chat_metadata': <String, Object?>{}}),
    for (final message in messages) jsonEncode(message),
  ].join('\n');
  final imported = await h.engine.importChats(h.characterId, [
    TavernChatFile(fileName: 'nul-search.jsonl', bytes: Uint8List.fromList(utf8.encode('$text\n'))),
  ]);
  final chat = imported.chatIds.single;
  return (chatId: chat, messages: await h.engine.path(chat));
}

Map<String, Object?> _row(String text, {String speaker = 'Guide'}) => {
  'name': speaker,
  'is_user': false,
  'is_system': false,
  'send_date': T24Harness.at.toIso8601String(),
  'mes': text,
};

List<String> _ids(Iterable<TavernMessage> messages) => messages.map((message) => message.nodeId).toList();

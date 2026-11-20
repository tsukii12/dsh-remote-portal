import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:test/test.dart';

void main() {
  test('public export keeps complete Unicode filenames within 255 UTF-8 bytes', () async {
    final h = await _Fixture.open();
    addTearDown(h.dispose);
    final cases = <({String source, String? requested, String expected})>[
      (source: '${_repeat('海', 100)}.jsonl', requested: null, expected: '${_repeat('海', 83)}.jsonl'),
      (source: '${_repeat('🌊', 100)}.jsonl', requested: null, expected: '${_repeat('🌊', 62)}.jsonl'),
      (
        source: 'mixed-source.jsonl',
        requested: 'aa${_repeat('海', 82)}${_repeat('🌊', 16)}.jsonl',
        expected: 'aa${_repeat('海', 82)}.jsonl',
      ),
      (
        source: 'exact-source.jsonl',
        requested: 'a${_repeat('🌊', 62)}${_repeat('海', 37)}.jsonl',
        expected: 'a${_repeat('🌊', 62)}.jsonl',
      ),
      (source: '${_repeat('a', 110)}.JSONL', requested: null, expected: '${_repeat('a', 100)}.jsonl'),
      (source: 'A海🌊 title.JSONL', requested: null, expected: 'A海🌊 title.jsonl'),
      (source: 'reserved-source.jsonl', requested: '../../CON.jsonl', expected: '_CON.jsonl'),
    ];
    final originals = <String>[];
    for (var index = 0; index < cases.length; index++) {
      final imported = await h.engine.importChats(h.characterId, [
        _file(cases[index].source, [_row('原文 $index 海🌊 {{user}}')]),
      ]);
      expect(imported.chatIds, hasLength(1));
      originals.add(imported.chatIds.single);
    }
    await h.reopen();
    final reimported = <String>[];
    for (var index = 0; index < cases.length; index++) {
      final value = cases[index];
      final files = await h.engine.exportChat(originals[index], fileName: value.requested);
      expect(files, hasLength(1));
      final file = files.single;
      final document = StChatDocument.decode(file.fileName, file.bytes);
      expect(document.messages.single['mes'], '原文 $index 海🌊 {{user}}');

      // First defect-specific oracle: the old product returns 306 bytes for
      // the first case. The same public assertion runs on both products.
      expect(utf8.encode(file.fileName).length, lessThanOrEqualTo(255), reason: 'Case $index');
      expect(file.fileName, value.expected);
      expect(file.fileName.endsWith('.jsonl'), isTrue);
      expect(file.fileName.runes, isNot(contains(0xfffd)));
      expect(_sourceName(document), value.source);
      final copy = await h.engine.importChats(h.characterId, files);
      expect(copy.chatIds, hasLength(1));
      reimported.add(copy.chatIds.single);
    }
    await h.reopen();
    for (var index = 0; index < cases.length; index++) {
      for (final chatId in [originals[index], reimported[index]]) {
        expect((await h.engine.path(chatId)).single.text, '原文 $index 海🌊 {{user}}');
      }
      final file = (await h.engine.exportChat(reimported[index])).single;
      expect(file.fileName, cases[index].expected);
      expect(_sourceName(StChatDocument.decode(file.fileName, file.bytes)), cases[index].source);
    }
  });

  test('Unicode collision suffixes retain branch links and original labels after reopen and reimport', () async {
    final h = await _Fixture.open();
    addTearDown(h.dispose);
    final longStem = _repeat('海', 100);
    final names = [for (var index = 0; index < 12; index++) '$longStem-source-$index.jsonl'];
    final links = [for (final name in names.skip(1)) _stem(name)];
    final inputs = [
      for (var index = 0; index < names.length; index++)
        _file(
          names[index],
          [
            _row('shared root', user: true, extra: {'branches': links, 'bookmark_link': _stem(names[10])}),
            _row('branch-$index'),
          ],
          metadata: {
            'chat_id_hash': 42,
            'variables': {'branch': index},
            if (index != 0) 'main_chat': _stem(names.first),
          },
        ),
    ];
    final imported = await h.engine.importChats(h.characterId, inputs);
    expect(imported.chatIds, hasLength(1));
    final chatId = imported.chatIds.single;
    expect(await h.engine.tree(chatId), hasLength(13));
    await h.reopen();
    final files = await h.engine.exportChat(chatId);
    expect(files, hasLength(12));
    final expected = [
      '${_repeat('海', 83)}.jsonl',
      for (var suffix = 2; suffix <= 12; suffix++) '${_repeat('海', 82)}-$suffix.jsonl',
    ];
    expect(files.map((file) => file.fileName), expected);
    expect(files.map((file) => file.fileName.toLowerCase()).toSet(), hasLength(12));
    expect(files.every((file) => utf8.encode(file.fileName).length <= 255), isTrue);
    final documents = [for (final file in files) StChatDocument.decode(file.fileName, file.bytes)];
    expect(documents.map(_sourceName), names);
    expect(documents.map((document) => _metadata(document)['integrity']).toSet(), hasLength(12));
    for (var index = 0; index < documents.length; index++) {
      final document = documents[index];
      final metadata = _metadata(document);
      if (index == 0) {
        expect(metadata.containsKey('main_chat'), isFalse);
      } else {
        expect(metadata['main_chat'], _stem(expected.first));
      }
      final extra = document.messages.first['extra']! as Map<String, Object?>;
      expect(extra['branches'], [for (final name in expected.skip(1)) _stem(name)]);
      expect(extra['bookmark_link'], _stem(expected[10]));
      expect(document.messages.last['mes'], 'branch-$index');
    }

    final copied = await h.engine.importChats(h.characterId, files);
    expect(copied.chatIds, hasLength(1));
    final copyId = copied.chatIds.single;
    await h.reopen();
    final tree = await h.engine.tree(copyId);
    expect(tree, hasLength(13));
    final leaves = tree.where((node) => node.preview.startsWith('branch-')).toList();
    expect(leaves.map((node) => node.preview).toSet(), {for (var index = 0; index < 12; index++) 'branch-$index'});
    for (final node in leaves) {
      final index = int.parse(node.preview.substring('branch-'.length));
      await h.engine.selectNode(copyId, node.nodeId);
      expect((await h.engine.path(copyId)).map((message) => message.text), ['shared root', 'branch-$index']);
      expect(await h.engine.readVariables(copyId), {'branch': index});
    }
    await h.engine.selectNode(copyId, leaves.singleWhere((node) => node.preview == 'branch-0').nodeId);
    final again = await h.engine.exportChat(copyId);
    expect(again.map((file) => file.fileName), expected);
    expect(again.map((file) => _sourceName(StChatDocument.decode(file.fileName, file.bytes))), names);
  });
}

final _at = DateTime.utc(2026, 11, 11, 3);
String _repeat(String value, int count) => List<String>.filled(count, value).join();
String _stem(String value) => value.substring(0, value.length - '.jsonl'.length);
Map<String, Object?> _metadata(StChatDocument value) => value.header['chat_metadata']! as Map<String, Object?>;
String _sourceName(StChatDocument value) {
  final dshgo = _metadata(value)['dshgo']! as Map<String, Object?>;
  final jsonl = dshgo['chatJsonl']! as Map<String, Object?>;
  return jsonl['sourceFileName']! as String;
}

Map<String, Object?> _row(String text, {bool user = false, Map<String, Object?> extra = const {}}) => {
  'name': user ? 'User' : '鲸',
  'is_user': user,
  'is_system': false,
  'send_date': _at.toIso8601String(),
  'mes': text,
  'extra': extra,
};

TavernChatFile _file(String name, List<Map<String, Object?>> messages, {Map<String, Object?> metadata = const {}}) =>
    TavernChatFile(
      fileName: name,
      bytes: StChatDocument(
        fileName: name,
        header: {'user_name': 'unused', 'character_name': 'unused', 'chat_metadata': metadata},
        messages: messages,
      ).encode(),
    );

class _Fixture {
  _Fixture._(this.root, this.engine, this.characterId);
  final Directory root;
  TavernEngine engine;
  final String characterId;

  static Future<TavernEngine> _openEngine(Directory root) => TavernEngine.openDirectory(
    root,
    config: TavernModelConfig(apiKey: () async => null),
    clock: () => _at,
  );

  static Future<_Fixture> open() async {
    final root = await Directory.systemTemp.createTemp('dsh-t12-export-name-');
    TavernEngine? engine;
    try {
      engine = await _openEngine(root);
      final character = await engine.importCard(_card());
      return _Fixture._(root, engine, character.id);
    } catch (_) {
      try {
        await engine?.close();
      } finally {
        await root.delete(recursive: true);
      }
      rethrow;
    }
  }

  Future<void> reopen() async {
    await engine.close();
    engine = await _openEngine(root);
  }

  Future<void> dispose() async {
    try {
      await engine.close();
    } finally {
      await root.delete(recursive: true);
    }
  }
}

Uint8List _card() => Uint8List.fromList(
  utf8.encode(
    jsonEncode({
      'spec': 'chara_card_v3',
      'spec_version': '3.0',
      'data': {
        'name': '鲸',
        'description': '',
        'personality': '',
        'scenario': '',
        'first_mes': '',
        'mes_example': '',
        'creator_notes': '',
        'system_prompt': '',
        'post_history_instructions': '',
        'alternate_greetings': <String>[],
        'tags': <String>[],
        'creator': '',
        'character_version': '',
        'extensions': <String, Object?>{},
      },
    }),
  ),
);

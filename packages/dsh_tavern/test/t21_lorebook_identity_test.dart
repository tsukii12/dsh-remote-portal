import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:test/test.dart';

// Integration regressions for the origin-name contract. The explicit source
// hash comes from the WI module whose loader hash has fixed ST oracle tests.
// These cases verify façade/storage wiring, rather than a second hash port.
void main() {
  test('the imported filename retains native sticky identity independently of display title after reopen', () async {
    final h = await _open();
    final raw = _book('仅供显示的标题');
    final imported = await h.engine.importLorebook(jsonEncode(raw), fileName: r'C:\exports\原生来源.JSON');
    final id = imported.book.id;
    expect(id, isNot('原生来源'));
    expect(imported.book.name, '仅供显示的标题');
    expect(imported.book.raw, raw);
    await h.engine.bindLorebooks([id]);
    final chat = await h.chatWithSticky(raw, '原生来源');
    await h.reopen();
    await h.expectSticky(chat, raw, '原生来源', id, source: WorldInfoSource.global);
    expect(await h.engine.lorebook(id), raw);
    expect(jsonDecode(await h.engine.exportLorebook(id)), raw);
    expect((await h.engine.listLorebooks()).single.name, '仅供显示的标题');
  });

  test('the exact current chat mapping overrides file identity even when the book is also globally bound', () async {
    final h = await _open();
    final raw = _book('显示名');
    final id = (await h.engine.importLorebook(jsonEncode(raw), fileName: '文件来源.json')).book.id;
    await h.engine.bindLorebooks([id]);
    final chat = await h.chatWithSticky(raw, '当前聊天来源', worldName: '当前聊天来源', mapping: {'不能任取的第一个别名': id, '当前聊天来源': id});
    await h.reopen();
    await h.expectSticky(chat, raw, '当前聊天来源', id, source: WorldInfoSource.global);
    expect((await h.metadata(chat))['world_info'], '当前聊天来源');
    expect(jsonDecode(await h.engine.exportLorebook(id)), raw);
  });

  test('two chats sharing one local book retain separate active aliases across later turns and reopening', () async {
    final h = await _open();
    final raw = _book('同一本书的显示名');
    final id = (await h.engine.importLorebook(jsonEncode(raw), fileName: '文件来源.json')).book.id;
    await h.engine.bindLorebooks([id]);
    final aliases = {'甲来源': id, '乙来源': id};
    final first = await h.chatWithSticky(raw, '甲来源', worldName: '甲来源', mapping: aliases);
    final second = await h.chatWithSticky(raw, '乙来源', worldName: '乙来源', mapping: aliases);
    await h.expectSticky(first, raw, '甲来源', id, source: WorldInfoSource.global);
    await h.expectSticky(second, raw, '乙来源', id, source: WorldInfoSource.global);
    await h.reopen();
    await h.expectSticky(first, raw, '甲来源', id, source: WorldInfoSource.global);
    await h.expectSticky(second, raw, '乙来源', id, source: WorldInfoSource.global);
    expect((await h.metadata(first))['world_info'], '甲来源');
    expect((await h.metadata(second))['world_info'], '乙来源');
  });

  test('put keeps imported source identity while publishing only a complete raw revision', () async {
    final h = await _open();
    final raw = _book('旧显示名');
    final id = (await h.engine.importLorebook(jsonEncode(raw), fileName: '/exports/原文件.json')).book.id;
    await h.engine.bindLorebooks([id]);
    final chat = await h.chatWithSticky(raw, '原文件');
    await h.expectSticky(chat, raw, '原文件', id);
    final edited = <String, Object?>{...raw, 'name': '新显示名', 'futureRevision': 2};
    final obstruction = Directory('${h.directory.path}/lorebooks/$id.json.writing');
    await obstruction.create();
    await expectLater(
      h.engine.putLorebook(id, edited),
      throwsA(
        isA<TavernAuthoringException>()
            .having((error) => error.code, 'code', 'resource_write_failed')
            .having((error) => error.receipt?.committed, 'committed', false)
            .having((error) => error.cause, 'cause', isA<FileSystemException>()),
      ),
    );
    expect(await h.engine.lorebook(id), raw);
    expect(jsonDecode(await h.engine.exportLorebook(id)), raw);
    await obstruction.delete();
    await h.engine.putLorebook(id, edited);
    await h.reopen();
    await h.expectSticky(chat, edited, '原文件', id);
    expect((await h.engine.listLorebooks()).single.name, '新显示名');
    expect(await h.engine.lorebook(id), edited);
    expect(jsonDecode(await h.engine.exportLorebook(id)), edited);
  });

  test('an import without source filename uses its stable local id instead of the display title', () async {
    final h = await _open();
    final raw = _book('未知来源的展示名');
    final id = (await h.engine.importLorebook(jsonEncode(raw))).book.id;
    await h.engine.bindLorebooks([id]);
    final chat = await h.chatWithSticky(raw, id);
    await h.reopen();
    await h.expectSticky(chat, raw, id, id);
    expect(await h.engine.lorebook(id), raw);
    expect(jsonDecode(await h.engine.exportLorebook(id)), raw);
  });

  test('a legacy raw book keeps its id fallback through reopen and put without exporting local metadata', () async {
    final h = await _open();
    const id = 'legacy-native-book';
    final raw = _book('旧文件的展示名');
    final file = File('${h.directory.path}/lorebooks/$id.json');
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(raw), flush: true);
    await h.engine.bindLorebooks([id]);
    final chat = await h.chatWithSticky(raw, id);
    await h.reopen();
    await h.expectSticky(chat, raw, id, id);
    final edited = <String, Object?>{...raw, 'name': '旧文件改名'};
    await h.engine.putLorebook(id, edited);
    await h.reopen();
    await h.expectSticky(chat, edited, id, id);
    expect(await h.engine.lorebook(id), edited);
    expect(jsonDecode(await h.engine.exportLorebook(id)), edited);
  });
}

Map<String, Object?> _book(String title) => {
  'name': title,
  'future': {
    'stWorldName': 'user-owned value',
    'raw': ['preserved'],
  },
  'entries': {
    '7': {
      'uid': 7,
      'key': ['NEVER_MATCH_THIS_KEY'],
      'keysecondary': <String>[],
      'content': 'NATIVE_STICKY_CONTENT',
      'constant': false,
      'disable': false,
      'position': 0,
      'order': 100,
      'sticky': 9,
      'cooldown': 8,
      'useProbability': true,
      'probability': 0,
    },
  },
};

WorldInfoEntry _sourceEntry(Map<String, Object?> raw, String sourceName) =>
    WorldInfoBook.fromJson(id: sourceName, source: WorldInfoSource.global, json: raw).entries.single;

Map<String, Object?> _map(Object? value) => value! as Map<String, Object?>;

Future<_Harness> _open() async {
  final directory = await Directory.systemTemp.createTemp('dsh-t21-lorebook-identity-');
  final harness = _Harness(directory);
  await harness.open();
  addTearDown(() async {
    await harness.engine.close();
    await directory.delete(recursive: true);
  });
  return harness;
}

class _Harness {
  _Harness(this.directory);
  final Directory directory;
  final model = _Model();
  late TavernEngine engine;

  Future<void> open() async {
    engine = await TavernEngine.openDirectory(
      directory,
      modelClient: model,
      config: TavernModelConfig(apiKey: () async => 'fixture', baseUrl: 'https://configured.invalid'),
      clock: () => DateTime.utc(2026, 11, 10),
      random: () => 0.75,
    );
  }

  Future<void> reopen() async {
    await engine.close();
    await open();
  }

  Future<String> chatWithSticky(
    Map<String, Object?> raw,
    String timerSource, {
    String? worldName,
    Map<String, String> mapping = const {},
  }) async {
    final card = await engine.importCard(
      Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'spec': 'chara_card_v3',
            'spec_version': '3.0',
            'data': {
              'name': 'Guide',
              'description': '',
              'personality': '',
              'scenario': '',
              'first_mes': 'unused greeting',
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
      ),
    );
    final source = _sourceEntry(raw, timerSource);
    final document = StChatDocument(
      fileName: 'identity.jsonl',
      header: {
        'user_name': 'User',
        'character_name': 'Guide',
        'create_date': '2026-11-10T00:00:00Z',
        'chat_metadata': {
          'world_info': ?worldName,
          'timedWorldInfo': {
            'sticky': {
              source.stKey: {'hash': source.stHash, 'start': 0, 'end': 50, 'protected': false},
            },
          },
        },
      },
      messages: [
        {
          'name': 'User',
          'is_user': true,
          'is_system': false,
          'send_date': '2026-11-10T00:00:00Z',
          'mes': '不含触发词的历史',
          'extra': <String, Object?>{},
        },
      ],
    );
    final result = await engine.importChats(card.id, [
      TavernChatFile(fileName: document.fileName, bytes: document.encode()),
    ], lorebookIds: mapping);
    expect(result.notices, isEmpty);
    return result.chatIds.single;
  }

  Future<Map<String, Object?>> metadata(String chat) async {
    final files = await engine.exportChat(chat);
    final document = StChatDocument.decode(files.first.fileName, files.first.bytes);
    return _map(document.header['chat_metadata']);
  }

  Future<void> expectSticky(
    String chat,
    Map<String, Object?> raw,
    String sourceName,
    String id, {
    WorldInfoSource? source,
  }) async {
    final events = await engine.send(chat, '').toList();
    expect(events.whereType<TavernTurnFailed>(), isEmpty);
    expect(events.whereType<TavernTurnDone>(), hasLength(1));
    final expected = _sourceEntry(raw, sourceName);
    final hits = engine.inspect(chat)!.worldInfo.activated;
    expect(hits, hasLength(1), reason: 'Only the retained native timer can activate this nonmatching entry.');
    final hit = hits.single;
    expect(hit.bookId, id);
    expect(hit.reason, 'sticky');
    expect(hit.probabilityRoll, isNull);
    expect(hit.entry.book.stWorldName, sourceName);
    expect(hit.entry.stHash, expected.stHash);
    expect(hit.entry.stKey, expected.stKey);
    if (source != null) expect(hit.source, source);
    final messages = (model.bodies.last['messages']! as List<Object?>).cast<Map<String, Object?>>();
    expect(messages.map((message) => message['content'] ?? '').join('\n'), contains('NATIVE_STICKY_CONTENT'));
    final timed = _map((await metadata(chat))['timedWorldInfo']);
    expect(_map(timed['sticky']).keys, [expected.stKey]);
    expect(_map(_map(timed['sticky'])[expected.stKey])['hash'], expected.stHash);
    expect(_map(timed['cooldown']).keys, [expected.stKey]);
  }
}

class _Model extends TavernModelClient {
  final bodies = <Map<String, Object?>>[];

  @override
  Stream<ModelDelta> generate({
    required TavernModelConfig config,
    required Map<String, Object?> body,
    required ModelCancellation cancellation,
    void Function(int attempt)? onRequestStarted,
  }) async* {
    bodies.add(jsonDecode(jsonEncode(body)) as Map<String, Object?>);
    yield const ModelText('REPLY');
    yield const ModelFinished('stop');
  }
}

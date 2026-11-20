import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsh_tavern/src/api.dart';
import 'package:dsh_tavern/src/io/card_codec.dart';
import 'package:dsh_tavern/src/store/character_library.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late CharacterLibrary library;
  late DateTime now;
  final importedAt = DateTime.utc(2026, 11, 10, 1);
  final editedAt = DateTime.utc(2026, 11, 11, 2, 3, 4, 987);

  Future<StoredCharacter> importFixture([String fixture = 'card-assets.charx']) async =>
      library.importCard(await File('test/fixtures/$fixture').readAsBytes(), fileName: fixture);

  setUp(() async {
    root = await Directory.systemTemp.createTemp('dsh-tavern-card-edit-');
    now = importedAt;
    library = CharacterLibrary(root, now: () => now);
  });
  tearDown(() async {
    await root.delete(recursive: true);
  });

  test('readFields exposes the complete V3 data without sharing mutable values', () async {
    final record = await importFixture();
    final fields = (await library.readFields(record.id))!;
    expect(fields, record.card.data);
    for (final key in const [
      'name',
      'nickname',
      'description',
      'personality',
      'scenario',
      'first_mes',
      'alternate_greetings',
      'mes_example',
      'system_prompt',
      'post_history_instructions',
      'creator_notes',
      'tags',
      'creator',
      'character_version',
    ]) {
      expect(fields.containsKey(key), true, reason: key);
    }
    (fields['extensions']! as Map<String, Object?>)['unknown'] = 'edited only in the form';
    (fields['tags']! as List<Object?>).clear();
    fields['name'] = 'not saved';
    expect(await library.readFields(record.id), record.card.data);
    expect((await library.read(record.id))!.card.name, '知更');
  });

  test('editing all 14 fields preserves every other JSON value and every non-card file', () async {
    final record = await importFixture();
    final beforeFiles = await _files(Directory('${root.path}/characters/${record.id}'));
    final expected = _copy(record.card.json);
    final patch = <String, Object?>{
      'name': '新的名字 🐋',
      'nickname': '鲸',
      'description':
          ' 描述\r\n{{user}} 与 '
          r'$1 ',
      'personality': '安静而好奇',
      'scenario': '黄昏的港口',
      'first_mes': '{{user}}，欢迎。',
      'alternate_greetings': ['第一候选', '', '第三候选\n下一行'],
      'mes_example': '<START>\n{{char}}: 例子',
      'system_prompt': '{{original}}\n保留原系统提示。',
      'post_history_instructions': '末尾指令。',
      'creator_notes': '<b>作者说明</b>',
      'tags': ['中文', '岛屿', '中文'],
      'creator': '测试作者',
      'character_version': '2.1',
    };
    now = editedAt;
    final edited = await library.updateFields(record.id, patch);
    (expected['data']! as Map<String, Object?>)
      ..addAll(patch)
      ..['modification_date'] = editedAt.millisecondsSinceEpoch ~/ 1000;
    expect(edited.card.json, expected);
    expect(edited.importedAt, importedAt);
    expect(edited.avatarPath, record.avatarPath);
    expect(edited.card.originalBytes, orderedEquals(record.card.originalBytes!));
    expect(edited.card.png, record.card.png);
    expect(edited.card.assets, record.card.assets);
    final afterFiles = await _files(Directory('${root.path}/characters/${record.id}'));
    expect(afterFiles.keys, unorderedEquals(beforeFiles.keys));
    for (final name in beforeFiles.keys.where((name) => name != 'card.json')) {
      expect(afterFiles[name], orderedEquals(beforeFiles[name]!), reason: name);
    }
    expect((await CharacterLibrary(root).read(record.id))!.card.json, expected);
  });

  test('partial edits preserve omitted fields and snapshots cannot overwrite a queued edit', () async {
    final record = await importFixture('card-v3.json');
    now = editedAt;
    final tags = ['first'];
    final patch = <String, Object?>{'description': 'changed once', 'tags': tags};
    final first = library.updateFields(record.id, patch);
    patch['description'] = 'mutated after the call';
    tags.add('too late');
    final second = library.updateFields(record.id, {'name': 'new name'});
    await Future.wait([first, second]);
    final fields = (await library.readFields(record.id))!;
    final expected = _copy(record.card.data)
      ..['description'] = 'changed once'
      ..['tags'] = ['first']
      ..['name'] = 'new name'
      ..['modification_date'] = editedAt.millisecondsSinceEpoch ~/ 1000;
    expect(fields, expected);
  });

  test('empty strings and arrays clear fields; an empty patch does not modify the timestamp or file', () async {
    final record = await importFixture('card-v3.json');
    final cardFile = File('${root.path}/characters/${record.id}/card.json');
    final before = await cardFile.readAsBytes();
    now = editedAt;
    final unchanged = await library.updateFields(record.id, {});
    expect(unchanged.card.data['modification_date'], 0);
    expect(await cardFile.readAsBytes(), orderedEquals(before));
    final edited = await library.updateFields(record.id, {
      'nickname': '',
      'description': '',
      'alternate_greetings': <String>[],
      'tags': <String>[],
    });
    expect(edited.card.promptName, record.card.name);
    expect(edited.card.data['nickname'], '');
    expect(edited.card.data['description'], '');
    expect(edited.card.data['alternate_greetings'], isEmpty);
    expect(edited.card.data['tags'], isEmpty);
    expect(edited.card.data['first_mes'], record.card.data['first_mes']);
  });

  test('invalid field patches are rejected as a unit without poisoning the operation queue', () async {
    final record = await importFixture('card-v3.json');
    final cardFile = File('${root.path}/characters/${record.id}/card.json');
    final before = await cardFile.readAsBytes();
    for (final invalid in <Map<String, Object?>>[
      {'name': null},
      {'nickname': null},
      {'personality': 5},
      {'alternate_greetings': 'not a list'},
      {
        'tags': ['valid', 9],
      },
      {'creation_date': 0},
      {'modification_date': 0},
      {
        'source': ['replacement'],
      },
      {'extensions': <String, Object?>{}},
      {'character_book': <String, Object?>{}},
      {'unexpected': 'value'},
    ]) {
      await expectLater(
        library.updateFields(record.id, {'description': 'must not leak', ...invalid}),
        throwsArgumentError,
      );
      expect(await cardFile.readAsBytes(), orderedEquals(before));
    }
    await library.updateFields(record.id, {'description': 'accepted after errors'});
    expect((await library.readFields(record.id))!['description'], 'accepted after errors');
  });

  test('an interrupted temporary write is ignored and overwritten by the next complete edit', () async {
    final record = await importFixture('card-v3.json');
    final pending = File('${root.path}/characters/${record.id}/card.json.writing');
    await pending.writeAsString('{"data":{"name":"half', flush: true);
    final recovered = CharacterLibrary(root, now: () => editedAt);
    expect((await recovered.read(record.id))!.card.json, record.card.json);
    await recovered.updateFields(record.id, {'name': 'complete'});
    expect(await pending.exists(), false);
    expect((await recovered.read(record.id))!.card.name, 'complete');
  });

  test('write failure keeps the committed card readable and later edits still work', () async {
    final record = await importFixture('card-v3.json');
    final cardFile = File('${root.path}/characters/${record.id}/card.json');
    final before = await cardFile.readAsBytes();
    final obstruction = await Directory('${cardFile.path}.writing').create();
    await expectLater(library.updateFields(record.id, {'name': 'not committed'}), throwsA(isA<FileSystemException>()));
    expect(await cardFile.readAsBytes(), orderedEquals(before));
    expect((await library.read(record.id))!.card.name, record.card.name);
    await obstruction.delete();
    final saved = await library.updateFields(record.id, {'name': 'saved after retry'});
    expect(saved.card.name, 'saved after retry');
  });

  test('edited data is exported in each format while original resources remain intact', () async {
    final record = await importFixture();
    now = editedAt;
    final edited = await library.updateFields(record.id, {
      'name': '导出的新名字',
      'tags': ['new'],
    });
    for (final format in TavernCardFormat.values) {
      final decoded = const CardCodec().decode(await library.exportCard(record.id, format: format));
      expect(decoded.data['name'], '导出的新名字', reason: format.name);
      expect(decoded.data['tags'], ['new']);
      expect(decoded.json['unknown_root'], record.card.json['unknown_root']);
      expect(decoded.data['extensions'], record.card.data['extensions']);
      expect(decoded.data['source'], record.card.data['source']);
      expect(decoded.data['creation_date'], record.card.data['creation_date']);
      expect(decoded.data['modification_date'], editedAt.millisecondsSinceEpoch ~/ 1000);
      if (format == TavernCardFormat.charx) expect(decoded.assets, record.card.assets);
    }
    expect((await library.read(record.id))!.card.json, edited.card.json);
    expect((await library.read(record.id))!.card.originalBytes, orderedEquals(record.card.originalBytes!));
  });

  test('editing an upgraded V1 card keeps its raw import and unknown legacy root fields', () async {
    final record = await importFixture('card-v1.json');
    expect((await library.readFields(record.id))!.containsKey('nickname'), false);
    now = editedAt;
    final edited = await library.updateFields(record.id, {'name': '改名', 'nickname': ''});
    final expected = _copy(record.card.json);
    (expected['data']! as Map<String, Object?>)
      ..['name'] = '改名'
      ..['nickname'] = ''
      ..['modification_date'] = editedAt.millisecondsSinceEpoch ~/ 1000;
    expect(edited.card.json, expected);
    expect(edited.card.promptName, '改名');
    expect(edited.card.originalBytes, orderedEquals(record.card.originalBytes!));
  });

  test('missing and malformed ids cannot edit a different character', () async {
    final record = await importFixture('card-v3.json');
    const missing = 'card-00000000000000000000000000000000';
    expect(await library.readFields(missing), isNull);
    await expectLater(library.updateFields(missing, {'name': 'missing'}), throwsA(isA<TavernImportError>()));
    await expectLater(library.readFields('../outside'), throwsArgumentError);
    await expectLater(library.updateFields('../outside', {'name': 'outside'}), throwsArgumentError);
    expect((await library.read(record.id))!.card.json, record.card.json);
  });
}

Map<String, Object?> _copy(Map<String, Object?> value) => jsonDecode(jsonEncode(value)) as Map<String, Object?>;

Future<Map<String, Uint8List>> _files(Directory directory) async {
  final result = <String, Uint8List>{};
  await for (final file in directory.list(recursive: true, followLinks: false)) {
    if (file is File) result[file.path.substring(directory.path.length + 1)] = await file.readAsBytes();
  }
  return result;
}

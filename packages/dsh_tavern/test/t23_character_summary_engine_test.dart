import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late TavernEngine engine;
  late DateTime now;
  final importedAt = DateTime.utc(2026, 11, 10, 12);

  Future<TavernEngine> open() => TavernEngine.openDirectory(
    root,
    config: TavernModelConfig(apiKey: () async => null),
    clock: () => now,
    random: () => 0.25,
  );

  Future<void> reopen() async {
    await engine.close();
    engine = await open();
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('dsh-tavern-t23-summary-engine-');
    now = importedAt;
    engine = await open();
  });

  tearDown(() async {
    await engine.close();
    await root.delete(recursive: true);
  });

  test('a cold list with a valid index opens no card body original image resource or report file', () async {
    final imported = await engine.importCard(await File('test/fixtures/card-assets.charx').readAsBytes());
    await engine.close();
    await _removeStoredFiles(root, imported.id);
    engine = await open();
    final summary = (await engine.watchCharacters().first).single;
    expect(summary.id, imported.id);
    expect(summary.name, '知更');
    expect(summary.tags, ['fixture', '中文']);
    expect(summary.avatarPath, '${_cardDirectory(root, imported.id).path}/portrait.png');
    expect(summary.description, isEmpty);
    expect(summary.creatorNotes, isEmpty);
    expect(summary.greetings, isEmpty);
    await expectLater(engine.character(imported.id), throwsA(isA<FileSystemException>()));
  });

  test('character explicitly loads complete details while summaries retain live chat counts and dates', () async {
    final first = await engine.importCard(_card('First'));
    final second = await engine.importCard(_card('Second'));
    await engine.createChat(first.id);
    now = importedAt.add(const Duration(minutes: 1));
    await engine.createChat(first.id);
    final firstLastChat = now;
    now = importedAt.add(const Duration(minutes: 2));
    await engine.createChat(second.id);
    await reopen();

    final summaries = await engine.watchCharacters().first;
    expect(summaries.map((item) => item.id), [second.id, first.id]);
    final firstSummary = summaries.singleWhere((item) => item.id == first.id);
    expect(firstSummary.chatCount, 2);
    expect(firstSummary.lastChatAt, firstLastChat);
    expect(firstSummary.description, isEmpty);
    expect(firstSummary.greetings, isEmpty);
    final detail = (await engine.character(first.id))!;
    expect(detail.name, 'First');
    expect(detail.nickname, 'First nick');
    expect(detail.description, 'First full description');
    expect(detail.creatorNotes, 'First full creator note');
    expect(detail.greetings, ['{{char}} greeting', 'First alternate greeting']);
    expect(detail.tags, ['tag-First']);
    expect(detail.regexCount, 1);
    expect(detail.chatCount, 2);
    expect(detail.lastChatAt, firstLastChat);
    expect(detail.importedAt, importedAt);
  });

  test('successive displays reuse a loaded full card after its source files become unavailable', () async {
    final imported = await engine.importCard(_card('Cached'));
    final chat = await engine.createChat(imported.id);
    await reopen();
    expect((await engine.displayText(chat, text: 'token')).text, 'Cached nick');
    await _removeStoredFiles(root, imported.id);
    for (var index = 0; index < 3; index++) {
      final displayed = await engine.displayText(chat, text: 'token $index');
      expect(displayed.text, 'Cached nick $index');
      expect(displayed.superseded, false);
    }
    expect((await engine.character(imported.id))!.description, 'Cached full description');
    expect((await engine.path(chat)).single.text, 'Cached nick greeting');
  });

  test('an edit refreshes only its own full cache entry and the next character list', () async {
    final first = await engine.importCard(_card('First'));
    final second = await engine.importCard(_card('Second'));
    final firstChat = await engine.createChat(first.id);
    final secondChat = await engine.createChat(second.id);
    await reopen();
    await engine.character(first.id);
    await engine.character(second.id);
    await _removeStoredFiles(root, second.id);

    now = now.add(const Duration(minutes: 1));
    final updated = await engine.updateCharacterFields(first.id, {
      'name': 'Edited first',
      'nickname': 'Edited nick',
      'description': 'Edited complete description',
      'first_mes': 'Edited greeting',
      'tags': ['edited tag'],
    });
    expect(updated.description, 'Edited complete description');
    final summaries = await engine.watchCharacters().first;
    final firstSummary = summaries.singleWhere((item) => item.id == first.id);
    expect(firstSummary.name, 'Edited first');
    expect(firstSummary.tags, ['edited tag']);
    expect(firstSummary.description, isEmpty);
    expect(firstSummary.greetings, isEmpty);
    expect((await engine.character(first.id))!.greetings.first, 'Edited greeting');
    expect((await engine.displayText(firstChat, text: 'token')).text, 'Edited nick');
    expect((await engine.character(second.id))!.description, 'Second full description');
    expect((await engine.displayText(secondChat, text: 'token')).text, 'Second nick');
  });

  test('importing another card preserves previously loaded full records', () async {
    final first = await engine.importCard(_card('First'));
    final chat = await engine.createChat(first.id);
    await reopen();
    await engine.character(first.id);
    await _removeStoredFiles(root, first.id);
    final second = await engine.importCard(_card('Second'));
    expect((await engine.watchCharacters().first).map((item) => item.id), unorderedEquals([first.id, second.id]));
    expect((await engine.character(first.id))!.description, 'First full description');
    expect((await engine.displayText(chat, text: 'token')).text, 'First nick');
    expect((await engine.character(second.id))!.description, 'Second full description');
  });

  test('deleting one card evicts only that record and cannot return its cached details', () async {
    final first = await engine.importCard(_card('First'));
    final second = await engine.importCard(_card('Second'));
    await engine.createChat(first.id);
    final secondChat = await engine.createChat(second.id);
    await reopen();
    await engine.character(first.id);
    await engine.character(second.id);
    await _removeStoredFiles(root, second.id);
    await engine.deleteCharacter(first.id);
    expect(await engine.character(first.id), isNull);
    expect((await engine.watchCharacters().first).single.id, second.id);
    expect((await engine.character(second.id))!.description, 'Second full description');
    expect((await engine.displayText(secondChat, text: 'token')).text, 'Second nick');
  });

  test('a failed detail read is evicted and a later call can retry the repaired source', () async {
    final imported = await engine.importCard(_card('Retry'));
    await engine.close();
    final original = File('${_cardDirectory(root, imported.id).path}/original.json');
    final held = await original.rename('${original.path}.unavailable');
    engine = await open();
    expect((await engine.watchCharacters().first).single.name, 'Retry');
    await expectLater(engine.character(imported.id), throwsA(isA<FileSystemException>()));
    await held.rename(original.path);
    expect((await engine.character(imported.id))!.description, 'Retry full description');
  });

  test('facade unknown identifiers keep nullable lookup and missing-character errors', () async {
    expect(await engine.character('missing'), isNull);
    expect(await engine.character('../outside'), isNull);
    await expectLater(engine.createChat('missing'), throwsA(isA<TavernImportError>()));
    // The lower-level file API keeps its pre-existing strict validation.
    await expectLater(CharacterLibrary(root).read('missing'), throwsArgumentError);
  });

  test('a missing detail result is not retained after the card directory becomes available', () async {
    final imported = await engine.importCard(_card('Reappearing'));
    await engine.close();
    final directory = _cardDirectory(root, imported.id);
    final held = await directory.rename('${root.path}/temporarily-unavailable-card');
    engine = await open();
    expect(await engine.character(imported.id), isNull);
    await held.rename(directory.path);
    expect((await engine.character(imported.id))!.description, 'Reappearing full description');
  });

  test('old-library recovery through the facade reads JSON but no original or embedded bytes', () async {
    final imported = await engine.importCard(await File('test/fixtures/card-assets.charx').readAsBytes());
    await engine.close();
    await File('${root.path}/character-index/${imported.id}.json').delete();
    await _removeStoredFiles(root, imported.id, keepJson: true);
    engine = await open();
    expect((await engine.watchCharacters().first).single.name, '知更');
    expect(await File('${root.path}/character-index/${imported.id}.json').exists(), true);
    await expectLater(engine.character(imported.id), throwsA(isA<FileSystemException>()));
  });

  test('moving the library changes summary and detail avatar paths to the new root', () async {
    final imported = await engine.importCard(await File('test/fixtures/card-assets.charx').readAsBytes());
    await engine.close();
    final previous = root.path;
    root = await root.rename('$previous-moved');
    engine = await open();
    final summary = (await engine.watchCharacters().first).single;
    final detail = (await engine.character(imported.id))!;
    final expected = '${_cardDirectory(root, imported.id).path}/portrait.png';
    expect(summary.avatarPath, expected);
    expect(detail.avatarPath, expected);
    expect(await File(expected).exists(), true);
    expect(detail.description, isNotEmpty);
    expect(detail.greetings, isNotEmpty);
    final index = await File('${root.path}/character-index/${imported.id}.json').readAsString();
    expect(index, isNot(contains(previous)));
  });

  test('the bounded detail cache retains the eight most recently accessed cards', () async {
    final imported = <TavernCharacter>[];
    for (var index = 0; index < 9; index++) {
      imported.add(await engine.importCard(_card('Card $index')));
    }
    await reopen();
    for (var index = 0; index < 8; index++) {
      await engine.character(imported[index].id);
    }
    // Refresh zero, so one is the oldest entry before the ninth distinct read.
    await engine.character(imported[0].id);
    final zero = File('${_cardDirectory(root, imported[0].id).path}/original.json');
    final one = File('${_cardDirectory(root, imported[1].id).path}/original.json');
    await zero.rename('${zero.path}.unavailable');
    final heldOne = await one.rename('${one.path}.unavailable');
    await engine.character(imported[8].id);
    expect((await engine.character(imported[0].id))!.description, 'Card 0 full description');
    await expectLater(engine.character(imported[1].id), throwsA(isA<FileSystemException>()));
    await heldOne.rename(one.path);
    expect((await engine.character(imported[1].id))!.description, 'Card 1 full description');
  });
}

Directory _cardDirectory(Directory root, String id) => Directory('${root.path}/characters/$id');

Future<void> _removeStoredFiles(Directory root, String id, {bool keepJson = false}) async {
  final directory = _cardDirectory(root, id);
  await for (final entity in directory.list(followLinks: false)) {
    if (keepJson && entity is File && const {'card.json', 'library.json'}.contains(entity.uri.pathSegments.last)) {
      continue;
    }
    await entity.delete(recursive: true);
  }
}

Uint8List _card(String name) => Uint8List.fromList(
  utf8.encode(
    jsonEncode({
      'spec': 'chara_card_v3',
      'spec_version': '3.0',
      'data': {
        'name': name,
        'nickname': '$name nick',
        'description': '$name full description',
        'creator_notes': '$name full creator note',
        'first_mes': '{{char}} greeting',
        'alternate_greetings': ['$name alternate greeting'],
        'tags': ['tag-$name'],
        'extensions': {
          'regex_scripts': [
            {
              'id': 'display-name',
              'scriptName': 'Display character name',
              'findRegex': 'token',
              'replaceString': '{{char}}',
              'trimStrings': <String>[],
              'placement': [2],
              'disabled': false,
              'markdownOnly': true,
              'promptOnly': false,
              'runOnEdit': false,
              'substituteRegex': 0,
            },
          ],
        },
      },
    }),
  ),
);

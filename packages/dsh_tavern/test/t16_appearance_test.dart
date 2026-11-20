import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:image/image.dart' as image;
import 'package:test/test.dart';

// Real card containers, library files and (in the facade case) SQLite.
// A loopback server counts prohibited downloads; no external request is made.
void main() {
  const codec = CardCodec();
  late Directory root;
  late CharacterLibrary library;
  final importedAt = DateTime.utc(2026, 11, 10, 5);

  setUp(() async {
    root = await Directory.systemTemp.createTemp('t16-appearance-');
    library = CharacterLibrary(root, now: () => importedAt);
  });
  tearDown(() async {
    await root.delete(recursive: true);
  });

  test('old DTO construction and cards without appearance data keep null and empty defaults', () {
    const value = TavernCharacter(id: 'card', name: 'Card');
    expect(value.theme, isNull);
    expect(value.assets, isEmpty);
    final card = codec.decode(_bytes(_document()));
    final before = jsonEncode(card.json);
    final character = card.toCharacter('one');
    expect(character.theme, isNull);
    expect(character.assets, isEmpty);
    expect(character.name, card.name);
    expect(jsonEncode(card.json), before);
  });

  test('theme is a deep detached JSON copy and does not expose other extensions', () {
    final json = _document();
    final theme = <String, Object?>{
      'accent': '#123456',
      'fonts': {
        'body': 'font one',
        'names': ['海', '鲸'],
      },
      'future': [
        null,
        true,
        1.5,
        {'x': r'{{literal}} $1'},
      ],
    };
    final extensions = _data(json)['extensions']! as Map<String, Object?>;
    extensions['dshgo'] = {
      'theme': theme,
      'notAppearance': {'keep': 'private'},
    };
    extensions['tavern_helper'] = {
      'scripts': ['not exposed'],
    };
    final card = codec.decode(_bytes(json));
    final before = jsonEncode(card.json);
    final first = card.toCharacter('one').theme! as Map<String, Object?>;
    final second = card.toCharacter('one').theme! as Map<String, Object?>;
    expect(first, theme);
    expect(first.containsKey('notAppearance'), isFalse);
    (first['fonts']! as Map<String, Object?>)['body'] = 'changed';
    ((first['fonts']! as Map<String, Object?>)['names']! as List<Object?>).clear();
    (first['future']! as List<Object?>).add('changed');
    first['accent'] = null;
    expect(second, theme);
    expect(card.toCharacter('one').theme, theme);
    expect(jsonEncode(card.json), before);
  });

  test('theme keeps every JSON shape and malformed extension containers yield null', () {
    for (final theme in <Object?>[
      null,
      false,
      7.25,
      'literal theme',
      [
        1,
        null,
        {'nested': true},
      ],
      <String, Object?>{},
    ]) {
      final json = _document();
      (_data(json)['extensions']! as Map<String, Object?>)['dshgo'] = {'theme': theme};
      final card = codec.decode(_bytes(json));
      final before = jsonEncode(card.json);
      expect(card.toCharacter('one').theme, theme);
      expect(jsonEncode(card.json), before);
    }
    for (final bad in <Object?>[
      null,
      'bad',
      [1],
    ]) {
      final json = _document();
      (_data(json)['extensions']! as Map<String, Object?>)['dshgo'] = bad;
      expect(codec.decode(_bytes(json)).toCharacter('one').theme, isNull);
      _data(json)['extensions'] = bad;
      expect(codec.decode(_bytes(json)).toCharacter('one').theme, isNull);
    }
  });

  test('asset object order and nullable fields are preserved without mutating the raw declarations', () {
    final json = _document();
    _data(json)['assets'] = [
      {
        'type': 'emotion',
        'name': ' smile ',
        'uri': 'embeded://A.png',
        'ext': 'PNG',
        'future': [7],
      },
      17,
      null,
      {
        'type': 5,
        'name': null,
        'uri': false,
        'ext': ['png'],
      },
      {'type': 'background', 'name': 'sea', 'uri': 'https://example.invalid/sea.png', 'ext': 'png'},
      <String, Object?>{},
      'not an object',
    ];
    final card = codec.decode(_bytes(json));
    final before = jsonEncode(card.json);
    final character = card.toCharacter('one');
    expect(_assets(character), [
      {'type': 'emotion', 'name': ' smile ', 'uri': 'embeded://A.png', 'ext': 'PNG', 'localPath': null},
      {'type': null, 'name': null, 'uri': null, 'ext': null, 'localPath': null},
      {'type': 'background', 'name': 'sea', 'uri': 'https://example.invalid/sea.png', 'ext': 'png', 'localPath': null},
      {'type': null, 'name': null, 'uri': null, 'ext': null, 'localPath': null},
    ]);
    character.assets.clear();
    expect(card.toCharacter('one').assets, hasLength(4));
    expect(jsonEncode(card.json), before);
    for (final invalid in <Object?>[
      null,
      'not a list',
      {'uri': 'wrong shape'},
    ]) {
      _data(json)['assets'] = invalid;
      expect(codec.decode(_bytes(json)).toCharacter('one').assets, isEmpty);
    }
  });

  test('CHARX resolves embedded aliases and safe relative payloads without exposing undeclared files', () async {
    final json = _document();
    final smile = _png(2, 3);
    final sea = _png(3, 2);
    final literal = _png(1, 4);
    final declarations = <Object?>[
      {'type': 'emotion', 'name': 'smile', 'uri': 'embeded://A/Smile.png', 'ext': 'png'},
      {'type': 'background', 'name': 'sea', 'uri': 'embedded://assets/bg Sea.png', 'ext': 'png'},
      {'type': 'emotion', 'name': 'legacy alias', 'uri': '__asset:A/Smile.png', 'ext': 'png'},
      {'type': 'emotion', 'name': 'relative', 'uri': 'A/Smile.png', 'ext': 'png'},
      {'type': 'emotion', 'name': 'case differs', 'uri': 'embeded://a/smile.png', 'ext': 'png'},
      {'type': 'emotion', 'name': 'literal percent', 'uri': 'embeded://%2e%2e/literal.png', 'ext': 'png'},
    ];
    _data(json)['assets'] = declarations;
    final bytes = _charx(json, {
      'A/Smile.png': smile,
      'assets/bg Sea.png': sea,
      '%2e%2e/literal.png': literal,
      'unknown-app.bin': Uint8List.fromList([0, 1, 127, 255]),
    });
    final imported = await library.importCard(bytes);
    final character = imported.toCharacter();
    expect(character.assets, hasLength(declarations.length));
    expect(
      character.assets.map((asset) => asset.uri),
      declarations.map((value) => (value! as Map<String, Object?>)['uri']),
    );
    final expectedPaths = <String?>[
      'A/Smile.png',
      'assets/bg Sea.png',
      'A/Smile.png',
      'A/Smile.png',
      null,
      '%2e%2e/literal.png',
    ];
    final expectedBytes = <Uint8List?>[smile, sea, smile, smile, null, literal];
    for (var index = 0; index < expectedPaths.length; index++) {
      final path = expectedPaths[index];
      final asset = character.assets[index];
      expect(asset.localPath, path == null ? null : '${imported.directoryPath}/resources/$path');
      if (path != null) {
        expect(await File(asset.localPath!).readAsBytes(), orderedEquals(expectedBytes[index]!));
      }
    }
    expect(character.assets.any((asset) => asset.uri == 'unknown-app.bin'), isFalse);
    expect(imported.card.assets.containsKey('unknown-app.bin'), isTrue);
    expect(imported.card.assetBytes('A/Smile.png'), isNull, reason: 'The byte codec URI contract was not broadened');
    expect((await library.readFields(imported.id))!['assets'], declarations);
    expect(await File('${imported.directoryPath}/original.charx').readAsBytes(), orderedEquals(bytes));
    final reloaded = (await CharacterLibrary(root).read(imported.id))!;
    expect(_assets(reloaded.toCharacter()), _assets(character));
  });

  test('missing and unsafe asset references remain declared with no guessed filesystem path', () async {
    final json = _document();
    final uris = [
      'embeded://missing.png',
      'embeded://../outside.png',
      'embedded:///absolute.png',
      '__asset:C:/outside.png',
      '../outside.png',
      'file:///outside.png',
      'ccdefault:',
      '',
    ];
    _data(json)['assets'] = [
      for (final uri in uris) {'type': 'emotion', 'name': uri, 'uri': uri, 'ext': 'png'},
    ];
    final imported = await library.importCard(_bytes(json));
    final assets = imported.toCharacter().assets;
    expect(assets.map((asset) => asset.uri), uris);
    expect(assets.map((asset) => asset.localPath), everyElement(isNull));
    expect(imported.card.data['assets'], _data(json)['assets']);
    expect(await Directory('${imported.directoryPath}/resources').exists(), isFalse);
  });

  test('ccdefault exposes the exact source PNG rather than a synthesized URI', () async {
    final json = _document();
    _data(json)['assets'] = [
      {'type': 'icon', 'name': 'main', 'uri': 'ccdefault:', 'ext': 'png'},
    ];
    final png = codec.encode(
      TavernCard(json: json, png: _png(2, 3)),
      modifiedAt: importedAt,
    );
    final imported = await library.importCard(png);
    final asset = imported.toCharacter().assets.single;
    expect(asset.uri, 'ccdefault:');
    expect(asset.localPath, '${imported.directoryPath}/source.png');
    expect(await File(asset.localPath!).readAsBytes(), orderedEquals(png));
    expect(imported.avatarPath, '${imported.directoryPath}/portrait.png');
    final reloaded = (await library.read(imported.id))!;
    expect(reloaded.toCharacter().assets.single.localPath, asset.localPath);
    expect(reloaded.card.data['assets'], _data(json)['assets']);
  });

  test('legacy PNG asset chunks materialize a readable path while keeping their URI', () async {
    final json = _document();
    _data(json)['assets'] = [
      {'type': 'emotion', 'name': 'legacy', 'uri': '__asset:assets/legacy.png', 'ext': 'png'},
    ];
    final payload = _png(3, 4);
    final base = codec.encode(
      TavernCard(json: json, png: _png(2, 2)),
      modifiedAt: importedAt,
    );
    final png = _insertText(base, 'chara-ext-asset_:assets/legacy.png', base64Encode(payload));
    final imported = await library.importCard(png);
    final asset = imported.toCharacter().assets.single;
    expect(asset.uri, '__asset:assets/legacy.png');
    expect(asset.localPath, '${imported.directoryPath}/resources/assets/legacy.png');
    expect(await File(asset.localPath!).readAsBytes(), orderedEquals(payload));
    expect(await File('${imported.directoryPath}/source.png').readAsBytes(), orderedEquals(png));
    final reloaded = (await CharacterLibrary(root).read(imported.id))!;
    expect(_assets(reloaded.toCharacter()), _assets(imported.toCharacter()));
    expect(reloaded.card.data['assets'], imported.card.data['assets']);
  });

  test('remote data and file URIs keep their text without downloads or local path guesses', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var requests = 0;
    final subscription = server.listen((request) {
      requests++;
      request.response.statusCode = 500;
      unawaited(request.response.close());
    });
    try {
      final external = File('${root.path}/outside.png');
      final externalBytes = _png(4, 3);
      await external.writeAsBytes(externalBytes);
      final remote = 'http://127.0.0.1:${server.port}/image.png?original=1#fragment';
      final inline = Uri.dataFromBytes(_png(1, 1), mimeType: 'image/png').toString();
      final uris = [remote, inline, external.absolute.uri.toString()];
      final json = _document();
      _data(json)['assets'] = [
        for (final uri in uris) {'type': 'emotion', 'name': uri, 'uri': uri, 'ext': 'png'},
      ];
      final imported = await library.importCard(_bytes(json));
      final reloaded = (await library.read(imported.id))!;
      expect(reloaded.toCharacter().assets.map((asset) => asset.uri), uris);
      expect(reloaded.toCharacter().assets.map((asset) => asset.localPath), everyElement(isNull));
      expect(reloaded.card.assets, isEmpty);
      expect(reloaded.card.data['assets'], _data(json)['assets']);
      expect(await Directory('${reloaded.directoryPath}/resources').exists(), isFalse);
      await Future<void>.delayed(Duration.zero);
      expect(requests, 0);
      expect(await external.readAsBytes(), orderedEquals(externalBytes));
    } finally {
      await server.close(force: true);
      await subscription.cancel();
    }
  });

  test('field and book updates reopening and export retain appearance paths and original files', () async {
    final json = _document();
    final theme = {
      'accent': '#abcdef',
      'future': [
        1,
        null,
        {'name': '海'},
      ],
    };
    (_data(json)['extensions']! as Map<String, Object?>)['dshgo'] = {'theme': theme, 'other': 'keep'};
    _data(json)['assets'] = [
      {
        'type': 'emotion',
        'name': 'smile',
        'uri': 'embeded://smile.png',
        'ext': 'png',
        'future': {'keep': true},
      },
    ];
    final payload = _png(2, 3);
    final bytes = _charx(json, {
      'smile.png': payload,
      'unknown.bin': Uint8List.fromList([1, 2, 3]),
    });
    final imported = await library.importCard(bytes, fileName: 'appearance.charx');
    final directory = Directory(imported.directoryPath!);
    final before = await _files(directory, includeCard: false);
    final expectedAssets = _assets(imported.toCharacter());
    final edited = await library.updateFields(imported.id, {'name': 'Edited'});
    expect(edited.directoryPath, imported.directoryPath);
    expect(edited.toCharacter().theme, theme);
    expect(_assets(edited.toCharacter()), expectedAssets);
    final bookEdited = await library.addBookEntry(imported.id, {'content': 'new entry'});
    expect(bookEdited.directoryPath, imported.directoryPath);
    expect(bookEdited.toCharacter().theme, theme);
    expect(_assets(bookEdited.toCharacter()), expectedAssets);
    final reloaded = (await CharacterLibrary(root).read(imported.id))!;
    expect(reloaded.directoryPath, imported.directoryPath);
    expect(reloaded.toCharacter().theme, theme);
    expect(_assets(reloaded.toCharacter()), expectedAssets);
    final summary = (await library.list()).single.toCharacter();
    expect(summary.theme, isNull);
    expect(summary.assets, isEmpty);
    expect(await _files(directory, includeCard: false), before);
    expect(await File('${directory.path}/original.charx').readAsBytes(), orderedEquals(bytes));
    final beforeExport = await _files(directory);
    final exported = codec.decode(await library.exportCard(imported.id, format: TavernCardFormat.charx));
    expect(exported.json, bookEdited.card.json);
    expect(exported.data['assets'], _data(json)['assets']);
    expect(exported.assets, bookEdited.card.assets);
    expect(await _files(directory), beforeExport);
    final exportedJson = codec.decode(await library.exportCard(imported.id, format: TavernCardFormat.json));
    expect(exportedJson.data['extensions'], bookEdited.card.data['extensions']);
    expect((exportedJson.data['assets']! as List<Object?>).single, {
      'type': 'emotion',
      'name': 'smile',
      'uri': Uri.dataFromBytes(payload, mimeType: 'image/png').toString(),
      'ext': 'png',
      'future': {'keep': true},
    });
    expect(await _files(directory), beforeExport);
  });

  test('missing materialized payloads keep the existing read failure and queue recovery behavior', () async {
    final json = _document();
    _data(json)['assets'] = [
      {'type': 'emotion', 'name': 'smile', 'uri': 'embeded://smile.png', 'ext': 'png'},
    ];
    final payload = _png(2, 3);
    final imported = await library.importCard(_charx(json, {'smile.png': payload}));
    final path = imported.toCharacter().assets.single.localPath!;
    final metadata = await File('${imported.directoryPath}/library.json').readAsBytes();
    await File(path).delete();
    await expectLater(library.read(imported.id), throwsA(isA<FileSystemException>()));
    expect(await File(path).exists(), isFalse);
    expect(await File('${imported.directoryPath}/library.json').readAsBytes(), orderedEquals(metadata));
    await File(path).writeAsBytes(payload);
    final recovered = (await library.read(imported.id))!;
    expect(recovered.toCharacter().assets.single.localPath, path);
    expect(await File(path).readAsBytes(), orderedEquals(payload));
  });

  test('a detached card record does not invent a filesystem location for in-memory bytes', () {
    final json = _document();
    _data(json)['assets'] = [
      {'type': 'emotion', 'name': 'memory', 'uri': 'embeded://memory.png', 'ext': 'png'},
      {'type': 'icon', 'name': 'main', 'uri': 'ccdefault:', 'ext': 'png'},
    ];
    final card = TavernCard(json: json, png: _png(1, 1), assets: {'memory.png': _png(2, 3)});
    final record = StoredCharacter(id: 'detached', card: card, importedAt: importedAt);
    expect(record.directoryPath, isNull);
    expect(record.toCharacter().assets, hasLength(2));
    expect(record.toCharacter().assets.map((asset) => asset.localPath), everyElement(isNull));
    expect(card.toCharacter('detached').assets.map((asset) => asset.localPath), everyElement(isNull));
  });

  test('public import list character edit and reopen expose detached appearance without a model call', () async {
    var modelFactories = 0;
    Future<TavernEngine> open() => TavernEngine.open(
      root,
      config: TavernModelConfig(apiKey: () async => 'fixture', baseUrl: 'https://example.invalid/v1', model: 'fixture'),
      modelClient: TavernModelClient(
        clientFactory: () {
          modelFactories++;
          throw StateError('Appearance reads must not call the model');
        },
      ),
      clock: () => importedAt,
    );
    var engine = await open();
    try {
      final json = _document();
      final theme = {
        'accent': '#123456',
        'nested': [1, null],
      };
      (_data(json)['extensions']! as Map<String, Object?>)['dshgo'] = {'theme': theme, 'other': 'private'};
      (_data(json)['extensions']! as Map<String, Object?>)['regex_scripts'] = [
        {
          'id': 'invalid',
          'scriptName': 'invalid',
          'findRegex': '/[/',
          'replaceString': 'unused',
          'placement': [2],
          'markdownOnly': true,
          'promptOnly': false,
          'disabled': false,
          'runOnEdit': false,
          'substituteRegex': 0,
          'trimStrings': <String>[],
        },
      ];
      _data(json)['assets'] = [
        {'type': 'emotion', 'name': 'smile', 'uri': 'embeded://smile.png', 'ext': 'png'},
      ];
      final Tavern tavern = engine;
      final payload = _png(2, 3);
      final imported = await tavern.importCard(_charx(json, {'smile.png': payload}));
      final expectedAssets = _assets(imported);
      expect(imported.theme, theme);
      expect(
        imported.regexDiagnostics.any(
          (issue) =>
              issue.status == TavernRegexCompatibility.incompatible &&
              issue.path == r'$.data.extensions.regex_scripts[0].findRegex',
        ),
        isTrue,
      );
      final reportBefore = (await tavern.readImportReport(TavernImportKind.character, imported.id))!.toJson();
      expect(await File(imported.assets.single.localPath!).readAsBytes(), orderedEquals(payload));
      (imported.theme! as Map<String, Object?>)['accent'] = 'caller edit';
      imported.assets.clear();
      final read = (await tavern.character(imported.id))!;
      expect(read.theme, theme);
      expect(_assets(read), expectedAssets);
      final listed = (await tavern.watchCharacters().first).single;
      expect(listed.theme, isNull);
      expect(listed.assets, isEmpty);
      expect((await tavern.readImportReport(TavernImportKind.character, imported.id))!.toJson(), reportBefore);
      final edited = await tavern.updateCharacterFields(imported.id, {'description': 'edited'});
      expect(edited.theme, theme);
      expect(_assets(edited), expectedAssets);
      expect((await tavern.characterFields(imported.id))!['extensions'], _data(json)['extensions']);
      await engine.close();
      engine = await open();
      final reopened = (await engine.character(imported.id))!;
      expect(reopened.theme, theme);
      expect(_assets(reopened), expectedAssets);
      expect(modelFactories, 0);
    } finally {
      await engine.close();
    }
  });

  test('appearance stays out of valid and recovered summaries without opening original or resource bytes', () async {
    final json = _document();
    (_data(json)['extensions']! as Map<String, Object?>)['dshgo'] = {
      'theme': {'appearance-only-marker': List<String>.filled(1024, 'theme payload')},
    };
    _data(json)['assets'] = [
      for (var index = 0; index < 64; index++)
        {'type': 'emotion', 'name': 'asset-$index', 'uri': 'embeded://smile.png', 'ext': 'png'},
    ];
    final record = await library.importCard(_charx(json, {'smile.png': _png(2, 3)}));
    final directory = Directory(record.directoryPath!);
    final source = File('${directory.path}/card.json');
    final metadata = File('${directory.path}/library.json');
    final sourceBefore = await source.readAsBytes();
    final metadataBefore = await metadata.readAsBytes();
    final index = File('${root.path}/character-index/${record.id}.json');
    expect(await index.readAsString(), isNot(contains('appearance-only-marker')));
    expect(await index.readAsString(), isNot(contains('embeded://smile.png')));
    expect(record.toCharacter().assets, hasLength(64));
    await Directory('${directory.path}/resources').delete(recursive: true);
    await File('${directory.path}/original.charx').delete();
    final indexed = (await CharacterLibrary(root).list()).single.toCharacter();
    expect(indexed.theme, isNull);
    expect(indexed.assets, isEmpty);
    await index.delete();
    final recovered = (await CharacterLibrary(root).list()).single.toCharacter();
    expect(recovered.id, record.id);
    expect(recovered.theme, isNull);
    expect(recovered.assets, isEmpty);
    expect(await source.readAsBytes(), orderedEquals(sourceBefore));
    expect(await metadata.readAsBytes(), orderedEquals(metadataBefore));
    expect(await Directory('${directory.path}/resources').exists(), isFalse);
    await source.delete();
    await metadata.delete();
    expect((await CharacterLibrary(root).list()).single.id, record.id);
  });

  test('moving the library recomputes per-character paths without rewriting portable JSON or reports', () async {
    final engine = await _openWithoutModel(root, importedAt);
    final json = _document();
    final theme = {'accent': '#123456', 'background': 'embeded://shared.png'};
    (_data(json)['extensions']! as Map<String, Object?>)['dshgo'] = {'theme': theme};
    _data(json)['assets'] = [
      {'type': 'background', 'name': 'same name', 'uri': 'embeded://shared.png', 'ext': 'png'},
    ];
    final firstBytes = _png(2, 3);
    final secondBytes = _png(3, 4);
    late TavernCharacter first;
    late TavernCharacter second;
    final before = <String, Uint8List>{};
    try {
      first = await engine.importCard(_charx(json, {'shared.png': firstBytes}));
      second = await engine.importCard(_charx(json, {'shared.png': secondBytes}));
      for (final id in [first.id, second.id]) {
        for (final name in ['card.json', 'library.json', 'import-report.json']) {
          final path = 'characters/$id/$name';
          before[path] = await File('${root.path}/$path').readAsBytes();
        }
        final path = 'character-index/$id.json';
        before[path] = await File('${root.path}/$path').readAsBytes();
      }
    } finally {
      await engine.close();
    }
    final oldRoot = root.path;
    root = await root.rename('$oldRoot-moved');
    final relocated = CharacterLibrary(root);
    for (final entry in [(first, firstBytes), (second, secondBytes)]) {
      final detail = (await relocated.read(entry.$1.id))!.toCharacter();
      expect(detail.theme, theme);
      expect(detail.assets.single.uri, 'embeded://shared.png');
      expect(detail.assets.single.localPath, '${root.absolute.path}/characters/${detail.id}/resources/shared.png');
      expect(detail.assets.single.localPath, isNot(entry.$1.assets.single.localPath));
      expect(await File(detail.assets.single.localPath!).readAsBytes(), orderedEquals(entry.$2));
      expect((await relocated.readImportReport(detail.id))!.stale, isFalse);
    }
    for (final entry in before.entries) {
      expect(await File('${root.path}/${entry.key}').readAsBytes(), orderedEquals(entry.value), reason: entry.key);
    }
  });

  test('backup captures an accepted book edit and restores appearance paths and stale report at a new root', () async {
    final engine = await _openWithoutModel(root, importedAt);
    final work = await Directory.systemTemp.createTemp('t16-appearance-backup-');
    TavernEngine? restored;
    try {
      final json = _document();
      _data(json).remove('character_book');
      final theme = {'layout': 'novel', 'background': '__asset:assets/smile.png'};
      (_data(json)['extensions']! as Map<String, Object?>)['dshgo'] = {'theme': theme};
      _data(json)['assets'] = [
        {'type': 'icon', 'name': 'main', 'uri': 'ccdefault:', 'ext': 'png'},
        {'type': 'emotion', 'name': 'smile', 'uri': '__asset:assets/smile.png', 'ext': 'png'},
      ];
      final payload = _png(3, 4);
      final base = codec.encode(
        TavernCard(json: json, png: _png(2, 3)),
        modifiedAt: importedAt,
      );
      final png = _insertText(base, 'chara-ext-asset_:assets/smile.png', base64Encode(payload));
      final imported = await engine.importCard(png);
      final reportPath = 'characters/${imported.id}/import-report.json';
      final reportBefore = await File('${root.path}/$reportPath').readAsBytes();
      final editing = engine.addCharacterBookEntry(imported.id, {
        'keys': ['beacon'],
        'content': 'captured book',
      });
      final archive = File('${work.path}/library.zip');
      final capturing = engine.backup(archive.path);
      expect(
        () => engine.addCharacterBookEntry(imported.id, {'content': 'too late'}),
        throwsA(isA<TavernModelException>().having((error) => error.kind, 'kind', TavernFailure.busy)),
      );
      await editing;
      await capturing;
      final sourceCard = await File('${root.path}/characters/${imported.id}/card.json').readAsBytes();
      final report = (await engine.readImportReport(TavernImportKind.character, imported.id))!;
      expect(report.stale, isTrue);
      expect(await File('${root.path}/$reportPath').readAsBytes(), orderedEquals(reportBefore));
      final target = Directory('${work.path}/restored');
      await restoreTavernDirectory(archive.path, target.path);
      final opened = await _openWithoutModel(target, importedAt);
      restored = opened;
      final detail = (await opened.character(imported.id))!;
      expect(detail.theme, theme);
      expect(detail.assets.map((asset) => asset.uri), ['ccdefault:', '__asset:assets/smile.png']);
      expect(detail.assets.map((asset) => asset.localPath), [
        '${target.absolute.path}/characters/${imported.id}/source.png',
        '${target.absolute.path}/characters/${imported.id}/resources/assets/smile.png',
      ]);
      expect(await File(detail.assets[0].localPath!).readAsBytes(), orderedEquals(png));
      expect(await File(detail.assets[1].localPath!).readAsBytes(), orderedEquals(payload));
      expect(detail.avatarPath, '${target.path}/characters/${imported.id}/portrait.png');
      expect(detail.assets[0].localPath, isNot(detail.avatarPath));
      expect(await File('${target.path}/characters/${imported.id}/card.json').readAsBytes(), orderedEquals(sourceCard));
      expect(await File('${target.path}/$reportPath').readAsBytes(), orderedEquals(reportBefore));
      expect((await opened.readImportReport(TavernImportKind.character, imported.id))!.toJson(), report.toJson());
      final book = (await opened.characterFields(imported.id))!['character_book']! as Map<String, Object?>;
      expect((book['entries']! as List<Object?>).single, containsPair('content', 'captured book'));
      expect((await opened.watchCharacters().first).single.assets, isEmpty);
    } finally {
      await restored?.close();
      await engine.close();
      await work.delete(recursive: true);
    }
  });
}

Future<TavernEngine> _openWithoutModel(Directory directory, DateTime at) => TavernEngine.openDirectory(
  directory,
  config: TavernModelConfig(apiKey: () async => 'fixture', model: 'fixture'),
  modelClient: TavernModelClient(clientFactory: () => throw StateError('Appearance must not call the model')),
  clock: () => at,
);

Map<String, Object?> _document() =>
    jsonDecode(File('test/fixtures/card-v3.json').readAsStringSync()) as Map<String, Object?>;
Map<String, Object?> _data(Map<String, Object?> json) => json['data']! as Map<String, Object?>;
Uint8List _bytes(Map<String, Object?> json) => Uint8List.fromList(utf8.encode(jsonEncode(json)));
Uint8List _png(int width, int height) => Uint8List.fromList(image.encodePng(image.Image(width: width, height: height)));
Uint8List _charx(Map<String, Object?> json, Map<String, Uint8List> payloads) {
  final archive = Archive()..addFile(ArchiveFile.string('card.json', jsonEncode(json)));
  for (final entry in payloads.entries) {
    archive.addFile(ArchiveFile(entry.key, entry.value.length, entry.value));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

List<Map<String, Object?>> _assets(TavernCharacter character) => [
  for (final asset in character.assets)
    {'type': asset.type, 'name': asset.name, 'uri': asset.uri, 'ext': asset.ext, 'localPath': asset.localPath},
];

Future<Map<String, String>> _files(Directory directory, {bool includeCard = true}) async {
  final result = <String, String>{};
  await for (final entity in directory.list(recursive: true, followLinks: false)) {
    if (entity is File && (includeCard || entity.uri.pathSegments.last != 'card.json')) {
      result[entity.path] = base64Encode(await entity.readAsBytes());
    }
  }
  return result;
}

// PNG fixture insertion uses archive's CRC implementation, not the codec's
// private chunk helpers. The original chunks are copied byte-for-byte.
Uint8List _insertText(Uint8List png, String keyword, String text) {
  final payload = [...latin1.encode(keyword), 0, ...latin1.encode(text)];
  final chunk = Uint8List(payload.length + 12);
  final data = ByteData.sublistView(chunk)..setUint32(0, payload.length);
  chunk.setRange(4, 8, ascii.encode('tEXt'));
  chunk.setRange(8, 8 + payload.length, payload);
  data.setUint32(chunk.length - 4, getCrc32(chunk.sublist(4, chunk.length - 4)));
  final out = BytesBuilder()..add(png.sublist(0, 8));
  final original = ByteData.sublistView(png);
  for (var offset = 8; offset < png.length;) {
    final length = original.getUint32(offset);
    final type = ascii.decode(png.sublist(offset + 4, offset + 8));
    if (type == 'IEND') {
      out.add(chunk);
    }
    out.add(png.sublist(offset, offset + length + 12));
    offset += length + 12;
  }
  return out.takeBytes();
}

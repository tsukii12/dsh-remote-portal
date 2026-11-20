import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:test/test.dart';

final _at = DateTime.utc(2026, 11, 11, 5);
const _nameA = 'source A 海🌊';
const _nameB = 'source B 海🌊';

void main() {
  late Directory root;
  late CharacterLibrary library;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('dsh-t12-card-origin-');
    library = CharacterLibrary(root, now: () => _at);
  });

  tearDown(() async {
    await root.delete(recursive: true);
  });

  test('a parsed import cannot return one original and reload a reused caller buffer', () async {
    final original = await _jsonCard(_nameA);
    final replacement = await _jsonCard(_nameB);
    expect(replacement.length, original.length);
    expect(const CardCodec().decode(original).name, _nameA);
    expect(const CardCodec().decode(replacement).name, _nameB);
    final input = Uint8List.fromList(original);
    final imported = await library.importCard(
      input,
      beforeSave: (card) async {
        // The public callback establishes that this import has already chosen A.
        // Only the caller's outer input is reused; the parsed card is untouched.
        expect(card.name, _nameA);
        expect(card.originalBytes, orderedEquals(original));
        input.setAll(0, replacement);
        expect(card.originalBytes, orderedEquals(original));
      },
    );
    expect(input, orderedEquals(replacement));
    expect(imported.card.name, _nameA);
    final reopened = CharacterLibrary(root, now: () => _at);
    final reloaded = (await reopened.read(imported.id))!;

    // First defect-specific oracle: both implementations have parsed A and
    // published a readable card. The old writer reloads source B instead.
    expect(
      {
        'returnedSource': const CardCodec().decode(imported.card.originalBytes!).name,
        'reloadedSource': const CardCodec().decode(reloaded.card.originalBytes!).name,
      },
      {'returnedSource': _nameA, 'reloadedSource': _nameA},
    );

    expect(imported.card.originalBytes, orderedEquals(original));
    expect(reloaded.card.originalBytes, orderedEquals(original));
    expect(reloaded.card.json, imported.card.json);
    expect(reloaded.card.name, _nameA);
    expect(await File('${root.path}/characters/${imported.id}/original.json').readAsBytes(), orderedEquals(original));
    expect((await reopened.list()).map((card) => card.name), [_nameA]);
    for (final format in [TavernCardFormat.json, TavernCardFormat.charx]) {
      final exported = const CardCodec().decode(await reopened.exportCard(imported.id, format: format));
      expect(exported.name, _nameA);
      expect(exported.json['unknown_root'], imported.card.json['unknown_root']);
    }

    // Reusing B for a later independent import still creates B normally.
    final later = await reopened.importCard(input);
    expect(later.id, isNot(imported.id));
    expect(later.card.name, _nameB);
    expect((await reopened.read(later.id))!.card.originalBytes, orderedEquals(replacement));
    expect((await reopened.read(imported.id))!.card.originalBytes, orderedEquals(original));
    expect((await reopened.list()).map((card) => card.name), unorderedEquals([_nameA, _nameB]));
  });

  test('PNG and CHARX imports keep their decoded originals when the outer bytes are cleared', () async {
    for (final (fixture, format) in [
      ('card-both.png', TavernCardFormat.png),
      ('card-assets.charx', TavernCardFormat.charx),
    ]) {
      final original = await File('test/fixtures/$fixture').readAsBytes();
      final input = Uint8List.fromList(original);
      final parsed = const CardCodec().decode(original);
      expect(parsed.sourceFormat, format);
      final imported = await library.importCard(
        input,
        beforeSave: (card) async {
          expect(card.json, parsed.json);
          expect(card.originalBytes, orderedEquals(original));
          input.fillRange(0, input.length, 0);
          expect(card.originalBytes, orderedEquals(original));
        },
      );
      expect(input.every((byte) => byte == 0), isTrue);
      final reopened = CharacterLibrary(root, now: () => _at);
      final reloaded = (await reopened.read(imported.id))!;
      expect(reloaded.card.originalBytes, orderedEquals(original), reason: fixture);
      expect(reloaded.card.json, imported.card.json);
      expect(reloaded.card.sourceFormat, format);
      expect(reloaded.card.assets, imported.card.assets);
      expect(reloaded.card.png, imported.card.png);
      expect(
        await File('${root.path}/characters/${imported.id}/original.${format.name}').readAsBytes(),
        orderedEquals(original),
      );
      final exported = const CardCodec().decode(await reopened.exportCard(imported.id, format: format));
      expect(exported.name, imported.card.name);
      // The source byte carrier differs from the ordinary rebuilt export.
      // This test does not expect either old exporter to fail or change names.
    }
    expect(await library.list(), hasLength(2));
  });
}

Future<Uint8List> _jsonCard(String name) async {
  final json = jsonDecode(await File('test/fixtures/card-v3.json').readAsString()) as Map<String, Object?>;
  (json['data']! as Map<String, Object?>)['name'] = name;
  return Uint8List.fromList(utf8.encode(jsonEncode(json)));
}

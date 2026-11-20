import 'dart:convert';
import 'dart:typed_data';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:test/test.dart';

import 'support/t24_engine_harness.dart';

void main() {
  test('public world info preview retains NEL in literal keys and scan text', () async {
    final h = await _open();
    await h.engine.addCharacterBookEntry(h.characterId, _entry(['\u0085KEY'], 'NEL_MARKER'));

    // Both versions must reach the same literal match before the defect oracle.
    final same = await _preview(h, '\u0085KEY');
    expect(_contents(same), ['NEL_MARKER']);
    expect(same.single['primaryKey'], '\u0085KEY');
    expect(same.single['reason'], 'keywords');
    expect(same.single['source'], 'character');
    expect(same.single['bookId'], '${h.characterId}:card');
    expect(same.single['phase'], 'initial');

    final plain = await _preview(h, 'KEY');
    // Old VM trim removes NEL from the key and incorrectly returns the marker.
    expect(_contents(plain), isEmpty);

    final fields = (await h.engine.characterFields(h.characterId))!;
    final book = fields['character_book']! as Map<String, Object?>;
    final entries = book['entries']! as List<Object?>;
    expect((entries.single! as Map<String, Object?>)['keys'], ['\u0085KEY']);
    await h.reopen();
    expect(_contents(await _preview(h, 'KEY')), isEmpty);
    expect(_contents(await _preview(h, '\u0085KEY')), ['NEL_MARKER']);
  });

  test('public secondary-key gates retain NEL for positive and negative logic', () async {
    final h = await _open();
    await h.engine.addCharacterBookEntry(h.characterId, _entry(['KEY'], 'SECONDARY_MARKER', secondary: ['\u0085GATE']));

    final same = await _preview(h, 'KEY \u0085GATE');
    expect(_contents(same), ['SECONDARY_MARKER']);
    expect(same.single['secondaryMatches'], ['\u0085GATE']);
    expect(_contents(await _preview(h, 'KEY GATE')), isEmpty);

    await h.engine.updateCharacterBookEntry(h.characterId, 0, {
      'extensions': {'selectiveLogic': 2}, // NOT_ANY.
    });
    final absent = await _preview(h, 'KEY GATE');
    expect(_contents(absent), ['SECONDARY_MARKER']);
    expect(absent.single['secondaryMatches'], isEmpty);
    expect(_contents(await _preview(h, 'KEY \u0085GATE')), isEmpty);
  });

  test('normal JS whitespace still trims keys and scan text before anchored matching', () async {
    final h = await _open();
    const key = '\u00a0\ufeff/^\\x01KEY\$/\ufeff\u00a0';
    await h.engine.addCharacterBookEntry(h.characterId, _entry([key], 'ANCHORED_MARKER'));

    // The real native regex sees the scan buffer's U+0001 prefix. Anchors make
    // the input-side whitespace handling observable, beyond substring matching.
    final padded = await _preview(h, '\u00a0\ufeffKEY\ufeff\u00a0');
    expect(_contents(padded), ['ANCHORED_MARKER']);
    expect(padded.single['primaryKey'], key);
    expect(_contents(await _preview(h, 'KEY')), ['ANCHORED_MARKER']);
    expect(_contents(await _preview(h, 'XKEY')), isEmpty);
    expect(_contents(await _preview(h, '\u0085KEY')), isEmpty);
  });

  test('public intake keeps NEL regex lookalikes literal and checks JS-spaced regexes', () async {
    final h = await _open();
    const key = '\u0085/[/\u0085';
    final raw = jsonDecode(utf8.decode(t24Card())) as Map<String, Object?>;
    (raw['data']! as Map<String, Object?>)['character_book'] = {
      'entries': [
        _entry([key], 'LITERAL_MARKER'),
      ],
    };
    final imported = await h.engine.importCard(Uint8List.fromList(utf8.encode(jsonEncode(raw))));
    expect(imported.regexDiagnostics, isEmpty);
    final report = (await h.engine.readImportReport(TavernImportKind.character, imported.id))!;
    expect(report.verdict, TavernImportVerdict.usable);
    expect(report.counts['regexChecks'] ?? 0, 0);
    expect(_contents(await _preview(h, key, characterId: imported.id)), ['LITERAL_MARKER']);
    final checked = await h.engine.recheckImport(TavernImportKind.character, imported.id);
    expect(checked.verdict, TavernImportVerdict.usable);
    expect(checked.counts['regexChecks'] ?? 0, 0);

    // NBSP/BOM still reveal the same invalid native regex to static inspection.
    await h.engine.updateCharacterBookEntry(imported.id, 0, {
      'keys': ['\u00a0/[/\ufeff'],
    });
    final invalid = await h.engine.recheckImport(TavernImportKind.character, imported.id);
    expect(invalid.verdict, TavernImportVerdict.partial);
    expect(invalid.counts['regexIncompatible'], 1);
    expect(
      invalid.findings.any(
        (finding) =>
            finding.path == r'$.data.character_book.entries[0].keys[0]' &&
            finding.kind == TavernImportFindingKind.invalid,
      ),
      isTrue,
    );
  });
}

Future<T24Harness> _open() async {
  final h = await T24Harness.open();
  addTearDown(h.dispose);
  await h.engine.setSettings({
    'worldInfo': {
      'world_info_depth': 1,
      'world_info_budget': 50,
      'world_info_include_names': false,
      'world_info_recursive': false,
      'world_info_case_sensitive': true,
      'world_info_match_whole_words': false,
    },
  });
  return h;
}

Map<String, Object?> _entry(List<String> keys, String content, {List<String> secondary = const []}) => {
  'keys': keys,
  'secondary_keys': secondary,
  'content': content,
  'enabled': true,
  'constant': false,
  'selective': secondary.isNotEmpty,
  'use_regex': false,
  'case_sensitive': true,
  'extensions': {'useProbability': false, 'match_whole_words': false, 'selectiveLogic': 0},
};

Future<List<Map<String, Object?>>> _preview(T24Harness h, String text, {String? characterId}) async {
  final value = await h.engine.previewCharacterBook(characterId ?? h.characterId, text);
  expect(value['scope'], 'character-book');
  expect(value['stage'], 'world-info');
  expect(value['chatId'], isNull);
  expect(value['contextNodeId'], isNull);
  expect(value['overflowed'], isFalse);
  expect(value['budget'], greaterThan(0));
  expect(value['regexDiagnostics'] ?? const [], isEmpty);
  expect(h.model.generated, 0);
  return (value['activated']! as List<Object?>).cast<Map<String, Object?>>();
}

List<Object?> _contents(List<Map<String, Object?>> hits) => [for (final hit in hits) hit['content']];

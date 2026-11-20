import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:dsh_tavern/src/io/gameplay_pack_codec.dart';
import 'package:test/test.dart';

import 'p2_script_test_support.dart';

final _at = DateTime.utc(2026, 11, 14, 8);

void main() {
  test('draft export preserves selected candidates and native diagnostics without adoption', () async {
    final h = await ScriptFixture.open();
    final dshgo = <String, Object?>{
      'v': 1,
      'state': {
        'schema': {
          'type': 'object',
          'properties': {
            'count': {'type': 'integer', 'minimum': 0, 'maximum': 4},
          },
        },
        'initial': {'count': 1},
      },
      'future': {
        'nullable': null,
        'values': [1, 'untouched'],
      },
    };
    final raw = _card(dshgo);
    final data = scriptMap(raw['data']);
    data['character_book'] = {
      'name': 'Embedded source',
      'vendor': {'opaque': true},
      'entries': [
        {
          'id': 7,
          'keys': ['source'],
          'content': 'BOOK',
          'enabled': true,
          'insertion_order': 0,
          'extensions': <String, Object?>{},
        },
      ],
    };
    scriptMap(data['extensions'])['regex_scripts'] = [
      {
        'id': 'original-rule',
        'scriptName': 'Native regex',
        'findRegex': '/source/g',
        'replaceString': 'result',
        'placement': [1],
        'disabled': false,
        'promptOnly': true,
        'vendor': {'keep': null},
      },
    ];
    final character = await h.engine.importCard(_jsonBytes(raw));
    final target = TavernAuthoringTarget(kind: TavernAuthoringTargetKind.character, id: character.id);
    final captured = await h.engine.createAuthoringDraft([target]);
    final draft = await h.engine.editAuthoringDraft(
      captured.id,
      draftRevision: captured.draftRevision,
      changes: [
        TavernAuthoringChange(
          id: 'schema',
          physicalResourceId: target.physicalResourceId,
          path: '/data/extensions/dshgo/state/schema/properties/count/maximum',
          operation: TavernAuthoringChangeKind.set,
          value: 9,
        ),
        TavernAuthoringChange(
          id: 'regex',
          physicalResourceId: target.physicalResourceId,
          path: '/data/extensions/regex_scripts/0/findRegex',
          operation: TavernAuthoringChangeKind.set,
          value: '/[/g',
          dependsOn: const ['schema'],
        ),
      ],
    );
    final resources = [
      TavernGameplayDraftResource.json(
        physicalResourceId: target.physicalResourceId,
        pointer: '/data/character_book',
        localId: 'book',
        kind: 'lorebook',
        path: 'books/selected.json',
        entries: const [TavernGameplayExportEntry(localId: 'entry', pointer: '/entries/0')],
      ),
      TavernGameplayDraftResource.json(
        physicalResourceId: target.physicalResourceId,
        pointer: '/data/extensions/regex_scripts',
        localId: '\uFEFFrules',
        kind: 'regex',
        path: 'regex/selected.json',
        entries: const [TavernGameplayExportEntry(localId: '\uFEFFrule', pointer: '/0')],
      ),
    ];
    const references = [
      {
        'vendor_note': 'preserved-unresolved',
        'future': {'nullable': null},
      },
    ];
    final request = _request(
      draft,
      resources,
      changeIds: const ['schema', 'regex'],
      schemaRoots: const ['/count'],
      references: references,
    );
    final file = File('${h.root.path}/characters/${character.id}/card.json');
    final originalFile = await file.readAsBytes();
    final savedData = scriptMap(scriptMap(jsonDecode(utf8.decode(originalFile)))['data']);
    final savedBook = scriptMap(savedData['character_book']);
    expect(scriptMap(captured.sources.single.base['data'])['character_book'], savedBook);
    expect(scriptMap((savedBook['entries']! as List<Object?>).single)['use_regex'], isFalse);
    final before = _rows(h);
    final preview = await h.engine.previewGameplayExport(request);
    expect(preview.issues.where((issue) => issue['blocking'] == true), isEmpty);
    expect(preview.mergedRaw['packId'], '\uFEFFdraft-export');
    expect(preview.mergedRaw['references'], references);
    expect(preview.mergedRaw['vendor'], {
      'complete': [null, 'preserved'],
    });
    final exportedDshgo = scriptMap(preview.mergedRaw['dshgo']);
    expect(exportedDshgo['future'], dshgo['future']);
    expect(preview.mergedRaw['schemaPatches'], [
      {
        'path': '/count',
        'node': {'type': 'integer', 'minimum': 0, 'maximum': 9},
      },
    ]);
    final regexMapping = preview.resourceMappings.singleWhere((row) => row['localId'] == '\uFEFFrules');
    final diagnostics = (scriptMap(regexMapping['inspection'])['regexDiagnostics']! as List<Object?>)
        .map(scriptMap)
        .toList();
    expect(diagnostics.single['status'], 'incompatible');
    expect(diagnostics.single['path'], r'$[0].findRegex');

    final bytes = await h.engine.exportGameplayPackFromDraft(request, expectedPreviewId: preview.previewId);
    final repeated = await h.engine.exportGameplayPackFromDraft(request, expectedPreviewId: preview.previewId);
    expect(repeated, bytes, reason: 'The supplied instant also fixes the new ZIP entry timestamps.');
    final pack = decodeGameplayPack(bytes);
    expect(pack.manifest, preview.mergedRaw);
    expect(pack.files.keys.toSet(), {'pack.json', 'books/selected.json', 'regex/selected.json'});
    expect(jsonDecode(utf8.decode(pack.files['books/selected.json']!)), savedBook);
    final scripts = jsonDecode(utf8.decode(pack.files['regex/selected.json']!)) as List<Object?>;
    expect(scriptMap(scripts.single)['findRegex'], '/[/g');
    expect(scriptMap(scripts.single)['vendor'], {'keep': null});
    expect(_rows(h), before);
    expect(await file.readAsBytes(), originalFile);

    await expectLater(
      h.engine.previewGameplayExport(
        _request(draft, resources, changeIds: const ['regex'], schemaRoots: const ['/count']),
      ),
      throwsA(_authoringError('missing_dependency')),
    );
    final missingRoot = await h.engine.previewGameplayExport(
      _request(draft, resources, changeIds: const ['schema', 'regex'], schemaRoots: const ['/absent']),
    );
    expect(
      missingRoot.issues.any((issue) => issue['code'] == 'export_schema_root' && issue['blocking'] == true),
      isTrue,
    );
    expect(missingRoot.mergedRaw['schemaPatches'], isEmpty);
    final bomPath = _request(
      draft,
      [
        TavernGameplayDraftResource.json(
          physicalResourceId: target.physicalResourceId,
          pointer: '/data/extensions/regex_scripts',
          localId: 'rules',
          kind: 'regex',
          path: '\uFEFFrules.json',
          entries: const [TavernGameplayExportEntry(localId: 'rule', pointer: '/0')],
        ),
      ],
      changeIds: const ['schema', 'regex'],
      schemaRoots: const ['/count'],
    );
    final blocked = await h.engine.previewGameplayExport(bomPath);
    expect(
      blocked.issues.any(
        (issue) =>
            issue['code'] == 'export_resource_path' && issue['path'] == '\uFEFFrules.json' && issue['blocking'] == true,
      ),
      isTrue,
    );
    await expectLater(
      h.engine.exportGameplayPackFromDraft(bomPath, expectedPreviewId: blocked.previewId),
      throwsA(_packError('export_conflict')),
    );
    expect(_rows(h), before);

    final changed = await h.engine.editAuthoringDraft(
      draft.id,
      draftRevision: draft.draftRevision,
      changes: [
        TavernAuthoringChange(
          id: 'schema',
          physicalResourceId: target.physicalResourceId,
          path: '/data/extensions/dshgo/state/schema/properties/count/maximum',
          operation: TavernAuthoringChangeKind.set,
          value: 11,
        ),
        draft.changes.last,
      ],
    );
    final changedRows = _rows(h);
    await expectLater(
      h.engine.exportGameplayPackFromDraft(
        _request(
          changed,
          resources,
          changeIds: const ['schema', 'regex'],
          schemaRoots: const ['/count'],
          references: references,
        ),
        expectedPreviewId: preview.previewId,
      ),
      throwsA(_packError('export_preview_conflict')),
    );
    expect(_rows(h), changedRows);
    expect(await file.readAsBytes(), originalFile);
    h.expectNoGeneration();
  });

  test('draft media is explicit seed bytes or a current source matching the saved authority', () async {
    final h = await ScriptFixture.open();
    final raw = _card({
      'v': 1,
      'future': {
        'opaque': [null, 'seed'],
      },
    });
    final data = scriptMap(raw['data']);
    data['assets'] = [
      {'type': 'other', 'name': 'payload', 'ext': 'bin', 'uri': 'embeded://assets/payload.bin'},
    ];
    final rawText = '\uFEFF${const JsonEncoder.withIndent('  ').convert(raw)}\n';
    final payload = Uint8List.fromList([0, 1, 127, 254, 255]);
    final archive = Archive()
      ..addFile(ArchiveFile.string('card.json', rawText))
      ..addFile(ArchiveFile('assets/payload.bin', payload.length, payload));
    final charx = Uint8List.fromList(ZipEncoder().encode(archive, modified: _at));
    final seed = await h.engine.createAuthoringSeed(
      TavernAuthoringSeedInput(kind: TavernAuthoringTargetKind.character, bytes: charx, fileName: 'source.charx'),
    );
    expect(seed.sources.single.origin, TavernAuthoringSourceOrigin.seed);
    final seedId = seed.sources.single.physicalResourceId;
    final selections = [
      TavernGameplayDraftResource.json(
        physicalResourceId: seedId,
        pointer: '',
        localId: 'complete-card',
        kind: 'castCard',
        path: 'cards/source.json',
      ),
      TavernGameplayDraftResource.asset(
        physicalResourceId: seedId,
        assetUri: 'embeded://assets/payload.bin',
        media: TavernAuthoringMediaSelection.seedCaptured,
        localId: 'payload',
        path: 'assets/copied.bin',
      ),
    ];
    final request = _request(seed, selections);
    final beforeSeed = _rows(h);
    final preview = await h.engine.previewGameplayExport(request);
    expect(preview.issues.where((issue) => issue['blocking'] == true), isEmpty);
    final bytes = await h.engine.exportGameplayPackFromDraft(request, expectedPreviewId: preview.previewId);
    final decoded = decodeGameplayPack(bytes);
    expect(
      decoded.files['cards/source.json'],
      utf8.encode(rawText),
      reason: 'The complete unchanged seed keeps its original BOM, whitespace and unknown JSON.',
    );
    expect(decoded.files['assets/copied.bin'], payload);
    expect(decoded.manifest['dshgo'], scriptMap(data['extensions'])['dshgo']);
    expect(_rows(h), beforeSeed);

    final none = _request(seed, [
      TavernGameplayDraftResource.asset(
        physicalResourceId: seedId,
        assetUri: 'embeded://assets/payload.bin',
        media: TavernAuthoringMediaSelection.none,
        localId: 'payload',
        path: 'assets/copied.bin',
      ),
    ]);
    final noMedia = await h.engine.previewGameplayExport(none);
    expect(noMedia.issues.any((issue) => issue['code'] == 'export_media_source' && issue['blocking'] == true), isTrue);
    await expectLater(
      h.engine.exportGameplayPackFromDraft(none, expectedPreviewId: noMedia.previewId),
      throwsA(_packError('export_conflict')),
    );
    expect(_rows(h), beforeSeed);

    final character = await h.engine.importCard(charx, fileName: 'source.charx');
    final current = await h.engine.createAuthoringDraft([
      TavernAuthoringTarget(kind: TavernAuthoringTargetKind.character, id: character.id),
    ]);
    final currentRequest = _request(current, [
      TavernGameplayDraftResource.asset(
        physicalResourceId: current.sources.single.physicalResourceId,
        assetUri: 'embeded://assets/payload.bin',
        media: TavernAuthoringMediaSelection.currentSource,
        localId: 'payload',
        path: 'assets/copied.bin',
      ),
    ]);
    final beforeCurrent = _rows(h);
    final currentPreview = await h.engine.previewGameplayExport(currentRequest);
    expect(currentPreview.issues.where((issue) => issue['blocking'] == true), isEmpty);
    final currentBytes = await h.engine.exportGameplayPackFromDraft(
      currentRequest,
      expectedPreviewId: currentPreview.previewId,
    );
    expect(decodeGameplayPack(currentBytes).files['assets/copied.bin'], payload);
    expect(_rows(h), beforeCurrent);

    await h.engine.updateCharacterFields(character.id, {'description': 'changed after draft capture'});
    final changedRows = _rows(h);
    await expectLater(
      h.engine.exportGameplayPackFromDraft(currentRequest, expectedPreviewId: currentPreview.previewId),
      throwsA(_authoringError('authority_conflict')),
    );
    expect(_rows(h), changedRows);
    h.expectNoGeneration();
  });
}

TavernGameplayExportRequest _request(
  TavernAuthoringDraft draft,
  List<TavernGameplayDraftResource> resources, {
  List<String> changeIds = const [],
  List<String> schemaRoots = const [],
  List<Map<String, Object?>> references = const [],
}) => TavernGameplayExportRequest.packFromDraft(
  draftId: draft.id,
  draftRevision: draft.draftRevision,
  physicalResourceId: draft.sources.single.physicalResourceId,
  changeIds: changeIds,
  packId: '\uFEFFdraft-export',
  packVersion: '1',
  schemaRoots: schemaRoots,
  draftResources: resources,
  at: _at,
  references: references,
  manifestFields: const {
    'vendor': {
      'complete': [null, 'preserved'],
    },
  },
);

Map<String, Object?> _card(Map<String, Object?> dshgo) => {
  'spec': 'chara_card_v3',
  'spec_version': '3.0',
  'vendor': {'keep': true},
  'data': {
    'name': 'Draft export',
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
    'extensions': <String, Object?>{'dshgo': dshgo},
  },
};

Uint8List _jsonBytes(Object? value) => Uint8List.fromList(utf8.encode(jsonEncode(value)));

Map<String, Object?> _rows(ScriptFixture h) => h.inspect(
  (db) => {
    for (final table in const [
      'authoring_drafts',
      'authoring_operations',
      'authoring_resources',
      'gameplay_pack_versions',
      'gameplay_scopes',
      'gameplay_bindings',
      'gameplay_effective_configs',
    ])
      table: [for (final row in db.select('SELECT * FROM $table ORDER BY rowid')) Map<String, Object?>.from(row)],
  },
);

TypeMatcher<TavernGameplayException> _packError(String code) =>
    isA<TavernGameplayException>().having((error) => error.code, 'code', code);

TypeMatcher<TavernAuthoringException> _authoringError(String code) =>
    isA<TavernAuthoringException>().having((error) => error.code, 'code', code);

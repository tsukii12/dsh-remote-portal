import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:test/test.dart';

import 'p2_script_test_support.dart';

typedef Json = Map<String, Object?>;

void main() {
  test('JSON and CHARX exports separate bound identities and keep the selected originals without writes', () async {
    final h = await ScriptFixture.open(allowModel: true);
    final original = _originalCard();
    final baseAsset = utf8.encode('BASE-ASSET');
    final originalArchive = _zip({
      'card.json': utf8.encode(jsonEncode(original)),
      'shared.bin': baseAsset,
      'unknown-local.bin': utf8.encode('LOCAL-UNKNOWN'),
    });
    final character = (await h.engine.importCard(originalArchive)).id;
    final one = await _install(h, 'export-one', 'ASSET-ONE');
    final two = await _install(h, 'export-two', 'ASSET-TWO');
    const scope = TavernPackScopeTarget(kind: TavernGameplayScope.global);
    final initial = await h.engine.readGameplayBindings(scope);
    final bound = await h.engine.updateGameplayBindings(
      scope,
      expected: initial.token,
      operationId: 'bind-export-pair',
      edits: [
        TavernPackBindingEdit.create(clientKey: 'one', packRef: one),
        TavernPackBindingEdit.create(clientKey: 'two', packRef: two),
      ],
    );
    final bindings = [bound.createdBindings['one']!, bound.createdBindings['two']!];
    final chat = await h.engine.createChat(character);
    await h.engine.putLorebook('ambient', {
      'entries': {
        'only': {
          'uid': 99,
          'key': ['NOT_PRESENT'],
          'content': 'AMBIENT-WORLD',
          'position': 0,
        },
      },
    });
    await h.engine.bindLorebooks(['ambient'], source: WorldInfoSource.global);
    await h.engine.setSettings({
      'globalRegexScripts': [
        {
          'id': 'ambient-regex',
          'scriptName': 'Ambient',
          'findRegex': '/NOT_PRESENT/g',
          'replaceString': 'AMBIENT-REGEX',
          'placement': [RegexPlacement.userInput],
          'disabled': true,
        },
      ],
    });
    final reply = h.reply('actual branch');
    final turn = await h.engine.send(chat, 'begin').toList();
    expect(turn.whereType<TavernTurnFailed>(), isEmpty);
    expect(turn.whereType<TavernTurnDone>(), hasLength(1));
    await reply.seen.future;
    final saved = await _saved(h.engine, chat);
    final runtime = _map(_map(saved['dshgoPackRuntime'])['bindings']);
    for (final id in bindings) {
      expect(_map(runtime[id])['rules'], ['shared-rule']);
    }

    final sourceCard = _map(jsonDecode(await File('${h.root.path}/characters/$character/card.json').readAsString()));
    final context = TavernGameplayContext(characterId: character, chatId: chat);
    final resources = [
      for (final binding in bindings)
        for (final local in ['lore', 'regex', 'asset'])
          TavernGameplayPackResourceRef(bindingId: binding, localId: local),
    ];
    final at = DateTime.utc(2026, 11, 14, 12, 34, 56);
    TavernGameplayExportRequest request(TavernCardFormat format) => TavernGameplayExportRequest.character(
      context: context,
      format: format,
      at: at,
      packResources: resources,
      copyCardMedia: true,
    );
    final originalPacks = [
      await h.engine.exportInstalledGameplayPack(one),
      await h.engine.exportInstalledGameplayPack(two),
    ];
    final rows = _rows(h);
    final files = await _files(h);
    final requests = h.requests.length;
    final keyReads = h.keyReads;

    final jsonPreview = await h.engine.previewGameplayExport(request(TavernCardFormat.json));
    expect(jsonPreview.issues.where((issue) => issue['blocking'] == true), isEmpty);
    _checkMerged(jsonPreview.mergedRaw, jsonPreview, sourceCard, bindings);
    expect(jsonEncode(jsonPreview.sources), contains('PACK-BOOK-UNKNOWN'));
    final jsonBytes = await h.engine.exportCharacterWithPacks(
      request(TavernCardFormat.json),
      expectedPreviewId: jsonPreview.previewId,
    );
    final jsonRaw = _map(jsonDecode(utf8.decode(jsonBytes)));
    _checkMerged(jsonRaw, jsonPreview, sourceCard, bindings);
    expect(_map(jsonRaw['data'])['modification_date'], at.millisecondsSinceEpoch ~/ 1000);
    final jsonCard = const CardCodec().decode(jsonBytes);
    expect(_assetContents(jsonCard), ['BASE-ASSET']);
    _checkAssets(jsonCard, jsonPreview, bindings, charx: false);

    // Format belongs to the complete export intent even though the effective
    // gameplay configuration and all source versions are unchanged.
    await expectLater(
      h.engine.exportCharacterWithPacks(request(TavernCardFormat.charx), expectedPreviewId: jsonPreview.previewId),
      throwsA(_error('export_preview_conflict')),
    );
    final charxPreview = await h.engine.previewGameplayExport(request(TavernCardFormat.charx));
    expect(charxPreview.issues.where((issue) => issue['blocking'] == true), isEmpty);
    final charxBytes = await h.engine.exportCharacterWithPacks(
      request(TavernCardFormat.charx),
      expectedPreviewId: charxPreview.previewId,
    );
    final archive = ZipDecoder().decodeBytes(charxBytes, verify: true);
    final cardFile = [
      for (final file in archive)
        if (file.name == 'card.json') file,
    ].single;
    final charxRaw = _map(jsonDecode(utf8.decode(cardFile.readBytes()!)));
    _checkMerged(charxRaw, charxPreview, sourceCard, bindings);
    final charx = const CardCodec().decode(charxBytes);
    expect(_assetContents(charx), ['BASE-ASSET']);
    _checkAssets(charx, charxPreview, bindings, charx: true);
    expect(charx.assets['shared.bin'], baseAsset);
    expect(charx.assets['unknown-local.bin'], utf8.encode('LOCAL-UNKNOWN'));
    expect(
      charx.assets.values.map((bytes) => utf8.decode(bytes, allowMalformed: true)),
      isNot(contains('PACK-UNSELECTED')),
    );
    expect(_rows(h), rows);
    expect(await _files(h), files);
    expect(await _saved(h.engine, chat), saved);
    expect(await h.engine.exportInstalledGameplayPack(one), originalPacks[0]);
    expect(await h.engine.exportInstalledGameplayPack(two), originalPacks[1]);
    expect(h.requests, hasLength(requests));
    expect(h.keyReads, keyReads);
  });

  test('required assets, real scope changes and unrepresentable WI prevent stale or incomplete export', () async {
    final h = await ScriptFixture.open();
    final character = await h.card(
      'Export conflicts',
      greeting: 'opening',
      extensions: {
        'dshgo': {
          'v': 1,
          'state': {
            'schema': {
              'type': 'object',
              'required': ['n'],
              'properties': {
                'n': {'type': 'integer'},
              },
            },
            'init': {'n': 0},
          },
        },
      },
    );
    final chat = await h.engine.createChat(character);
    final pack = await _install(h, 'export-conflicts', 'REQUIRED-ASSET', incompatibleWorld: true);
    final scope = TavernPackScopeTarget(kind: TavernGameplayScope.character, targetId: character);
    final initial = await h.engine.readGameplayBindings(scope);
    final bound = await h.engine.updateGameplayBindings(
      scope,
      expected: initial.token,
      operationId: 'bind-conflicts',
      edits: [TavernPackBindingEdit.create(clientKey: 'pack', packRef: pack)],
    );
    final binding = bound.createdBindings['pack']!;
    TavernGameplayExportRequest request(List<String> locals) => TavernGameplayExportRequest.character(
      context: TavernGameplayContext(characterId: character, chatId: chat),
      format: TavernCardFormat.json,
      at: DateTime.utc(2026, 11, 14),
      packResources: [for (final local in locals) TavernGameplayPackResourceRef(bindingId: binding, localId: local)],
      copyCardMedia: false,
    );
    final before = _rows(h);
    final files = await _files(h);
    final missing = await h.engine.previewGameplayExport(request(const []));
    expect(missing.issues.any((issue) => issue['blocking'] == true), isTrue);
    await expectLater(
      h.engine.exportCharacterWithPacks(request(const []), expectedPreviewId: missing.previewId),
      throwsA(_error('export_conflict')),
    );
    expect(_rows(h), before);
    expect(await _files(h), files);

    final selected = request(['asset']);
    final good = await h.engine.previewGameplayExport(selected);
    expect(good.issues.where((issue) => issue['blocking'] == true), isEmpty);
    final disabled = await h.engine.updateGameplayBindings(
      scope,
      expected: bound.snapshot.token,
      operationId: 'disable-after-preview',
      edits: [TavernPackBindingEdit.setEnabled(bindingId: binding, enabled: false)],
    );
    final afterDisable = _rows(h);
    await expectLater(
      h.engine.exportCharacterWithPacks(selected, expectedPreviewId: good.previewId),
      throwsA(_error('export_preview_conflict')),
    );
    expect(_rows(h), afterDisable);
    await h.engine.updateGameplayBindings(
      scope,
      expected: disabled.snapshot.token,
      operationId: 'enable-for-wi-export',
      edits: [TavernPackBindingEdit.setEnabled(bindingId: binding, enabled: true)],
    );
    final beforeWorld = _rows(h);
    final withWorld = request(['asset', 'lore']);
    final world = await h.engine.previewGameplayExport(withWorld);
    expect(world.issues.any((issue) => issue['blocking'] == true), isTrue);
    await expectLater(
      h.engine.exportCharacterWithPacks(withWorld, expectedPreviewId: world.previewId),
      throwsA(_error('export_conflict')),
    );
    expect(_rows(h), beforeWorld);
    expect(await _files(h), files);

    final componentPack = (await h.engine.importGameplayPack(
      _zip({
        'pack.json': utf8.encode(
          jsonEncode({
            'formatVersion': 1,
            'packId': 'export-unreferenced-component',
            'packVersion': 'one',
            'dshgo': {
              'v': 1,
              'components': {
                'custom': [
                  {'id': 'panel', 'unknown': 'COMPONENT-UNKNOWN'},
                ],
                'enabled': ['panel'],
              },
              'director': {
                'eventRules': {
                  'v': 1,
                  'rules': [
                    {'id': '', 'name': 'x', 'when': true, 'do': []},
                    {'id': 'other', 'name': '', 'when': true, 'do': []},
                  ],
                },
              },
            },
            'resources': [],
          }),
        ),
      }),
    )).ref;
    final componentScope = await h.engine.readGameplayBindings(scope);
    await h.engine.updateGameplayBindings(
      scope,
      expected: componentScope.token,
      operationId: 'bind-unreferenced-component',
      edits: [TavernPackBindingEdit.create(clientKey: 'component', packRef: componentPack)],
    );
    final beforeComponent = _rows(h);
    final componentFiles = await _files(h);
    final componentRequest = request(['asset']);
    final component = await h.engine.previewGameplayExport(componentRequest);
    expect(
      component.issues.any(
        (issue) => issue['code'] == 'export_component_reference_required' && issue['blocking'] == true,
      ),
      isTrue,
    );
    expect(
      component.issues.any((issue) => issue['code'] == 'export_event_handler_conversion' && issue['blocking'] == true),
      isTrue,
    );
    await expectLater(
      h.engine.exportCharacterWithPacks(componentRequest, expectedPreviewId: component.previewId),
      throwsA(_error('export_conflict')),
    );
    expect(_rows(h), beforeComponent);
    expect(await _files(h), componentFiles);
    h.expectNoGeneration();
  });
}

void _checkMerged(Json raw, TavernGameplayExportPreview preview, Json original, List<String> bindings) {
  expect(raw['foreignRoot'], original['foreignRoot']);
  expect(raw['dshgo_export_sources'], original['dshgo_export_sources']);
  final data = _map(raw['data']);
  final old = _map(original['data']);
  expect(data['foreignData'], old['foreignData']);
  final extensions = _map(data['extensions']);
  final oldExtensions = _map(old['extensions']);
  expect(extensions['foreignExtension'], oldExtensions['foreignExtension']);
  final dshgo = _map(extensions['dshgo']);
  final oldDshgo = _map(oldExtensions['dshgo']);
  final rules = _maps(_map(dshgo['state'])['rules']);
  expect(rules.singleWhere((rule) => rule['id'] == 'shared-rule'), _maps(_map(oldDshgo['state'])['rules']).single);
  expect(rules.map((rule) => rule['id']), containsAll(_mappedIds(preview, bindings, 'shared-rule')));
  final events = _maps(_map(_map(dshgo['director'])['eventRules'])['rules']);
  expect(
    events.singleWhere((rule) => rule['id'] == 'shared-handler'),
    _maps(_map(_map(oldDshgo['director'])['eventRules'])['rules']).single,
  );
  expect(events.map((rule) => rule['id']), containsAll(_mappedIds(preview, bindings, 'shared-handler')));
  expect(events.map((rule) => rule['name']), containsAll(_mappedIds(preview, bindings, 'shared-event')));
  final components = _maps(_map(dshgo['components'])['custom']);
  expect(
    components.singleWhere((item) => item['id'] == 'shared-component'),
    _maps(_map(oldDshgo['components'])['custom']).single,
  );
  expect(components.map((item) => item['id']), containsAll(_mappedIds(preview, bindings, 'shared-component')));
  final skills = _map(_map(dshgo['dice'])['skills']);
  expect(skills['shared-skill'], _map(_map(oldDshgo['dice'])['skills'])['shared-skill']);
  expect(skills.keys, containsAll(_mappedIds(preview, bindings, 'shared-skill')));

  final regex = _maps(extensions['regex_scripts']);
  expect(regex.singleWhere((row) => row['id'] == 'shared-regex'), _maps(oldExtensions['regex_scripts']).single);
  expect(regex.map((row) => row['id']), [
    for (final binding in bindings)
      preview.idMappings.singleWhere(
        (row) =>
            row['kind'] == 'regex' && row['resourceLocalId'] == 'regex' && _map(row['source'])['bindingId'] == binding,
      )['exportedId'],
    'shared-regex',
  ]);
  final packedRegex = regex.where((row) => row['scriptName'] == 'PACK-REGEX').toList();
  expect(packedRegex, hasLength(2));
  expect(packedRegex.map((row) => row['id']).toSet(), hasLength(2));
  expect(packedRegex.every((row) => row['id'] != 'shared-regex'), isTrue);
  expect(packedRegex.map((row) => row['vendor']), everyElement('REGEX-UNKNOWN'));
  expect(regex.any((row) => row['id'] == 'ambient-regex'), isFalse);
  final book = _map(data['character_book']);
  final entries = _maps(book['entries']);
  expect(entries.take(3).toList(), _map(old['character_book'])['entries']);
  expect(book['legacyUnknown'], _map(old['character_book'])['legacyUnknown']);
  final packedWorld = entries.skip(3).toList();
  expect(packedWorld, hasLength(2));
  expect(packedWorld.map((row) => row['id']).toSet(), hasLength(2));
  expect(packedWorld.every((row) => !{'7', '2'}.contains('${row['id']}')), isTrue);
  expect(
    packedWorld.map((row) => row['id']),
    containsAll(_mappedIds(preview, bindings, 'shared-entry', resourceLocalId: 'lore')),
  );
  expect(packedWorld.map((row) => row['vendor']), everyElement('WORLD-UNKNOWN'));
  expect(entries.any((row) => row['content'] == 'AMBIENT-WORLD'), isFalse);
}

void _checkAssets(TavernCard card, TavernGameplayExportPreview preview, List<String> bindings, {required bool charx}) {
  final selected = preview.resourceMappings
      .where(
        (row) =>
            row['kind'] == 'asset' && row['localId'] == 'asset' && bindings.contains(_map(row['source'])['bindingId']),
      )
      .toList();
  expect(selected, hasLength(2));
  for (final row in selected) {
    final binding = _map(row['source'])['bindingId'];
    final bytes = utf8.encode(binding == bindings.first ? 'ASSET-ONE' : 'ASSET-TWO');
    expect(row['originalPath'], 'shared.bin');
    final uri = row['uri']! as String;
    expect(card.assetBytes(uri), bytes);
    if (charx) {
      final path = row['exportedPath']! as String;
      expect(path, isNot('shared.bin'));
      expect(card.assets[path], bytes);
    } else {
      expect(uri.startsWith('data:'), isTrue);
    }
  }
  final winner = selected.singleWhere((row) => _map(row['source'])['bindingId'] == bindings.last);
  final dshgo = _map(_map(card.data['extensions'])['dshgo']);
  expect(_map(dshgo['theme'])['background'], winner['uri']);
}

List<String> _mappedIds(
  TavernGameplayExportPreview preview,
  List<String> bindings,
  String localId, {
  String? resourceLocalId,
}) {
  final rows = preview.idMappings
      .where(
        (row) =>
            row['localId'] == localId &&
            bindings.contains(_map(row['source'])['bindingId']) &&
            (resourceLocalId == null || row['resourceLocalId'] == resourceLocalId),
      )
      .toList();
  expect(rows, hasLength(2));
  expect(rows.map((row) => row['kind']), everyElement(isA<String>()));
  final ids = [for (final row in rows) row['exportedId']! as String];
  expect(ids.toSet(), hasLength(2));
  expect(ids, isNot(contains(localId)));
  return ids;
}

Json _originalCard() => {
  'spec': 'chara_card_v3',
  'spec_version': '3.0',
  'foreignRoot': {'kept': null},
  'dshgo_export_sources': {'legacy': 'DO-NOT-REPLACE'},
  'data': {
    'name': 'Base export',
    'first_mes': 'opening',
    'foreignData': {'kept': false},
    'assets': [
      {'type': 'x_custom', 'name': 'base', 'uri': 'embedded://shared.bin', 'unknown': true},
    ],
    'character_book': {
      'legacyUnknown': {'kept': null},
      'entries': [
        {'id': 7, 'enabled': true, 'content': 'LEGACY-SHADOWED', 'constant': true},
        {'id': 7, 'enabled': true, 'content': 'LEGACY-WINNER', 'constant': true},
        {'enabled': false, 'content': 'LEGACY-IMPLICIT', 'unknown': true},
      ],
    },
    'extensions': {
      'foreignExtension': {
        'kept': [null, false],
      },
      'regex_scripts': [
        {
          'id': 'shared-regex',
          'scriptName': 'Legacy',
          'findRegex': '/NOT_PRESENT/g',
          'replaceString': 'LEGACY',
          'placement': [RegexPlacement.userInput],
          'disabled': true,
          'unknown': null,
        },
      ],
      'dshgo': {
        'v': 1,
        'state': {
          'schema': {
            'type': 'object',
            'additionalProperties': false,
            'required': ['n'],
            'properties': {
              'n': {'type': 'integer'},
            },
          },
          'init': {'n': 0},
          'rules': [
            {
              'id': 'shared-rule',
              'when': false,
              'do': [
                {'type': 'notice', 'text': 'legacy'},
              ],
            },
          ],
        },
        'director': {
          'eventRules': {
            'v': 1,
            'rules': [
              {
                'id': 'shared-handler',
                'name': 'shared-event',
                'when': false,
                'do': [
                  {'type': 'notice', 'text': 'legacy'},
                ],
              },
            ],
          },
        },
        'components': {
          'custom': [
            {'id': 'shared-component', 'unknown': 'LEGACY-COMPONENT'},
          ],
        },
        'dice': {
          'skills': {
            'shared-skill': {'unknown': 'LEGACY-SKILL'},
          },
        },
      },
    },
  },
};

Future<TavernPackVersionRef> _install(
  ScriptFixture h,
  String id,
  String asset, {
  bool incompatibleWorld = false,
}) async {
  final row = <String, Object?>{
    'uid': 7,
    'key': ['NOT_PRESENT'],
    'keysecondary': ['SECOND'],
    'selectiveLogic': incompatibleWorld ? null : 0,
    'content': 'PACK-WORLD',
    'position': 0,
    'vendor': 'WORLD-UNKNOWN',
  };
  final manifest = <String, Object?>{
    'formatVersion': 1,
    'packId': id,
    'packVersion': 'one',
    'dshgo': {
      'v': 1,
      'state': {
        'rules': [
          {
            'id': 'shared-rule',
            'when': true,
            'once': true,
            'do': [
              {
                'type': 'state',
                'ops': [
                  {'op': 'add', 'path': '/n', 'value': 1, 'why': 'pack once'},
                ],
              },
            ],
          },
        ],
      },
      'director': {
        'eventRules': {
          'v': 1,
          'rules': [
            {
              'id': 'shared-handler',
              'name': 'shared-event',
              'when': true,
              'do': [
                {'type': 'notice', 'text': 'pack'},
              ],
            },
          ],
        },
      },
      'components': {
        'custom': [
          {'id': 'shared-component', 'unknown': 'PACK-COMPONENT'},
        ],
        'enabled': ['shared-component'],
      },
      'dice': {
        'skills': {
          'shared-skill': {'unknown': 'PACK-SKILL'},
        },
      },
      'theme': {'background': 'DECLARED-ASSET'},
    },
    'references': [
      {'pointer': '/components/enabled/0', 'kind': 'component', 'source': 'self', 'localId': 'shared-component'},
      {'pointer': '/theme/background', 'kind': 'asset', 'source': 'self', 'localId': 'asset'},
    ],
    'resources': [
      {
        'kind': 'lorebook',
        'localId': 'lore',
        'path': 'lore.json',
        'entries': [
          {'localId': 'shared-entry', 'pointer': '/entries/entry'},
        ],
      },
      {'kind': 'regex', 'localId': 'regex', 'path': 'regex.json'},
      {'kind': 'asset', 'localId': 'asset', 'path': 'shared.bin'},
    ],
  };
  final bytes = _zip({
    'pack.json': utf8.encode(jsonEncode(manifest)),
    'lore.json': utf8.encode(
      jsonEncode({
        'bookVendor': 'PACK-BOOK-UNKNOWN',
        'entries': {'entry': row},
      }),
    ),
    'regex.json': utf8.encode(
      jsonEncode({
        'id': 'shared-regex',
        'scriptName': 'PACK-REGEX',
        'findRegex': '/NOT_PRESENT/g',
        'replaceString': 'PACK',
        'placement': [RegexPlacement.userInput],
        'promptOnly': true,
        'markdownOnly': true,
        'vendor': 'REGEX-UNKNOWN',
      }),
    ),
    'shared.bin': utf8.encode(asset),
    'unselected.bin': utf8.encode('PACK-UNSELECTED'),
  });
  return (await h.engine.importGameplayPack(bytes)).ref;
}

Uint8List _zip(Map<String, List<int>> files) {
  final archive = Archive();
  for (final row in files.entries) {
    archive.addFile(ArchiveFile(row.key, row.value.length, row.value));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

List<String> _assetContents(TavernCard card) => [
  for (final asset in _maps(card.data['assets']))
    if (asset['uri'] case final String uri) utf8.decode(card.assetBytes(uri)!, allowMalformed: true),
];

// Snapshot ordinary logical tables, not the FTS virtual table or its shadows.
Json _rows(ScriptFixture h) => h.inspect(
  (db) => {
    for (final table in db.select(
      "SELECT name FROM sqlite_master WHERE type = 'table' "
      "AND name NOT LIKE 'sqlite_%' AND sql NOT LIKE 'CREATE VIRTUAL TABLE%' "
      "AND name NOT GLOB 'nodes_fts_*' ORDER BY name",
    ))
      table['name']! as String: [
        for (final row in db.select('SELECT * FROM "${table['name']}" ORDER BY rowid')) Map<String, Object?>.from(row),
      ],
  },
);

Future<Map<String, List<int>>> _files(ScriptFixture h) async {
  final files = <String, List<int>>{};
  await for (final entity in h.root.list(recursive: true, followLinks: false)) {
    if (entity is! File ||
        entity.path.endsWith('tavern.sqlite3') ||
        entity.path.endsWith('tavern.sqlite3-wal') ||
        entity.path.endsWith('tavern.sqlite3-shm')) {
      continue;
    }
    files[entity.path] = await entity.readAsBytes();
  }
  return files;
}

Future<Json> _saved(TavernEngine engine, String chat) async {
  final files = await engine.exportChat(chat);
  final document = StChatDocument.decode(files.first.fileName, files.first.bytes);
  return _map(_map(_map(document.messages.last['extra'])['dshgo'])['tavernState']);
}

TypeMatcher<TavernGameplayException> _error(String code) =>
    isA<TavernGameplayException>().having((error) => error.code, 'code', code);
Json _map(Object? value) => value! as Json;
List<Json> _maps(Object? value) => (value! as List<Object?>).map(_map).toList();

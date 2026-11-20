import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:test/test.dart';

import 'p2_script_test_support.dart';

typedef Json = Map<String, Object?>;

void main() {
  test('schema roots replace complete nodes and failed traversal preserves the prior schema and value', () async {
    final h = await ScriptFixture.open();
    final original = <String, Object?>{
      'v': 1,
      'state': {
        'schema': {
          'type': 'object',
          'required': ['branch'],
          'additionalProperties': false,
          'x-dsh-by': ['user'],
          'x-dsh-hidden': true,
          'properties': {
            'branch': {
              'type': 'object',
              'required': ['old'],
              'additionalProperties': false,
              'properties': {
                'old': {'type': 'number', 'maximum': 10},
                'kept': {'type': 'string'},
              },
            },
            'blank': {'type': 'object'},
          },
        },
        'init': {
          'branch': {'old': 1, 'kept': 'original'},
          'blank': <String, Object?>{},
        },
      },
    };
    final character = await h.card('Schema composition', extensions: {'dshgo': original});
    final chat = await h.engine.createGroupChat([character], hostCharacterId: character, addGreetings: false);
    final low = await _install(h, 'child-low', {
      'schemaPatches': [
        {
          'path': '/branch/old',
          'node': {'type': 'integer', 'minimum': 0},
        },
      ],
    });
    final parent = await _install(h, 'parent-high', {
      'schemaPatches': [
        {
          'path': '/branch',
          'node': {
            'type': 'object',
            'required': ['leaf'],
            'additionalProperties': false,
            'properties': {
              'leaf': {'type': 'integer', 'maximum': 8},
            },
          },
        },
      ],
    });
    final child = await _install(h, 'child-high', {
      'schemaPatches': [
        {
          'path': '/branch/leaf',
          'node': {
            'type': 'number',
            'minimum': -2,
            'x-dsh-by': ['model'],
          },
        },
        {
          'path': '/new',
          'node': {'type': 'boolean'},
        },
      ],
    });
    final failed = await _install(h, 'bad-parent', {
      'schemaPatches': [
        {
          'path': '/blank/missing/child',
          'node': {'type': 'string'},
        },
      ],
    });
    List<TavernPackScopePreview> scopes({bool bad = false}) => [
      TavernPackScopePreview(
        scope: TavernGameplayScope.global,
        bindings: [TavernPackBindingPreview(bindingId: 'low', packRef: low)],
      ),
      TavernPackScopePreview(
        scope: TavernGameplayScope.character,
        targetId: character,
        bindings: [TavernPackBindingPreview(bindingId: 'parent', packRef: parent)],
      ),
      TavernPackScopePreview(
        scope: TavernGameplayScope.chat,
        targetId: chat,
        bindings: [
          TavernPackBindingPreview(bindingId: 'child', packRef: child),
          if (bad) TavernPackBindingPreview(bindingId: 'failed', packRef: failed),
        ],
      ),
    ];
    final before = _rows(h);
    final context = TavernGameplayContext(characterId: character, chatId: chat);
    final result = await h.engine.resolveGameplayConfig(context, proposedScopes: scopes(), validateCurrentState: true);
    final state = _map(_map(result.effective)['state']);
    final schema = _map(state['schema']);
    final properties = _map(schema['properties']);
    expect(schema['required'], ['branch']);
    expect(schema['additionalProperties'], isFalse);
    expect(schema['x-dsh-by'], ['user']);
    expect(schema['x-dsh-hidden'], isTrue);
    expect(properties['branch'], {
      'type': 'object',
      'required': ['leaf'],
      'additionalProperties': false,
      'properties': {
        'leaf': {
          'type': 'number',
          'minimum': -2,
          'x-dsh-by': ['model'],
        },
      },
    });
    expect(properties['blank'], {'type': 'object'});
    expect(properties['new'], {'type': 'boolean'});
    expect(state['init'], _map(original['state'])['init']);
    expect(result.raw, original);
    expect(_state(result)['compositionEligible'], isTrue);
    expect(result.currentState!.validated, isTrue);
    expect(result.currentState!.value, _map(original['state'])['init']);
    expect(
      result.currentState!.issues,
      isNotEmpty,
      reason: 'The old value is checked as it is; the new required leaf is not initialized.',
    );
    final parentTrace = result.fieldSources.singleWhere((row) => row['path'] == '/state/schema/properties/branch');
    expect(_map(parentTrace['winner'])['bindingId'], 'parent');
    final shadowed = (parentTrace['shadowed']! as List<Object?>).map(_map).toList();
    expect(shadowed, contains(equals({'kind': 'card', 'characterId': character})));
    expect(shadowed.any((row) => row['bindingId'] == 'low'), isTrue);
    // The same card also underlies the lower child, but is one source.
    expect(shadowed, hasLength(2));
    final leafTrace = result.fieldSources.singleWhere(
      (row) => row['path'] == '/state/schema/properties/branch/properties/leaf',
    );
    expect((leafTrace['shadowed']! as List<Object?>).map(_map).single['bindingId'], 'parent');
    expect(
      result.fieldSources.singleWhere((row) => row['path'] == '/state/schema/properties/new')['shadowed'],
      isEmpty,
    );
    expect(result.conflicts, isEmpty);
    final withoutValueCheck = await h.engine.resolveGameplayConfig(context, proposedScopes: scopes());
    expect(withoutValueCheck.effectiveConfigId, result.effectiveConfigId);

    final rejected = await h.engine.resolveGameplayConfig(
      context,
      proposedScopes: scopes(bad: true),
      validateCurrentState: true,
    );
    expect(_map(_map(rejected.effective)['state'])['schema'], schema);
    expect(_map(_map(_map(_map(rejected.effective)['state'])['schema'])['properties'])['blank'], {'type': 'object'});
    expect(rejected.conflicts.map((row) => row['code']), contains('schema_parent'));
    expect(_state(rejected)['executable'], isTrue);
    expect(_state(rejected)['compositionEligible'], isFalse);
    expect(rejected.currentState!.validated, isFalse);
    expect(rejected.currentState!.value, result.currentState!.value);
    expect(_rows(h), before);
    expect((await h.engine.readGameplayPack(child))!.manifest['schemaPatches'], [
      {
        'path': '/branch/leaf',
        'node': {
          'type': 'number',
          'minimum': -2,
          'x-dsh-by': ['model'],
        },
      },
      {
        'path': '/new',
        'node': {'type': 'boolean'},
      },
    ]);
    h.expectNoGeneration();
  });

  test('source eligibility and source-local rule identities preserve the shared original declaration budget', () async {
    final h = await ScriptFixture.open();
    final base = await h.card(
      'Rules',
      extensions: {
        'dshgo': {
          'v': 1,
          'state': {
            'schema': {'type': 'object'},
            'init': <String, Object?>{},
            'rules': [_rule('shared'), _rule('')],
          },
        },
      },
    );
    final chat = await h.engine.createGroupChat([base], hostCharacterId: base, addGreetings: false);
    final borrowed = await _install(h, 'rules-only', {
      'dshgo': {
        'v': 1.0,
        'state': {
          'rules': [_rule('shared')],
        },
      },
    });
    final context = TavernGameplayContext(characterId: base, chatId: chat);
    final scope = TavernPackScopePreview(
      scope: TavernGameplayScope.global,
      bindings: [TavernPackBindingPreview(bindingId: 'borrowed', packRef: borrowed)],
    );
    final result = await h.engine.resolveGameplayConfig(context, proposedScopes: [scope], validateCurrentState: true);
    final rules = (_state(result)['rules']! as List<Object?>).map(_map).toList();
    expect(rules.map((row) => row['key']), ['id:shared', 'id:', 'id:shared']);
    expect(rules.map((row) => row['compositionEligible']), everyElement(isTrue));
    expect(_map(rules.last['source'])['bindingId'], 'borrowed');
    expect(_state(result)['issues'], isEmpty);
    expect(result.currentState!.validated, isTrue);
    expect(result.currentState!.issues, isEmpty);

    final bare = await h.card('No state');
    final single = await _install(h, 'single-pack', {
      'schemaPatches': [
        {
          'path': '',
          'node': {'type': 'object'},
        },
      ],
      'dshgo': {
        'state': {
          'rules': [_rule('only')],
        },
      },
    });
    final one = await h.engine.resolveGameplayConfig(
      TavernGameplayContext(characterId: bare),
      proposedScopes: [
        TavernPackScopePreview(
          scope: TavernGameplayScope.global,
          bindings: [TavernPackBindingPreview(bindingId: 'only', packRef: single)],
        ),
      ],
    );
    expect(_map(_map(one.effective)['state'])['rules'], [_rule('only')]);
    expect((_state(one)['rules']! as List<Object?>).map(_map).single['key'], 'id:only');
    expect(one.rawPresent, isFalse);
    expect(one.conflicts, isEmpty);

    final malformedCarrier = await h.engine.importCard(
      _bytes({
        'spec': 'chara_card_v3',
        'spec_version': '3.0',
        'data': {'name': 'Preserved extensions carrier', 'extensions': null},
      }),
    );
    final carrier = await h.engine.resolveGameplayConfig(TavernGameplayContext(characterId: malformedCarrier.id));
    final toolIssues = (carrier.definitions.singleWhere((row) => row['path'] == '/tools')['issues']! as List<Object?>)
        .map(_map)
        .toList();
    final carrierIssue = toolIssues.singleWhere((row) => _map(row['diagnostic'])['fieldPath'] == 'extensions');
    expect(carrierIssue['sourceRoot'], 'cardData');
    expect(carrierIssue['sourcePath'], '/extensions');
    expect(carrier.rawPresent, isFalse);

    final nullState = await _install(h, 'null-state', {
      'dshgo': {'state': null},
      'schemaPatches': [
        {
          'path': '/null-source',
          'node': {'type': 'number'},
        },
      ],
    });
    final future = await _install(h, 'future-source', {
      'dshgo': {'v': 2},
      'schemaPatches': [
        {
          'path': '/future-source',
          'node': {'type': 'number'},
        },
      ],
    });
    final invalid = await h.engine.resolveGameplayConfig(
      context,
      proposedScopes: [
        TavernPackScopePreview(
          scope: TavernGameplayScope.global,
          bindings: [
            TavernPackBindingPreview(bindingId: 'null', packRef: nullState),
            TavernPackBindingPreview(bindingId: 'future', packRef: future),
          ],
        ),
      ],
      validateCurrentState: true,
    );
    expect(_map(_map(invalid.effective)['state'])['schema'], {'type': 'object'});
    expect(_state(invalid)['executable'], isTrue);
    expect(_state(invalid)['compositionEligible'], isFalse);
    expect(invalid.currentState!.validated, isFalse);
    expect(invalid.currentState!.value, <String, Object?>{});
    expect(invalid.conflicts.map((row) => row['code']), containsAll(['state_source_shape', 'dshgo_source_version']));

    final budget = await h.card(
      'Full original list',
      extensions: {
        'dshgo': {
          'state': {
            'schema': {'type': 'object'},
            'rules': [_rule('duplicate'), for (var i = 1; i < 256; i++) null, _rule('duplicate')],
          },
        },
      },
    );
    final tail = await _install(h, 'tail', {
      'dshgo': {
        'state': {
          'rules': [_rule('tail')],
        },
      },
    });
    final bounded = await h.engine.resolveGameplayConfig(
      TavernGameplayContext(characterId: budget),
      proposedScopes: [
        TavernPackScopePreview(
          scope: TavernGameplayScope.global,
          bindings: [TavernPackBindingPreview(bindingId: 'tail', packRef: tail)],
        ),
      ],
    );
    expect(_state(bounded)['rules'], isEmpty);
    final issues = (_state(bounded)['issues']! as List<Object?>).map(_map).toList();
    expect(
      issues.map((row) => _map(row['diagnostic'])['code']),
      containsAll(['rules_limit', 'rule_duplicate_id', 'rules_composition_limit']),
    );
    final duplicate = issues.singleWhere((row) => _map(row['diagnostic'])['code'] == 'rule_duplicate_id');
    expect(duplicate['sourcePath'], '/state/rules/0');
    expect(_map(duplicate['source'])['characterId'], budget);
    final limit = issues.singleWhere((row) => _map(row['diagnostic'])['code'] == 'rules_composition_limit');
    expect(_map(limit['source'])['bindingId'], 'tail');
    h.expectNoGeneration();
  });

  test('resource plans retain scope order, saved regex disabling and explicit cross-source references', () async {
    final h = await ScriptFixture.open();
    final host = await h.card(
      'Host',
      extensions: {
        'dshgo': {
          'state': {
            'schema': {'type': 'object'},
            'init': <String, Object?>{},
          },
          'dice': {'system': 'host-system'},
          'components': {
            'custom': [
              {'id': 'host-panel', 'foreign': true},
            ],
          },
        },
      },
    );
    final actor = await h.card('Actor');
    final chat = await h.engine.createGroupChat([actor], hostCharacterId: host, addGreetings: false);
    final book = <String, Object?>{
      'entries': {
        '0': {'uid': 0, 'key': <String>[], 'content': 'Pack book', 'constant': true, 'disable': false},
      },
    };
    final scripts = [
      {
        'id': 'bad',
        'findRegex': '/[/g',
        'replaceString': '',
        'placement': [2],
        'disabled': false,
      },
      {
        'id': 'good',
        'findRegex': '/TOKEN/g',
        'replaceString': 'ok',
        'placement': [2],
        'disabled': false,
      },
    ];
    final bookBytes = Uint8List.fromList([...utf8.encode('\uFEFF\uFEFF'), ..._bytes(book)]);
    final cast = <String, Object?>{
      'spec': 'chara_card_v3',
      'spec_version': '3.0',
      'data': {'name': 'Catalog only'},
    };
    final castBytes = Uint8List.fromList([...utf8.encode('\uFEFF\uFEFF'), ..._bytes(cast)]);
    final ref = await _install(
      h,
      'resources',
      {
        'resources': [
          {
            'localId': 'book',
            'kind': 'lorebook',
            'path': 'book.json',
            'entries': [
              {'localId': 'entry', 'pointer': '/entries/0'},
            ],
          },
          {
            'localId': 'regex',
            'kind': 'regex',
            'path': 'regex.json',
            'entries': [
              {'localId': 'bad', 'pointer': '/0'},
              {'localId': 'good', 'pointer': '/1'},
            ],
          },
          {'localId': 'asset', 'kind': 'asset', 'path': 'asset.bin'},
          {'localId': 'cast', 'kind': 'castCard', 'path': 'cast.json'},
        ],
        'dshgo': {
          'state': {
            'rules': [
              {
                'id': 'rule',
                'when': true,
                'do': [
                  {'type': 'event', 'name': 'event', 'data': null},
                ],
              },
            ],
          },
          'director': {
            'eventRules': {
              'v': 1,
              'rules': [
                {'id': 'handler', 'name': 'event', 'when': true, 'do': []},
              ],
            },
          },
          'components': {
            'custom': [
              {'id': 'panel', 'foreign': 'kept'},
            ],
            'enabled': ['panel', 'host-panel'],
          },
          'dice': {
            'skills': {
              'same': {'opaque': true},
            },
          },
          'theme': {
            'background': 'not-a-guessed-card-id',
            'fonts': {'external': 'asset'},
          },
        },
        'references': [
          {'pointer': '/state/rules/0/do/0/name', 'kind': 'event', 'source': 'global', 'localId': 'event'},
          {'pointer': '/components/enabled/0', 'kind': 'component', 'source': 'self', 'localId': 'panel'},
          {'pointer': '/components/enabled/1', 'kind': 'component', 'source': 'card', 'localId': 'host-panel'},
          {'pointer': '/theme/background', 'kind': 'asset', 'source': 'card', 'localId': 'asset'},
          {'pointer': '/theme/fonts/external', 'kind': 'asset', 'source': 'actor', 'localId': 'asset'},
        ],
      },
      files: {
        'book.json': bookBytes,
        'regex.json': _bytes(scripts),
        'asset.bin': Uint8List.fromList([1, 2, 3]),
        'cast.json': castBytes,
      },
    );
    TavernPackBindingPreview binding(String id) =>
        TavernPackBindingPreview(bindingId: id, packRef: ref, aliases: const {'global': 'g', 'actor': 'c'});
    final scopes = [
      TavernPackScopePreview(scope: TavernGameplayScope.global, bindings: [binding('g')]),
      TavernPackScopePreview(scope: TavernGameplayScope.character, targetId: actor, bindings: [binding('c')]),
      TavernPackScopePreview(scope: TavernGameplayScope.chat, targetId: chat, bindings: [binding('t')]),
    ];
    await h.engine.setSettings({'regexEnabled': false, 'characterRegexEnabled': true});
    final before = _rows(h);
    final context = TavernGameplayContext(characterId: actor, chatId: chat);
    final result = await h.engine.resolveGameplayConfig(context, proposedScopes: scopes);
    final books = result.resources.where((row) => row['kind'] == 'lorebook').toList();
    final regex = result.resources
        .where((row) => row['kind'] == 'regex' && _map(row['source'])['kind'] == 'pack')
        .toList();
    expect(
      result.resources.singleWhere(
        (row) => row['kind'] == 'regex' && row['bucket'] == 'global' && _map(row['source'])['kind'] == 'settings',
      )['entries'],
      isEmpty,
    );
    expect(books.map((row) => _map(row['source'])['bindingId']), ['g', 't', 'c']);
    expect(books.map((row) => row['raw']), everyElement(book));
    expect(result.resources.where((row) => row['kind'] == 'castCard').map((row) => row['raw']), everyElement(cast));
    expect(regex.map((row) => _map(row['source'])['bindingId']), ['g', 'c', 't']);
    for (final row in regex) {
      final entries = (row['entries']! as List<Object?>).map(_map).toList();
      expect(entries.map((entry) => entry['effective']), [false, false]);
      expect(entries.first['disabled'], isTrue);
      expect(_map(entries.first['raw'])['disabled'], isFalse);
      expect(_map((entries.first['diagnostics']! as List<Object?>).single)['status'], 'incompatible');
    }
    final events = result.definitions.singleWhere((row) => row['path'] == '/director/eventRules');
    expect(events['executable'], isNull);
    expect(events['compositionEligible'], isTrue);
    final registries = (events['registries']! as List<Object?>).map(_map).toList();
    expect(registries.map((row) => _map(row['source'])['bindingId']), ['g', 't']);
    expect(registries.map((row) => row['executable']), [true, true]);
    expect(registries.map((row) => row['handlers']), everyElement(hasLength(1)));
    final references =
        (result.definitions.singleWhere((row) => row['path'] == '/references')['items']! as List<Object?>)
            .map(_map)
            .toList();
    expect(references.where((row) => row['pointer'] == '/theme/background').map((row) => row['resolved']), [
      false,
      false,
    ]);
    final assetRefs = references.where((row) => row['pointer'] == '/theme/fonts/external').toList();
    expect(assetRefs.map((row) => row['resolved']), [true, true]);
    expect(assetRefs.map((row) => _map(row['target'])['bindingId']), ['c', 'c']);
    expect(references.where((row) => row['kind'] == 'event').map((row) => row['resolved']), [true, true]);
    expect(result.conflicts.map((row) => row['code']), ['unresolved_reference', 'unresolved_reference']);
    expect(_map(_map(result.effective)['dice'])['system'], 'host-system');
    expect(
      _map(result.fieldSources.singleWhere((row) => row['path'] == '/dice/system')['winner'])['characterId'],
      host,
    );
    final skills = (result.definitions.singleWhere((row) => row['path'] == '/dice/skills')['items']! as List<Object?>)
        .map(_map)
        .toList();
    expect(skills.map((row) => _map(row['source'])['bindingId']), ['g', 't']);
    expect(skills.map((row) => row['localId']), ['same', 'same']);
    expect(_rows(h), before);

    await h.engine.setSettings({'regexEnabled': true, 'characterRegexEnabled': false});
    final reopened = await h.engine.resolveGameplayConfig(context, proposedScopes: scopes);
    final enabled = reopened.resources
        .where((row) => row['kind'] == 'regex' && _map(row['source'])['kind'] == 'pack')
        .toList();
    expect(enabled.map((row) => (row['entries']! as List<Object?>).map(_map).last['effective']), [true, false, true]);
    expect(enabled.map((row) => (row['entries']! as List<Object?>).map(_map).first['disabled']), everyElement(isTrue));
    expect(
      reopened.effectiveConfigId,
      result.effectiveConfigId,
      reason: 'Resource enablement changes the resource view, not the host definition identity.',
    );
    expect((await h.engine.readGameplayPackResource(ref, 'regex'))!.bytes, _bytes(scripts));
    expect((await h.engine.readGameplayPackResource(ref, 'book'))!.bytes, bookBytes);
    expect((await h.engine.readGameplayPackResource(ref, 'cast'))!.bytes, castBytes);
    h.expectNoGeneration();
  });
}

Json _map(Object? value) => value! as Json;
Json _state(TavernGameplayResolution result) => result.definitions.singleWhere((row) => row['path'] == '/state');
Json _rule(String id) => {'id': id, 'when': true, 'do': <Object?>[]};
Uint8List _bytes(Object? value) => Uint8List.fromList(utf8.encode(jsonEncode(value)));

Future<TavernPackVersionRef> _install(
  ScriptFixture h,
  String id,
  Json fields, {
  Map<String, Uint8List> files = const {},
}) async {
  final bytes = _bytes({'formatVersion': 1, 'packId': id, 'packVersion': '1', 'resources': <Object?>[], ...fields});
  final archive = Archive()..addFile(ArchiveFile('pack.json', bytes.length, bytes));
  for (final entry in files.entries) {
    archive.addFile(ArchiveFile(entry.key, entry.value.length, entry.value));
  }
  return (await h.engine.importGameplayPack(Uint8List.fromList(ZipEncoder().encode(archive)))).ref;
}

Json _rows(ScriptFixture h) => h.inspect(
  (db) => {
    for (final table in ['chats', 'nodes', 'node_states', 'agent_runs'])
      table: [for (final row in db.select('SELECT * FROM $table ORDER BY rowid')) Map<String, Object?>.from(row)],
  },
);

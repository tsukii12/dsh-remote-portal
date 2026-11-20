import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:dsh_tavern/src/io/import_intake.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import 'support/t24_engine_harness.dart' show t24Card;

void main() {
  test('cards without an explicit state schema keep the entire old report shape', () {
    final baseline = _withoutFingerprint(
      _assess({
        'data': {'first_mes': 'Hello', 'extensions': {}},
      }),
    );
    for (final dshgo in <Object?>[
      null,
      'opaque',
      <String, Object?>{},
      {'v': 99},
      {'v': null, 'state': null},
      {'v': 2, 'state': 'opaque'},
      {
        'state': {
          'init': {'n': 9},
          'rules': 'not executed',
          'future': '<script>code</script>{{banned}}',
        },
      },
      {
        'schema': null,
        'state': {
          'vendor': {'schema': false},
        },
      },
    ]) {
      final document = <String, Object?>{
        'data': {
          'first_mes': 'Hello',
          'extensions': {'dshgo': dshgo},
        },
      };
      final before = jsonEncode(document);
      final report = _assess(document);
      expect(_withoutFingerprint(report), baseline, reason: '$dshgo');
      expect(report.counts.keys.any((key) => key.startsWith('state')), isFalse);
      expect(jsonEncode(document), before);
    }
  });

  test('valid definitions count declarations without generating state or effects', () {
    final state = <String, Object?>{
      'schema': {
        'type': 'object',
        'properties': {
          'n': {'type': 'integer', 'default': 0},
        },
      },
      'init': {'n': 2},
      'rules': [
        {
          'id': 'once',
          'when': true,
          'once': true,
          'do': [
            {'type': 'notice', 'text': 'notice'},
          ],
        },
        {'when': false, 'do': <Object?>[]},
      ],
    };
    final document = _document({'v': 1, 'state': state});
    final before = jsonEncode(document);
    final report = _assess(document);
    expect(report.verdict, TavernImportVerdict.usable);
    expect(report.findings, isEmpty);
    expect(report.counts['stateDefinitions'], 1);
    expect(report.counts['stateRules'], 2);
    expect(report.counts['stateDefinitionIssues'], 0);
    expect(report.renderLevel, 0);
    expect(report.fingerprint, importFingerprint(TavernImportKind.character, document));
    expect(jsonEncode(document), before);
  });

  test('explicit null scalar and array schemas are visible without rejecting the character core', () {
    for (final schema in <Object?>[null, false, 'object', <Object?>[]]) {
      final document = _document({
        'state': {'schema': schema},
      });
      final before = jsonEncode(document);
      final report = _assess(document);
      expect(report.verdict, TavernImportVerdict.partial, reason: '$schema');
      expect(report.findings, hasLength(1));
      expect(report.findings.single.code, 'schema_shape');
      expect(report.findings.single.path, r'$.data.extensions.dshgo.state.schema');
      expect(report.findings.single.kind, TavernImportFindingKind.invalid);
      expect(report.counts['stateDefinitions'], 1);
      expect(report.counts['stateDefinitionIssues'], 1);
      expect(jsonEncode(document), before);
    }
  });

  test('an omitted version defaults to one without writing it into the raw card', () {
    for (final version in <Map<String, Object?>>[
      {},
      {'v': 1},
      {'v': 1.0},
    ]) {
      final dshgo = <String, Object?>{
        ...version,
        'state': {
          'schema': {'type': 'object'},
        },
      };
      final before = jsonEncode(dshgo);
      final report = _assess(_document(dshgo));
      expect(report.verdict, TavernImportVerdict.usable);
      expect(report.findings, isEmpty);
      expect(jsonEncode(dshgo), before);
      expect(dshgo.containsKey('v'), version.containsKey('v'));
    }
  });

  test('future null and string versions point to the actual extension version field', () {
    for (final version in <Object?>[2, 99, null, '1']) {
      final document = _document({
        'v': version,
        'state': {
          'schema': {'type': 'object'},
        },
      });
      final before = jsonEncode(document);
      final report = _assess(document);
      expect(report.verdict, TavernImportVerdict.partial, reason: '$version');
      expect(report.findings.single.code, 'state_version');
      expect(report.findings.single.path, r'$.data.extensions.dshgo.v');
      expect(report.findings.single.kind, TavernImportFindingKind.invalid);
      expect(jsonEncode(document), before);
    }
  });

  test('unsupported constraints remain separate per source location and never make a card preserve only', () {
    final document = _document({
      'state': {
        'schema': {
          'type': 'object',
          'properties': {
            'a': {'type': 'string', 'pattern': '^A'},
            'b': {r'$ref': '#/external'},
            'allowed': {'type': 'integer', 'x-dsh-by': <Object?>[]},
          },
        },
      },
    });
    final before = jsonEncode(document);
    final report = _assess(document);
    expect(report.verdict, TavernImportVerdict.partial);
    expect(report.findings.map((issue) => issue.code), ['schema_unsupported', 'schema_unsupported']);
    expect(report.findings.map((issue) => issue.path), [
      r'$.data.extensions.dshgo.state.schema.properties.a.pattern',
      r'$.data.extensions.dshgo.state.schema.properties.b.$ref',
    ]);
    expect(report.findings.every((issue) => issue.kind == TavernImportFindingKind.unsupported), isTrue);
    expect(report.counts['stateDefinitionIssues'], 2);
    expect(jsonEncode(document), before);
    final rootBlocked = _assess(
      _document({
        'state': {
          'schema': {r'$ref': '#/external'},
        },
      }),
    );
    expect(rootBlocked.verdict, TavernImportVerdict.partial);
    expect(rootBlocked.findings.single.code, 'schema_unsupported');
  });

  test('unknown annotations remain lossless unknown findings without changing usability', () {
    const opaque = '<script>doNotRun()</script>{{banned::secret}}';
    final document = _document({
      'v': 1,
      'state': {
        'schema': {
          'type': 'object',
          'x-vendor': {'payload': opaque},
          'properties': {
            'n': {'type': 'number', 'x-dsh-show': 'future-widget'},
          },
        },
        'vendor': {
          'keep': [false, null, opaque],
        },
        'rules': [
          {
            'when': true,
            'do': <Object?>[],
            'vendor': {'payload': opaque},
          },
        ],
      },
    });
    final before = jsonEncode(document);
    final report = _assess(document);
    expect(report.verdict, TavernImportVerdict.usable);
    expect(report.findings.map((issue) => issue.code), [
      'schema_unknown',
      'schema_show',
      'state_unknown',
      'rule_unknown',
    ]);
    expect(report.findings.every((issue) => issue.kind == TavernImportFindingKind.unknown), isTrue);
    expect(report.findings.any((issue) => issue.message.contains(opaque)), isFalse);
    expect(report.counts['stateDefinitionIssues'], 4);
    expect(report.counts['scripts'], 0);
    expect(report.counts['macroOccurrences'], 0);
    expect(report.renderLevel, 0);
    expect(jsonEncode(document), before);
    expect(
      TavernImportReport.fromJson(jsonDecode(jsonEncode(report.toJson())) as Map<String, Object?>).toJson(),
      report.toJson(),
    );
  });

  test('pointer mapping distinguishes escaped object keys and rule indices with raw or wrapped input', () {
    final state = <String, Object?>{
      'schema': {
        'type': 'object',
        'properties': {
          'a/b~c': {
            'type': 'array',
            'items': {
              'type': 'object',
              'properties': {
                '0': {'type': 'string', 'pattern': 'x'},
                'line\n': {'type': 'string', 'pattern': 'y'},
                'quote"': {'type': 'integer', 'x-dsh-step': -1},
              },
            },
          },
        },
      },
      'rules': [
        {'when': false, 'do': <Object?>[]},
        {
          'when': true,
          'do': [
            {'type': 'unrecognized'},
          ],
        },
      ],
    };
    final data = <String, Object?>{
      'extensions': {
        'dshgo': {'state': state},
      },
    };
    for (final wrapped in [false, true]) {
      final document = wrapped ? <String, Object?>{'data': data} : data;
      final report = _assess(document, path: r'$[4]');
      final prefix = wrapped ? r'$[4].data.extensions.dshgo.state' : r'$[4].extensions.dshgo.state';
      expect(report.findings.map((issue) => issue.path), [
        '$prefix.schema.properties["a/b~c"].items.properties["0"].pattern',
        '$prefix.schema.properties["a/b~c"].items.properties["line\\n"].pattern',
        '$prefix.schema.properties["a/b~c"].items.properties[${jsonEncode('quote"')}]["x-dsh-step"]',
        '$prefix.rules[1].do[0]',
      ]);
      expect(report.findings.every((issue) => issue.line == null && issue.offset == null), isTrue);
      expect(report.counts['stateDefinitionIssues'], 4);
    }
  });

  test('bad rules retain individual compiler diagnostics without evaluating their conditions', () {
    final document = _document({
      'state': {
        'schema': {'type': 'object'},
        'rules': [
          {'id': 'same', 'when': true, 'do': <Object?>[]},
          {'id': 'same', 'when': false, 'do': <Object?>[]},
          {
            'when': true,
            'do': [
              {'type': 'not-supported'},
            ],
          },
          {
            'when': {'log': 'not supported'},
            'do': <Object?>[],
          },
          false,
        ],
      },
    });
    final before = jsonEncode(document);
    final report = _assess(document);
    expect(report.findings.map((issue) => issue.code), [
      'rule_duplicate_id',
      'rule_duplicate_id',
      'rule_action',
      'logic_operator',
      'rule_shape',
    ]);
    expect(report.findings.map((issue) => issue.path), [
      r'$.data.extensions.dshgo.state.rules[0]',
      r'$.data.extensions.dshgo.state.rules[1]',
      r'$.data.extensions.dshgo.state.rules[2].do[0]',
      r'$.data.extensions.dshgo.state.rules[3].when',
      r'$.data.extensions.dshgo.state.rules[4]',
    ]);
    expect(report.counts['stateRules'], 5);
    expect(report.counts['stateDefinitionIssues'], 5);
    expect(report.verdict, TavernImportVerdict.partial);
    expect(jsonEncode(document), before);
  });

  test('schema depth refusal is reported while the complete raw definition survives', () {
    Object? schema = <String, Object?>{'type': 'number'};
    for (var i = 0; i < 65; i++) {
      schema = {'type': 'array', 'items': schema};
    }
    final document = _document({
      'state': {'schema': schema},
    });
    final before = jsonEncode(document);
    final report = _assess(document);
    expect(report.verdict, TavernImportVerdict.partial);
    expect(report.findings.single.code, 'schema_limit');
    expect(report.findings.single.path, r'$.data.extensions.dshgo.state.schema' + List.filled(65, '.items').join());
    expect(report.counts['stateDefinitionIssues'], 1);
    expect(jsonEncode(document), before);
  });

  test('rule resource counts describe all declarations instead of pretending that they executed', () {
    final document = _document({
      'state': {
        'schema': {'type': 'object'},
        'rules': [
          for (var i = 0; i < 257; i++) {'when': false, 'do': <Object?>[]},
        ],
      },
    });
    final before = jsonEncode(document);
    final report = _assess(document);
    expect(report.counts['stateRules'], 257);
    expect(report.findings.single.code, 'rules_limit');
    expect(report.findings.single.path, r'$.data.extensions.dshgo.state.rules');
    expect(report.verdict, TavernImportVerdict.partial);
    expect(jsonEncode(document), before);
  });

  test('compile only intake does not evaluate derive rules or literal macro and HTML strings', () {
    final document = _document({'state': _dangerousDefinition()});
    final before = jsonEncode(document);
    final report = _assess(document);
    // Division by zero is valid expression syntax but not a valid evaluated
    // state value. Intake must not ask initialPreview or run this rule.
    expect(report.findings, isEmpty);
    expect(report.verdict, TavernImportVerdict.usable);
    expect(report.counts['stateRules'], 1);
    expect(report.counts['macroOccurrences'], 0);
    expect(report.counts['scripts'], 0);
    expect(report.renderLevel, 0);
    expect(jsonEncode(document), before);
  });

  test('state-shaped metadata in other import kinds remains outside the character state contract', () {
    final extensions = <String, Object?>{
      'dshgo': {
        'state': {'schema': null},
      },
    };
    for (final entry in <TavernImportKind, Map<String, Object?>>{
      TavernImportKind.preset: {'prompts': <Object?>[], 'extensions': extensions},
      TavernImportKind.regex: {'id': 'r', 'findRegex': 'a', 'replaceString': '', 'extensions': extensions},
      TavernImportKind.lorebook: {'entries': <String, Object?>{}, 'extensions': extensions},
    }.entries) {
      final report = assessImport(kind: entry.key, document: entry.value, checkedAt: _at);
      expect(report.counts.keys.any((key) => key.startsWith('state')), isFalse);
      expect(report.findings.any((issue) => issue.code == 'schema_shape'), isFalse);
    }
  });

  test('actual card import persists definition findings through recheck export and reopening', () async {
    final h = await _open();
    final dshgo = <String, Object?>{
      'v': 1,
      'state': {
        'schema': {
          'type': 'object',
          'properties': {
            'n': {'type': 'integer', 'x-dsh-step': -1},
            'meta': {
              'type': 'string',
              'x-vendor': {
                'keep': [null, false],
              },
            },
          },
        },
      },
    };
    final source = _cardBytes(dshgo);
    final card = await h.engine.importCard(source);
    final report = (await h.engine.readImportReport(TavernImportKind.character, card.id))!;
    expect(report.verdict, TavernImportVerdict.partial);
    expect(report.findings.map((issue) => issue.code), ['schema_definition', 'schema_unknown']);
    expect(report.counts['stateDefinitions'], 1);
    final current = File('${h.directory.path}/characters/${card.id}/card.json');
    final before = await current.readAsBytes();
    expect(await File('${h.directory.path}/characters/${card.id}/original.json').readAsBytes(), source);
    expect(_databaseRows(h, 'chats'), isEmpty);
    expect(_databaseRows(h, 'agent_runs'), isEmpty);
    await h.reopen();
    expect((await h.engine.readImportReport(TavernImportKind.character, card.id))!.toJson(), report.toJson());
    h.at = h.at.add(const Duration(days: 1));
    final fresh = await h.engine.recheckImport(TavernImportKind.character, card.id);
    expect(fresh.checkedAt, h.at);
    expect(fresh.fingerprint, report.fingerprint);
    expect(fresh.findings.map((issue) => issue.toJson()), report.findings.map((issue) => issue.toJson()));
    expect(fresh.stale, isFalse);
    expect(await current.readAsBytes(), before);
    final exported = const CardCodec().decode(await h.engine.exportCard(card.id, format: TavernCardFormat.json));
    expect((exported.data['extensions']! as Map<String, Object?>)['dshgo'], dshgo);
    expect(exported.json.containsKey('importReport'), isFalse);
    expect(h.engine.globalVariables, isEmpty);
    expect(h.model.calls, 0);
  });

  test('dangerous derive and once effects are inert during import and recheck of an existing chat', () async {
    final h = await _open();
    final card = await h.engine.importCard(_cardBytes({'state': _dangerousDefinition()}));
    final report = (await h.engine.readImportReport(TavernImportKind.character, card.id))!;
    expect(report.findings, isEmpty);
    expect(_databaseRows(h, 'chats'), isEmpty);
    expect(_databaseRows(h, 'nodes'), isEmpty);
    expect(_databaseRows(h, 'agent_runs'), isEmpty);
    final saved = <String, Object?>{
      'variables': {'local': 3},
      'messageVariables': {
        'stat_data': {'keep': 7},
      },
      'dshgoStateRuntime': {
        'version': 99,
        'firedRules': null,
        'future': {'keep': true},
      },
    };
    final document = StChatDocument(
      fileName: 'existing.jsonl',
      header: {
        'user_name': 'User',
        'character_name': 'Guide',
        'chat_metadata': {'variables': saved['variables']},
      },
      messages: [
        {
          'name': 'Guide',
          'is_user': false,
          'is_system': false,
          'mes': 'existing',
          'send_date': _at.toIso8601String(),
          'extra': {
            'dshgo': {'tavernState': saved},
          },
        },
      ],
    );
    final chatId = (await h.engine.importChats(card.id, [
      TavernChatFile(fileName: document.fileName, bytes: document.encode()),
    ])).chatIds.single;
    final before = _chatSnapshot(h);
    final state = _savedState(h, chatId);
    expect(state['messageVariables'], saved['messageVariables']);
    expect(state['dshgoStateRuntime'], saved['dshgoStateRuntime']);
    expect((state['messageVariables']! as Map<String, Object?>).containsKey('dshgo'), isFalse);
    h.at = h.at.add(const Duration(days: 1));
    final fresh = await h.engine.recheckImport(TavernImportKind.character, card.id);
    expect(fresh.findings, isEmpty);
    expect(_chatSnapshot(h), before);
    await h.reopen();
    expect((await h.engine.readImportReport(TavernImportKind.character, card.id))!.toJson(), fresh.toJson());
    expect(_chatSnapshot(h), before);
    expect(_databaseRows(h, 'agent_runs'), isEmpty);
    expect(h.engine.globalVariables, isEmpty);
    expect(h.model.calls, 0);
  });
}

final _at = DateTime.utc(2026, 11, 10, 12);

Map<String, Object?> _document(Map<String, Object?> dshgo) => {
  'data': {
    'first_mes': 'Hello',
    'extensions': {'dshgo': dshgo},
  },
};

TavernImportReport _assess(Map<String, Object?> document, {String path = r'$'}) =>
    assessImport(kind: TavernImportKind.character, document: document, checkedAt: _at, path: path);

Map<String, Object?> _withoutFingerprint(TavernImportReport report) => report.toJson()..remove('fingerprint');

Map<String, Object?> _dangerousDefinition() => {
  'schema': {
    'type': 'object',
    'properties': {
      'n': {
        'type': 'number',
        'default': 0,
        'x-dsh-derive': {
          '/': [1, 0],
        },
      },
    },
  },
  'init': {'n': 5},
  'summary': '<script>doNotRun()</script>{{banned::literal}}{{setglobalvar::intake-ran::yes}}',
  'rules': [
    {
      'id': 'once',
      'when': true,
      'once': true,
      'do': [
        {
          'type': 'state',
          'ops': [
            {'op': 'set', 'path': '/n', 'value': 9, 'why': 'must not execute'},
          ],
        },
        {'type': 'prompt', 'text': '{{setglobalvar::intake-ran::yes}}'},
        {'type': 'notice', 'text': 'MUST_NOT_FIRE'},
      ],
    },
  ],
};

Uint8List _cardBytes(Map<String, Object?> dshgo) {
  final card = jsonDecode(utf8.decode(t24Card())) as Map<String, Object?>;
  (card['data']! as Map<String, Object?>)['extensions'] = {'dshgo': dshgo};
  return Uint8List.fromList(utf8.encode(jsonEncode(card)));
}

Future<_Harness> _open() async {
  final h = _Harness(await Directory.systemTemp.createTemp('t17-import-state-'));
  try {
    await h.open();
  } catch (_) {
    await h.directory.delete(recursive: true);
    rethrow;
  }
  addTearDown(() async {
    await h.engine.close();
    await h.directory.delete(recursive: true);
  });
  return h;
}

class _Harness {
  _Harness(this.directory);
  final Directory directory;
  final model = _NoModel();
  DateTime at = _at;
  late TavernEngine engine;
  Future<void> open() async {
    engine = await TavernEngine.openDirectory(directory, modelClient: model, clock: () => at);
  }

  Future<void> reopen() async {
    await engine.close();
    await open();
  }
}

class _NoModel extends TavernModelClient {
  int calls = 0;
  @override
  Stream<ModelDelta> generate({
    required TavernModelConfig config,
    required Map<String, Object?> body,
    required ModelCancellation cancellation,
    void Function(int attempt)? onRequestStarted,
  }) {
    calls++;
    throw StateError('State import inspection must not invoke a model.');
  }
}

T _withDatabase<T>(_Harness h, T Function(Database database) action) {
  final database = sqlite3.open('${h.directory.path}/tavern.sqlite3');
  try {
    return action(database);
  } finally {
    database.close();
  }
}

List<Map<String, Object?>> _databaseRows(_Harness h, String table) => _withDatabase(
  h,
  (database) => [for (final row in database.select('SELECT * FROM $table ORDER BY id')) Map<String, Object?>.from(row)],
);

Map<String, Object?> _chatSnapshot(_Harness h) => {
  for (final table in ['chats', 'nodes', 'agent_runs']) table: _databaseRows(h, table),
};

Map<String, Object?> _savedState(_Harness h, String chatId) => _withDatabase(h, (database) {
  final row = database.select('SELECT n.extra FROM nodes n JOIN chats c ON c.current_leaf_id = n.id WHERE c.id = ?', [
    chatId,
  ]).single;
  final extra = jsonDecode(row['extra']! as String) as Map<String, Object?>;
  final own = extra['dshgo']! as Map<String, Object?>;
  return own['tavernState']! as Map<String, Object?>;
});

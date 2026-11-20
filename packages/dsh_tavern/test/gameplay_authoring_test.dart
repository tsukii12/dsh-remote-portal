import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import 'p2_script_generation_test_support.dart';

final _at = DateTime.utc(2026, 11, 12, 5);
const _deadline = Duration(seconds: 10);

void main() {
  test('preview seals an empty binding vector and uses the same adopted pack prompt as native send', () async {
    final h = await generationFixture();
    final character = await h.card(
      'Guide',
      greeting: 'hello',
      description: 'LIVE_DESCRIPTION',
      extensions: {
        'dshgo': {'v': 1, 'state': _state()},
      },
    );
    final chat = await h.engine.createChat(character);
    await h.engine.putLorebook('capture-gate', _book());
    await h.engine.bindLorebooks(['capture-gate']);
    final ref = await _install(h, 'preview-pack', increment: 1, prompt: 'PACK_ONCE_LITERAL');
    final base = await h.engine.createAuthoringDraft([_character(character)]);
    final draft = await h.engine.editAuthoringDraft(
      base.id,
      draftRevision: base.draftRevision,
      changes: [
        TavernAuthoringChange(
          id: 'description',
          physicalResourceId: 'character:$character',
          path: '/data/description',
          operation: TavernAuthoringChangeKind.set,
          value: 'CANDIDATE_DESCRIPTION',
        ),
      ],
    );
    final scope = TavernPackScopeTarget(kind: TavernGameplayScope.character, targetId: character);
    final empty = await h.engine.readGameplayBindings(scope);
    expect(empty.token.revision, 0);
    expect(empty.bindings, isEmpty);
    late TavernPackBindingReceipt bound;
    final gate = _ReadGate();
    await _withReadGate(File('${h.root.path}/lorebooks/capture-gate.json'), gate, () async {
      final task = h.engine.previewAuthoringPrompt(_previewRequest(draft, chat, 'zero-vector'));
      try {
        await Future.any<void>([
          gate.entered.future,
          task.result.then<void>((_) => throw TestFailure('Preview ended before its actual book read.')),
        ]).timeout(_deadline);
        bound = await h.engine.updateGameplayBindings(
          scope,
          expected: empty.token,
          operationId: 'activate-first-preview-pack',
          edits: [TavernPackBindingCreate(clientKey: 'rule', packRef: ref)],
        );
        final afterIntent = _rows(h);
        gate.release();
        final preview = await task.result.timeout(_deadline);
        expect(preview.status, TavernAuthoringPreviewStatus.conflict);
        expect(preview.assembly, isNull);
        expect(preview.issues.any((issue) => issue.type == 'capture_conflict'), isTrue);
        expect(_rows(h), afterIntent);
      } finally {
        gate.release();
        await task.cancel();
      }
    });
    h.expectNoGeneration();

    // A real completed turn, rather than fabricated ledger JSON, creates the
    // pending rule prompt and the binding's once fact.
    h.reply('FIRST_NATIVE_REPLY');
    final first = await h.engine.send(chat, '').toList();
    expect(first.whereType<TavernTurnFailed>(), isEmpty);
    final saved = await _saved(h.engine, chat);
    expect(scriptMap(saved['messageVariables'])['dshgo'], {'n': 1});
    final binding = bound.createdBindings['rule']!;
    expect(scriptMap(scriptMap(scriptMap(saved['dshgoPackRuntime'])['bindings'])[binding])['rules'], ['once']);
    expect(
      (scriptMap(saved['dshgoStateRuntime'])['pendingPrompts']! as List<Object?>).map(scriptMap).single['text'],
      'PACK_ONCE_LITERAL',
    );
    final database = _rows(h);
    final files = await _files(h.root);
    final requestCount = h.requests.length;
    final preview = await h.engine
        .previewAuthoringPrompt(_previewRequest(draft, chat, 'same-pack-body', text: 'NEXT'))
        .result
        .timeout(_deadline);
    expect(preview.status, TavernAuthoringPreviewStatus.complete);
    expect(scriptMap(preview.origin['gameplay'])['effectiveConfigId'], isA<String>());
    final prompt = _promptText(preview.assembly!.body);
    expect(prompt, contains('CANDIDATE_DESCRIPTION'));
    expect(prompt, isNot(contains('LIVE_DESCRIPTION')));
    expect('PACK_ONCE_LITERAL'.allMatches(prompt), hasLength(1));
    expect(_rows(h), database);
    expect(await _files(h.root), files);
    expect(h.requests, hasLength(requestCount));

    final applied = await h.engine.applyAuthoringChanges(
      draft.id,
      draftRevision: draft.draftRevision,
      physicalResourceId: 'character:$character',
      changeIds: ['description'],
      expectedAuthorityRevision: base.sources.single.authorityRevision!,
      operationId: 'apply-preview-description',
    );
    expect(applied.committed, isTrue);
    h.reply('SECOND_NATIVE_REPLY');
    final second = await h.engine.send(chat, 'NEXT').toList();
    expect(second.whereType<TavernTurnFailed>(), isEmpty);
    expect((await h.engine.inspectTurn(chat))!.prompt!.body, preview.assembly!.body);
    final after = await _saved(h.engine, chat);
    expect(scriptMap(after['messageVariables'])['dshgo'], {'n': 1});
    expect(scriptMap(after['dshgoStateRuntime'])['pendingPrompts'], isEmpty);
    expect(scriptMap(scriptMap(scriptMap(after['dshgoPackRuntime'])['bindings'])[binding])['rules'], ['once']);
  });

  test('simulation copies only its real binding closure into a new domain and keeps missing history missing', () async {
    final h = await generationFixture();
    final character = await h.card(
      'Simulation',
      greeting: 'HISTORICAL_GREETING',
      extensions: {
        'dshgo': {'v': 1, 'state': _state()},
      },
    );
    final globalRef = await _install(h, 'global-simulation', increment: 1, prompt: 'GLOBAL_PACK_PROMPT');
    final characterRef = await _install(h, 'character-simulation', increment: 10, prompt: 'CHARACTER_PACK_PROMPT');
    const global = TavernPackScopeTarget(kind: TavernGameplayScope.global);
    final characterScope = TavernPackScopeTarget(kind: TavernGameplayScope.character, targetId: character);
    final emptyGlobal = await h.engine.readGameplayBindings(global);
    final globalBinding = await h.engine.updateGameplayBindings(
      global,
      expected: emptyGlobal.token,
      operationId: 'bind-simulation-global',
      edits: [TavernPackBindingCreate(clientKey: 'global', packRef: globalRef)],
    );
    final emptyCharacter = await h.engine.readGameplayBindings(characterScope);
    final characterBinding = await h.engine.updateGameplayBindings(
      characterScope,
      expected: emptyCharacter.token,
      operationId: 'bind-simulation-character',
      edits: [TavernPackBindingCreate(clientKey: 'character', packRef: characterRef)],
    );
    final characterBindingId = characterBinding.createdBindings['character']!;
    final reset = await h.engine.updateGameplayBindings(
      characterScope,
      expected: characterBinding.snapshot.token,
      operationId: 'reset-simulation-character',
      edits: [TavernPackBindingResetOnce(bindingId: characterBindingId)],
    );
    expect(reset.snapshot.bindings.single.onceEpoch, 2);
    final chat = await h.engine.createChat(character);
    final saved = await _saved(h.engine, chat);
    final historicalId = saved['dshgoPackDefinitionConfigId']! as String;
    final historical = h.inspect(
      (db) => Map<String, Object?>.from(
        db.select('SELECT * FROM gameplay_effective_configs WHERE config_id = ?', [historicalId]).single,
      ),
    );
    final draft = await h.engine.createAuthoringDraft([_character(character)]);
    final database = _rows(h);
    final files = await _files(h.root);
    final liveDomain = globalBinding.snapshot.token.domainId;
    var randomCalls = 0;
    h.onRandom = () {
      randomCalls++;
    };

    await _withTemp((base) async {
      final first = generationJsonResponse(h, _completion('SIM_ONE', 5, 2));
      generationJsonResponse(h, _completion('SIM_TWO', 7, 3)).beforeResponse = () async {
        final root = base.listSync().whereType<Directory>().single;
        final db = sqlite3.open('${root.path}/tavern.sqlite3', mode: OpenMode.readOnly);
        try {
          final state = _stateFromExtra(
            db.select('SELECT extra FROM nodes WHERE text = ?', ['SIM_ONE']).single['extra'],
          );
          expect(scriptMap(state['messageVariables'])['dshgo'], {'n': 11});
          final bindings = scriptMap(scriptMap(state['dshgoPackRuntime'])['bindings']);
          expect(scriptMap(bindings[globalBinding.createdBindings['global']!])['onceEpoch'], 1);
          expect(scriptMap(bindings[characterBindingId])['onceEpoch'], 2);
          expect(scriptMap(bindings[globalBinding.createdBindings['global']!])['rules'], ['once']);
          expect(scriptMap(bindings[characterBindingId])['rules'], ['once']);
          final adoptedId = state['dshgoPackDefinitionConfigId']! as String;
          expect(adoptedId, isNot(historicalId));
          expect(
            db.select('SELECT config_id FROM gameplay_effective_configs WHERE config_id = ?', [adoptedId]),
            hasLength(1),
          );
        } finally {
          db.close();
        }
      };
      String? temporaryChat;
      first.beforeResponse = () async {
        final root = base.listSync().whereType<Directory>().single;
        final db = sqlite3.open('${root.path}/tavern.sqlite3', mode: OpenMode.readOnly);
        try {
          temporaryChat = db.select('SELECT id FROM chats').single['id']! as String;
          expect(temporaryChat, isNot(chat));
          for (final table in [
            'gameplay_packs',
            'gameplay_pack_versions',
            'gameplay_pack_files',
            'gameplay_scopes',
            'gameplay_bindings',
            'gameplay_source_ids',
          ]) {
            expect(
              [for (final row in db.select('SELECT * FROM "$table"')) Map<String, Object?>.from(row)],
              database[table],
              reason: table,
            );
          }
          expect(db.select('SELECT * FROM gameplay_operations'), isEmpty);
          expect(
            Map<String, Object?>.from(
              db.select('SELECT * FROM gameplay_effective_configs WHERE config_id = ?', [historicalId]).single,
            ),
            historical,
          );
          expect(db.select('SELECT text FROM nodes').any((row) => row['text'] == 'HISTORICAL_GREETING'), isFalse);
        } finally {
          db.close();
        }
      };
      final task = h.engine.simulateAuthoringDraft(
        _simulationRequest(draft, character, 'captured-packs', saved: saved, inputs: const ['ONE', 'TWO']),
      );
      try {
        final result = await task.result.timeout(_deadline);
        expect(result.status, TavernAuthoringSimulationStatus.completed);
        expect(result.turns.map((turn) => turn.message!.text), ['SIM_ONE', 'SIM_TWO']);
        expect(result.requests, hasLength(2));
        expect(result.requests.every((request) => request.attempts.length == 1), isTrue);
        final secondBody = _promptText(result.requests.last.body);
        expect('GLOBAL_PACK_PROMPT'.allMatches(secondBody), hasLength(1));
        expect('CHARACTER_PACK_PROMPT'.allMatches(secondBody), hasLength(1));
        final origin = scriptMap(result.origin['temporaryGameplay']);
        expect(origin['domainId'], isNot(liveDomain));
        expect(origin['originDomainId'], liveDomain);
        expect(origin['chatId'], temporaryChat);
        expect(scriptMap(result.origin['gameplay'])['domainId'], liveDomain);
        expect(scriptMap(result.origin['gameplay'])['historicalConfigId'], historicalId);
        final usage = scriptMap(result.usage['fields']);
        expect(scriptMap(usage['prompt_tokens'])['total'], 12);
        expect(scriptMap(usage['completion_tokens'])['total'], 5);
        expect(result.cleanup, {'rootCreated': true, 'closeConfirmed': true, 'removed': true});
        expect(base.listSync(), isEmpty);
      } finally {
        await task.cancel();
      }
    });
    expect(_rows(h), database);
    expect(await _files(h.root), files);
    expect(randomCalls, 0);

    // A foreign explanation ID is copied as an observed absence, never filled
    // with a current live row merely to make the temporary history readable.
    const missingId = 'foreign:configuration:not-present';
    final unresolved = {...saved, 'dshgoPackDefinitionConfigId': missingId};
    expect(
      h.inspect((db) => db.select('SELECT config_id FROM gameplay_effective_configs WHERE config_id = ?', [missingId])),
      isEmpty,
    );
    await _withTemp((base) async {
      generationJsonResponse(h, _completion('UNRESOLVED_HISTORY_REPLY', 4, 1)).beforeResponse = () async {
        final root = base.listSync().whereType<Directory>().single;
        final db = sqlite3.open('${root.path}/tavern.sqlite3', mode: OpenMode.readOnly);
        try {
          expect(
            db.select('SELECT config_id FROM gameplay_effective_configs WHERE config_id = ?', [missingId]),
            isEmpty,
          );
          final inherited = _stateFromExtra(
            db.select('SELECT extra FROM nodes WHERE text = ?', ['SAMPLE_HISTORY']).single['extra'],
          );
          expect(inherited['dshgoPackDefinitionConfigId'], missingId);
          expect(scriptMap(inherited['messageVariables'])['dshgo'], {'n': 0});
        } finally {
          db.close();
        }
      };
      final task = h.engine.simulateAuthoringDraft(
        _simulationRequest(draft, character, 'missing-history-config', saved: unresolved, inputs: const ['CHECK']),
      );
      try {
        final result = await task.result.timeout(_deadline);
        expect(result.status, TavernAuthoringSimulationStatus.completed);
        expect(scriptMap(result.origin['gameplay'])['historicalReferenced'], isTrue);
        expect(scriptMap(result.origin['gameplay'])['historicalConfigId'], isNull);
        expect(scriptMap(result.origin['gameplay'])['historicalIssues'], isNotEmpty);
        expect(result.requests, hasLength(1));
        expect(result.cleanup['removed'], isTrue);
        expect(base.listSync(), isEmpty);
      } finally {
        await task.cancel();
      }
    });
    expect(_rows(h), database);
    expect(await _files(h.root), files);
    expect(randomCalls, 0);
  });
}

ScriptJson _state() => {
  'schema': {
    'type': 'object',
    'required': ['n'],
    'additionalProperties': false,
    'properties': {
      'n': {'type': 'integer'},
    },
  },
  'init': {'n': 0},
};

Future<TavernPackVersionRef> _install(
  ScriptFixture h,
  String packId, {
  required int increment,
  required String prompt,
}) async {
  final manifest = <String, Object?>{
    'formatVersion': 1,
    'packId': packId,
    'packVersion': 'one',
    'resources': [
      {'localId': 'asset', 'kind': 'asset', 'path': 'assets/note.txt'},
    ],
    'dshgo': {
      'v': 1,
      'state': {
        'rules': [
          {
            'id': 'once',
            'when': true,
            'once': true,
            'do': [
              {
                'type': 'state',
                'ops': [
                  {'op': 'add', 'path': '/n', 'value': increment, 'why': 'pack once rule'},
                ],
              },
              {'type': 'prompt', 'text': prompt},
            ],
          },
        ],
      },
    },
  };
  final entries = <String, List<int>>{
    'pack.json': utf8.encode(jsonEncode(manifest)),
    'assets/note.txt': utf8.encode('$packId asset'),
    'undeclared.bin': [0, 128, 255],
  };
  final archive = Archive();
  for (final entry in entries.entries) {
    archive.addFile(ArchiveFile(entry.key, entry.value.length, entry.value));
  }
  return (await h.engine.importGameplayPack(Uint8List.fromList(ZipEncoder().encode(archive)))).ref;
}

TavernAuthoringTarget _character(String id) => TavernAuthoringTarget(kind: TavernAuthoringTargetKind.character, id: id);

TavernAuthoringPromptRequest _previewRequest(TavernAuthoringDraft draft, String chat, String id, {String text = 'Q'}) =>
    TavernAuthoringPromptRequest(
      requestId: id,
      draftId: draft.id,
      draftRevision: draft.draftRevision,
      changeIds: const ['description'],
      context: TavernAuthoringChatContext(chatId: chat),
      text: text,
      at: _at,
      seed: 41,
    );

TavernAuthoringSimulationRequest _simulationRequest(
  TavernAuthoringDraft draft,
  String character,
  String id, {
  required ScriptJson saved,
  required List<String> inputs,
}) => TavernAuthoringSimulationRequest(
  requestId: id,
  draftId: draft.id,
  draftRevision: draft.draftRevision,
  changeIds: const [],
  at: _at,
  seed: 41,
  userInputs: inputs,
  context: TavernAuthoringSampleContext(
    characterResourceId: 'character:$character',
    state: saved,
    history: const [TavernAuthoringSampleMessage(role: TavernRole.character, text: 'SAMPLE_HISTORY')],
  ),
);

ScriptJson _completion(String text, int prompt, int completion) => {
  'model': 'actual-reported',
  'choices': [
    {
      'index': 0,
      'message': {'role': 'assistant', 'content': text},
      'finish_reason': 'stop',
    },
  ],
  'usage': {'prompt_tokens': prompt, 'prompt_cache_hit_tokens': 0, 'completion_tokens': completion},
};

ScriptJson _book() => {
  'entries': {
    '0': {
      'uid': 0,
      'key': <String>[],
      'content': 'CAPTURE_BOOK',
      'constant': true,
      'position': 0,
      'useProbability': false,
    },
  },
};

String _promptText(ScriptJson body) =>
    (body['messages']! as List<Object?>).map(scriptMap).map((message) => message['content']).join('\n');

ScriptJson _stateFromExtra(Object? extra) =>
    scriptMap(scriptMap(scriptMap(jsonDecode(extra! as String))['dshgo'])['tavernState']);

Future<ScriptJson> _saved(TavernEngine engine, String chat) async {
  final files = await engine.exportChat(chat);
  final document = StChatDocument.decode(files.first.fileName, files.first.bytes);
  return scriptMap(scriptMap(scriptMap(document.messages.last['extra'])['dshgo'])['tavernState']);
}

ScriptJson _rows(ScriptFixture h) => h.inspect(
  (db) => {
    for (final table in db.select("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name"))
      table['name']! as String: [
        for (final row in db.select('SELECT * FROM "${(table['name']! as String).replaceAll('"', '""')}"'))
          Map<String, Object?>.from(row),
      ],
  },
);

Future<Map<String, List<int>>> _files(Directory root) async {
  final result = <String, List<int>>{};
  await for (final entity in root.list(recursive: true, followLinks: false)) {
    if (entity is! File) {
      continue;
    }
    final path = entity.path.substring(root.path.length + 1);
    if (const {'tavern.sqlite3', 'tavern.sqlite3-wal', 'tavern.sqlite3-shm'}.contains(path)) {
      continue;
    }
    result[path] = await entity.readAsBytes();
  }
  return result;
}

Future<void> _withTemp(Future<void> Function(Directory) body) async {
  final base = await Directory.systemTemp.createTemp('dsh-gameplay-simulation-test-');
  try {
    await IOOverrides.runZoned(() => body(base), getSystemTempDirectory: () => base);
  } finally {
    if (await base.exists()) {
      await base.delete(recursive: true);
    }
  }
}

Future<void> _withReadGate(File file, _ReadGate gate, Future<void> Function() body) async {
  final parent = Zone.current;
  final aliases = {file.absolute.uri, File(await file.resolveSymbolicLinks()).absolute.uri};
  try {
    await IOOverrides.runZoned(
      body,
      createFile: (path) {
        final real = parent.run(() => File(path));
        return aliases.contains(parent.run(() => real.absolute.uri)) ? _GatedFile(real, gate) : real;
      },
    );
  } finally {
    gate.release();
    if (gate.entered.isCompleted) {
      await gate.finished.future;
    }
  }
}

class _ReadGate {
  final entered = Completer<void>();
  final finished = Completer<void>();
  final _released = Completer<void>();
  void release() {
    if (!_released.isCompleted) {
      _released.complete();
    }
  }

  Future<T> read<T>(Future<T> Function() action) async {
    if (entered.isCompleted) {
      return action();
    }
    entered.complete();
    try {
      await _released.future;
      return await action();
    } finally {
      finished.complete();
    }
  }
}

class _GatedFile implements File {
  _GatedFile(this.real, this.gate);
  final File real;
  final _ReadGate gate;
  @override
  String get path => real.path;
  @override
  Uri get uri => real.uri;
  @override
  bool get isAbsolute => real.isAbsolute;
  @override
  File get absolute => real.absolute;
  @override
  Directory get parent => real.parent;
  @override
  Future<bool> exists() => real.exists();
  @override
  bool existsSync() => real.existsSync();
  @override
  Future<Uint8List> readAsBytes() => gate.read(real.readAsBytes);
  @override
  Future<String> readAsString({Encoding encoding = utf8}) => gate.read(() => real.readAsString(encoding: encoding));
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

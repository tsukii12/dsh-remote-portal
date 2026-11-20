import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import 'p2_script_generation_test_support.dart';

final _at = DateTime.utc(2026, 11, 14, 8);
const _deadline = Duration(seconds: 10);
const _regexTarget = TavernAuthoringTarget(kind: TavernAuthoringTargetKind.regexLibrary, id: 'global');

// Real resource files, SQLite, fresh-open loaders, native send/director and
// production HTTP encoding/decoding. Only HTTP peers and actual waits below
// are controlled; no fake model events, temporary engine or proof is used.
void main() {
  test('two actual turns preserve resource identities and fresh-file diagnostics without changing live data', () async {
    final h = await generationFixture();
    final character = await h.card(
      'Guide',
      greeting: 'NEVER_GREETING {{setglobalvar::outside::bad}}',
      description: 'CARD_KEEP {{random::red::blue}}',
    );
    await h.engine.addCharacterBookEntry(character, {
      'keys': <String>[],
      'content': 'EMBEDDED_DETAIL',
      'enabled': true,
      'constant': true,
      'insertion_order': 100,
      'extensions': {'position': 0},
    });
    final persona = await h.engine.createPersona(name: 'Reader', description: 'PERSONA_DETAIL');
    await h.engine.setDefaultPersona(persona.id);
    for (final name in ['global', 'chat', 'character', 'persona']) {
      await h.engine.putLorebook(
        name,
        _book(name == 'persona' ? 'PERSONA_BOOK_DETAIL' : '${name.toUpperCase()}_DETAIL'),
      );
    }
    await h.engine.bindLorebooks(['global', 'missing']);
    await h.engine.bindLorebooks(['character'], source: WorldInfoSource.character, characterId: character);
    await h.engine.bindLorebooks(['persona'], source: WorldInfoSource.persona, personaId: persona.id);
    final globalFile = File('${h.root.path}/lorebooks/global.json');
    await globalFile.writeAsString(
      '\ufeff${jsonEncode({
        'format': 'dshgo-lorebook',
        'version': 1,
        'stWorldName': 'OriginalGlobalName',
        'book': _book('GLOBAL_BASE'),
        'unknownEnvelope': [null, true],
      })}',
    );
    final preset = (await h.engine.importPreset(
      jsonEncode(scriptPreset(main: 'PRESET_IDENTITY {{getvar::step}} {{getglobalvar::scratch}}').raw),
    )).preset;
    final unused = (await h.engine.importPreset(jsonEncode(scriptPreset().raw))).preset;
    await h.engine.setDefaultPreset(unused.id);
    h.inspect(
      (db) => db.execute('UPDATE presets SET raw_json = ? WHERE id = ?', ['not-json', unused.id]),
      writable: true,
    );
    await h.engine.importRegexScripts(jsonEncode(_regex()));
    final regexFile = File('${h.root.path}/regex-library.json');
    final regex = scriptMap(jsonDecode(await regexFile.readAsString()));
    scriptMap((regex['scripts']! as List<Object?>).single)['diagnostics'] = [
      const TavernRegexDiagnostic(
        path: 'findRegex',
        status: TavernRegexCompatibility.incompatible,
        code: 'saved_decision',
        message: 'An existing saved decision, not a new compilation.',
      ).toJson(),
    ];
    final regexBytes = utf8.encode('\ufeff${jsonEncode(regex)}');
    await regexFile.writeAsBytes(regexBytes);
    expect(
      (await h.engine.listRegexScripts()).single.compatible,
      isTrue,
      reason: 'The deliberately older live cache is distinct from the captured fresh-open file.',
    );
    final cardFile = File('${h.root.path}/characters/$character/card.json');
    final cardBytes = utf8.encode('\ufeff${await cardFile.readAsString()}');
    await cardFile.writeAsBytes(cardBytes);
    final identityFile = File('${cardFile.parent.path}/library.json');
    final identity = scriptMap(jsonDecode(await identityFile.readAsString()))..['resources'] = ['notes.txt'];
    final identityBytes = utf8.encode('\ufeff${jsonEncode(identity)}');
    await identityFile.writeAsBytes(identityBytes);
    final media = File('${cardFile.parent.path}/resources/notes.txt');
    await media.parent.create(recursive: true);
    await media.writeAsString('Original media bytes.');
    final draft0 = await h.engine.createAuthoringDraft([
      _character(character),
      const TavernAuthoringTarget(kind: TavernAuthoringTargetKind.lorebook, id: 'global'),
      TavernAuthoringTarget(kind: TavernAuthoringTargetKind.preset, id: preset.id),
      _regexTarget,
    ]);
    final draft = await h.engine.editAuthoringDraft(
      draft0.id,
      draftRevision: draft0.draftRevision,
      changes: [
        const TavernAuthoringChange(
          id: 'book',
          physicalResourceId: 'lorebook:global',
          path: '/book/entries/0/content',
          operation: TavernAuthoringChangeKind.set,
          value: 'GLOBAL_SELECTED',
        ),
      ],
    );
    final database = _databaseState(h), files = await _persistentFiles(h.root);
    final globals = h.engine.globalVariables;
    var outerRandom = 0;
    h.onRandom = () {
      outerRandom++;
    };
    await _inTemp((base) async {
      final first = generationJsonResponse(h, _completion('FIRST_ACTUAL_REPLY', prompt: 10, completion: 2));
      generationJsonResponse(h, _completion('SECOND_ACTUAL_REPLY', prompt: 15, completion: 3));
      first.beforeResponse = () async {
        final root = base.listSync().whereType<Directory>().single;
        expect(await File('${root.path}/characters/$character/card.json').readAsBytes(), cardBytes);
        expect(await File('${root.path}/characters/$character/library.json').readAsBytes(), identityBytes);
        expect(
          await File('${root.path}/characters/$character/resources/notes.txt').readAsBytes(),
          await media.readAsBytes(),
        );
        expect(await File('${root.path}/regex-library.json').readAsBytes(), regexBytes);
        final global = scriptMap(jsonDecode(await File('${root.path}/lorebooks/global.json').readAsString()));
        expect(global['stWorldName'], 'OriginalGlobalName');
        expect(global['unknownEnvelope'], [null, true]);
        final db = sqlite3.open('${root.path}/tavern.sqlite3', mode: OpenMode.readOnly);
        try {
          final chat = db.select('SELECT character_id, persona_id, preset_id FROM chats').single;
          expect(chat['character_id'], character);
          expect(chat['persona_id'], persona.id);
          expect(chat['preset_id'], preset.id);
          expect(db.select('SELECT id FROM presets').map((row) => row['id']), unorderedEquals([preset.id, unused.id]));
          expect(db.select('SELECT raw_json FROM presets WHERE id = ?', [unused.id]).single['raw_json'], 'not-json');
          expect(
            db.select('SELECT text FROM nodes').any((row) => (row['text']! as String).contains('NEVER_GREETING')),
            isFalse,
          );
          expect(db.select('SELECT COUNT(*) AS n FROM nodes').single['n'], 3);
        } finally {
          db.close();
        }
      };
      final task = h.engine.simulateAuthoringDraft(
        _request(
          draft,
          character,
          'resources',
          changes: ['book'],
          inputs: ['{{setglobalvar::scratch::temporary}}QUESTION_ONE', 'QUESTION_TWO'],
          context: TavernAuthoringSampleContext(
            characterResourceId: 'character:$character',
            presetId: preset.id,
            personaId: persona.id,
            variables: const {'step': 0},
            settings: const {
              'lorebooks': {
                'chat': ['chat'],
              },
            },
            history: const [
              TavernAuthoringSampleMessage(role: TavernRole.character, text: 'ROOT_KEEP {{incvar::step}}'),
            ],
          ),
        ),
      );
      addTearDown(task.cancel);
      final result = await task.result.timeout(_deadline);
      expect(result.status, TavernAuthoringSimulationStatus.completed);
      expect(result.turns.map((turn) => turn.message!.text), ['FIRST_ACTUAL_REPLY', 'SECOND_ACTUAL_REPLY']);
      expect(result.requests.map((request) => request.turnIndex), [1, 2]);
      expect(result.requests.every((request) => request.attempts.length == 1 && request.attempts.single == 0), isTrue);
      expect(result.requests.every((request) => request.responseComplete), isTrue);
      final text = _promptText(result.requests.first.body);
      for (final expected in [
        'CARD_KEEP',
        'ROOT_KEEP',
        'PRESET_IDENTITY',
        'PERSONA_DETAIL',
        'EMBEDDED_DETAIL',
        'GLOBAL_SELECTED',
        'CHAT_DETAIL',
        'CHARACTER_DETAIL',
        'PERSONA_BOOK_DETAIL',
      ]) {
        expect(text, contains(expected));
      }
      expect(text, isNot(contains('MUST_NOT_RECOMPILE')));
      expect(text, isNot(contains('GLOBAL_BASE')));
      expect(_promptText(result.requests.last.body), contains('FIRST_ACTUAL_REPLY'));
      final fields = scriptMap(result.usage['fields']);
      expect(scriptMap(fields['prompt_tokens'])['total'], 25);
      expect(scriptMap(fields['completion_tokens'])['total'], 5);
      expect(scriptMap(fields['cache_hit_tokens'])['total'], 0);
      expect(result.turns.every((turn) => turn.toolTurn?['status'] == 'completed'), isTrue);
      expect(result.origin['semantics'], 'captured-file-fresh-open');
      expect(result.cleanup, {'rootCreated': true, 'closeConfirmed': true, 'removed': true});
      expect(base.listSync(), isEmpty);
      result.requests.first.body.clear();
      expect(task.view.requests.first.body, isNotEmpty);
    });
    expect(_databaseState(h), database);
    expect(await _persistentFiles(h.root), files);
    expect(h.engine.globalVariables, globals);
    expect(outerRandom, 0);
    expect(h.requests, hasLength(2));
    expect(h.keyReads, 2);
  });

  test(
    'a successful main turn waits for its actual auxiliary HTTP helper and preserves its usage and stored result',
    () async {
      final h = await generationFixture();
      final character = await h.card('Helper');
      await h.engine.setSettings({
        'director': {'enabled': true, 'every': 1},
      });
      final draft = await h.engine.createAuthoringDraft([_character(character)]);
      h.engine.configure(
        TavernModelConfig(
          apiKey: () => throw StateError('The main supplier is not selected.'),
          model: 'not-selected-main',
          deepseek: false,
          auxiliary: TavernModelConfig(
            apiKey: () async => 'helper-key',
            baseUrl: 'https://aux-sim.invalid/v1',
            model: 'actual-auxiliary',
            deepseek: false,
          ),
        ),
      );
      final database = _databaseState(h), files = await _persistentFiles(h.root);
      await _inTemp((base) async {
        generationJsonResponse(h, _completion('MAIN_IS_COMMITTED', prompt: 10, completion: 1));
        final release = Completer<void>();
        final helper = generationJsonResponse(h, _helperCompletion());
        helper.beforeResponse = () => release.future;
        final task = h.engine.simulateAuthoringDraft(
          _request(draft, character, 'helper', role: TavernAuthoringModelRole.auxiliary),
        );
        var completed = false;
        unawaited(
          task.result.then<void>(
            (_) {
              completed = true;
            },
            onError: (Object _, StackTrace _) {
              completed = true;
            },
          ),
        );
        try {
          await _signal(task, helper.seen.future);
          await Future<void>(() {});
          expect(completed, isFalse);
          expect(task.view.turns.single.status, TavernAuthoringSimulationStatus.completed);
          expect(task.view.requests, hasLength(2));
          expect(h.requests.every((request) => request.body['model'] == 'actual-auxiliary'), isTrue);
          release.complete();
          final result = await task.result.timeout(_deadline);
          expect(result.status, TavernAuthoringSimulationStatus.completed);
          expect(result.origin['model'], 'actual-auxiliary');
          expect(result.origin['modelRole'], 'auxiliary');
          expect(result.requests.map((request) => request.model['role']), ['main', 'helper']);
          final helperResult = result.turns.single.helpers.singleWhere((row) => row['kind'] == 'director.success');
          expect(helperResult['persisted'], isTrue);
          expect(helperResult['scope'], 'simulation');
          expect(scriptMap(scriptMap(helperResult['result'])['output'])['beat'], 'A real helper beat.');
          expect(result.turns.single.helpers.where((row) => row['kind'] == 'director.tick'), hasLength(1));
          expect(scriptMap(scriptMap(result.usage['fields'])['prompt_tokens'])['total'], 30);
          expect(h.requests, hasLength(2));
          expect(base.listSync(), isEmpty);
        } finally {
          if (!release.isCompleted) {
            release.complete();
          }
          await task.cancel();
        }
      });
      expect(_databaseState(h), database);
      expect(await _persistentFiles(h.root), files);
    },
  );

  test(
    'cancel owns late key completion and real SSE cancellation before backup close or root removal can finish',
    () async {
      final h = await generationFixture();
      final character = await h.card('Cancel');
      final draft = await h.engine.createAuthoringDraft([_character(character)]);
      final engine = h.engine;
      await _inTemp((base) async {
        final keyEntered = Completer<void>(), key = Completer<String?>();
        engine.configure(
          TavernModelConfig(
            apiKey: () {
              keyEntered.complete();
              return key.future;
            },
            deepseek: false,
          ),
        );
        final waitingKey = engine.simulateAuthoringDraft(_request(draft, character, 'key-cancel'));
        var keyResultDone = false, keyCancelDone = false;
        unawaited(
          waitingKey.result.then<void>(
            (_) {
              keyResultDone = true;
            },
            onError: (Object _, StackTrace _) {
              keyResultDone = true;
            },
          ),
        );
        Future<void>? cancellingKey;
        try {
          await _signal(waitingKey, keyEntered.future);
          cancellingKey = waitingKey.cancel().then<void>((_) {
            keyCancelDone = true;
          });
          await Future<void>(() {});
          expect((keyResultDone, keyCancelDone), (false, false));
          expect(base.listSync(), isNotEmpty);
          key.completeError(StateError('The original supplier ended late.'));
          await cancellingKey.timeout(_deadline);
          final stopped = await waitingKey.result;
          expect(stopped.status, TavernAuthoringSimulationStatus.cancelled);
          expect(stopped.issues.any((issue) => issue.type == 'key_supplier_failed'), isTrue);
          expect(stopped.cleanup['removed'], isTrue);
          expect(h.requests, isEmpty);
        } finally {
          final keyDrain = cancellingKey ?? waitingKey.cancel();
          if (!key.isCompleted) {
            key.complete(null);
          }
          await keyDrain;
        }
        engine.configure(h.config);
        await engine.setPreset(scriptPreset(streaming: true));
        final plan = ScriptResponsePlan.json(const {});
        h.pending.add(plan);
        h.plans.add(plan);
        final cancelEntered = Completer<void>(), releaseCancel = Completer<void>();
        plan.source = StreamController<List<int>>(
          sync: true,
          onListen: () {
            plan.listening.complete();
          },
          onCancel: () {
            cancelEntered.complete();
            return releaseCancel.future;
          },
        );
        final task = engine.simulateAuthoringDraft(
          _request(draft, character, 'body-cancel', inputs: ['Q', 'NEVER_SEND']),
        );
        final archive = File(
          '${base.parent.path}/${base.uri.pathSegments.where((value) => value.isNotEmpty).last}-backup.zip',
        );
        addTearDown(() async {
          if (await archive.exists()) {
            await archive.delete();
          }
        });
        var resultDone = false, cancelDone = false, backupDone = false, closeDone = false;
        unawaited(
          task.result.then<void>(
            (_) {
              resultDone = true;
            },
            onError: (Object _, StackTrace _) {
              resultDone = true;
            },
          ),
        );
        Future<void>? bodyClose, backup, cancelling, closing;
        try {
          await _signal(task, plan.listening.future);
          plan.delta('ACTUAL_PARTIAL');
          generationSse(plan, {
            'choices': <Object?>[],
            'usage': {'prompt_tokens': 7, 'prompt_cache_hit_tokens': 0, 'completion_tokens': 1},
          });
          await Future<void>(() {});
          backup = engine.backup(archive.path).then<void>((_) {
            backupDone = true;
          });
          cancelling = task.cancel().then<void>((_) {
            cancelDone = true;
          });
          closing = h.close().then<void>((_) {
            closeDone = true;
          });
          await Future<void>(() {});
          expect((resultDone, cancelDone, backupDone, closeDone), (false, false, false, false));
          plan.delta('AFTER_CANCELLATION');
          bodyClose = plan.source!.close();
          await cancelEntered.future.timeout(_deadline);
          expect((resultDone, cancelDone, backupDone, closeDone), (false, false, false, false));
          expect(base.listSync(), isNotEmpty);
          releaseCancel.complete();
          await Future.wait([cancelling, backup, closing, bodyClose]).timeout(_deadline);
          final result = await task.result;
          expect(result.status, TavernAuthoringSimulationStatus.cancelled);
          expect(result.turns, hasLength(1));
          expect(result.requests, hasLength(1));
          expect(result.requests.single.attempts, [0]);
          expect(result.requests.single.text, 'ACTUAL_PARTIAL');
          expect(result.requests.single.usage['reportedUsageObserved'], isTrue);
          expect(result.turns.single.toolTurn, isNotNull);
          expect(h.requests, hasLength(1));
          expect(result.cleanup['removed'], isTrue);
          expect(base.listSync(), isEmpty);
          expect(await archive.exists(), isTrue);
        } finally {
          final cancelDrain = cancelling ?? task.cancel();
          if (!releaseCancel.isCompleted) {
            releaseCancel.complete();
          }
          // dispose knows whether this real source was listened to; awaiting
          // close on an unused single-subscription controller would self-wait.
          await plan.dispose();
          final closeDrain = closing ?? h.close();
          await Future.wait<void>([?bodyClose, cancelDrain, ?backup, closeDrain]);
        }
      });
    },
  );

  test(
    'unsupported empty-history state creates no node and a real fresh-open failure preserves its original exception',
    () async {
      final h = await generationFixture(allowModel: false);
      final character = await h.card('Initialization');
      await h.engine.importRegexScripts(jsonEncode(_regex()));
      final baseDraft = await h.engine.createAuthoringDraft([_character(character), _regexTarget]);
      final draft = await h.engine.editAuthoringDraft(
        baseDraft.id,
        draftRevision: baseDraft.draftRevision,
        changes: [
          const TavernAuthoringChange(
            id: 'invalid-loader-record',
            physicalResourceId: 'regex-library',
            path: '/scripts/0/diagnostics',
            operation: TavernAuthoringChangeKind.set,
            value: 'not-a-list',
          ),
        ],
      );
      final database = _databaseState(h), files = await _persistentFiles(h.root);
      await _inTemp((base) async {
        final unsupported = await h.engine
            .simulateAuthoringDraft(
              _request(
                draft,
                character,
                'no-leaf',
                context: TavernAuthoringSampleContext(
                  characterResourceId: 'character:$character',
                  state: const {'saved': true},
                ),
              ),
            )
            .result;
        expect(unsupported.status, TavernAuthoringSimulationStatus.unsupported);
        expect(unsupported.issues.single.type, 'unsupported_simulation_state');
        expect(unsupported.requests, isEmpty);
        expect(unsupported.turns, isEmpty);
        expect(unsupported.cleanup['rootCreated'], isFalse);
        final task = h.engine.simulateAuthoringDraft(
          _request(draft, character, 'loader-failure', changes: ['invalid-loader-record']),
        );
        await expectLater(
          task.result.timeout(_deadline),
          throwsA(
            isA<FormatException>().having(
              (error) => error.message,
              'original loader message',
              'Invalid regex library record.',
            ),
          ),
        );
        await task.cancel();
        expect(task.view.status, TavernAuthoringSimulationStatus.failed);
        expect(task.view.requests, isEmpty);
        expect(task.view.cleanup, {'rootCreated': true, 'closeConfirmed': true, 'removed': true});
        expect(base.listSync(), isEmpty);
      });
      expect(_databaseState(h), database);
      expect(await _persistentFiles(h.root), files);
      h.expectNoGeneration();
    },
  );
}

TavernAuthoringTarget _character(String id) => TavernAuthoringTarget(kind: TavernAuthoringTargetKind.character, id: id);

TavernAuthoringSimulationRequest _request(
  TavernAuthoringDraft draft,
  String character,
  String id, {
  List<String> changes = const [],
  List<String> inputs = const ['Q'],
  TavernAuthoringSampleContext? context,
  TavernAuthoringModelRole role = TavernAuthoringModelRole.main,
}) => TavernAuthoringSimulationRequest(
  requestId: id,
  draftId: draft.id,
  draftRevision: draft.draftRevision,
  changeIds: changes,
  context: context ?? TavernAuthoringSampleContext(characterResourceId: 'character:$character'),
  userInputs: inputs,
  at: _at,
  seed: 41,
  modelRole: role,
);

Future<T> _signal<T>(TavernAuthoringSimulationTask task, Future<T> signal) => Future.any([
  signal,
  task.result.then<T>((_) => throw TestFailure('Simulation ended before the real fixture boundary.')),
]).timeout(_deadline);

Future<void> _inTemp(Future<void> Function(Directory) body) async {
  final base = await Directory.systemTemp.createTemp('dsh-simulation-test-');
  addTearDown(() async {
    if (await base.exists()) {
      await base.delete(recursive: true);
    }
  });
  await IOOverrides.runZoned(() => body(base), getSystemTempDirectory: () => base);
}

ScriptJson _completion(String text, {required int prompt, required int completion}) => {
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

ScriptJson _helperCompletion() => {
  'model': 'actual-helper-reported',
  'choices': [
    {
      'index': 0,
      'message': {
        'role': 'assistant',
        'content': null,
        'tool_calls': [
          {
            'id': 'real-helper-call',
            'type': 'function',
            'function': {
              'name': 'direct',
              'arguments': jsonEncode({
                'notes': 'Temporary planning.',
                'beat': 'A real helper beat.',
                'prefetch': <Object?>[],
                'events': <Object?>[],
                'suggestions': [
                  {'text': 'Look', 'risk': ''},
                  {'text': 'Wait', 'risk': ''},
                  {'text': 'Ask', 'risk': ''},
                ],
              }),
            },
          },
        ],
      },
      'finish_reason': 'tool_calls',
    },
  ],
  'usage': {'prompt_tokens': 20, 'prompt_cache_hit_tokens': 0, 'completion_tokens': 2},
};

ScriptJson _book(String content) => {
  'entries': {
    '0': {'uid': 0, 'key': <String>[], 'content': content, 'constant': true, 'position': 0, 'useProbability': false},
  },
};

ScriptJson _regex() => {
  'scriptName': 'Saved compatibility',
  'findRegex': '/KEEP/g',
  'replaceString': 'MUST_NOT_RECOMPILE',
  'trimStrings': <String>[],
  'placement': [2],
  'disabled': false,
  'markdownOnly': false,
  'promptOnly': true,
  'runOnEdit': false,
  'substituteRegex': 0,
};

String _promptText(ScriptJson body) =>
    (body['messages']! as List<Object?>).map(scriptMap).map((message) => message['content']).join('\n');

ScriptJson _databaseState(ScriptFixture h) => h.inspect((db) {
  final result = <String, Object?>{};
  for (final table in db.select("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")) {
    final name = table['name']! as String, quoted = name.replaceAll('"', '""');
    result[name] = [for (final row in db.select('SELECT * FROM "$quoted"')) Map<String, Object?>.from(row)];
  }
  return result;
});

Future<Map<String, List<int>>> _persistentFiles(Directory root) async {
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

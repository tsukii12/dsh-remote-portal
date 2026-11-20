import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:test/test.dart';

import 'p2_script_test_support.dart';

typedef Json = Map<String, Object?>;

void main() {
  test('removing the last pack preserves branch interpretation until an explicit repair is adopted', () async {
    final h = await ScriptFixture.open(allowModel: true);
    final character = await h.card(
      'Guide',
      greeting: 'hello',
      extensions: {
        'dshgo': {
          'v': 1,
          'state': {
            'schema': _modeSchema('A'),
            'init': {'mode': 'A'},
            'rules': [
              {
                'id': 'would-normalize-old-value',
                'when': {
                  '==': [
                    {'var': 'mode'},
                    'B',
                  ],
                },
                'do': [
                  {
                    'type': 'state',
                    'ops': [
                      {'op': 'set', 'path': '/mode', 'value': 'A', 'why': 'bare-card rule'},
                    ],
                  },
                ],
              },
            ],
          },
        },
      },
    );
    final ref = await _install(h, 'mode-b', {
      'schemaPatches': [
        {'path': '', 'node': _modeSchema('B')},
      ],
      'dshgo': {
        'v': 1,
        'state': {
          'init': {'mode': 'B'},
        },
      },
    });
    final scope = TavernPackScopeTarget(kind: TavernGameplayScope.character, targetId: character);
    final beforeBinding = await h.engine.readGameplayBindings(scope);
    final bound = await h.engine.updateGameplayBindings(
      scope,
      expected: beforeBinding.token,
      operationId: 'bind-b',
      edits: [TavernPackBindingEdit.create(clientKey: 'b', packRef: ref)],
    );
    final chat = await h.engine.createChat(character);
    final greeting = (await h.engine.path(chat)).single.nodeId;
    final initial = await _saved(h.engine, chat);
    final priorConfig = initial['dshgoPackDefinitionConfigId'];
    expect(priorConfig, isA<String>());
    expect(_map(initial['messageVariables'])['dshgo'], {'mode': 'B'});
    expect(_modeChoices((await h.engine.readState(chat)).schema), ['B']);

    final removed = await h.engine.updateGameplayBindings(
      scope,
      expected: bound.snapshot.token,
      operationId: 'remove-b',
      edits: [TavernPackBindingEdit.remove(bindingId: bound.createdBindings['b']!)],
    );
    expect(removed.snapshot.bindings.single.removed, isTrue);

    // The old bare-card rule could change B to A. The transition gate must
    // preserve the branch before any such automatic repair is attempted.
    h.reply('body after removal');
    final events = await h.engine.send(chat, '').toList();
    expect(events.whereType<TavernTurnFailed>(), isEmpty);
    expect(events.whereType<TavernTurnDone>(), hasLength(1));
    final retained = await _saved(h.engine, chat);
    expect(_map(retained['messageVariables'])['dshgo'], {'mode': 'B'});
    expect(retained['dshgoPackDefinitionConfigId'], priorConfig);
    final oldView = await h.engine.readState(chat);
    expect(oldView.values, {'mode': 'B'});
    expect(_modeChoices(oldView.schema), ['B']);

    final repaired = await h.engine.setStateValue(chat, '/mode', 'A');
    expect(repaired.applied, isTrue);
    expect(repaired.snapshot.values, {'mode': 'A'});
    expect(_modeChoices(repaired.snapshot.schema), ['A']);
    final adopted = await _saved(h.engine, chat);
    expect(adopted['dshgoPackDefinitionConfigId'], isA<String>());
    expect(adopted['dshgoPackDefinitionConfigId'], isNot(priorConfig));

    await h.engine.selectNode(chat, greeting);
    final original = await h.engine.readState(chat);
    expect(original.values, {'mode': 'B'});
    expect(_modeChoices(original.schema), ['B']);
    expect((await _saved(h.engine, chat))['dshgoPackDefinitionConfigId'], priorConfig);
  });

  test(
    'historical value domains preserve missing and unresolved state while stateless story keeps local variables',
    () async {
      final h = await ScriptFixture.open(allowModel: true);
      final character = await h.card('Guide', greeting: 'hello');
      final ref = await _install(h, 'historical', {
        'schemaPatches': [
          {'path': '', 'node': _modeSchema('B')},
        ],
        'dshgo': {
          'v': 1,
          'state': {
            'init': {'mode': 'B'},
          },
          'story': {
            'acts': [
              {'id': 'pack-act', 'title': 'Pack chapter'},
            ],
          },
        },
      });
      final scope = TavernPackScopeTarget(kind: TavernGameplayScope.character, targetId: character);
      final beforeBinding = await h.engine.readGameplayBindings(scope);
      await h.engine.updateGameplayBindings(
        scope,
        expected: beforeBinding.token,
        operationId: 'bind-history',
        edits: [TavernPackBindingEdit.create(clientKey: 'history', packRef: ref)],
      );
      final originalChat = await h.engine.createChat(character);
      final original = await _saved(h.engine, originalChat);
      final knownConfig = original['dshgoPackDefinitionConfigId'];
      expect(knownConfig, isA<String>());

      final missingChat = await _importSaved(h.engine, character, {
        'variables': {'local': 'keep'},
        'messageVariables': {'foreign': 7},
        'dshgoPackDefinitionConfigId': knownConfig,
      }, 'missing-value.jsonl');
      final foreignRuntime = <String, Object?>{
        'version': 99,
        'foreign': ['keep'],
      };
      final unknownChat = await _importSaved(h.engine, character, {
        'variables': {'local': 'keep'},
        'messageVariables': {
          'dshgo': {'mode': 'foreign'},
        },
        'dshgoPackDefinitionConfigId': 'not-in-this-database',
        'dshgoStoryRuntime': foreignRuntime,
      }, 'unknown-config.jsonl');
      final beforeReads = _rows(h);

      final missing = await h.engine.readState(missingChat);
      expect(missing.legacy, isFalse);
      expect(missing.valueExists, isFalse);
      expect(missing.initialized, isFalse);
      expect(missing.initialValuesAvailable, isFalse);
      expect(_modeChoices(missing.schema), ['B']);
      final unknown = await h.engine.readState(unknownChat);
      expect(unknown.legacy, isFalse);
      expect(unknown.automaticEnabled, isFalse);
      expect(unknown.schema, isNull);
      expect(unknown.values, {'mode': 'foreign'});
      expect(unknown.issues.map((row) => row['code']), contains('gameplay_config_unresolved'));
      final director = await h.engine.readDirector(unknownChat);
      expect(director.story?['unresolved'], isTrue);
      expect(director.story?['runtime'], foreignRuntime);
      expect(_rows(h), beforeReads);

      final stillMissing = await _saved(h.engine, missingChat);
      expect(_map(stillMissing['messageVariables']).containsKey('dshgo'), isFalse);
      expect(stillMissing['dshgoPackDefinitionConfigId'], knownConfig);
      final stillUnknown = await _saved(h.engine, unknownChat);
      expect(stillUnknown['dshgoPackDefinitionConfigId'], 'not-in-this-database');
      expect(stillUnknown['dshgoStoryRuntime'], foreignRuntime);
      h.expectNoGeneration();

      // A real stateless story adoption also retains a configuration reference.
      // Its resolved no-schema domain must not hide or lock ST local variables.
      final statelessCharacter = await h.card('Story only', greeting: 'begin');
      final storyRef = await _install(h, 'story-only', {
        'dshgo': {
          'v': 1,
          'story': {
            'acts': [
              {'id': 'chapter', 'title': 'Chapter'},
            ],
          },
        },
      });
      final storyScope = TavernPackScopeTarget(kind: TavernGameplayScope.character, targetId: statelessCharacter);
      final storyBindings = await h.engine.readGameplayBindings(storyScope);
      await h.engine.updateGameplayBindings(
        storyScope,
        expected: storyBindings.token,
        operationId: 'bind-story-only',
        edits: [TavernPackBindingEdit.create(clientKey: 'story', packRef: storyRef)],
      );
      final settings = await h.settingsDocument();
      await h.engine.setSettings({
        ..._map(settings['settings']),
        'director': {'enabled': true, 'every': 1000},
      });
      final storyChat = await h.engine.createChat(statelessCharacter);
      expect((await h.engine.setStateValue(storyChat, '/local', 7)).applied, isTrue);
      h.reply('first chapter turn');
      expect((await h.engine.send(storyChat, '').toList()).whereType<TavernTurnFailed>(), isEmpty);
      final adoptedStory = await _saved(h.engine, storyChat);
      expect(adoptedStory['dshgoPackDefinitionConfigId'], isA<String>());
      expect(_map(adoptedStory['dshgoStoryRuntime'])['actTurns'], 1);
      final localView = await h.engine.readState(storyChat);
      expect(localView.legacy, isTrue);
      expect(_map(localView.values)['local'], 7);
      final localEdit = await h.engine.setStateValue(storyChat, '/local', 8);
      expect(localEdit.applied, isTrue);
      expect(localEdit.snapshot.legacy, isTrue);
      expect(_map(localEdit.snapshot.values)['local'], 8);
      h.reply('second chapter turn');
      expect((await h.engine.send(storyChat, '').toList()).whereType<TavernTurnFailed>(), isEmpty);
      final continuedStory = await _saved(h.engine, storyChat);
      expect(_map(continuedStory['dshgoStoryRuntime'])['actTurns'], 2);
      expect(continuedStory['dshgoPackDefinitionConfigId'], adoptedStory['dshgoPackDefinitionConfigId']);
    },
  );
  test('script message data adopts only validated changes on the actual physical target', () async {
    final h = await ScriptFixture.open();
    final character = await h.card('Script state', greeting: 'legacy leaf');
    final chat = await h.engine.createChat(character);
    final leaf = (await h.engine.path(chat)).single.nodeId;
    expect((await _saved(h.engine, chat)).containsKey('dshgoPackDefinitionConfigId'), isFalse);
    final ref = await _install(h, 'script-count', {
      'schemaPatches': [
        {
          'path': '',
          'node': {
            'type': 'object',
            'required': ['n'],
            'properties': {
              'n': {'type': 'integer'},
            },
          },
        },
      ],
      'dshgo': {
        'v': 1,
        'state': {
          'init': {'n': 0},
          'rules': [
            {
              'id': 'once',
              'once': true,
              'when': true,
              'do': [
                {
                  'type': 'state',
                  'ops': [
                    {'op': 'add', 'path': '/n', 'value': 1, 'why': 'script once'},
                  ],
                },
              ],
            },
          ],
        },
      },
    });
    final scope = TavernPackScopeTarget(kind: TavernGameplayScope.character, targetId: character);
    final empty = await h.engine.readGameplayBindings(scope);
    final bound = await h.engine.updateGameplayBindings(
      scope,
      expected: empty.token,
      operationId: 'bind-script-count',
      edits: [TavernPackBindingEdit.create(clientKey: 'count', packRef: ref)],
    );
    final bindingId = bound.createdBindings['count']!;
    final context = await h.context(chat, characterId: character);

    // Insert a real root before the still-selected legacy leaf. Its actual
    // initialization must persist the configuration in the same SQL adoption.
    final created = await h.bridge.createChatMessages(context.id, [
      TavernScriptMessageDraft(role: TavernScriptRole.user, message: 'pack root'),
    ], insertBefore: 0);
    final rootRef = created.upsertMessages.singleWhere((message) => message.message == 'pack root').ref;
    expect((await h.engine.path(chat)).map((message) => message.nodeId), [rootRef.nodeId, leaf]);
    final initialized = await _savedMessage(h.engine, chat, 'pack root');
    expect(_map(initialized['messageVariables'])['dshgo'], {'n': 0});
    expect(initialized['dshgoPackDefinitionConfigId'], isA<String>());
    expect(
      h.inspect(
        (db) => [
          for (final row in db.select('SELECT config_id FROM gameplay_effective_configs WHERE config_id = ?', [
            initialized['dshgoPackDefinitionConfigId'],
          ]))
            row['config_id'],
        ],
      ),
      [initialized['dshgoPackDefinitionConfigId']],
    );
    expect(initialized.containsKey('dshgoPackRuntime'), isFalse);
    expect((await _saved(h.engine, chat)).containsKey('dshgoPackDefinitionConfigId'), isFalse);

    final target = TavernVariableTarget(scope: TavernVariableScope.message, messageRef: rootRef);
    final changed = await h.bridge.replaceVariables(context.id, target, {
      'dshgo': {'n': 1},
      'foreign': 'first',
    });
    expect(changed.value['dshgo'], {'n': 2});
    expect(changed.stateEdit?.applied, isTrue);
    final adopted = await _savedMessage(h.engine, chat, 'pack root');
    final packRuntime = _map(adopted['dshgoPackRuntime']);
    expect(_map(_map(packRuntime['bindings'])[bindingId])['rules'], ['once']);

    final ordinary = await h.bridge.replaceVariables(context.id, target, {...changed.value, 'foreign': 'second'});
    expect(ordinary.stateEdit, isNull);
    final afterOrdinary = await _savedMessage(h.engine, chat, 'pack root');
    for (final key in adopted.keys.where((key) => key != 'messageVariables')) {
      expect(afterOrdinary[key], adopted[key], reason: key);
    }

    await h.engine.updateGameplayBindings(
      scope,
      expected: bound.snapshot.token,
      operationId: 'remove-script-count',
      edits: [TavernPackBindingEdit.remove(bindingId: bindingId)],
    );
    final preserved = await h.bridge.replaceVariables(context.id, target, {
      ...ordinary.value,
      'foreign': 'after removal',
    });
    expect(preserved.stateEdit, isNull);
    final beforeRejected = await _savedMessage(h.engine, chat, 'pack root');
    expect(beforeRejected['dshgoPackDefinitionConfigId'], adopted['dshgoPackDefinitionConfigId']);
    expect(beforeRejected['dshgoPackRuntime'], packRuntime);
    final rowsBeforeRejected = _rows(h);

    // The selected leaf has no configuration reference. The physical root
    // still does, so an actual DSH change must not take the legacy no-schema path.
    await expectLater(
      () => h.bridge.replaceVariables(context.id, target, {
        ...preserved.value,
        'dshgo': {'n': 9},
      }),
      throwsA(
        scriptError(TavernScriptErrorCode.stateValidation).having((error) => error.committed, 'committed', isFalse),
      ),
    );
    final afterRejected = await h.bridge.getVariables(context.id, target);
    expect(afterRejected.value, preserved.value);
    expect(afterRejected.version, preserved.version);
    expect(await _savedMessage(h.engine, chat, 'pack root'), beforeRejected);
    expect(_rows(h), rowsBeforeRejected);
    expect((await h.engine.path(chat)).last.nodeId, leaf);
    expect((await _saved(h.engine, chat)).containsKey('dshgoPackDefinitionConfigId'), isFalse);
    h.expectNoGeneration();
  });

  test('legacy card failures precede malformed presets for create and manual append', () async {
    final h = await ScriptFixture.open();
    final character = await h.card('Unavailable card', greeting: 'saved greeting');
    final chat = await h.engine.createChat(character);
    final presetId = (await h.engine.presetSelection()).effectivePresetId;
    expect(presetId, isNotNull);

    // Close the engine to remove the real card cache. Both failures then
    // coexist at their native file/SQLite boundaries, with no pack bindings.
    await h.reopen(
      whileClosed: () async {
        await Directory('${h.root.path}/characters/$character').delete(recursive: true);
        h.inspect((db) {
          db.execute('UPDATE presets SET raw_json = ? WHERE id = ?', ['{', presetId]);
        }, writable: true);
      },
    );
    final before = _rows(h);
    await expectLater(h.engine.presetSelection(), throwsA(isA<FormatException>()));
    final missingCard = isA<TavernImportError>().having((error) => error.message, 'message', '角色不存在。');

    await expectLater(h.engine.createChat(character), throwsA(missingCard));
    await expectLater(h.engine.sendOnly(chat, 'not appended'), throwsA(missingCard));
    await expectLater(
      h.engine.createGroupChat([character], addGreetings: false),
      throwsA(
        isA<TavernGroupException>()
            .having((error) => error.code, 'code', TavernGroupError.characterNotFound)
            .having((error) => error.characterId, 'characterId', character),
      ),
    );

    expect(_rows(h), before);
    h.expectNoGeneration();
  });
}

Json _modeSchema(String value) => {
  'type': 'object',
  'required': ['mode'],
  'additionalProperties': false,
  'properties': {
    'mode': {
      'type': 'string',
      'enum': [value],
    },
  },
};

Object? _modeChoices(Object? schema) => _map(_map(_map(schema)['properties'])['mode'])['enum'];
Json _map(Object? value) => value! as Json;

Future<TavernPackVersionRef> _install(ScriptFixture h, String id, Json fields) async {
  final bytes = Uint8List.fromList(
    utf8.encode(
      jsonEncode({'formatVersion': 1, 'packId': id, 'packVersion': '1', 'resources': <Object?>[], ...fields}),
    ),
  );
  final archive = Archive()..addFile(ArchiveFile('pack.json', bytes.length, bytes));
  return (await h.engine.importGameplayPack(Uint8List.fromList(ZipEncoder().encode(archive)))).ref;
}

Future<Json> _saved(TavernEngine engine, String chatId) async {
  final files = await engine.exportChat(chatId);
  final document = StChatDocument.decode(files.first.fileName, files.first.bytes);
  final state = _map(_map(_map(document.messages.last['extra'])['dshgo'])['tavernState']);
  return _map(jsonDecode(jsonEncode(state)));
}

Future<Json> _savedMessage(TavernEngine engine, String chatId, String text) async {
  final files = await engine.exportChat(chatId);
  final document = StChatDocument.decode(files.first.fileName, files.first.bytes);
  final message = document.messages.singleWhere((message) => message['mes'] == text);
  final state = _map(_map(_map(message['extra'])['dshgo'])['tavernState']);
  return _map(jsonDecode(jsonEncode(state)));
}

Future<String> _importSaved(TavernEngine engine, String characterId, Json state, String name) async {
  final document = StChatDocument(
    fileName: name,
    header: {
      'user_name': 'User',
      'character_name': 'Guide',
      'chat_metadata': {
        'variables': {'local': 'keep'},
      },
    },
    messages: [
      {
        'name': 'Guide',
        'is_user': false,
        'is_system': false,
        'mes': 'imported',
        'send_date': DateTime.utc(2026, 11, 14).toIso8601String(),
        'variables': [state['messageVariables']],
        'extra': {
          'dshgo': {'tavernState': state},
        },
      },
    ],
  );
  return (await engine.importChats(characterId, [
    TavernChatFile(fileName: name, bytes: document.encode()),
  ])).chatIds.single;
}

Json _rows(ScriptFixture h) => h.inspect(
  (db) => {
    for (final row in db.select(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name",
    ))
      row['name']! as String: [
        for (final item in db.select('SELECT * FROM "${(row['name']! as String).replaceAll('"', '""')}"'))
          Map<String, Object?>.from(item),
      ],
  },
);

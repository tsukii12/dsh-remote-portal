import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

// Real engine, card files, SQLite, JSONL and backup. No model result is supplied:
// these operations must never invoke the model or request an API key.
void main() {
  test('group CRUD keeps duplicate names distinct and persists roster preferences', () async {
    final h = await _Fixture.open();
    final first = await h.card(name: 'Twin', greeting: 'first greeting', talk: 0.2);
    final second = await h.card(name: 'Twin', greeting: 'second greeting', talk: 0.8);
    final third = await h.card(name: 'Third', greeting: 'must not be appended', talk: 5);
    expect(first, isNot(second));
    final Tavern tavern = h.engine;
    final id = await tavern.createGroupChat([first, second], title: 'Twins');
    final initial = (await tavern.watchGroupChat(id).first)!;
    expect(initial.hostCharacterId, first);
    expect(initial.activation, TavernGroupActivation.natural);
    expect(initial.maxSpeakersPerTurn, 3);
    expect(initial.allowSelfResponses, isFalse);
    expect(_members(initial), [
      [first, 0.2, false, TavernGroupModelRole.main, true],
      [second, 0.8, false, TavernGroupModelRole.helper, true],
    ]);
    expect(() => initial.members.clear(), throwsUnsupportedError);
    final originalPath = await tavern.path(id);
    expect(originalPath.map((m) => m.text), ['first greeting', 'second greeting']);
    expect(originalPath.map((m) => m.speaker), ['Twin', 'Twin']);
    expect(originalPath.map((m) => m.speakerCharacterId), [first, second]);
    expect(originalPath.last.parentId, originalPath.first.nodeId);

    final added = await tavern.addGroupMember(id, third, muted: true);
    expect(_members(added).last, [third, 1.0, true, TavernGroupModelRole.helper, true]);
    final changed = await tavern.updateGroupMember(
      id,
      second,
      talkativeness: 0.35,
      muted: true,
      modelRole: TavernGroupModelRole.main,
    );
    expect(_members(changed)[1], [second, 0.35, true, TavernGroupModelRole.main, true]);
    expect((await tavern.groupChat(id))!.members.first.talkativeness, 0.2);
    expect(initial.members[1].muted, isFalse);
    await tavern.reorderGroupMembers(id, [third, second, first]);
    final configured = await tavern.updateGroupChat(
      id,
      title: 'Saved group',
      activation: TavernGroupActivation.listOrder,
      maxSpeakersPerTurn: 2,
      allowSelfResponses: true,
    );
    expect(configured.members.map((m) => m.characterId), [third, second, first]);
    final removed = await tavern.removeGroupMember(id, first);
    expect(removed.hostCharacterId, first);
    expect(removed.members.map((m) => m.characterId), [third, second]);
    expect((await tavern.path(id)).map((m) => m.nodeId), originalPath.map((m) => m.nodeId));

    for (final characterId in [first, second, third]) {
      final chats = await tavern.watchChats(characterId: characterId).first;
      expect(chats.map((chat) => chat.id), [id]);
      expect(chats.single.kind, TavernChatKind.group);
      expect(chats.single.characterId, first);
      expect(chats.single.memberCharacterIds, [third, second]);
      expect(chats.single.messageCount, 2);
      expect((await tavern.character(characterId))!.chatCount, 1);
    }
    final saved = _configuration(removed);
    await h.reopen();
    expect(_configuration((await h.engine.groupChat(id))!), saved);
    expect((await h.engine.path(id)).map((m) => m.speakerCharacterId), [first, second]);
    final deleted = h.engine.watchGroupChat(id).firstWhere((group) => group == null);
    await h.engine.deleteChat(id);
    expect(await deleted, isNull);
    expect(await h.engine.groupChat(id), isNull);
    expect(await h.engine.watchChats().first, isEmpty);
    h.expectNoGeneration();
  });

  test('invalid group edits fail without changing the saved roster or creating chats', () async {
    final h = await _Fixture.open();
    final host = await h.card(name: 'Host');
    final member = await h.card(name: 'Member', talk: 'NaN');
    final id = await h.engine.createGroupChat([host, member], addGreetings: false);
    expect((await h.engine.groupChat(id))!.members[1].talkativeness, 0.5);
    final before = _configuration((await h.engine.groupChat(id))!);
    await expectLater(h.engine.createGroupChat([host, host]), throwsA(_groupError(TavernGroupError.invalidMembers)));
    await expectLater(h.engine.createGroupChat([]), throwsA(_groupError(TavernGroupError.invalidMembers)));
    await expectLater(
      h.engine.createGroupChat([host, 'missing-card']),
      throwsA(_groupError(TavernGroupError.characterNotFound)),
    );
    await expectLater(
      h.engine.createGroupChat([host], maxSpeakersPerTurn: 0),
      throwsA(_groupError(TavernGroupError.invalidLimit)),
    );
    await expectLater(h.engine.addGroupMember(id, member), throwsA(_groupError(TavernGroupError.memberExists)));
    await expectLater(
      h.engine.removeGroupMember(id, 'missing-member'),
      throwsA(_groupError(TavernGroupError.memberNotFound)),
    );
    for (final value in [double.nan, double.infinity, -0.1, 1.1]) {
      await expectLater(
        h.engine.updateGroupMember(id, member, talkativeness: value),
        throwsA(_groupError(TavernGroupError.invalidTalkativeness)),
      );
    }
    for (final order in [
      [host],
      [host, host],
      [host, 'missing-member'],
    ]) {
      await expectLater(h.engine.reorderGroupMembers(id, order), throwsA(_groupError(TavernGroupError.invalidOrder)));
    }
    await expectLater(
      h.engine.updateGroupChat(id, maxSpeakersPerTurn: 0),
      throwsA(_groupError(TavernGroupError.invalidLimit)),
    );
    expect(_configuration((await h.engine.groupChat(id))!), before);
    expect((await h.engine.watchChats().first).map((chat) => chat.id), [id]);
    expect(await h.engine.path(id), isEmpty);
    final single = await h.engine.createChat(host);
    expect(await h.engine.groupChat(single), isNull);
    expect(await h.engine.groupChat('missing-chat'), isNull);
    await expectLater(
      h.engine.updateGroupChat(single, title: 'not a group'),
      throwsA(_groupError(TavernGroupError.notGroup)),
    );
    await h.reopen();
    expect(_configuration((await h.engine.groupChat(id))!), before);
    h.expectNoGeneration();
  });

  test('host deletion is guarded before card and single-chat removal while actors may leave', () async {
    final h = await _Fixture.open();
    final host = await h.card(name: 'Host', greeting: 'host history');
    final actor = await h.card(name: 'Actor', greeting: 'actor history');
    final hostSingle = await h.engine.createChat(host);
    final actorSingle = await h.engine.createChat(actor);
    final group = await h.engine.createGroupChat([host, actor]);
    final empty = await h.engine.createGroupChat([], hostCharacterId: host, addGreetings: false);
    final pathBefore = await h.engine.path(group);
    final cardFile = File('${h.root.path}/characters/$host/card.json');
    final cardBefore = await cardFile.readAsBytes();
    await h.engine.removeGroupMember(group, host);
    await expectLater(
      h.engine.deleteCharacter(host),
      throwsA(
        _groupError(TavernGroupError.hostInUse)
            .having((error) => error.characterId, 'characterId', host)
            .having((error) => error.relatedChatIds, 'relatedChatIds', unorderedEquals([group, empty])),
      ),
    );
    expect(await cardFile.readAsBytes(), cardBefore);
    expect(await h.engine.character(host), isNotNull);
    expect((await h.engine.path(hostSingle)).single.text, 'host history');
    expect((await h.engine.groupChat(group))!.hostCharacterId, host);

    await h.engine.deleteCharacter(actor);
    expect(await h.engine.character(actor), isNull);
    expect(await Directory('${h.root.path}/characters/$actor').exists(), isFalse);
    expect((await h.engine.groupChat(group))!.members, isEmpty);
    expect((await h.engine.path(group)).map((m) => m.nodeId), pathBefore.map((m) => m.nodeId));
    expect((await h.engine.path(group)).map((m) => m.speakerCharacterId), [host, actor]);
    expect((await h.engine.watchChats().first).map((chat) => chat.id), isNot(contains(actorSingle)));
    await h.reopen();
    expect((await h.engine.path(group)).last.speakerCharacterId, actor);
    expect((await h.engine.groupChat(empty))!.hostCharacterId, host);
    await h.engine.deleteChat(group);
    await h.engine.deleteChat(empty);
    await h.engine.deleteCharacter(host);
    expect(await h.engine.character(host), isNull);
    expect(await h.engine.watchChats().first, isEmpty);
    h.expectNoGeneration();
  });

  test('a group without greetings saves the host initial state without a hidden seed node', () async {
    final h = await _Fixture.open();
    final host = await h.card(name: 'Host', greeting: 'not added', initialCount: 7);
    final actor = await h.card(name: 'Actor', greeting: 'not added either', initialCount: 99);
    final id = await h.engine.createGroupChat([actor], hostCharacterId: host, addGreetings: false);
    expect(await h.engine.path(id), isEmpty);
    expect(await h.engine.tree(id), isEmpty);
    final initial = await h.engine.readState(id);
    expect(initial.legacy, isFalse);
    expect(initial.initialized, isTrue);
    expect(initial.valueExists, isTrue);
    expect(initial.initialValuesAvailable, isFalse);
    expect(initial.nodeId, isNull);
    expect(initial.values, {'count': 7});
    expect(await h.engine.readAgentRuns(id), isEmpty);
    // This fixture replaces the card source while the engine is closed. The
    // public field editor intentionally does not edit extensions. A later card
    // init must not replace the group's already saved host state on reopen.
    await h.reopen(
      whileClosed: () async {
        final file = File('${h.root.path}/characters/$host/card.json');
        final raw = _map(jsonDecode(await file.readAsString()));
        _map(raw['data'])['extensions'] = _stateExtension(42);
        await file.writeAsString(jsonEncode(raw));
      },
    );
    expect((await h.engine.readState(id)).values, {'count': 7});
    expect(await h.engine.tree(id), isEmpty);

    // The actor has its own different initial value (99), while the changed
    // host source now says 42. Neither may reset the saved value of 7.
    final first = await h.engine.sendOnly(id, 'first user line');
    expect(first.role, TavernRole.user);
    expect(first.speakerCharacterId, isNull);
    expect((await h.engine.readState(id)).values, {'count': 7});
    final edited = await h.engine.setStateValue(id, '/count', 11, expectedNodeId: first.nodeId);
    expect(edited.applied, isTrue);
    expect(edited.snapshot.values, {'count': 11});
    await h.engine.addGroupMember(id, host);
    await h.engine.reorderGroupMembers(id, [host, actor]);
    await h.engine.removeGroupMember(id, actor);
    await h.engine.sendOnly(id, 'second user line');
    await h.reopen();
    expect((await h.engine.readState(id)).values, {'count': 11});
    expect((await h.engine.path(id)).map((m) => m.text), ['first user line', 'second user line']);
    expect((await h.engine.tree(id)).length, 2);
    h.expectNoGeneration();
  });

  test('speaker identities survive same-name JSONL export and import without inventing avatars', () async {
    final h = await _Fixture.open();
    final first = await h.card(name: 'Twin', greeting: 'first body');
    final second = await h.card(name: 'Twin', greeting: 'second body');
    final id = await h.engine.createGroupChat([first, second]);
    await h.engine.sendOnly(id, 'user body');
    await h.engine.narrate(id, 'narrator body', speaker: 'Twin');
    await h.engine.updateCharacterFields(second, {'name': 'Renamed actor'});
    await h.engine.removeGroupMember(id, second);
    final before = await h.engine.path(id);
    expect(before.map((m) => m.speakerCharacterId), [first, second, null, null]);
    expect((await h.engine.tree(id)).map((m) => m.speakerCharacterId), [first, second, null, null]);
    expect((await h.engine.searchChat(id, 'second')).single.speakerCharacterId, second);

    final files = await h.engine.exportChat(id);
    final document = StChatDocument.decode(files.first.fileName, files.first.bytes);
    expect(document.messages.map((line) => line['name']), ['Twin', 'Twin', before[2].speaker, 'Twin']);
    for (var index = 0; index < 2; index++) {
      final row = document.messages[index];
      final own = _map(_map(_map(row['extra'])['dshgo'])['chatJsonl']);
      final identity = index == 0 ? first : second;
      expect(own['speakerCharacterId'], identity);
      expect(row['original_avatar'], isNot(identity));
    }
    final imported = await h.engine.importChats(first, files);
    final copy = imported.chatIds.single;
    expect(
      await h.engine.groupChat(copy),
      isNull,
      reason: 'JSONL carries messages, not a cross-library group definition.',
    );
    expect((await h.engine.path(copy)).map((m) => m.text), before.map((m) => m.text));
    expect((await h.engine.path(copy)).map((m) => m.speakerCharacterId), [first, second, null, null]);

    final external = StChatDocument(
      fileName: 'unmapped.jsonl',
      header: {'user_name': 'User', 'character_name': 'Twin', 'chat_metadata': <String, Object?>{}},
      messages: [
        {
          'name': 'Twin',
          'is_user': false,
          'is_system': false,
          'mes': 'external body',
          'send_date': '2026-11-12T04:00:00.000Z',
          'original_avatar': 'unmapped.png',
        },
      ],
    );
    final unknown = (await h.engine.importChats(first, [
      TavernChatFile(fileName: external.fileName, bytes: external.encode()),
    ])).chatIds.single;
    expect((await h.engine.path(unknown)).single.speakerCharacterId, isNull);
    await h.reopen();
    expect((await h.engine.path(copy)).map((m) => m.speakerCharacterId), [first, second, null, null]);
    expect((await h.engine.path(unknown)).single.speakerCharacterId, isNull);
    final unknownFiles = await h.engine.exportChat(unknown);
    final unknownDocument = StChatDocument.decode(unknownFiles.first.fileName, unknownFiles.first.bytes);
    expect(unknownDocument.messages.single['original_avatar'], 'unmapped.png');
    h.expectNoGeneration();
  });

  test('whole-directory backup restores group configuration and an empty host state', () async {
    final h = await _Fixture.open();
    final host = await h.card(name: 'Host', greeting: 'host body', initialCount: 7);
    final actor = await h.card(name: 'Actor', greeting: 'actor body');
    final group = await h.engine.createGroupChat(
      [actor, host],
      hostCharacterId: host,
      title: 'Backed up',
      activation: TavernGroupActivation.listOrder,
      maxSpeakersPerTurn: 1,
      allowSelfResponses: true,
    );
    await h.engine.updateGroupMember(
      group,
      actor,
      talkativeness: 0.3,
      muted: true,
      modelRole: TavernGroupModelRole.main,
    );
    final empty = await h.engine.createGroupChat(
      [],
      hostCharacterId: host,
      title: 'Empty but initialized',
      addGreetings: false,
    );
    final configuration = _configuration((await h.engine.groupChat(group))!);
    final path = await h.engine.path(group);
    final work = await Directory.systemTemp.createTemp('dsh-p2-group-backup-');
    TavernEngine? restored;
    addTearDown(() async {
      try {
        await restored?.close();
      } finally {
        if (await work.exists()) await work.delete(recursive: true);
      }
    });
    final archive = File('${work.path}/groups.zip');
    final info = await h.engine.backup(archive.path);
    expect(info.sqliteUserVersion, ChatStore.schemaVersion);
    final destination = Directory('${work.path}/restored');
    final restoredInfo = await restoreTavernDirectory(archive.path, destination.path);
    expect(restoredInfo.sqliteUserVersion, ChatStore.schemaVersion);
    restored = await TavernEngine.openDirectory(
      destination,
      config: h.config,
      modelClient: h.model,
      clock: () => _at,
      random: () => 0.25,
    );
    final engine = restored;
    expect(_configuration((await engine.groupChat(group))!), configuration);
    expect((await engine.path(group)).map((m) => m.nodeId), path.map((m) => m.nodeId));
    expect((await engine.path(group)).map((m) => m.speakerCharacterId), [actor, host]);
    expect((await engine.character(host))!.name, 'Host');
    expect((await engine.groupChat(empty))!.members, isEmpty);
    expect(await engine.tree(empty), isEmpty);
    expect((await engine.readState(empty)).values, {'count': 7});
    final manual = await engine.sendOnly(empty, 'restored group remains writable');
    expect(manual.speakerCharacterId, isNull);
    expect((await engine.readState(empty)).values, {'count': 7});
    h.expectNoGeneration();
  });

  test('genuine schema six migrates once preserving old data and accepts new groups', () async {
    final h = await _Fixture.open(beforeOpen: _writeVersionSix);
    expect((await h.engine.watchChats().first).single.kind, TavernChatKind.single);
    expect(await h.engine.groupChat('old-chat'), isNull);
    final old = (await h.engine.path('old-chat')).single;
    expect(old.nodeId, 'old-node');
    expect(old.text, 'old searchable oracle');
    expect(old.speakerCharacterId, isNull);
    expect(old.reportedUsage!.promptTokens, 17);
    expect((await h.engine.tree('old-chat')).single.speakerCharacterId, isNull);
    expect(await h.engine.readVariables('old-chat'), {'kept': 7});
    expect((await h.engine.searchChat('old-chat', 'searchable')).single.nodeId, 'old-node');
    final snapshot = _inspect(
      h.root,
      (db) => {
        'version': db.select('PRAGMA user_version').single['user_version'],
        'marker': db.select('SELECT vendor_marker FROM chats WHERE id = ?', ['old-chat']).single['vendor_marker'],
        'metadata': jsonDecode(
          db.select('SELECT metadata FROM chats WHERE id = ?', ['old-chat']).single['metadata']! as String,
        ),
      },
    );
    expect(snapshot, {
      'version': ChatStore.schemaVersion,
      'marker': 'do not rewrite',
      'metadata': {
        'foreign': ['keep', 2],
      },
    });
    final host = await h.card(name: 'New host', greeting: 'new group greeting');
    final group = await h.engine.createGroupChat([host]);
    expect((await h.engine.groupChat(group))!.hostCharacterId, host);
    expect((await h.engine.path(group)).single.speakerCharacterId, host);
    await h.reopen();
    expect((await h.engine.path('old-chat')).single.nodeId, 'old-node');
    expect(await h.engine.readVariables('old-chat'), {'kept': 7});
    expect((await h.engine.path(group)).single.speakerCharacterId, host);
    expect(_inspect(h.root, (db) => db.select('PRAGMA user_version').single['user_version']), ChatStore.schemaVersion);
    h.expectNoGeneration();
  });
}

final _at = DateTime.utc(2026, 11, 12, 4);

class _Fixture {
  _Fixture(this.root);

  static Future<_Fixture> open({void Function(Directory)? beforeOpen}) async {
    final root = await Directory.systemTemp.createTemp('dsh-p2-group-store-');
    final fixture = _Fixture(root);
    // Registered before the first database open, including fixture preparation.
    addTearDown(fixture.dispose);
    beforeOpen?.call(root);
    await fixture._open();
    return fixture;
  }

  final Directory root;
  final model = _UnexpectedModel();
  TavernEngine? _engine;
  int keyCalls = 0;
  late final config = TavernModelConfig(
    apiKey: () async {
      keyCalls++;
      throw StateError('Storage operations must not request a model key.');
    },
    model: 'unused-group-storage',
    baseUrl: 'https://group-storage.invalid/v1',
    deepseek: false,
  );

  TavernEngine get engine => _engine!;

  Future<void> _open() async {
    _engine = await TavernEngine.openDirectory(
      root,
      config: config,
      modelClient: model,
      clock: () => _at,
      random: () => 0.25,
    );
  }

  Future<void> reopen({Future<void> Function()? whileClosed}) async {
    await engine.close();
    _engine = null;
    await whileClosed?.call();
    await _open();
  }

  Future<String> card({required String name, String greeting = '', Object? talk, int? initialCount}) async {
    final card = await engine.importCard(
      Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'spec': 'chara_card_v3',
            'spec_version': '3.0',
            'data': {
              'name': name,
              'description': '',
              'personality': '',
              'scenario': '',
              'first_mes': greeting,
              'mes_example': '',
              'creator_notes': '',
              'system_prompt': '',
              'post_history_instructions': '',
              'alternate_greetings': <String>[],
              'tags': <String>[],
              'creator': '',
              'character_version': '',
              'talkativeness': ?talk,
              'extensions': initialCount == null ? <String, Object?>{} : _stateExtension(initialCount),
            },
          }),
        ),
      ),
    );
    return card.id;
  }

  void expectNoGeneration() {
    expect(model.calls, 0);
    expect(keyCalls, 0);
  }

  Future<void> dispose() async {
    try {
      await _engine?.close();
    } finally {
      if (await root.exists()) await root.delete(recursive: true);
    }
  }
}

class _UnexpectedModel extends TavernModelClient {
  int calls = 0;

  @override
  Stream<ModelDelta> generate({
    required TavernModelConfig config,
    required Map<String, Object?> body,
    required ModelCancellation cancellation,
    void Function(int attempt)? onRequestStarted,
  }) {
    calls++;
    throw StateError('Storage operations must not generate.');
  }
}

Map<String, Object?> _stateExtension(int count) => {
  'dshgo': {
    'v': 1,
    'state': {
      'schema': {
        'type': 'object',
        'additionalProperties': false,
        'required': ['count'],
        'properties': {
          'count': {'type': 'integer', 'minimum': 0, 'maximum': 100, 'default': 0},
        },
      },
      'init': {'count': count},
      'rules': <Object?>[],
    },
  },
};

Map<String, Object?> _map(Object? value) => value! as Map<String, Object?>;

List<List<Object?>> _members(TavernGroupChat group) => [
  for (final member in group.members)
    [member.characterId, member.talkativeness, member.muted, member.modelRole, member.available],
];

Map<String, Object?> _configuration(TavernGroupChat group) => {
  'id': group.chatId,
  'title': group.title,
  'host': group.hostCharacterId,
  'members': _members(group),
  'activation': group.activation,
  'maxSpeakersPerTurn': group.maxSpeakersPerTurn,
  'allowSelfResponses': group.allowSelfResponses,
};

TypeMatcher<TavernGroupException> _groupError(TavernGroupError code) =>
    isA<TavernGroupException>().having((error) => error.code, 'code', code);

T _inspect<T>(Directory root, T Function(Database) action) {
  final db = sqlite3.open('${root.path}/tavern.sqlite3', mode: OpenMode.readOnly);
  try {
    return action(db);
  } finally {
    db.close();
  }
}

void _writeVersionSix(Directory root) {
  final db = sqlite3.open('${root.path}/tavern.sqlite3');
  try {
    // Genuine frozen v4 SQL plus the fixed v5/v6 DDL, before inserting data.
    // There are no rows for the v5 reported-usage backfill to transform. This
    // does not create a current database and relabel its version as old.
    db.execute(File('test/fixtures/t24_schema_v4.sql').readAsStringSync());
    db.execute(_versionFiveAndSix);
    expect(db.select('PRAGMA user_version').single['user_version'], 6);
    expect(db.select('PRAGMA table_info(nodes)').map((row) => row['name']), isNot(contains('speaker_character_id')));
    db.execute("ALTER TABLE chats ADD COLUMN vendor_marker TEXT DEFAULT 'do not rewrite'");
    db.execute(
      '''INSERT INTO chats(id,character_id,title,created_at,updated_at,metadata,variables)
      VALUES('old-chat','old-card','Old single',1,2,?,?)''',
      [
        jsonEncode({
          'foreign': ['keep', 2],
        }),
        jsonEncode({'kept': 7}),
      ],
    );
    db.execute(
      '''INSERT INTO nodes(id,chat_id,depth,role,speaker,text,at,reported_usage)
      VALUES('old-node','old-chat',1,'character','Old actor','old searchable oracle',1,?)''',
      [
        jsonEncode({'promptTokens': 17, 'cacheHitTokens': 0, 'completionTokens': 3, 'model': 'old'}),
      ],
    );
    db.execute("INSERT INTO node_states(node_id,full_json) VALUES('old-node',?)", [
      jsonEncode({
        'variables': {'kept': 7},
      }),
    ]);
    db.execute("UPDATE chats SET selected_root_id='old-node',current_leaf_id='old-node' WHERE id='old-chat'");
  } finally {
    db.close();
  }
}

// Schema 5 and 6 add these objects to the frozen empty v4 fixture. Keep this
// input independent of ChatStore.schemaVersion and its current migration map.
const _versionFiveAndSix = '''
ALTER TABLE chats ADD COLUMN tree_revision INTEGER NOT NULL DEFAULT 0;
CREATE TABLE deleted_subtrees (
  id TEXT PRIMARY KEY NOT NULL,
  chat_id TEXT NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
  root_node_id TEXT NOT NULL,
  parent_id TEXT,
  selected_child_id TEXT,
  selected_root_id TEXT,
  current_leaf_id TEXT,
  revision_after INTEGER NOT NULL
);
CREATE INDEX deleted_subtrees_chat ON deleted_subtrees(chat_id);
ALTER TABLE nodes ADD COLUMN deleted_by TEXT REFERENCES deleted_subtrees(id) DEFERRABLE INITIALLY DEFERRED;
CREATE INDEX nodes_deleted_by ON nodes(deleted_by) WHERE deleted_by IS NOT NULL;
ALTER TABLE nodes ADD COLUMN reported_usage TEXT;
CREATE INDEX agent_runs_chat_kind ON agent_runs(chat_id, kind);
PRAGMA user_version = 6;
''';

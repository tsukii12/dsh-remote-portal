import 'dart:convert';
import 'dart:io';

import 'package:dsh_tavern/src/api.dart';
import 'package:dsh_tavern/src/persona.dart';
import 'package:dsh_tavern/src/store/chat_store.dart';
import 'package:dsh_tavern/src/store/persona_store.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  late Directory directory;
  late PersonaStore personas;
  late ChatStore chats;
  var serial = 0;

  String nextId() => 'persona-${serial++}';
  File indexFile() => File('${directory.path}/personas/index.json');

  Future<void> reopenPersonas() async {
    await personas.close();
    personas = await PersonaStore.open(directory, createId: nextId);
  }

  setUp(() async {
    serial = 0;
    directory = await Directory.systemTemp.createTemp('dsh-tavern-personas-');
    personas = await PersonaStore.open(directory, createId: nextId);
    chats = ChatStore.open('${directory.path}/chats.sqlite');
  });

  tearDown(() async {
    await personas.close();
    await chats.close();
    await directory.delete(recursive: true);
  });

  test('raw text, optional avatar and field-only edits survive reopening', () async {
    const name = '  海鸥 🌊\t';
    const description = ' \r\n{{user}}：第一行\r\n{{incvar::visits}}\n末行  ';
    final original = await personas.create(name: name, description: description, avatarPath: '/caller/owned/头像.png');
    expect(personas.list().single.name, name);
    expect(original.description, description);
    expect(original.inPrompt, isTrue);
    final updated = await personas.update(original.id, name: '后来的名字');
    expect(updated.description, description);
    expect(updated.avatarPath, '/caller/owned/头像.png');
    expect(original.name, name);
    await reopenPersonas();
    expect(personas.get(original.id)!.description, description);
    expect(personas.get(original.id)!.name, '后来的名字');
    await personas.update(original.id, description: '', clearAvatar: true);
    await reopenPersonas();
    expect(personas.get(original.id)!.description, '');
    expect(personas.get(original.id)!.avatarPath, isNull);
    await expectLater(personas.update(original.id, avatarPath: 'new.png', clearAvatar: true), throwsArgumentError);
    expect(personas.get(original.id)!.avatarPath, isNull);
  });

  test('unknown profile and index fields remain detached and survive edits', () async {
    await personas.close();
    final file = indexFile();
    await file.parent.create(recursive: true);
    await file.writeAsString(
      jsonEncode({
        'version': 1,
        'futureRoot': {
          'nested': [1, null, '雪'],
        },
        'personas': [
          {
            'id': 'external',
            'name': '旧名字',
            'description': ' 未展开的 {{user}} ',
            'extensions': {
              'vendor': {'level': 4},
            },
          },
        ],
        'defaultPersonaId': 'external',
      }),
    );
    personas = await PersonaStore.open(directory, createId: nextId);
    final exported = personas.get('external')!.toJson();
    ((exported['extensions']! as Map<String, Object?>)['vendor']! as Map<String, Object?>)['level'] = 99;
    expect(
      ((personas.get('external')!.toJson()['extensions']! as Map<String, Object?>)['vendor']!
          as Map<String, Object?>)['level'],
      4,
    );
    await personas.update('external', name: '新名字');
    await reopenPersonas();
    final persisted = jsonDecode(await file.readAsString()) as Map<String, Object?>;
    expect(persisted['futureRoot'], {
      'nested': [1, null, '雪'],
    });
    expect(personas.get('external')!.toJson()['extensions'], {
      'vendor': {'level': 4},
    });
    expect(personas.defaultPersonaId, 'external');
    expect(() => personas.list().clear(), throwsUnsupportedError);
  });

  test('ST position constants and deprecated AFTER_CHAR migration are explicit', () {
    expect(PersonaDescriptionPosition.inPrompt, 0);
    expect(PersonaDescriptionPosition.topAuthorNote, 2);
    expect(PersonaDescriptionPosition.bottomAuthorNote, 3);
    expect(PersonaDescriptionPosition.atDepth, 4);
    expect(PersonaDescriptionPosition.none, 9);
    final old = TavernPersona.fromJson({'id': 'old', 'name': '旧', 'descriptionPosition': 1});
    expect(old.descriptionPosition, 0);
    expect(old.inPrompt, isTrue);
    for (final position in [2, 3, 4, 9, 42]) {
      final persona = old.copyWith(descriptionPosition: position);
      expect(persona.descriptionPosition, position);
      expect(persona.inPrompt, isFalse);
      expect(TavernPersona.fromJson(persona.toJson()).descriptionPosition, position);
    }
    expect(() => TavernPersona.fromJson({'id': 'bad', 'name': '错', 'descriptionPosition': 1.5}), throwsFormatException);
  });

  test('model validation rejects malformed known fields without altering input', () {
    final data = <String, Object?>{
      'id': 'raw',
      'name': ' 名字 ',
      'description': '\r\n',
      'extra': {
        'values': [1, 2],
      },
    };
    final persona = TavernPersona.fromJson(data);
    (data['extra']! as Map<String, Object?>)['values'] = [99];
    expect(persona.toJson()['extra'], {
      'values': [1, 2],
    });
    for (final patch in <Map<String, Object?>>[
      {'id': ''},
      {'name': 1},
      {'description': false},
      {'avatarPath': 8},
      {'descriptionPosition': '0'},
    ]) {
      expect(() => TavernPersona.fromJson({...data, ...patch}), throwsFormatException);
    }
  });

  test('binding takes precedence over default and null binding inherits', () async {
    final chat = chats.createChat(characterId: 'card');
    expect(personas.forChat(chats, chat).source, PersonaSelectionSource.none);
    final first = await personas.create(name: '默认一');
    final second = await personas.create(name: '绑定');
    final third = await personas.create(name: '默认二');
    await personas.setDefault(first.id);
    expect(personas.forChat(chats, chat).persona!.id, first.id);
    expect(personas.forChat(chats, chat).source, PersonaSelectionSource.globalDefault);
    await personas.bindChat(chats, chat, second.id);
    await personas.setDefault(third.id);
    final bound = personas.forChat(chats, chat);
    expect(bound.persona!.id, second.id);
    expect(bound.boundPersonaId, second.id);
    expect(bound.defaultPersonaId, third.id);
    expect(bound.source, PersonaSelectionSource.chat);
    await personas.bindChat(chats, chat, null);
    expect(chats.chat(chat).personaId, isNull);
    expect(personas.forChat(chats, chat).persona!.id, third.id);
    await personas.setDefault(null);
    expect(personas.forChat(chats, chat).persona, isNull);
    expect(personas.defaultPersonaId, isNull);
  });

  test('global default and SQLite binding both survive independent reopening', () async {
    final first = await personas.create(name: '默认');
    final second = await personas.create(name: '绑定');
    final chat = chats.createChat(characterId: 'card');
    await personas.setDefault(first.id);
    await personas.bindChat(chats, chat, second.id);
    await reopenPersonas();
    await chats.close();
    chats = ChatStore.open('${directory.path}/chats.sqlite');
    expect(personas.forChat(chats, chat).persona!.id, second.id);
    expect(personas.defaultPersonaId, first.id);
    await personas.bindChat(chats, chat, null);
    expect(personas.forChat(chats, chat).persona!.id, first.id);
  });

  test('unknown ids fail without changing profiles, defaults or chat metadata', () async {
    final persona = await personas.create(name: '有名');
    final chat = chats.createChat(characterId: 'card', metadata: {'retained': true});
    await personas.setDefault(persona.id);
    await personas.bindChat(chats, chat, persona.id);
    await expectLater(personas.setDefault('missing'), throwsStateError);
    await expectLater(personas.bindChat(chats, chat, 'missing'), throwsStateError);
    await expectLater(personas.bindChat(chats, 'missing-chat', persona.id), throwsStateError);
    await expectLater(personas.update('missing', name: 'new'), throwsStateError);
    expect(personas.get('missing'), isNull);
    expect(personas.defaultPersonaId, persona.id);
    expect(chats.chat(chat).personaId, persona.id);
    expect(chats.chat(chat).metadata, {'retained': true});
  });

  test('delete clears all matching bindings and preserves history and avatar', () async {
    final avatar = File('${directory.path}/caller-avatar.png');
    await avatar.writeAsBytes([1, 2, 3]);
    final removed = await personas.create(name: '旧人设', avatarPath: avatar.path);
    final fallback = await personas.create(name: '剩下的人设');
    await personas.setDefault(fallback.id);
    final a = chats.createChat(characterId: 'card', personaId: removed.id);
    final b = chats.createChat(characterId: 'other-card', personaId: removed.id);
    final c = chats.createChat(characterId: 'card', personaId: fallback.id);
    final old = chats.append(a, parentId: null, role: TavernRole.user, speaker: removed.name, text: '当时的消息');
    expect(await personas.delete(removed.id, chats: chats), isTrue);
    expect(chats.chat(a).personaId, isNull);
    expect(chats.chat(b).personaId, isNull);
    expect(chats.chat(c).personaId, fallback.id);
    expect(personas.forChat(chats, a).persona!.id, fallback.id);
    expect(chats.message(a, old.nodeId).speaker, '旧人设');
    expect(chats.message(a, old.nodeId).text, '当时的消息');
    expect(await avatar.readAsBytes(), [1, 2, 3]);
    expect(personas.get(removed.id), isNull);
    await reopenPersonas();
    expect(personas.get(removed.id), isNull);
    expect(personas.defaultPersonaId, fallback.id);
  });

  test('deleting the global default leaves null and never picks an arbitrary profile', () async {
    final selected = await personas.create(name: '默认');
    await personas.create(name: '没有被选中的另一个');
    final chat = chats.createChat(characterId: 'card', personaId: selected.id);
    await personas.setDefault(selected.id);
    await personas.delete(selected.id, chats: chats);
    expect(personas.defaultPersonaId, isNull);
    expect(personas.forChat(chats, chat).persona, isNull);
    expect(personas.forChat(chats, chat).source, PersonaSelectionSource.none);
    await reopenPersonas();
    expect(personas.defaultPersonaId, isNull);
  });

  test('dangling bindings safely fall back and repeated delete clears them', () async {
    final fallback = await personas.create(name: '默认');
    await personas.setDefault(fallback.id);
    final chat = chats.createChat(characterId: 'card', personaId: 'previously-deleted');
    final selection = personas.forChat(chats, chat);
    expect(selection.persona!.id, fallback.id);
    expect(selection.boundPersonaId, isNull);
    expect(selection.source, PersonaSelectionSource.globalDefault);
    expect(await personas.delete('previously-deleted', chats: chats), isFalse);
    expect(chats.chat(chat).personaId, isNull);
    expect(personas.defaultPersonaId, fallback.id);
  });

  test('queued field edits read the latest commit instead of losing earlier edits', () async {
    final persona = await personas.create(name: '开始', description: '旧描述');
    final rename = personas.update(persona.id, name: '新名字');
    final describe = personas.update(persona.id, description: '新描述');
    final choose = personas.setDefault(persona.id);
    await Future.wait([rename, describe, choose]);
    expect(personas.get(persona.id)!.name, '新名字');
    expect(personas.get(persona.id)!.description, '新描述');
    expect(personas.defaultPersonaId, persona.id);
    await reopenPersonas();
    expect(personas.get(persona.id)!.name, '新名字');
    expect(personas.get(persona.id)!.description, '新描述');
  });

  test('temporary-file failure preserves committed bytes and recovers the queue', () async {
    final persona = await personas.create(name: '已提交');
    final before = await indexFile().readAsBytes();
    final obstruction = Directory('${indexFile().path}.writing');
    await obstruction.create();
    var events = 0;
    final subscription = personas.changes.listen((_) => events++);
    addTearDown(subscription.cancel);
    await expectLater(personas.update(persona.id, name: '未提交'), throwsA(isA<FileSystemException>()));
    await Future<void>.delayed(Duration.zero);
    expect(personas.get(persona.id)!.name, '已提交');
    expect(await indexFile().readAsBytes(), before);
    expect(events, 0);
    await obstruction.delete();
    await personas.update(persona.id, name: '恢复后提交');
    await Future<void>.delayed(Duration.zero);
    expect(events, 1);
    expect(personas.get(persona.id)!.name, '恢复后提交');
    await reopenPersonas();
    expect(personas.get(persona.id)!.name, '恢复后提交');
  });

  test('failed SQLite cleanup rolls every binding back and repeated delete repairs it', () async {
    await chats.close();
    final database = sqlite3.openInMemory();
    chats = ChatStore.fromDatabase(database, clock: () => DateTime.utc(2026));
    final persona = await personas.create(name: '待删除');
    await personas.setDefault(persona.id);
    chats.createChat(id: 'a-first', characterId: 'card', personaId: persona.id);
    chats.createChat(id: 'z-blocked', characterId: 'card', personaId: persona.id);
    database.execute('''
      CREATE TRIGGER fail_persona_cleanup BEFORE UPDATE OF persona_id ON chats
      WHEN OLD.id = 'z-blocked' AND NEW.persona_id IS NULL
      BEGIN SELECT RAISE(ABORT, 'test persona cleanup failure'); END;
    ''');
    await expectLater(personas.delete(persona.id, chats: chats), throwsA(isA<SqliteException>()));
    expect(personas.get(persona.id), isNull);
    expect(personas.defaultPersonaId, isNull);
    expect(chats.chat('a-first').personaId, persona.id);
    expect(chats.chat('z-blocked').personaId, persona.id);
    expect(personas.forChat(chats, 'a-first').persona, isNull);
    database.execute('DROP TRIGGER fail_persona_cleanup');
    expect(await personas.delete(persona.id, chats: chats), isFalse);
    expect(chats.chat('a-first').personaId, isNull);
    expect(chats.chat('z-blocked').personaId, isNull);
  });

  test('a closed database is rejected before committing profile deletion', () async {
    final persona = await personas.create(name: '保留');
    await personas.setDefault(persona.id);
    final before = await indexFile().readAsBytes();
    await chats.close();
    await expectLater(personas.delete(persona.id, chats: chats), throwsStateError);
    expect(personas.get(persona.id)!.name, '保留');
    expect(personas.defaultPersonaId, persona.id);
    expect(await indexFile().readAsBytes(), before);
  });

  test('committed index wins over a leftover staging file and BOM is accepted', () async {
    final persona = await personas.create(name: '有效提交');
    await personas.close();
    final committed = await indexFile().readAsString();
    await indexFile().writeAsString('\uFEFF$committed');
    await File('${indexFile().path}.writing').writeAsString('{"version":1,"personas":[');
    personas = await PersonaStore.open(directory, createId: nextId);
    expect(personas.get(persona.id)!.name, '有效提交');
    await personas.update(persona.id, name: '再次提交');
    await reopenPersonas();
    expect(personas.get(persona.id)!.name, '再次提交');
    expect(await File('${indexFile().path}.writing').exists(), isFalse);
  });

  test('malformed, future and inconsistent indexes fail without resetting bytes', () async {
    await personas.close();
    final file = indexFile();
    await file.parent.create(recursive: true);
    final profile = {'id': 'p', 'name': '有效'};
    final cases = [
      '{broken',
      '[]',
      jsonEncode({
        'version': 2,
        'personas': [profile],
      }),
      jsonEncode({
        'version': 1,
        'personas': [profile, profile],
      }),
      jsonEncode({'version': 1, 'personas': 'wrong'}),
      jsonEncode({
        'version': 1,
        'personas': [false],
      }),
      jsonEncode({
        'version': 1,
        'personas': [profile],
        'defaultPersonaId': 'missing',
      }),
    ];
    for (final value in cases) {
      await file.writeAsString(value);
      await expectLater(PersonaStore.open(directory), throwsFormatException);
      expect(await file.readAsString(), value);
    }
  });

  test('a directory at the index path is an error rather than an empty library', () async {
    await personas.close();
    await Directory(indexFile().path).create(recursive: true);
    await expectLater(PersonaStore.open(directory), throwsA(isA<FileSystemException>()));
    expect(await Directory(indexFile().path).exists(), isTrue);
  });

  test('a captured persona snapshot is stable while later turns see edits', () async {
    final persona = await personas.create(name: '本回合', description: '旧 {{user}}');
    final chat = chats.createChat(characterId: 'card');
    await personas.setDefault(persona.id);
    final captured = personas.forChat(chats, chat);
    final message = chats.append(
      chat,
      parentId: null,
      role: TavernRole.user,
      speaker: captured.persona!.name,
      text: '旧话',
    );
    await personas.update(persona.id, name: '下回合', description: '新 {{user}}');
    expect(captured.persona!.name, '本回合');
    expect(captured.persona!.description, '旧 {{user}}');
    expect(personas.forChat(chats, chat).persona!.name, '下回合');
    expect(personas.forChat(chats, chat).persona!.description, '新 {{user}}');
    expect(chats.message(chat, message.nodeId).speaker, '本回合');
  });

  test('close drains queued writes without waiting for paused notification listeners', () async {
    final subscription = personas.changes.listen((_) {})..pause();
    addTearDown(subscription.cancel);
    final created = personas.create(name: '关闭前排队');
    final closing = personas.close();
    expect(() => personas.create(name: '太晚'), throwsStateError);
    expect(() => personas.list(), throwsStateError);
    final persona = await created;
    await closing.timeout(const Duration(seconds: 5));
    await subscription.cancel();
    await personas.close();
    personas = await PersonaStore.open(directory, createId: nextId);
    expect(personas.get(persona.id)!.name, '关闭前排队');
  });

  test('a duplicate generated id fails without overwriting an existing persona', () async {
    await personas.close();
    personas = await PersonaStore.open(directory, createId: () => 'fixed-id');
    await personas.create(name: '原有');
    await expectLater(personas.create(name: '冲突'), throwsStateError);
    expect(personas.list().map((persona) => persona.name), ['原有']);
    await personas.update('fixed-id', name: '队列仍可用');
    expect(personas.get('fixed-id')!.name, '队列仍可用');
  });
}

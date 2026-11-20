import 'dart:io';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:test/test.dart';

import 'p2_script_test_support.dart';

void main() {
  test('group titles reject trimmed emptiness while null creation and update keep their distinct meanings', () async {
    final h = await ScriptFixture.open();
    final host = await h.card('Host name');
    final blank = await h.card(' \t ');
    await h.engine.updateCharacterFields(host, {'nickname': 'Nickname is not the title'});
    final invalid = isA<TavernGroupException>().having((error) => error.code, 'code', TavernGroupError.invalidTitle);
    for (final title in ['', ' \t\n ']) {
      await expectLater(h.engine.createGroupChat([host], title: title, addGreetings: false), throwsA(invalid));
    }
    await expectLater(h.engine.createGroupChat([blank], addGreetings: false), throwsA(invalid));
    expect(h.inspect((db) => db.select('SELECT id FROM chats')), isEmpty);
    final chat = await h.engine.createGroupChat([host], title: null, addGreetings: false);
    expect((await h.engine.groupChat(chat))!.title, 'Host name');
    await h.engine.updateGroupChat(chat, title: '  Saved title  ');
    for (final title in ['', ' \t\n ']) {
      await expectLater(h.engine.updateGroupChat(chat, title: title), throwsA(invalid));
      expect((await h.engine.groupChat(chat))!.title, '  Saved title  ');
    }
    expect((await h.engine.updateGroupChat(chat, title: null)).title, '  Saved title  ');
    expect((await h.engine.updateGroupChat(chat)).title, '  Saved title  ');
    expect(await h.engine.path(chat), isEmpty);
    expect(h.inspect((db) => db.select('SELECT id FROM chats')), hasLength(1));
    await h.reopen();
    expect((await h.engine.groupChat(chat))!.title, '  Saved title  ');
    h.expectNoGeneration();
  });

  test('nine-member append edit and display project raw names without opening unrelated original files', () async {
    final h = await ScriptFixture.open();
    final ids = <String>[];
    for (var index = 0; index < 9; index++) {
      ids.add(await h.card(index == 0 ? 'Host' : 'Member$index'));
    }
    for (final entry in <int, String>{1: '  Raw  ', 2: ' ', 3: '', 4: 'Duplicate', 5: 'Duplicate'}.entries) {
      await h.engine.updateCharacterFields(ids[entry.key], {'nickname': entry.value});
    }
    final chat = await h.engine.createGroupChat(ids, addGreetings: false);
    await h.engine.updateGroupMember(chat, ids[4], muted: true);
    await h.engine.setSettings({
      'globalRegexScripts': [
        {
          'id': 'group-names',
          'scriptName': 'group names',
          'findRegex': '/DISPLAY/g',
          'replaceString': 'ALL({{group}}) ACTIVE({{groupNotMuted}})',
          'trimStrings': <String>[],
          'placement': [2],
          'disabled': false,
          'markdownOnly': true,
          'promptOnly': false,
          'runOnEdit': true,
          'substituteRegex': 0,
        },
      ],
    });
    // Clear the eight-entry full-card cache. Every non-host original is then
    // physically unavailable, while its authoritative JSON and summary remain.
    // This checks an actual file dependency; it does not claim a timing result.
    final moved = <({File current, String original})>[];
    await h.reopen(
      whileClosed: () async {
        for (var index = 1; index < ids.length; index++) {
          final source = File('${h.root.path}/characters/${ids[index]}/original.json');
          final current = await source.rename('${h.root.path}/unneeded-original-$index.json');
          moved.add((current: current, original: source.path));
        }
      },
    );
    try {
      const names = ['Host', '  Raw  ', ' ', 'Member3', 'Duplicate', 'Duplicate', 'Member6', 'Member7', 'Member8'];
      final active = [
        for (var index = 0; index < names.length; index++)
          if (index != 4) names[index],
      ];
      final expected = 'ALL(${names.join(', ')}) ACTIVE(${active.join(', ')})';
      final message = await h.engine.sendOnly(chat, 'ALL({{group}}) ACTIVE({{groupNotMuted}})');
      expect(message.text, expected);
      await h.engine.edit(chat, message.nodeId, 'EDIT ALL({{group}}) ACTIVE({{groupNotMuted}})');
      expect((await h.engine.path(chat)).single.text, 'EDIT $expected');
      final displayed = await h.engine.displayText(chat, text: 'DISPLAY', role: TavernRole.character);
      expect(displayed.text, expected);
      expect((await h.engine.groupChat(chat))!.members, hasLength(9));
      h.expectNoGeneration();
    } finally {
      for (final file in moved) {
        await file.current.rename(file.original);
      }
    }
  });

  test('header-only export uses current root metadata and variables while retaining opaque header fields', () {
    final store = ChatStore.inMemory();
    addTearDown(store.close);
    var serial = 0;
    final codec = ChatJsonlCodec(createIntegrity: () => 'new-${serial++}');
    final chat = codec
        .importBatch(
          store,
          characterId: 'card',
          documents: [
            StChatDocument(
              fileName: 'header-only.jsonl',
              header: {
                'user_name': 'User',
                'character_name': 'Card',
                'unknown_header': {
                  'keep': [false, null, 'raw'],
                },
                'chat_metadata': {
                  'note_prompt': 'OLD_NOTE',
                  'remove_me': {'old': true},
                  'variables': {'old': 1},
                  'unknown_root': {
                    'kept': [1, null],
                  },
                  'script_injects': {
                    'old': {'value': 'OLD_INJECTION'},
                  },
                },
              },
              messages: const [],
            ),
          ],
        )
        .chatIds
        .single;
    final root = store.chat(chat).metadata;
    root['note_prompt'] = 'NEW_NOTE';
    root.remove('remove_me');
    root['script_injects'] = {
      'new': {'value': 'NEW_INJECTION'},
    };
    root['new_root'] = {'later': true};
    store.updateChat(chat, metadata: root, variables: {'current': 2});
    final exported = codec.exportChat(store, chat).single;
    expect(exported.messages, isEmpty);
    expect(exported.header['unknown_header'], {
      'keep': [false, null, 'raw'],
    });
    final metadata = scriptMap(exported.header['chat_metadata']);
    expect(metadata['note_prompt'], 'NEW_NOTE');
    expect(metadata.containsKey('remove_me'), isFalse);
    expect(metadata['unknown_root'], {
      'kept': [1, null],
    });
    expect(metadata['new_root'], {'later': true});
    expect(metadata['script_injects'], {
      'new': {'value': 'NEW_INJECTION'},
    });
    expect(metadata['variables'], {'current': 2});
  });

  test(
    'a message batch normalizes identity at the final role and never revives identity cleared by an earlier call',
    () async {
      final h = await ScriptFixture.open();
      final a = await h.card('A');
      final b = await h.card('B');
      final chat = await h.emptyChat(a);
      final context = await h.context(chat, characterId: a);
      final created = await h.bridge.createChatMessages(context.id, [
        TavernScriptMessageDraft(role: TavernScriptRole.assistant, message: 'BODY', speakerCharacterId: a),
      ], options: const TavernScriptWriteOptions(refresh: TavernScriptRefresh.none));
      final ref = created.upsertMessages.single.ref;
      Future<TavernMessage> current() async => (await h.engine.path(chat)).single;
      Future<void> write(List<Map<String, Object?>> fields) async {
        await h.bridge.setChatMessages(context.id, [
          for (final value in fields) TavernScriptMessagePatch(ref: ref, fields: value),
        ], options: const TavernScriptWriteOptions(refresh: TavernScriptRefresh.none));
      }

      await write([
        {'role': 'user'},
        {'role': 'assistant'},
      ]);
      expect(((await current()).role, (await current()).speakerCharacterId), (TavernRole.character, a));
      await write([
        {'role': 'user'},
        {'speakerCharacterId': b},
        {'role': 'assistant'},
      ]);
      expect((await current()).speakerCharacterId, b);
      await write([
        {'role': 'user'},
        {'speakerCharacterId': a},
      ]);
      expect(((await current()).role, (await current()).speakerCharacterId), (TavernRole.user, null));
      await write([
        {'role': 'assistant'},
      ]);
      expect(((await current()).role, (await current()).speakerCharacterId), (TavernRole.character, null));
      await write([
        {'speakerCharacterId': a},
        {'role': 'system'},
      ]);
      expect(((await current()).role, (await current()).speakerCharacterId), (TavernRole.system, null));
      await write([
        {'speakerCharacterId': b},
        {'role': 'assistant'},
      ]);
      expect((await current()).speakerCharacterId, b);
      await write([
        {'speakerCharacterId': null},
      ]);
      expect((await current()).speakerCharacterId, isNull);
      await h.reopen();
      expect(((await current()).role, (await current()).speakerCharacterId), (TavernRole.character, null));
      h.expectNoGeneration();
    },
  );
}

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:test/test.dart';

import 'support/t24_engine_harness.dart';

void main() {
  test('createChat preserves literal greeting edges and raw alternate indexes through persistence', () async {
    final h = await _open();
    await h.engine.updateCharacterFields(h.characterId, {
      'first_mes': ' G ',
      'alternate_greetings': ['', ' ALT '],
    });
    final fields = (await h.engine.characterFields(h.characterId))!;
    expect(fields['first_mes'], ' G ');
    expect(fields['alternate_greetings'], ['', ' ALT ']);

    final defaultChat = await h.engine.createChat(h.characterId);
    final first = (await h.engine.path(defaultChat)).single;
    expect(first.role, TavernRole.character);
    expect(first.parentId, isNull);
    // First defect oracle: the old product returns 'G' after the same setup.
    expect(first.text, ' G ');

    final alternateChat = await h.engine.createChat(h.characterId, greeting: 2);
    final alternate = (await h.engine.path(alternateChat)).single;
    final emptyChat = await h.engine.createChat(h.characterId, greeting: 1);
    final empty = (await h.engine.path(emptyChat)).single;
    final expected = [
      (chat: defaultChat, nodeId: first.nodeId, text: ' G ', index: 0),
      (chat: alternateChat, nodeId: alternate.nodeId, text: ' ALT ', index: 2),
      (chat: emptyChat, nodeId: empty.nodeId, text: '', index: 1),
    ];
    for (final row in expected) {
      final node = (await h.engine.path(row.chat)).single;
      expect((node.nodeId, node.text, node.parentId), (row.nodeId, row.text, null));
      expect(node.role, TavernRole.character);
      final document = await _export(h, row.chat);
      final metadata = document.header['chat_metadata']! as Map<String, Object?>;
      expect(metadata['greetingIndex'], row.index);
      expect(document.messages.single['mes'], row.text);
    }
    expect(h.model.generated, 0);

    await h.reopen();
    for (final row in expected) {
      final node = (await h.engine.path(row.chat)).single;
      expect((node.nodeId, node.text, node.parentId), (row.nodeId, row.text, null));
      final document = await _export(h, row.chat);
      final metadata = document.header['chat_metadata']! as Map<String, Object?>;
      expect(metadata['greetingIndex'], row.index);
      expect(document.messages.single['mes'], row.text);
    }
    final savedFields = (await h.engine.characterFields(h.characterId))!;
    expect(savedFields['first_mes'], ' G ');
    expect(savedFields['alternate_greetings'], ['', ' ALT ']);
    expect(h.model.generated, 0);
  });

  test('createChat applies AI_OUTPUT before whole greeting macros and CR removal', () async {
    final h = await _open();
    const raw = ' RAW {{incvar::n}}\r ';
    await h.engine.updateCharacterFields(h.characterId, {'first_mes': raw});
    await h.engine.setSettings({
      'globalRegexScripts': [
        {
          'id': 'raw-greeting-prefix',
          'scriptName': 'raw-greeting-prefix',
          // Match only the prefix. The macro stays outside the replacement,
          // so regex replacement expansion cannot stand in for whole expansion.
          'findRegex': r'^ RAW (?=\{\{incvar::n\}\}\r $)',
          'replaceString': ' BEFORE ',
          'trimStrings': <String>[],
          'placement': [2],
          'disabled': false,
          'markdownOnly': false,
          'promptOnly': false,
          'runOnEdit': false,
          'substituteRegex': 0,
          'minDepth': null,
          'maxDepth': null,
        },
      ],
    });
    expect((await h.engine.characterFields(h.characterId))!['first_mes'], raw);
    final chat = await h.engine.createChat(h.characterId);
    final first = (await h.engine.path(chat)).single;
    // This is the package's existing order, not a full ST creation execution.
    expect(first.text, ' BEFORE 1 ');
    expect(h.engine.variables(chat), {'n': 1});
    final document = await _export(h, chat);
    final metadata = document.header['chat_metadata']! as Map<String, Object?>;
    expect(document.messages.single['mes'], ' BEFORE 1 ');
    expect(metadata['variables'], {'n': 1});
    expect(metadata['greetingIndex'], 0);
    expect(h.model.generated, 0);

    await h.reopen();
    final saved = (await h.engine.path(chat)).single;
    expect((saved.nodeId, saved.text), (first.nodeId, ' BEFORE 1 '));
    expect(h.engine.variables(chat), {'n': 1});
    expect(h.model.generated, 0);
  });
}

Future<T24Harness> _open() async {
  final h = await T24Harness.open();
  addTearDown(h.dispose);
  await h.engine.setSettings({'macroEngine': 'modern'});
  return h;
}

Future<StChatDocument> _export(T24Harness h, String chatId) async {
  final file = (await h.engine.exportChat(chatId)).single;
  return StChatDocument.decode(file.fileName, file.bytes);
}

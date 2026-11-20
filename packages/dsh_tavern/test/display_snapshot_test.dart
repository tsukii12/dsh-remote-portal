import 'dart:convert';
import 'dart:typed_data';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:test/test.dart';

import 'support/t24_engine_harness.dart';

void main() {
  test('display snapshots keep hidden tail, narrator, idle time and off-path macro context', () async {
    for (final mode in ['modern', 'legacy']) {
      final h = await T24Harness.open();
      addTearDown(h.dispose);
      await h.engine.setSettings({'macroEngine': mode});
      final chat = await _import(h, [
        _row('U-old', minute: 50, user: true),
        _row('C-old', minute: 51),
        _row('U-last', minute: 58, user: true),
        _row('Stage', minute: 59, narrator: true),
        _row('Hidden', minute: 59, user: true, hidden: true),
      ]);
      final range = mode == 'legacy' ? '|{{allChatRange}}' : '';
      await h.engine.importRegexScripts(
        jsonEncode(
          _rule(
            '{{lastMessage}}|{{lastMessageId}}|{{lastUserMessage}}|{{lastCharMessage}}|'
            '{{idle_duration}}|{{lastSwipeId}}|{{currentSwipeId}}$range',
          ),
        ),
      );
      final path = await h.engine.path(chat);
      final wholeRange = mode == 'legacy' ? '|0-4' : '';
      final expected = 'D|4|U-last|Stage|2 minutes|1|1$wholeRange';
      expect((await h.engine.displayText(chat, nodeId: path.last.nodeId, text: 'D')).text, expected);
      expect((await h.engine.displayText(chat, nodeId: path.last.nodeId, text: 'D')).text, expected);
      expect(
        (await h.engine.displayText(chat, nodeId: path.last.nodeId, text: 'D', reasoning: true)).text,
        'Hidden|4|U-last|Stage|2 minutes|1|1$wholeRange',
      );
      expect(
        (await h.engine.displayText(chat, nodeId: path[2].nodeId, text: 'D')).text,
        'Hidden|4|D|Stage|2 minutes|1|1$wholeRange',
      );
      await h.engine.selectNode(chat, path[2].nodeId);
      final userRange = mode == 'legacy' ? '|0-2' : '';
      expect((await h.engine.displayText(chat, text: 'D')).text, 'U-last|2|U-last|C-old|10 minutes|1|1$userRange');
      await h.engine.selectNode(chat, path[1].nodeId);
      expect((await h.engine.displayText(chat, nodeId: path.last.nodeId, text: 'D')).text, expected);
      final shortRange = mode == 'legacy' ? '|0-1' : '';
      expect((await h.engine.displayText(chat, text: 'D')).text, 'C-old|1|U-old|C-old|10 minutes|1|1$shortRange');
      expect((await h.engine.path(chat)).map((message) => message.text), ['U-old', 'C-old']);
      await h.engine.deleteMessage(chat, path.first.nodeId);
      final rootRange = mode == 'legacy' ? '|0-0' : '';
      expect((await h.engine.displayText(chat, text: 'D')).text, 'C-old|0||C-old|just now|1|1$rootRange');
    }
  });

  test('cached display follows committed message state and current card persona settings and regex', () async {
    final h = await T24Harness.open();
    addTearDown(h.dispose);
    final first = (await h.engine.path(h.chatId)).single;
    await h.engine.edit(h.chatId, first.nodeId, 'G{{setvar::n::old}}');
    await h.engine.setGlobalVariables({'g': 'one'});
    final rule = (await h.engine.importRegexScripts(
      jsonEncode(_rule('{{lastMessage}}|{{getvar::n}}|{{char}}|{{user}}|{{getglobalvar::g}}')),
    )).scripts.single;
    Future<String> display() async => (await h.engine.displayText(h.chatId, text: 'D')).text;
    expect(await display(), 'G|old|Guide|User|one');
    expect(await display(), 'G|old|Guide|User|one');
    await h.engine.setGlobalVariables({'g': 'two'});
    await h.engine.setSettings({'userName': 'Reader'});
    await h.engine.updateCharacterFields(h.characterId, {'name': 'NewGuide'});
    expect(await display(), 'G|old|NewGuide|Reader|two');
    final persona = await h.engine.createPersona(name: 'Persona');
    await h.engine.setDefaultPersona(persona.id);
    expect(await display(), 'G|old|NewGuide|Persona|two');
    await h.engine.edit(h.chatId, first.nodeId, 'G2{{setvar::n::new}}');
    expect(await display(), 'G2|new|NewGuide|Persona|two');
    await h.engine.updateRegexScript(rule.id, {'replaceString': 'new={{lastMessage}}'});
    expect(await display(), 'new=G2');
    expect(h.engine.variables(h.chatId)['n'], 'new');
  });
}

Map<String, Object?> _rule(String replacement) => {
  'id': 'display-snapshot',
  'scriptName': 'display snapshot',
  'findRegex': r'/^D$/g',
  'replaceString': replacement,
  'trimStrings': <String>[],
  'placement': [1, 2, 3, 6],
  'disabled': false,
  'markdownOnly': true,
  'promptOnly': false,
  'runOnEdit': true,
  'substituteRegex': 0,
};

Map<String, Object?> _row(
  String text, {
  required int minute,
  bool user = false,
  bool hidden = false,
  bool narrator = false,
}) => {
  'name': user
      ? 'User'
      : narrator
      ? 'Stage'
      : 'Guide',
  'is_user': user,
  'is_system': hidden,
  'send_date': DateTime.utc(2026, 11, 10, 11, minute).toIso8601String(),
  'mes': text,
  'extra': <String, Object?>{if (narrator) 'type': 'narrator'},
};

Future<String> _import(T24Harness h, List<Map<String, Object?>> rows) async {
  final text = [
    jsonEncode({
      'user_name': 'User',
      'character_name': 'Guide',
      'create_date': '2026-11-10T11:00:00Z',
      'chat_metadata': <String, Object?>{},
    }),
    ...rows.map(jsonEncode),
  ].join('\n');
  return (await h.engine.importChats(h.characterId, [
    TavernChatFile(fileName: 'display-snapshot.jsonl', bytes: Uint8List.fromList(utf8.encode(text))),
  ])).chatIds.single;
}

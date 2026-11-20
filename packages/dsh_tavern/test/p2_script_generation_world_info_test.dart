import 'dart:io';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:test/test.dart';

import 'p2_script_generation_test_support.dart';

void main() {
  test('raw WI shares one scan and its real ten-message clock ignores overrides hidden rows and new input', () async {
    final h = await generationFixture();
    final character = await h.card('World clock');
    final chat = await h.emptyChat(character);
    final context = await h.context(chat, characterId: character);
    await h.bridge.createChatMessages(context.id, [
      for (var index = 0; index < 10; index++)
        TavernScriptMessageDraft(
          role: index.isEven ? TavernScriptRole.user : TavernScriptRole.assistant,
          message: index == 0 ? 'REALKEY' : 'old-$index',
        ),
      TavernScriptMessageDraft(role: TavernScriptRole.user, message: 'HIDDENKEY', hidden: true),
      TavernScriptMessageDraft(role: TavernScriptRole.system, message: 'SYSTEMKEY'),
    ]);
    await h.bridge.replaceVariables(context.id, scriptGlobal, {'before': 0, 'after': 0});
    await h.engine.putLorebook(
      'b2-clock',
      _book([
        {
          'key': ['REALKEY'],
          'content': 'BEFORE{{incglobalvar::before}}',
          'sticky': 3,
        },
        {
          'key': ['INPUTKEY'],
          'content': 'UNREQUESTED{{incglobalvar::after}}',
          'position': 1,
          'sticky': 2,
        },
        {
          'key': ['HIDDENKEY'],
          'content': 'BAD-HIDDEN',
        },
        {
          'key': ['SYSTEMKEY'],
          'content': 'BAD-SYSTEM',
        },
      ]),
    );
    await h.engine.bindLorebooks(['b2-clock']);
    final before = (await h.engine.path(
      chat,
    )).map((message) => (message.nodeId, message.text, message.hidden)).toList();
    final response = h.reply('done');
    final generation = await h.bridge.generateRaw(
      context.id,
      TavernScriptRawRequest(
        userInput: 'INPUTKEY {{maxcontext}}/{{maxresponse}}/{{maxprompt}}',
        maxChatHistory: 0,
        samplingOverrides: {'max_tokens': 5},
        overrides: TavernScriptPromptOverrides(
          fields: {
            'chatHistory': [
              {'role': 'user', 'content': 'FAKE ONE-LINE HISTORY'},
            ],
            'withDepthEntries': false,
          },
        ),
        orderedPrompts: const [
          TavernScriptPromptPart.literal(role: TavernScriptPromptRole.system, content: 'EXPLICIT SYS'),
          TavernScriptPromptPart.placeholder(TavernScriptPromptPlaceholder.worldInfoBefore),
          TavernScriptPromptPart.placeholder(TavernScriptPromptPlaceholder.chatHistory),
          TavernScriptPromptPart.placeholder(TavernScriptPromptPlaceholder.worldInfoBefore),
          TavernScriptPromptPart.placeholder(TavernScriptPromptPlaceholder.userInput),
        ],
      ),
    );
    final wire = await generationRequest(generation, response);
    await generation.result;
    expect(wire.body, {
      'model': 'p2-script-model',
      'stream': false,
      'max_tokens': 5,
      'messages': [
        {'role': 'system', 'content': 'EXPLICIT SYS'},
        {'role': 'system', 'content': 'BEFORE1'},
        {'role': 'system', 'content': 'BEFORE1'},
        {'role': 'user', 'content': 'INPUTKEY 4095/300/3795'},
      ],
    });
    expect((await h.bridge.getVariables(context.id, scriptGlobal)).value, {'before': 1, 'after': 1});
    final metadata = await _metadata(h, chat);
    final timed = scriptMap(metadata['timedWorldInfo']);
    final sticky = scriptMap(timed['sticky']);
    expect(sticky, hasLength(2));
    expect(sticky.values.map((value) => scriptMap(value)['start']), everyElement(10));
    final ends = sticky.values.map((value) => scriptMap(value)['end']! as num).toList()..sort();
    expect(ends, [12, 13]);
    expect((await h.engine.path(chat)).map((message) => (message.nodeId, message.text, message.hidden)), before);
    expect(generationNodes(h, chat), hasLength(12));
    await h.reopen();
    expect(scriptMap((await _metadata(h, chat))['timedWorldInfo']), timed);
    expect((await h.engine.path(chat)).map((message) => (message.nodeId, message.text, message.hidden)), before);
    stdout.writeln('P2_B2_WORLD_INFO_READY');
  }, timeout: const Timeout(Duration(seconds: 15)));

  test('one scan-only filter and prepared text can commit WI effects without printing an unrequested outlet', () async {
    final h = await generationFixture();
    final character = await h.card('Scan only');
    final chat = await h.emptyChat(character);
    final context = await h.context(chat, characterId: character);
    await h.bridge.replaceVariables(context.id, scriptGlobal, {'scan': 0});
    await h.engine.putLorebook(
      'b2-scan',
      _book([
        {
          'key': ['SCANKEY'],
          'content': 'UNREQUESTED WORLD BODY',
          'sticky': 4,
        },
      ]),
    );
    await h.engine.bindLorebooks(['b2-scan']);
    final host = GenerationHost();
    host.onInvoke = (request, cancellation) async =>
        TavernScriptCallbackResult(requestId: request.requestId, status: 'completed', value: true);
    h.bridge.attachHost(host);
    await h.bridge.injectPrompts(context.id, [
      TavernScriptInjection(
        id: 'scan',
        content: 'SCANKEY{{incglobalvar::scan}}',
        scan: true,
        position: TavernScriptInjectionPosition.scanOnly,
        filter: TavernScriptCallbackRef(contextId: context.id, instanceId: context.instanceId, callbackId: 'scan'),
      ),
    ], once: true);
    final response = h.reply('done');
    final generation = await h.bridge.generateRaw(
      context.id,
      TavernScriptRawRequest(
        orderedPrompts: const [TavernScriptPromptPart.literal(role: TavernScriptPromptRole.user, content: 'ONLY')],
      ),
    );
    final wire = await generationRequest(generation, response);
    await generation.result;
    expect(generationMessages(wire), [
      {'role': 'user', 'content': 'ONLY'},
    ]);
    expect(wire.body.containsKey('max_tokens'), isFalse);
    expect(host.invocations, hasLength(1));
    expect((await h.bridge.getVariables(context.id, scriptGlobal)).value, {'scan': 1});
    expect((await h.bridge.listInjections(context.id)).single.claimed, isTrue);
    final sticky = scriptMap(scriptMap((await _metadata(h, chat))['timedWorldInfo'])['sticky']);
    expect(sticky, hasLength(1));
    expect(scriptMap(sticky.values.single)['start'], 0);
    expect(scriptMap(sticky.values.single)['end'], 4);
    expect(generationNodes(h, chat), isEmpty);
    await h.reopen();
    expect(scriptMap(scriptMap((await _metadata(h, chat))['timedWorldInfo'])['sticky']), sticky);
    expect(generationNodes(h, chat), isEmpty);
  }, timeout: const Timeout(Duration(seconds: 15)));

  test(
    'a book changed inside a filter affects the next request while the captured request uses its old source once',
    () async {
      final h = await generationFixture();
      final character = await h.card('Book capture');
      final chat = await h.emptyChat(character);
      final context = await h.context(chat, characterId: character);
      await h.engine.putLorebook(
        'b2-captured',
        _book([
          {'constant': true, 'content': 'OLD BOOK'},
        ]),
      );
      await h.engine.bindLorebooks(['b2-captured']);
      final host = GenerationHost();
      host.onInvoke = (request, cancellation) async {
        if (host.invocations.length == 1) {
          await h.engine.putLorebook(
            'b2-captured',
            _book([
              {'constant': true, 'content': 'NEW BOOK'},
            ]),
          );
        }
        return TavernScriptCallbackResult(requestId: request.requestId, status: 'completed', value: true);
      };
      h.bridge.attachHost(host);
      TavernScriptRawRequest request(String id) => TavernScriptRawRequest(
        generationId: id,
        orderedPrompts: const [TavernScriptPromptPart.placeholder(TavernScriptPromptPlaceholder.worldInfoBefore)],
        injects: [
          TavernScriptInjection(
            id: 'gate',
            content: '',
            position: TavernScriptInjectionPosition.scanOnly,
            filter: TavernScriptCallbackRef(
              contextId: context.id,
              instanceId: context.instanceId,
              callbackId: 'change-book',
            ),
          ),
        ],
      );
      final firstResponse = h.reply('first');
      final first = await h.bridge.generateRaw(context.id, request('old-book'));
      final firstWire = await generationRequest(first, firstResponse);
      await first.result;
      expect(generationMessages(firstWire), [
        {'role': 'system', 'content': 'OLD BOOK'},
      ]);
      final secondResponse = h.reply('second');
      final second = await h.bridge.generateRaw(context.id, request('new-book'));
      final secondWire = await generationRequest(second, secondResponse);
      await second.result;
      expect(generationMessages(secondWire), [
        {'role': 'system', 'content': 'NEW BOOK'},
      ]);
      expect(host.invocations, hasLength(2));
      expect(h.requests, hasLength(2));
      expect(h.keyReads, 2);
      expect(generationNodes(h, chat), isEmpty);
    },
    timeout: const Timeout(Duration(seconds: 15)),
  );
}

ScriptJson _book(List<ScriptJson> entries) => {
  'name': 'B2 world book',
  'entries': {
    for (var index = 0; index < entries.length; index++)
      index.toString(): {
        'uid': index,
        'key': <String>[],
        'content': '',
        'constant': false,
        'disable': false,
        'position': 0,
        'order': 100,
        'useProbability': false,
        ...entries[index],
      },
  },
};

Future<ScriptJson> _metadata(ScriptFixture h, String chat) async {
  final file = (await h.engine.exportChat(chat)).first;
  return scriptMap(StChatDocument.decode(file.fileName, file.bytes).header['chat_metadata']);
}

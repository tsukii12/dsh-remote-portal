import 'dart:convert';
import 'dart:io';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:test/test.dart';

import 'p2_script_generation_test_support.dart';

void main() {
  test('raw literal is unscoped, verbatim and never inherits the active preset or a hidden budget', () async {
    final h = await generationFixture();
    final context = await h.bridge.openContext(const TavernScriptContextSpec(instanceId: 'raw-unscoped'));
    final host = GenerationHost();
    h.bridge.attachHost(host);
    final literal = '  {{incglobalvar::must-not-run}} ${List.filled(24000, 'x').join()}  ';
    final parts = <TavernScriptPromptPart>[
      TavernScriptPromptPart.literal(role: TavernScriptPromptRole.user, content: literal),
    ];
    final request = TavernScriptRawRequest(orderedPrompts: parts);
    parts.clear();
    final response = h.reply('literal answer');
    final generation = await h.bridge.generateRaw(context.id, request);
    final wire = await generationRequest(generation, response);
    final result = await generation.result;
    expect(wire.body, {
      'messages': [
        {'role': 'user', 'content': literal},
      ],
      'model': 'p2-script-model',
      'stream': false,
    });
    expect(wire.method, 'POST');
    expect(wire.url, Uri.parse('https://p2-script.invalid/v1/chat/completions'));
    expect(result.text, 'literal answer');
    expect(result.reasoning, isNull);
    expect(result.usage, isNull);
    expect(result.origin.contextId, context.id);
    expect(result.origin.instanceId, 'raw-unscoped');
    expect(result.origin.provider, 'openaiCompatible');
    expect(result.origin.chatId, isNull);
    expect(result.origin.nodeAnchor, isNull);
    expect(result.origin.emptyChatAnchor, isFalse);
    expect(h.engine.globalVariables.containsKey('must-not-run'), isFalse);
    expect(h.inspect((db) => db.select('SELECT COUNT(*) AS n FROM nodes').single['n']), 0);
    expect(host.deliveries.where((e) => e.name == 'MESSAGE_SENT' || e.name == 'MESSAGE_RECEIVED'), isEmpty);
    expect(h.requests, hasLength(1));
    expect(h.keyReads, 1);
    stdout.writeln('P2_B2_RAW_READY');
  }, timeout: const Timeout(Duration(seconds: 15)));

  test('request JSON rejects unsupported options and explicit invalid values before generation', () {
    const literal = {'kind': 'literal', 'role': 'user', 'content': 'Q'};
    for (final fields in <ScriptJson>[
      {'model': 'not-an-override'},
      {
        'samplingOverrides': {
          'stop': ['END'],
        },
      },
      {
        'samplingOverrides': {'reasoning_effort': 'high'},
      },
      {
        'samplingOverrides': {'stream': true},
      },
      {
        'overrides': {
          'chatHistory': [
            {'role': 'user', 'content': 'Q', 'nodeId': 'fake'},
          ],
        },
      },
    ]) {
      expect(
        () => TavernScriptRawRequest.fromJson({
          'orderedPrompts': [literal],
          ...fields,
        }),
        throwsA(scriptError(TavernScriptErrorCode.unsupportedOption)),
      );
    }
    for (final fields in <ScriptJson>[
      {'stream': null},
      {'userInput': null},
      {'silent': 'false'},
      {'overrides': null},
      {'orderedPrompts': null},
      {
        'samplingOverrides': {'max_tokens': 0},
      },
      {
        'samplingOverrides': {'max_tokens': 1.5},
      },
      {
        'samplingOverrides': {'seed': -1},
      },
    ]) {
      expect(
        () => TavernScriptRawRequest.fromJson({
          'orderedPrompts': [literal],
          ...fields,
        }),
        throwsA(scriptError(TavernScriptErrorCode.invalidArgument)),
      );
    }
    expect(
      () => TavernScriptRawRequest.fromJson({
        'orderedPrompts': [literal],
        'samplingOverrides': {'temperature': double.infinity},
      }),
      throwsA(scriptError(TavernScriptErrorCode.invalidJson)),
    );
    expect(() => TavernScriptGenerateRequest(maxChatHistory: -1), throwsA(scriptError(TavernScriptErrorCode.range)));
    expect(
      () => TavernScriptRawRequest(
        orderedPrompts: [],
        injects: [
          TavernScriptInjection(id: 'same', content: 'one'),
          TavernScriptInjection(id: 'same', content: 'two'),
        ],
      ),
      throwsA(scriptError(TavernScriptErrorCode.duplicateId)),
    );
    expect(
      () => TavernScriptInjection(id: 'too-deep', content: '', depth: 10001),
      throwsA(scriptError(TavernScriptErrorCode.range)),
    );
  });

  test('repeated raw sources prepare once while macros use the complete real path and unused input is empty', () async {
    final h = await generationFixture();
    final character = await h.card(
      'Sources',
      description: 'DESC{{incglobalvar::desc}}/{{lastMessageId}}/{{lastMessage}}/{{input}}',
    );
    final chat = await h.emptyChat(character);
    final context = await h.context(chat, characterId: character);
    await h.bridge.createChatMessages(context.id, [
      TavernScriptMessageDraft(role: TavernScriptRole.user, message: 'FIRST'),
      TavernScriptMessageDraft(role: TavernScriptRole.system, message: 'COMMENT'),
      TavernScriptMessageDraft(role: TavernScriptRole.assistant, message: 'HIDDEN', hidden: true),
      TavernScriptMessageDraft(role: TavernScriptRole.user, message: 'LAST'),
    ]);
    await h.bridge.replaceVariables(context.id, scriptGlobal, {'desc': 0});
    final before = generationNodes(h, chat);
    final history = <Object?>[
      <String, Object?>{'role': 'assistant', 'content': 'OVERRIDE-OLD'},
      <String, Object?>{'role': 'user', 'content': 'OVERRIDE-LAST'},
    ];
    final request = TavernScriptRawRequest(
      userInput: 'UNREQUESTED INPUT',
      maxChatHistory: 1,
      overrides: TavernScriptPromptOverrides(fields: {'chatHistory': history, 'withDepthEntries': false}),
      orderedPrompts: const [
        TavernScriptPromptPart.placeholder(TavernScriptPromptPlaceholder.charDescription),
        TavernScriptPromptPart.placeholder(TavernScriptPromptPlaceholder.chatHistory),
        TavernScriptPromptPart.placeholder(TavernScriptPromptPlaceholder.charDescription),
      ],
    );
    scriptMap(history.last)['content'] = 'LATE MUTATION';
    history.clear();
    final response = h.reply('done');
    final generation = await h.bridge.generateRaw(context.id, request);
    final wire = await generationRequest(generation, response);
    final result = await generation.result;
    expect(generationMessages(wire), [
      {'role': 'system', 'content': 'DESC1/3/LAST/'},
      {'role': 'user', 'content': 'OVERRIDE-LAST'},
      {'role': 'system', 'content': 'DESC1/3/LAST/'},
    ]);
    expect((await h.bridge.getVariables(context.id, scriptGlobal)).value, {'desc': 1});
    expect(generationNodes(h, chat), before);
    expect(
      result.origin.nodeAnchor,
      TavernScriptMessageRef(chatId: chat, nodeId: (await h.engine.path(chat)).last.nodeId),
    );
    expect(result.origin.emptyChatAnchor, isFalse);
    await h.reopen();
    final fresh = await h.context(chat, characterId: character);
    expect((await h.bridge.getVariables(fresh.id, scriptGlobal)).value, {'desc': 1});
    expect(generationNodes(h, chat), before);
  }, timeout: const Timeout(Duration(seconds: 15)));

  test('raw prepares character fields only when an actual source consumes them in either macro engine', () async {
    final h = await generationFixture();
    final character = await h.card(
      'Raw field demand',
      description: 'D{{incglobalvar::desc}}',
      greeting: 'G{{incglobalvar::greet}}',
      extensions: {
        'depth_prompt': {'prompt': 'Z{{incglobalvar::depth}}', 'depth': 4, 'role': 'system'},
      },
    );
    final chat = await h.emptyChat(character);
    var context = await h.context(chat, characterId: character);
    final before = generationNodes(h, chat);
    var calls = 0;
    for (final macroEngine in ['modern', 'legacy']) {
      await h.engine.setSettings({'macroEngine': macroEngine});
      for (final source in ['input', 'empty', 'macro', 'placeholder']) {
        // Reset after native chat creation and before each independent source
        // so earlier legitimate preparation cannot hide an unwanted write.
        await h.bridge.replaceVariables(context.id, scriptGlobal, {'desc': 0, 'greet': 0, 'depth': 0});
        final input = source == 'macro'
            ? '{{description}}/{{description}}'
            : source == 'empty'
            ? 'X{{description}}Y'
            : 'Q';
        final response = h.reply('source accepted');
        final generation = await h.bridge.generateRaw(
          context.id,
          TavernScriptRawRequest(
            generationId: 'raw-field-$macroEngine-$source',
            userInput: input,
            overrides: TavernScriptPromptOverrides(fields: {if (source == 'empty') 'charDescription': ''}),
            orderedPrompts: [
              if (source == 'empty' || source == 'placeholder')
                const TavernScriptPromptPart.placeholder(TavernScriptPromptPlaceholder.charDescription),
              const TavernScriptPromptPart.placeholder(TavernScriptPromptPlaceholder.userInput),
              if (source == 'placeholder')
                const TavernScriptPromptPart.placeholder(TavernScriptPromptPlaceholder.charDescription),
            ],
          ),
        );
        final wire = await generationRequest(generation, response);
        final result = await generation.result;
        expect(result.text, 'source accepted');
        expect(result.hookIssues, isEmpty);
        expect(generationMessages(wire), [
          if (source == 'placeholder') {'role': 'system', 'content': 'D1'},
          {
            'role': 'user',
            'content': source == 'macro'
                ? 'D1/D1'
                : source == 'empty'
                ? 'XY'
                : 'Q',
          },
          if (source == 'placeholder') {'role': 'system', 'content': 'D1'},
        ]);
        final expected = {'desc': source == 'macro' || source == 'placeholder' ? 1 : 0, 'greet': 0, 'depth': 0};
        expect((await h.bridge.getVariables(context.id, scriptGlobal)).value, expected);
        // Read the actual file before any later settings/reset operation can
        // accidentally make an earlier unwanted persistent write disappear.
        expect((await h.settingsDocument())['globalVariables'], expected);
        expect(generationNodes(h, chat), before);
        expect(await h.engine.path(chat), isEmpty);
        calls++;
        expect(h.keyReads, calls);
        expect(h.requests, hasLength(calls));
      }
      await h.reopen();
      context = await h.context(chat, characterId: character);
      expect((await h.bridge.getVariables(context.id, scriptGlobal)).value, {'desc': 1, 'greet': 0, 'depth': 0});
      expect((await h.settingsDocument())['globalVariables'], {'desc': 1, 'greet': 0, 'depth': 0});
      expect(generationNodes(h, chat), before);
      expect(await h.engine.path(chat), isEmpty);
    }
    expect(h.requests, hasLength(8));
    expect(h.keyReads, 8);
  }, timeout: const Timeout(Duration(seconds: 15)));

  test('present empty overrides cut off their original macros and never create implicit history', () async {
    final h = await generationFixture();
    final character = await h.card('Override', description: 'FORBIDDEN{{incglobalvar::cut}}');
    final chat = await h.emptyChat(character);
    final context = await h.context(chat, characterId: character);
    await h.bridge.createChatMessages(context.id, [
      TavernScriptMessageDraft(role: TavernScriptRole.user, message: 'OLD HISTORY'),
    ]);
    await h.bridge.replaceVariables(context.id, scriptGlobal, {'cut': 0});
    final before = generationNodes(h, chat);
    final response = h.reply('done');
    final generation = await h.bridge.generateRaw(
      context.id,
      TavernScriptRawRequest(
        orderedPrompts: const [
          TavernScriptPromptPart.placeholder(TavernScriptPromptPlaceholder.charDescription),
          TavernScriptPromptPart.placeholder(TavernScriptPromptPlaceholder.chatHistory),
          TavernScriptPromptPart.literal(role: TavernScriptPromptRole.user, content: 'ONLY'),
        ],
        overrides: TavernScriptPromptOverrides(
          fields: {'charDescription': '', 'chatHistory': <Object?>[], 'authorNote': '', 'withDepthEntries': false},
        ),
      ),
    );
    final wire = await generationRequest(generation, response);
    await generation.result;
    expect(generationMessages(wire), [
      {'role': 'user', 'content': 'ONLY'},
    ]);
    expect((await h.bridge.getVariables(context.id, scriptGlobal)).value, {'cut': 0});
    expect(generationNodes(h, chat), before);
  });

  test('raw explicit preset supplies parameters only and six sampling overrides affect the final wire', () async {
    final h = await generationFixture();
    final context = await h.bridge.openContext(const TavernScriptContextSpec(instanceId: 'parameters-only'));
    final preset = (await h.engine.importPreset(
      jsonEncode(scriptPreset(main: 'NEVER{{incglobalvar::preset-main}}').raw),
    )).preset.id;
    final sampling = <String, Object?>{
      'temperature': 0.6,
      'top_p': 0.7,
      'presence_penalty': 0.3,
      'frequency_penalty': -0.2,
      'max_tokens': 41,
      'seed': 17,
    };
    final request = TavernScriptRawRequest(
      presetId: preset,
      samplingOverrides: sampling,
      orderedPrompts: const [TavernScriptPromptPart.literal(role: TavernScriptPromptRole.user, content: 'Q')],
    );
    sampling['temperature'] = 99;
    final response = h.reply('done');
    final generation = await h.bridge.generateRaw(context.id, request);
    final wire = await generationRequest(generation, response);
    await generation.result;
    expect(wire.body, {
      'messages': [
        {'role': 'user', 'content': 'Q'},
      ],
      'model': 'p2-script-model',
      'stream': false,
      'temperature': 0.6,
      'top_p': 0.7,
      'presence_penalty': 0.3,
      'frequency_penalty': -0.2,
      'max_tokens': 41,
      'seed': 17,
    });
    expect(h.engine.globalVariables.containsKey('preset-main'), isFalse);
    expect(h.inspect((db) => db.select('SELECT COUNT(*) AS n FROM nodes').single['n']), 0);
  });

  test('raw explicit budget fails before key instead of silently trimming literal content', () async {
    final h = await generationFixture(allowModel: false);
    final context = await h.bridge.openContext(const TavernScriptContextSpec(instanceId: 'budget'));
    final presetRaw = scriptPreset().raw;
    presetRaw['openai_max_context'] = 100;
    presetRaw['openai_max_tokens'] = 73;
    final preset = (await h.engine.importPreset(jsonEncode(presetRaw))).preset.id;
    final generation = await h.bridge.generateRaw(
      context.id,
      TavernScriptRawRequest(
        presetId: preset,
        samplingOverrides: {'max_tokens': 1},
        orderedPrompts: [
          TavernScriptPromptPart.literal(
            role: TavernScriptPromptRole.user,
            content: List.filled(8000, 'long literal ').join(),
          ),
        ],
      ),
    );
    final failure = await generationFailure(generation);
    expect(failure.code, TavernScriptErrorCode.model);
    expect(failure.modelFailure, TavernFailure.contextTooLong);
    expect(failure.committed, isFalse);
    expect(h.inspect((db) => db.select('SELECT COUNT(*) AS n FROM nodes').single['n']), 0);
    h.expectNoGeneration();
  });

  test('DeepSeek raw takes thinking from config while reasoning visibility remains independent', () async {
    final h = await generationFixture();
    h.engine.configure(
      TavernModelConfig(
        apiKey: h.config.apiKey,
        baseUrl: 'https://p2-script.invalid/v1',
        model: 'configured-deepseek',
        deepseek: true,
        thinking: true,
      ),
    );
    final context = await h.bridge.openContext(const TavernScriptContextSpec(instanceId: 'deepseek'));
    final response = generationJsonResponse(h, {
      'choices': [
        {
          'index': 0,
          'message': {'role': 'assistant', 'content': 'ANSWER', 'reasoning_content': 'PRIVATE REASONING'},
          'finish_reason': 'stop',
        },
      ],
    });
    final generation = await h.bridge.generateRaw(
      context.id,
      TavernScriptRawRequest(
        orderedPrompts: const [TavernScriptPromptPart.literal(role: TavernScriptPromptRole.user, content: 'Q')],
      ),
    );
    final events = ScriptEvents(generation.events);
    final wire = await generationRequest(generation, response);
    final result = await generation.result;
    await events.done.future;
    expect(wire.body, {
      'messages': [
        {'role': 'user', 'content': 'Q'},
      ],
      'model': 'configured-deepseek',
      'stream': false,
      'thinking': {'type': 'enabled'},
    });
    expect(wire.url, Uri.parse('https://p2-script.invalid/beta/chat/completions'));
    expect(result.text, 'ANSWER');
    expect(result.reasoning, isNull);
    expect(result.origin.provider, 'deepseek');
    expect(events.values.where((event) => event.kind == TavernScriptGenerationEventKind.reasoningDelta), isEmpty);
    expect(events.values.every((event) => event.reasoning == null), isTrue);
    await expectLater(
      () => h.bridge.generateRaw(
        context.id,
        TavernScriptRawRequest(generationId: 'bad-seed', samplingOverrides: {'seed': 7}, orderedPrompts: []),
      ),
      throwsA(scriptError(TavernScriptErrorCode.unsupportedOption)),
    );
    expect(h.requests, hasLength(1));
    expect(h.keyReads, 1);
  });

  test('normal background preparation commits locals without a user or reply node or main inspection', () async {
    final h = await generationFixture();
    final character = await h.card('Normal background', extensions: scriptStateExtension(initial: 2));
    final chat = await h.emptyChat(character);
    final context = await h.context(chat, characterId: character);
    await h.engine.setPreset(scriptPreset(main: 'PRE{{incvar::count}}/{{getglobalvar::shared}}'));
    await h.bridge.replaceVariables(context.id, scriptChat, {'count': 0});
    await h.bridge.replaceVariables(context.id, scriptGlobal, {'shared': 'G'});
    final stateBefore = (await h.engine.readState(chat)).values;
    final before = generationNodes(h, chat);
    final host = GenerationHost();
    h.bridge.attachHost(host);
    final response = h.reply('BACKGROUND');
    final generation = await h.bridge.generate(context.id, TavernScriptGenerateRequest(userInput: 'Q'));
    final wire = await generationRequest(generation, response);
    final result = await generation.result;
    expect(
      wire.body,
      scriptWire([
        {'role': 'system', 'content': 'PRE1/G'},
        {'role': 'user', 'content': 'Q'},
      ]),
    );
    expect(result.text, 'BACKGROUND');
    expect(result.origin.nodeAnchor, isNull);
    expect(result.origin.emptyChatAnchor, isTrue);
    expect((await h.bridge.getVariables(context.id, scriptChat)).value['count'], 1);
    expect((await h.engine.readState(chat)).values, stateBefore);
    expect(generationNodes(h, chat), before);
    expect(await h.engine.inspectTurn(chat), isNull);
    expect(host.deliveries.where((event) => event.name == 'MESSAGE_SENT' || event.name == 'MESSAGE_RECEIVED'), isEmpty);
    await h.reopen();
    final fresh = await h.context(chat, characterId: character);
    expect((await h.bridge.getVariables(fresh.id, scriptChat)).value['count'], 1);
    expect((await h.engine.readState(chat)).values, stateBefore);
    expect(generationNodes(h, chat), before);
    expect(await h.engine.inspectTurn(chat), isNull);
  });

  test('normal prompt history expansion leaves the real lastMessage macro input unchanged', () async {
    final h = await generationFixture();
    final character = await h.card('Real macro history');
    final chat = await h.emptyChat(character);
    final context = await h.context(chat, characterId: character);
    const rawHistory = 'RAW{{incglobalvar::history}}';
    await h.bridge.createChatMessages(context.id, [
      TavernScriptMessageDraft(role: TavernScriptRole.assistant, message: rawHistory),
    ]);
    await h.bridge.replaceVariables(context.id, scriptGlobal, {'history': 0});
    await h.engine.setPreset(scriptPreset(main: 'LAST={{lastMessage}}'));
    final before = (await h.engine.path(chat)).single;
    final response = h.reply('BACKGROUND');
    final generation = await h.bridge.generate(context.id, TavernScriptGenerateRequest(userInput: 'Q'));
    final wire = await generationRequest(generation, response);
    expect((await generation.result).text, 'BACKGROUND');
    expect(
      wire.body,
      scriptWire([
        {'role': 'system', 'content': 'LAST=RAW{{incglobalvar::history}}'},
        {'role': 'assistant', 'content': 'RAW1'},
        {'role': 'user', 'content': 'Q'},
      ]),
    );
    expect((await h.bridge.getVariables(context.id, scriptGlobal)).value, {'history': 1});
    final after = (await h.engine.path(chat)).single;
    expect(after.nodeId, before.nodeId);
    expect(after.text, rawHistory);
    expect(generationNodes(h, chat), hasLength(1));
    expect(h.requests, hasLength(1));
    expect(h.keyReads, 1);
    await h.reopen();
    expect((await h.engine.path(chat)).single.text, rawHistory);
    expect(h.engine.globalVariables, {'history': 1});
  });

  test('group-dependent raw rejects an absent actor and explicit actor controls only the requested source', () async {
    final h = await generationFixture();
    final host = await h.card('Host', description: 'HOST DESCRIPTION');
    final actor = await h.card('Actor', description: 'ACTOR DESCRIPTION');
    final chat = await h.engine.createGroupChat([host, actor], addGreetings: false);
    final context = await h.context(chat);
    final before = generationNodes(h, chat);
    final unresolved = await h.bridge.generateRaw(
      context.id,
      TavernScriptRawRequest(
        orderedPrompts: const [TavernScriptPromptPart.placeholder(TavernScriptPromptPlaceholder.charDescription)],
      ),
    );
    expect((await generationFailure(unresolved)).code, TavernScriptErrorCode.noContext);
    expect(h.keyReads, 0);
    expect(h.requests, isEmpty);
    final response = h.reply('actor answer');
    final generation = await h.bridge.generateRaw(
      context.id,
      TavernScriptRawRequest(
        speakerCharacterId: actor,
        orderedPrompts: const [TavernScriptPromptPart.placeholder(TavernScriptPromptPlaceholder.charDescription)],
      ),
    );
    final wire = await generationRequest(generation, response);
    await generation.result;
    expect(generationMessages(wire), [
      {'role': 'system', 'content': 'ACTOR DESCRIPTION'},
    ]);
    expect(generationNodes(h, chat), before);
    expect((await h.engine.groupChat(chat))!.hostCharacterId, host);
    expect((await h.engine.groupChat(chat))!.members.map((member) => member.characterId), [host, actor]);
  });

  test('raw macro actor requirements follow actual sources in both macro engines', () async {
    final h = await generationFixture();
    final host = await h.card('Host', description: 'HOST DESCRIPTION');
    final actor = await h.card('Actor', description: 'ACTOR DESCRIPTION');
    final chat = await h.engine.createGroupChat([host, actor], addGreetings: false);
    final context = await h.context(chat);
    final unscoped = await h.bridge.openContext(const TavernScriptContextSpec(instanceId: 'actor-free-global'));
    await h.bridge.replaceVariables(context.id, scriptGlobal, {'plain': 'OK'});
    final before = generationNodes(h, chat);
    for (final macroEngine in ['modern', 'legacy']) {
      await h.engine.setSettings({'macroEngine': macroEngine});
      final keysBefore = h.keyReads;
      final requestsBefore = h.requests.length;
      final lease = await h.bridge.injectPrompts(context.id, [
        TavernScriptInjection(id: 'not-claimed', content: 'UNCONSUMED ONCE'),
      ], once: true);
      for (final request in [
        TavernScriptRawRequest(
          userInput: '{{incglobalvar::uncommitted}}Who={{char}}',
          orderedPrompts: const [TavernScriptPromptPart.placeholder(TavernScriptPromptPlaceholder.userInput)],
        ),
        TavernScriptRawRequest(
          orderedPrompts: const [TavernScriptPromptPart.literal(role: TavernScriptPromptRole.user, content: 'Q')],
          injects: [TavernScriptInjection(id: 'missing-actor', content: '{{incglobalvar::uncommitted}}Who={{char}}')],
        ),
      ]) {
        final generation = await h.bridge.generateRaw(context.id, request);
        final failure = await generationFailure(generation);
        expect(failure.code, TavernScriptErrorCode.noContext);
        expect(failure.message, contains('actor'));
        expect(failure.committed, isFalse);
        final preparation = failure.issues.singleWhere((issue) => issue.code == 'generationPreparation');
        expect(preparation.stage, 'assemble');
        expect(preparation.committed, isFalse);
        expect(preparation.details['preparationAccepted'], isFalse);
        expect(preparation.details['persistedTargets'], isEmpty);
        expect(preparation.details['claimedInjectionVersions'], isEmpty);
        expect((await h.bridge.listInjections(context.id)).single.claimed, isFalse);
        expect(h.engine.globalVariables, {'plain': 'OK'});
        expect((await h.settingsDocument())['globalVariables'], {'plain': 'OK'});
        expect(generationNodes(h, chat), before);
        expect(h.keyReads, keysBefore);
        expect(h.requests, hasLength(requestsBefore));
      }
      await h.bridge.releaseInjectionLease(lease.leaseId);
      final actorResponse = h.reply('ACTOR OK');
      final explicit = await h.bridge.generateRaw(
        context.id,
        TavernScriptRawRequest(
          speakerCharacterId: actor,
          userInput: 'Who={{char}}',
          orderedPrompts: const [TavernScriptPromptPart.placeholder(TavernScriptPromptPlaceholder.userInput)],
        ),
      );
      final actorWire = await generationRequest(explicit, actorResponse);
      await explicit.result;
      expect(generationMessages(actorWire), [
        {'role': 'user', 'content': 'Who=Actor'},
      ]);
      final overrideResponse = h.reply('OVERRIDE OK');
      final overridden = await h.bridge.generateRaw(
        context.id,
        TavernScriptRawRequest(
          userInput: 'Group={{group}}',
          overrides: TavernScriptPromptOverrides(fields: {'charDescription': 'OVERRIDE'}),
          orderedPrompts: const [
            TavernScriptPromptPart.placeholder(TavernScriptPromptPlaceholder.charDescription),
            TavernScriptPromptPart.placeholder(TavernScriptPromptPlaceholder.userInput),
          ],
        ),
      );
      final overrideWire = await generationRequest(overridden, overrideResponse);
      await overridden.result;
      expect(generationMessages(overrideWire), [
        {'role': 'system', 'content': 'OVERRIDE'},
        {'role': 'user', 'content': 'Group=Host, Actor'},
      ]);
      final globalResponse = h.reply('GLOBAL OK');
      final global = await h.bridge.generateRaw(
        unscoped.id,
        TavernScriptRawRequest(
          userInput: 'G={{getglobalvar::plain}}',
          orderedPrompts: const [
            TavernScriptPromptPart.literal(role: TavernScriptPromptRole.assistant, content: 'Who={{char}}'),
            TavernScriptPromptPart.placeholder(TavernScriptPromptPlaceholder.userInput),
          ],
        ),
      );
      final globalWire = await generationRequest(global, globalResponse);
      await global.result;
      expect(generationMessages(globalWire), [
        {'role': 'assistant', 'content': 'Who={{char}}'},
        {'role': 'user', 'content': 'G=OK'},
      ]);
      expect(h.engine.globalVariables, {'plain': 'OK'});
      expect(generationNodes(h, chat), before);
      expect((await h.engine.groupChat(chat))!.members.map((member) => member.characterId), [host, actor]);
    }
    expect(h.requests, hasLength(6));
    expect(h.keyReads, 6);
    await h.reopen();
    expect(h.engine.globalVariables, {'plain': 'OK'});
    expect(generationNodes(h, chat), before);
    expect((await h.engine.groupChat(chat))!.hostCharacterId, host);
    expect((await h.engine.groupChat(chat))!.members.map((member) => member.characterId), [host, actor]);
  }, timeout: const Timeout(Duration(seconds: 15)));
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:test/test.dart';

import 'p2_script_generation_test_support.dart';

void main() {
  test(
    'a hot SSE execution has independent atomic snapshots and one terminal even for a silent late observer',
    () async {
      final h = await generationFixture();
      final context = await h.bridge.openContext(const TavernScriptContextSpec(instanceId: 'observers'));
      final host = GenerationHost();
      h.bridge.attachHost(host);
      final response = h.stream();
      final generation = await h.bridge.generateRaw(
        context.id,
        _raw('hot', stream: true, includeReasoning: true, silent: true),
      );
      // No event/result observer is needed to initiate the real HTTP operation.
      await response.seen.future;
      await response.listening.future;
      expect(h.requests, hasLength(1));
      final first = ScriptEvents(generation.events);
      final initial = await first.until((event) => event.isSnapshot);
      expect(initial.kind, TavernScriptGenerationEventKind.snapshot);
      expect(initial.seq, initial.lastSeq);
      expect(initial.text, '');
      generationSse(response, {
        'choices': [
          {
            'index': 0,
            'delta': {'reasoning_content': '思'},
            'finish_reason': null,
          },
        ],
      });
      final payload = <String, Object?>{
        'choices': [
          {
            'index': 0,
            'delta': {'content': '你'},
            'finish_reason': null,
          },
        ],
      };
      final encoded = utf8.encode('data: ${jsonEncode(payload)}\n\n');
      generationSse(response, payload, splitAt: encoded.indexOf(0xe4) + 1);
      await first.until((event) => event.kind == TavernScriptGenerationEventKind.textDelta && event.text == '你');
      final second = ScriptEvents(generation.events);
      final resumed = await second.until((event) => event.isSnapshot);
      expect(resumed.kind, TavernScriptGenerationEventKind.snapshot);
      expect(resumed.text, '你');
      expect(resumed.reasoning, '思');
      expect(resumed.seq, resumed.lastSeq);
      await first.detach();
      response.delta('好');
      await second.until((event) => event.kind == TavernScriptGenerationEventKind.textDelta && event.text == '你好');
      generationSse(response, {
        'choices': <Object?>[],
        'usage': {'prompt_tokens': 3, 'completion_tokens': 2, 'total_tokens': 5},
      });
      response.finish();
      final result = await generation.result;
      await second.done.future;
      expect(result.text, '你好');
      expect(result.reasoning, '思');
      expect(result.usage!.promptTokens, 3);
      expect(result.usage!.completionTokens, 2);
      expect(result.finishReason, 'stop');
      final futureEvents = second.values.where((event) => !event.isSnapshot).toList();
      expect(futureEvents.every((event) => event.seq > resumed.lastSeq!), isTrue);
      expect(futureEvents.map((event) => event.seq).toSet(), hasLength(futureEvents.length));
      for (var index = 1; index < futureEvents.length; index++) {
        expect(futureEvents[index].seq, greaterThan(futureEvents[index - 1].seq));
      }
      expect(first.values.where((event) => event.isSnapshot), hasLength(1));
      expect(second.values.where((event) => event.isSnapshot), hasLength(1));
      expect(futureEvents.where((event) => event.kind == TavernScriptGenerationEventKind.finished), hasLength(1));
      final terminal = futureEvents.last;
      final late = await generation.events.toList();
      expect(late, hasLength(1));
      expect(late.single.kind, TavernScriptGenerationEventKind.finished);
      expect(late.single.isSnapshot, isTrue);
      expect(late.single.seq, terminal.seq);
      expect(late.single.lastSeq, terminal.seq);
      expect(late.single.text, '你好');
      expect(late.single.reasoning, '思');
      expect(first.values.where((event) => event.kind == TavernScriptGenerationEventKind.finished), isEmpty);
      expect(host.deliveries.where((event) => event.name == 'GENERATION_STARTED'), hasLength(1));
      expect(host.deliveries.where((event) => event.name == 'GENERATION_ENDED'), hasLength(1));
      expect(host.deliveries.where((event) => event.name == 'STREAM_TOKEN_RECEIVED_INCREMENTALLY'), hasLength(2));
      expect(host.deliveries.where((event) => event.name == 'STREAM_TOKEN_RECEIVED_FULLY'), hasLength(2));
      expect(h.requests.single.body, {
        'messages': [
          {'role': 'user', 'content': 'Q'},
        ],
        'model': 'p2-script-model',
        'stream': true,
      });
      expect(h.keyReads, 1);
      await h.peers.single.closedSignal.future;
      expect(h.peers.single.closed, isTrue);
      stdout.writeln('P2_B2_LIFECYCLE_READY');
    },
    timeout: const Timeout(Duration(seconds: 15)),
  );

  test('stopping a pending key fixes the old record while reusing its id targets only the new operation', () async {
    final h = await generationFixture();
    final context = await h.bridge.openContext(const TavernScriptContextSpec(instanceId: 'id-reuse'));
    final host = GenerationHost();
    final bothEnded = Completer<void>();
    host.onDispatch = (request, cancellation) async {
      if (request.name == 'GENERATION_ENDED' &&
          host.deliveries.where((event) => event.name == 'GENERATION_ENDED').length == 2) {
        bothEnded.complete();
      }
      return TavernScriptDispatchAck(eventId: request.eventId);
    };
    h.bridge.attachHost(host);
    final keyEntered = Completer<void>();
    final key = Completer<String?>();
    addTearDown(() {
      if (!key.isCompleted) key.complete('late-key');
    });
    h.engine.configure(
      TavernModelConfig(
        apiKey: () {
          h.keyReads++;
          keyEntered.complete();
          return key.future;
        },
        baseUrl: h.config.baseUrl,
        model: 'old-config',
        deepseek: false,
      ),
    );
    final old = await h.bridge.generateRaw(context.id, _raw('same-id'));
    await generationSignal(old, keyEntered.future);
    await expectLater(
      () => h.bridge.generateRaw(context.id, _raw('same-id')),
      throwsA(scriptError(TavernScriptErrorCode.duplicateId)),
    );
    expect(h.keyReads, 1);
    expect(h.bridge.stopGenerationById('same-id'), isTrue);
    final oldFailure = await generationFailure(old);
    expect(oldFailure.code, TavernScriptErrorCode.cancelled);
    expect(oldFailure.committed, isFalse);
    expect(h.requests, isEmpty);
    h.engine.configure(h.config);
    final response = h.stream();
    final current = await h.bridge.generateRaw(context.id, _raw('same-id', stream: true));
    await generationRequest(current, response);
    await generationSignal(current, response.listening.future);
    key.complete('late-key');
    final oldReplay = await old.events.toList();
    expect(oldReplay.single.status, TavernScriptGenerationStatus.cancelled);
    expect(oldReplay.single.isSnapshot, isTrue);
    expect(h.requests.single.body['model'], 'p2-script-model');
    expect(h.bridge.stopGenerationById('same-id'), isTrue);
    expect((await generationFailure(current)).code, TavernScriptErrorCode.cancelled);
    expect(h.bridge.stopGenerationById('same-id'), isFalse);
    // The synthetic peer has no socket abort implementation. Release its
    // actual body separately, then observe production ModelClient.finally.
    await response.dispose();
    await h.peers.single.closedSignal.future;
    await bothEnded.future;
    final endings = host.deliveries.where((event) => event.name == 'GENERATION_ENDED').toList();
    expect(endings, hasLength(2));
    expect(endings.map((event) => event.generationId), ['same-id', 'same-id']);
    expect(endings.map((event) => event.eventId).toSet(), hasLength(2));
    expect(endings.map((event) => scriptMap(event.args.single)['status']), ['cancelled', 'cancelled']);
    expect(h.requests, hasLength(1));
    expect(h.keyReads, 2);
    expect((await old.events.toList()).single.error, same(oldFailure));
  }, timeout: const Timeout(Duration(seconds: 15)));

  test('background dispatch failures preserve only effects reported before terminal', () async {
    final h = await generationFixture(allowModel: false);
    final character = await h.card('Known dispatch effects');
    final chat = await h.emptyChat(character);
    final context = await h.context(chat, characterId: character);
    final host = GenerationHost();
    h.bridge.attachHost(host);
    final watched = ScriptEvents(h.bridge.watchEvents(chatId: chat));
    await h.bridge.injectPrompts(context.id, [
      TavernScriptInjection(
        id: 'held-once',
        content: '',
        position: TavernScriptInjectionPosition.scanOnly,
        filter: TavernScriptCallbackRef(contextId: context.id, instanceId: context.instanceId, callbackId: 'hold'),
      ),
    ], once: true);
    for (final mode in ['top', 'issue', 'clean', 'late']) {
      final id = 'dispatch-effect-$mode';
      final knownBeforeTerminal = mode == 'top' || mode == 'issue';
      final kept = mode == 'top'
          ? 7
          : mode == 'late'
          ? 9
          : 8;
      final filterEntered = Completer<void>();
      final filterGate = Completer<void>();
      final writeDone = Completer<void>();
      final throwGate = Completer<void>();
      final ended = Completer<TavernScriptDispatch>();
      addTearDown(() {
        if (!filterGate.isCompleted) filterGate.complete();
        if (!throwGate.isCompleted) throwGate.complete();
      });
      host.onInvoke = (request, cancellation) async {
        expect(request.ref.callbackId, 'hold');
        filterEntered.complete();
        await filterGate.future;
        return TavernScriptCallbackResult(requestId: request.requestId, status: 'failed');
      };
      host.onDispatch = (request, cancellation) async {
        if (request.name == 'GENERATION_STARTED' && request.generationId == id) {
          await filterEntered.future;
          if (mode != 'clean') {
            await h.bridge.replaceVariables(context.id, scriptChat, {'kept': kept});
          }
          writeDone.complete();
          if (mode == 'late') await throwGate.future;
          if (mode == 'clean') throw StateError('no effect reported');
          throw TavernScriptException(
            code: TavernScriptErrorCode.hookFailure,
            operation: 'fixtureStarted',
            message: 'bridge write completed before dispatch throw',
            committed: mode != 'issue',
            issues: [
              if (mode == 'issue')
                TavernScriptIssue(
                  code: 'known-dispatch-write',
                  message: 'the preceding bridge write completed',
                  committed: true,
                  contextId: context.id,
                  eventId: request.eventId,
                  generationId: id,
                ),
            ],
          );
        }
        if (request.name == 'GENERATION_ENDED' && request.generationId == id) {
          ended.complete(request);
        }
        return TavernScriptDispatchAck(eventId: request.eventId);
      };
      final deliveryFailed = watched.until(
        (event) =>
            event.dispatch.name == 'GENERATION_STARTED' && event.dispatch.generationId == id && event.phase == 'failed',
      );
      final generation = await h.bridge.generateRaw(context.id, _raw(id));
      final observed = ScriptEvents(generation.events);
      await generationSignal(generation, writeDone.future);
      if (mode != 'late') {
        await generationSignal(generation, deliveryFailed);
        // The failed observation is published inside delivery. Move to the
        // next event turn so its future continuations have joined the record
        // before this independent filter is allowed to fix the terminal.
        await Future<void>(() {});
      }
      filterGate.complete();
      final failure = await generationFailure(generation);
      await observed.done.future;
      expect(failure.code, TavernScriptErrorCode.hookFailure);
      expect(failure.committed, knownBeforeTerminal);
      final preparation = failure.issues.singleWhere((issue) => issue.code == 'generationPreparation');
      expect(preparation.committed, knownBeforeTerminal);
      expect(preparation.stage, 'filter');
      expect(preparation.details['preparationAccepted'], isFalse);
      expect(preparation.details['persistedTargets'], isEmpty);
      expect(preparation.details['claimedInjectionVersions'], isEmpty);
      expect(failure.issues.where((issue) => issue.code == 'known-dispatch-write'), hasLength(mode == 'issue' ? 1 : 0));
      final notice = scriptMap((await ended.future).args.single);
      expect(notice['status'], 'failed');
      expect(notice['error'], 'hookFailure');
      expect(notice['committed'], knownBeforeTerminal);
      if (mode == 'late') {
        // A real write may already exist without a report known to the record.
        // Receiving its structured throw after terminal must not rewrite it.
        expect(throwGate.isCompleted, isFalse);
        throwGate.complete();
      }
      final failedDelivery = await deliveryFailed;
      await Future<void>(() {});
      expect(failedDelivery.committed, mode != 'clean');
      expect(failedDelivery.issues.any((issue) => issue.committed), mode != 'clean');
      expect(
        failedDelivery.issues.where((issue) => issue.code == 'known-dispatch-write'),
        hasLength(mode == 'issue' ? 1 : 0),
      );
      final dispatchIssues = failure.issues
          .where((issue) => issue.eventId == failedDelivery.dispatch.eventId && issue.stage == 'lifecycle')
          .toList();
      expect(dispatchIssues, hasLength(mode == 'late' ? 0 : 1));
      if (dispatchIssues.isNotEmpty) expect(dispatchIssues.single.committed, knownBeforeTerminal);
      expect(
        observed.values.where((event) => !event.isSnapshot && event.kind == TavernScriptGenerationEventKind.failed),
        hasLength(1),
      );
      final terminal = (await generation.events.toList()).single;
      expect(terminal.kind, TavernScriptGenerationEventKind.failed);
      expect(terminal.error, same(failure));
      expect(await generationFailure(generation), same(failure));
      expect(
        host.deliveries.where((event) => event.name == 'GENERATION_STARTED' && event.generationId == id),
        hasLength(1),
      );
      expect(
        host.deliveries.where((event) => event.name == 'GENERATION_ENDED' && event.generationId == id),
        hasLength(1),
      );
      expect((await h.bridge.getVariables(context.id, scriptChat)).value['kept'], kept);
      expect(await h.engine.path(chat), isEmpty);
      expect(generationNodes(h, chat), isEmpty);
      final registrations = await h.bridge.listInjections(context.id);
      expect(registrations.single.once, isTrue);
      expect(registrations.single.claimed, isFalse);
      h.expectNoGeneration();
    }
    expect(host.invocations, hasLength(4));
    await watched.detach();
    await h.reopen();
    final fresh = await h.context(chat, characterId: character);
    expect((await h.bridge.getVariables(fresh.id, scriptChat)).value['kept'], 9);
    expect(await h.engine.path(chat), isEmpty);
    expect(generationNodes(h, chat), isEmpty);
    h.expectNoGeneration();
  }, timeout: const Timeout(Duration(seconds: 15)));

  test('normal generation freezes config before key waiting and request streaming overrides the preset', () async {
    final h = await generationFixture();
    final character = await h.card('Frozen config', description: 'DESC');
    final chat = await h.emptyChat(character);
    final context = await h.context(chat, characterId: character);
    final entered = Completer<void>();
    final key = Completer<String?>();
    var newKeyReads = 0;
    addTearDown(() {
      if (!key.isCompleted) key.complete('released-key');
    });
    h.engine.configure(
      TavernModelConfig(
        apiKey: () {
          h.keyReads++;
          entered.complete();
          return key.future;
        },
        baseUrl: 'https://old-script.invalid/v1',
        model: 'old-model',
        deepseek: true,
        thinking: true,
      ),
    );
    final response = h.stream();
    final generation = await h.bridge.generate(
      context.id,
      TavernScriptGenerateRequest(generationId: 'frozen-config', userInput: 'Q', stream: true, includeReasoning: true),
    );
    final events = ScriptEvents(generation.events);
    await generationSignal(generation, entered.future);
    expect(h.requests, isEmpty);
    h.engine.configure(
      TavernModelConfig(
        apiKey: () async {
          newKeyReads++;
          return 'new-key';
        },
        baseUrl: 'https://new-script.invalid/v1',
        model: 'new-model',
        deepseek: true,
        thinking: false,
      ),
    );
    key.complete('old-key');
    final wire = await generationRequest(generation, response);
    await generationSignal(generation, response.listening.future);
    expect(wire.method, 'POST');
    expect(wire.url, Uri.parse('https://old-script.invalid/beta/chat/completions'));
    expect(wire.body, {
      'messages': [
        {'role': 'system', 'content': 'DESC'},
        {'role': 'user', 'content': 'Q'},
      ],
      'model': 'old-model',
      'temperature': 0.4,
      'max_tokens': 73,
      'stream': true,
      'presence_penalty': 0.2,
      'frequency_penalty': 0.1,
      'top_p': 0.9,
      'thinking': {'type': 'enabled'},
    });
    generationSse(response, {
      'choices': [
        {
          'index': 0,
          'delta': {'reasoning_content': 'THINK'},
        },
      ],
    });
    response.delta('ANSWER');
    response.finish();
    final result = await generation.result;
    await events.done.future;
    expect(result.text, 'ANSWER');
    expect(result.reasoning, 'THINK');
    expect(result.origin.model, 'old-model');
    expect(result.origin.provider, 'deepseek');
    expect(events.values.where((event) => event.kind == TavernScriptGenerationEventKind.reasoningDelta), hasLength(1));
    expect(h.keyReads, 1);
    expect(newKeyReads, 0);
    expect(h.requests, hasLength(1));
    expect(h.peers, hasLength(1));
    await h.peers.single.closedSignal.future;
    expect(generationNodes(h, chat), isEmpty);
  }, timeout: const Timeout(Duration(seconds: 15)));

  test('closing an owner cancels its hung filter without waiting for the arbitrary host promise', () async {
    final h = await generationFixture(allowModel: false);
    final character = await h.card('Close filter');
    final chat = await h.emptyChat(character);
    final owner = await h.context(chat, characterId: character, instanceId: 'owner');
    final observer = await h.context(chat, characterId: character, instanceId: 'observer');
    final entered = Completer<TavernScriptCallbackRequest>();
    final reply = Completer<TavernScriptCallbackResult>();
    addTearDown(() {
      if (!reply.isCompleted) {
        reply.complete(TavernScriptCallbackResult(requestId: 'released-during-teardown', status: 'cancelled'));
      }
    });
    final host = GenerationHost();
    host.onInvoke = (request, cancellation) {
      entered.complete(request);
      return reply.future;
    };
    h.bridge.attachHost(host);
    await h.bridge.injectPrompts(owner.id, [
      TavernScriptInjection(
        id: 'held',
        content: 'NEVER',
        filter: TavernScriptCallbackRef(contextId: owner.id, instanceId: owner.instanceId, callbackId: 'held'),
      ),
    ], once: true);
    final generation = await h.bridge.generateRaw(owner.id, _raw('held-filter'));
    final callback = await generationSignal(generation, entered.future);
    await h.bridge.closeContext(owner.id);
    expect(reply.isCompleted, isFalse);
    expect((await generationFailure(generation)).code, TavernScriptErrorCode.cancelled);
    expect(await h.bridge.listInjections(observer.id), isEmpty);
    reply.complete(TavernScriptCallbackResult(requestId: callback.requestId, status: 'completed', value: true));
    final late = await generation.events.toList();
    expect(late.single.status, TavernScriptGenerationStatus.cancelled);
    expect(late.single.text, '');
    h.expectNoGeneration();
  }, timeout: const Timeout(Duration(seconds: 15)));

  test(
    'an unobserved result failure is retained and a real 401 makes one request with a fixed late terminal',
    () async {
      final h = await generationFixture();
      final context = await h.bridge.openContext(const TavernScriptContextSpec(instanceId: 'late-failure'));
      h.reply('denied', status: 401);
      final generation = await h.bridge.generateRaw(context.id, _raw('bad-key'));
      final events = ScriptEvents(generation.events);
      final terminal = await events.until((event) => event.kind == TavernScriptGenerationEventKind.failed);
      await events.done.future;
      // Deliberately first attach to result only after its terminal was already
      // delivered; an unhandled asynchronous result error would fail this test.
      final failure = await generationFailure(generation);
      expect(failure.code, TavernScriptErrorCode.model);
      expect(failure.modelFailure, TavernFailure.badKey);
      expect(terminal.error, same(failure));
      expect(failure.committed, isFalse);
      final late = await generation.events.toList();
      expect(late, hasLength(1));
      expect(late.single.seq, terminal.seq);
      expect(late.single.lastSeq, terminal.seq);
      expect(late.single.error, same(failure));
      expect(late.single.isSnapshot, isTrue);
      expect(h.requests, hasLength(1));
      expect(h.keyReads, 1);
    },
  );
  test('accepted tool fragments and tool-only finish fail explicitly without another model execution', () async {
    final h = await generationFixture();
    final context = await h.bridge.openContext(const TavernScriptContextSpec(instanceId: 'unsupported-tools'));
    for (final withFragment in [true, false]) {
      generationJsonResponse(h, {
        'choices': [
          {
            'index': 0,
            'message': {
              'role': 'assistant',
              'content': 'PREFIX',
              if (withFragment)
                'tool_calls': [
                  {
                    'id': 'call-1',
                    'type': 'function',
                    'function': {'name': 'remember', 'arguments': '{}'},
                  },
                ],
            },
            'finish_reason': 'tool_calls',
          },
        ],
      });
      final generation = await h.bridge.generateRaw(context.id, _raw(withFragment ? 'fragment' : 'finish-only'));
      final events = ScriptEvents(generation.events);
      final failure = await generationFailure(generation);
      await events.done.future;
      expect(failure.code, TavernScriptErrorCode.unsupportedCapability);
      expect(failure.issues.any((issue) => issue.stage == 'model' && issue.code == 'unsupportedCapability'), isTrue);
      expect(events.values.last.kind, TavernScriptGenerationEventKind.failed);
      expect(events.values.last.text, 'PREFIX');
      expect(events.values.where((event) => event.kind == TavernScriptGenerationEventKind.finished), isEmpty);
    }
    expect(h.requests, hasLength(2));
    expect(h.keyReads, 2);
    expect(h.inspect((db) => db.select('SELECT COUNT(*) AS n FROM agent_runs').single['n']), 0);
  });

  test('background model output does not replay the native output write-back regex or save messages', () async {
    final h = await generationFixture();
    final character = await h.card('Output isolation');
    final chat = await h.emptyChat(character);
    final context = await h.context(chat, characterId: character);
    await h.bridge.replaceVariables(context.id, scriptGlobal, {'output': 0});
    await h.engine.setSettings({
      'globalRegexScripts': [
        {
          'id': 'output-writeback',
          'scriptName': 'output-writeback',
          'findRegex': 'RAW',
          'replaceString': '{{incglobalvar::output}}REWRITTEN',
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
    h.reply('RAW');
    final generation = await h.bridge.generateRaw(context.id, _raw('no-output-writeback'));
    expect((await generation.result).text, 'RAW');
    expect((await h.bridge.getVariables(context.id, scriptGlobal)).value, {'output': 0});
    expect(await h.engine.path(chat), isEmpty);
    expect(generationNodes(h, chat), isEmpty);
    await h.reopen();
    final fresh = await h.context(chat, characterId: character);
    expect((await h.bridge.getVariables(fresh.id, scriptGlobal)).value, {'output': 0});
    expect(generationNodes(h, chat), isEmpty);
  });

  test('native stop leaves a simultaneous background request alive and observer detach owns neither call', () async {
    final h = await generationFixture();
    final character = await h.card('Concurrent');
    final chat = await h.emptyChat(character);
    final context = await h.context(chat, characterId: character);
    await h.engine.setPreset(scriptPreset(streaming: true));
    final nativeResponse = h.stream();
    final native = ScriptEvents(h.engine.send(chat, 'NATIVE Q'));
    await native.waitRequest(nativeResponse);
    await nativeResponse.listening.future;
    final response = h.stream();
    final background = await h.bridge.generateRaw(context.id, _raw('independent', stream: true));
    await generationRequest(background, response);
    await generationSignal(background, response.listening.future);
    final observation = ScriptEvents(background.events);
    await observation.until((event) => event.isSnapshot);
    await observation.detach();
    expect(h.requests, hasLength(2));
    h.engine.stop(chat);
    await nativeResponse.dispose();
    await native.done.future;
    expect(native.values.whereType<TavernTurnFailed>().single.kind, TavernFailure.cancelled);
    response.delta('BACKGROUND CONTINUES');
    response.finish();
    expect((await background.result).text, 'BACKGROUND CONTINUES');
    expect((await background.events.toList()).single.status, TavernScriptGenerationStatus.completed);
    expect(h.keyReads, 2);
    expect(h.requests, hasLength(2));
    expect((await h.engine.path(chat)).any((message) => message.text == 'BACKGROUND CONTINUES'), isFalse);
    await Future.wait([for (final peer in h.peers) peer.closedSignal.future]);
    expect(h.peers.every((peer) => peer.closed), isTrue);
  }, timeout: const Timeout(Duration(seconds: 15)));

  test(
    'a received hook can await background local preparation without cancelling or waiting for its parent turn',
    () async {
      final h = await generationFixture();
      final character = await h.card('Received background');
      final chat = await h.emptyChat(character);
      final context = await h.context(chat, characterId: character);
      final host = GenerationHost();
      final completed = Completer<TavernScriptGenerationResult>();
      host.onDispatch = (request, cancellation) async {
        if (request.name == 'MESSAGE_RECEIVED') {
          final generation = await h.bridge.generateRaw(
            context.id,
            TavernScriptRawRequest(
              generationId: 'received-child',
              userInput: '{{setvar::background::yes}}Q',
              orderedPrompts: const [TavernScriptPromptPart.placeholder(TavernScriptPromptPlaceholder.userInput)],
            ),
          );
          completed.complete(await generation.result);
        }
        return TavernScriptDispatchAck(eventId: request.eventId);
      };
      h.bridge.attachHost(host);
      h.reply('NATIVE');
      h.reply('CHILD');
      final events = await h.engine.send(chat, 'NATIVE Q').toList();
      expect(events.whereType<TavernTurnFailed>(), isEmpty);
      expect(events.whereType<TavernTurnDone>().single.hookIssues, isEmpty);
      expect((await completed.future).text, 'CHILD');
      expect((await h.engine.readVariables(chat))['background'], 'yes');
      expect((await h.engine.path(chat)).map((message) => message.text), ['NATIVE Q', 'NATIVE']);
      expect(generationNodes(h, chat), hasLength(2));
      expect(h.requests, hasLength(2));
      expect(generationMessages(h.requests.last), [
        {'role': 'user', 'content': 'Q'},
      ]);
      await h.reopen();
      expect((await h.engine.readVariables(chat))['background'], 'yes');
      expect(generationNodes(h, chat), hasLength(2));
    },
    timeout: const Timeout(Duration(seconds: 15)),
  );

  test('background local intent conflicts with an unsettled native owner without stopping that owner', () async {
    final h = await generationFixture();
    final character = await h.card('Busy owner');
    final chat = await h.emptyChat(character);
    final context = await h.context(chat, characterId: character);
    await h.engine.setPreset(scriptPreset(streaming: true));
    final response = h.stream();
    final native = ScriptEvents(h.engine.send(chat, 'NATIVE Q'));
    await native.waitRequest(response);
    await response.listening.future;
    final background = await h.bridge.generateRaw(
      context.id,
      TavernScriptRawRequest(
        generationId: 'busy-write',
        userInput: '{{setvar::must-not-commit::background}}Q',
        orderedPrompts: const [TavernScriptPromptPart.placeholder(TavernScriptPromptPlaceholder.userInput)],
      ),
    );
    expect((await generationFailure(background)).code, TavernScriptErrorCode.busy);
    expect(native.done.isCompleted, isFalse);
    expect(h.requests, hasLength(1));
    expect(h.keyReads, 1);
    response.delta('NATIVE COMPLETES');
    response.finish();
    await native.done.future;
    expect(native.values.whereType<TavernTurnFailed>(), isEmpty);
    expect(native.values.whereType<TavernTurnDone>().single.message.text, 'NATIVE COMPLETES');
    expect((await h.engine.readVariables(chat)).containsKey('must-not-commit'), isFalse);
  }, timeout: const Timeout(Duration(seconds: 15)));
}

TavernScriptRawRequest _raw(String id, {bool stream = false, bool includeReasoning = false, bool silent = false}) =>
    TavernScriptRawRequest(
      generationId: id,
      stream: stream,
      includeReasoning: includeReasoning,
      silent: silent,
      orderedPrompts: const [TavernScriptPromptPart.literal(role: TavernScriptPromptRole.user, content: 'Q')],
    );

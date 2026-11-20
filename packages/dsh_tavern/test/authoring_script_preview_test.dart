import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:test/test.dart';

import 'p2_script_generation_test_support.dart';

final _at = DateTime.utc(2026, 11, 12, 5);
const _deadline = Duration(seconds: 10);

void main() {
  test('isolated lifecycle and filters match native ordering without adopting local variables or once', () async {
    final h = await generationFixture();
    final character = await h.card('Guide', description: 'FIELD={{getvar::phase}} GLOBAL={{getglobalvar::tone}}');
    final chat = await _chat(
      h,
      character,
      metadata: {
        'script_injects': {
          'persistent': {'value': 'PERSISTENT', 'position': 1, 'depth': 0, 'role': 0},
        },
      },
    );
    await h.engine.putLorebook('scan', {
      'entries': {
        '0': {
          'uid': 0,
          'key': ['local-trigger'],
          'content': 'LOCAL_WI',
          'constant': false,
          'position': 0,
          'useProbability': false,
        },
      },
    });
    await h.engine.bindLorebooks(['scan']);
    final a = await h.context(chat, characterId: character, instanceId: 'a');
    final b = await h.context(chat, characterId: character, instanceId: 'b');
    final first = _ref(a, 'first'), second = _ref(a, 'second');
    await h.bridge.injectPrompts(a.id, [
      TavernScriptInjection(id: 'first', content: 'USED={{getvar::phase}}', filter: first),
      TavernScriptInjection(id: 'second', content: 'FALSE_FILTER', filter: second),
    ], once: true);
    final native = GenerationHost();
    final nativeOrder = <String>[];
    var nativePrepared = 0;
    native.onDispatch = (request, token) async {
      if (_preparationEvents.contains(request.name)) {
        final context = request.contextId == a.id ? a : b;
        nativeOrder.add('${request.name}:${context.instanceId}');
        await _orderedPreparation(_BridgeRuntime(h.bridge, context.id), context.instanceId, request.name!);
        nativePrepared++;
        if (request.name == 'GENERATION_AFTER_COMMANDS' && context.instanceId == 'b') {
          return TavernScriptDispatchAck(
            eventId: request.eventId,
            status: TavernScriptAckStatus.failed,
            issues: [
              TavernScriptIssue(code: 'local-notice', message: 'The earlier local effect remains.', committed: false),
            ],
          );
        }
      }
      return TavernScriptDispatchAck(eventId: request.eventId);
    };
    native.onInvoke = (request, token) async => TavernScriptCallbackResult(
      requestId: request.requestId,
      status: 'completed',
      value: await _orderedFilter(_BridgeRuntime(h.bridge, request.ref.contextId), request.ref.callbackId),
    );
    h.bridge.attachHost(native);
    await h.bridge.snapshot(a.id);
    await h.bridge.snapshot(b.id);
    final draft = await _draft(h, character);
    final database = _database(h), files = await _files(h.root);
    final versions = (await h.bridge.listInjections(a.id)).map((view) => view.registrationVersion).toList();
    TavernAuthoringPromptPreview? previous;
    for (var index = 0; index < 2; index++) {
      var prepared = 0;
      final session = _Session(
        _binding([a, b], filters: [first, second]),
        onPrepare: (request) async {
          await _orderedPreparation(request.runtime, request.context.instanceId, request.lifecycle);
          prepared++;
          if (request.lifecycle == 'GENERATION_AFTER_COMMANDS' && request.context.instanceId == 'b') {
            return TavernAuthoringPreparationResult(
              requestId: request.requestId,
              captureId: request.captureId,
              invocationId: request.invocationId,
              contextId: request.context.id,
              instanceId: request.context.instanceId,
              lifecycle: request.lifecycle,
              status: TavernAuthoringCallbackStatus.failed,
              issues: [const TavernAuthoringIssue(type: 'local-notice', message: 'The earlier local effect remains.')],
            );
          }
          return _prepared(request);
        },
        onFilter: (request) async => _filtered(request, await _orderedFilter(request.runtime, request.ref.callbackId)),
      );
      final result = await h.engine
          .previewAuthoringPrompt(
            _request(draft, chat, 'ordered-$index', text: 'ENTER'),
            host: _Host((capture, token) async {
              // Mutating a public capture is not an SDK write and cannot change
              // the canonical request, candidate or local workspace.
              capture.request.changeIds.add('not-selected');
              scriptMap(capture.resources['character:$character']!.candidate!['data'])['description'] = 'HOST_MUTATION';
              capture.workspace['currentLeafId'] = 'fake-leaf';
              final reread = await capture.reader.read(_target(character));
              expect(scriptMap(reread.candidate!['data'])['description'], contains('FIELD='));
              return session;
            }),
          )
          .result;
      expect(result.status, TavernAuthoringPreviewStatus.complete);
      expect(prepared, 4, reason: 'A failed host assertion must not be hidden by native lifecycle error handling.');
      expect(result.issues.any((issue) => issue.type == 'local-notice'), isTrue);
      final effects = (scriptMap(result.origin['scriptPreparation'])['effects']! as List<Object?>).map(scriptMap);
      expect(
        effects.any(
          (effect) => effect['operation'] == 'mutateVariables' && (effect['target']! as String).startsWith('["chat"'),
        ),
        isTrue,
      );
      final text = _text(result);
      for (final expected in ['FIELD=FILTER', 'GLOBAL=FINAL', 'USED=FILTER', 'PERSISTENT', 'LOCAL_WI']) {
        expect(text, contains(expected));
      }
      for (final absent in ['FALSE_FILTER', 'LATE_REGISTRATION', 'HOST_MUTATION']) {
        expect(text, isNot(contains(absent)));
      }
      expect(session.order, [
        'GENERATION_STARTED:a',
        'GENERATION_STARTED:b',
        'GENERATION_AFTER_COMMANDS:a',
        'GENERATION_AFTER_COMMANDS:b',
        'filter:first',
        'filter:second',
      ]);
      expect(session.closeCalls, 1);
      expect(_database(h), database);
      expect(await _files(h.root), files);
      expect(h.engine.globalVariables, isEmpty);
      final live = await h.bridge.listInjections(a.id);
      expect(live.map((view) => view.registrationVersion), versions);
      expect(live.where((view) => view.once).every((view) => !view.claimed), isTrue);
      expect(nativeOrder, isEmpty);
      if (previous != null) {
        expect(result.assembly!.body, previous.assembly!.body);
      }
      previous = result;
      h.expectNoGeneration();
    }
    // A sample has no live script contexts. An explicit reader host must not
    // merge its separately supplied state.variables and macro variables.
    final sample = TavernAuthoringPromptRequest(
      requestId: 'sample-carriers',
      draftId: draft.id,
      draftRevision: draft.draftRevision,
      changeIds: const [],
      at: _at,
      seed: 17,
      context: TavernAuthoringSampleContext(
        characterResourceId: 'character:$character',
        history: [const TavernAuthoringSampleMessage(role: TavernRole.character, text: 'Sample history')],
        state: const {
          'variables': {'phase': 1},
        },
        variables: const {'phase': 2},
      ),
    );
    final withoutHost = await h.engine.previewAuthoringPrompt(sample).result;
    final sampleSession = _Session(_binding([]));
    final withHost = await h.engine.previewAuthoringPrompt(sample, host: _host(sampleSession)).result;
    expect(withHost.status, TavernAuthoringPreviewStatus.complete);
    expect(withHost.assembly!.body, withoutHost.assembly!.body);
    expect(_text(withHost), contains('FIELD=2'));
    expect(sampleSession.order, isEmpty);
    expect(_database(h), database);
    expect(await _files(h.root), files);
    h.reply('Native reply.');
    final events = await h.engine.send(chat, 'ENTER').toList();
    expect(events.whereType<TavernTurnFailed>(), isEmpty);
    expect(h.requests.single.body, previous!.assembly!.body);
    expect(nativeOrder, [
      'GENERATION_STARTED:a',
      'GENERATION_STARTED:b',
      'GENERATION_AFTER_COMMANDS:a',
      'GENERATION_AFTER_COMMANDS:b',
    ]);
    expect(nativePrepared, 4);
    final live = await h.bridge.listInjections(a.id);
    expect(live.singleWhere((view) => view.injection!.id == 'first').claimed, isTrue);
    expect(live.singleWhere((view) => view.injection!.id == 'second').claimed, isFalse);
    expect(h.engine.globalVariables['tone'], 'FINAL');
  });

  test('group user globals and the local message exist before isolated preparation exactly once', () async {
    final h = await generationFixture(allowModel: false);
    final host = await h.card('Host');
    final actor = await h.card('Actor', description: 'FIELD={{getvar::phase}} GLOBAL={{getglobalvar::tone}}');
    final chat = await h.engine.createGroupChat([actor], hostCharacterId: host, addGreetings: false);
    await h.engine.importRegexScripts(
      jsonEncode({
        'scriptName': 'group-user',
        'findRegex': r'/^ENTER$/',
        'replaceString': '{{incglobalvar::count}}{{setglobalvar::tone::GROUP}}GROUP_USER',
        'trimStrings': <String>[],
        'placement': [1],
        'disabled': false,
        'markdownOnly': false,
        'promptOnly': false,
        'runOnEdit': false,
        'substituteRegex': 0,
      }),
    );
    final context = await h.context(chat, characterId: host);
    h.bridge.attachHost(ScriptHost());
    await h.bridge.snapshot(context.id);
    final draft = await _draft(h, host);
    final database = _database(h), files = await _files(h.root);
    var checkedStages = 0;
    final session = _Session(
      _binding([context]),
      onPrepare: (request) async {
        final global = await request.runtime.getVariables(scriptGlobal);
        expect(global.value['tone'], 'GROUP');
        expect(global.value['count'], 1);
        final message = await request.runtime.getVariables(scriptMessage);
        expect(message.resolvedTarget.messageRef!.nodeId, contains(':user'));
        if (request.lifecycle == 'GENERATION_STARTED') {
          await request.runtime.replaceVariables(scriptMessage, {'local': true});
          await request.runtime.replaceVariables(scriptChat, {'phase': 'HOOK'});
        } else {
          expect(message.value['local'], isTrue);
        }
        checkedStages++;
        return _prepared(request);
      },
    );
    final result = await h.engine
        .previewAuthoringPrompt(
          _request(draft, chat, 'group-hooks', text: 'ENTER', actorId: actor),
          host: _Host((capture, token) async {
            final messages = (capture.workspace['messages']! as List<Object?>).map(scriptMap).toList();
            expect(messages.single['text'], '1GROUP_USER');
            expect(capture.workspace['currentLeafId'], messages.single['nodeId']);
            return session;
          }),
        )
        .result;
    expect(result.status, TavernAuthoringPreviewStatus.complete);
    expect(checkedStages, 2);
    expect(_text(result), contains('FIELD=HOOK GLOBAL=GROUP'));
    expect(result.regexTrace.where((trace) => trace['source'] == 'userInput'), hasLength(1));
    expect(_database(h), database);
    expect(await _files(h.root), files);
    expect(await h.engine.path(chat), isEmpty);
    expect(h.engine.globalVariables, isEmpty);
    h.expectNoGeneration();
  });

  test('regenerate reuses its parent while message writes stay physical and invalid state is atomic', () async {
    final h = await generationFixture(allowModel: false);
    final character = await h.card(
      'State',
      description: 'SELECTED={{getvar::phase}}',
      extensions: scriptStateExtension(initial: 10),
    );
    final chat = await _chat(
      h,
      character,
      messages: [
        _message('Root', 'ROOT'),
        _message('Question', 'PARENT', user: true),
        _message('Target', 'TARGET'),
        _message('Later', 'LEAF', user: true),
      ],
    );
    final path = await h.engine.path(chat);
    final context = await h.context(chat, characterId: character);
    h.bridge.attachHost(ScriptHost());
    await h.bridge.snapshot(context.id);
    final draft = await _draft(h, character);
    final database = _database(h), files = await _files(h.root);
    final parent = TavernVariableTarget(
      scope: TavernVariableScope.message,
      messageRef: TavernScriptMessageRef(chatId: chat, nodeId: path[1].nodeId),
    );
    final target = TavernVariableTarget(
      scope: TavernVariableScope.message,
      messageRef: TavernScriptMessageRef(chatId: chat, nodeId: path[2].nodeId),
    );
    var checkedWrite = false;
    final session = _Session(
      _binding([context]),
      onPrepare: (request) async {
        if (request.lifecycle == 'GENERATION_STARTED') {
          expect((await request.runtime.getVariables(scriptMessage)).value['plain'], 'LEAF');
          await request.runtime.replaceVariables(scriptChat, {'phase': 'NEW_LEAF'});
          final before = await request.runtime.getVariables(parent);
          await expectLater(
            request.runtime.replaceVariables(parent, {
              'dshgo': {'count': 'invalid'},
              'plain': 'LOST',
            }),
            throwsA(scriptError(TavernScriptErrorCode.stateValidation)),
          );
          final unchanged = await request.runtime.getVariables(parent);
          expect(unchanged.value, before.value);
          expect(unchanged.version, before.version);
          final accepted = await request.runtime.replaceVariables(parent, {
            'dshgo': {'count': 15},
            'plain': 'EDITED_PARENT',
          }, expectedVersion: before.version);
          expect(accepted.stateEdit!.applied, isTrue);
          expect((await request.runtime.getVariables(target)).value['plain'], 'TARGET');
          expect((await request.runtime.getVariables(scriptChat)).value['phase'], 'NEW_LEAF');
          checkedWrite = true;
        }
        return _prepared(request);
      },
    );
    final result = await h.engine
        .previewAuthoringPrompt(
          _request(draft, chat, 'regen-hooks', generationType: 'regenerate', nodeId: path[2].nodeId),
          host: _host(session),
        )
        .result;
    expect(result.status, TavernAuthoringPreviewStatus.complete);
    expect(checkedWrite, isTrue);
    expect(_text(result), contains('SELECTED=PARENT'));
    expect(_text(result), isNot(contains('SELECTED=NEW_LEAF')));
    expect(result.origin['contextNodeId'], path[1].nodeId);
    expect(_database(h), database);
    expect(await _files(h.root), files);
    h.expectNoGeneration();
  });

  test('local replacement keeps the original claim conflict and caught unsupported calls cannot complete', () async {
    final h = await generationFixture(allowModel: false);
    final character = await h.card('Claims');
    final chat = await h.emptyChat(character);
    final context = await h.context(chat, characterId: character);
    final ref = _ref(context, 'replace');
    await h.bridge.injectPrompts(context.id, [
      TavernScriptInjection(id: 'same', content: 'SAME', filter: ref),
    ], once: true);
    h.bridge.attachHost(ScriptHost());
    await h.bridge.snapshot(context.id);
    final draft = await _draft(h, character);
    final database = _database(h);
    final replaced = _Session(
      _binding([context], filters: [ref]),
      onFilter: (request) async {
        await request.runtime.injectPrompts([TavernScriptInjection(id: 'same', content: 'SAME')]);
        return _filtered(request, true);
      },
    );
    final conflict = await h.engine
        .previewAuthoringPrompt(_request(draft, chat, 'claim-conflict'), host: _host(replaced))
        .result;
    expect(conflict.status, TavernAuthoringPreviewStatus.conflict);
    expect(conflict.issues.single.type, 'revisionConflict');
    expect(conflict.assembly, isNull);
    expect((await h.bridge.listInjections(context.id)).single.claimed, isFalse);

    var checkedUnsupported = false;
    final missing = _Session(
      _binding([context], filters: [ref], operations: const {}),
      onPrepare: (request) async {
        await expectLater(
          request.runtime.replaceVariables(scriptGlobal, {'forbidden': true}),
          throwsA(scriptError(TavernScriptErrorCode.unsupportedCapability)),
        );
        checkedUnsupported = true;
        return _prepared(request);
      },
    );
    final unsupported = await h.engine
        .previewAuthoringPrompt(_request(draft, chat, 'caught-unsupported'), host: _host(missing))
        .result;
    expect(unsupported.status, TavernAuthoringPreviewStatus.unsupported);
    expect(checkedUnsupported, isTrue);
    expect(unsupported.assembly, isNull);
    expect(missing.order, ['GENERATION_STARTED:fixture-instance']);
    expect(_database(h), database);
    expect(h.engine.globalVariables, isEmpty);
    h.expectNoGeneration();
  });

  test('seal rejects actual live registration replacement and isolated source invalidation without replay', () async {
    final h = await generationFixture(allowModel: false);
    final character = await h.card('Sources');
    final chat = await h.emptyChat(character);
    final context = await h.context(chat, characterId: character);
    await h.bridge.injectPrompts(context.id, [TavernScriptInjection(id: 'live', content: 'SAME')]);
    h.bridge.attachHost(ScriptHost());
    await h.bridge.snapshot(context.id);
    final draft = await _draft(h, character);
    final entered = Completer<void>(), release = Completer<void>();
    addTearDown(() {
      if (!release.isCompleted) {
        release.complete();
      }
    });
    final session = _Session(
      _binding([context]),
      onPrepare: (request) async {
        if (request.lifecycle == 'GENERATION_STARTED') {
          entered.complete();
          await release.future;
        }
        return _prepared(request);
      },
    );
    final task = h.engine.previewAuthoringPrompt(_request(draft, chat, 'registration-version'), host: _host(session));
    await entered.future.timeout(_deadline);
    await h.bridge.injectPrompts(context.id, [TavernScriptInjection(id: 'live', content: 'SAME')]);
    release.complete();
    final conflict = await task.result;
    expect(conflict.status, TavernAuthoringPreviewStatus.conflict);
    expect(conflict.issues.single.type, 'capture_conflict');
    expect(session.order, ['GENERATION_STARTED:fixture-instance', 'GENERATION_AFTER_COMMANDS:fixture-instance']);
    expect(session.closeCalls, 1);
    final invalidated = _Session(_binding([context]));
    invalidated.onPrepare = (request) async {
      invalidated.invalidated.cancel();
      return _prepared(request);
    };
    final newerSource = await h.engine
        .previewAuthoringPrompt(_request(draft, chat, 'source-version'), host: _host(invalidated))
        .result;
    expect(newerSource.status, TavernAuthoringPreviewStatus.conflict);
    expect(newerSource.assembly, isNull);
    expect(invalidated.closeCalls, 1);
    h.expectNoGeneration();
  });

  test('cancel and engine close drain the original preparation or filter and actual session close', () async {
    for (final filterStage in [false, true]) {
      final h = await generationFixture(allowModel: false);
      final character = await h.card('Drain');
      final chat = await h.emptyChat(character);
      final context = await h.context(chat, characterId: character);
      final ref = _ref(context, 'pending');
      if (filterStage) {
        await h.bridge.injectPrompts(context.id, [
          TavernScriptInjection(id: 'pending', content: 'PENDING', filter: ref),
        ]);
      }
      h.bridge.attachHost(ScriptHost());
      await h.bridge.snapshot(context.id);
      final draft = await _draft(h, character);
      final entered = Completer<void>(), release = Completer<void>();
      final closing = Completer<void>(), releaseClose = Completer<void>();
      TavernAuthoringPromptRuntime? oldRuntime;
      Future<void> hold(TavernAuthoringPromptRuntime runtime) async {
        oldRuntime = runtime;
        entered.complete();
        await release.future;
      }

      final session = _Session(
        _binding([context], filters: filterStage ? [ref] : []),
        onPrepare: (request) async {
          if (!filterStage && request.lifecycle == 'GENERATION_STARTED') {
            await hold(request.runtime);
          }
          return _prepared(request);
        },
        onFilter: (request) async {
          await hold(request.runtime);
          return _filtered(request, true);
        },
        onClose: () async {
          closing.complete();
          await release.future;
          await releaseClose.future;
        },
      );
      final task = h.engine.previewAuthoringPrompt(_request(draft, chat, 'pending-$filterStage'), host: _host(session));
      var cancelled = false, done = false, engineClosed = false;
      final result = task.result.then((value) {
        done = true;
        return value;
      });
      Future<void>? cancel, close;
      try {
        await entered.future.timeout(_deadline);
        cancel = task.cancel().then((_) {
          cancelled = true;
        });
        close = h.close().then((_) {
          engineClosed = true;
        });
        await closing.future.timeout(_deadline);
        await Future<void>.delayed(Duration.zero);
        expect([cancelled, done, engineClosed], [false, false, false]);
        release.complete();
        await Future<void>.delayed(Duration.zero);
        expect([cancelled, done, engineClosed], [false, false, false]);
        releaseClose.complete();
        expect((await result.timeout(_deadline)).status, TavernAuthoringPreviewStatus.cancelled);
        await Future.wait([cancel, close]).timeout(_deadline);
        expect(session.closeCalls, 1);
        await expectLater(oldRuntime!.getVariables(scriptGlobal), throwsA(isA<TavernModelException>()));
        h.expectNoGeneration();
      } finally {
        if (!release.isCompleted) {
          release.complete();
        }
        if (!releaseClose.isCompleted) {
          releaseClose.complete();
        }
        // h.close already clears the fixture's engine field. Keep its actual
        // Future here even when an earlier pending assertion fails.
        await Future.wait([task.cancel(), result.then<void>((_) {}), ?cancel, ?close]);
      }
    }
  });

  test('failed prompt-domain close preserves its owner and still waits for the original callback', () async {
    // There is deliberately no recovery API for an unconfirmed domain close.
    // Confine this root reservation to a worker and wait for its actual exit.
    final directory = await Directory.systemTemp.createTemp('dsh-authoring-hook-close-');
    final response = ReceivePort(), exited = ReceivePort();
    final exit = exited.first.then<void>((_) {});
    Isolate? worker;
    try {
      worker = await Isolate.spawn(_runFailedHookClose, [response.sendPort, directory.path], onExit: exited.sendPort);
      expect(await response.first.timeout(_deadline), {
        'waitedForCallback': true,
        'resultError': true,
        'cancelError': true,
        'engineError': true,
        'rootStillOwned': true,
        'closeCalls': 1,
      });
    } finally {
      worker?.kill(priority: Isolate.immediate);
      if (worker != null) {
        await exit;
      }
      response.close();
      exited.close();
      await directory.delete(recursive: true);
    }
  });
}

Future<void> _runFailedHookClose(List<Object?> input) async {
  final reply = input[0]! as SendPort;
  try {
    reply.send(await _failedHookClose(input[1]! as String));
  } catch (error, stack) {
    reply.send({'error': '$error', 'stack': '$stack'});
  }
}

Future<Map<String, Object?>> _failedHookClose(String path) async {
  final engine = await TavernEngine.openDirectory(Directory(path));
  final character = (await engine.importCard(
    Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'spec': 'chara_card_v3',
          'spec_version': '3.0',
          'data': {'name': 'Close', 'extensions': <String, Object?>{}},
        }),
      ),
    ),
  )).id;
  final chat = await engine.createChat(character);
  final context = await engine.scripts.openContext(TavernScriptContextSpec(instanceId: 'fatal', chatId: chat));
  engine.scripts.attachHost(ScriptHost());
  await engine.scripts.snapshot(context.id);
  final draft = await engine.createAuthoringDraft([_target(character)]);
  final entered = Completer<TavernAuthoringPreparationRequest>();
  final callback = Completer<TavernAuthoringPreparationResult>();
  final closing = Completer<void>();
  final failure = StateError('prompt domain cleanup is unconfirmed');
  final session = _Session(
    _binding([context]),
    onPrepare: (request) {
      entered.complete(request);
      return callback.future;
    },
    onClose: () async {
      closing.complete();
      throw failure;
    },
  );
  final task = engine.previewAuthoringPrompt(_request(draft, chat, 'failed-close'), host: _host(session));
  final frame = await entered.future;
  var resultEnded = false, cancelEnded = false;
  final result = task.result.then<Object?>(
    (value) {
      resultEnded = true;
      return value;
    },
    onError: (Object error, StackTrace _) {
      resultEnded = true;
      return error;
    },
  );
  final cancel = task.cancel().then<Object?>(
    (_) {
      cancelEnded = true;
      return null;
    },
    onError: (Object error, StackTrace _) {
      cancelEnded = true;
      return error;
    },
  );
  await closing.future;
  await Future<void>.delayed(Duration.zero);
  final waited = !resultEnded && !cancelEnded;
  callback.complete(_prepared(frame));
  final resultError = identical(await result, failure), cancelError = identical(await cancel, failure);
  var engineError = false, rootOwned = false;
  try {
    await engine.close();
  } catch (error) {
    engineError = identical(error, failure);
  }
  try {
    await TavernEngine.openDirectory(Directory(path));
  } on StateError {
    rootOwned = true;
  }
  return {
    'waitedForCallback': waited,
    'resultError': resultError,
    'cancelError': cancelError,
    'engineError': engineError,
    'rootStillOwned': rootOwned,
    'closeCalls': session.closeCalls,
  };
}

const _preparationEvents = {'GENERATION_STARTED', 'GENERATION_AFTER_COMMANDS'};

Future<void> _orderedPreparation(TavernAuthoringPromptRuntime runtime, String owner, String lifecycle) async {
  if (lifecycle == 'GENERATION_STARTED' && owner == 'a') {
    await runtime.replaceVariables(scriptChat, {'phase': 'A'});
    await runtime.replaceVariables(scriptGlobal, {'tone': 'A'});
  } else if (lifecycle == 'GENERATION_STARTED') {
    final old = await runtime.getVariables(scriptChat);
    expect(old.value['phase'], 'A');
    await runtime.mutateVariables(scriptChat, [
      TavernVariableChange(kind: TavernVariableChangeKind.set, pathTokens: ['phase'], value: 'B'),
    ], expectedVersion: old.version);
  } else if (owner == 'a') {
    await runtime.injectPrompts([
      TavernScriptInjection(
        id: 'hook-scan',
        content: 'local-trigger',
        position: TavernScriptInjectionPosition.scanOnly,
        scan: true,
      ),
    ], once: true);
  } else {
    await runtime.replaceVariables(scriptGlobal, {'tone': 'FINAL'});
  }
}

Future<bool> _orderedFilter(TavernAuthoringPromptRuntime runtime, String name) async {
  if (name == 'first') {
    await runtime.replaceVariables(scriptChat, {'phase': 'FILTER'});
    await runtime.injectPrompts([TavernScriptInjection(id: 'late', content: 'LATE_REGISTRATION')]);
    return true;
  }
  expect((await runtime.getVariables(scriptChat)).value['phase'], 'FILTER');
  return false;
}

TavernScriptCallbackRef _ref(TavernScriptContext context, String id) =>
    TavernScriptCallbackRef(contextId: context.id, instanceId: context.instanceId, callbackId: id);

TavernAuthoringScriptBinding _binding(
  List<TavernScriptContext> contexts, {
  List<TavernScriptCallbackRef> filters = const [],
  Set<TavernAuthoringRuntimeOperation>? operations,
}) => TavernAuthoringScriptBinding(
  hostEpoch: 'copied-domain',
  lifecycleSources: [
    for (final context in contexts)
      TavernAuthoringLifecycleSource(
        contextId: context.id,
        instanceId: context.instanceId,
        manifestVersion: 'handlers-and-environment-v1',
        handlers: _preparationEvents,
      ),
  ],
  filterSources: [for (final ref in filters) TavernAuthoringFilterSource(ref: ref, sourceVersion: 'closure-v1')],
  runtimeOperations: operations ?? TavernAuthoringRuntimeOperation.values.toSet(),
);

TavernAuthoringPreparationResult _prepared(TavernAuthoringPreparationRequest request) =>
    TavernAuthoringPreparationResult(
      requestId: request.requestId,
      captureId: request.captureId,
      invocationId: request.invocationId,
      contextId: request.context.id,
      instanceId: request.context.instanceId,
      lifecycle: request.lifecycle,
      status: TavernAuthoringCallbackStatus.completed,
    );
TavernAuthoringFilterResult _filtered(TavernAuthoringFilterRequest request, bool value) => TavernAuthoringFilterResult(
  requestId: request.requestId,
  captureId: request.captureId,
  invocationId: request.invocationId,
  ref: request.ref,
  status: TavernAuthoringCallbackStatus.completed,
  value: value,
);

final class _Host implements TavernAuthoringPromptHost {
  _Host(this.open);
  final Future<TavernAuthoringPromptSession> Function(TavernAuthoringPromptHostCapture, TavernScriptCancellation) open;
  @override
  Future<TavernAuthoringPromptSession> openPromptPreview(
    TavernAuthoringPromptHostCapture capture,
    TavernScriptCancellation cancellation,
  ) => open(capture, cancellation);
}

_Host _host(_Session session) => _Host((capture, token) async => session);

final class _Session implements TavernAuthoringPromptSession {
  _Session(this.binding, {this.onPrepare, this.onFilter, this.onClose});
  @override
  final TavernAuthoringScriptBinding binding;
  final invalidated = ModelCancellation();
  final order = <String>[];
  var closeCalls = 0;
  Future<TavernAuthoringPreparationResult> Function(TavernAuthoringPreparationRequest)? onPrepare;
  final Future<TavernAuthoringFilterResult> Function(TavernAuthoringFilterRequest)? onFilter;
  final Future<void> Function()? onClose;
  @override
  TavernScriptCancellation get sourceInvalidated => _Token(invalidated);
  @override
  Future<TavernAuthoringPreparationResult> prepare(TavernAuthoringPreparationRequest request) async {
    order.add('${request.lifecycle}:${request.context.instanceId}');
    return await onPrepare?.call(request) ?? _prepared(request);
  }

  @override
  Future<TavernAuthoringFilterResult> filter(TavernAuthoringFilterRequest request) async {
    order.add('filter:${request.ref.callbackId}');
    return await onFilter?.call(request) ?? _filtered(request, true);
  }

  @override
  Future<void> close() async {
    closeCalls++;
    await onClose?.call();
  }
}

final class _Token implements TavernScriptCancellation {
  const _Token(this.source);
  final ModelCancellation source;
  @override
  bool get isCancelled => source.isCancelled;
  @override
  Future<void> get whenCancelled => source.whenCancelled;
}

// The same test handler runs against the real native bridge for the wire
// comparison above; it supplies no fake model stream or private state.
final class _BridgeRuntime implements TavernAuthoringPromptRuntime {
  const _BridgeRuntime(this.bridge, this.contextId);
  final TavernScriptBridge bridge;
  final String contextId;
  @override
  Future<TavernVariableSnapshot> getVariables(TavernVariableTarget target) => bridge.getVariables(contextId, target);
  @override
  Future<TavernVariableSnapshot> replaceVariables(
    TavernVariableTarget target,
    TavernJsonObject value, {
    String? expectedVersion,
  }) => bridge.replaceVariables(contextId, target, value, expectedVersion: expectedVersion);
  @override
  Future<TavernVariableMutation> mutateVariables(
    TavernVariableTarget target,
    List<TavernVariableChange> changes, {
    String? expectedVersion,
  }) => bridge.mutateVariables(contextId, target, changes, expectedVersion: expectedVersion);
  @override
  Future<TavernScriptInjectionLease> injectPrompts(List<TavernScriptInjection> prompts, {bool once = false}) =>
      bridge.injectPrompts(contextId, prompts, once: once);
  @override
  Future<void> uninjectPrompts(List<String> ids) => bridge.uninjectPrompts(contextId, ids);
  @override
  Future<void> releaseInjectionLease(String leaseId) => bridge.releaseInjectionLease(leaseId);
  @override
  Future<List<TavernScriptInjectionView>> listInjections() => bridge.listInjections(contextId);
}

TavernAuthoringTarget _target(String id) => TavernAuthoringTarget(kind: TavernAuthoringTargetKind.character, id: id);
Future<TavernAuthoringDraft> _draft(ScriptFixture h, String character) =>
    h.engine.createAuthoringDraft([_target(character)]);
TavernAuthoringPromptRequest _request(
  TavernAuthoringDraft draft,
  String chat,
  String id, {
  String text = '',
  String? actorId,
  String? nodeId,
  String generationType = 'normal',
}) => TavernAuthoringPromptRequest(
  requestId: id,
  draftId: draft.id,
  draftRevision: draft.draftRevision,
  changeIds: <String>[],
  context: TavernAuthoringChatContext(chatId: chat, generationType: generationType, actorId: actorId, nodeId: nodeId),
  text: text,
  at: _at,
  seed: 17,
);
String _text(TavernAuthoringPromptPreview value) =>
    (value.assembly!.body['messages']! as List<Object?>).map(scriptMap).map((message) => message['content']).join('\n');

Future<String> _chat(
  ScriptFixture h,
  String character, {
  ScriptJson metadata = const {},
  List<ScriptJson> messages = const [],
}) async {
  final document = StChatDocument(
    fileName: 'hooks.jsonl',
    header: {'user_name': 'User', 'character_name': 'Guide', 'chat_metadata': metadata},
    messages: messages,
  );
  return (await h.engine.importChats(character, [
    TavernChatFile(fileName: document.fileName, bytes: document.encode()),
  ])).chatIds.single;
}

ScriptJson _message(String text, String phase, {bool user = false}) => {
  'name': user ? 'User' : 'Guide',
  'is_user': user,
  'is_system': false,
  'send_date': _at.toIso8601String(),
  'mes': text,
  'extra': {
    'dshgo': {
      'tavernState': {
        'variables': {'phase': phase},
        'messageVariables': {
          'dshgo': {'count': 10},
          'plain': phase,
        },
      },
    },
  },
};
ScriptJson _database(ScriptFixture h) => h.inspect((db) {
  final result = <String, Object?>{};
  for (final table in db.select("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")) {
    final name = table['name']! as String;
    final quoted = name.replaceAll('"', '""');
    result[name] = [for (final row in db.select('SELECT * FROM "$quoted"')) Map<String, Object?>.from(row)];
  }
  return result;
});
Future<Map<String, List<int>>> _files(Directory root) async {
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

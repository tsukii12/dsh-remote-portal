import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as image;
import 'package:test/test.dart';

import 'p2_script_generation_test_support.dart';

const _deadline = Duration(seconds: 10);
const _bookTarget = TavernAuthoringTarget(kind: TavernAuthoringTargetKind.lorebook, id: 'image-book');

void main() {
  test('author images follow the complete real HTTP tool batch and replay without rendering again', () async {
    final h = await _fixture();
    final adapter = _Images(h.model);
    h.model = adapter;
    await h.reopen();
    final card = TavernAuthoringTarget(
      kind: TavernAuthoringTargetKind.character,
      id: await h.card('Preview card', description: 'PROMPT_CAPTURE'),
    );
    await h.engine.putLorebook(_bookTarget.id, _book('LIVE'));
    final draft = await h.engine.createAuthoringDraft([_bookTarget, card]);
    final bookFile = File('${h.root.path}/lorebooks/${_bookTarget.id}.json');
    final beforeBook = await bookFile.readAsBytes();
    final beforeBusiness = _business(h);
    final samples = <TavernAuthoringSampleMessage>[
      const TavernAuthoringSampleMessage(role: TavernRole.character, text: 'USER_SELECTED_SAMPLE'),
    ];
    final input = TavernAuthoringRunRequest(
      runId: 'image-complete',
      draftId: draft.id,
      draftRevision: draft.draftRevision,
      instruction: 'Edit, preview and inspect these saved sources.',
      previewContext: TavernAuthoringSampleContext(characterResourceId: card.physicalResourceId),
      renderContext: TavernAuthoringRenderContext(
        physicalResourceId: _bookTarget.physicalResourceId,
        viewportWidth: 2,
        viewportHeight: 3,
        theme: 'dark',
        samples: samples,
      ),
    );
    final sessions = <_RenderSession>[];
    final renderer = _RenderHost((_) async {
      final mime = sessions.isEmpty ? 'image/png' : 'image/jpeg';
      final session = _RenderSession(onRender: (frame) async => _rendered(frame, mime: mime));
      sessions.add(session);
      return session;
    });
    final promptHost = _PromptHost();
    final first = h.stream(), second = h.stream();
    final run = h.engine.startAuthoringRun(input, renderHost: renderer, promptHost: promptHost);
    final unused = _RenderHost((_) async => _RenderSession());
    expect(identical(h.engine.startAuthoringRun(input, renderHost: unused), run), isTrue);
    samples[0] = const TavernAuthoringSampleMessage(role: TavernRole.user, text: 'CALLER_CHANGED_SAMPLE');
    final calls = [
      _call('write', 'lore_write', {
        'physicalResourceId': _bookTarget.physicalResourceId,
        'changes': [
          {'id': 'selected', 'path': '/entries/0/content', 'operation': 'set', 'value': '<p>SELECTED</p>'},
          {'id': 'omitted', 'path': '/name', 'operation': 'set', 'value': 'UNSELECTED_NAME'},
        ],
      }),
      _call('selected-image', 'render_preview', {
        'changeIds': ['selected'],
      }),
      _call('read', 'draft_read', {}),
      _call('prompt', 'prompt_preview', {
        'changeIds': ['selected'],
        'text': 'LOCAL_USER',
        'at': '2026-11-12T05:00:00Z',
        'seed': 23,
      }),
      _call('base-image', 'render_preview', {'changeIds': <String>[]}),
    ];
    await _reply(first, run, calls: calls);
    await _listening(second, run);
    final during = (await h.engine.readAuthoringRun(run.runId))!;
    expect(during.currentRevision, draft.draftRevision + 1);
    expect(during.receipts, hasLength(calls.length));
    expect(during.receipts.every((receipt) => receipt.status == TavernAuthoringToolStatus.succeeded), isTrue);
    expect(renderer.captures, hasLength(2));
    expect(unused.captures, isEmpty);
    expect(promptHost.captures, hasLength(1));
    expect(promptHost.sessions.single.closeCalls, 1);
    expect(promptHost.sessions.single.callbackCalls, 0);
    expect(promptHost.captures.single.request.context.toJson(), input.previewContext!.toJson());
    final frames = [for (final session in sessions) await session.entered.future];
    for (final frame in frames) {
      expect(
        (frame.request.physicalResourceId, frame.request.draftRevision),
        (_bookTarget.physicalResourceId, during.currentRevision),
      );
      expect(
        (
          frame.request.viewportWidth,
          frame.request.viewportHeight,
          frame.request.devicePixelRatio,
          frame.request.theme,
          frame.request.mode,
        ),
        (2, 3, 1.0, 'dark', TavernAuthoringRenderMode.staticMarkup),
      );
      expect(frame.request.samples.single.text, 'USER_SELECTED_SAMPLE');
      expect(frame.resource.candidate!['name'], 'Live book');
    }
    expect(_bookContent(frames[0].resource.candidate!), '<p>SELECTED</p>');
    expect(_bookContent(frames[1].resource.candidate!), 'LIVE');
    expect(sessions.map((session) => session.closeCalls), [1, 1]);
    expect(adapter.queries, hasLength(1));
    expect(adapter.generated, hasLength(2));
    expect(adapter.generated.every((config) => identical(config, adapter.queries.single)), isTrue);
    expect(adapter.encoded, hasLength(2));
    final renderReceipts = during.receipts.where((receipt) => receipt.toolName == 'render_preview').toList();
    for (var index = 0; index < 2; index++) {
      final accepted = adapter.encoded[index];
      final receipt = renderReceipts[index];
      final frame = frames[index];
      expect(
        (accepted.requestId, accepted.captureId, accepted.draftRevision, accepted.physicalResourceId),
        (frame.request.requestId, frame.captureId, during.currentRevision, _bookTarget.physicalResourceId),
      );
      expect(accepted.changeIds, frame.request.changeIds);
      expect(accepted.bytes, _image(index == 0 ? 'image/png' : 'image/jpeg'));
      expect(() => accepted.bytes[0] = 0, throwsUnsupportedError);
      expect(receipt.result['requestId'], accepted.requestId);
      expect(receipt.result['captureId'], accepted.captureId);
      expect(receipt.result['status'], 'complete');
      expect(receipt.result['byteLength'], accepted.bytes.length);
      expect(receipt.result['imageInput'], {
        'profile': 'fixture-images',
        'version': '1',
        'wireForm': 'openAiChatImageUrl',
      });
      expect(receipt.result.containsKey('bytes'), isFalse);
      expect(jsonEncode(receipt.toJson()), isNot(contains(base64Encode(accepted.bytes))));
    }
    final wire = generationMessages(h.requests[1]);
    expect(wire[2]['role'], 'assistant');
    expect(
      (wire[2]['tool_calls']! as List<Object?>).map((call) => scriptMap(call)['id']),
      calls.map((call) => call['id']),
    );
    final outputs = wire.skip(3).take(calls.length).toList();
    expect(outputs.map((message) => message['role']), List.filled(calls.length, 'tool'));
    expect(outputs.map((message) => message['tool_call_id']), calls.map((call) => call['id']));
    for (var index = 0; index < outputs.length; index++) {
      expect(jsonDecode(outputs[index]['content']! as String), during.receipts[index].toJson());
    }
    final imageMessages = wire.skip(3 + calls.length).toList();
    expect(imageMessages, hasLength(2));
    for (var index = 0; index < imageMessages.length; index++) {
      final message = imageMessages[index];
      expect(message['role'], 'user');
      final content = (message['content']! as List<Object?>).map(scriptMap).toList();
      expect(content, hasLength(2));
      expect(content.first['type'], 'text');
      expect(content.first['text'], contains(renderReceipts[index].receiptId));
      final accepted = adapter.encoded[index];
      expect(content.last, {
        'type': 'image_url',
        'image_url': {'url': 'data:${accepted.mimeType};base64,${base64Encode(accepted.bytes)}', 'detail': 'low'},
      });
    }
    expect(during.requests[1].body, h.requests[1].body);
    expect(_toolNames(h.requests.first), containsAll(['prompt_preview', 'render_preview']));
    await _reply(second, run, text: 'The selected render is ready.');
    final result = await run.result.timeout(_deadline);
    expect(result.status, TavernAuthoringRunStatus.completed);
    expect(result.requests.map((request) => request.attempts), [
      [0],
      [0],
    ]);
    expect(await bookFile.readAsBytes(), beforeBook);
    expect(_business(h), beforeBusiness);
    final savedInput = result.request;
    await h.reopen();
    final replay = await h.engine
        .startAuthoringRun(savedInput, renderHost: unused, promptHost: _PromptHost())
        .result
        .timeout(_deadline);
    expect(replay.toJson(), result.toJson());
    expect(h.requests, hasLength(2));
    expect(adapter.queries, hasLength(1));
    expect(adapter.encoded, hasLength(2));
    expect(unused.captures, isEmpty);
  });

  test(
    'unknown or mismatched image clients do not render and pending render drains through author cancellation',
    () async {
      final h = await _fixture();
      await h.engine.putLorebook(_bookTarget.id, _book('LIVE'));
      final draft = await h.engine.createAuthoringDraft([_bookTarget]);
      final unused = _RenderHost((_) async => _RenderSession());
      final first = h.stream(), second = h.stream();
      final unknown = h.engine.startAuthoringRun(_request(draft, 'unknown-images'), renderHost: unused);
      await _reply(
        first,
        unknown,
        calls: [
          _call('not-offered', 'render_preview', {'changeIds': <String>[]}),
        ],
      );
      await _reply(second, unknown, text: 'No image adapter is available.');
      final unsupported = await unknown.result.timeout(_deadline);
      expect(unsupported.status, TavernAuthoringRunStatus.completed);
      expect(_toolNames(h.requests.first), isNot(contains('render_preview')));
      expect(unsupported.receipts.single.status, TavernAuthoringToolStatus.rejected);
      expect(unsupported.receipts.single.result['code'], 'unsupported_tool');
      expect(unused.captures, isEmpty);
      final transport = h.model;
      final mismatch = _Images(transport, wrongConfiguration: true);
      h.model = mismatch;
      await h.reopen();
      final wrong = h.engine.startAuthoringRun(_request(draft, 'wrong-images'), renderHost: unused);
      await expectLater(
        wrong.result.timeout(_deadline),
        throwsA(isA<TavernAuthoringException>().having((error) => error.code, 'code', 'unsupported_image_input')),
      );
      expect((await h.engine.readAuthoringRun(wrong.runId))!.status, TavernAuthoringRunStatus.failed);
      expect((await h.engine.readAuthoringRun(wrong.runId))!.requests, isEmpty);
      expect(mismatch.queries, hasLength(1));
      expect(mismatch.generated, isEmpty);
      expect(mismatch.encoded, isEmpty);
      expect(h.requests, hasLength(2));
      expect(unused.captures, isEmpty);

      final adapter = _Images(transport);
      h.model = adapter;
      await h.reopen();
      final renderRelease = Completer<void>(), closeStarted = Completer<void>(), closeRelease = Completer<void>();
      final session = _RenderSession(
        onRender: (frame) async {
          await renderRelease.future;
          return _rendered(frame);
        },
        onClose: () async {
          closeStarted.complete();
          await renderRelease.future;
          await closeRelease.future;
        },
      );
      final response = h.stream();
      final run = h.engine.startAuthoringRun(
        _request(draft, 'cancel-image'),
        renderHost: _RenderHost((_) async => session),
      );
      final archive = await Directory.systemTemp.createTemp('dsh-author-image-backup-');
      addTearDown(() async {
        if (await archive.exists()) {
          await archive.delete(recursive: true);
        }
      });
      var cancelled = false, finished = false, backedUp = false, closed = false;
      Future<void>? cancel, close;
      Future<TavernBackupInfo>? backup;
      final result = run.result.then((value) {
        finished = true;
        return value;
      });
      unawaited(result.then<void>((_) {}, onError: (Object _, StackTrace _) {}));
      try {
        await _listening(response, run);
        // Backup closes external admission before the model asks for a render.
        // The already admitted author owner must still start its real child.
        backup = h.engine.backup('${archive.path}/image.zip').then((value) {
          backedUp = true;
          return value;
        });
        await _reply(
          response,
          run,
          calls: [
            _call('render', 'render_preview', {'changeIds': <String>[]}),
          ],
        );
        await _signal(run, session.entered.future);
        cancel = run.cancel().then((_) {
          cancelled = true;
        });
        close = h.close().then((_) {
          closed = true;
        });
        await closeStarted.future.timeout(_deadline);
        await Future<void>(() {});
        expect([cancelled, finished, backedUp, closed], [false, false, false, false]);
        renderRelease.complete();
        await Future<void>(() {});
        expect([cancelled, finished, backedUp, closed], [false, false, false, false]);
        closeRelease.complete();
        await cancel.timeout(_deadline);
        final cancelledRun = await result.timeout(_deadline);
        expect(cancelledRun.status, TavernAuthoringRunStatus.cancelled);
        expect(cancelledRun.receipts, isEmpty);
        expect(cancelledRun.requests, hasLength(1));
        await backup.timeout(_deadline);
        await close.timeout(_deadline);
        expect(await File('${archive.path}/image.zip').exists(), isTrue);
        expect(session.closeCalls, 1);
        expect(adapter.encoded, isEmpty);
        expect(h.requests, hasLength(3));
      } finally {
        if (!renderRelease.isCompleted) {
          renderRelease.complete();
        }
        if (!closeRelease.isCompleted) {
          closeRelease.complete();
        }
        // This HTTP peer cannot abort an idle SSE source. Release it before
        // waiting on cancellation even if the test never reached _reply.
        await response.dispose();
        final closeDrain = close ?? h.close();
        final backupDrain = backup?.then<void>((_) {});
        // h.close clears its fixture slot immediately. Retain and await the
        // actual close/backup Futures before fixture teardown can delete files.
        await Future.wait<void>([
          for (final future in <Future<void>>[
            run.cancel(),
            result.then<void>((_) {}),
            ?cancel,
            ?backupDrain,
            closeDrain,
          ])
            future.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
        ]);
      }
    },
  );

  test('author close failure reaches result and both cancellation APIs without releasing the root', () async {
    final directory = await Directory.systemTemp.createTemp('dsh-author-image-fatal-');
    final response = ReceivePort(), exited = ReceivePort();
    final exit = exited.first;
    Isolate? worker;
    try {
      worker = await Isolate.spawn(_runFailedClose, [response.sendPort, directory.path], onExit: exited.sendPort);
      expect(await response.first.timeout(_deadline), {
        'waitedForRender': true,
        'resultError': true,
        'cancelError': true,
        'cancelByIdError': true,
        'engineError': true,
        'rootStillOwned': true,
        'status': 'failed',
        'receiptCount': 0,
        'httpRequests': 1,
        'httpClosed': true,
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

Future<ScriptFixture> _fixture() async {
  final h = await generationFixture();
  h.config = TavernModelConfig(
    apiKey: h.config.apiKey,
    baseUrl: 'https://author-images.invalid/v1',
    model: 'author-images',
    deepseek: true,
    thinking: false,
  );
  await h.reopen();
  return h;
}

TavernAuthoringRunRequest _request(TavernAuthoringDraft draft, String id) => TavernAuthoringRunRequest(
  runId: id,
  draftId: draft.id,
  draftRevision: draft.draftRevision,
  instruction: 'Render this saved selection.',
  renderContext: TavernAuthoringRenderContext(
    physicalResourceId: _bookTarget.physicalResourceId,
    viewportWidth: 2,
    viewportHeight: 3,
  ),
);

Map<String, Object?> _book(String content) => {
  'name': 'Live book',
  'entries': {
    '0': {'uid': 0, 'key': <String>[], 'content': content, 'constant': true, 'position': 0},
  },
};
Object? _bookContent(Map<String, Object?> book) => scriptMap(scriptMap(book['entries'])['0'])['content'];
Map<String, Object?> _business(ScriptFixture h) => h.inspect(
  (db) => {
    for (final table in ['chats', 'nodes', 'tool_turns', 'agent_runs'])
      table: [for (final row in db.select('SELECT * FROM $table')) Map<String, Object?>.from(row)],
  },
);

List<Object?> _toolNames(ScriptRequest request) => [
  for (final tool in request.body['tools']! as List<Object?>) scriptMap(scriptMap(tool)['function'])['name'],
];
Map<String, Object?> _call(String id, String name, Map<String, Object?> parameters) => {
  'id': id,
  'type': 'function',
  'function': {'name': name, 'arguments': jsonEncode(parameters)},
};

Future<T> _signal<T>(TavernAuthoringRun run, Future<T> signal) => Future.any([
  signal,
  run.result.then<T>(
    (value) => throw TestFailure('Author run ended before its expected boundary: ${value.status.name}'),
  ),
]).timeout(_deadline);
Future<void> _listening(ScriptResponsePlan plan, TavernAuthoringRun run) => _signal(run, plan.listening.future);
Future<void> _reply(
  ScriptResponsePlan plan,
  TavernAuthoringRun run, {
  List<Map<String, Object?>> calls = const [],
  String? text,
}) async {
  await _listening(plan, run);
  plan.source!.add(_response(calls, text: text));
  await plan.source!.close();
}

List<int> _response(List<Map<String, Object?>> calls, {String? text}) => utf8.encode(
  'data: ${jsonEncode({
    'choices': [
      {
        'index': 0,
        'delta': {
          'role': 'assistant',
          'content': text,
          if (calls.isNotEmpty) 'tool_calls': [
              for (var index = 0; index < calls.length; index++) {'index': index, ...calls[index]},
            ],
        },
        'finish_reason': calls.isEmpty ? 'stop' : 'tool_calls',
      },
    ],
  })}\n\ndata: [DONE]\n\n',
);

// The adapter delegates generation to the fixture's actual production HTTP
// client. Only image capability/encoding is implemented here; no ModelDelta
// stream or author tool result is manufactured by this adapter.
class _Images extends TavernModelClient implements TavernAuthoringImageClient {
  _Images(this.transport, {this.wrongConfiguration = false});
  final TavernModelClient transport;
  final bool wrongConfiguration;
  final queries = <TavernModelConfig>[], generated = <TavernModelConfig>[];
  final encoded = <TavernAuthoringAcceptedImage>[];
  @override
  TavernAuthoringImageCapability? imageInputFor(TavernModelConfig config) {
    queries.add(config);
    return TavernAuthoringImageCapability(
      baseUrl: config.baseUrl,
      model: wrongConfiguration ? 'another-model' : config.model,
      deepseek: config.deepseek,
      thinking: config.thinking,
      profile: 'fixture-images',
      version: '1',
      formats: {'image/png', 'image/jpeg', 'image/webp'},
      maxImageBytes: 65536,
      maxPixelWidth: 16,
      maxPixelHeight: 16,
    );
  }

  @override
  Map<String, Object?> encodeAuthoringImage(
    TavernAuthoringImageCapability capability,
    TavernAuthoringAcceptedImage value,
  ) {
    encoded.add(value);
    return encodeAuthoringOpenAiImage(value, detail: 'low');
  }

  @override
  Stream<ModelDelta> generate({
    required TavernModelConfig config,
    required Map<String, Object?> body,
    required ModelCancellation cancellation,
    void Function(int attempt)? onRequestStarted,
  }) {
    generated.add(config);
    return transport.generate(
      config: config,
      body: body,
      cancellation: cancellation,
      onRequestStarted: onRequestStarted,
    );
  }
}

class _Token implements TavernScriptCancellation {
  final done = Completer<void>();
  @override
  bool get isCancelled => done.isCompleted;
  @override
  Future<void> get whenCancelled => done.future;
}

class _RenderHost implements TavernAuthoringPreviewHost {
  _RenderHost(this.open);
  final Future<TavernAuthoringPreviewSession> Function(TavernAuthoringHostCapture) open;
  final captures = <TavernAuthoringHostCapture>[];
  @override
  Future<TavernAuthoringPreviewSession> openPreview(
    TavernAuthoringHostCapture capture,
    TavernScriptCancellation cancellation,
  ) {
    captures.add(capture);
    return open(capture);
  }
}

class _RenderSession implements TavernAuthoringPreviewSession {
  _RenderSession({this.onRender, this.onClose});
  final Future<TavernAuthoringRenderResult> Function(TavernAuthoringHostRenderRequest)? onRender;
  final Future<void> Function()? onClose;
  final entered = Completer<TavernAuthoringHostRenderRequest>();
  final _Token token = _Token();
  var closeCalls = 0;
  @override
  TavernAuthoringHostBinding get binding => TavernAuthoringHostBinding(
    hostEpoch: 'fixture-renderer',
    renderModes: {TavernAuthoringRenderMode.staticMarkup},
    formats: {'image/png', 'image/jpeg'},
    maxImageBytes: 65536,
    maxPixelWidth: 16,
    maxPixelHeight: 16,
  );
  @override
  TavernScriptCancellation get sourceInvalidated => token;
  @override
  Future<TavernAuthoringRenderResult> render(TavernAuthoringHostRenderRequest request) async {
    entered.complete(request);
    return onRender == null ? _rendered(request) : await onRender!(request);
  }

  @override
  Future<void> close() async {
    closeCalls++;
    await onClose?.call();
  }
}

class _PromptHost implements TavernAuthoringPromptHost {
  final captures = <TavernAuthoringPromptHostCapture>[], sessions = <_PromptSession>[];
  @override
  Future<TavernAuthoringPromptSession> openPromptPreview(
    TavernAuthoringPromptHostCapture capture,
    TavernScriptCancellation cancellation,
  ) async {
    captures.add(capture);
    final session = _PromptSession();
    sessions.add(session);
    return session;
  }
}

class _PromptSession implements TavernAuthoringPromptSession {
  final _Token token = _Token();
  var closeCalls = 0, callbackCalls = 0;
  @override
  TavernAuthoringScriptBinding get binding => TavernAuthoringScriptBinding(
    hostEpoch: 'fixture-prompt',
    lifecycleSources: const [],
    filterSources: const [],
    runtimeOperations: const {},
  );
  @override
  TavernScriptCancellation get sourceInvalidated => token;
  @override
  Future<TavernAuthoringPreparationResult> prepare(TavernAuthoringPreparationRequest request) async {
    callbackCalls++;
    throw StateError('No sample lifecycle handler was declared.');
  }

  @override
  Future<TavernAuthoringFilterResult> filter(TavernAuthoringFilterRequest request) async {
    callbackCalls++;
    throw StateError('No sample filter was declared.');
  }

  @override
  Future<void> close() async {
    closeCalls++;
  }
}

Uint8List _image(String mime) {
  final pixels = image.Image(width: 2, height: 3);
  return Uint8List.fromList(mime == 'image/jpeg' ? image.encodeJpg(pixels) : image.encodePng(pixels));
}

TavernAuthoringRenderResult _rendered(
  TavernAuthoringHostRenderRequest frame, {
  String mime = 'image/png',
  bool cancelled = false,
}) => TavernAuthoringRenderResult(
  requestId: frame.request.requestId,
  captureId: frame.captureId,
  draftId: frame.request.draftId,
  draftRevision: frame.request.draftRevision,
  physicalResourceId: frame.request.physicalResourceId,
  changeIds: frame.request.changeIds,
  mode: frame.request.mode,
  status: cancelled ? TavernAuthoringRenderStatus.cancelled : TavernAuthoringRenderStatus.complete,
  mimeType: cancelled ? null : mime,
  bytes: cancelled ? null : _image(mime),
  pixelWidth: cancelled ? null : 2,
  pixelHeight: cancelled ? null : 3,
);

Future<void> _runFailedClose(List<Object?> input) async {
  final reply = input[0]! as SendPort;
  try {
    reply.send(await _failedClose(input[1]! as String));
  } catch (error, stack) {
    reply.send({'error': '$error', 'stack': '$stack'});
  }
}

Future<Map<String, Object?>> _failedClose(String path) async {
  final peers = <_SinglePeer>[];
  final adapter = _Images(
    TavernModelClient(
      clientFactory: () {
        final peer = _SinglePeer();
        peers.add(peer);
        return peer;
      },
    ),
  );
  final engine = await TavernEngine.openDirectory(
    Directory(path),
    config: TavernModelConfig(
      apiKey: () async => 'fixture-key',
      baseUrl: 'https://author-images.invalid/v1',
      model: 'author-images',
      deepseek: true,
      thinking: false,
    ),
    modelClient: adapter,
  );
  await engine.putLorebook(_bookTarget.id, _book('LIVE'));
  final draft = await engine.createAuthoringDraft([_bookTarget]);
  final release = Completer<void>(), closing = Completer<void>();
  final failure = StateError('The image domain cleanup is unconfirmed.');
  final session = _RenderSession(
    onRender: (frame) async {
      await release.future;
      return _rendered(frame, cancelled: true);
    },
    onClose: () async {
      closing.complete();
      throw failure;
    },
  );
  final run = engine.startAuthoringRun(_request(draft, 'fatal-image'), renderHost: _RenderHost((_) async => session));
  await session.entered.future;
  var resultEnded = false, cancelEnded = false;
  final result = run.result.then<Object?>(
    (value) {
      resultEnded = true;
      return value;
    },
    onError: (Object error, StackTrace _) {
      resultEnded = true;
      return error;
    },
  );
  final cancel = run.cancel().then<Object?>(
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
  await Future<void>(() {});
  final waited = !resultEnded && !cancelEnded;
  release.complete();
  final resultError = identical(await result, failure);
  final cancelError = identical(await cancel, failure);
  final snapshot = (await engine.readAuthoringRun(run.runId))!;
  var cancelByIdError = false, engineError = false, rootOwned = false;
  try {
    await engine.cancelAuthoringRun(run.runId);
  } catch (error) {
    cancelByIdError = identical(error, failure);
  }
  try {
    await engine.close();
  } catch (error) {
    engineError = identical(error, failure);
  }
  try {
    final unexpected = await TavernEngine.openDirectory(Directory(path));
    await unexpected.close();
  } on StateError {
    rootOwned = true;
  }
  return {
    'waitedForRender': waited,
    'resultError': resultError,
    'cancelError': cancelError,
    'cancelByIdError': cancelByIdError,
    'engineError': engineError,
    'rootStillOwned': rootOwned,
    'status': snapshot.status.name,
    'receiptCount': snapshot.receipts.length,
    'httpRequests': peers.fold<int>(0, (count, peer) => count + peer.requests),
    'httpClosed': peers.every((peer) => peer.closed),
    'closeCalls': session.closeCalls,
  };
}

// A real HTTP/SSE response for the fatal-isolate case; the engine still uses
// the production encoder, decoder, accumulator and author tool dispatcher.
class _SinglePeer extends http.BaseClient {
  var requests = 0;
  var closed = false;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    await request.finalize().toBytes();
    requests++;
    return http.StreamedResponse(
      Stream.value(
        _response([
          _call('render', 'render_preview', {'changeIds': <String>[]}),
        ]),
      ),
      200,
      headers: {'content-type': 'text/event-stream'},
    );
  }

  @override
  void close() {
    closed = true;
  }
}

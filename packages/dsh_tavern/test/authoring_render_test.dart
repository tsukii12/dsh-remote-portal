import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:image/image.dart' as image;
import 'package:test/test.dart';

import 'p2_script_test_support.dart';

const _deadline = Duration(seconds: 10);
const _bookTarget = TavernAuthoringTarget(kind: TavernAuthoringTargetKind.lorebook, id: 'book');

void main() {
  test('static render captures selected raw and media without preparation or persistent effects', () async {
    final h = await ScriptFixture.open();
    final media = _image('image/png');
    final raw = <String, Object?>{
      'spec': 'chara_card_v3',
      'spec_version': '3.0',
      'foreign': [null, true],
      'data': {
        'name': 'Render',
        'description': 'BASE',
        'extensions': <String, Object?>{},
        'assets': [
          {'type': 'icon', 'name': 'main', 'ext': 'png', 'uri': 'embeded://portrait.png'},
        ],
      },
    };
    final cardBytes = utf8.encode(jsonEncode(raw));
    final archive = Archive()
      ..addFile(ArchiveFile('card.json', cardBytes.length, cardBytes))
      ..addFile(ArchiveFile('portrait.png', media.length, media));
    final seed = await h.engine.createAuthoringSeed(
      TavernAuthoringSeedInput(
        kind: TavernAuthoringTargetKind.character,
        fileName: 'render.charx',
        bytes: Uint8List.fromList(ZipEncoder().encode(archive)),
      ),
    );
    final draft = await h.engine.editAuthoringDraft(
      seed.id,
      draftRevision: seed.draftRevision,
      changes: [
        TavernAuthoringChange(
          id: 'selected',
          physicalResourceId: seed.sources.single.physicalResourceId,
          path: '/data/description',
          operation: TavernAuthoringChangeKind.set,
          value: '<p>SELECTED</p>{{incglobalvar::renderSideEffect}}',
        ),
      ],
    );
    await h.engine.putLorebook('book', _book('CAPTURED_BOOK'));
    final database = _databaseState(h);
    final files = await _files(h.root);
    for (final mime in const ['image/png', 'image/jpeg']) {
      TavernAuthoringHostCapture? captured;
      final session = _Session(
        onRender: (request) async {
          final resource = request.resource;
          expect(resource.document, raw);
          expect(resource.present, isFalse);
          expect(resource.seedDraftId, seed.id);
          expect(
            scriptMap(resource.candidate!['data'])['description'],
            '<p>SELECTED</p>{{incglobalvar::renderSideEffect}}',
          );
          final local = resource.candidate!;
          scriptMap(local['data'])['description'] = 'HOST_LOCAL_MUTATION';
          final reread = await captured!.reader.read(resource.target);
          expect(scriptMap(reread.candidate!['data'])['description'], contains('SELECTED'));
          expect(resource.media['resources/portrait.png'], media);
          expect(() => resource.media['resources/portrait.png']![0] = 0, throwsUnsupportedError);
          expect(request.resources['lorebook:book']!.rawText, contains('CAPTURED_BOOK'));
          expect((await captured!.reader.read(_bookTarget)).candidate, _book('CAPTURED_BOOK'));
          await expectLater(
            Future.sync(
              () => captured!.reader.read(
                const TavernAuthoringTarget(kind: TavernAuthoringTargetKind.lorebook, id: 'late'),
              ),
            ),
            throwsA(_authoringError('unsupported_render_resource')),
          );
          // This is an isolated copy now; source invalidation is only a seal
          // condition and must not chase the live source during render.
          expect(request.captureId, captured!.captureId);
          final bytes = _image(mime);
          final result = _result(request, mime: mime, bytes: bytes);
          bytes.fillRange(0, bytes.length, 0);
          return result;
        },
      );
      final host = _Host((capture, cancellation) async {
        captured = capture;
        expect(cancellation.isCancelled, isFalse);
        expect(capture.request.samples.single.text, '<em>DISPLAY_SAMPLE</em>');
        scriptMap(capture.resource.candidate!['data'])['description'] = 'HOST_OPEN_MUTATION';
        final fresh = await capture.reader.read(capture.resource.target);
        expect(scriptMap(fresh.candidate!['data'])['description'], contains('SELECTED'));
        await capture.reader.read(_bookTarget);
        return session;
      });
      // The closure above reads this exact session's source token only after
      // engine sealing, without giving the renderer any live engine handle.
      session.afterEntered = session.invalidated.cancel;
      final result = await h.engine
          .renderAuthoringDraft(
            _request(
              draft,
              mime,
              changes: ['selected'],
              samples: [
                const TavernAuthoringSampleMessage(role: TavernRole.character, text: '<em>DISPLAY_SAMPLE</em>'),
              ],
            ),
            host: host,
          )
          .result;
      expect(result.status, TavernAuthoringRenderStatus.complete);
      expect((result.mimeType, result.pixelWidth, result.pixelHeight), (mime, 2, 3));
      expect(result.bytes, _image(mime));
      expect(() => result.bytes![0] = 0, throwsUnsupportedError);
      expect(session.closeCalls, 1);
      expect(h.engine.globalVariables.containsKey('renderSideEffect'), isFalse);
    }
    expect(_databaseState(h), database);
    expect(await _files(h.root), files);
    h.expectNoGeneration();
  });

  test('render validates error identities and decodes images instead of trusting a PNG header', () async {
    final h = await ScriptFixture.open();
    final draft = await _draft(h);
    final wrong = _Session(
      onRender: (request) async =>
          _result(request, requestId: 'another-view', status: TavernAuthoringRenderStatus.failed),
    );
    final mismatch = await h.engine.renderAuthoringDraft(_request(draft, 'identity'), host: _host(wrong)).result;
    expect(mismatch.status, TavernAuthoringRenderStatus.superseded);
    expect(mismatch.issues.single.type, 'render_identity_mismatch');
    expect(mismatch.bytes, isNull);

    final headerOnly = _Session(
      onRender: (request) async => _result(request, bytes: Uint8List.fromList([137, 80, 78, 71, 13, 10, 26, 10])),
    );
    final invalid = await h.engine.renderAuthoringDraft(_request(draft, 'header-only'), host: _host(headerOnly)).result;
    expect(invalid.status, TavernAuthoringRenderStatus.failed);
    expect(invalid.issues.single.type, 'invalid_render_image');
    expect(invalid.bytes, isNull);
    final wrongSize = _Session(onRender: (request) async => _result(request, bytes: _image('image/png'), width: 9));
    final dimensions = await h.engine
        .renderAuthoringDraft(_request(draft, 'wrong-size'), host: _host(wrongSize))
        .result;
    expect(dimensions.status, TavernAuthoringRenderStatus.failed);
    expect(dimensions.issues.single.type, 'invalid_render_image');
    expect([wrong.closeCalls, headerOnly.closeCalls, wrongSize.closeCalls], [1, 1, 1]);
    h.expectNoGeneration();
  });

  test('render seal rejects a managed resource ABA and final publication rejects a newer draft', () async {
    final h = await ScriptFixture.open();
    final draft = await _draft(h);
    final opened = Completer<void>(), releaseOpen = Completer<void>();
    addTearDown(() {
      if (!releaseOpen.isCompleted) {
        releaseOpen.complete();
      }
    });
    final session = _Session();
    final task = h.engine.renderAuthoringDraft(
      _request(draft, 'resource-aba'),
      host: _Host((capture, token) async {
        opened.complete();
        await releaseOpen.future;
        return session;
      }),
    );
    await opened.future.timeout(_deadline);
    await h.engine.putLorebook('book', _book('B'));
    await h.engine.putLorebook('book', _book('A'));
    final database = _databaseState(h);
    releaseOpen.complete();
    final conflict = await task.result;
    expect(conflict.status, TavernAuthoringRenderStatus.superseded);
    expect(conflict.issues.single.type, 'capture_conflict');
    expect(session.renderCalls, 0);
    expect(session.closeCalls, 1);
    expect(_databaseState(h), database);

    final changedSource = _Session()..invalidated.cancel();
    final invalidated = await h.engine
        .renderAuthoringDraft(_request(draft, 'invalidated-source'), host: _host(changedSource))
        .result;
    expect(invalidated.status, TavernAuthoringRenderStatus.superseded);
    expect(invalidated.issues.single.type, 'capture_conflict');
    expect(changedSource.renderCalls, 0);
    expect(changedSource.closeCalls, 1);

    final renderDone = Completer<TavernAuthoringRenderResult>();
    final closing = Completer<void>(), releaseClose = Completer<void>();
    addTearDown(() {
      if (!renderDone.isCompleted) {
        renderDone.completeError(StateError('Released test renderer.'));
      }
      if (!releaseClose.isCompleted) {
        releaseClose.complete();
      }
    });
    final late = _Session(
      onRender: (request) => renderDone.future,
      onClose: () async {
        closing.complete();
        await releaseClose.future;
      },
    );
    final rendering = h.engine.renderAuthoringDraft(_request(draft, 'stale-after-close'), host: _host(late));
    final frame = await late.entered.future.timeout(_deadline);
    renderDone.complete(_result(frame, bytes: _image('image/png')));
    await closing.future.timeout(_deadline);
    await h.engine.editAuthoringDraft(
      draft.id,
      draftRevision: draft.draftRevision,
      changes: [
        const TavernAuthoringChange(
          id: 'edit',
          physicalResourceId: 'lorebook:book',
          path: '/entries/0/content',
          operation: TavernAuthoringChangeKind.set,
          value: 'NEW_DRAFT',
        ),
      ],
    );
    releaseClose.complete();
    final superseded = await rendering.result;
    expect(superseded.status, TavernAuthoringRenderStatus.superseded);
    expect(superseded.issues.single.type, 'revision_conflict');
    expect(superseded.bytes, isNull);
    h.expectNoGeneration();
  });

  test('cancelling pending open owns the late session until its actual close completes', () async {
    final h = await ScriptFixture.open();
    final draft = await _draft(h);
    final opened = Completer<void>();
    final deliver = Completer<TavernAuthoringPreviewSession>();
    final closed = Completer<void>(), releaseClose = Completer<void>();
    final session = _Session(
      onClose: () async {
        closed.complete();
        await releaseClose.future;
      },
    );
    addTearDown(() {
      if (!deliver.isCompleted) {
        deliver.complete(session);
      }
      if (!releaseClose.isCompleted) {
        releaseClose.complete();
      }
    });
    final task = h.engine.renderAuthoringDraft(
      _request(draft, 'pending-open'),
      host: _Host((capture, token) {
        opened.complete();
        return deliver.future;
      }),
    );
    await opened.future.timeout(_deadline);
    var cancelled = false, finished = false, engineClosed = false;
    final cancel = task.cancel().then((_) {
      cancelled = true;
    });
    final result = task.result.then((value) {
      finished = true;
      return value;
    });
    final close = h.close().then((_) {
      engineClosed = true;
    });
    await Future<void>(() {});
    expect([cancelled, finished, engineClosed], [false, false, false]);
    deliver.complete(session);
    await closed.future.timeout(_deadline);
    expect(session.renderCalls, 0);
    expect([cancelled, finished, engineClosed], [false, false, false]);
    releaseClose.complete();
    await cancel;
    expect((await result).status, TavernAuthoringRenderStatus.cancelled);
    await close;
    expect(session.closeCalls, 1);
    h.expectNoGeneration();
  });

  test('cancel does not discard an original render Future when close has already returned', () async {
    final h = await ScriptFixture.open();
    final draft = await _draft(h);
    final render = Completer<TavernAuthoringRenderResult>();
    addTearDown(() {
      if (!render.isCompleted) {
        render.completeError(StateError('Released test renderer.'));
      }
    });
    final closeStarted = Completer<void>();
    final session = _Session(
      onRender: (_) => render.future,
      onClose: () async {
        closeStarted.complete();
      },
    );
    final task = h.engine.renderAuthoringDraft(_request(draft, 'pending-render'), host: _host(session));
    final frame = await session.entered.future.timeout(_deadline);
    var cancelled = false, finished = false;
    final cancel = task.cancel().then((_) {
      cancelled = true;
    });
    final result = task.result.then((value) {
      finished = true;
      return value;
    });
    await closeStarted.future.timeout(_deadline);
    await Future<void>(() {});
    expect([cancelled, finished], [false, false]);
    render.complete(_result(frame, bytes: _image('image/jpeg'), mime: 'image/jpeg'));
    await cancel;
    expect((await result).status, TavernAuthoringRenderStatus.cancelled);
    expect(session.closeCalls, 1);
    h.expectNoGeneration();
  });

  test('close failure preserves its error and the engine gate after original render settles', () async {
    // The intentional fatal owner has no recovery API. Confine its sticky
    // root reservation to this test isolate; no callback or timer is left live.
    final directory = await Directory.systemTemp.createTemp('dsh-render-close-failure-');
    final response = ReceivePort();
    final exited = ReceivePort();
    final exit = exited.first;
    Isolate? worker;
    try {
      worker = await Isolate.spawn(_runFailedClose, [response.sendPort, directory.path], onExit: exited.sendPort);
      final evidence = await response.first.timeout(_deadline);
      expect(evidence, {
        'waitedForRender': true,
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

Future<void> _runFailedClose(List<Object?> input) async {
  final reply = input[0]! as SendPort;
  try {
    reply.send(await _failedClose(input[1]! as String));
  } catch (error, stack) {
    reply.send({'error': '$error', 'stack': '$stack'});
  }
}

Future<Map<String, Object?>> _failedClose(String path) async {
  final engine = await TavernEngine.openDirectory(Directory(path));
  await engine.putLorebook('book', _book('A'));
  final draft = await engine.createAuthoringDraft([_bookTarget]);
  final render = Completer<TavernAuthoringRenderResult>();
  final closing = Completer<void>();
  final failure = StateError('renderer cleanup is unconfirmed');
  final session = _Session(
    onRender: (_) => render.future,
    onClose: () async {
      closing.complete();
      throw failure;
    },
  );
  final task = engine.renderAuthoringDraft(_request(draft, 'failed-close'), host: _host(session));
  final frame = await session.entered.future;
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
  await Future<void>(() {});
  final waited = !resultEnded && !cancelEnded;
  render.complete(_result(frame, status: TavernAuthoringRenderStatus.cancelled));
  final resultError = identical(await result, failure);
  final cancelError = identical(await cancel, failure);
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
    'waitedForRender': waited,
    'resultError': resultError,
    'cancelError': cancelError,
    'engineError': engineError,
    'rootStillOwned': rootOwned,
    'closeCalls': session.closeCalls,
  };
}

// Test host output is a real encoded raster, not proof of App sandbox/rendering.
Uint8List _image(String mime) {
  final pixels = image.Image(width: 2, height: 3);
  return Uint8List.fromList(mime == 'image/jpeg' ? image.encodeJpg(pixels) : image.encodePng(pixels));
}

TavernAuthoringRenderRequest _request(
  TavernAuthoringDraft draft,
  String id, {
  List<String> changes = const [],
  List<TavernAuthoringSampleMessage> samples = const [],
}) => TavernAuthoringRenderRequest(
  requestId: id,
  draftId: draft.id,
  draftRevision: draft.draftRevision,
  physicalResourceId: draft.sources.first.physicalResourceId,
  changeIds: changes,
  viewportWidth: 2,
  viewportHeight: 3,
  samples: samples,
);

TavernAuthoringRenderResult _result(
  TavernAuthoringHostRenderRequest frame, {
  String? requestId,
  TavernAuthoringRenderStatus status = TavernAuthoringRenderStatus.complete,
  String mime = 'image/png',
  Uint8List? bytes,
  int width = 2,
}) => TavernAuthoringRenderResult(
  requestId: requestId ?? frame.request.requestId,
  captureId: frame.captureId,
  draftId: frame.request.draftId,
  draftRevision: frame.request.draftRevision,
  physicalResourceId: frame.request.physicalResourceId,
  changeIds: frame.request.changeIds,
  mode: frame.request.mode,
  status: status,
  mimeType: bytes == null ? null : mime,
  bytes: bytes,
  pixelWidth: bytes == null ? null : width,
  pixelHeight: bytes == null ? null : 3,
);

_Host _host(_Session session) => _Host((_, _) async => session);
Matcher _authoringError(String code) => isA<TavernAuthoringException>().having((error) => error.code, 'code', code);
Map<String, Object?> _book(String content) => {
  'entries': {
    '0': {'uid': 0, 'key': <String>[], 'content': content, 'constant': true, 'position': 0},
  },
};
Future<TavernAuthoringDraft> _draft(ScriptFixture h) async {
  await h.engine.putLorebook('book', _book('A'));
  return h.engine.createAuthoringDraft([_bookTarget]);
}

class _Token implements TavernScriptCancellation {
  final done = Completer<void>();
  void cancel() {
    if (!done.isCompleted) {
      done.complete();
    }
  }

  @override
  bool get isCancelled => done.isCompleted;
  @override
  Future<void> get whenCancelled => done.future;
}

class _Host implements TavernAuthoringPreviewHost {
  _Host(this.open);
  final Future<TavernAuthoringPreviewSession> Function(TavernAuthoringHostCapture, TavernScriptCancellation) open;
  @override
  Future<TavernAuthoringPreviewSession> openPreview(
    TavernAuthoringHostCapture capture,
    TavernScriptCancellation cancellation,
  ) => open(capture, cancellation);
}

class _Session implements TavernAuthoringPreviewSession {
  _Session({this.onRender, this.onClose});
  final Future<TavernAuthoringRenderResult> Function(TavernAuthoringHostRenderRequest)? onRender;
  final Future<void> Function()? onClose;
  final invalidated = _Token();
  final entered = Completer<TavernAuthoringHostRenderRequest>();
  void Function()? afterEntered;
  var renderCalls = 0, closeCalls = 0;
  @override
  TavernAuthoringHostBinding get binding => TavernAuthoringHostBinding(
    hostEpoch: 'test-renderer-v1',
    renderModes: {TavernAuthoringRenderMode.staticMarkup},
    formats: {'image/png', 'image/jpeg'},
    maxImageBytes: 65536,
    maxPixelWidth: 16,
    maxPixelHeight: 16,
  );
  @override
  TavernScriptCancellation get sourceInvalidated => invalidated;
  @override
  Future<TavernAuthoringRenderResult> render(TavernAuthoringHostRenderRequest request) async {
    renderCalls++;
    entered.complete(request);
    afterEntered?.call();
    return onRender == null ? _result(request, bytes: _image('image/png')) : await onRender!(request);
  }

  @override
  Future<void> close() async {
    closeCalls++;
    await onClose?.call();
  }
}

Map<String, Object?> _databaseState(ScriptFixture h) => h.inspect(
  (db) => {
    for (final table in db.select("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name"))
      table['name']! as String: [
        for (final row in db.select('SELECT * FROM "${(table['name']! as String).replaceAll('"', '""')}"'))
          Map<String, Object?>.from(row),
      ],
  },
);

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

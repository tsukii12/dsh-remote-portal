/// Live checks against a running `dsh web`; no model prompts are sent.
///
/// Skipped unless `DSH_LIVE_URL` holds the launch URL (with `?token=`):
/// ```sh
/// DSH_LIVE_URL='http://127.0.0.1:3080/?token=...' dart test test/live_test.dart
/// ```
/// Creates sessions and a workspace under `DSH_LIVE_CWD` (or the Host cwd);
/// point it at a throwaway `DSH_HOME`.
@Tags(['live'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_client/dsh_client.dart';
import 'package:test/test.dart';

void main() {
  final url = Platform.environment['DSH_LIVE_URL'];
  final cwd = Platform.environment['DSH_LIVE_CWD'];
  final skip = url == null ? 'set DSH_LIVE_URL to run live tests' : null;

  group('live dsh web', skip: skip, () {
    late DshLaunchUrl launch;
    late DshClient client;

    setUpAll(() async {
      launch = DshLaunchUrl.tryParse(url!)!;
      client = await DshClient.connect(baseUri: launch.baseUri, token: launch.token);
    });

    tearDownAll(() async => client.close());

    test('cookie is reusable by a fresh connection without the token', () async {
      final again = await DshClient.connect(baseUri: launch.baseUri, cookie: client.connection.cookie);
      addTearDown(again.close);
      expect(await again.connection.checkHealth(), DshHealth.ok);
      expect(again.mux.generation!.clientId, isNot(client.mux.generation!.clientId));
    });

    test('missing cookie: HTTP 401 and mux unauthorized', () async {
      final anonymous = DshClient(DshConnection(launch.baseUri));
      addTearDown(anonymous.close);
      await expectLater(
        anonymous.listSessions(),
        throwsA(isA<DshHttpException>().having((e) => e.statusCode, 'status', 401)),
      );
      await expectLater(
        anonymous.mux.ready(),
        throwsA(isA<DshHttpException>().having((e) => e.statusCode, 'status', 401)),
      );
      expect(anonymous.mux.state, DshConnectionState.unauthorized);
    });

    test('Host header override: localhost authority gets its own cookie', () async {
      final authority = 'localhost:${launch.baseUri.port}';
      final viaLocalhost = await DshClient.connect(baseUri: launch.baseUri, token: launch.token, hostHeader: authority);
      addTearDown(viaLocalhost.close);
      expect(viaLocalhost.connection.cookie!.authority, authority);
      expect(viaLocalhost.mux.state, DshConnectionState.connected);
      await viaLocalhost.listSessions();
      // The 127.0.0.1 cookie is not valid for the localhost authority.
      final mismatched = DshClient(
        DshConnection(launch.baseUri, hostHeader: authority, cookie: client.connection.cookie),
      );
      addTearDown(mismatched.close);
      await expectLater(mismatched.listSessions(), throwsA(isA<DshHttpException>()));
    });

    test(r'$events/result reaches the Gateway (path keeps the literal $)', () async {
      // Unknown eventId: the Host accepts it as a no-op.
      await client.respondHostEvent('no-such-event', {'kind': 'next'});
      // Unknown clientId: business error, not HTTP 404.
      await expectLater(
        client.rpc.call(r'$events/result', {
          'clientId': 'stale',
          'eventId': 'x',
          'outcome': {'kind': 'next'},
        }),
        throwsA(isA<DshRemoteException>()),
      );
    });

    test('remote errors are typed', () async {
      await expectLater(
        client.rpc.call('session/list', {'request': <String, Object?>{}}),
        throwsA(isA<DshRemoteException>().having((e) => e.code, 'code', 'gateway/arguments-invalid')),
      );
      await expectLater(client.projections('session-does-not-exist'), completion(isNull));
    });

    test('watch: snapshot, resync after a forced reconnect, history paging', () async {
      final created = await client.createSession(cwd: cwd);
      await client.renameSession(created.sessionId, 'live test');
      final events = <DshEvent>[];
      final snapshots = StreamController<SessionSnapshotEvent>.broadcast();
      final sub = client.watch(created.sessionId).listen((event) {
        events.add(event);
        if (event is SessionSnapshotEvent) snapshots.add(event);
      });
      addTearDown(sub.cancel);
      final first = await snapshots.stream.first.timeout(const Duration(seconds: 10));
      expect(first.isResync, isFalse);
      expect(first.header.id, created.sessionId);
      expect(first.events.map((e) => e.type), contains('session/title'));

      final resync = snapshots.stream.first.timeout(const Duration(seconds: 20));
      client.mux.reconnect();
      final second = await resync;
      expect(second.isResync, isTrue);
      expect(second.cursor, first.cursor);
      expect(
        events.whereType<ConnectionStateEvent>().map((e) => e.state),
        containsAllInOrder([DshConnectionState.reconnecting, DshConnectionState.connected]),
      );

      // A durable event after the resync continues the seq chain.
      await client.renameSession(created.sessionId, 'live test 2');
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final titles = events.whereType<TitleChangedEvent>().toList();
      expect(titles.last.title, 'live test 2');
      expect(titles.last.seq, first.cursor + 1);

      final page = await client.history(created.sessionId, throughSeq: titles.last.seq, beforeSeq: 2);
      expect(page.events.map((e) => e.seq), [0, 1]);
      expect(page.hasMore, isFalse);
    });

    test('workspace follow emits a baseline and archive updates', () async {
      final created = await client.createSession(cwd: cwd);
      final updates = <WorkspaceUpdate>[];
      final sub = client.watchWorkspaces().listen(updates.add);
      addTearDown(sub.cancel);
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(updates.first, isA<WorkspaceBaseline>());
      final archived = await client.archiveSession(created.sessionId);
      expect(archived, contains(created.sessionId));
      await client.unarchiveSession(created.sessionId);
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(updates.whereType<WorkspaceArchivedUpdate>().length, greaterThanOrEqualTo(2));
    });

    test('attachments: a staged file and an inline image come back on the user message', () async {
      // Runs without provider credentials: the prompt is admitted and echoed,
      // then the turn fails before any model call.
      final created = await client.createSession(cwd: cwd);
      final sid = created.sessionId;
      final events = <DshEvent>[];
      final sub = client.watch(sid).listen(events.add);
      addTearDown(sub.cancel);
      // Inline images need a model that reads them (V4 Pro is text-only and
      // may be the saved default); without a catalog, keep the Host default.
      final vision = (await client.listModels()).models.where((m) => m.id == 'deepseek-flash').firstOrNull;
      if (vision != null) await client.setModel(sid, provider: vision.provider, model: vision.id);

      final receipt = await client.uploadFile(sid, 'hello, file\n'.codeUnits, name: 'notes.md');
      expect(receipt.receiptId, isNotEmpty);
      expect(receipt.attachment.name, 'notes.md');
      expect(receipt.attachment.bytes, 12);

      final png = base64Decode(_tinyPng);
      await client.prompt(
        sid,
        '看看附件',
        images: [PromptImage.fromBytes(png, mediaType: 'image/png', name: 'dot.png')],
        fileReceiptIds: [receipt.receiptId],
      );

      UserMessageEvent? echoed;
      for (var i = 0; i < 50 && echoed == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        echoed = events.whereType<UserMessageEvent>().firstOrNull;
      }
      expect(echoed, isNotNull, reason: 'user/message not echoed');
      final parts = echoed!.message.parts;
      expect(parts.whereType<TextPart>().single.text, '看看附件');
      final file = parts.whereType<FilePart>().single.attachment;
      expect(file.name, 'notes.md');
      expect(file.bytes, 12);
      final image = parts.whereType<ImagePart>().single.attachment;

      final fetched = await client.attachment(sid, image);
      expect(fetched.bytes, png);
      await client.cancel(sid);
    });

    test('a text-only model refuses images with a reason; the same request goes through as a file', () async {
      // Needs a DeepSeek credential in the throwaway home (any value: the turn
      // fails before a real model answers) so the catalog lists V4 Pro.
      final catalog = await client.listModels();
      final pro = catalog.models.where((m) => m.id == 'deepseek-v4-pro').firstOrNull;
      if (pro == null) {
        markTestSkipped('deepseek-v4-pro is not in the catalog (no DeepSeek credential)');
        return;
      }
      final sid = (await client.createSession(cwd: cwd)).sessionId;
      final events = <DshEvent>[];
      final sub = client.watch(sid).listen(events.add);
      addTearDown(sub.cancel);
      await client.setModel(sid, provider: pro.provider, model: pro.id);

      final png = base64Decode(_tinyPng);
      final requestId = 'live-img-${DateTime.now().microsecondsSinceEpoch}';
      await expectLater(
        client.prompt(
          sid,
          '看看这张图',
          images: [PromptImage.fromBytes(png, mediaType: 'image/png', name: 'dot.png')],
          requestId: requestId,
        ),
        throwsA(
          isA<DshRemoteException>()
              .having((e) => e.code, 'code', 'session/attachment-invalid')
              .having((e) => e.details['reason'], 'reason', 'MODEL_DOES_NOT_SUPPORT_IMAGES'),
        ),
      );

      // Refused at admission, so nothing was recorded: retrying the same
      // request with the image staged as a file is accepted.
      final receipt = await client.uploadFile(sid, png, name: 'dot.png');
      await client.prompt(sid, '看看这张图', fileReceiptIds: [receipt.receiptId], requestId: requestId);
      UserMessageEvent? echoed;
      for (var i = 0; i < 50 && echoed == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        echoed = events.whereType<UserMessageEvent>().firstOrNull;
      }
      expect(echoed, isNotNull, reason: 'user/message not echoed');
      expect(echoed!.message.source.requestId, requestId);
      expect(echoed.message.parts.whereType<FilePart>().single.attachment.name, 'dot.png');
      expect(echoed.message.parts.whereType<ImagePart>(), isEmpty);
      await client.cancel(sid);
    });

    test('credentials set/describe/unset on a scratch ref', () async {
      const ref = 'DSH_CLIENT_LIVE_TEST_REF';
      await client.setProviderKey('not-a-real-key', ref: ref);
      expect((await client.describeCredentials([ref]))[ref]!.configured, isTrue);
      await client.clearProviderKey(ref: ref);
      expect((await client.describeCredentials([ref]))[ref]!.configured, isFalse);
    });
  });
}

/// A 4×4 PNG.
const _tinyPng = 'iVBORw0KGgoAAAANSUhEUgAAAAQAAAAECAYAAACp8Z5+AAAAEklEQVR4nGPwTt/yHxkzkC4AAAPnJlH/osXzAAAAAElFTkSuQmCC';

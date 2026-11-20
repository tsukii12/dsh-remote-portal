import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/state/mention_state.dart';
import 'package:dsh_app/ui/chat/mention/mention_controller.dart';
import 'package:dsh_app/ui/chat/mention/mention_text_controller.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

// Keep the real Dart socket implementation under Flutter's test binding.
class _RealHttp extends HttpOverrides {}

final _summaries = [
  for (final id in ['a', 'b'])
    SessionSummary.fromJson({
      'sessionId': id,
      'cwd': '/work/$id',
      'updatedAt': 1793740000000,
      'running': false,
      'blank': false,
      'agentAvailable': true,
    }),
];

class _Host {
  _Host(this.server) {
    server.listen((request) {
      final work = _respond(request);
      handlers.add(work);
      // A test assertion must not leave a server-side rejection unowned.
      unawaited(work.catchError((Object error) => errors.add(error)));
    });
  }

  final HttpServer server;
  final aSeen = Completer<void>();
  final aReply = Completer<bool>();
  final handlers = <Future<void>>[];
  final errors = <Object>[];
  final fileCalls = <String>[];

  static Future<_Host> start() async => _Host(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));

  Future<void> _respond(HttpRequest request) async {
    final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map<String, dynamic>;
    final payload = body['payload'] as Map<String, dynamic>;
    final args = payload['args'] as Map<String, dynamic>;
    Object? value;
    var ok = true;
    switch (request.uri.path) {
      case '/api/session/list':
        value = {
          'items': [
            for (final row in _summaries)
              {
                'sessionId': row.sessionId,
                'cwd': row.cwd,
                'updatedAt': row.updatedAt.millisecondsSinceEpoch,
                'running': false,
                'blank': false,
                'agentAvailable': true,
              },
          ],
        };
      case '/api/sessionReferenceResolver/candidates':
        value = <Object?>[];
      case '/api/fileReferences/list':
        final id = args['agentId'] as String;
        expect(args['query'], '');
        fileCalls.add(id);
        if (id == 'a') {
          if (!aSeen.isCompleted) aSeen.complete();
          ok = await aReply.future;
        }
        value = [
          {'path': 'README-$id.md', 'kind': 'file'},
        ];
      default:
        throw StateError('unexpected RPC ${request.uri.path}');
    }
    request.response.headers.contentType = ContentType.json;
    request.response.write(
      jsonEncode({
        'type': 'server-response',
        'rpcId': body['rpcId'],
        'result': ok
            ? {'ok': true, 'value': value}
            : {
                'ok': false,
                'error': {'code': 'file-reference/unavailable', 'message': 'controlled read failure'},
              },
      }),
    );
    await request.response.close();
  }

  Future<void> close() async {
    if (!aReply.isCompleted) aReply.complete(true);
    await Future.wait(handlers);
    await server.close(force: true);
    expect(errors, isEmpty);
  }
}

class _Rig {
  _Rig(this.host) {
    client = DshClient(DshConnection(Uri.parse('http://127.0.0.1:${host.server.port}')));
    source = ClientMentionSource(client);
    picker = MentionPickerController(
      input: input,
      source: () => source,
      sessionId: () => session,
      localSessions: () async {
        localReads++;
        for (final entry in waiters.entries.toList()) {
          if (localReads >= entry.key) {
            waiters.remove(entry.key);
            entry.value.complete();
          }
        }
        return _summaries;
      },
      recents: recents,
      clock: () => DateTime.fromMillisecondsSinceEpoch(1793740000000),
    );
  }

  final _Host host;
  final input = MentionTextController();
  final recents = MentionRecents(persist: false);
  late final DshClient client;
  late final ClientMentionSource source;
  late final MentionPickerController picker;
  String session = 'a';
  int localReads = 0;
  final waiters = <int, Completer<void>>{};

  static Future<_Rig> start() async {
    final rig = _Rig(await _Host.start());
    addTearDown(rig.close);
    return rig;
  }

  void open(String id) {
    // ChatScreen._switchDraft dismisses and restores the new conversation's
    // draft; here it is empty. The person then opens its own @ picker.
    picker.dismiss();
    session = id;
    input.value = const TextEditingValue(text: '', selection: TextSelection.collapsed(offset: 0));
    input.value = const TextEditingValue(text: '@', selection: TextSelection.collapsed(offset: 1));
  }

  Future<void> ready(String id) {
    bool done() => !picker.loading && picker.items.any((item) => item.path == 'README-$id.md');
    if (done()) return Future.value();
    final completion = Completer<void>();
    void listen() {
      if (!done()) return;
      picker.removeListener(listen);
      completion.complete();
    }

    picker.addListener(listen);
    return completion.future;
  }

  Future<void> lateLookupSettled(int reads) async {
    if (localReads < reads) await (waiters[reads] ??= Completer<void>()).future;
    // The observed lookup reached its final await (localSessions). All work
    // after it is synchronous or a Future continuation. One event barrier
    // drains those microtasks; this is not a fixed wall-clock sleep.
    await Future<void>(() {});
  }

  Future<void> close() async {
    picker.dispose();
    input.dispose();
    await host.close();
    await client.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (_) async => null,
    );
  });

  for (final success in [true, false]) {
    test('late file lookup ${success ? 'success' : 'failure'} cannot change current reference workspace', () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final rig = await _Rig.start();
        rig.open('a');
        await rig.host.aSeen.future;
        rig.open('b');
        await rig.ready('b');
        expect(rig.host.fileCalls, ['a', 'b']);
        expect(rig.localReads, 2); // constructor and the adopted B lookup

        rig.host.aReply.complete(success);
        await rig.lateLookupSettled(3);
        expect(rig.picker.items.single.path, 'README-b.md');
        expect(rig.picker.loading, isFalse);

        rig.picker.pick(rig.picker.items.single);
        expect(rig.input.text, '@README-b.md ');
        expect(rig.recents.entries.single.key, 'f:README-b.md');
        expect(rig.recents.entries.single.sessionId, 'b');
        expect(rig.recents.entries.single.cwd, '/work/b');
      }, _RealHttp());
    });
  }

  test('a current lookup still records its file with the actual workspace', () async {
    await HttpOverrides.runWithHttpOverrides(() async {
      final rig = await _Rig.start();
      rig.open('a');
      await rig.host.aSeen.future;
      rig.host.aReply.complete(true);
      await rig.ready('a');
      rig.picker.pick(rig.picker.items.single);
      expect(rig.input.text, '@README-a.md ');
      expect(rig.recents.entries.single.cwd, '/work/a');
      expect(rig.recents.entries.single.sessionId, 'a');
    }, _RealHttp());
  });
}

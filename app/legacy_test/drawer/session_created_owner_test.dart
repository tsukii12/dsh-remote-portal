import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/session_created_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _host = HostRef.portal('created-owner');
final _created = DateTime.fromMillisecondsSinceEpoch(1793000000000);

Map<String, Object?> _page(DateTime? at) => {
  'hasMore': false,
  'records': [
    if (at != null)
      {
        'event': {
          'seq': 0,
          'time': at.millisecondsSinceEpoch,
          'type': 'turn/start',
          'data': {'turn': 1},
        },
      },
  ],
};

class _Read {
  _Read(this.id);
  final String id;
  final answer = Completer<RpcResult>();
}

class _Carrier extends DshCarrier {
  final reads = <_Read>[];
  bool closed = false;
  late final client = DshClient.withCarrier(this);

  @override
  String get kind => 'controlled-created-time';
  @override
  DshTracer? get tracer => null;

  @override
  Future<RpcResult> call(String endpoint, Map<String, Object?> args, {Duration? timeout}) {
    if (closed) throw const DshClosedException('carrier closed');
    expect(endpoint, 'session/page');
    final request = args['request']! as Map;
    expect(request['throughSeq'], 0);
    expect(request['maxMessages'], 1);
    final address = request['address']! as Map;
    final read = _Read(address['sessionId']! as String);
    reads.add(read);
    return read.answer.future;
  }

  @override
  Future<DshMuxLink> openLink(MuxOptions options) => throw StateError('history does not open a stream');

  // Like ordinary HTTP close(force: false), closing prevents new calls but
  // does not replace the replies of already-started unary requests.
  @override
  Future<void> close() async => closed = true;
}

_Carrier _carrier() {
  final carrier = _Carrier();
  addTearDown(() {
    for (final read in carrier.reads) {
      if (!read.answer.isCompleted) read.answer.complete(RpcOk(_page(null)));
    }
  });
  return carrier;
}

class _Harness {
  _Harness(this.container, this.clients);
  final ProviderContainer container;
  final List<DshClient> clients;

  SessionCreatedController get controller => container.read(sessionCreatedProvider.notifier);
  Map<String, DateTime> get state => container.read(sessionCreatedProvider);

  static AsyncValue<HostConnection?> connection(DshClient client) =>
      AsyncData(HostConnection(client: client, isLocal: false, kind: HostKind.portal, hostId: _host.id));

  static Future<_Harness> start(DshClient client) async {
    final container = ProviderContainer(overrides: [activeConnectionProvider.overrideWithValue(connection(client))]);
    container.read(activeHostProvider.notifier).select(_host);
    container.listen(sessionCreatedProvider, (_, _) {});
    final h = _Harness(container, [client]);
    addTearDown(() async {
      container.dispose();
      for (final client in h.clients) {
        await client.close();
      }
    });
    await h.flush();
    return h;
  }

  Future<void> flush() async {
    await container.pump();
    for (var i = 0; i < 16; i++) {
      await Future<void>.value();
    }
  }

  Future<void> replace(DshClient client) async {
    final before = controller;
    final previous = clients.last;
    clients.add(client);
    container.updateOverrides([activeConnectionProvider.overrideWithValue(connection(client))]);
    // SshHostLink publishes the new client, then gracefully closes the old
    // one. The real fetcher rebuilds while the host/cache key stays the same.
    await previous.close();
    await flush();
    expect(controller, same(before));
    expect(container.read(activeHostProvider), _host);
    expect(container.read(activeConnectionProvider).value!.client, same(client));
  }
}

/// Observes a real HTTP carrier after its response has been decoded, so the
/// test can drain the controller's continuation without a timed wait.
class _ObservedHttp extends DshHttpCarrier {
  _ObservedHttp(super.connection);
  final replies = <Completer<void>>[];

  @override
  Future<RpcResult> call(String endpoint, Map<String, Object?> args, {Duration? timeout}) async {
    final done = Completer<void>();
    replies.add(done);
    try {
      return await super.call(endpoint, args, timeout: timeout);
    } finally {
      done.complete();
    }
  }
}

class _HttpPage {
  _HttpPage(this.server, this.automatic);
  final HttpServer server;
  final DateTime? automatic;
  final entered = Completer<void>();
  final answer = Completer<RpcResult>();
  final handlers = <Future<void>>[];
  late final carrier = _ObservedHttp(DshConnection(Uri.parse('http://127.0.0.1:${server.port}')));
  late final client = DshClient.withCarrier(carrier);

  static Future<_HttpPage> start({DateTime? automatic}) async {
    final wire = _HttpPage(await HttpServer.bind(InternetAddress.loopbackIPv4, 0), automatic);
    wire.server.listen((request) => wire.handlers.add(wire.respond(request)));
    addTearDown(() async {
      if (!wire.answer.isCompleted) wire.answer.complete(RpcOk(_page(null)));
      await Future.wait(wire.handlers);
      await wire.server.close(force: true);
    });
    return wire;
  }

  Future<void> respond(HttpRequest request) async {
    expect(request.uri.path, '/api/session/page');
    final envelope = jsonDecode(await utf8.decodeStream(request)) as Map;
    if (!entered.isCompleted) entered.complete();
    final result = automatic == null ? await answer.future : RpcOk(_page(automatic));
    final response = request.response;
    response.headers.contentType = ContentType.json;
    response.write(
      jsonEncode({
        'type': 'server-response',
        'rpcId': envelope['rpcId'],
        'result': switch (result) {
          RpcOk(:final value) => {'ok': true, 'value': value},
          RpcError(:final error) => {
            'ok': false,
            'error': {'code': error.code, 'message': error.message},
          },
        },
      }),
    );
    await response.close();
  }
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    // Match main()'s warmed preferences; the regression is not a cold-store race.
    await SharedPreferences.getInstance();
  });

  for (final late in ['remote-error', 'empty-page']) {
    test('retired $late cannot suppress the replacement client creation-time read', () async {
      final first = _carrier();
      final next = _carrier();
      final h = await _Harness.start(first.client);
      h.controller.ensure(['shared']);
      expect(first.reads.single.id, 'shared');
      await h.replace(next.client);

      first.reads.single.answer.complete(
        late == 'remote-error'
            ? const RpcError(DshRemoteException('session/not-found', 'old reply'))
            : RpcOk(_page(null)),
      );
      await h.flush();
      // DrawerList asks in a post-frame callback. A retired response can
      // finish after the provider rebuild but before this next ensure.
      h.controller.ensure(['shared']);
      expect(next.reads, hasLength(1), reason: 'an old failure must not enter the new fetcher failed set');
      next.reads.single.answer.complete(RpcOk(_page(_created)));
      await h.flush();
      expect(h.state, {'shared': _created});
    });
  }

  test('real HTTP response after graceful old-client close still belongs to the retired fetcher', () async {
    final first = await _HttpPage.start();
    final next = await _HttpPage.start(automatic: _created);
    final h = await _Harness.start(first.client);
    h.controller.ensure(['shared']);
    await first.entered.future;
    expect(first.carrier.replies, hasLength(1));
    await h.replace(next.client);
    first.answer.complete(const RpcError(DshRemoteException('session/not-found', 'old HTTP reply')));
    await first.carrier.replies.single.future;
    await h.flush();

    h.controller.ensure(['shared']);
    expect(next.carrier.replies, hasLength(1), reason: 'graceful close did not cancel the earlier HTTP reply');
    await next.carrier.replies.single.future;
    await h.flush();
    expect(h.state, {'shared': _created});
  });

  test('retired workers free both slots for the already-queued replacement reads', () async {
    final first = _carrier();
    final next = _carrier();
    final h = await _Harness.start(first.client);
    h.controller.ensure(['old-a', 'old-b']);
    expect(first.reads, hasLength(SessionCreatedController.parallel));
    await h.replace(next.client);
    h.controller.ensure(['new-a', 'new-b']);
    expect(next.reads, isEmpty);
    for (final read in first.reads) {
      read.answer.complete(RpcOk(_page(null)));
    }
    await h.flush();
    expect(next.reads.map((r) => r.id), ['new-a', 'new-b']);
    for (final read in next.reads) {
      read.answer.complete(RpcOk(_page(_created)));
    }
    await h.flush();
    expect(h.state, {'new-a': _created, 'new-b': _created});
  });

  test('a current fetcher failure is still deduplicated until a replacement', () async {
    final first = _carrier();
    final next = _carrier();
    final h = await _Harness.start(first.client);
    h.controller.ensure(['missing']);
    first.reads.single.answer.complete(const RpcError(DshRemoteException('session/not-found', 'current reply')));
    await h.flush();
    h.controller.ensure(['missing']);
    expect(first.reads, hasLength(1));
    await h.replace(next.client);
    h.controller.ensure(['missing']);
    expect(next.reads, hasLength(1));
  });

  test('persisted creation times are still restored without another read', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      SessionCreatedController.keyFor(_host),
      jsonEncode({'known': _created.millisecondsSinceEpoch}),
    );
    final first = _carrier();
    final next = _carrier();
    final h = await _Harness.start(first.client);
    h.controller.ensure(['known']);
    expect(h.state, {'known': _created});
    expect(first.reads, isEmpty);
    await h.replace(next.client);
    h.controller.ensure(['known']);
    expect(h.state, {'known': _created});
    expect(next.reads, isEmpty);
  });

  test('a pending read may finish after disposal without starting another read', () async {
    final first = _carrier();
    final h = await _Harness.start(first.client);
    h.controller.ensure(['one', 'two', 'queued']);
    expect(first.reads, hasLength(2));
    h.container.dispose();
    for (final read in first.reads) {
      read.answer.complete(RpcOk(_page(_created)));
    }
    for (var i = 0; i < 16; i++) {
      await Future<void>.value();
    }
    expect(first.reads, hasLength(2));
  });
}

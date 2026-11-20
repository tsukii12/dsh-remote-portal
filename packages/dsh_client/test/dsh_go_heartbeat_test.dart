import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_client/dsh_client.dart';
import 'package:test/test.dart';

void main() {
  test('healthy control ping/pong does not reconnect a quiet live surface', () {
    final clock = _Clock();
    return clock.run(() async {
      final h = await _Harness.start(clock);
      final original = h.socket;
      final received = original.incoming.all.length;
      await h.controlPingRoundTrip();
      expect(original.incoming.all, hasLength(received), reason: 'control frames stay inside dart:io');

      clock.elapse(const Duration(seconds: 5)); // 30 s since the last text.
      await h.drainProbeIfSent();
      clock.elapse(const Duration(seconds: 30));

      expect(h.stream.subscriptionCount, 1);
      expect(h.stream.link, DshGoLink.open);
      expect(h.stream.conn, 'c1');
      expect(original.closedWith, isNull);
      expect(h.host.connections.all, hasLength(1));
    });
  }, skip: 'Upstream v1.2.0 flake on Dart 3.13.5: fixture writes to a closed WebSocket (line 302).');

  test('sending an unanswered probe does not move the original silence deadline', () {
    final clock = _Clock();
    return clock.run(() async {
      final h = await _Harness.start(clock, answerProbe: false);
      await h.controlPingRoundTrip();
      clock.elapse(const Duration(seconds: 5));
      await h.drainProbeIfSent();
      clock.elapse(const Duration(seconds: 29));
      expect(h.stream.link, DshGoLink.open);

      clock.elapse(const Duration(seconds: 1));
      expect(h.stream.link, DshGoLink.backoff);
      expect(h.socket.closedWith, 1000);
      expect(await h.host.current.closed.future.timeout(_watchdog), 1000);
    });
  });

  for (final version in <int?>[null, 2]) {
    test('business data without a supported welcome does not enable probes ($version)', () {
      final clock = _Clock();
      return clock.run(() async {
        // The Host still sends initial data. It is not proof of welcome.
        final h = await _Harness.start(clock, welcomeVersion: version);
        clock.elapse(const Duration(seconds: 30));
        expect(h.socket.sent.where((m) => m['t'] == 'ping'), isEmpty);
        clock.elapse(const Duration(seconds: 30));
        expect(h.stream.link, DshGoLink.backoff);
        expect(await h.host.current.closed.future.timeout(_watchdog), 1000);
      });
    });
  }

  test('actual business data restarts both the quiet window and its deadline', () {
    final clock = _Clock();
    return clock.run(() async {
      final h = await _Harness.start(clock, answerProbe: false);
      clock.elapse(const Duration(seconds: 20));
      h.host.current.send({
        't': 'data',
        'sub': 's1',
        'rev': 'r2',
        'data': {'text': 'changed'},
      });
      expect((await h.nextData()).rev, 'r2');

      clock.elapse(const Duration(seconds: 10));
      expect(h.socket.sent.where((m) => m['t'] == 'ping'), isEmpty);
      clock.elapse(const Duration(seconds: 20));
      await h.drainProbeIfSent();
      clock.elapse(const Duration(seconds: 29));
      expect(h.stream.link, DshGoLink.open);
      clock.elapse(const Duration(seconds: 1));
      expect(h.stream.link, DshGoLink.backoff);
      expect(await h.host.current.closed.future.timeout(_watchdog), 1000);
    });
  });

  test('end with no remaining owner cannot keep itself alive through probes', () {
    final clock = _Clock();
    return clock.run(() async {
      final h = await _Harness.start(clock);
      h.host.current.send({'t': 'end', 'sub': 's1', 'reason': 'not-found'});
      await h.ended.future.timeout(_watchdog);
      expect(h.stream.subscriptionCount, 0);

      clock.elapse(const Duration(seconds: 30));
      expect(h.socket.sent.where((m) => m['t'] == 'ping'), isEmpty);
      clock.elapse(const Duration(seconds: 30));
      expect(h.stream.link, DshGoLink.idle);
      expect(await h.host.current.closed.future.timeout(_watchdog), 1000);
    });
  });

  test('explicit close retires a pending probe', () {
    final clock = _Clock();
    return clock.run(() async {
      final h = await _Harness.start(clock);
      await h.stream.close();
      expect(await h.host.current.closed.future.timeout(_watchdog), 1000);
      clock.elapse(const Duration(seconds: 120));
      expect(h.stream.link, DshGoLink.closed);
      expect(h.socket.sent.where((m) => m['t'] == 'ping'), isEmpty);
      expect(h.host.connections.all, hasLength(1));
    });
  });

  test('a dropped connection cannot send its old probe on its replacement', () {
    final clock = _Clock();
    return clock.run(() async {
      final h = await _Harness.start(clock);
      final old = h.socket;
      final lost = h.stream.links.firstWhere((link) => link == DshGoLink.backoff);
      await h.host.current.socket.close(1001);
      await lost.timeout(_watchdog);
      clock.elapse(const Duration(seconds: 1));
      await h.nextData();
      expect(h.stream.conn, 'c2');

      clock.elapse(const Duration(seconds: 29));
      expect(old.sent.where((m) => m['t'] == 'ping'), isEmpty);
      expect(h.socket.sent.where((m) => m['t'] == 'ping'), isEmpty, reason: 'new quiet window starts at 1 s');
      clock.elapse(const Duration(seconds: 1));
      await h.drainProbeIfSent();
      expect(h.stream.link, DshGoLink.open);
      expect(h.host.connections.all, hasLength(2));
    });
  });
}

const _watchdog = Duration(seconds: 5);

class _Harness {
  _Harness(this.clock, this.host, this.client);

  final _Clock clock;
  final _Host host;
  final DshClient client;
  late final DshGoStream stream;
  final sockets = <_ObservedSocket>[];
  final events = _Inbox<DshGoEvent>();
  final ended = Completer<void>();

  _ObservedSocket get socket => sockets.last;

  static Future<_Harness> start(_Clock clock, {bool answerProbe = true, int? welcomeVersion = 1}) async {
    final host = await _Host.start(answerProbe: answerProbe, welcomeVersion: welcomeVersion);
    addTearDown(host.close);
    final client = await DshClient.connect(baseUri: host.baseUri, token: 'test-token', startMux: false);
    addTearDown(client.close);
    final h = _Harness(clock, host, client);
    h.stream = DshGoStream(() async {
      // The same authenticated connector and io adapter as openDshGoStream;
      // this delegate only records text and close calls for I/O barriers.
      final socket = await client.connection.connectWebSocket(dshGoStreamPath);
      final observed = _ObservedSocket(DshGoSocket.io(socket));
      h.sockets.add(observed);
      return observed;
    });
    addTearDown(h.stream.close);
    final subscription = h.stream
        .subscribe(pkg: '@acme/usage', id: 'cost')
        .listen(h.events.add, onDone: h.ended.complete);
    addTearDown(subscription.cancel);
    await h.nextData();
    return h;
  }

  Future<DshGoData> nextData() async => await events.nextWhere((event) => event is DshGoData) as DshGoData;

  Future<void> controlPingRoundTrip() async {
    final before = clock.count(const Duration(seconds: 25));
    host.current.socket.pingInterval = const Duration(seconds: 25);
    clock.elapse(const Duration(seconds: 25));
    // Fixed dart:io creates the initial ping timer, its no-pong deadline,
    // then a fresh ping timer only after the real peer's pong is consumed.
    await clock.whenCount(const Duration(seconds: 25), before + 3).timeout(_watchdog);
  }

  Future<void> drainProbeIfSent() async {
    // Advance real I/O only for bytes this version actually sent. The base
    // has no probe; it still reaches the same final link-state assertion.
    final sent = socket.sent.where((m) => m['t'] == 'ping').length;
    while (host.current.messages.all.where((m) => m['t'] == 'ping').length < sent) {
      await host.current.messages.nextWhere((m) => m['t'] == 'ping');
    }
    if (!host.answerProbe) return;
    while (socket.incoming.all.where((m) => m['t'] == 'pong').length < sent) {
      await socket.incoming.nextWhere((m) => m['t'] == 'pong');
    }
  }
}

class _ObservedSocket implements DshGoSocket {
  _ObservedSocket(this.delegate);

  final DshGoSocket delegate;
  final sent = <Map<String, Object?>>[];
  final incoming = _Inbox<Map<String, Object?>>();
  int? closedWith;

  @override
  late final messages = delegate.messages.map((raw) {
    if (raw is String) incoming.add(jsonDecode(raw) as Map<String, Object?>);
    return raw;
  });

  @override
  void send(String text) {
    sent.add(jsonDecode(text) as Map<String, Object?>);
    delegate.send(text);
  }

  @override
  Future<void> close([int? code]) {
    closedWith = code;
    return delegate.close(code);
  }
}

class _Host {
  _Host(this.server, this.answerProbe, this.welcomeVersion);

  final HttpServer server;
  final bool answerProbe;
  final int? welcomeVersion;
  final connections = _Inbox<_HostConnection>();
  _HostConnection get current => connections.all.last;
  Uri get baseUri => Uri.parse('http://127.0.0.1:${server.port}');

  static Future<_Host> start({required bool answerProbe, required int? welcomeVersion}) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final host = _Host(server, answerProbe, welcomeVersion);
    server.listen((request) => unawaited(host.handle(request)));
    return host;
  }

  Future<void> handle(HttpRequest request) async {
    if (request.uri.queryParameters['token'] == 'test-token') {
      request.response
        ..statusCode = 303
        ..headers.set('location', './')
        ..headers.add('set-cookie', 'dsh-auth-test=v1.sig; Max-Age=3600; Path=/; HttpOnly');
      await request.response.close();
      return;
    }
    if (request.headers.value(HttpHeaders.cookieHeader) != 'dsh-auth-test=v1.sig') {
      request.response.statusCode = 401;
      await request.response.close();
      return;
    }
    if (request.uri.path != dshGoStreamPath || !WebSocketTransformer.isUpgradeRequest(request)) {
      request.response.statusCode = 404;
      await request.response.close();
      return;
    }
    final socket = await WebSocketTransformer.upgrade(request);
    final connection = _HostConnection(socket);
    connections.add(connection);
    final id = 'c${connections.all.length}';
    socket.listen((raw) {
      final message = jsonDecode(raw as String) as Map<String, Object?>;
      connection.messages.add(message);
      switch (message['t']) {
        case 'hello':
          if (welcomeVersion != null) connection.send({'t': 'welcome', 'v': welcomeVersion, 'conn': id, 'hb': 25});
        case 'sub':
          connection.send({
            't': 'data',
            'sub': message['sub'],
            'rev': 'r1',
            'data': {'text': 'quiet'},
          });
        case 'ping':
          if (answerProbe) connection.send({'t': 'pong'});
      }
    }, onDone: () => connection.closed.complete(socket.closeCode));
  }

  Future<void> close() async {
    for (final connection in connections.all) {
      await connection.socket.close();
    }
    await server.close(force: true);
  }
}

class _HostConnection {
  _HostConnection(this.socket);

  final WebSocket socket;
  final messages = _Inbox<Map<String, Object?>>();
  final closed = Completer<int?>();
  void send(Map<String, Object?> message) => socket.add(jsonEncode(message));
}

class _Inbox<T> {
  final all = <T>[];
  final _buffer = <T>[];
  final _waiting = <Completer<T>>[];

  void add(T value) {
    all.add(value);
    if (_waiting.isEmpty) {
      _buffer.add(value);
    } else {
      _waiting.removeAt(0).complete(value);
    }
  }

  Future<T> nextWhere(bool Function(T) accept) async {
    while (true) {
      final value = _buffer.isNotEmpty ? _buffer.removeAt(0) : await _wait();
      if (accept(value)) return value;
    }
  }

  Future<T> _wait() {
    final waiter = Completer<T>();
    _waiting.add(waiter);
    return waiter.future.timeout(_watchdog);
  }
}

/// Advances only the documented 25 s control heartbeat, 30 s probe, 60 s
/// silence and 1 s initial reconnect. Real I/O/microtasks and watchdogs run.
class _Clock {
  Duration elapsed = Duration.zero;
  final _timers = <_ManualTimer>[];
  final _waiters = <(Duration, int, Completer<void>)>[];

  T run<T>(T Function() body) => runZoned(
    body,
    zoneSpecification: ZoneSpecification(
      createTimer: (self, parent, zone, duration, callback) {
        if (!const [
          Duration(seconds: 1),
          Duration(seconds: 25),
          Duration(seconds: 30),
          Duration(seconds: 60),
        ].contains(duration)) {
          return parent.createTimer(zone, duration, callback);
        }
        final timer = _ManualTimer(duration, elapsed + duration, callback);
        _timers.add(timer);
        for (final waiter in _waiters.toList()) {
          if (count(waiter.$1) >= waiter.$2) {
            _waiters.remove(waiter);
            waiter.$3.complete();
          }
        }
        return timer;
      },
    ),
  );

  int count(Duration duration) => _timers.where((timer) => timer.duration == duration).length;

  Future<void> whenCount(Duration duration, int target) {
    if (count(duration) >= target) return Future.value();
    final waiter = Completer<void>();
    _waiters.add((duration, target, waiter));
    return waiter.future;
  }

  void elapse(Duration amount) {
    final target = elapsed + amount;
    while (true) {
      final due = _timers.where((timer) => timer.isActive && timer.deadline <= target).toList()
        ..sort((a, b) => a.deadline.compareTo(b.deadline));
      if (due.isEmpty) break;
      final timer = due.first;
      elapsed = timer.deadline;
      timer.fire();
    }
    elapsed = target;
  }
}

class _ManualTimer implements Timer {
  _ManualTimer(this.duration, this.deadline, this.callback);
  final Duration duration;
  final Duration deadline;
  final void Function() callback;
  bool _active = true;
  int _tick = 0;

  @override
  bool get isActive => _active;
  @override
  int get tick => _tick;
  @override
  void cancel() => _active = false;

  void fire() {
    if (!_active) return;
    _active = false;
    _tick = 1;
    callback();
  }
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_client/dsh_client.dart';
import 'package:test/test.dart';

/// The DS Bot channel of a `dsh web` Host: `POST /api/bot` behind the session
/// cookie, and the SSE feed. [feeds] scripts each feed connection in turn.
class FakeDsBot {
  FakeDsBot._(this._server);

  static const cookie = 'dsh-auth-test=v1.payload.sig';

  static Future<FakeDsBot> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fake = FakeDsBot._(server);
    server.listen(fake._handle);
    return fake;
  }

  final HttpServer _server;
  int get port => _server.port;
  Uri get baseUri => Uri.parse('http://127.0.0.1:$port');

  final Map<String, Object? Function(Map<String, Object?> payload)> handlers = {};
  final List<Map<String, Object?>> calls = [];
  final List<Map<String, String?>> requests = [];
  bool installed = true;

  /// Each feed connection takes the next script: it writes the chunks, then
  /// keeps the connection open while [holdFeed] is set, else closes it.
  final List<List<String>> feeds = [];
  bool holdFeed = false;
  final List<HttpResponse> _open = [];

  Future<void> close() async {
    for (final response in _open) {
      await response.close().catchError((_) {});
    }
    await _server.close(force: true);
  }

  /// Ends every open feed connection, as a host restart would.
  Future<void> dropFeeds() async {
    for (final response in [..._open]) {
      _open.remove(response);
      await response.close().catchError((_) {});
    }
  }

  Future<void> _handle(HttpRequest request) async {
    requests.add({
      'path': request.uri.path,
      'host': request.headers.value('host'),
      'cookie': request.headers.value(HttpHeaders.cookieHeader),
      'accept': request.headers.value(HttpHeaders.acceptHeader),
    });
    final response = request.response;
    if (request.headers.value(HttpHeaders.cookieHeader) != cookie) {
      response.statusCode = 401;
      await response.close();
      return;
    }
    if (!installed) {
      response.statusCode = 404;
      await response.close();
      return;
    }
    if (request.uri.path == '/api/bot/feed' && request.method == 'GET') {
      response.headers.contentType = ContentType('text', 'event-stream', charset: 'utf-8');
      response.bufferOutput = false;
      final script = feeds.isEmpty ? const <String>[] : feeds.removeAt(0);
      for (final chunk in script) {
        response.write(chunk);
        await response.flush();
      }
      if (holdFeed) {
        _open.add(response);
      } else {
        await response.close();
      }
      return;
    }
    if (request.uri.path == '/api/bot' && request.method == 'POST') {
      final body = jsonDecode(await utf8.decodeStream(request)) as Map<String, Object?>;
      calls.add(body);
      final endpoint = body['endpoint']! as String;
      final payload = (body['payload'] as Map?)?.cast<String, Object?>() ?? const {};
      final handler = handlers[endpoint];
      final Object result = handler == null
          ? {
              'ok': false,
              'error': {'code': 'bot/not-found', 'message': 'Unknown endpoint $endpoint', 'details': {}},
            }
          : {'ok': true, 'value': handler(payload)};
      response.headers.contentType = ContentType.json;
      response.write(jsonEncode(result));
      await response.close();
      return;
    }
    response.statusCode = 404;
    await response.close();
  }
}

String sse(String event, Object data) => 'event: $event\ndata: ${jsonEncode(data)}\n\n';

void main() {
  late FakeDsBot host;
  late DsBotApi api;

  setUp(() async {
    host = await FakeDsBot.start();
    final connection = DshConnection(
      host.baseUri,
      cookie: DshCookie(name: 'dsh-auth-test', value: 'v1.payload.sig', authority: '127.0.0.1:${host.port}'),
    );
    api = DsBotApi(DsBotHttpTransport(connection, feedIdle: const Duration(seconds: 5)));
  });
  tearDown(() async {
    await api.close();
    await host.close();
  });

  group('calls', () {
    test('a call posts the endpoint and payload with the cookie and Host, and returns the value', () async {
      host.handlers['hello'] = (payload) {
        expect(payload['api'], [1]);
        expect((payload['client']! as Map)['name'], 'dsh-go');
        return {
          'api': 1,
          'apiMin': 1,
          'apiMax': 1,
          'plugin': {'name': 'ds-bot', 'version': '0.2.0'},
          'capabilities': ['room-chat', 'notices', 'memory-edit'],
          'boot': 'b1',
          'seq': 4,
          'revision': 12,
          'readOnly': null,
          'memory': true,
          'feed': 'api/bot/feed',
          'later': {'ignored': true},
        };
      };
      final hello = await api.hello(version: '1.0.0');
      expect(hello.api, 1);
      expect(hello.compatible, isTrue);
      expect(hello.pluginVersion, '0.2.0');
      expect(hello.supports('memory-edit'), isTrue);
      expect(hello.supports('usage-summary'), isFalse);
      expect((hello.boot, hello.seq, hello.revision, hello.readOnly), ('b1', 4, 12, null));
      expect(host.requests.single['path'], '/api/bot');
      expect(host.requests.single['host'], '127.0.0.1:${host.port}');
      expect(host.calls.single['endpoint'], 'hello');
    });

    test('a refusal is a DshRemoteException with the bot code; a missing plugin is a 404', () async {
      await expectLater(api.hello(), throwsA(isA<DshRemoteException>().having((e) => e.code, 'code', 'bot/not-found')));
      host.installed = false;
      await expectLater(api.state(), throwsA(isA<DshHttpException>().having((e) => e.statusCode, 'status', 404)));
    });

    test('state reads the team, and the live part alone when nothing was saved', () async {
      host.handlers['state'] = (payload) {
        expect(payload['avatars'], 'ref');
        if (payload['since'] == 7) {
          return {
            'revision': 7,
            'unchanged': true,
            'activity': {'m1': 'thinking'},
            'work': {
              'bots': {
                'm1': {'since': 1000, 'tool': 'bash', 'note': 'Run the tests'},
              },
              'rooms': {
                'r1': [
                  {'botId': 'b2', 'since': 1000, 'speaking': true},
                ],
              },
              'approvals': [
                {'id': 'a1', 'sessionId': 'g2', 'botId': 'b2', 'roomId': 'r1', 'tool': 'bash', 'answerable': true},
              ],
            },
          };
        }
        return {
          'revision': 7,
          'mainBotIds': ['m1'],
          'bots': [
            {
              'id': 'm1',
              'name': 'Chief',
              'role': 'Chief of Staff',
              'color': 'deepseek',
              'avatar': {'shape': 'whale'},
              'sessionId': 'm1c',
              'parts': ['m1'],
              'model': 'deepseek/v4',
            },
            {
              'id': 'b2',
              'name': 'Writer',
              'avatar': {'imageRef': '0123456789abcdef'},
              'waiting': true,
            },
          ],
          'rooms': [
            {
              'id': 'r1',
              'name': 'Launch',
              'members': ['m1', 'b2'],
              'admin': 'm1',
              'mode': 'admin',
              'preview': 'Writer：draft ready',
            },
          ],
          'questions': {
            'm1c': {
              'id': 'q1',
              'question': 'Ship it?',
              'options': [
                {'label': 'Yes'},
                {'label': 'No', 'description': 'wait'},
              ],
            },
          },
          'models': [
            {'ref': 'deepseek/v4', 'name': 'V4', 'providerName': 'DeepSeek'},
          ],
          'defaultModel': 'deepseek/v4',
          'modelsKey': 'k',
          'work': <String, Object?>{},
        };
      };
      final full = await api.state();
      final team = full.team!;
      expect(team.revision, 7);
      expect(team.isMain('m1'), isTrue);
      final chief = team.bot('m1')!;
      expect((chief.sessionId, chief.ink, chief.modelRef, chief.shape), ('m1c', 'deepseek', 'deepseek/v4', 'whale'));
      final writer = team.bot('b2')!;
      expect(writer.sessionId, 'b2');
      expect(writer.waiting, isTrue);
      expect(writer.imageRef, '0123456789abcdef');
      expect(writer.ink, dsBotDefaultColor('b2'));
      expect(team.botOfSession('m1')?.id, 'm1');
      expect(team.room('r1')!.adminFirst, isTrue);
      expect(team.questionOf(chief)!.options.map((o) => o.label), ['Yes', 'No']);
      expect(team.models.single.ref, 'deepseek/v4');

      final quiet = await api.state(since: 7);
      expect(quiet.team, isNull);
      expect(quiet.live.activity['m1'], 'thinking');
      expect(quiet.live.bots['m1']!.tool, 'bash');
      expect(quiet.live.bots['m1']!.note, 'Run the tests');
      expect(quiet.live.rooms['r1']!.single.speaking, isTrue);
      expect(quiet.live.approvals.single.answerable, isTrue);
    });

    test('pages, notices, memory and usage parse what the host sends', () async {
      host.handlers['room-chat'] = (payload) => {
        'roomId': payload['roomId'],
        'items': [
          {'id': '1', 'kind': 'user', 'text': 'Plan it', 'time': 1},
          {
            'id': 'c:0',
            'kind': 'bot',
            'botId': 'm1',
            'name': 'Chief',
            'text': '@Writer go',
            'time': 2,
            'duration': 1500,
          },
          {'id': 'c:1', 'kind': 'event', 'event': 'working', 'botId': 'b2', 'name': 'Writer', 'time': 3, 'live': true},
          {'id': 'c:2', 'kind': 'hologram', 'text': '?'},
        ],
        'cursor': {'beforeSeq': 1},
        'running': true,
        'speaking': 'b2',
      };
      final page = await api.roomChat('r1');
      expect(page.items.map((i) => i.kind), [
        DsBotItemKind.user,
        DsBotItemKind.bot,
        DsBotItemKind.event,
        DsBotItemKind.unknown,
      ]);
      expect(page.items[1].duration, const Duration(milliseconds: 1500));
      expect(page.items[2].live, isTrue);
      expect(page.cursor, {'beforeSeq': 1});
      expect((page.running, page.speaking), (true, 'b2'));
      await api.roomChat('r1', cursor: page.cursor);
      expect(host.calls.last['payload'], {
        'roomId': 'r1',
        'cursor': {'beforeSeq': 1},
      });

      host.handlers['notices'] = (payload) => {
        'boot': 'b1',
        'seq': 9,
        'reset': payload['boot'] != 'b1',
        'notices': [
          {
            'seq': 9,
            'kind': 'group',
            'botId': 'b2',
            'name': 'Writer',
            'roomId': 'r1',
            'title': 'Launch',
            'text': 'done',
          },
        ],
      };
      final notices = await api.notices(boot: 'b1', since: 8);
      expect(notices.reset, isFalse);
      expect(notices.notices.single.conversationId, 'r1');
      expect((await api.notices()).reset, isTrue);

      host.handlers['memory-edit'] = (payload) {
        expect(payload, {'botId': 'b2', 'scope': 'own', 'topic': null, 'text': 'old', 'next': 'new'});
        return {
          'entries': [
            {'scope': 'own', 'topic': null, 'text': 'new', 'added': '2026-10-24', 'by': 'user'},
          ],
          'summary': {'text': 'Likes short drafts', 'at': 1},
        };
      };
      final memory = await api.editMemory(
        const DsBotMemoryEntry(scope: 'own', text: 'old'),
        'new',
        botId: 'b2',
      );
      expect(memory.entries.single.text, 'new');
      expect(memory.summary, 'Likes short drafts');

      host.handlers['usage-summary'] = (payload) => {
        'botId': payload['botId'],
        'day': {'input': 100, 'cacheRead': 0, 'cacheWrite': 0, 'output': 10, 'calls': 1},
        'week': {'input': 300, 'cacheRead': 50, 'cacheWrite': 10, 'output': 30, 'calls': 3},
        'month': {'input': 300, 'cacheRead': 50, 'cacheWrite': 10, 'output': 30, 'calls': 3},
        'models': [
          {'key': 'deepseek/v4', 'name': 'V4', 'input': 100, 'output': 10, 'calls': 1},
        ],
      };
      final usage = await api.usageSummary('b2', timeZone: 'Asia/Shanghai');
      expect(usage.day.total, 110);
      expect(usage.week.total, 390);
      expect(usage.models.single.name, 'V4');
      expect(host.calls.last['payload'], {'botId': 'b2', 'timeZone': 'Asia/Shanghai'});
    });

    test('actions send the shapes the plugin takes', () async {
      for (final name in [
        'send',
        'update-bot',
        'create-room',
        'approval-answer',
        'answer-question',
        'stop-member-work',
      ]) {
        host.handlers[name] = (payload) =>
            name == 'create-room' ? {'id': 'r9', 'name': 'New', 'members': payload['members']} : true;
      }
      await api.send('r1', '@Writer hi');
      expect(host.calls.last['payload'], {'sessionId': 'r1', 'text': '@Writer hi'});
      await api.updateBot('b2', model: 'deepseek/v4', effort: 'high');
      expect(host.calls.last['payload'], {'id': 'b2', 'model': 'deepseek/v4', 'effort': 'high'});
      final room = await api.createRoom(members: ['m1', 'b2'], admin: 'm1');
      expect(room.members, ['m1', 'b2']);
      await api.answerApproval('a1', allow: false);
      expect(host.calls.last['payload'], {'id': 'a1', 'choice': 'reject'});
      await api.answerQuestion(
        const DsBot(id: 'm1', name: 'Chief', sessionId: 'm1c'),
        const DsBotQuestion(id: 'q1', question: 'Ship it?'),
        selected: ['Yes'],
      );
      expect(host.calls.last['payload'], {
        'sessionId': 'm1c',
        'questionId': 'q1',
        'answer': {
          'selected': ['Yes'],
        },
      });
      expect(await api.stopMemberWork('r1', 'b2'), isTrue);
    });
  });

  group('feed', () {
    test('events arrive parsed; comments and unknown events are skipped or passed on as such', () async {
      host.holdFeed = true;
      host.feeds.add([
        sse('hello', {'revision': 3, 'api': 1, 'boot': 'b1', 'seq': 2}),
        ': keepalive\n\n',
        sse('notice', {'seq': 3, 'kind': 'message', 'botId': 'm1', 'name': 'Chief', 'sessionId': 'm1c', 'text': 'Hi'}),
        // One event split across writes.
        'event: room\nda',
        'ta: {"roomId":"r1"}\n\n',
        sse('stream', {'botId': 'm1', 'sessionId': 'm1c', 'attemptId': 'a1', 'text': '你好'}),
        sse('message', {
          'botId': 'm1',
          'sessionId': 'm1c',
          'item': {'kind': 'bot', 'text': '你好', 'time': 5},
        }),
        sse('later-kind', {'x': 1}),
        sse('live', {}),
      ]);
      final feed = api.feed();
      final events = <DsBotFeedEvent>[];
      final done = Completer<void>();
      final sub = feed.events.listen((event) {
        events.add(event);
        if (event is DsBotFeedLive) done.complete();
      });
      feed.start();
      await done.future.timeout(const Duration(seconds: 5));
      await sub.cancel();
      await feed.close();
      expect(events.map((e) => e.runtimeType), [
        DsBotFeedHello,
        DsBotFeedNotice,
        DsBotFeedRoom,
        DsBotFeedStream,
        DsBotFeedMessage,
        DsBotFeedOther,
        DsBotFeedLive,
      ]);
      final hello = events.first as DsBotFeedHello;
      expect((hello.revision, hello.api, hello.boot, hello.seq), (3, 1, 'b1', 2));
      expect((events[1] as DsBotFeedNotice).notice.text, 'Hi');
      expect((events[2] as DsBotFeedRoom).roomId, 'r1');
      expect((events[3] as DsBotFeedStream).text, '你好');
      expect((events[4] as DsBotFeedMessage).item.kind, DsBotItemKind.bot);
      expect(host.requests.first['accept'], 'text/event-stream');
    });

    test('a dropped feed reports the loss and reconnects with a fresh hello', () async {
      host.holdFeed = true;
      host.feeds
        ..add([
          sse('hello', {'revision': 1, 'api': 1, 'boot': 'b1', 'seq': 0}),
        ])
        ..add([
          sse('hello', {'revision': 2, 'api': 1, 'boot': 'b2', 'seq': 0}),
        ]);
      final feed = DsBotFeed(api.transport, backoff: const [Duration(milliseconds: 10)]);
      final events = <DsBotFeedEvent>[];
      final second = Completer<void>();
      final sub = feed.events.listen((event) {
        events.add(event);
        if (event is DsBotFeedHello && event.boot == 'b2') second.complete();
      });
      feed.start();
      while (!feed.connected) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      await host.dropFeeds();
      await second.future.timeout(const Duration(seconds: 5));
      expect(feed.connected, isTrue);
      await sub.cancel();
      await feed.close();
      expect(events.map((e) => e.runtimeType), [DsBotFeedHello, DsBotFeedLost, DsBotFeedHello]);
    });

    test('a feed without the plugin keeps retrying quietly', () async {
      host.installed = false;
      final feed = DsBotFeed(api.transport, backoff: const [Duration(milliseconds: 10)]);
      final events = <DsBotFeedEvent>[];
      final sub = feed.events.listen(events.add);
      feed.start();
      await Future<void>.delayed(const Duration(milliseconds: 120));
      await sub.cancel();
      await feed.close();
      expect(host.requests.length, greaterThan(2));
      expect(events.whereType<DsBotFeedLost>().first.error, isA<DshHttpException>());
      expect(events.whereType<DsBotFeedHello>(), isEmpty);
    });
  });

  test('SseParser follows the event-stream rules', () {
    final parser = SseParser();
    expect(parser.add(': comment'), isNull);
    expect(parser.add('event: notice'), isNull);
    expect(parser.add('data: {"a":'), isNull);
    expect(parser.add('data: 1}'), isNull);
    final event = parser.add('')!;
    expect(event.event, 'notice');
    // Multi-line data joins with a newline, which JSON allows between tokens.
    expect(event.data, {'a': 1});
    expect(parser.add(''), isNull);
    expect(parser.add('data:plain'), isNull);
    final plain = parser.add('')!;
    expect(plain.event, 'message');
    expect(plain.data, isNull);
  });

  test('a Bot without a color gets the one DS Bot picks from its id', () {
    // Values from DS Bot's own `defaultColor` / `fnv1a` (src/client/characters.js) in Node.
    const expected = {
      's1': ('blue', 139573449),
      's2': ('green', 89240592),
      'm1': ('magenta', 2486071275),
      'b2': ('cyan', 2402036085),
      '01JB7Q8XYZ': ('green', 1701597717),
      '019a1b2c-3d4e-7f80-9abc-def012345678': ('cyan', 2794792167),
      '会话': ('blue', 861184368),
      '🐳x': ('cyan', 2621675451),
    };
    for (final MapEntry(key: id, value: (color, hash)) in expected.entries) {
      expect(dsBotFnv1a(id), hash, reason: id);
      expect(dsBotDefaultColor(id), color, reason: id);
    }
    expect(dsBotInkArgb('deepseek', dark: false), 0xFF4D6BFE);
    expect(dsBotInkArgb('kimi', dark: true), 0xFFF1F2F4);
    expect(dsBotInkArgb('#123456', dark: true), 0xFF123456);
    expect(dsBotIsColor('qwen'), isTrue);
    expect(dsBotIsColor('plaid'), isFalse);
  });

  group('over Remote methods (a relay)', () {
    late _RelayCarrier relay;
    late DshClient client;

    setUp(() async {
      relay = _RelayCarrier();
      client = await DshClient.connectCarrier(relay, muxOptions: _fastMux);
    });
    tearDown(() => client.close());

    test('a relay that forwards dsBot/call and dsBot/feed gets the RPC transport', () async {
      relay.allowed = {r'$events', r'$events/result'};
      expect(DsBotApi.of(client), isNull);
      relay.allowed = null;
      final api = DsBotApi.of(client)!;
      expect(api.transport, isA<DsBotRpcTransport>());

      relay.handlers['dsBot/call'] = (args) {
        final endpoint = args['endpoint'];
        if (endpoint == 'hello') {
          return const RpcOk({
            'ok': true,
            'value': {
              'api': 1,
              'apiMin': 1,
              'apiMax': 1,
              'boot': 'b',
              'seq': 0,
              'revision': 1,
              'capabilities': ['rpc'],
            },
          });
        }
        return const RpcOk({
          'ok': false,
          'error': {'code': 'bot/read-only', 'message': 'held'},
        });
      };
      final hello = await api.hello();
      expect((hello.api, hello.supports('rpc')), (1, true));
      expect(relay.calls.last.$2['endpoint'], 'hello');
      expect((relay.calls.last.$2['payload']! as Map)['api'], [1]);
      await expectLater(
        api.send('m1', 'hi'),
        throwsA(isA<DshRemoteException>().having((e) => e.code, 'code', 'bot/read-only')),
      );
    });

    test('a host whose DS Bot has no Remote methods reads as missing', () async {
      relay.handlers.remove('dsBot/call');
      final api = DsBotApi(DsBotRpcTransport(client));
      await expectLater(api.hello(), throwsA(isA<DshHttpException>().having((e) => e.statusCode, 'status', 404)));
    });

    test('the feed stream delivers the same events, and the feed reopens it after a drop', () async {
      final opened = <String>[];
      relay.onOpen = (link, streamId, endpoint, payload) {
        opened.add(endpoint);
        scheduleMicrotask(() {
          link.item(streamId, {
            'event': 'hello',
            'data': {'revision': 3, 'api': 1, 'boot': 'b', 'seq': opened.length},
          });
          link.item(streamId, {
            'event': 'notice',
            'data': {'seq': 1, 'kind': 'group', 'botId': 'b2', 'roomId': 'r1', 'text': '2'},
          });
        });
      };
      final feed = DsBotApi(DsBotRpcTransport(client)).feed(backoff: const [Duration(milliseconds: 10)]);
      final events = <DsBotFeedEvent>[];
      final second = Completer<void>();
      final sub = feed.events.listen((event) {
        events.add(event);
        if (event is DsBotFeedHello && event.seq == 2) second.complete();
      });
      feed.start();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      relay.links.last.end(relay.lastStream!);
      await second.future.timeout(const Duration(seconds: 5));
      await sub.cancel();
      await feed.close();
      expect(opened, ['dsBot/feed', 'dsBot/feed']);
      expect(events.map((e) => e.runtimeType).take(4), [
        DsBotFeedHello,
        DsBotFeedNotice,
        DsBotFeedLost,
        DsBotFeedHello,
      ]);
      expect((events[1] as DsBotFeedNotice).notice.roomId, 'r1');
    });
  });

  test('a client on the HTTP carrier uses the route', () {
    final local = DshClient(DshConnection(host.baseUri));
    expect(DsBotApi.of(local)!.transport, isA<DsBotHttpTransport>());
  });
}

const _fastMux = MuxOptions(readyTimeout: Duration(seconds: 2), retryCaps: [Duration(milliseconds: 10)]);

/// A relay-like carrier in memory: an allow-list, unary calls by endpoint,
/// one link at a time.
class _RelayCarrier extends DshCarrier {
  final Map<String, RpcResult Function(Map<String, Object?> args)> handlers = {};
  final List<(String, Map<String, Object?>)> calls = [];
  final List<_RelayLink> links = [];
  Set<String>? allowed;
  String? lastStream;
  void Function(_RelayLink link, String streamId, String endpoint, Map<String, Object?> payload)? onOpen;

  @override
  String get kind => 'remote-relay';

  @override
  DshTracer? get tracer => null;

  @override
  bool get supportsUplink => false;

  @override
  bool allowsEndpoint(String endpoint) => allowed?.contains(endpoint) ?? true;

  @override
  Future<RpcResult> call(String endpoint, Map<String, Object?> args, {Duration? timeout}) async {
    calls.add((endpoint, args));
    final handler = handlers[endpoint];
    if (handler == null) {
      return RpcError(
        DshRemoteException('gateway/invocation-unavailable', 'no active Remote method exports $endpoint'),
      );
    }
    return handler(args);
  }

  @override
  Future<DshMuxLink> openLink(MuxOptions options) async {
    final link = _RelayLink(this);
    links.add(link);
    return link;
  }

  @override
  Future<void> close() async {}
}

class _RelayLink implements DshMuxLink {
  _RelayLink(this.carrier);

  final _RelayCarrier carrier;
  late DshMuxFrameHandler onFrame;

  void item(String streamId, Object? value) => onFrame({'type': 'item', 'streamId': streamId, 'value': value});
  void end(String streamId) => onFrame({'type': 'end', 'streamId': streamId});

  @override
  void start({required DshMuxFrameHandler onFrame, required DshMuxLossHandler onLost}) => this.onFrame = onFrame;

  @override
  void open(String streamId, String endpoint, Map<String, Object?> payload) {
    if (endpoint == r'$events') {
      scheduleMicrotask(
        () => item(streamId, {
          'type': 'ready',
          'clientId': 'relay-1',
          'host': {'home': '/h'},
        }),
      );
      return;
    }
    carrier.lastStream = streamId;
    carrier.onOpen?.call(this, streamId, endpoint, payload);
  }

  @override
  void sendItem(String streamId, Object? value) {}

  @override
  void endUplink(String streamId) {}

  @override
  void cancel(String streamId) {}

  @override
  Future<void> close(int code, String reason) async {}
}

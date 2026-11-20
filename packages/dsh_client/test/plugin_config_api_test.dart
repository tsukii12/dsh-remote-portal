// The dsh-go bridge's plugin-config routes (PLUGIN-CONFIG-CONTRACT R1 §4)
// against a fake Host over real HTTP: the list (and its absence), one entry
// with the live marker, secret facts and an opaque revision, a write, and
// every refusal: 400 invalid-operation, 404 entry-unavailable, 409 conflict /
// overridden / apply-failed, 422 invalid-config with a field path, 503
// host-unavailable, 500 recovery-failed, a code-less status, a malformed body.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_client/dsh_client.dart';
import 'package:test/test.dart';

Map<String, Object?> _entry({String revision = 'r1', Map<String, Object?> user = const {}}) => {
  'v': 1,
  'entryId': 'speech-to-text-sensevoice',
  'revision': revision,
  'schema': {
    'uid': 1,
    'refs': {
      '1': {
        'type': 'object',
        'dict': {'language': 2, 'threads': 3, 'apiKey': 4, 'token': 5},
        'meta': {},
      },
      '2': {
        'type': 'string',
        'meta': {'volatile': true, 'default': 'auto'},
      },
      '3': {
        'type': 'number',
        'meta': {'default': 2},
      },
      '4': {
        'type': 'string',
        'meta': {'role': 'secret'},
      },
      '5': {
        'type': 'string',
        'meta': {'role': 'secret'},
      },
    },
  },
  'value': {'language': 'auto', 'threads': 2, ...user},
  'base': {'language': 'auto', 'threads': 2},
  'user': user,
  'secrets': [
    {'path': ['apiKey'], 'configured': true, 'credentialRef': 'SENSEVOICE_KEY', 'writable': true},
    {'path': ['token'], 'configured': false},
  ],
  'writable': true,
};

class _Bridge {
  _Bridge._(this._server);

  static const token = 'launch-token';
  static const cookie = 'dsh-auth-k1';

  static Future<_Bridge> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final bridge = _Bridge._(server);
    server.listen((request) => unawaited(bridge._handle(request)));
    return bridge;
  }

  final HttpServer _server;
  Uri get baseUri => Uri.parse('http://127.0.0.1:${_server.port}');

  /// The list; null answers 404 without a code (no such routes).
  Object? list = {
    'v': 1,
    'entries': [
      {'entryId': 'speech-to-text-sensevoice', 'package': '@deepseek-ai/dsh-experimental-speech-to-text-sensevoice', 'label': {'zh': '本机语音识别', 'en': 'On-device recognition'}, 'state': 'active', 'configurable': true},
      {'entryId': 'nested', 'state': 'unsupported', 'configurable': false, 'reason': 'nested-include'},
      {'state': 'active'},
    ],
  };
  Map<String, Object?> entry = _entry();

  /// The list answers this instead: (status, body).
  (int, Object?)? listRefusal;

  /// Next answer instead of [entry]: (status, body).
  (int, Object?)? refuse;
  Duration delay = Duration.zero;
  final requests = <(String, String, Object?)>[];

  Future<void> close() => _server.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    final path = request.uri.path;
    if (path == '/' && request.uri.queryParameters['token'] == token) {
      response
        ..statusCode = 303
        ..headers.set('location', './')
        ..headers.add('set-cookie', '$cookie=v1.sig; Path=/; HttpOnly');
      await response.close();
      return;
    }
    if (!(request.headers.value(HttpHeaders.cookieHeader)?.contains('$cookie=v1.sig') ?? false)) {
      response.statusCode = 401;
      await response.close();
      return;
    }
    final body = request.method == 'POST' ? jsonDecode(await utf8.decodeStream(request)) : null;
    requests.add((request.method, request.uri.toString(), body));
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    void json(int status, Object? payload) {
      response.statusCode = status;
      response.headers.contentType = ContentType.json;
      response.write(jsonEncode(payload));
    }

    if (path == dshGoPluginConfigPath) {
      if (listRefusal case (final status, final payload)) {
        json(status, payload);
      } else if (list == null) {
        response.statusCode = 404;
      } else {
        json(200, list);
      }
    } else if (path.startsWith('$dshGoPluginConfigPath/')) {
      if (refuse case (final status, final payload)) {
        refuse = null;
        if (payload == null) {
          response.statusCode = status;
        } else if (payload is String) {
          response.statusCode = status;
          response.write(payload);
        } else {
          json(status, payload);
        }
      } else {
        json(200, entry);
      }
    } else {
      response.statusCode = 404;
    }
    await response.close();
  }
}

Map<String, Object?> _error(String code, [List<String>? path]) => {
  'error': {'code': code, 'message': 'refused', 'path': ?path},
};

void main() {
  late _Bridge bridge;
  late DshClient client;

  setUp(() async {
    bridge = await _Bridge.start();
    client = await DshClient.connect(baseUri: bridge.baseUri, token: _Bridge.token, startMux: false);
  });

  tearDown(() async {
    await client.close();
    await bridge.close();
  });

  test('the list: entries with why one cannot be edited; no routes reads null', () async {
    final entries = (await client.listPluginConfig())!;
    expect(entries.map((e) => e.entryId), ['speech-to-text-sensevoice', 'nested'], reason: 'an entry without id is dropped');
    expect(entries.first.configurable, isTrue);
    expect(entries.first.label!.resolve('en'), 'On-device recognition');
    expect(entries.last.reason, 'nested-include');
    expect(entries.last.state, 'unsupported');

    bridge.list = [
      {'entryId': 'a', 'configurable': true},
    ];
    expect((await client.listPluginConfig())!.single.entryId, 'a', reason: 'a bare list is read too');

    bridge.list = null;
    expect(await client.listPluginConfig(), isNull);
  });

  test('bridge R7: who carries each entry and whether a write would be taken; older: unsaid', () async {
    bridge.list = {
      'v': 1,
      'entries': [
        // As an r14 Host lists them (app/test/plugin_config/fixtures/bridge_catalog_r14.json).
        {
          'entryId': 'speech-to-text-sensevoice',
          'package': '@deepseek-ai/dsh-experimental-speech-to-text-sensevoice',
          'owner': 'optional',
          'bundle': '@deepseek-ai/dsh-experimental-voice-input-bundle',
          'kind': 'plugin',
          'source': 'official-optional-bundle',
          'label': {'en': 'Voice input', 'zh': '语音输入'},
          'state': 'active',
          'configurable': true,
          'writable': false,
          'reason': 'overridden',
        },
        {
          'entryId': 'dsh-app-phone',
          'package': '@deepseek-ai/dsh-mcp-client',
          'owner': 'overlay',
          'bundle': null,
          'kind': 'overlay',
          'source': 'unverified',
          'label': 'dsh-app-phone',
          'state': 'unsupported',
          'configurable': false,
          'writable': false,
          'reason': 'entry-unavailable',
        },
        {'entryId': 'older', 'configurable': true, 'writable': 'yes'},
      ],
    };
    final [voice, phone, older] = (await client.listPluginConfig())!;
    expect(
      (voice.owner, voice.bundle, voice.kind, voice.source, voice.writable, voice.reason),
      (
        'optional',
        '@deepseek-ai/dsh-experimental-voice-input-bundle',
        'plugin',
        'official-optional-bundle',
        false,
        'overridden',
      ),
    );
    expect(voice.label!.resolve('zh'), '语音输入', reason: 'the bundle title');
    expect((phone.owner, phone.bundle, phone.kind, phone.writable), ('overlay', null, 'overlay', false));
    expect((older.owner, older.bundle, older.kind, older.source, older.writable), (null, null, null, null, null));
  });

  test('a carrier that cannot reach the bridge (the relay) reads null', () async {
    final relayLike = DshClient.withCarrier(_RpcOnly());
    expect(await relayLike.listPluginConfig(), isNull);
  });

  test('one entry: schema with the live marker, layers, secret facts, opaque revision', () async {
    final detail = await client.readPluginConfig('speech-to-text-sensevoice');
    expect(detail.revision, 'r1');
    expect(detail.schema.fields!['language']!.meta.volatile, isTrue);
    expect(detail.schema.fields!['threads']!.meta.volatile, isFalse);
    expect(detail.secrets.first.credentialRef, 'SENSEVOICE_KEY');
    expect(detail.secrets.first.writable, isTrue);
    expect(detail.secrets.last.credentialRef, isNull);
    expect(detail.secrets.last.writable, isFalse, reason: 'a bare secret is not written in v1');
    final view = detail.view;
    expect(view.ns, 'speech-to-text-sensevoice');
    expect(view.secrets.map((s) => s.set), [true, false]);
    expect(view.value.containsKey('apiKey'), isFalse);
  });

  test('an entry id with a slash or a space is one path segment', () async {
    await client.readPluginConfig('a/b c');
    expect(bridge.requests.last.$2, '$dshGoPluginConfigPath/a%2Fb%20c');
  });

  test('a write sends the revision as read and the path ops; the answer is the new entry', () async {
    bridge.entry = _entry(revision: 'r2', user: {'threads': 4});
    final detail = await client.writePluginConfig(
      'speech-to-text-sensevoice',
      revision: 'r1',
      ops: const [SettingsOp.set(['threads'], 4), SettingsOp.unset(['language'])],
    );
    expect(bridge.requests.last.$1, 'POST');
    expect(bridge.requests.last.$3, {
      'revision': 'r1',
      'ops': [
        {'op': 'set', 'path': ['threads'], 'value': 4},
        {'op': 'unset', 'path': ['language']},
      ],
    });
    expect(detail.revision, 'r2');
    expect(detail.user, {'threads': 4});
  });

  group('refusals carry their code', () {
    Future<DshRemoteException> refusal(int status, Object? body) async {
      bridge.refuse = (status, body);
      try {
        await client.writePluginConfig('x', revision: 'r1', ops: const [SettingsOp.unset(['a'])]);
      } on DshRemoteException catch (error) {
        return error;
      }
      fail('no refusal');
    }

    for (final (status, code) in [
      (400, 'invalid-operation'),
      (404, 'entry-unavailable'),
      (409, 'conflict'),
      (409, 'overridden'),
      (409, 'apply-failed'),
      (422, 'invalid-config'),
      (503, 'host-unavailable'),
      (500, 'recovery-failed'),
    ]) {
      test('$status $code', () async {
        final error = await refusal(status, _error(code));
        expect(error.code, 'plugin-config/$code');
        expect(error.details['status'], status);
      });
    }

    test('422 names the field', () async {
      final error = await refusal(422, _error('invalid-config', ['vad', 'threshold']));
      expect(error.details['path'], ['vad', 'threshold']);
    });

    test('a code at the top level is read too', () async {
      final error = await refusal(409, {'code': 'conflict', 'message': 'stale'});
      expect(error.code, 'plugin-config/conflict');
    });

    test('a status without a code', () async {
      expect((await refusal(502, null)).code, 'plugin-config/http-502');
      expect((await refusal(500, 'oops')).code, 'plugin-config/http-500');
    });

    test('an entry read refused the same way', () async {
      bridge.refuse = (404, _error('entry-unavailable'));
      await expectLater(
        client.readPluginConfig('gone'),
        throwsA(isA<DshRemoteException>().having((e) => e.code, 'code', 'plugin-config/entry-unavailable')),
      );
    });

    test('a list refused with a code is not "no routes"', () async {
      bridge.listRefusal = (503, _error('host-unavailable'));
      await expectLater(
        client.listPluginConfig(),
        throwsA(isA<DshRemoteException>().having((e) => e.code, 'code', 'plugin-config/host-unavailable')),
      );
      bridge.listRefusal = (404, _error('entry-unavailable'));
      await expectLater(client.listPluginConfig(), throwsA(isA<DshRemoteException>()));
    });
  });

  test('a body that is not an entry is a protocol error', () async {
    bridge.refuse = (200, {'v': 2, 'entryId': 'x'});
    await expectLater(client.readPluginConfig('x'), throwsA(isA<DshProtocolException>()));
    bridge.refuse = (200, {'v': 1, 'entryId': 'x', 'revision': 3, 'schema': {}});
    await expectLater(client.readPluginConfig('x'), throwsA(isA<DshProtocolException>()), reason: 'revision is a token');
  });

  test('a write that outlives its deadline throws a transport error (outcome unknown)', () async {
    bridge.delay = const Duration(milliseconds: 400);
    await expectLater(
      client.writePluginConfig(
        'x',
        revision: 'r1',
        ops: const [SettingsOp.unset(['a'])],
        timeout: const Duration(milliseconds: 50),
      ),
      throwsA(isNot(isA<DshRemoteException>())),
    );
  });
}

/// A carrier with RPC only (the relay's shape).
class _RpcOnly extends DshCarrier {
  @override
  String get kind => 'relay';

  @override
  DshTracer? get tracer => null;

  @override
  Future<RpcResult> call(String endpoint, Map<String, Object?> args, {Duration? timeout}) async =>
      RpcError(DshRemoteException('gateway/method-not-found', endpoint));

  @override
  Future<DshMuxLink> openLink(MuxOptions options) => throw UnimplementedError();

  @override
  Future<void> close() async {}
}

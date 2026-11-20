import 'dart:convert';
import 'dart:io';

import 'package:dsh_client/dsh_client.dart';
import 'package:test/test.dart';

const _path = '/dsh-go/v1/companion/recall';
const _store = '10000000-0000-4000-8000-000000000001';
const _bindingId = '20000000-0000-4000-8000-000000000002';
const _epoch = '30000000-0000-4000-8000-000000000003';
const _operation = '40000000-0000-4000-8000-000000000004';
const _consumer = '50000000-0000-4000-8000-000000000005';
const _session = 'actual-session';

class _RecallHost {
  _RecallHost._(this._server) {
    _server.listen((request) async {
      if (request.uri.path == '/' && request.uri.queryParameters['token'] == 't') {
        request.response
          ..statusCode = 303
          ..headers.set('location', './')
          ..headers.add('set-cookie', 'dsh-auth-k1=v1.sig; Path=/; HttpOnly');
        await request.response.close();
        return;
      }
      paths.add(request.uri.path);
      methods.add(request.method);
      cookies.add(request.headers.value(HttpHeaders.cookieHeader));
      final text = await utf8.decoder.bind(request).join();
      bodies.add(text.isEmpty ? null : jsonDecode(text) as Map<String, Object?>);
      await answer(request);
    });
  }

  static Future<_RecallHost> start() async => _RecallHost._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
  final HttpServer _server;
  final paths = <String>[];
  final methods = <String>[];
  final cookies = <String?>[];
  final bodies = <Map<String, Object?>?>[];
  Future<void> Function(HttpRequest) answer = (request) => _reply(request, _capabilities());
  Uri get baseUri => Uri.parse('http://127.0.0.1:${_server.port}');
  Future<void> close() => _server.close(force: true);
}

Map<String, Object?> _capabilities({bool supported = true, bool busy = false}) => {
  'v': 1,
  'supported': supported,
  'reason': supported ? null : 'provider-unsupported',
  'selectorVersion': companionRecallSelector,
  'maxItems': 12,
  'textUtf16Budget': 1200,
  'busy': busy,
  'activeBindingId': busy ? _bindingId : null,
};

Map<String, Object?> _binding({String status = 'ready', String sessionId = _session, int memoryRevision = 7}) => {
  'v': 1,
  'bindingId': _bindingId,
  'bridgeEpoch': _epoch,
  'recallEpoch': 1,
  'storeId': _store,
  'memoryRevision': memoryRevision,
  'sessionId': sessionId,
  'status': status,
  'selectorVersion': companionRecallSelector,
  'reason': status == 'ready' ? null : 'user-off',
  'serverNow': 1794090000000,
};

Future<void> _reply(HttpRequest request, Object? value, {int status = 200}) async {
  request.response
    ..statusCode = status
    ..headers.contentType = ContentType.json
    ..write(jsonEncode(value));
  await request.response.close();
}

Future<CompanionRecallBinding> _bind(
  DshClient client,
  CompanionRecallCapabilities host, {
  String operationId = _operation,
  String storeId = _store,
  int expectedMemoryRevision = 7,
  String sessionId = _session,
  String consumerId = _consumer,
  String consent = companionRecallSelector,
}) => client.bindCompanionRecall(
  host,
  operationId: operationId,
  storeId: storeId,
  expectedMemoryRevision: expectedMemoryRevision,
  sessionId: sessionId,
  consumerId: consumerId,
  consent: consent,
);

void main() {
  late _RecallHost host;
  late DshClient client;
  setUp(() async {
    host = await _RecallHost.start();
    client = await DshClient.connect(baseUri: host.baseUri, token: 't', startMux: false);
  });
  tearDown(() async {
    await client.close();
    await host.close();
  });

  test('authenticated capability, explicit bind, status and explicit revoke use the exact protocol', () async {
    final capabilities = (await client.readCompanionRecallCapabilities())!;
    expect(capabilities.supported, isTrue);
    expect(capabilities.busy, isFalse);
    expect(capabilities.maxItems, 12);
    expect(capabilities.textUtf16Budget, 1200);
    expect(host.paths, [_path]);
    host.answer = (request) => _reply(request, _binding());
    final bound = await _bind(client, capabilities);
    expect(bound.isReady, isTrue);
    expect(bound.memoryRevision, 7);
    final status = await client.readCompanionRecallBinding(capabilities, _bindingId);
    expect(status.serverNow, 1794090000000);
    host.answer = (request) => _reply(request, _binding(status: 'retired'));
    final retired = await client.revokeCompanionRecall(capabilities, operationId: _consumer, bindingId: _bindingId);
    expect(retired.isReady, isFalse);
    expect(retired.status, CompanionRecallStatus.retired);
    expect(host.paths, [_path, '$_path/bind', '$_path/bindings/$_bindingId', '$_path/revoke']);
    expect(host.methods, ['GET', 'POST', 'GET', 'POST']);
    expect(host.bodies, [
      null,
      {
        'v': 1,
        'operationId': _operation,
        'storeId': _store,
        'expectedMemoryRevision': 7,
        'sessionId': _session,
        'consumerId': _consumer,
        'consent': companionRecallSelector,
      },
      null,
      {'v': 1, 'operationId': _consumer, 'bindingId': _bindingId, 'reason': 'user-off'},
    ]);
    expect(host.cookies.every((value) => value?.contains('dsh-auth-k1=') == true), isTrue);
  });

  test('busy observation does not revoke or steal; explicit bind exposes one server conflict', () async {
    host.answer = (request) => _reply(request, _capabilities(busy: true));
    final capabilities = (await client.readCompanionRecallCapabilities())!;
    expect(capabilities.activeBindingId, _bindingId);
    expect(host.paths, [_path]);
    host.answer = (request) => _reply(request, {
      'error': {'code': 'companion/recall-binding-busy'},
    }, status: 409);
    await expectLater(
      _bind(client, capabilities),
      throwsA(isA<DshRemoteException>().having((e) => e.code, 'code', 'companion/recall-binding-busy')),
    );
    expect(host.paths, [_path, '$_path/bind']);
  });

  test('unsupported Host cannot bind but status and retirement stay available', () async {
    host.answer = (request) => _reply(request, _capabilities(supported: false, busy: true));
    final capabilities = (await client.readCompanionRecallCapabilities())!;
    await expectLater(_bind(client, capabilities), throwsA(isA<DshRemoteException>()));
    expect(host.paths, [_path]);
    host.answer = (request) => _reply(request, _binding(status: 'unavailable'));
    expect(
      (await client.readCompanionRecallBinding(capabilities, _bindingId)).status,
      CompanionRecallStatus.unavailable,
    );
    host.answer = (request) => _reply(request, _binding(status: 'retired'));
    expect(
      (await client.revokeCompanionRecall(capabilities, operationId: _operation, bindingId: _bindingId)).status,
      CompanionRecallStatus.retired,
    );
  });

  test('capabilities cannot authorize a different client or Host', () async {
    final capabilities = (await client.readCompanionRecallCapabilities())!;
    final otherHost = await _RecallHost.start();
    final other = await DshClient.connect(baseUri: otherHost.baseUri, token: 't', startMux: false);
    try {
      await expectLater(_bind(other, capabilities), throwsArgumentError);
      await expectLater(other.readCompanionRecallBinding(capabilities, _bindingId), throwsArgumentError);
      await expectLater(
        other.revokeCompanionRecall(capabilities, operationId: _operation, bindingId: _bindingId),
        throwsArgumentError,
      );
      expect(otherHost.paths, isEmpty);
    } finally {
      await other.close();
      await otherHost.close();
    }
  });

  test('idempotent replay keeps the operation id and can return a retired binding', () async {
    final capabilities = (await client.readCompanionRecallCapabilities())!;
    host.answer = (request) => _reply(request, _binding(status: 'retired', memoryRevision: 8));
    final result = await _bind(client, capabilities);
    expect(result.isReady, isFalse);
    expect(result.memoryRevision, 8);
    expect(host.bodies.last!['operationId'], _operation);
    expect(host.paths.length, 2);
  });

  for (final entry in <String, Object?>{
    'memoryRevision': 8,
    'storeId': _consumer,
    'sessionId': 'another-session',
  }.entries) {
    test('ready bind cannot acknowledge a different target: ${entry.key}', () async {
      final capabilities = (await client.readCompanionRecallCapabilities())!;
      host.answer = (request) => _reply(request, _binding()..[entry.key] = entry.value);
      await expectLater(_bind(client, capabilities), throwsA(isA<DshProtocolException>()));
    });
  }

  test('session limit is 256 Unicode scalar values, not UTF16 units', () async {
    final capabilities = (await client.readCompanionRecallCapabilities())!;
    final session = '😀' * 256;
    host.answer = (request) => _reply(request, _binding(sessionId: session));
    expect((await _bind(client, capabilities, sessionId: session)).sessionId, session);
    expect(host.bodies.last!['sessionId'], session);
    for (final bad in ['😀' * 257, '', 'x\u0000', '\u0085', String.fromCharCode(0xd800), String.fromCharCode(0xdc00)]) {
      await expectLater(_bind(client, capabilities, sessionId: bad), throwsArgumentError);
    }
    expect(host.paths.length, 2);
  });

  test('malformed UUID, consent and unsafe revision are rejected before POST', () async {
    final capabilities = (await client.readCompanionRecallCapabilities())!;
    for (final id in [
      'A0000000-0000-4000-8000-000000000001',
      'x',
      '$_store\n',
      '10000000-0000-0000-8000-000000000001',
    ]) {
      await expectLater(_bind(client, capabilities, operationId: id), throwsArgumentError);
      await expectLater(_bind(client, capabilities, storeId: id), throwsArgumentError);
      await expectLater(_bind(client, capabilities, consumerId: id), throwsArgumentError);
      await expectLater(client.readCompanionRecallBinding(capabilities, id), throwsArgumentError);
    }
    await expectLater(_bind(client, capabilities, consent: 'automatic'), throwsArgumentError);
    await expectLater(_bind(client, capabilities, expectedMemoryRevision: -1), throwsArgumentError);
    await expectLater(_bind(client, capabilities, expectedMemoryRevision: 9007199254740992), throwsArgumentError);
    expect(host.paths, [_path]);
  });

  test('generated operation ids are distinct canonical UUIDs', () {
    final ids = List.generate(32, (_) => newCompanionRecallId());
    expect(ids.toSet().length, ids.length);
    final pattern = RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$');
    expect(ids.every(pattern.hasMatch), isTrue);
  });

  for (final entry in <String, Object?>{
    'v': 1.0,
    'supported': 1,
    'busy': true,
    'selectorVersion': 'unknown',
    'maxItems': 12.0,
    'textUtf16Budget': 1201,
    'reason': 123,
    'activeBindingId': 'not-a-uuid',
  }.entries) {
    test('malformed capabilities fail closed: ${entry.key}', () async {
      host.answer = (request) => _reply(request, _capabilities()..[entry.key] = entry.value);
      await expectLater(client.readCompanionRecallCapabilities(), throwsA(isA<DshProtocolException>()));
    });
  }

  test('required capability keys cannot disappear as nullable defaults', () async {
    for (final key in ['activeBindingId', 'reason']) {
      host.answer = (request) => _reply(request, _capabilities()..remove(key));
      await expectLater(client.readCompanionRecallCapabilities(), throwsA(isA<DshProtocolException>()));
    }
  });

  for (final entry in <String, Object?>{
    'status': 'enabled',
    'bridgeEpoch': _epoch.toUpperCase().replaceFirst('3', 'A'),
    'recallEpoch': -1,
    'memoryRevision': 7.0,
    'serverNow': null,
    'sessionId': '\u0000',
    'reason': '\u0085',
    'selectorVersion': 'old',
    'bindingId': _consumer,
  }.entries) {
    test('status validates the full binding envelope: ${entry.key}', () async {
      final capabilities = (await client.readCompanionRecallCapabilities())!;
      host.answer = (request) => _reply(request, _binding()..[entry.key] = entry.value);
      await expectLater(
        client.readCompanionRecallBinding(capabilities, _bindingId),
        throwsA(isA<DshProtocolException>()),
      );
    });
  }

  test('revocation must confirm retired for the same binding', () async {
    final capabilities = (await client.readCompanionRecallCapabilities())!;
    for (final body in [
      _binding(),
      _binding(status: 'unavailable'),
      _binding(status: 'retired')..['bindingId'] = _consumer,
    ]) {
      host.answer = (request) => _reply(request, body);
      await expectLater(
        client.revokeCompanionRecall(capabilities, operationId: _operation, bindingId: _bindingId),
        throwsA(isA<DshProtocolException>()),
      );
    }
  });

  for (final code in [null, 'companion/not-found']) {
    test('only unclaimed old capability routes map to unsupported ($code)', () async {
      host.answer = (request) => _reply(
        request,
        code == null
            ? null
            : {
                'error': {'code': code},
              },
        status: 404,
      );
      expect(await client.readCompanionRecallCapabilities(), isNull);
    });
  }

  test('logical binding-not-found and malformed error codes stay errors', () async {
    final capabilities = (await client.readCompanionRecallCapabilities())!;
    for (final code in ['companion/recall-binding-not-found', 42]) {
      host.answer = (request) => _reply(request, {
        'error': {'code': code},
      }, status: 404);
      await expectLater(client.readCompanionRecallCapabilities(), throwsA(isA<DshRemoteException>()));
      await expectLater(
        client.readCompanionRecallBinding(capabilities, _bindingId),
        throwsA(isA<DshRemoteException>()),
      );
    }
  });

  test('GET and POST never follow redirects or retry a refusal', () async {
    final capabilities = (await client.readCompanionRecallCapabilities())!;
    host.answer = (request) async {
      request.response
        ..statusCode = 307
        ..headers.set('location', '/leak');
      await request.response.close();
    };
    await expectLater(
      client.readCompanionRecallCapabilities(),
      throwsA(isA<DshHttpException>().having((e) => e.statusCode, 'status', 307)),
    );
    await expectLater(_bind(client, capabilities), throwsA(isA<DshRemoteException>()));
    expect(host.paths, [_path, _path, '$_path/bind']);
  });

  test('GET and POST response bodies have an independent 16KiB bound', () async {
    final capabilities = (await client.readCompanionRecallCapabilities())!;
    host.answer = (request) => _reply(request, {'oversized': 'x' * 16384});
    await expectLater(client.readCompanionRecallCapabilities(), throwsA(isA<DshProtocolException>()));
    await expectLater(_bind(client, capabilities), throwsA(isA<DshProtocolException>()));
  });

  test('gzip expansion is bounded after decompression', () async {
    host.answer = (request) async {
      request.response.headers
        ..contentType = ContentType.json
        ..set(HttpHeaders.contentEncodingHeader, 'gzip');
      request.response.add(gzip.encode(utf8.encode(jsonEncode({'oversized': 'x' * 32768}))));
      await request.response.close();
    };
    await expectLater(client.readCompanionRecallCapabilities(), throwsA(isA<DshProtocolException>()));
  });

  test('malformed UTF8 cannot be repaired into a valid capability', () async {
    host.answer = (request) async {
      final parts = jsonEncode(_capabilities()..['reason'] = 'BAD_BYTE').split('BAD_BYTE');
      request.response.headers.contentType = ContentType.json;
      request.response.add([...utf8.encode(parts[0]), 0xff, ...utf8.encode(parts[1])]);
      await request.response.close();
    };
    await expectLater(client.readCompanionRecallCapabilities(), throwsA(isA<DshProtocolException>()));
  });
}

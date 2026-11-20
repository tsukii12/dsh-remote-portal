import 'dart:convert';
import 'dart:typed_data';

import 'package:dsh_client/dsh_client.dart';
import 'package:test/test.dart';

import 'support/fake_dsh.dart';

const fastMux = MuxOptions(readyTimeout: Duration(seconds: 2), retryCaps: [Duration(milliseconds: 20)]);

void main() {
  late FakeDsh host;

  setUp(() async => host = await FakeDsh.start());
  tearDown(() async => host.close());

  Future<DshClient> connect() =>
      DshClient.connect(baseUri: host.baseUri, token: FakeDsh.token, muxOptions: fastMux, startMux: false);

  Map<String, Object?> staged(String receiptId, String? name, int bytes) => {
    'ok': true,
    'value': {
      'receiptId': receiptId,
      'file': {'attachmentId': 'a-$receiptId', 'name': name, 'bytes': bytes},
    },
  };

  test('prefers the streamed route over the base64 RPC', () async {
    host.uploadFileBinary = (sessionId, name, bytes) {
      expect(sessionId, 's1');
      expect(name, 'notes.md');
      expect(bytes, [1, 2, 3]);
      return staged('r1', name, bytes.length);
    };
    final client = await connect();
    addTearDown(client.close);

    final receipt = await client.uploadFile('s1', [1, 2, 3], name: 'notes.md');
    expect(receipt.receiptId, 'r1');
    expect(receipt.attachment.name, 'notes.md');
    expect(receipt.attachment.bytes, 3);
    expect(host.binaryUploads.single, containsPair('sessionId', 's1'));
    expect(host.binaryUploads.single, containsPair('name', 'notes.md'));
    expect(host.binaryUploads.single, containsPair('contentType', 'application/octet-stream'));
    expect(host.rpcCalls, isEmpty);
  });

  test('falls back to the inline Remote call when the Host lacks the route', () async {
    host.handlers['fileUploads/upload'] = (args) {
      expect(args['agentId'], 's1');
      final request = (args['request']! as Map).cast<String, Object?>();
      expect(request['data'], base64Encode([9, 8, 7]));
      expect(request['name'], 'old.bin');
      return staged('r2', 'old.bin', 3);
    };
    final client = await connect();
    addTearDown(client.close);

    final receipt = await client.uploadFile('s1', [9, 8, 7], name: 'old.bin');
    expect(receipt.receiptId, 'r2');
    expect(host.binaryUploads, hasLength(1));
    expect(host.rpcCalls.map((call) => call['method']), contains('fileUploads/upload'));
  });

  test('a streamed-route refusal keeps its Host code and does not fall back', () async {
    host.uploadFileBinary = (sessionId, name, bytes) => {
      'ok': false,
      'error': {'code': 'session/not-found', 'message': 'session is gone', 'details': {}},
    };
    final client = await connect();
    addTearDown(client.close);

    await expectLater(
      client.uploadFile('s1', [1]),
      throwsA(isA<DshRemoteException>().having((e) => e.code, 'code', 'session/not-found')),
    );
    expect(host.rpcCalls, isEmpty);
  });

  test('refuses a file too large for the inline fallback when the Host lacks the route', () async {
    final client = await connect();
    addTearDown(client.close);
    final tooLarge = Uint8List(30 * 1024 * 1024 + 1);

    await expectLater(client.uploadFile('s1', tooLarge), throwsA(isA<DshProtocolException>()));
    expect(host.rpcCalls, isEmpty);
  });
}

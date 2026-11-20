import 'dart:async';
import 'dart:convert';
import 'package:dsh_client/dsh_client.dart';
import 'package:test/test.dart';
import 'support/fake_dsh.dart';

const image = ImageAttachment(
  attachmentId: 'image-fixture',
  mediaType: 'image/png',
  bytes: 3,
  width: 1,
  height: 1,
  name: 'pixel.png',
);
Map<String, Object?> ok() => {
  'ok': true,
  'value': {
    'attachment': image.toJson(),
    'data': base64Encode([1, 2, 3]),
  },
};
Map<String, Object?> failure(String code) => {
  'ok': false,
  'error': {'code': code, 'message': code},
};
void main() {
  late FakeDsh host;
  setUp(() async => host = await FakeDsh.start());
  tearDown(() async => host.close());
  Future<DshClient> connect() async {
    final client = await DshClient.connect(baseUri: host.baseUri, token: FakeDsh.token);
    addTearDown(client.close);
    return client;
  }

  test('new Host receives the exact known image reference and byte response is preserved', () async {
    host.handlers['session/attachment'] = (args) {
      expect(args, {
        'request': {'sessionId': 'session-a', 'attachment': image.toJson()},
      });
      return ok();
    };
    final result = await (await connect()).attachment('session-a', image);
    expect(result.bytes, [1, 2, 3]);
    expect(result.attachment, image);
  });
  for (final validationCode in ['gateway/arguments-invalid', 'gateway/input-invalid']) {
    test(
      '$validationCode legacy validation refusal falls back once and caches only a successful legacy response',
      () async {
        var calls = 0;
        host.handlers['session/attachment'] = (args) {
          final request = args['request'] as Map;
          calls++;
          if (calls == 1) {
            expect(request['attachment'], image.toJson());
            return failure(validationCode);
          }
          expect(request, {'sessionId': 'session-a', 'attachmentId': image.attachmentId});
          return ok();
        };
        final client = await connect();
        await client.attachment('session-a', image);
        await client.attachment('session-a', image);
        expect(calls, 3);
      },
    );
  }
  for (final code in [
    'session/attachment-invalid',
    'gateway/method-unavailable',
    'permission/denied',
    'gateway/internal',
  ]) {
    test('$code never retries against the other contract', () async {
      var calls = 0;
      host.handlers['session/attachment'] = (_) {
        calls++;
        return failure(code);
      };
      await expectLater((await connect()).attachment('session-a', image), throwsA(isA<DshRemoteException>()));
      expect(calls, 1);
    });
  }
  test('confirmed reference Host does not downgrade a later malformed request', () async {
    var calls = 0;
    host.handlers['session/attachment'] = (_) {
      calls++;
      return calls == 1 ? ok() : failure('gateway/arguments-invalid');
    };
    final client = await connect();
    await client.attachment('session-a', image);
    await expectLater(client.attachment('session-a', image), throwsA(isA<DshRemoteException>()));
    expect(calls, 2);
  });
  for (final initiallyNew in [false, true]) {
    test('protocol cache resets across a real mux reconnect ($initiallyNew)', () async {
      var newHost = initiallyNew;
      final requests = <bool>[];
      host.handlers['session/attachment'] = (args) {
        final full = (args['request'] as Map).containsKey('attachment');
        requests.add(full);
        return full == newHost ? ok() : failure('gateway/input-invalid');
      };
      final client = await connect();
      await client.attachment('session-a', image);
      final next = client.mux.generations.first;
      newHost = !initiallyNew;
      await host.sockets.last.ws.close();
      await next.timeout(const Duration(seconds: 5));
      await client.attachment('session-a', image);
      expect(requests, initiallyNew ? [true, true, false] : [true, false, true]);
    });
  }

  test('late old-generation discovery cannot replace the new-generation capability', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    Map<String, Object?>? lateArguments;
    final requests = <bool>[];
    host.beforeRpc = (endpoint, args) async {
      if (endpoint != 'session/attachment') return;
      requests.add((args['request'] as Map).containsKey('attachment'));
      if (lateArguments == null) {
        lateArguments = args;
        entered.complete();
        await release.future;
      }
    };
    host.handlers['session/attachment'] = (args) {
      if (identical(args, lateArguments)) return ok(); // Old Host full-ref response.
      return (args['request'] as Map).containsKey('attachment') ? failure('gateway/input-invalid') : ok();
    };
    final client = await connect();
    final late = client.attachment('session-a', image);
    await entered.future;
    final next = client.mux.generations.first;
    await host.sockets.last.ws.close();
    await next.timeout(const Duration(seconds: 5));
    await client.attachment('session-a', image); // Replacement Host is legacy.
    release.complete();
    await late;
    await client.attachment('session-a', image);
    expect(requests, [true, true, false, false]);
  });

  test('HTTP-only reads do not retain a Host capability without a ready generation', () async {
    var newHost = false;
    final requests = <bool>[];
    host.handlers['session/attachment'] = (args) {
      final full = (args['request'] as Map).containsKey('attachment');
      requests.add(full);
      return full == newHost ? ok() : failure('gateway/input-invalid');
    };
    final client = await DshClient.connect(baseUri: host.baseUri, token: FakeDsh.token, startMux: false);
    addTearDown(client.close);
    await client.attachment('session-a', image);
    newHost = true;
    await client.attachment('session-a', image);
    expect(requests, [true, false, true]);
  });

  test('same wire reference has stable cache identity; changed metadata does not reuse it', () {
    final copy = ImageAttachment.fromJson(image.toJson());
    expect(copy, image);
    expect(copy.hashCode, image.hashCode);
    for (final change in [
      {'bytes': 4},
      {'width': 2},
      {'height': 2},
      {'mediaType': 'image/jpeg'},
      {'name': 'other.png'},
      {'attachmentId': 'other'},
    ]) {
      expect(ImageAttachment.fromJson({...image.toJson(), ...change}), isNot(image));
    }
  });
}

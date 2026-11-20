import 'package:dsh_client/dsh_client.dart';
import 'package:test/test.dart';

import 'support/fake_dsh.dart';

void main() {
  late FakeDsh host;

  setUp(() async => host = await FakeDsh.start());
  tearDown(() async => host.close());

  Future<DshClient> connect() async {
    final client = await DshClient.connect(baseUri: host.baseUri, token: FakeDsh.token, startMux: false);
    addTearDown(client.close);
    return client;
  }

  test('session/search: request shape, hits in Host order, hasMore', () async {
    host.handlers['session/search'] = (args) {
      expect(args, {
        'request': {'query': '登录 bug'},
      });
      return {
        'ok': true,
        'value': {
          'items': [
            {'sessionId': 's2', 'snippet': '…跳回「登录」页'},
            {'sessionId': 's1', 'snippet': '用户双击「登录」'},
          ],
          'hasMore': true,
        },
      };
    };
    final client = await connect();
    final page = await client.searchSessionsPage('登录 bug');
    expect(page.items.map((i) => i.sessionId), ['s2', 's1']);
    expect(page.items.first.snippet, '…跳回「登录」页');
    expect(page.hasMore, isTrue);
    expect((await client.searchSessions('登录 bug')).length, 2);
  });

  test('session/search with the index off is a gateway/internal error', () async {
    host.handlers['session/search'] = (_) => {
      'ok': false,
      'error': {
        'code': 'gateway/internal',
        'message':
            'session search failed: SessionQueryError: session search is disabled: '
            'this deployment configures the session-query index with openAt "never"',
        'details': <String, Object?>{},
      },
    };
    final client = await connect();
    await expectLater(
      client.searchSessionsPage('x'),
      throwsA(
        isA<DshRemoteException>()
            .having((e) => e.code, 'code', 'gateway/internal')
            .having((e) => e.message, 'message', contains('search is disabled')),
      ),
    );
  });

  test('a page without hasMore reads as complete', () async {
    host.handlers['session/search'] = (_) => {
      'ok': true,
      'value': {'items': <Object?>[]},
    };
    final client = await connect();
    final page = await client.searchSessionsPage('nothing');
    expect(page.items, isEmpty);
    expect(page.hasMore, isFalse);
  });
}

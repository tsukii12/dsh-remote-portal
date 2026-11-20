import 'dart:async';
import 'dart:convert';

import 'package:dsh_app/forum/forum_auth.dart';
import 'package:dsh_app/forum/forum_config.dart';
import 'package:dsh_app/forum/forum_state.dart';
import 'package:dsh_app/remote/secret_store.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const secondBase = 'https://forum-second.example';
String credentials(String key) => jsonEncode({'key': key, 'client': 'diagnostic-client'});
http.Response page(int id, {bool more = false}) => http.Response(
  jsonEncode({
    'notifications': [
      {
        'id': id,
        'notification_type': 1,
        'data': {'username': 'diagnostic'},
      },
    ],
    if (more) 'load_more_notifications': '/notifications.json?offset=1',
  }),
  200,
);
Future<void> userReady(ProviderContainer c, [String name = 'first-user']) async {
  final ready = Completer<void>();
  final sub = c.listen(forumAuthProvider, (_, next) {
    if (next.user?.username == name && !ready.isCompleted) ready.complete();
  }, fireImmediately: true);
  try {
    await ready.future;
  } finally {
    sub.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  for (final change in ['none', 'logout', 'expiry', 'switch']) {
    for (final status in [200, 500]) {
      test('notification page HTTP $status after $change retains its owner', () async {
        final store = MemorySecretStore({
          'session:$forumDefaultBaseUrl': credentials('first-key'),
          'session:$secondBase': credentials('second-key'),
        });
        final entered = Completer<void>();
        final release = Completer<http.Response>();
        var expired = false;
        final client = MockClient((request) async {
          if (request.url.path == '/session/current.json') {
            if (expired && request.url.host != Uri.parse(secondBase).host) return http.Response('{}', 401);
            return http.Response(
              jsonEncode({
                'current_user': {
                  'id': 1,
                  'username': request.url.host == Uri.parse(secondBase).host ? 'second-user' : 'first-user',
                },
              }),
              200,
            );
          }
          if (request.url.path == '/user-api-key/revoke') return http.Response('{}', 200);
          expect(request.url.path, '/notifications.json');
          if (request.url.host == Uri.parse(secondBase).host) return page(9);
          if (request.url.queryParameters.containsKey('offset')) {
            entered.complete();
            return release.future;
          }
          return page(1, more: true);
        });
        final c = ProviderContainer(
          overrides: [
            forumSecretStoreProvider.overrideWithValue(store),
            forumHttpClientProvider.overrideWithValue(client),
          ],
        );
        addTearDown(c.dispose);
        addTearDown(client.close);
        await userReady(c);
        final subscription = c.listen(forumNotificationsProvider, (_, next) {});
        addTearDown(subscription.close);
        expect((await c.read(forumNotificationsProvider.future)).items.map((n) => n.id), [1]);
        final controller = c.read(forumNotificationsProvider.notifier);
        final pending = controller.loadMore();
        await entered.future;
        if (change == 'logout') await c.read(forumAuthProvider.notifier).signOut();
        if (change == 'expiry' || change == 'switch') {
          expired = true;
          await c.read(forumAuthProvider.notifier).refreshUser();
          expect(c.read(forumAuthProvider).signedIn, false);
        }
        if (change == 'switch') await c.read(forumBaseUrlProvider.notifier).set(secondBase);
        await c.pump();
        if (change == 'switch') {
          await userReady(c, 'second-user');
          await c.pump();
        }
        if (change != 'none') {
          final fresh = await c.read(forumNotificationsProvider.future);
          expect(fresh.items.map((n) => n.id), change == 'switch' ? [9] : isEmpty);
          expect(identical(controller, c.read(forumNotificationsProvider.notifier)), true);
        }
        release.complete(status == 200 ? page(2) : http.Response('{}', status));
        await pending;
        final finalState = c.read(forumNotificationsProvider).requireValue;
        expect(finalState.items.map((n) => n.id), switch (change) {
          'logout' || 'expiry' => <int>[],
          'switch' => [9],
          _ => status == 200 ? [1, 2] : [1],
        });
        expect(finalState.loadingMore, false);
        expect(finalState.moreError, change == 'none' && status == 500 ? isNotNull : isNull);
      });
    }
  }
}

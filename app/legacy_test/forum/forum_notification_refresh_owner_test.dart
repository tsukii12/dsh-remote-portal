import 'dart:async';
import 'dart:convert';

import 'package:dsh_app/forum/discourse_client.dart';
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
http.Response user(String name) => http.Response(
  jsonEncode({
    'current_user': {'id': 1, 'username': name, 'all_unread_notifications_count': 7},
  }),
  200,
);
http.Response page(int id) => http.Response(
  jsonEncode({
    'notifications': [
      {'id': id, 'notification_type': 1, 'read': false},
    ],
  }),
  200,
);
Future<void> authReady(ProviderContainer c, bool Function(ForumAuthState) matches) async {
  final ready = Completer<void>();
  final sub = c.listen(forumAuthProvider, (_, next) {
    if (matches(next) && !ready.isCompleted) ready.complete();
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
  for (final operation in ['refresh', 'markRead', 'markAllRead']) {
    for (final change in operation == 'refresh' ? ['none', 'expiry', 'switch'] : ['switch']) {
      for (final status in operation == 'refresh' ? [200, 500] : [500]) {
        test('$operation HTTP $status after automatic-auth $change retains its owner', () async {
          final store = MemorySecretStore({
            'session:$forumDefaultBaseUrl': credentials('first-key'),
            'session:$secondBase': credentials('second-key'),
          });
          final authEntered = Completer<void>(), authResponse = Completer<http.Response>();
          final entered = Completer<void>(), response = Completer<http.Response>();
          var notifications = 0;
          final client = MockClient((request) async {
            if (request.url.path == '/session/current.json') {
              if (request.url.host == Uri.parse(secondBase).host) return user('second-user');
              authEntered.complete();
              return authResponse.future;
            }
            if (request.url.host == Uri.parse(secondBase).host) {
              expect(request.url.path, '/notifications.json');
              return page(9);
            }
            if (request.url.path == '/notifications/mark-read.json') {
              expect(request.method, 'PUT');
              entered.complete();
              return response.future;
            }
            expect(request.url.path, '/notifications.json');
            if (++notifications > 1) {
              entered.complete();
              return response.future;
            }
            return page(1);
          });
          final c = ProviderContainer(
            overrides: [
              forumSecretStoreProvider.overrideWithValue(store),
              forumHttpClientProvider.overrideWithValue(client),
            ],
          );
          addTearDown(c.dispose);
          addTearDown(client.close);
          await authReady(c, (s) => s.signedIn);
          await authEntered.future;
          // Real restore has published signedIn while its automatic current-user check is pending.
          expect(c.read(forumAuthProvider).user, isNull);
          final subscription = c.listen(forumNotificationsProvider, (_, next) {});
          addTearDown(subscription.close);
          final initial = await c.read(forumNotificationsProvider.future);
          final controller = c.read(forumNotificationsProvider.notifier);
          final pending = switch (operation) {
            'refresh' => controller.refresh(),
            'markRead' => controller.markRead(initial.items.single),
            _ => controller.markAllRead(),
          };
          await entered.future;
          authResponse.complete(change == 'none' ? user('first-user') : http.Response('{}', 401));
          await authReady(
            c,
            (s) => change == 'none' ? s.user?.username == 'first-user' : s.phase == ForumAuthPhase.signedOut,
          );
          await c.pump();
          if (change == 'switch') {
            await c.read(forumBaseUrlProvider.notifier).set(secondBase);
            await c.pump();
            await authReady(c, (s) => s.user?.username == 'second-user');
            await c.pump();
          }
          if (change != 'none') {
            final fresh = await c.read(forumNotificationsProvider.future);
            expect(fresh.items.map((n) => n.id), change == 'expiry' ? <int>[] : [9]);
            expect(identical(controller, c.read(forumNotificationsProvider.notifier)), true);
          }
          final completion = expectLater(
            pending,
            change == 'none' && status == 500 ? throwsA(isA<ForumException>()) : completes,
          );
          response.complete(status == 200 ? page(2) : http.Response('{}', status));
          await completion;
          final current = c.read(forumNotificationsProvider).requireValue;
          expect(current.items.map((n) => n.id), switch (change) {
            'expiry' => <int>[],
            'switch' => [9],
            _ => status == 200 ? [2] : [1],
          });
          if (change == 'switch') {
            expect(current.items.single.read, false);
            expect(c.read(forumAuthProvider).unread, 7);
          }
        });
      }
    }
  }
}

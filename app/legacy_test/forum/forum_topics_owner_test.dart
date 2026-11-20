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
const feed = ForumFeed.latest();
String credentials(String key) => jsonEncode({'key': key, 'client': 'diagnostic-client'});
http.Response page(int id, {bool more = false}) => http.Response(
  jsonEncode({
    'topic_list': {
      'topics': [
        {'id': id, 'title': 'diagnostic topic $id'},
      ],
      'can_create_topic': id != 8,
      if (more) 'more_topics_url': '/latest.json?page=1',
    },
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
  for (final operation in ['refresh', 'loadMore']) {
    for (final change in ['none', 'logout', 'switch']) {
      for (final status in [200, 500]) {
        test('topics $operation HTTP $status after $change retains its owner', () async {
          final store = MemorySecretStore({
            'session:$forumDefaultBaseUrl': credentials('first-key'),
            'session:$secondBase': credentials('second-key'),
          });
          final entered = Completer<void>();
          final release = Completer<http.Response>();
          var hold = false;
          final client = MockClient((request) async {
            if (request.url.path == '/session/current.json') {
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
            expect(request.url.path, '/latest.json');
            if (request.url.host == Uri.parse(secondBase).host) return page(9);
            if (!request.headers.containsKey('User-Api-Key')) return page(8);
            if (hold) {
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
          final provider = forumTopicsProvider(feed);
          final subscription = c.listen(provider, (_, next) {});
          addTearDown(subscription.close);
          expect((await c.read(provider.future)).topics.map((n) => n.id), [1]);
          final controller = c.read(provider.notifier);
          hold = true;
          final pending = operation == 'refresh' ? controller.refresh() : controller.loadMore();
          await entered.future;
          if (change == 'logout') await c.read(forumAuthProvider.notifier).signOut();
          if (change == 'switch') await c.read(forumBaseUrlProvider.notifier).set(secondBase);
          await c.pump();
          if (change == 'switch') {
            await userReady(c, 'second-user');
            await c.pump();
          }
          if (change != 'none') {
            final fresh = await c.read(provider.future);
            expect(fresh.topics.map((n) => n.id), change == 'logout' ? [8] : [9]);
            expect(identical(controller, c.read(provider.notifier)), true);
          }
          release.complete(status == 200 ? page(2) : http.Response('{}', status));
          await pending;
          final finalState = c.read(provider).requireValue;
          expect(finalState.topics.map((n) => n.id), switch (change) {
            'logout' => [8],
            'switch' => [9],
            _ =>
              status == 500
                  ? [1]
                  : operation == 'refresh'
                  ? [2]
                  : [1, 2],
          });
          expect(finalState.loadingMore, false);
          expect(finalState.moreError, change == 'none' && status == 500 ? isNotNull : isNull);
          expect(finalState.canCreateTopic, change != 'logout');
        });
      }
    }
  }
}

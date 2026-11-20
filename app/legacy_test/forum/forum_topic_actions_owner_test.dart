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
  for (final operation in ['like', 'unlike', 'bookmark-error', 'remove-bookmark', 'bookmark-success']) {
    for (final expires in [false, true]) {
      test('$operation after automatic auth expires=$expires keeps current post', () async {
        final authEntered = Completer<void>(), authResponse = Completer<http.Response>();
        final entered = Completer<void>(), response = Completer<http.Response>();
        var topicReads = 0;
        final client = MockClient((request) async {
          if (request.url.path == '/session/current.json') {
            authEntered.complete();
            return authResponse.future;
          }
          if (request.url.path == '/t/7.json') {
            final fresh = ++topicReads > 1;
            return http.Response(
              jsonEncode({
                'id': 7,
                'title': 'Public topic',
                'posts_count': 1,
                'post_stream': {
                  'stream': [71],
                  'posts': [
                    {
                      'id': 71,
                      'topic_id': 7,
                      'post_number': 1,
                      'username': 'writer',
                      'cooked': fresh ? '<p>new revision</p>' : '<p>old revision</p>',
                      'actions_summary': [
                        {
                          'id': 2,
                          'count': fresh ? 11 : 3,
                          'acted': !fresh && operation == 'unlike',
                          'can_act': true,
                          'can_undo': true,
                        },
                      ],
                      'bookmarked': !fresh && operation == 'remove-bookmark',
                      if (!fresh && operation == 'remove-bookmark') 'bookmark_id': 8,
                    },
                  ],
                },
              }),
              200,
            );
          }
          final expectedPath = switch (operation) {
            'like' => '/post_actions.json',
            'unlike' => '/post_actions/71.json',
            'remove-bookmark' => '/bookmarks/8.json',
            _ => '/bookmarks.json',
          };
          expect(request.url.path, expectedPath);
          expect(request.method, ['unlike', 'remove-bookmark'].contains(operation) ? 'DELETE' : 'POST');
          entered.complete();
          return response.future;
        });
        final c = ProviderContainer(
          overrides: [
            forumHttpClientProvider.overrideWithValue(client),
            forumSecretStoreProvider.overrideWithValue(
              MemorySecretStore({
                'session:$forumDefaultBaseUrl': jsonEncode({'key': 'synthetic-key', 'client': 'diagnostic-client'}),
              }),
            ),
          ],
        );
        addTearDown(c.dispose);
        addTearDown(client.close);
        await authReady(c, (s) => s.signedIn);
        await authEntered.future;
        expect(c.read(forumAuthProvider).user, isNull);
        final provider = forumTopicProvider(7);
        final sub = c.listen(provider, (_, next) {});
        addTearDown(sub.close);
        final old = (await c.read(provider.future)).posts.single;
        final controller = c.read(provider.notifier);
        final pending = ['like', 'unlike'].contains(operation)
            ? controller.toggleLike(old)
            : controller.toggleBookmark(old);
        await entered.future;
        authResponse.complete(
          expires
              ? http.Response('{}', 401)
              : http.Response(
                  jsonEncode({
                    'current_user': {'id': 1, 'username': 'reader'},
                  }),
                  200,
                ),
        );
        await authReady(c, (s) => expires ? s.phase == ForumAuthPhase.signedOut : s.user != null);
        await c.pump();
        if (expires) {
          expect((await c.read(provider.future)).posts.single.cooked, '<p>new revision</p>');
          expect(identical(controller, c.read(provider.notifier)), true);
        }
        final succeeds = operation == 'bookmark-success';
        // Errors retain their original caller contract even after owner retirement.
        final completed = expectLater(pending, succeeds ? completes : throwsA(isA<ForumException>()));
        response.complete(http.Response(succeeds ? '{"id":9}' : '{}', succeeds ? 200 : 500));
        await completed;
        final actual = c.read(provider).requireValue.posts.single;
        if (expires) {
          expect(actual.cooked, '<p>new revision</p>');
          expect(actual.likeCount, 11);
          expect(actual.liked, false);
          expect(actual.bookmarked, false);
          expect(actual.bookmarkId, isNull);
        } else {
          expect(actual.cooked, old.cooked);
          expect(actual.likeCount, old.likeCount);
          expect(actual.liked, old.liked);
          expect(actual.bookmarked, succeeds || old.bookmarked);
          expect(actual.bookmarkId, succeeds ? 9 : old.bookmarkId);
        }
      });
    }
  }
}

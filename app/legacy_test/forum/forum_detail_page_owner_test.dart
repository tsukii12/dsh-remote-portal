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

Map<String, Object> post(int id, String revision) => {
  'id': id,
  'topic_id': 7,
  'post_number': id,
  'username': 'writer',
  'cooked': '<p>$revision $id</p>',
};
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
  for (final expires in [false, true]) {
    for (final status in [200, 500]) {
      test('detail page HTTP $status after automatic auth expires=$expires keeps current posts', () async {
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
            // Initial first page has 20/21 posts. After post 1 is deleted,
            // the next topic reload contains 2..21, including a new revision of 21.
            return http.Response(
              jsonEncode({
                'id': 7,
                'title': 'Public topic',
                'posts_count': fresh ? 20 : 21,
                'chunk_size': 20,
                'post_stream': {
                  'stream': [for (var id = fresh ? 2 : 1; id <= 21; id++) id],
                  'posts': [
                    for (var id = fresh ? 2 : 1; id <= (fresh ? 21 : 20); id++) post(id, fresh ? 'new' : 'old'),
                  ],
                },
              }),
              200,
            );
          }
          expect(request.url.path, '/t/7/posts.json');
          expect(request.url.queryParametersAll['post_ids[]'], ['21']);
          expect(request.method, 'GET');
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
        final initial = await c.read(provider.future);
        expect(initial.missing, [21]);
        final controller = c.read(provider.notifier);
        final pending = controller.loadMore();
        await entered.future;
        expect(controller.loadingMore, true);
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
          final fresh = await c.read(provider.future);
          expect(fresh.posts.last.cooked, '<p>new 21</p>');
          expect(fresh.stream, [for (var id = 2; id <= 21; id++) id]);
          expect(identical(controller, c.read(provider.notifier)), true);
        }
        final completion = expectLater(pending, status == 200 ? completes : throwsA(isA<ForumException>()));
        response.complete(
          status == 200
              ? http.Response(
                  jsonEncode({
                    'post_stream': {
                      'posts': [post(21, 'old')],
                    },
                  }),
                  200,
                )
              : http.Response('{}', 500),
        );
        await completion;
        expect(controller.loadingMore, false);
        final actual = c.read(provider).requireValue;
        if (expires) {
          expect(actual.posts.last.cooked, '<p>new 21</p>');
          expect(actual.posts.length, 20);
          expect(actual.hasMore, false);
        } else {
          expect(actual.posts.length, status == 200 ? 21 : 20);
          expect(actual.posts.last.cooked, status == 200 ? '<p>old 21</p>' : '<p>old 20</p>');
          expect(actual.hasMore, status != 200);
        }
      });
    }
  }
}

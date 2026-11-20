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
http.Response user(String name) => http.Response(
  jsonEncode({
    'current_user': {'id': 1, 'username': name},
  }),
  200,
);
Future<void> userReady(ProviderContainer c, String name) async {
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

class DeleteGateStore extends MemorySecretStore {
  DeleteGateStore(super.initial);
  final entered = Completer<void>();
  final release = Completer<void>();
  bool hold = false;
  @override
  Future<void> delete(String key) async {
    if (hold && key == 'session:$forumDefaultBaseUrl') {
      entered.complete();
      await release.future;
    }
    await super.delete(key);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  for (final status in [200, 401, 403, 404]) {
    test('old forum current-user HTTP $status cannot change the newly selected forum', () async {
      final store = MemorySecretStore({
        'session:$forumDefaultBaseUrl': credentials('first-key'),
        'session:$secondBase': credentials('second-key'),
      });
      final entered = Completer<void>();
      final release = Completer<http.Response>();
      var hold = false;
      final client = MockClient((request) async {
        expect(request.url.path, '/session/current.json');
        if (request.url.host == Uri.parse(secondBase).host) return user('second-user');
        if (hold) {
          entered.complete();
          return release.future;
        }
        return user('first-user');
      });
      final c = ProviderContainer(
        overrides: [
          forumSecretStoreProvider.overrideWithValue(store),
          forumHttpClientProvider.overrideWithValue(client),
        ],
      );
      addTearDown(c.dispose);
      addTearDown(client.close);
      await userReady(c, 'first-user');
      hold = true;
      final oldRefresh = c.read(forumAuthProvider.notifier).refreshUser();
      await entered.future;
      expect(await c.read(forumBaseUrlProvider.notifier).set(secondBase), true);
      await userReady(c, 'second-user');
      release.complete(status == 200 ? user('late-first-user') : http.Response('{}', status));
      await oldRefresh;
      expect(await store.read('session:$secondBase'), credentials('second-key'));
      expect(c.read(forumAuthProvider).signedIn, true);
      expect(c.read(forumAuthProvider).user?.username, 'second-user');
    });
  }
  test('expiry deletion started for old forum cannot sign out newly selected forum on completion', () async {
    final store = DeleteGateStore({
      'session:$forumDefaultBaseUrl': credentials('first-key'),
      'session:$secondBase': credentials('second-key'),
    });
    var rejected = false;
    final client = MockClient((request) async {
      if (request.url.host == Uri.parse(secondBase).host) return user('second-user');
      return rejected ? http.Response('{}', 401) : user('first-user');
    });
    final c = ProviderContainer(
      overrides: [forumSecretStoreProvider.overrideWithValue(store), forumHttpClientProvider.overrideWithValue(client)],
    );
    addTearDown(c.dispose);
    addTearDown(client.close);
    await userReady(c, 'first-user');
    rejected = true;
    store.hold = true;
    final pending = c.read(forumAuthProvider.notifier).refreshUser();
    await store.entered.future;
    await c.read(forumBaseUrlProvider.notifier).set(secondBase);
    await userReady(c, 'second-user');
    store.release.complete();
    await pending;
    expect(c.read(forumAuthProvider).signedIn, true);
    expect(c.read(forumAuthProvider).user?.username, 'second-user');
    expect(await store.read('session:$secondBase'), credentials('second-key'));
  });
  test('current forum unauthorized response still expires the matching stored key', () async {
    final store = MemorySecretStore({'session:$forumDefaultBaseUrl': credentials('first-key')});
    var rejected = false;
    final client = MockClient((_) async => rejected ? http.Response('{}', 401) : user('first-user'));
    final c = ProviderContainer(
      overrides: [forumSecretStoreProvider.overrideWithValue(store), forumHttpClientProvider.overrideWithValue(client)],
    );
    addTearDown(c.dispose);
    addTearDown(client.close);
    await userReady(c, 'first-user');
    rejected = true;
    await c.read(forumAuthProvider.notifier).refreshUser();
    expect(c.read(forumAuthProvider).signedIn, false);
    expect(c.read(forumAuthProvider).error, isNotNull);
    expect(await store.read('session:$forumDefaultBaseUrl'), isNull);
  });
}

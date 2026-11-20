import 'dart:async';

import 'package:dsh_app/state/bots_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support.dart';

class MissingFeed extends FakeDsBotTransport {
  final stream = StreamController<DsBotSseEvent>();
  @override
  Stream<DsBotSseEvent> openFeed() {
    feedOpens++;
    return stream.stream;
  }

  @override
  Future<void> close() => stream.close();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test('feed404 invalidates pending state and refresh cannot restore ready', () async {
    final fake = MissingFeed();
    final container = dsBotContainer(fake);
    addTearDown(container.dispose);
    container.listen(dsBotProvider, (_, _) {});
    await settle(12);
    final pending = Completer<Object?>();
    fake.handlers['state'] = (_) => pending.future;
    final refresh = container.read(dsBotProvider.notifier).refresh();
    await settle();
    fake.stream.addError(const DshHttpException(404, 'controlled missing feed'));
    await settle(12);
    pending.complete(sampleTeam());
    await refresh;
    await container.read(dsBotProvider.notifier).refresh();
    expect(container.read(dsBotProvider).availability, DsBotAvailability.outdated);
    expect(container.read(dsBotProvider.notifier).api, isNull);
    expect(fake.feedOpens, 1);
  });

  for (final code in ['bot/read-only', 'bot/not-found']) {
    test('legacy hello $code is an unsupported mobile capability', () async {
      final fake = FakeDsBotTransport();
      fake.handlers['hello'] = (_) => throw DshRemoteException(code, 'legacy endpoint');
      final container = dsBotContainer(fake);
      addTearDown(container.dispose);
      container.listen(dsBotProvider, (_, _) {});
      await settle(12);
      expect(container.read(dsBotProvider).availability, DsBotAvailability.outdated);
    });
  }
  for (final code in [401, 403]) {
    test('HTTP $code remains an authentication failure', () async {
      final fake = FakeDsBotTransport();
      fake.handlers['hello'] = (_) => throw DshHttpException(code, 'auth');
      final container = dsBotContainer(fake);
      addTearDown(container.dispose);
      container.listen(dsBotProvider, (_, _) {});
      await settle(12);
      expect(container.read(dsBotProvider).availability, DsBotAvailability.failed);
      expect(fake.feedOpens, 0);
    });
  }
}

import 'package:dsh_app/state/bots_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final compatible in [true, false]) {
    test('changed feed boot rechecks handshake; compatible=$compatible', () async {
      final old = FakeDsBotTransport()..helloOnFeed = false;
      final next = FakeDsBotTransport()..helloOnFeed = false;
      next.handlers['hello'] = (_) => {
        ...next.helloAnswer(),
        'boot': 'boot-2',
        if (!compatible) ...{'api': null, 'apiMin': 2, 'apiMax': 2},
      };
      var opens = 0;
      final container = ProviderContainer(
        overrides: [
          ...(dsBotOverrides(old)..removeAt(1)),
          dsBotApiFactoryProvider.overrideWithValue((_) => DsBotApi(opens++ == 0 ? old : next)),
        ],
      );
      addTearDown(container.dispose);
      container.listen(dsBotProvider, (_, _) {});
      await settle(12);
      final previousApi = container.read(dsBotProvider.notifier).api;
      old.emit('hello', {'api': 1, 'boot': 'boot-2', 'seq': 0, 'revision': 1});
      await settle(20);
      expect(next.endpoints, contains('hello'));
      expect(container.read(dsBotProvider.notifier).api, isNot(same(previousApi)));
      expect(container.read(dsBotProvider).hello!.boot, 'boot-2');
      expect(
        container.read(dsBotProvider).availability,
        compatible ? DsBotAvailability.ready : DsBotAvailability.outdated,
      );
      if (!compatible) expect(next.endpoints, isNot(contains('state')));
    });
  }

  test('ordinary reconnects and feeds without boot do not restart the hub', () async {
    final fake = FakeDsBotTransport()..helloOnFeed = false;
    final container = dsBotContainer(fake);
    addTearDown(container.dispose);
    container.listen(dsBotProvider, (_, _) {});
    await settle(12);
    final api = container.read(dsBotProvider.notifier).api;
    for (final boot in ['boot-1', null, '']) {
      fake.emit('hello', {'revision': 7, 'boot': ?boot, 'seq': 0});
      await settle(12);
    }
    expect(fake.endpoints.where((endpoint) => endpoint == 'hello'), hasLength(1));
    expect(container.read(dsBotProvider.notifier).api, same(api));
  });
}

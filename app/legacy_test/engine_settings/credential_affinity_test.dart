// A key sheet opened on one host must not store a credential on the next one
// (media-generation §5.8: the media page names credentials itself instead of
// using a schema-declared secret slot, so the engine's snapshot affinity has
// to cover that path too).

import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/engine_settings_state.dart';
import 'package:dsh_app/state/plugins_state.dart';
import 'package:dsh_app/state/read_list_identity.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../shell/golden_harness.dart' show FakeSettings;
import 'support.dart';

final _initialActive = ValueNotifier<HostConnection?>(null);

class _ActiveHost extends Notifier<AsyncValue<HostConnection?>> {
  @override
  AsyncValue<HostConnection?> build() => AsyncData(_initialActive.value);

  void set(HostConnection? connection) => state = AsyncData(connection);
}

final _activeHostProvider = NotifierProvider<_ActiveHost, AsyncValue<HostConnection?>>(_ActiveHost.new);

void main() {
  tearDown(() => _initialActive.value = null);

  test('a credential editor from host A cannot write to host B', () async {
    final a = FakeSettingsHost();
    final b = FakeSettingsHost();
    _initialActive.value = fakeConnection(DshClient.withCarrier(a));
    final container = ProviderContainer(
      overrides: [
        activeConnectionProvider.overrideWith((ref) => ref.watch(_activeHostProvider)),
        localSafeModeProvider.overrideWithValue(false),
        settingsProvider.overrideWith(() => FakeSettings(const AppSettings(loaded: true))),
        readListIdentityProvider.overrideWithValue(null),
      ],
    );
    addTearDown(container.dispose);
    final sub = container.listen(engineSettingsProvider, (_, _) {});
    addTearDown(sub.close);
    await container.read(engineSettingsProvider.future);
    final old = container.read(engineSettingsProvider.notifier).edit(container.read(engineSettingsProvider).value!);

    container.read(_activeHostProvider.notifier).set(fakeConnection(DshClient.withCarrier(b)));
    await container.read(engineSettingsProvider.future);

    await expectLater(
      old.setCredential('DSH_MEDIA_ARK_API_KEY', 'sk-must-not-land'),
      throwsA(isA<EngineSettingsFailure>()),
    );
    expect(
      [
        for (final (endpoint, _) in b.calls)
          if (endpoint == 'credentials/set') endpoint,
      ],
      isEmpty,
      reason: 'nothing is written to the new host',
    );
    expect(b.credentials, isEmpty);
    expect(
      [
        for (final (endpoint, _) in a.calls)
          if (endpoint == 'credentials/set') endpoint,
      ],
      isEmpty,
      reason: 'the stale draft does not reach the old host either',
    );
    await expectLater(old.clearCredential('DSH_MEDIA_ARK_API_KEY'), throwsA(isA<EngineSettingsFailure>()));
    expect(
      [
        for (final (endpoint, _) in b.calls)
          if (endpoint == 'credentials/unset') endpoint,
      ],
      isEmpty,
      reason: 'a stale clear does not reach the new host either',
    );
  });
}

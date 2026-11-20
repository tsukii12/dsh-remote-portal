import 'dart:convert';

import 'package:dsh_app/remote/portal_link.dart';
import 'package:dsh_app/remote/secret_store.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/read_list_epoch.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final first = PortalHostConfig(id: 'one', name: 'One', base: Uri.parse('https://example.test/__t/one/'));
  final second = PortalHostConfig(id: 'two', name: 'Two', base: Uri.parse('https://example.test/__t/two/'));

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('portal identity round-trips without using display names as identity', () {
    const host = HostRef.portal('one', name: 'One');
    expect(HostRef.decode(host.encode()), host);
    expect(HostRef.decode(host.encode()).name, 'One');
    expect(host, const HostRef.portal('one', name: 'Renamed'));
    expect(host, isNot(const HostRef.portal('two')));
    expect(host.isLocal, isFalse);
  });

  test('missing, malformed and retired host kinds cannot enable a local fallback', () {
    for (final raw in [null, '', 'invalid', '[]', '{"kind":"local"}', '{"kind":"ssh","id":"one"}']) {
      expect(HostRef.decode(raw), HostRef.none);
    }
  });

  test('saved bases preserve relay prefixes and isolate cookies on one authority', () {
    final restored = PortalHostConfig.fromJson(first.toJson());
    expect(restored.base, first.base);
    expect(restored.cookieKey, first.cookieKey);
    expect(first.cookieKey, isNot(second.cookieKey));
    expect(first.cookieKey, isNot(contains(first.base.toString())));
  });

  test('profiles persist, replace by id and restore the selected portal', () async {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    await c.read(hostsProvider.notifier).ready;
    await c.read(activeHostProvider.notifier).ready;
    await c.read(hostsProvider.notifier).save(first);
    await c.read(hostsProvider.notifier).save(second);
    final renamed = PortalHostConfig(id: first.id, name: 'Renamed', base: first.base);
    await c.read(hostsProvider.notifier).save(renamed);
    expect(c.read(hostsProvider).portals, hasLength(2));
    expect(c.read(hostsProvider).portalById('one')?.name, 'Renamed');
    final epoch = c.read(readListCredentialEpochProvider);
    c.read(activeHostProvider.notifier).select(const HostRef.portal('one'));
    expect(c.read(readListCredentialEpochProvider), greaterThan(epoch));
    await Future<void>.delayed(Duration.zero);
    final restored = ProviderContainer();
    addTearDown(restored.dispose);
    await restored.read(activeHostProvider.notifier).ready;
    expect(restored.read(activeHostProvider), const HostRef.portal('one'));
    expect(restored.read(hostsProvider).portalById('one')?.base, first.base);
  });

  test('removing a selected portal deletes only its cookies and returns to login', () async {
    final secrets = MemorySecretStore({first.cookieKey: 'fixture-one', second.cookieKey: 'fixture-two'});
    final c = ProviderContainer(overrides: [secretStoreProvider.overrideWithValue(secrets)]);
    addTearDown(c.dispose);
    await c.read(activeHostProvider.notifier).ready;
    await c.read(hostsProvider.notifier).save(first);
    await c.read(hostsProvider.notifier).save(second);
    c.read(activeHostProvider.notifier).select(const HostRef.portal('one'));
    await c.read(hostsProvider.notifier).remove('one');
    expect(c.read(activeHostProvider), HostRef.none);
    expect(secrets.values, {second.cookieKey: 'fixture-two'});
    expect(c.read(hostsProvider).portals.single.id, 'two');
    await c.read(hostsProvider.notifier).remove('unknown');
    expect(c.read(hostsProvider).portals.single.id, 'two');
  });

  test('corrupt profiles and a deleted selection stay disconnected', () async {
    SharedPreferences.setMockInitialValues({
      HostsController.prefsKey: 'not-json',
      ActiveHostController.prefsKey: const HostRef.portal('missing').encode(),
    });
    final c = ProviderContainer();
    addTearDown(c.dispose);
    await c.read(activeHostProvider.notifier).ready;
    expect(c.read(hostsProvider).loaded, isTrue);
    expect(c.read(hostsProvider).portals, isEmpty);
    expect(c.read(activeHostProvider), HostRef.none);
  });

  test('valid profiles do not silently select an unrecognized saved host', () async {
    SharedPreferences.setMockInitialValues({
      HostsController.prefsKey: jsonEncode([first.toJson()]),
      ActiveHostController.prefsKey: const HostRef.portal('missing').encode(),
    });
    final c = ProviderContainer();
    addTearDown(c.dispose);
    await c.read(activeHostProvider.notifier).ready;
    expect(c.read(hostsProvider).portals, hasLength(1));
    expect(c.read(activeHostProvider), HostRef.none);
  });

  for (final cookies in <String?>[null, 'not-json']) {
    test(
      'missing or corrupt cookies require login before opening mux: ${cookies == null ? 'missing' : 'corrupt'}',
      () async {
        final secrets = MemorySecretStore({first.cookieKey: ?cookies});
        final link = PortalHostLink(first, secrets);
        addTearDown(link.close);
        await expectLater(
          link.open(),
          throwsA(isA<HostLinkError>().having((e) => e.kind, 'kind', HostLinkErrorKind.authFailed)),
        );
        expect(link.status.phase, HostLinkPhase.failed);
        expect(link.currentClient, isNull);
        expect(secrets.values, isEmpty);
      },
    );
  }
}

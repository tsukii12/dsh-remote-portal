import 'dart:async';

import 'package:dsh_app/state/bots_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../chat/support/harness.dart' show fakeConnection;
import 'support.dart';

class _Host extends ActiveHostController {
  @override
  HostRef build() => HostRef.none;
  @override
  void select(HostRef host) => state = host;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  final photo = dsBotPhotoProvider((botId: 'b3', ref: 'abc123'));

  for (final change in ['host', 'HTTP boot']) {
    for (final lateError in [false, true]) {
      test('photo renews after $change while old request is pending; lateError=$lateError', () async {
        final old = FakeDsBotTransport()..helloOnFeed = false;
        final next = FakeDsBotTransport()..helloOnFeed = false;
        final pending = Completer<Object?>();
        old.handlers['avatar'] = (_) => pending.future;
        next.handlers['hello'] = (_) => {...next.helloAnswer(), 'boot': 'boot-2'};
        var restarted = false;
        final container = ProviderContainer(
          overrides: [
            activeHostProvider.overrideWith(_Host.new),
            activeConnectionProvider.overrideWith((ref) {
              final host = ref.watch(activeHostProvider);
              return AsyncData(
                HostConnection(
                  client: fakeConnection.client,
                  label: host.id,
                  isLocal: host.isLocal,
                  kind: host.kind,
                  hostId: host.id,
                ),
              );
            }),
            dsBotApiFactoryProvider.overrideWithValue(
              (connection) => DsBotApi((connection.hostId == HostRef.none.id) && !restarted ? old : next),
            ),
          ],
        );
        addTearDown(container.dispose);
        container.listen(dsBotProvider, (_, _) {});
        await settle(12);
        container.listen(photo, (_, _) {});
        await settle(8);
        expect(old.endpoints.where((e) => e == 'avatar'), hasLength(1));
        final originalApi = container.read(dsBotProvider.notifier).api;
        if (change == 'host') {
          container.read(activeHostProvider.notifier).select(const HostRef.portal('next'));
        } else {
          restarted = true;
          old.emit('hello', {'api': 1, 'boot': 'boot-2', 'seq': 0, 'revision': 1});
        }
        await settle(20);
        expect(container.read(dsBotProvider).ready, isTrue);
        expect(container.read(dsBotProvider).hello!.boot, 'boot-2');
        expect(container.read(dsBotProvider.notifier).api, isNot(same(originalApi)));
        expect(next.endpoints.where((e) => e == 'avatar'), hasLength(1));
        expect(container.read(photo).value, orderedEquals(decodeDataUrl(tinyPhoto)!));
        // The reference and the image bytes are identical on both hosts. The
        // issue is a stranded read, not a manufactured content-hash collision.
        if (lateError) {
          pending.completeError(const DshTransportException('old connection closed'));
        } else {
          pending.complete({'botId': 'b3', 'ref': 'abc123', 'image': tinyPhoto});
        }
        await settle(12);
        expect(container.read(photo).hasError, isFalse);
        expect(container.read(photo).isLoading, isFalse);
        expect(container.read(photo).value, orderedEquals(decodeDataUrl(tinyPhoto)!));
      });
    }
  }

  test('ordinary state and same-boot feed updates keep the decoded photo cached', () async {
    final fake = FakeDsBotTransport()..helloOnFeed = false;
    final container = dsBotContainer(fake);
    addTearDown(container.dispose);
    container.listen(dsBotProvider, (_, _) {});
    await settle(12);
    container.listen(photo, (_, _) {});
    await settle(8);
    final original = container.read(photo).value;
    expect(original, isNotNull);
    await container.read(dsBotProvider.notifier).refresh();
    fake.emit('hello', {'api': 1, 'boot': 'boot-1', 'seq': 0, 'revision': 7});
    await settle(12);
    expect(fake.endpoints.where((e) => e == 'avatar'), hasLength(1));
    expect(container.read(photo).value, same(original));
  });

  test('disconnect clears cached photo and does not start another avatar read', () async {
    final fake = FakeDsBotTransport();
    final container = dsBotContainer(fake);
    addTearDown(container.dispose);
    container.listen(dsBotProvider, (_, _) {});
    await settle(12);
    container.listen(photo, (_, _) {});
    await settle(8);
    expect(container.read(photo).value, isNotNull);
    container.updateOverrides([
      ...(dsBotOverrides(fake)..removeAt(0)),
      activeConnectionProvider.overrideWithValue(const AsyncData(null)),
    ]);
    await settle(12);
    expect(container.read(dsBotProvider).ready, isFalse);
    expect(container.read(photo).value, isNull);
    expect(fake.endpoints.where((e) => e == 'avatar'), hasLength(1));
  });

  test('a pending handshake does not request photos until ready', () async {
    final fake = FakeDsBotTransport()..helloOnFeed = false;
    final hello = Completer<Object?>();
    fake.handlers['hello'] = (_) => hello.future;
    final container = dsBotContainer(fake);
    addTearDown(container.dispose);
    container.listen(dsBotProvider, (_, _) {});
    container.listen(photo, (_, _) {});
    await settle(8);
    expect(container.read(dsBotProvider).ready, isFalse);
    expect(fake.endpoints.where((e) => e == 'avatar'), isEmpty);
    hello.complete(fake.helloAnswer());
    await settle(20);
    expect(container.read(dsBotProvider).ready, isTrue);
    expect(fake.endpoints.where((e) => e == 'avatar'), hasLength(1));
    expect(container.read(photo).value, isNotNull);
  });
}

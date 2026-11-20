import 'dart:convert';

import 'package:dsh_app/share_hosted/hosted_client.dart';
import 'package:dsh_app/share_hosted/hosted_crypto.dart';
import 'package:dsh_app/share_hosted/hosted_link.dart';
import 'package:dsh_app/share_hosted/hosted_links_state.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'hosted_client_test.dart' show FakeHost;

const _channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
final _file = Uint8List.fromList(utf8.encode('{"dshgo":2,"kind":"conversation"}'));
final _old = HostedLink(
  id: 'z000000099',
  key: encodeHostedKey(Uint8List(32)),
  deleteToken: 'synthetic-old-delete-token',
  title: 'Existing test link',
  createdAt: DateTime.utc(2026, 10, 1),
  ttl: HostedTtl.forever,
  origin: 'https://go.example',
);

enum _FirstRead { normal, initializationError, nativeReset }

class _Rig {
  _Rig({String? initial, this.firstRead = _FirstRead.normal}) : stored = initial {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_channel, _call);
    addTearDown(() {
      for (final container in containers) {
        container.dispose();
      }
      client.close();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_channel, null);
      debugDefaultTargetPlatformOverride = null;
    });
  }

  final _FirstRead firstRead;
  final host = FakeHost();
  final store = const SecureHostedLinkStore();
  late final client = HostedShareClient(client: host.client, origin: 'https://go.example');
  final containers = <ProviderContainer>[];
  String? stored;
  int reads = 0;
  int writes = 0;

  Future<Object?> _call(MethodCall call) async {
    final args = call.arguments as Map;
    if (args['key'] != SecureHostedLinkStore.storageKey) {
      throw StateError('unexpected secure storage key');
    }
    final options = args['options'] as Map;
    if (options['resetOnError'] != 'true') {
      throw StateError('this fixture keeps the default resetOnError option');
    }
    switch (call.method) {
      case 'read':
        reads++;
        if (reads == 1) {
          switch (firstRead) {
            case _FirstRead.initializationError:
              // Models the native initializeStorageCipher general-error path:
              // it reports an error before readUnsafe/reset modifies the key.
              throw PlatformException(code: 'Exception encountered', message: 'synthetic initialization failure');
            case _FirstRead.nativeReset:
              // Distinct control: native reset has already removed the value
              // and its successful retry reports absence. This is not a read
              // refusal with a retained old collection.
              stored = null;
              break;
            case _FirstRead.normal:
              break;
          }
        }
        return stored;
      case 'write':
        writes++;
        stored = args['value'] as String;
        return null;
      default:
        throw StateError('unexpected secure storage operation ${call.method}');
    }
  }

  ProviderContainer open() {
    final container = ProviderContainer(
      overrides: [
        hostedLinkStoreProvider.overrideWithValue(store),
        hostedShareClientProvider.overrideWithValue(client),
      ],
    );
    containers.add(container);
    return container;
  }

  void close(ProviderContainer container) {
    containers.remove(container);
    container.dispose();
  }

  List<HostedLink> get persisted => [for (final item in jsonDecode(stored!) as List) HostedLink.fromJson(item)!];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('an initialization read refusal cannot turn later publishing into replacement of unread links', () async {
    final original = jsonEncode([_old.toJson()]);
    final rig = _Rig(initial: original, firstRead: _FirstRead.initializationError);
    final container = rig.open();
    final links = container.read(hostedLinksProvider.notifier);
    await links.ready;
    expect(rig.reads, 1);
    expect(rig.stored == original, isTrue, reason: 'the modeled initialization error has not reset native data');
    expect(container.read(hostedLinksProvider).loaded, isTrue);
    expect(container.read(hostedLinksProvider).links, isEmpty);

    final made = await links.publish(_file, title: 'New volatile link', ttl: HostedTtl.forever);
    expect(rig.host.blobs, contains(made.id));
    expect(container.read(hostedLinksProvider).visible.single.id, made.id);
    expect(rig.writes, 0, reason: 'a replacement list cannot discard a collection that was never read');
    expect(rig.stored == original, isTrue);

    // The same run still permits in-memory add/remove/undo, but none of those
    // operations can make its initially unread collection safe to replace.
    await links.remove(made.id);
    await links.undo(made.id);
    expect(container.read(hostedLinksProvider).visible.single.id, made.id);
    expect(rig.writes, 0);
    expect(rig.stored == original, isTrue);
  });

  test('a fresh successful load recovers old links and permits a later complete save', () async {
    final rig = _Rig(initial: jsonEncode([_old.toJson()]), firstRead: _FirstRead.initializationError);
    final first = rig.open();
    final firstLinks = first.read(hostedLinksProvider.notifier);
    await firstLinks.ready;
    final volatile = await firstLinks.publish(_file, title: 'This run only', ttl: HostedTtl.forever);
    expect(first.read(hostedLinksProvider).visible.single.id, volatile.id);
    rig.close(first);

    final next = rig.open();
    final nextLinks = next.read(hostedLinksProvider.notifier);
    await nextLinks.ready;
    expect(rig.reads, 2);
    expect(next.read(hostedLinksProvider).links.map((link) => link.id), [_old.id]);
    expect(next.read(hostedLinksProvider).links.single.key == _old.key, isTrue);
    expect(next.read(hostedLinksProvider).links.single.deleteToken == _old.deleteToken, isTrue);
    final made = await nextLinks.publish(_file, title: 'Saved after recovery', ttl: HostedTtl.forever);
    expect(rig.persisted.map((link) => link.id), [made.id, _old.id]);
    expect(rig.writes, 1);
  });

  test('a successful existing collection load retains old keys and saves a newly published link', () async {
    final rig = _Rig(initial: jsonEncode([_old.toJson()]));
    final container = rig.open();
    final links = container.read(hostedLinksProvider.notifier);
    await links.ready;
    final made = await links.publish(_file, title: 'Normal new link', ttl: HostedTtl.forever);
    expect(rig.persisted.map((link) => link.id), [made.id, _old.id]);
    expect(rig.persisted.last.key == _old.key, isTrue);
    expect(rig.persisted.last.deleteToken == _old.deleteToken, isTrue);
    expect(rig.writes, 1);
  });

  for (final input in <String, String?>{
    'absent value': null,
    'empty value': '',
    'invalid JSON': '{broken',
    'non-list JSON': '{}',
  }.entries) {
    test('a successfully read ${input.key} keeps its existing empty-list recovery behavior', () async {
      final rig = _Rig(initial: input.value);
      final container = rig.open();
      final links = container.read(hostedLinksProvider.notifier);
      await links.ready;
      expect(container.read(hostedLinksProvider).loaded, isTrue);
      expect(container.read(hostedLinksProvider).links, isEmpty);
      final made = await links.publish(_file, title: 'First saved link', ttl: HostedTtl.forever);
      expect(rig.persisted.single.id, made.id);
      expect(rig.writes, 1);
    });
  }

  test('a successful absent reply after native reset is not mistaken for a retained-data read refusal', () async {
    final rig = _Rig(initial: jsonEncode([_old.toJson()]), firstRead: _FirstRead.nativeReset);
    final container = rig.open();
    final links = container.read(hostedLinksProvider.notifier);
    await links.ready;
    expect(rig.stored, isNull);
    expect(container.read(hostedLinksProvider).links, isEmpty);
    final made = await links.publish(_file, title: 'Saved after native reset', ttl: HostedTtl.forever);
    expect(rig.persisted.single.id, made.id);
    expect(rig.writes, 1);
  });
}

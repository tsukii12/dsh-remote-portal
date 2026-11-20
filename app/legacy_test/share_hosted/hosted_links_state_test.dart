import 'dart:convert';
import 'dart:typed_data';

import 'package:dsh_app/share_hosted/hosted_client.dart';
import 'package:dsh_app/share_hosted/hosted_crypto.dart';
import 'package:dsh_app/share_hosted/hosted_link.dart';
import 'package:dsh_app/share_hosted/hosted_links_state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'hosted_client_test.dart' show FakeHost;

class MemoryStore implements HostedLinkStore {
  MemoryStore([List<HostedLink> initial = const []]) : saved = List.of(initial);
  List<HostedLink> saved;
  int saves = 0;

  @override
  Future<List<HostedLink>> load() async => List.of(saved);

  @override
  Future<void> save(List<HostedLink> links) async {
    saves++;
    saved = List.of(links);
  }
}

HostedLink link(String id, {DateTime? expires, bool deleting = false, String? token}) => HostedLink(
  id: id,
  key: encodeHostedKey(newHostedKey()),
  deleteToken: token ?? 'token-$id-0123456789',
  title: '对话 $id',
  createdAt: DateTime.utc(2026, 10, 1),
  ttl: HostedTtl.month,
  expiresAt: expires,
  origin: 'https://go.example',
  deleting: deleting,
);

void main() {
  final file = Uint8List.fromList(utf8.encode('{"dshgo":2,"kind":"conversation"}'));

  (ProviderContainer, FakeHost, MemoryStore) setUpContainer([List<HostedLink> saved = const []]) {
    final host = FakeHost();
    final store = MemoryStore(saved);
    final container = ProviderContainer(
      overrides: [
        hostedLinkStoreProvider.overrideWithValue(store),
        hostedShareClientProvider.overrideWithValue(
          HostedShareClient(client: host.client, origin: 'https://go.example'),
        ),
      ],
    );
    addTearDown(container.dispose);
    return (container, host, store);
  }

  testWidgets('publish keeps the link, newest first, in secure storage', (tester) async {
    final (container, host, store) = setUpContainer([link('M000000099')]);
    final links = container.read(hostedLinksProvider.notifier);
    await links.ready;
    final made = await links.publish(file, title: '修复登录', ttl: HostedTtl.week);
    expect(container.read(hostedLinksProvider).visible.map((l) => l.id), [made.id, 'M000000099']);
    expect(store.saved.first.id, made.id);
    expect(store.saved.first.title, '修复登录');
    expect(host.blobs, contains(made.id));
  });

  testWidgets('remove hides at once, deletes after the undo window', (tester) async {
    final (container, host, store) = setUpContainer();
    final links = container.read(hostedLinksProvider.notifier);
    await links.ready;
    final made = await links.publish(file, title: 'a');
    await links.remove(made.id);
    expect(container.read(hostedLinksProvider).visible, isEmpty);
    expect(store.saved.single.deleting, isTrue);
    expect(host.blobs, contains(made.id));

    await tester.pump(HostedLinksController.undoWindow + const Duration(milliseconds: 10));
    await tester.pump();
    expect(host.blobs, isNot(contains(made.id)));
    expect(container.read(hostedLinksProvider).links, isEmpty);
    expect(store.saved, isEmpty);
  });

  testWidgets('undo inside the window keeps the link', (tester) async {
    final (container, host, store) = setUpContainer();
    final links = container.read(hostedLinksProvider.notifier);
    await links.ready;
    final made = await links.publish(file, title: 'a');
    await links.remove(made.id);
    await tester.pump(const Duration(seconds: 2));
    await links.undo(made.id);
    await tester.pump(const Duration(seconds: 10));
    expect(container.read(hostedLinksProvider).visible.single.id, made.id);
    expect(store.saved.single.deleting, isFalse);
    expect(host.blobs, contains(made.id));
    expect(host.requests.where((r) => r.method == 'DELETE'), isEmpty);
  });

  testWidgets('a delete that fails puts the link back and says so', (tester) async {
    final (container, host, _) = setUpContainer();
    final links = container.read(hostedLinksProvider.notifier);
    await links.ready;
    final made = await links.publish(file, title: 'a');
    host.failWith = 503;
    await links.remove(made.id);
    await tester.pump(HostedLinksController.undoWindow + const Duration(milliseconds: 10));
    await tester.pump();
    final state = container.read(hostedLinksProvider);
    expect(state.visible.single.id, made.id);
    expect(state.failure?.link.id, made.id);
    expect(state.failure?.error.kind, HostedShareError.unavailable);
  });

  testWidgets('deletes confirmed before a restart finish on load; old expired links drop off', (tester) async {
    final now = DateTime.now();
    final pending = link('M000000001', deleting: true);
    final expiredLongAgo = link('A000000002', expires: now.subtract(const Duration(days: 40)));
    final expiredRecently = link('A000000003', expires: now.subtract(const Duration(days: 2)));
    final (container, host, store) = setUpContainer([pending, expiredLongAgo, expiredRecently]);
    host.blobs['M000000001'] = Uint8List(40);
    host.tokens['M000000001'] = pending.deleteToken;
    await container.read(hostedLinksProvider.notifier).ready;
    await tester.pump();
    expect(host.blobs, isNot(contains('M000000001')));
    expect(container.read(hostedLinksProvider).links.map((l) => l.id), ['A000000003']);
    expect(store.saved.map((l) => l.id), ['A000000003']);
  });

  testWidgets('removing an expired link just forgets it', (tester) async {
    final gone = link('A000000004', expires: DateTime.now().subtract(const Duration(days: 1)));
    final (container, host, store) = setUpContainer([gone]);
    final links = container.read(hostedLinksProvider.notifier);
    await links.ready;
    await links.remove(gone.id);
    await tester.pump(HostedLinksController.undoWindow + const Duration(milliseconds: 10));
    await tester.pump();
    expect(host.requests.single.method, 'DELETE');
    expect(container.read(hostedLinksProvider).links, isEmpty);
    expect(store.saved, isEmpty);
  });
}

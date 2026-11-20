import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/remote/portal_link.dart';
import 'package:dsh_app/remote/secret_store.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('portal link and a late sidebar subscriber recover after relay socket loss', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final sockets = <WebSocket>[];
    var generation = 0;
    server.listen((request) async {
      expect(request.uri.path, '/__t/test/api/remote.mux');
      expect(request.headers.value(HttpHeaders.cookieHeader), 'fixture=local');
      final socket = await WebSocketTransformer.upgrade(request);
      sockets.add(socket);
      socket.listen((data) {
        final frame = jsonDecode(data as String) as Map<String, dynamic>;
        if (frame['type'] == 'open' && frame['endpoint'] == r'$events') {
          socket.add(
            jsonEncode({
              'type': 'item',
              'streamId': frame['streamId'],
              'value': {
                'type': 'ready',
                'clientId': 'relay-${++generation}',
                'host': {'home': '/home/test'},
              },
            }),
          );
        }
      });
    });
    final base = Uri.parse('http://127.0.0.1:${server.port}/__t/test/');
    final config = PortalHostConfig(id: 'relay', name: 'Relay', base: base);
    final secrets = MemorySecretStore({
      config.cookieKey: jsonEncode({
        'base': base.toString(),
        'cookies': ['fixture=local; Path=/__t/test/'],
      }),
    });
    final link = PortalHostLink(config, secrets);
    final container = ProviderContainer(
      overrides: [hostLinkProvider(const HostRef.portal('relay')).overrideWithValue(link)],
    );
    addTearDown(() async {
      container.dispose();
      await link.close();
      for (final socket in sockets) {
        await socket.close();
      }
      await server.close(force: true);
    });
    final initial = link.statuses.firstWhere((value) => value.phase == HostLinkPhase.connected);
    final client = await link.open().timeout(const Duration(seconds: 10));
    await initial;
    final first = client.mux.generation;
    expect(link.currentClient, same(client));

    final lost = link.statuses.firstWhere((value) => value.phase == HostLinkPhase.reconnecting);
    await sockets.single.close(WebSocketStatus.goingAway, 'relay stopped');
    await lost.timeout(const Duration(seconds: 10));
    expect(link.currentClient, isNull);
    final recovered = link.statuses.firstWhere((value) => value.phase == HostLinkPhase.connected);
    await recovered.timeout(const Duration(seconds: 10));
    expect(link.currentClient, same(client));
    expect(client.mux.generation, isNot(same(first)));

    const host = HostRef.portal('relay');
    final subscription = container.listen(hostLinkStatusProvider(host), (_, _) {});
    addTearDown(subscription.close);
    expect((await container.read(hostLinkStatusProvider(host).future)).phase, HostLinkPhase.connected);
    expect(await link.open(), same(client));
  });
}

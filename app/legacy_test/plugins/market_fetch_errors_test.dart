// The plugin market's own download (fetchMarketIndex): a connection that
// fails while securing it (TLS handshake, certificate) is a network problem
// with 重试, not 「目录格式有误」 (0.9.8 smoke 06n).

import 'dart:async';
import 'dart:io';

import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/plugins_state.dart';
import 'package:dsh_app/ui/plugins/plugins_screen.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../chat/support/harness.dart';
import 'support/fake_plugin_host.dart';

const _insecure = '没能和插件目录建立安全连接';

/// An HttpClient whose every request fails with [error] (the TLS layer
/// throws from `getUrl` or `close`, depending on where the handshake stops).
class _FailingClient implements HttpClient {
  _FailingClient(this.error);
  final Object error;

  @override
  Future<HttpClientRequest> getUrl(Uri url) => Future.error(error);

  @override
  void close({bool force = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _Overrides extends HttpOverrides {
  _Overrides(this.error);
  final Object error;

  @override
  HttpClient createHttpClient(SecurityContext? context) => _FailingClient(error);
}

/// HttpOverrides' own client is the real one.
class _RealHttp extends HttpOverrides {}

void main() {
  test('a server that does not speak TLS: a network error, not a format error', () async {
    // Plain HTTP where HTTPS was asked for: the handshake fails (HandshakeException).
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    server.listen((socket) {
      socket.write('HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}');
      unawaited(socket.flush().whenComplete(socket.close));
    });
    // The real HttpClient: the test binding answers every request with 400 otherwise.
    await HttpOverrides.runWithHttpOverrides(() async {
      await expectLater(
        fetchMarketIndex(Uri.parse('https://127.0.0.1:${server.port}/dsh-index.json')),
        throwsA(isA<MarketFetchException>().having((e) => e.message, 'message', _insecure)),
      );
    }, _RealHttp());
  });

  for (final error in <Object>[
    const HandshakeException('Handshake error in client'),
    const CertificateException('CERTIFICATE_VERIFY_FAILED: unable to get local issuer certificate'),
    const TlsException('unexpected TLS failure'),
  ]) {
    test('${error.runtimeType} reads as a network error', () async {
      await HttpOverrides.runZoned(() async {
        await expectLater(
          fetchMarketIndex(Uri.parse('https://api.dshfind.com/market/dsh-index.json')),
          throwsA(isA<MarketFetchException>().having((e) => e.message, 'message', _insecure)),
        );
      }, createHttpClient: _Overrides(error).createHttpClient);
    });
  }

  test('any other I/O failure on the way is a network error too', () async {
    await HttpOverrides.runZoned(() async {
      await expectLater(
        fetchMarketIndex(Uri.parse('https://api.dshfind.com/market/dsh-index.json')),
        throwsA(isA<MarketFetchException>().having((e) => e.message, 'message', '没能连上插件目录')),
      );
    }, createHttpClient: _Overrides(const OSError('Network is unreachable', 101)).createHttpClient);
  });

  testWidgets('the market tab says so and offers 重试', (tester) async {
    usePhoneView(tester);
    final carrier = FakePluginCarrier();
    carrier.handlers['pluginManager/listBundles'] = (_) => sampleBundles;
    final client = DshClient.withCarrier(carrier);
    addTearDown(client.close);
    var attempts = 0;
    await tester.pumpWidget(
      testApp(
        const PluginsScreen(initialTab: PluginsTab.market),
        overrides: [
          activeConnectionProvider.overrideWithValue(AsyncData(fakeHost(client))),
          localSafeModeProvider.overrideWithValue(false),
          marketIndexFetcherProvider.overrideWithValue((url) async {
            attempts++;
            return HttpOverrides.runZoned(
              () => fetchMarketIndex(url),
              createHttpClient: _Overrides(const HandshakeException('Handshake error in client')).createHttpClient,
            );
          }),
        ],
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('插件目录没打开'), findsOneWidget);
    expect(find.text(_insecure), findsOneWidget);
    expect(find.text('目录格式有误'), findsNothing);
    await tester.tap(find.widgetWithText(OutlinedButton, '重试'));
    await tester.pumpAndSettle();
    expect(attempts, 2);
    expect(find.text(_insecure), findsOneWidget);
  });
}

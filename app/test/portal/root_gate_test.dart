import 'package:dsh_app/remote/secret_store.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/ui/remote/remote_screen.dart';
import 'package:dsh_app/ui/shell/root_gate.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _Hosts extends HostsController {
  _Hosts(this.initial);
  final HostsState initial;
  @override
  HostsState build() => initial;
}

class _ActiveHost extends ActiveHostController {
  _ActiveHost(this.initial);
  final HostRef initial;
  @override
  HostRef build() => initial;
}

void main() {
  final config = PortalHostConfig(id: 'one', name: 'Relay', base: Uri.parse('https://example.test/__t/one/'));

  Future<void> pump(WidgetTester tester, {bool saved = true, bool expired = false}) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          hostsProvider.overrideWith(() => _Hosts(HostsState(loaded: true, portals: saved ? [config] : []))),
          activeHostProvider.overrideWith(() => _ActiveHost(saved ? const HostRef.portal('one') : HostRef.none)),
          secretStoreProvider.overrideWithValue(MemorySecretStore()),
          activeConnectionProvider.overrideWithValue(
            expired
                ? AsyncError(const HostLinkError(HostLinkErrorKind.authFailed, 'Sign in again'), StackTrace.current)
                : const AsyncData<HostConnection?>(null),
          ),
        ],
        child: MaterialApp(
          theme: buildLightTheme(),
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          supportedLocales: const [Locale('en'), Locale('zh', 'CN')],
          home: const RootGate(home: Scaffold(body: Text('chat-home'))),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('empty host list shows native portal login, never a local bootstrap', (tester) async {
    await pump(tester, saved: false);
    expect(find.byType(RemoteScreen), findsOneWidget);
    expect(find.byType(TextField), findsNWidgets(3));
    expect(find.text('chat-home'), findsNothing);
  });

  testWidgets('saved portal enters the unchanged chat shell', (tester) async {
    await pump(tester);
    expect(find.text('chat-home'), findsOneWidget);
    expect(find.byType(RemoteScreen), findsNothing);
  });

  testWidgets('expired portal credentials return to login with the relay base intact', (tester) async {
    await pump(tester, expired: true);
    expect(find.byType(RemoteScreen), findsOneWidget);
    expect(find.text('chat-home'), findsNothing);
    final fields = tester.widgetList<TextField>(find.byType(TextField)).toList();
    expect(fields.first.controller?.text, config.base.toString());
    expect(fields.last.obscureText, isTrue);
    expect(fields.last.controller?.text, isEmpty);
  });
}

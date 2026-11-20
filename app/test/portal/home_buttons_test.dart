import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/state/agents_state.dart';
import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/ui/agents/header_agents.dart';
import 'package:dsh_app/ui/agents/team_page.dart';
import 'package:dsh_app/ui/shell/brand_mark.dart';
import 'package:dsh_app/ui/shell/home_shell.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Selection extends CurrentSessionController {
  _Selection(this.initial);
  final String? initial;
  @override
  String? build() => initial;
}

class _Chat extends ChatController {
  _Chat() : super('chat');
  @override
  ChatState build() => const ChatState(title: 'Fixture chat', loading: false);
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppLocale.use(AppLocale.en);
  });
  tearDown(() => AppLocale.use(AppLocale.zhCN));

  Future<ProviderContainer> show(WidgetTester tester, {String? sessionId}) async {
    tester.view.physicalSize = const Size(402, 874);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final container = ProviderContainer(
      overrides: [
        activeConnectionProvider.overrideWithValue(const AsyncData<HostConnection?>(null)),
        currentSessionProvider.overrideWith(() => _Selection(sessionId)),
        chatProvider('chat').overrideWith(_Chat.new),
        headerAgentsProvider('chat').overrideWithValue(const HeaderAgents(team: TeamSnapshot.empty, leadId: 'chat')),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildLightTheme(),
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          supportedLocales: const [Locale('en'), Locale('zh', 'CN')],
          home: const HomeShell(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    return container;
  }

  testWidgets('home without an open chat or connection can open the sidebar', (tester) async {
    await show(tester);
    expect(find.byKey(const ValueKey('chat-new-chat')), findsNothing);
    expect(find.byType(HeaderAgentsKey), findsNothing);
    await tester.tap(find.byKey(const ValueKey('chat-menu')));
    await tester.pumpAndSettle();
    expect(find.byType(BrandLockup).hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('new chat button returns an open conversation to the home composer', (tester) async {
    final container = await show(tester, sessionId: 'chat');
    await tester.tap(find.byKey(const ValueKey('chat-new-chat')));
    await tester.pumpAndSettle();
    expect(container.read(currentSessionProvider), isNull);
    expect(find.byKey(const ValueKey('chat-menu')).hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('agent team button opens the native team page even after connection loss', (tester) async {
    await show(tester, sessionId: 'chat');
    await tester.tap(find.byType(HeaderAgentsKey));
    await tester.pumpAndSettle();
    expect(find.byType(TeamPage), findsOneWidget);
    expect(find.text(appL10n.botsAgentTeam), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('sidebar artwork grows without enlarging its wordmark', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: Center(child: BrandLockup(height: 19))),
      ),
    );
    final logo = tester.widget<BrandMark>(find.byType(BrandMark));
    final label = tester.widget<Text>(find.text('YuRemote'));
    expect(logo.size, closeTo(19 * 0.95 * 1.25 * 1.4, 0.001));
    expect(label.style?.fontSize, 19 * 0.95);
    expect(tester.takeException(), isNull);
  });
}

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/state/engine_settings_state.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/ui/chat/chat_screen.dart';
import 'package:dsh_app/ui/chat/empty_actions.dart';
import 'package:dsh_app/ui/chat/empty_state.dart';
import 'package:dsh_app/ui/chat/new_chat_options.dart';
import 'package:dsh_app/ui/features/feature_catalog.dart';
import 'package:dsh_app/ui/settings/interface_page.dart';
import 'package:dsh_app/ui/settings/search/settings_search.dart';
import 'package:dsh_app/ui/settings/settings_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../chat/support/harness.dart';

const _preference = 'chat_suggestions';

class _NoEngineSettings extends EngineSettingsController {
  @override
  Future<EngineSettings?> build() async => null;
}

Future<void> _loaded(WidgetTester tester, ProviderContainer container) async {
  for (var i = 0; i < 20 && !container.read(settingsProvider).loaded; i++) {
    await tester.pump();
  }
  expect(container.read(settingsProvider).loaded, isTrue);
  await pumpFrames(tester);
}

Future<ProviderContainer> _pumpChat(WidgetTester tester) async {
  usePhoneView(tester);
  final harness = ChatHarness();
  await tester.pumpWidget(
    testApp(
      const ChatScreen(),
      overrides: [
        for (final override in harness.overrides)
          if (override.origin != settingsProvider) override,
        engineSettingsProvider.overrideWith(_NoEngineSettings.new),
      ],
    ),
  );
  final container = ProviderScope.containerOf(tester.element(find.byType(ChatScreen)));
  await _loaded(tester, container);
  return container;
}

void _expectCards(bool visible) {
  expect(find.byType(SuggestionCards), visible ? findsOneWidget : findsNothing);
  for (final suggestion in defaultSuggestions) {
    expect(find.text(suggestion.label), visible ? findsOneWidget : findsNothing);
  }
  expect(find.byType(TipLine), findsOneWidget);
  expect(find.byType(NewChatOptions), findsOneWidget);
  expect(find.text(appL10n.viewEmptySubtitle), findsOneWidget);
}

Finder _switch() => find.descendant(of: find.widgetWithText(SettingsSwitchTile, '聊天建议'), matching: find.byType(Switch));

Future<void> _openSettings(WidgetTester tester) async {
  Navigator.of(tester.element(find.byType(ChatScreen)))
      .push(MaterialPageRoute<void>(builder: (_) => const InterfacePage()));
  await pumpFrames(tester);
  await tester.ensureVisible(_switch());
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  testWidgets('default keeps all four suggestions without writing a preference', (tester) async {
    await _pumpChat(tester);
    _expectCards(true);
    expect((await SharedPreferences.getInstance()).containsKey(_preference), isFalse);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('stored off hides only suggestions after loading preferences', (tester) async {
    SharedPreferences.setMockInitialValues({_preference: false});
    final container = await _pumpChat(tester);
    _expectCards(false);
    // Other preferences still copy the current choice forward.
    await container.read(settingsProvider.notifier).setThemeMode(ThemeMode.dark);
    await pumpFrames(tester);
    _expectCards(false);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('interface switch updates chat, persists, reloads, and can be enabled again', (tester) async {
    final container = await _pumpChat(tester);
    _expectCards(true);
    await _openSettings(tester);
    expect(find.text('起始页'), findsOneWidget);
    expect(tester.widget<Switch>(_switch()).value, isTrue);
    await tester.tap(_switch());
    await pumpFrames(tester);
    expect(tester.widget<Switch>(_switch()).value, isFalse);
    expect((await SharedPreferences.getInstance()).getBool(_preference), isFalse);
    Navigator.of(tester.element(find.byType(InterfacePage))).pop();
    await pumpFrames(tester);
    _expectCards(false);

    container.invalidate(settingsProvider);
    await _loaded(tester, container);
    _expectCards(false);
    await _openSettings(tester);
    expect(tester.widget<Switch>(_switch()).value, isFalse);
    await tester.tap(_switch());
    await pumpFrames(tester);
    expect((await SharedPreferences.getInstance()).getBool(_preference), isTrue);
    Navigator.of(tester.element(find.byType(InterfacePage))).pop();
    await pumpFrames(tester);
    _expectCards(true);
    await tester.pumpWidget(const SizedBox());
  });

  test('Chinese and English searches find the interface row', () {
    final zh = lookupL10n(AppLocale.zhCN);
    final en = lookupL10n(AppLocale.en);
    for (final query in ['聊天建议', '起始页', 'chat suggestions', 'start page']) {
      final hits = searchSettings(query, spots: SettingsIndex.spots, features: featureSections, zh: zh, en: en);
      final spot = hits.firstWhere((hit) => hit.spot?.id == 'chat-suggestions').spot!;
      expect(spot.page, SettingsPageId.interface);
    }
  });
}

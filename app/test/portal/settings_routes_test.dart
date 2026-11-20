import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/ui/settings/index/settings_pages.dart';
import 'package:dsh_app/ui/settings/search/settings_search_page.dart';
import 'package:dsh_app/ui/settings/settings_screen.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppLocale.use(AppLocale.en);
  });
  tearDown(() => AppLocale.use(AppLocale.zhCN));

  test('retained settings and their links resolve', () {
    for (final id in remoteSettingsPages) {
      expect(() => settingsPage(id), returnsNormally);
      for (final link in SettingsIndex.page(id).links) {
        expect(settingsPageForLink(link), isNotNull, reason: link);
      }
    }
  });

  test('removed settings reject direct routes and deep links', () {
    for (final id in SettingsPageId.values.where((id) => !remoteSettingsPages.contains(id))) {
      expect(() => settingsPage(id), throwsArgumentError);
      for (final link in SettingsIndex.page(id).links) {
        expect(settingsPageForLink(link), isNull, reason: link);
      }
    }
    expect(settingsPageForLink('not-a-settings-page'), isNull);
    expect(settingsPageForLink(''), isNull);
  });

  testWidgets('settings hub contains remote controls without account or removed features', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(theme: buildLightTheme(), home: const SettingsScreen()),
      ),
    );
    await tester.pumpAndSettle();
    for (final id in [SettingsPageId.models, SettingsPageId.permission, SettingsPageId.agentPresets]) {
      expect(find.text(SettingsIndex.page(id).title(appL10n)), findsOneWidget);
    }
    for (final id in [
      SettingsPageId.phone,
      SettingsPageId.webSearch,
      SettingsPageId.pets,
      SettingsPageId.voice,
      SettingsPageId.engine,
      SettingsPageId.diagnostics,
      SettingsPageId.account,
      SettingsPageId.plugins,
    ]) {
      expect(find.text(SettingsIndex.page(id).title(appL10n)), findsNothing);
    }
  });

  testWidgets('search matches retained settings and handles no matches', (tester) async {
    await tester.pumpWidget(MaterialApp(theme: buildLightTheme(), home: const SettingsSearchPage()));
    await tester.pumpAndSettle();
    final title = SettingsIndex.page(SettingsPageId.about).title(appL10n);
    await tester.enterText(find.byType(TextField), title);
    await tester.pumpAndSettle();
    expect(find.text(title), findsWidgets);
    await tester.enterText(find.byType(TextField), 'no-such-setting-12345');
    await tester.pumpAndSettle();
    expect(find.text(title), findsNothing);
    expect(find.text(appL10n.searchNoResults), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

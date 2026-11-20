// First run with only a custom provider: 「其他模型渠道」 on the connect step
// opens the add form; saving finishes the step and stops it coming back.

import 'package:dsh_app/state/account_state.dart';
import 'package:dsh_app/state/onboarding_state.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/ui/onboarding/connect_page.dart';
import 'package:dsh_app/ui/providers/provider_form_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../shell/golden_harness.dart' show goldenApp, loadGoldenFonts;
import 'support.dart';

void main() {
  testWidgets('其他模型渠道 → add form → save finishes the connect step', (tester) async {
    await tester.runAsync(loadGoldenFonts);
    tester.view.devicePixelRatio = 2;
    tester.view.physicalSize = const Size(390 * 2, 1400 * 2);
    addTearDown(tester.view.reset);
    final backend = FakeProviderBackend();
    final vault = MemoryProviderKeyVault();
    var done = 0;
    await tester.pumpWidget(
      goldenApp(
        home: ConnectPage(onDone: () => done++),
        brightness: Brightness.light,
        overrides: [
          ...providerOverrides(backend, vault: vault, settings: const AppSettings(loaded: true)),
          accountEngineStarterProvider.overrideWithValue(() async {}),
        ],
      ),
    );
    await settle(tester);

    // The two quiet ways on share the row equally.
    final other = tester.getRect(find.widgetWithText(TextButton, '其他模型渠道'));
    final later = tester.getRect(find.widgetWithText(TextButton, '稍后设置'));
    expect(other.width, moreOrLessEquals(later.width, epsilon: 0.6));
    expect(other.center.dy, moreOrLessEquals(later.center.dy, epsilon: 0.6));

    await tester.tap(find.text('其他模型渠道'));
    await settle(tester);
    expect(find.byType(ProviderFormPage), findsOneWidget);

    await tester.enterText(find.byType(TextField).at(1), 'https://api.siliconflow.cn/v1');
    await tester.enterText(find.byType(TextField).at(2), 'sk-sf-1');
    await tester.tap(find.text('手动添加'));
    await settle(tester);
    await tester.enterText(
      find.descendant(of: find.byType(AlertDialog), matching: find.byType(TextField)),
      'deepseek-ai/DeepSeek-V3.2',
    );
    await tester.tap(find.widgetWithText(FilledButton, '添加'));
    await settle(tester);
    await tester.tap(find.text('保存'));
    await settle(tester);

    expect(backend.profiles.single.route, 'custom-siliconflow');
    expect(vault.data, {'custom-siliconflow': 'sk-sf-1'});
    expect(done, 1);
    final container = ProviderScope.containerOf(tester.element(find.byType(ConnectPage)));
    expect(container.read(onboardingPrefsProvider).keySkipped, isTrue);
  });
}

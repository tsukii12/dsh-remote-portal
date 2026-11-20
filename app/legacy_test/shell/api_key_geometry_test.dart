import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/ui/onboarding/api_key_page.dart';
import 'package:dsh_app/ui/onboarding/onboarding_scaffold.dart';
import 'package:dsh_app/ui/shell/page_frame.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'golden_harness.dart';

void main() {
  testWidgets('settings and onboarding share the secondary-page back rectangle', (tester) async {
    usePhoneSurface(tester);
    Future<Rect> pump(Widget page) async {
      await tester.pumpWidget(
        goldenApp(
          home: page,
          brightness: Brightness.light,
          overrides: [settingsProvider.overrideWith(() => FakeSettings(const AppSettings(loaded: true)))],
        ),
      );
      await tester.pump();
      return tester.getRect(find.byTooltip('返回'));
    }

    final expected = await pump(AppPage.list(title: '基准', children: const []));
    final settings = await pump(const ApiKeyPage(onboarding: false));
    expect(settings, expected);
    expect(settings, const Rect.fromLTWH(12, 38, 44, 44));
    final onboarding = await pump(OnboardingProgress(step: 3, steps: 3, child: ApiKeyPage(onBack: () {})));
    expect(onboarding, expected);
    final bar = tester.getRect(find.byType(OnboardingStepBar));
    expect(bar.center.dx, 390 / 2);
    expect(bar.center.dy, onboarding.center.dy);
    expect(tester.takeException(), isNull);
  });
}

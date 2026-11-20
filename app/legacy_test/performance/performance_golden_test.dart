import 'package:dsh_app/app.dart';
import 'package:dsh_app/performance/performance_state.dart';
import 'package:dsh_app/state/locale_state.dart';
import 'package:dsh_app/ui/settings/performance_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support.dart';

class _Language extends AppLanguageController {
  _Language(this.language);
  final AppLanguage language;
  @override
  AppLanguage build() => language;
}

void main() {
  for (final brightness in Brightness.values) {
    for (final language in [AppLanguage.zh, AppLanguage.en]) {
      testWidgets('performance ${brightness.name} ${language.name}', (tester) async {
        SharedPreferences.setMockInitialValues({'performance.mode': 'light'});
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(390, 844);
        tester.platformDispatcher.platformBrightnessTestValue = brightness;
        addTearDown(tester.view.reset);
        addTearDown(tester.platformDispatcher.clearAllTestValues);
        final channel = FakePerformanceChannel(Future.value(snapshot(DeviceTier.low)));
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              performanceChannelProvider.overrideWithValue(channel),
              appLanguageProvider.overrideWith(() => _Language(language)),
              noUiJson,
            ],
            child: const DshApp(home: PerformancePage()),
          ),
        );
        await tester.pumpAndSettle();
        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile('goldens/performance_${brightness.name}_${language.name}.png'),
        );
        await tester.pumpWidget(const SizedBox.shrink());
        await channel.events.close();
      });
    }
  }
}

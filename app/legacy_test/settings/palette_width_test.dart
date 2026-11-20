import 'package:dsh_app/app.dart';
import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/state/appearance_state.dart';
import 'package:dsh_app/state/locale_state.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/ui/onboarding/appearance_step.dart';
import 'package:dsh_app/ui/settings/appearance/appearance_page.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../shell/golden_harness.dart' show FakeSettings;

class _NoWallpaper extends DynamicColorChannel {
  const _NoWallpaper();

  @override
  Future<Color?> wallpaperAccent() async => null;
}

Future<ProviderContainer> _pump(
  WidgetTester tester, {
  required double width,
  required double scale,
  required bool english,
  Widget home = const AppearancePage(),
}) async {
  SharedPreferences.setMockInitialValues({});
  AppLanguageController.initial = english ? AppLanguage.en : AppLanguage.zh;
  AppLocale.use(english ? AppLocale.en : AppLocale.zhCN);
  addTearDown(() {
    AppLanguageController.initial = AppLanguage.zh;
    AppLocale.use(AppLocale.zhCN);
  });
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 844);
  addTearDown(tester.view.reset);
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  final container = ProviderContainer(
    overrides: [
      settingsProvider.overrideWith(() => FakeSettings(const AppSettings(loaded: true))),
      dynamicColorChannelProvider.overrideWithValue(const _NoWallpaper()),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: DshApp(home: home),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

Finder _choice(String label) => find.bySemanticsLabel(appL10n.pluginsColorLabel(label));

List<Rect> _rings(WidgetTester tester, {required bool custom}) {
  final card = tester.getRect(find.ancestor(of: find.byType(PalettePicker), matching: find.byType(GlassSurface)).first);
  final rings = [
    for (final label in [...AppAccent.presets.map((p) => p.label), if (custom) appL10n.pluginsCustomColor])
      tester.getRect(find.descendant(of: _choice(label), matching: find.byType(CustomPaint)).first),
  ];
  for (final ring in rings) {
    expect(ring.left, greaterThanOrEqualTo(card.left + PickerGrid.inset - 0.01));
    expect(ring.right, lessThanOrEqualTo(card.right - PickerGrid.inset + 0.01));
    expect(ring.top, greaterThanOrEqualTo(card.top));
    expect(ring.bottom, lessThanOrEqualTo(card.bottom));
    expect(
      ring.width,
      moreOrLessEquals(PalettePicker.disc + 2 * (PalettePicker.ringGap + PalettePicker.ringWidth), epsilon: 0.01),
    );
  }
  for (var i = 0; i < rings.length; i++) {
    for (var j = i + 1; j < rings.length; j++) {
      expect(rings[i].overlaps(rings[j]), false, reason: 'swatches $i and $j must stay separately tappable');
    }
  }
  return rings;
}

void main() {
  for (final english in [false, true]) {
    final language = english ? 'en' : 'zh';
    for (final (width, scale) in [(320.0, 1.0), (320.0, 1.3), (337.0, 1.3), (390.0, 1.3)]) {
      testWidgets('appearance palette fits and selects at $width/$scale ($language)', (tester) async {
        final container = await _pump(tester, width: width, scale: scale, english: english);
        expect(tester.takeException(), isNull);
        _rings(tester, custom: true);

        final preset = AppAccent.presets.last;
        await tester.tap(_choice(preset.label));
        await tester.pumpAndSettle();
        expect(container.read(appearanceProvider).presetId, preset.id);
        await tester.tap(_choice(appL10n.pluginsCustomColor));
        await tester.pumpAndSettle();
        expect(container.read(appearanceProvider).source, AccentSource.custom);
        expect(find.byType(HueSlider), findsOneWidget);
        expect(tester.takeException(), isNull);
        _rings(tester, custom: true);
      });
    }

    testWidgets('first-run six-palette row keeps its fixed height at 320/1.3 ($language)', (tester) async {
      var completed = false;
      final container = await _pump(
        tester,
        width: 320,
        scale: 1.3,
        english: english,
        home: AppearanceStepPage(onDone: () => completed = true),
      );
      expect(tester.takeException(), isNull);
      final rings = _rings(tester, custom: false);
      expect(rings.map((r) => r.center.dy).toSet(), hasLength(1));
      expect(_choice(appL10n.pluginsCustomColor), findsNothing);
      final preset = AppAccent.presets.last;
      await tester.tap(_choice(preset.label));
      await tester.pumpAndSettle();
      expect(container.read(appearanceProvider).presetId, preset.id);
      await tester.tap(find.text(appL10n.commonContinue));
      expect(completed, true);
      expect(tester.takeException(), isNull);
    });
  }
}

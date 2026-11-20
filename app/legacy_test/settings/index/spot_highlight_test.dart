// A page opened for one row (a search result, a row link) scrolls the row a
// third of the way down the screen, even when the lazy list hasn't built it
// yet, and flashes its background twice; the row keeps its size the whole
// time. With animations off the highlight holds still for a second.

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/links/page_links.dart';
import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/ui/settings/index/settings_pages.dart';
import 'package:dsh_app/ui/settings/index/spot_anchor.dart';
import 'package:dsh_app/ui/settings/settings_screen.dart';
import 'package:dsh_app/ui/settings/settings_widgets.dart';
import 'package:dsh_app/ui/shell/page_frame.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../shell/golden_harness.dart';

final _target = SettingSpot('test-target', page: SettingsPageId.hub, title: (_) => '目标');

Widget _longPage() => AppPage.list(
  title: '长页',
  children: [
    for (var g = 0; g < 8; g++)
      SettingsSection(
        title: '分组 $g',
        children: [
          for (var i = 0; i < 5; i++)
            if (g == 6 && i == 2)
              SettingsSwitchTile(spot: _target, value: false, onChanged: (_) {})
            else
              SettingsTile(title: '行 $g-$i', onTap: () {}),
        ],
      ),
  ],
);

Future<void> _pump(WidgetTester tester, Widget home, {bool reduced = false}) async {
  tester.view.devicePixelRatio = 2;
  tester.view.physicalSize = const Size(390 * 2, 844 * 2);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        theme: buildLightTheme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
          child: child!,
        ),
        home: home,
      ),
    ),
  );
}

/// The highlight's colour under [id] (null: none).
Color? _highlight(WidgetTester tester, String id) {
  final box = tester.widget<DecoratedBox>(
    find.descendant(of: find.byKey(SpotKey(id)), matching: find.byType(DecoratedBox)).first,
  );
  return (box.decoration as BoxDecoration).color;
}

void main() {
  testWidgets('a row past the first screen is scrolled to a third of the way down and flashes twice', (tester) async {
    await _pump(tester, SpotFocus(target: _target.id, child: _longPage()));
    // Not built at first: the page walks down until it is.
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    await tester.pump(const Duration(milliseconds: 300));
    final row = find.byKey(SpotKey(_target.id));
    expect(row, findsOneWidget);
    final rect = tester.getRect(row);
    const screen = 844.0;
    expect(rect.top, greaterThan(0));
    expect(rect.bottom, lessThan(screen));
    expect(rect.top, moreOrLessEquals(screen / 3, epsilon: 60), reason: 'about a third of the way down');
    expect(rect.height, SettingsMetrics.rowHeight);

    // Twice 0 → 0.5 → 0 over 1.6 s; the row's size never moves.
    final peaks = <double>[];
    var last = 0.0;
    var rising = true;
    for (var t = 0; t < 1700; t += 50) {
      await tester.pump(const Duration(milliseconds: 50));
      expect(tester.getRect(row).height, SettingsMetrics.rowHeight);
      final a = _highlight(tester, _target.id)?.a ?? 0;
      if (rising && a < last) {
        peaks.add(last);
        rising = false;
      } else if (!rising && a > last) {
        rising = true;
      }
      last = a;
    }
    expect(peaks, hasLength(2));
    for (final p in peaks) {
      expect(p, moreOrLessEquals(SpotAnchor.peak, epsilon: 0.06));
    }
    expect(_highlight(tester, _target.id), isNull, reason: 'gone after the flash');
  });

  testWidgets('animations off: a still highlight for a second, then none', (tester) async {
    await _pump(tester, SpotFocus(target: _target.id, child: _longPage()), reduced: true);
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    final peak = Theme.of(tester.element(find.byKey(SpotKey(_target.id)))).colorScheme.primaryContainer;
    expect(_highlight(tester, _target.id), peak.withValues(alpha: SpotAnchor.peak));
    await tester.pump(const Duration(milliseconds: 500));
    expect(_highlight(tester, _target.id), peak.withValues(alpha: SpotAnchor.peak), reason: 'no fading in between');
    await tester.pump(const Duration(milliseconds: 600));
    expect(_highlight(tester, _target.id), isNull);
  });

  testWidgets('a page opened plainly highlights nothing', (tester) async {
    await _pump(tester, _longPage());
    await tester.pump(const Duration(milliseconds: 600));
    expect(tester.getRect(find.text('行 0-0')).top, lessThan(400), reason: 'stays at the top');
  });

  testWidgets('a row link opens the hub near its end', (tester) async {
    usePhoneSurface(tester);
    final page = pageForId('chat-text-size', null);
    expect(page, isA<SpotFocus>());
    // The hub's last group, by its spot.
    await tester.pumpWidget(
      goldenApp(
        home: spotPage(Spots.community),
        brightness: Brightness.light,
        overrides: [
          localRuntimeProvider.overrideWith(
            () => FakeRuntime(const LocalRuntimeState(loaded: true, status: runningStatus)),
          ),
          settingsProvider.overrideWith(() => FakeSettings(const AppSettings(loaded: true))),
        ],
      ),
    );
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.byType(SettingsScreen), findsOneWidget);
    final rect = tester.getRect(find.byKey(SpotKey(Spots.community.id)));
    expect(rect.top, greaterThan(0));
    expect(rect.bottom, lessThan(844));
    expect(find.text(appL10n.hubSettingsCommunity), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
  });
}

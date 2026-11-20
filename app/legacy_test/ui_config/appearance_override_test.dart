import 'dart:ui' as ui;

import 'package:dsh_app/app.dart';
import 'package:dsh_app/state/appearance_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/ui/settings/appearance/appearance_page.dart';
import 'package:dsh_app/ui_config/ui_config.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../shell/golden_harness.dart' show FakeSettings;
import 'support.dart';

class _NoWallpaper extends DynamicColorChannel {
  const _NoWallpaper();

  @override
  Future<Color?> wallpaperAccent() async => null;
}

Future<ProviderContainer> _pump(WidgetTester tester, Map<HostRef, UiConfigSource> sources) async {
  tester.view.devicePixelRatio = 2;
  tester.view.physicalSize = const Size(390 * 2, 844 * 2);
  addTearDown(tester.view.reset);
  tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
  addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
  final container = ProviderContainer(
    overrides: [
      ...sourceOverrides(sources),
      settingsProvider.overrideWith(() => FakeSettings(const AppSettings(loaded: true))),
      dynamicColorChannelProvider.overrideWithValue(const _NoWallpaper()),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const DshApp(home: Scaffold(body: AppearanceEntryTile())),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

Future<void> _open(WidgetTester tester) async {
  await tester.tap(find.byType(AppearanceEntryTile));
  await tester.pumpAndSettle();
  expect(find.byType(AppearancePage), findsOneWidget);
}

Finder _mode(String label) => find.descendant(of: find.byType(ThemeModePicker), matching: find.bySemanticsLabel(label));

bool _selected(WidgetTester tester, String label) =>
    tester.getSemantics(_mode(label)).getSemanticsData().flagsCollection.isSelected == ui.Tristate.isTrue;

Brightness _brightness(WidgetTester tester) => Theme.of(tester.element(find.byType(ThemeModePicker))).brightness;

Future<void> _restore(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('from-ui-json-theme.mode')));
  await tester.pumpAndSettle();
  expect(find.text('/theme/mode'), findsOneWidget);
  await tester.tap(find.byKey(const ValueKey('ui-json-restore-default')));
  await tester.pumpAndSettle();
  expect(find.byType(UiOverrideSheet), findsNothing);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('ordinary appearance controls still select light, dark, and system', (tester) async {
    final container = await _pump(tester, {});
    await _open(tester);
    expect(find.byKey(const ValueKey('from-ui-json-theme.mode')), findsNothing);

    await tester.tap(_mode('深色'));
    await tester.pumpAndSettle();
    expect(container.read(settingsProvider).themeMode, ThemeMode.dark);
    expect(_brightness(tester), Brightness.dark);
    expect(_selected(tester, '深色'), isTrue);

    await tester.tap(_mode('跟随系统'));
    await tester.pumpAndSettle();
    expect(container.read(settingsProvider).themeMode, ThemeMode.system);
    expect(_brightness(tester), Brightness.light);
  });

  testWidgets('appearance entry names the active file mode instead of the saved mode', (tester) async {
    final source = FakeUiSource();
    final container = await _pump(tester, {HostRef.none: source});
    source.text('{"version":1,"theme":{"mode":"dark"}}');
    await tester.pumpAndSettle();

    expect(container.read(settingsProvider).themeMode, ThemeMode.system);
    expect(find.descendant(of: find.byType(AppearanceEntryTile), matching: find.text('雾蓝 · 深色')), findsOneWidget);
  });

  testWidgets('mode selection follows the file, including its removal', (tester) async {
    final source = FakeUiSource();
    await _pump(tester, {HostRef.none: source});
    source.text('{"version":1,"theme":{"mode":"dark"}}');
    await tester.pumpAndSettle();
    await _open(tester);

    expect(_brightness(tester), Brightness.dark);
    expect(_selected(tester, '深色'), isTrue);
    expect(_selected(tester, '跟随系统'), isFalse);

    source.push(const UiConfigAbsent());
    await tester.pumpAndSettle();
    expect(_selected(tester, '跟随系统'), isTrue);
    expect(find.byKey(const ValueKey('from-ui-json-theme.mode')), findsNothing);
    await tester.tap(_mode('深色'));
    await tester.pumpAndSettle();
    expect(_brightness(tester), Brightness.dark);
  });

  testWidgets('file-controlled mode cannot silently change the ineffective saved setting', (tester) async {
    final source = FakeUiSource();
    final container = await _pump(tester, {HostRef.none: source});
    source.text('{"version":1,"theme":{"mode":"dark"}}');
    await tester.pumpAndSettle();
    await _open(tester);

    // This preview is intentionally disabled while the file decides.
    await tester.tapAt(tester.getCenter(_mode('浅色')));
    await tester.pumpAndSettle();
    expect(container.read(settingsProvider).themeMode, ThemeMode.system);
    expect(_brightness(tester), Brightness.dark);
    expect(find.byKey(const ValueKey('from-ui-json-theme.mode')), findsOneWidget);
    expect(tester.getSemantics(_mode('浅色')).getSemanticsData().flagsCollection.isEnabled, ui.Tristate.isFalse);
  });

  testWidgets('source sheet restores manual choice without rewriting the file or other overrides', (tester) async {
    final source = FakeUiSource();
    final container = await _pump(tester, {HostRef.none: source});
    source.text('{"version":1,"theme":{"mode":"dark"},"density":"compact"}');
    await tester.pumpAndSettle();
    await _open(tester);
    await _restore(tester);

    expect(_brightness(tester), Brightness.light);
    expect(find.byKey(const ValueKey('from-ui-json-theme.mode')), findsNothing);
    expect(container.read(uiConfigProvider(HostRef.none)).load!.config.themeMode, UiThemeMode.dark);
    expect(container.read(uiOverridesProvider).fromUiJson(UiSettingKey.density), isTrue);
    await tester.tap(_mode('深色'));
    await tester.pumpAndSettle();
    expect(container.read(settingsProvider).themeMode, ThemeMode.dark);
    expect(_brightness(tester), Brightness.dark);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(UiIgnoresController.prefsKey), contains('theme.mode'));

    source.text('{"version":1,"theme":{"mode":"light"},"density":"compact"}');
    await tester.pumpAndSettle();
    expect(_brightness(tester), Brightness.light);
    expect(_selected(tester, '浅色'), isTrue);
    expect(find.byKey(const ValueKey('from-ui-json-theme.mode')), findsOneWidget);
  });

  testWidgets('restoring one host does not unlock the same file value on another host', (tester) async {
    const remote = HostRef.portal('synthetic-pc');
    final local = FakeUiSource();
    final other = FakeUiSource();
    final container = await _pump(tester, {HostRef.none: local, remote: other});
    local.text('{"version":1,"theme":{"mode":"dark"}}');
    await tester.pumpAndSettle();
    await _open(tester);
    await _restore(tester);
    expect(_brightness(tester), Brightness.light);

    container.read(activeHostProvider.notifier).select(remote);
    other.text('{"version":1,"theme":{"mode":"dark"}}');
    await tester.pumpAndSettle();
    expect(_brightness(tester), Brightness.dark);
    expect(_selected(tester, '深色'), isTrue);
    expect(find.byKey(const ValueKey('from-ui-json-theme.mode')), findsOneWidget);

    container.read(activeHostProvider.notifier).select(HostRef.none);
    await tester.pumpAndSettle();
    expect(_brightness(tester), Brightness.light);
    expect(_selected(tester, '跟随系统'), isTrue);
    expect(find.byKey(const ValueKey('from-ui-json-theme.mode')), findsNothing);
  });
}

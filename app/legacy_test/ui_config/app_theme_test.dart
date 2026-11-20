// Exercise the real app entry point: accepting theme.mode in the parser is
// insufficient unless MaterialApp also consumes the merged active-host mode.
import 'package:dsh_app/app.dart';
import 'package:dsh_app/state/appearance_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/settings_state.dart';
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

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<ProviderContainer> pump(WidgetTester tester, Map<HostRef, UiConfigSource> sources) async {
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
        child: const DshApp(home: Scaffold(body: Text('theme target'))),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  Brightness brightness(WidgetTester tester) => Theme.of(tester.element(find.text('theme target'))).brightness;

  testWidgets('file mode changes native appearance; removing it restores the saved setting', (tester) async {
    final local = FakeUiSource();
    final container = await pump(tester, {HostRef.none: local});
    expect(brightness(tester), Brightness.light);

    local.text('{"version":1,"theme":{"mode":"dark"}}');
    await tester.pumpAndSettle();
    expect(brightness(tester), Brightness.dark);
    expect(container.read(settingsProvider).themeMode, ThemeMode.system);

    local.push(const UiConfigAbsent());
    await tester.pumpAndSettle();
    expect(brightness(tester), Brightness.light);

    await container.read(settingsProvider.notifier).setThemeMode(ThemeMode.dark);
    await tester.pumpAndSettle();
    expect(brightness(tester), Brightness.dark);
    local.text('{"version":1,"theme":{"mode":"system"}}');
    await tester.pumpAndSettle();
    expect(brightness(tester), Brightness.light);
    expect(container.read(settingsProvider).themeMode, ThemeMode.dark);
  });

  testWidgets('restoring the default and switching hosts both update native appearance', (tester) async {
    const remote = HostRef.portal('pc');
    final local = FakeUiSource();
    final container = await pump(tester, {HostRef.none: local});
    local.text('{"version":1,"theme":{"mode":"dark"}}');
    await tester.pumpAndSettle();
    expect(brightness(tester), Brightness.dark);

    await restoreUiDefault(
      container.read(uiOverridesProvider),
      container.read(uiIgnoresProvider.notifier),
      UiSettingKey.themeMode,
    );
    await tester.pumpAndSettle();
    expect(brightness(tester), Brightness.light);

    // A changed file value applies again; changing to an unconfigured host
    // must restore that host's ordinary app setting.
    local.text('{"version":1,"theme":{"mode":"light"}}');
    await tester.pumpAndSettle();
    local.text('{"version":1,"theme":{"mode":"dark"}}');
    await tester.pumpAndSettle();
    expect(brightness(tester), Brightness.dark);
    container.read(activeHostProvider.notifier).select(remote);
    await tester.pumpAndSettle();
    expect(brightness(tester), Brightness.light);
    container.read(activeHostProvider.notifier).select(HostRef.none);
    await tester.pumpAndSettle();
    expect(brightness(tester), Brightness.dark);
  });
}

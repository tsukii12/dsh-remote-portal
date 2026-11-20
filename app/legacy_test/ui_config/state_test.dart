// ui.json as app state: per-host loads, reloads, the last good config on a
// fatal read, the cold-start cache, 「恢复默认」 and the merged values with
// their source. Plus the real local wiring end to end (temp rootfs + inotify).

import 'dart:io';

import 'package:dsh_app/plugins/seams/seat_models.dart' show SeatOverride, SeatOverrides;
import 'package:dsh_app/runtime/runtime_bridge.dart';
import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/state/appearance_state.dart';
import 'package:dsh_app/state/drawer_view_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/ui/theme/accent.dart';
import 'package:dsh_app/ui_config/ui_config.dart';
import 'package:flutter/material.dart' show Color, ThemeMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support.dart';

const _ssh = HostRef.portal('pc');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  ProviderContainer container(Map<HostRef, UiConfigSource> sources, {HostRef active = HostRef.none}) {
    final c = ProviderContainer(overrides: sourceOverrides(sources, active: active));
    addTearDown(c.dispose);
    return c;
  }

  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 20));

  test('a read becomes the active host\'s overrides; a new text reloads', () async {
    final local = FakeUiSource();
    final c = container({HostRef.none: local});
    c.listen(uiOverridesProvider, (_, _) {});
    expect(c.read(uiOverridesProvider).config, UiConfig.empty);

    local.text('{"version": 1, "density": "compact", "hide": ["whaleTail"]}');
    await settle();
    final o = c.read(uiOverridesProvider);
    expect(o.config.density, UiDensity.compact);
    expect(o.hides(UiHideItem.whaleTail), isTrue);
    expect(c.read(uiConfigProvider(HostRef.none)).availability, UiConfigAvailability.live);

    local.text('{"version": 1, "density": "comfortable"}');
    await settle();
    expect(c.read(uiOverridesProvider).config.density, UiDensity.comfortable);
    expect(c.read(uiHiddenProvider(UiHideItem.whaleTail)), isFalse);
  });

  test('a fatal read keeps the last good configuration and says so', () async {
    final local = FakeUiSource();
    final c = container({HostRef.none: local});
    c.listen(uiOverridesProvider, (_, _) {});
    local.text('{"version": 1, "density": "compact"}');
    await settle();
    local.text('{"version": 1, "density": "comfortable",}');
    await settle();
    final load = c.read(uiConfigProvider(HostRef.none)).load!;
    expect(load.fatal, isTrue);
    expect(load.fromLastGood, isTrue);
    expect(c.read(uiOverridesProvider).config.density, UiDensity.compact);

    local.push(const UiConfigBroken('文件超过 64 KiB'));
    await settle();
    expect(c.read(uiOverridesProvider).config.density, UiDensity.compact);
    expect(c.read(uiConfigProvider(HostRef.none)).load!.issues.single.message, '文件超过 64 KiB');
  });

  test('deleting the file clears it, and forgets the cache', () async {
    final local = FakeUiSource();
    final c = container({HostRef.none: local});
    c.listen(uiOverridesProvider, (_, _) {});
    local.text('{"version": 1, "density": "compact"}');
    await settle();
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(UiConfigController.cacheKey(HostRef.none)), contains('compact'));
    local.push(const UiConfigAbsent());
    await settle();
    expect(c.read(uiConfigProvider(HostRef.none)).load, isNull);
    expect(c.read(uiOverridesProvider).config, UiConfig.empty);
    expect(prefs.getString(UiConfigController.cacheKey(HostRef.none)), isNull);
  });

  test('cold start: the remembered config applies before the host is reachable', () async {
    SharedPreferences.setMockInitialValues({
      UiConfigController.cacheKey(_ssh): '{"version": 1, "theme": {"mode": "dark"}}',
    });
    final c = container({}, active: _ssh);
    c.listen(uiOverridesProvider, (_, _) {});
    await settle();
    final state = c.read(uiConfigProvider(_ssh));
    expect(state.restored, isTrue);
    expect(state.availability, UiConfigAvailability.cached);
    expect(c.read(uiOverridesProvider).config.themeMode, UiThemeMode.dark);
    expect(c.read(uiThemeModeProvider).value, ThemeMode.dark);
  });

  test('each host has its own file; switching hosts switches the config', () async {
    final local = FakeUiSource();
    final remote = FakeUiSource();
    final c = container({HostRef.none: local, _ssh: remote});
    c.listen(uiOverridesProvider, (_, _) {});
    c.listen(uiConfigProvider(_ssh), (_, _) {});
    local.text('{"version": 1, "density": "compact"}');
    remote.text('{"version": 1, "density": "comfortable", "theme": {"mode": "light"}}');
    await settle();
    expect(c.read(uiOverridesProvider).config.density, UiDensity.compact);
    c.read(activeHostProvider.notifier).select(_ssh);
    await settle();
    expect(c.read(uiOverridesProvider).host, _ssh);
    expect(c.read(uiOverridesProvider).config.density, UiDensity.comfortable);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(UiConfigController.cacheKey(_ssh)), contains('light'));
    expect(prefs.getString(UiConfigController.cacheKey(HostRef.none)), contains('compact'));
  });

  test('merged values: ui.json over the app\'s settings, with the entry that set them', () async {
    final local = FakeUiSource();
    final c = container({HostRef.none: local});
    for (final p in [
      uiThemeModeProvider,
      uiAccentProvider,
      uiDrawerSortProvider,
      uiDrawerFilterProvider,
      uiDensityProvider,
    ]) {
      c.listen(p, (_, _) {});
    }
    await settle();
    expect(c.read(uiThemeModeProvider), UiValue(c.read(settingsProvider).themeMode));
    expect(c.read(uiAccentProvider).value, c.read(accentProvider));
    expect(c.read(uiAccentProvider).fromUiJson, isFalse);
    expect(c.read(uiDrawerSortProvider).value, DrawerSort.activity);
    expect(c.read(uiDensityProvider).value, UiDensity.comfortable);

    local.text(
      '{"version": 1, "theme": {"mode": "dark", "accent": "#5F7A55"}, '
      '"drawer": {"sort": "created", "filter": "unread"}, "density": "compact"}',
    );
    await settle();
    final mode = c.read(uiThemeModeProvider);
    expect(mode.value, ThemeMode.dark);
    expect(mode.entry!.pointer, '/theme/mode');
    final accent = c.read(uiAccentProvider);
    expect(accent.value, AppAccent.derive(const Color(0xFF5F7A55)));
    expect(accent.entry!.pointer, '/theme/accent');
    expect(c.read(uiDrawerSortProvider).value, DrawerSort.created);
    expect(c.read(uiDrawerFilterProvider).value, DrawerFilter.unread);
    expect(c.read(uiDensityProvider).value, UiDensity.compact);
    expect(c.read(uiSettingEntryProvider(UiSettingKey.drawerSort))!.pointer, '/drawer/sort');
    expect(c.read(uiSettingEntryProvider(UiSettingKey.pet)), isNull);

    local.text('{"version": 1, "theme": {"accentPreset": "amber"}}');
    await settle();
    expect(c.read(uiAccentProvider).value, AppAccent.amber);
    expect(c.read(uiThemeModeProvider).fromUiJson, isFalse);
  });

  test('恢复默认 sets one setting aside until the file says something else', () async {
    final local = FakeUiSource();
    final c = container({HostRef.none: local});
    c.listen(uiOverridesProvider, (_, _) {});
    c.listen(uiThemeModeProvider, (_, _) {});
    local.text('{"version": 1, "theme": {"mode": "dark"}, "density": "compact"}');
    await settle();
    expect(c.read(uiThemeModeProvider).value, ThemeMode.dark);

    await restoreUiDefault(c.read(uiOverridesProvider), c.read(uiIgnoresProvider.notifier), UiSettingKey.themeMode);
    await settle();
    expect(c.read(uiThemeModeProvider).fromUiJson, isFalse);
    expect(c.read(uiThemeModeProvider).value, c.read(settingsProvider).themeMode);
    expect(c.read(uiOverridesProvider).config.density, UiDensity.compact, reason: 'only that setting');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(UiIgnoresController.prefsKey), contains('theme.mode'));

    // Same value rewritten (formatting changed): still set aside.
    local.text('{"version":1,"theme":{"mode":"dark"},"density":"compact"}');
    await settle();
    expect(c.read(uiThemeModeProvider).fromUiJson, isFalse);

    // A new value applies again, and the record is dropped.
    local.text('{"version": 1, "theme": {"mode": "light"}, "density": "compact"}');
    await settle();
    expect(c.read(uiThemeModeProvider).value, ThemeMode.light);
    expect(c.read(uiThemeModeProvider).fromUiJson, isTrue);
    expect(c.read(uiIgnoresProvider), isEmpty);
  });

  test('set-aside records are per host', () async {
    final local = FakeUiSource();
    final remote = FakeUiSource();
    final c = container({HostRef.none: local, _ssh: remote});
    c.listen(uiOverridesProvider, (_, _) {});
    c.listen(uiConfigProvider(_ssh), (_, _) {});
    const text = '{"version": 1, "density": "compact"}';
    local.text(text);
    remote.text(text);
    await settle();
    await restoreUiDefault(c.read(uiOverridesProvider), c.read(uiIgnoresProvider.notifier), UiSettingKey.density);
    await settle();
    expect(c.read(uiOverridesProvider).config.density, isNull);
    c.read(activeHostProvider.notifier).select(_ssh);
    await settle();
    expect(c.read(uiOverridesProvider).config.density, UiDensity.compact);
  });

  test('remote availability: offline keeps the last config, the skill flag comes through', () async {
    final remote = FakeUiSource();
    final c = container({_ssh: remote}, active: _ssh);
    c.listen(uiConfigProvider(_ssh), (_, _) {});
    remote.push(const UiConfigAbsent(skillMissing: true));
    await settle();
    expect(c.read(uiConfigProvider(_ssh)).needsSkill, isTrue);
    remote.text('{"version": 1}');
    await settle();
    expect(c.read(uiConfigProvider(_ssh)).needsSkill, isFalse);
    remote.push(const UiConfigUnavailable(UiConfigUnavailableReason.denied));
    await settle();
    final state = c.read(uiConfigProvider(_ssh));
    expect(state.availability, UiConfigAvailability.denied);
    expect(state.load, isNotNull);
  });

  test('pluginCapsule hide applies from the host file and restore-default ignores it', () async {
    final local = FakeUiSource();
    final c = container({HostRef.none: local});
    c.listen(uiHiddenProvider(UiHideItem.pluginCapsule), (_, _) {});
    local.text('{"version":1,"hide":["pluginCapsule"]}');
    await settle();
    expect(c.read(uiConfigProvider(HostRef.none)).load!.appliedCount, 1);
    expect(c.read(uiHiddenProvider(UiHideItem.pluginCapsule)), isTrue);
    await restoreUiDefault(
      c.read(uiOverridesProvider),
      c.read(uiIgnoresProvider.notifier),
      UiSettingKey.hide(UiHideItem.pluginCapsule),
    );
    await settle();
    expect(c.read(uiHiddenProvider(UiHideItem.pluginCapsule)), isFalse);
  });

  test('plugins.seats reach the seat planner as SeatOverrides', () async {
    final local = FakeUiSource();
    final c = container({HostRef.none: local});
    c.listen(uiSeatOverridesProvider, (_, _) {});
    expect(c.read(uiSeatOverridesProvider), SeatOverrides.none);
    local.text(
      '{"version": 1, "plugins": {"seats": {"conversation.input.dock": {"dsh-cost-meter": "hidden", "@a/b": "web"}}}}',
    );
    await settle();
    final seats = c.read(uiSeatOverridesProvider);
    expect(seats.lookup('conversation.input.dock', 'dsh-cost-meter'), SeatOverride.hidden);
    expect(seats.lookup('conversation.input.dock', '@a/b'), SeatOverride.web);
    await restoreUiDefault(
      c.read(uiOverridesProvider),
      c.read(uiIgnoresProvider.notifier),
      UiSettingKey.seat('conversation.input.dock', 'dsh-cost-meter'),
    );
    await settle();
    expect(c.read(uiSeatOverridesProvider).lookup('conversation.input.dock', 'dsh-cost-meter'), isNull);
    expect(c.read(uiSeatOverridesProvider).lookup('conversation.input.dock', '@a/b'), SeatOverride.web);
  });

  test('the real local wiring follows a file in the rootfs', () async {
    final root = tempRootfs();
    addTearDown(() => root.deleteSync(recursive: true));
    final c = ProviderContainer(
      overrides: [
        activeHostProvider.overrideWith(() => TestActiveHost(HostRef.none)),
        uiConfigSourceBuilderProvider.overrideWithValue(defaultUiConfigSource),
        uiConfigKicksProvider.overrideWithValue(const Stream.empty()),
        uiRootfsResolverProvider.overrideWithValue(() async => root),
        localRuntimeProvider.overrideWith(() => TestRuntime(RuntimePhase.running)),
      ],
    );
    addTearDown(c.dispose);
    c.listen(uiOverridesProvider, (_, _) {});
    final file = File('${root.path}/root/.dsh/dsh-go/ui.json');
    await until(() => file.parent.existsSync());
    file.writeAsStringSync('{"version": 1, "density": "compact"}');
    await until(() => c.read(uiOverridesProvider).config.density == UiDensity.compact);
    await until(() => File('${file.parent.path}/ui.status.json').existsSync());
    file.writeAsStringSync('{"version": 1, "density": "comfortable"}');
    await until(() => c.read(uiOverridesProvider).config.density == UiDensity.comfortable);
    file.deleteSync();
    await until(() => c.read(uiConfigProvider(HostRef.none)).load == null);
    await until(() => !File('${file.parent.path}/ui.status.json').existsSync());
  });
}

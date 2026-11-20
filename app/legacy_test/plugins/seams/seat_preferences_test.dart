import 'dart:convert';

import 'package:dsh_app/plugins/seams/seams.dart';
import 'package:dsh_app/plugins/seams/seat_preferences.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/ui_config/ui_config.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import '../../ui_config/support.dart';

const _plugin = 'local-overlay';
const _other = 'other-overlay';
const _ssh = HostRef.portal('computer');

class _FailingStore extends InMemorySharedPreferencesStore {
  _FailingStore() : super.empty();

  bool fail = true;

  @override
  Future<bool> setValue(String type, String key, Object value) =>
      fail ? Future.value(false) : super.setValue(type, key, value);
}

ProviderContainer _container() {
  final c = ProviderContainer(overrides: sourceOverrides({}));
  addTearDown(c.dispose);
  c.listen(seatOverridesProvider, (_, _) {});
  return c;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('unset preferences never opt in, including before cold-start load', () async {
    final c = _container();
    expect(c.read(seatOverridesProvider).lookup(Slots.shellOverlay, _plugin), isNull);
    await c.read(seatPreferencesProvider.notifier).ready;
    await c.pump();
    expect(c.read(seatOverridesProvider).lookup(Slots.shellOverlay, _plugin), isNull);
  });

  test('overlay preferences persist separately by host and package', () async {
    final c = _container();
    final preferences = c.read(seatPreferencesProvider.notifier);
    await preferences.setOverlay(HostRef.none, _plugin, true);
    await preferences.setOverlay(HostRef.none, _other, false);
    await preferences.setOverlay(_ssh, _plugin, false);
    final restarted = _container();
    await restarted.read(seatPreferencesProvider.notifier).ready;
    await restarted.pump();
    expect(restarted.read(seatPreferencesProvider)[seatPreferenceHostKey(HostRef.none)], {
      _plugin: true,
      _other: false,
    });
    expect(restarted.read(seatPreferencesProvider)[seatPreferenceHostKey(_ssh)], {_plugin: false});
    expect(restarted.read(seatOverridesProvider).lookup(Slots.shellOverlay, _plugin), SeatOverride.island);
    restarted.read(activeHostProvider.notifier).select(_ssh);
    await restarted.pump();
    expect(restarted.read(seatOverridesProvider).lookup(Slots.shellOverlay, _plugin), SeatOverride.hidden);
    final prefs = await SharedPreferences.getInstance();
    expect(jsonDecode(prefs.getString(SeatPreferencesController.prefsKey)!), hasLength(2));
  });

  test('simultaneous writes preserve both plugin choices and a later close', () async {
    final c = _container();
    final preferences = c.read(seatPreferencesProvider.notifier);
    await Future.wait([
      preferences.setOverlay(HostRef.none, _plugin, true),
      preferences.setOverlay(HostRef.none, _other, true),
      preferences.setOverlay(HostRef.none, _plugin, false),
    ]);
    expect(c.read(seatPreferencesProvider)[seatPreferenceHostKey(HostRef.none)], {_plugin: false, _other: true});
  });

  test('corrupt preferences stay off and can be replaced by a user choice', () async {
    SharedPreferences.setMockInitialValues({SeatPreferencesController.prefsKey: '{broken'});
    final c = _container();
    await c.read(seatPreferencesProvider.notifier).ready;
    expect(c.read(seatPreferencesProvider), isEmpty);
    await c.read(seatPreferencesProvider.notifier).setOverlay(HostRef.none, _plugin, true);
    expect(c.read(seatPreferencesProvider)[seatPreferenceHostKey(HostRef.none)]![_plugin], isTrue);
  });

  test('a failed durable write stays off and a later user retry can succeed', () async {
    final previous = SharedPreferencesStorePlatform.instance;
    final store = _FailingStore();
    SharedPreferencesStorePlatform.instance = store;
    addTearDown(() => SharedPreferencesStorePlatform.instance = previous);
    final c = _container();
    final preferences = c.read(seatPreferencesProvider.notifier);
    await expectLater(preferences.setOverlay(HostRef.none, _plugin, true), throwsStateError);
    expect(c.read(seatPreferencesProvider), isEmpty);
    store.fail = false;
    await preferences.setOverlay(HostRef.none, _plugin, true);
    expect(c.read(seatPreferencesProvider)[seatPreferenceHostKey(HostRef.none)]![_plugin], isTrue);
  });

  test('explicit ui.json seats win; restore default reveals the local choice', () async {
    final source = FakeUiSource();
    final c = ProviderContainer(overrides: sourceOverrides({HostRef.none: source}));
    addTearDown(c.dispose);
    c.listen(seatOverridesProvider, (_, _) {});
    await c.read(seatPreferencesProvider.notifier).setOverlay(HostRef.none, _plugin, true);
    source.text(
      jsonEncode({
        'version': 1,
        'plugins': {
          'seats': {
            Slots.shellOverlay: {_plugin: 'hidden', _other: 'island'},
            Slots.settingsSection: {_plugin: 'web'},
          },
        },
      }),
    );
    await c.pump();
    expect(c.read(seatOverridesProvider).lookup(Slots.shellOverlay, _plugin), SeatOverride.hidden);
    expect(c.read(seatOverridesProvider).lookup(Slots.shellOverlay, _other), SeatOverride.island);
    expect(c.read(seatOverridesProvider).lookup(Slots.settingsSection, _plugin), SeatOverride.web);
    await restoreUiDefault(
      c.read(uiOverridesProvider),
      c.read(uiIgnoresProvider.notifier),
      UiSettingKey.seat(Slots.shellOverlay, _plugin),
    );
    expect(c.read(seatOverridesProvider).lookup(Slots.shellOverlay, _plugin), SeatOverride.island);
    expect(c.read(uiSettingEntryProvider(UiSettingKey.seat(Slots.shellOverlay, _plugin))), isNull);
  });

  test('a cached ui.json hide wins over a restored enabled preference', () async {
    SharedPreferences.setMockInitialValues({
      SeatPreferencesController.prefsKey: jsonEncode({
        seatPreferenceHostKey(HostRef.none): {_plugin: true},
      }),
      UiConfigController.cacheKey(HostRef.none): jsonEncode({
        'version': 1,
        'plugins': {
          'seats': {
            Slots.shellOverlay: {_plugin: 'hidden'},
          },
        },
      }),
    });
    final c = _container();
    final observed = <SeatOverride?>[];
    c.listen(seatOverridesProvider, (_, next) => observed.add(next.lookup(Slots.shellOverlay, _plugin)));
    await c.read(seatPreferencesProvider.notifier).ready;
    await c.pump();
    expect(c.read(seatOverridesProvider).lookup(Slots.shellOverlay, _plugin), SeatOverride.hidden);
    expect(observed, isNot(contains(SeatOverride.island)));
  });
}

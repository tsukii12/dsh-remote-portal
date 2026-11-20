// The plugin seats on the app's pages (docs/design/plugin-seams.md §3) over a
// fake inventory — the plugin detail's config row, a plugin's own page (island
// or the way to DSH Web), the 对话详情 插件 tab, 全部功能's plugin panels, the
// settings hub rows and the Cordis interactive region. Goldens (light + dark)
// and behaviour. Without third-party occupants the pages' own goldens
// (test/plugins, test/session, …) are unaffected.
// Regenerate with `flutter test --update-goldens test/plugins/seats`.

import 'package:dsh_app/plugins/seams/seams.dart';
import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/state/plugins_state.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/ui/chat/empty_state.dart' show chatClock;
import 'package:dsh_app/ui/chat/widgets/live_clock.dart' show runClock;
import 'package:dsh_app/ui/cordis/cordis_page.dart';
import 'package:dsh_app/ui/features/all_features_page.dart';
import 'package:dsh_app/ui/features/feature_catalog.dart';
import 'package:dsh_app/ui/plugins/plugin_detail_sheet.dart';
import 'package:dsh_app/ui/plugins/plugins_screen.dart';
import 'package:dsh_app/ui/plugins/seats/cordis_island_seat.dart';
import 'package:dsh_app/ui/plugins/seats/plugin_seat_page.dart';
import 'package:dsh_app/ui/plugins/seats/session_plugins_tab.dart';
import 'package:dsh_app/ui/session/session_detail_page.dart';
import 'package:dsh_app/ui/settings/settings_screen.dart';
import 'package:dsh_app/ui/web/web_target.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import '../../chat/support/harness.dart' as chat;
import '../../chat/support/run_info_fixture.dart';
import '../../cordis/support.dart';
import '../../shell/golden_harness.dart';
import '../support/fake_plugin_host.dart';
import 'support.dart';

/// Pumps [home] on the phone surface with the seats and [extra] overrides.
Future<void> _pump(
  WidgetTester tester,
  Widget home, {
  Brightness brightness = Brightness.light,
  List<Override> seats = const [],
  List<Override> extra = const [],
}) async {
  await tester.runAsync(loadGoldenFonts);
  usePhoneSurface(tester);
  await tester.pumpWidget(goldenApp(home: home, brightness: brightness, overrides: [...extra, ...seats]));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
}

/// Scrolls [finder] to the middle of the page.
Future<void> _reveal(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(finder, 200, scrollable: find.byType(Scrollable).first);
  await Scrollable.ensureVisible(tester.element(finder), alignment: 0.5);
  await _settle(tester);
}

/// The installed list on a fake local host.
List<Override> _pluginHost() {
  final carrier = FakePluginCarrier();
  final client = DshClient.withCarrier(carrier);
  carrier.handlers['pluginManager/listBundles'] = (_) => const <Object?>[];
  addTearDown(client.close);
  // seatOverrides selects the host.
  return pluginOverrides(fakeHost(client), selectHost: false);
}

/// 插件 › 已安装 › 岛屿探针.
Future<void> _openProbeSheet(WidgetTester tester) async {
  await tester.tap(find.text('岛屿探针').first);
  await _settle(tester);
}

final _hub = [
  localRuntimeProvider.overrideWith(() => FakeRuntime(const LocalRuntimeState(loaded: true, status: runningStatus))),
  settingsProvider.overrideWith(() => FakeSettings(const AppSettings(loaded: true))),
];

/// 对话详情 over the timed sample session (test/chat/support).
Future<void> _pumpDetail(
  WidgetTester tester, {
  required List<Override> seats,
  Brightness brightness = Brightness.light,
  SessionTab tab = SessionTab.trajectory,
}) async {
  chat.usePhoneView(tester);
  chat.mockClipboard(tester);
  final harness = chat.ChatHarness(session: 's1', states: {'s1': runInfoState()});
  await tester.pumpWidget(
    chat.testApp(
      SessionDetailPage(sessionId: 's1', initialTab: tab),
      brightness: brightness,
      overrides: [...harness.overrides, ...seats],
    ),
  );
  await chat.pumpFrames(tester, 6);
}

/// The inventory behind a seat, switchable mid-test.
class _Inventory extends Notifier<SeatInventory?> {
  _Inventory(this.initial);
  final SeatInventory? initial;

  @override
  SeatInventory? build() => initial;

  void set(SeatInventory? next) => state = next;
}

final _inventoryProvider = NotifierProvider<_Inventory, SeatInventory?>(() => _Inventory(null));

void main() {
  setUpAll(() async {
    await chat.loadTestFonts();
    chatClock = () => DateTime(2026, 10, 23, 15, 20);
  });
  setUp(() {
    openedWeb.clear();
    // 对话详情's running time, fixed.
    runClock = () => runInfoTestDispatched.add(const Duration(milliseconds: 12300));
  });
  tearDown(() => runClock = DateTime.now);

  group('goldens', () {
    for (final brightness in Brightness.values) {
      final mode = brightness == Brightness.dark ? 'dark' : 'light';
      Future<void> match(String name, [Finder? at]) =>
          expectLater(at ?? find.byType(MaterialApp), matchesGoldenFile('goldens/${name}_$mode.png'));

      testWidgets('plugin detail: config only in DSH Web ($mode)', (tester) async {
        await _pump(
          tester,
          const PluginsScreen(),
          brightness: brightness,
          extra: _pluginHost(),
          seats: seatOverrides(
            inventory: seatInventory(tier: ClientInventoryTier.boot),
            budget: const NoIslandBudget(),
          ),
        );
        await _openProbeSheet(tester);
        await match('seat_bundle_web');
      });

      testWidgets('a plugin page with its island ($mode)', (tester) async {
        await _pump(
          tester,
          const PluginSeatPage(
            title: '岛屿探针',
            request: SeatRequest(
              slot: Slots.settingsSection,
              placement: SeatPlacement.page,
              package: probe,
              cell: 'k4-probe',
            ),
          ),
          brightness: brightness,
          seats: seatOverrides(inventory: seatInventory(occupancy: fullOccupancy)),
        );
        await match('seat_island_page');
      });

      testWidgets('a plugin page that only opens in DSH Web ($mode)', (tester) async {
        await _pump(
          tester,
          const PluginSeatPage(
            title: '桌宠面板',
            request: SeatRequest(slot: Slots.main, placement: SeatPlacement.page, package: pet, cell: 'pet-panel'),
          ),
          brightness: brightness,
          seats: seatOverrides(inventory: seatInventory(occupancy: fullOccupancy)),
        );
        await match('seat_web_page');
      });

      testWidgets('settings hub: the plugins\' sections under 插件 ($mode)', (tester) async {
        await _pump(
          tester,
          const SettingsScreen(),
          brightness: brightness,
          extra: _hub,
          seats: seatOverrides(inventory: seatInventory(occupancy: fullOccupancy)),
        );
        await _reveal(tester, find.text('桌宠提醒'));
        await match('seat_settings');
      });

      testWidgets('全部功能: plugin panels in 插件 ($mode)', (tester) async {
        await _pump(
          tester,
          const AllFeaturesPage(),
          brightness: brightness,
          seats: seatOverrides(inventory: seatInventory(occupancy: fullOccupancy)),
        );
        await _reveal(tester, find.text('探针面板'));
        await match('seat_all_features');
      });

      testWidgets('Cordis: the interactive region over the actions ($mode)', (tester) async {
        await _pump(
          tester,
          const CordisPage(),
          brightness: brightness,
          extra: cordisOverrides(),
          seats: seatOverrides(inventory: seatInventory(occupancy: fullOccupancy)),
        );
        await tester.tap(find.text('桌面时钟'));
        await _settle(tester);
        await match('seat_cordis_sheet');
      });

      testWidgets('对话详情: the 插件 tab ($mode)', (tester) async {
        await _pumpDetail(
          tester,
          brightness: brightness,
          tab: SessionTab.plugins,
          seats: seatOverrides(inventory: seatInventory(occupancy: fullOccupancy)),
        );
        await match('seat_session_plugins', find.byType(SessionDetailPage));
      });
    }
  });

  group('plugin detail', () {
    testWidgets('a third-party config only DSH Web has: 设置 · 网页版, opening its card there', (tester) async {
      await _pump(
        tester,
        const PluginsScreen(),
        extra: _pluginHost(),
        seats: seatOverrides(
          inventory: seatInventory(tier: ClientInventoryTier.boot),
          budget: const NoIslandBudget(),
        ),
      );
      await _openProbeSheet(tester);
      final row = find.ancestor(of: find.text('设置'), matching: find.byType(InkWell)).first;
      expect(find.descendant(of: row, matching: find.text('网页版')), findsOneWidget);
      // On a host without the occupancy table the rest of its web part is one
      // more row under 「网页版界面」 (plugin-ui-v3 §3.5).
      expect(find.byKey(const ValueKey('web-place-unknown')), findsOneWidget);
      await tester.tap(row);
      expect(openedWeb.single.pluginItem, ['岛屿探针', 'Island probe', probe]);
    });

    testWidgets('with room for an island the row opens the plugin\'s own page', (tester) async {
      await _pump(
        tester,
        const PluginsScreen(),
        extra: _pluginHost(),
        seats: seatOverrides(
          inventory: seatInventory(tier: ClientInventoryTier.boot),
          budget: const OpenIslandBudget(),
        ),
      );
      await _openProbeSheet(tester);
      final config = find.ancestor(of: find.text('设置'), matching: find.byType(InkWell)).first;
      expect(find.descendant(of: config, matching: find.text('网页版')), findsNothing);
      await tester.tap(find.text('设置'));
      await _settle(tester);
      expect(find.byType(PluginSeatPage), findsOneWidget);
      expect(find.byType(FakeIsland), findsOneWidget);
      expect(openedWeb, isEmpty);
    });

    testWidgets('no seat on a host without islands or DSH Web: the sheet as before', (tester) async {
      await _pump(tester, const PluginsScreen(), extra: _pluginHost(), seats: seatOverrides(inventory: null));
      await _openProbeSheet(tester);
      expect(find.byType(BundleSheet), findsOneWidget);
      expect(find.byType(PluginSeat), findsNothing);
      expect(find.text('设置'), findsNothing);
    });
  });

  group('对话详情', () {
    testWidgets('one global panel opens in the tab without a conversation scope', (tester) async {
      await _pumpDetail(
        tester,
        tab: SessionTab.plugins,
        seats: seatOverrides(
          inventory: seatInventory(
            occupancy: {
              Slots.main: [occupant(Slots.main, probe, 'k4-panel')],
              Slots.panelList: fullOccupancy[Slots.panelList]!,
            },
          ),
        ),
      );
      expect(find.text('插件'), findsOneWidget);
      expect(find.text('探针面板'), findsOneWidget);
      final spec = tester.widget<FakeIsland>(find.byType(FakeIsland)).spec;
      expect(spec.slot, Slots.main);
      expect(spec.sessionId, isNull);
      final container = ProviderScope.containerOf(tester.element(find.byType(SessionDetailPage)));
      expect(container.read(sessionPluginPlanProvider('s1')).seat.sessionId, isNull);
    });

    testWidgets('several global panels keep their slot and root scope when opened', (tester) async {
      await _pumpDetail(
        tester,
        tab: SessionTab.plugins,
        seats: seatOverrides(inventory: seatInventory(occupancy: {...fullOccupancy, Slots.rightPaneTab: []})),
      );
      expect(find.text('探针面板'), findsOneWidget);
      expect(find.text('桌宠面板'), findsOneWidget);
      await tester.tap(find.text('桌宠面板'));
      expect(openedWeb.single, const DshWebTarget(sidebar: true));
      await tester.tap(find.text('探针面板'));
      await chat.pumpFrames(tester, 8);
      final page = tester.widget<PluginSeatPage>(find.byType(PluginSeatPage));
      expect(page.request.slot, Slots.main);
      expect(page.request.sessionId, isNull);
      expect(page.request.cell, 'k4-panel');
      expect(tester.widget<FakeIsland>(find.byType(FakeIsland)).spec.sessionId, isNull);
    });

    testWidgets('conversation-specific tabs retain priority over global panels', (tester) async {
      await _pumpDetail(
        tester,
        tab: SessionTab.plugins,
        seats: seatOverrides(inventory: seatInventory(occupancy: fullOccupancy)),
      );
      expect(find.text('探针页签'), findsOneWidget);
      expect(find.text('探针面板'), findsNothing);
      expect(find.text('桌宠面板'), findsNothing);
      final spec = tester.widget<FakeIsland>(find.byType(FakeIsland)).spec;
      expect(spec.slot, Slots.rightPaneTab);
      expect(spec.sessionId, 's1');
    });

    testWidgets('global panels remain available when the island route gate closes', (tester) async {
      await _pumpDetail(
        tester,
        tab: SessionTab.plugins,
        seats: seatOverrides(
          inventory: seatInventory(
            routeGuard: false,
            occupancy: {
              Slots.main: [occupant(Slots.main, probe, 'k4-panel')],
              Slots.panelList: fullOccupancy[Slots.panelList]!,
            },
          ),
        ),
      );
      expect(find.byType(FakeIsland), findsNothing);
      expect(find.text('探针面板'), findsOneWidget);
      await tester.tap(find.text('在网页版打开'));
      expect(openedWeb.single, const DshWebTarget(sidebar: true));
    });

    testWidgets('inventory changes keep the chosen tab and its fallback in sync', (tester) async {
      await _pumpDetail(
        tester,
        tab: SessionTab.plugins,
        seats: [
          ...seatOverrides(inventoryOf: (ref) => ref.watch(_inventoryProvider)),
          _inventoryProvider.overrideWith(() => _Inventory(seatInventory(occupancy: fullOccupancy))),
        ],
      );
      expect(find.text('探针页签'), findsOneWidget);
      final container = ProviderScope.containerOf(tester.element(find.byType(SessionDetailPage)));
      container
          .read(_inventoryProvider.notifier)
          .set(
            seatInventory(
              occupancy: {
                Slots.main: [occupant(Slots.main, probe, 'k4-panel')],
                Slots.panelList: fullOccupancy[Slots.panelList]!,
              },
            ),
          );
      await chat.pumpFrames(tester, 6);
      expect(find.text('插件'), findsOneWidget);
      expect(find.text('探针面板'), findsOneWidget);
      expect(find.text('探针页签'), findsNothing);
      expect(tester.widget<FakeIsland>(find.byType(FakeIsland)).spec.sessionId, isNull);
      container.read(_inventoryProvider.notifier).set(seatInventory());
      await chat.pumpFrames(tester, 6);
      expect(find.text('插件'), findsNothing);
      expect(find.byType(SessionPluginsTab), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('插件 only while the conversation has plugin tabs; the tab on screen stays', (tester) async {
      await _pumpDetail(
        tester,
        tab: SessionTab.changes,
        seats: seatOverrides(inventoryOf: (ref) => ref.watch(_inventoryProvider)),
      );
      expect(find.text('插件'), findsNothing);
      final container = ProviderScope.containerOf(tester.element(find.byType(SessionDetailPage)));
      container.read(_inventoryProvider.notifier).set(seatInventory(occupancy: fullOccupancy));
      await chat.pumpFrames(tester, 4);
      expect(find.text('插件'), findsOneWidget);
      // Still on 改动.
      expect(find.byType(ChangesTab), findsOneWidget);
      await tester.tap(find.text('插件'));
      await chat.pumpFrames(tester, 6);
      expect(find.byType(FakeIsland), findsOneWidget);
      expect(find.text('探针页签'), findsOneWidget);
      // Gone again: back to the first tab, nothing breaks.
      container.read(_inventoryProvider.notifier).set(null);
      await chat.pumpFrames(tester, 4);
      expect(find.text('插件'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a tab whose island can\'t come up is the way to DSH Web alone', (tester) async {
      await _pumpDetail(
        tester,
        tab: SessionTab.plugins,
        seats: seatOverrides(
          inventory: seatInventory(occupancy: fullOccupancy),
          renderers: testRenderers(island: (context, spec, items, fallback) => fallback(context)),
        ),
      );
      await chat.pumpFrames(tester, 2);
      // Named once, by the entry itself.
      expect(find.text('探针页签'), findsOneWidget);
      expect(find.text('在网页版打开'), findsOneWidget);
      await tester.tap(find.text('在网页版打开'));
      expect(openedWeb.single, const DshWebTarget(sessionId: 's1'));
    });

    testWidgets('several plugin tabs are a list, each opening its page or DSH Web', (tester) async {
      await _pumpDetail(
        tester,
        tab: SessionTab.plugins,
        seats: seatOverrides(
          inventory: seatInventory(
            occupancy: {
              ...fullOccupancy,
              Slots.rightPaneTab: [
                occupant(Slots.rightPaneTab, probe, 'k4-tab'),
                occupant(Slots.rightPaneTab, pet, 'pet-tab', label: '桌宠状态'),
              ],
            },
          ),
        ),
      );
      expect(find.text('探针页签'), findsOneWidget);
      expect(find.text('桌宠状态'), findsOneWidget);
      expect(find.text('网页版'), findsOneWidget);
      await tester.tap(find.text('桌宠状态'));
      expect(openedWeb.single, const DshWebTarget(sessionId: 's1'));
      await tester.tap(find.text('探针页签'));
      await chat.pumpFrames(tester, 8);
      expect(find.byType(PluginSeatPage), findsOneWidget);
      expect(find.byType(FakeIsland), findsOneWidget);
    });
  });

  group('全部功能', () {
    test('exactly the catalog without plugin panels; with them, at the end of 插件', () async {
      final empty = ProviderContainer(overrides: seatOverrides(inventory: seatInventory()));
      addTearDown(empty.dispose);
      expect(identical(empty.read(featureSectionsProvider), featureSections), isTrue);

      final full = ProviderContainer(
        overrides: seatOverrides(inventory: seatInventory(occupancy: fullOccupancy)),
      );
      addTearDown(full.dispose);
      await full.read(installedPluginsProvider.future);
      final section = full.read(featureSectionsProvider).singleWhere((s) => s.title == pluginFeatureSection);
      final base = featureSections.singleWhere((s) => s.title == pluginFeatureSection);
      expect(section.items.length, base.items.length + 2);
      final probePanel = section.items[base.items.length];
      final petPanel = section.items.last;
      expect((probePanel.title, probePanel.summary, probePanel.hasNative), ('探针面板', '岛屿探针', true));
      expect((petPanel.title, petPanel.webOnly, petPanel.web), ('桌宠面板', true, const DshWebTarget(sidebar: true)));
    });

    testWidgets('a panel with an island opens its page; the other opens DSH Web', (tester) async {
      await _pump(
        tester,
        const AllFeaturesPage(),
        seats: [
          ...seatOverrides(inventory: seatInventory(occupancy: fullOccupancy)),
          dshWebOpenerProvider.overrideWithValue((context, ref, target) => openedWeb.add(target)),
        ],
      );
      await _reveal(tester, find.text('桌宠面板'));
      await tester.tap(find.text('桌宠面板'));
      expect(openedWeb.single, const DshWebTarget(sidebar: true));
      await tester.tap(find.text('探针面板'));
      await _settle(tester);
      expect(find.byType(PluginSeatPage), findsOneWidget);
      expect(find.byType(FakeIsland), findsOneWidget);
    });
  });

  group('settings hub', () {
    testWidgets('a section with an island opens its page; one without, DSH Web', (tester) async {
      await _pump(
        tester,
        const SettingsScreen(),
        extra: _hub,
        seats: seatOverrides(inventory: seatInventory(occupancy: fullOccupancy)),
      );
      await _reveal(tester, find.text('桌宠提醒'));
      await tester.tap(find.text('桌宠提醒'));
      expect(openedWeb.single, const DshWebTarget(settings: DshWebSettings.general));
      await tester.tap(find.text('岛屿探针'));
      await _settle(tester);
      expect(find.byType(PluginSeatPage), findsOneWidget);
      expect(find.byType(FakeIsland), findsOneWidget);
    });

    testWidgets('no rows without plugin sections', (tester) async {
      await _pump(
        tester,
        const SettingsScreen(),
        extra: _hub,
        seats: seatOverrides(inventory: seatInventory()),
      );
      await _reveal(tester, find.text('插件'));
      expect(find.text('插件'), findsOneWidget); // the 插件 row itself
      expect(find.text('岛屿探针'), findsNothing);
    });
  });

  group('Cordis', () {
    testWidgets('the region folds away when its island can\'t come up', (tester) async {
      await _pump(
        tester,
        const CordisPage(),
        extra: cordisOverrides(),
        seats: seatOverrides(
          inventory: seatInventory(occupancy: fullOccupancy),
          renderers: testRenderers(island: (context, spec, items, fallback) => fallback(context)),
        ),
      );
      await tester.tap(find.text('桌面时钟'));
      await _settle(tester);
      expect(tester.getSize(find.byType(CordisIslandSeat)).height, 0);
      expect(find.text('在网页版打开'), findsOneWidget);
    });

    testWidgets('only the plugin\'s own region: none for another plugin', (tester) async {
      await _pump(
        tester,
        const CordisPage(),
        extra: cordisOverrides(),
        seats: seatOverrides(inventory: seatInventory(occupancy: fullOccupancy)),
      );
      await tester.tap(find.text('构建通知'));
      await _settle(tester);
      expect(find.byType(FakeIsland), findsNothing);
      expect(tester.getSize(find.byType(CordisIslandSeat)).height, 0);
    });
  });
}

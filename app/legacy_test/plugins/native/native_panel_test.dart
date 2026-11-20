// Native panels in the seats: a package that declares one shows it in
// 对话详情's 「插件」 tab and in 全部功能 instead of its web entry (ui.json can
// still ask for the web); the panel reads its view, follows the stream from
// that revision, and its controls go back to the plugin with the action
// name and value; `patch` and `stale` land on it.

import 'package:dsh_app/plugins/native/native_model.dart';
import 'package:dsh_app/plugins/seams/seams.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/ui/features/feature_catalog.dart';
import 'package:dsh_app/ui/plugins/native/native_panel.dart';
import 'package:dsh_app/ui/plugins/seats/plugin_seat_page.dart';
import 'package:dsh_app/ui/plugins/seats/session_plugins_tab.dart';
import 'package:dsh_app/ui/plugins/view/plugin_view.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../chat/support/harness.dart';
import 'support.dart';

const _usage = NativePanel(
  package: 'dsh-go-example-usage',
  id: 'usage',
  title: '用量',
  icon: 'chart',
  placement: {'session.tab', 'features'},
  live: true,
);

const _seat = SeatContext(host: HostRef.none, sessionId: 's1', placement: SeatPlacement.page);

/// The usage panel's view: a bound metric and a refresh button.
const _view = {
  'type': 'stack',
  'children': [
    {
      'type': 'metric',
      'label': '本对话',
      'value': {r'$': 'data.session'},
    },
    {
      'type': 'actions',
      'items': [
        {
          'label': '清零',
          'action': {
            'id': 'reset',
            'args': {'scope': 'today'},
          },
        },
      ],
    },
  ],
};

SeatInventory inventory({List<NativePanel> panels = const [_usage], bool webTab = true}) => SeatInventory(
  tier: ClientInventoryTier.bridge,
  routeGuard: true,
  webReachable: true,
  occupancy: {
    Slots.rightPaneTab: [
      if (webTab) const SlotOccupant(slot: Slots.rightPaneTab, package: 'dsh-go-example-usage', cell: 'cost-tab'),
      const SlotOccupant(slot: Slots.rightPaneTab, package: 'web-only', cell: 'notes'),
    ],
  },
  nativePanels: panels,
);

List<SeatItem> plan(SeatInventory inventory, {SeatOverrides overrides = SeatOverrides.none}) =>
    SlotAdapterRegistry.standard().plan(
      Slots.rightPaneTab,
      inventory.occupantsFor(Slots.rightPaneTab),
      _seat,
      budget: const OpenIslandBudget(),
      overrides: overrides,
      inventory: inventory,
    );

List<Override> panelOverrides(FakeBridge bridge, SeatInventory inv) => [
  ...nativeOverrides(bridge),
  seatInventoryProvider.overrideWith((ref) => inv),
  islandBudgetProvider.overrideWithValue(const NoIslandBudget()),
];

FakeBridge usageBridge() {
  final bridge = FakeBridge(contributions([usagePlugin()]));
  bridge.views['dsh-go-example-usage/usage'] = const DshGoView(
    pkg: 'dsh-go-example-usage',
    id: 'usage',
    title: '用量',
    view: _view,
    data: {'session': '¥0.42'},
    rev: 'r1',
    live: true,
    bytes: 2140,
  );
  return bridge;
}

void main() {
  setUpAll(loadTestFonts);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('planner', () {
    test('a package with a native panel shows it, not its web tab; others unchanged', () {
      final items = plan(inventory());
      expect(
        [for (final i in items) (i.occupant.package, i.occupant.cell, i.mode)],
        [('dsh-go-example-usage', 'dsh-go:usage', SeatMode.native), ('web-only', 'notes', SeatMode.island)],
      );
      expect(items.first.adapter?.id, 'dsh-ui-panel');
      expect(items.first.occupant.label, '用量');
    });

    test('ui.json asking for the web keeps the web tab instead', () {
      final items = plan(
        inventory(),
        overrides: const SeatOverrides({
          Slots.rightPaneTab: {'dsh-go-example-usage': SeatOverride.web},
        }),
      );
      expect(items.first.occupant.cell, 'cost-tab');
      expect(items.first.mode, SeatMode.webLink);
    });

    test('panels switched off (or none): exactly the web seats as before', () {
      expect(plan(inventory(panels: const [])).map((i) => i.occupant.cell), ['cost-tab', 'notes']);
    });

    test('placement decides the seat: features only is not a tab', () {
      final features = inventory(
        panels: const [
          NativePanel(package: 'p', id: 'board', title: '看板', placement: {'features'}),
        ],
        webTab: false,
      );
      expect(features.occupantsFor(Slots.rightPaneTab).map((o) => o.cell), ['notes']);
      expect(features.occupantsFor(Slots.main).map((o) => o.cell), ['dsh-go:board']);
    });
  });

  testWidgets('对话详情 › 插件: one native panel fills the tab, signed with the plugin name', (tester) async {
    usePhoneView(tester);
    final bridge = usageBridge();
    await tester.pumpWidget(
      testApp(
        const Scaffold(body: SessionPluginsTab(sessionId: 's1')),
        overrides: panelOverrides(bridge, inventory(webTab: true)),
      ),
    );
    await pumpFrames(tester);
    // Two occupants (the native panel and another plugin's web tab): a list.
    expect(find.text('用量'), findsOneWidget);
    await tester.tap(find.text('用量'));
    await pumpFrames(tester);
    expect(find.byType(PluginSeatPage), findsOneWidget);
    expect(find.byType(PluginFrame), findsOneWidget);
    expect(find.text('¥0.42'), findsOneWidget);
    // The frame names the plugin.
    expect(tester.widget<PluginFrame>(find.byType(PluginFrame)).pluginName, '用量');
  });

  testWidgets('the panel follows the stream from its view revision; controls go back to the plugin', (tester) async {
    usePhoneView(tester);
    final bridge = usageBridge()
      ..answer = (_) => DshGoInvokeResult.fromJson({
        'effects': [
          {
            'type': 'patch',
            'data': {'session': '¥0.00'},
          },
          {'type': 'toast', 'text': '已清零'},
        ],
      });
    await tester.pumpWidget(
      testApp(
        const NativePanelPage(panel: _usage, sessionId: 's1'),
        overrides: panelOverrides(bridge, inventory()),
      ),
    );
    await pumpFrames(tester);
    expect(find.text('¥0.42'), findsOneWidget);
    final sub = bridge.socket.subOf('usage')!;
    expect(sub['rev'], 'r1', reason: 'subscribes from the data it already has');
    expect(sub['scope'], {'sessionId': 's1'});

    bridge.socket.push({
      't': 'patch',
      'sub': sub['sub'],
      'rev': 'r2',
      'base': 'r1',
      'merge': {'session': '¥0.50'},
    });
    await pumpFrames(tester);
    expect(find.text('¥0.50'), findsOneWidget);

    await tester.tap(find.text('清零'));
    await pumpFrames(tester);
    final call = bridge.invocations.single;
    expect((call.surface, call.id, call.action), ('panel', 'usage', 'reset'));
    expect(call.value, {'scope': 'today'});
    expect(find.text('¥0.00'), findsOneWidget, reason: 'patch lands on the panel');
    expect(find.text('已清零'), findsOneWidget);

    // The plugin's view changed: read again.
    bridge.views['dsh-go-example-usage/usage'] = const DshGoView(
      pkg: 'dsh-go-example-usage',
      id: 'usage',
      view: {'type': 'text', 'text': '新的视图'},
      rev: 'r9',
    );
    bridge.socket.push({'t': 'stale', 'sub': sub['sub']});
    await pumpFrames(tester);
    expect(find.text('新的视图'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('a panel the plugin no longer has: one line and a retry', (tester) async {
    usePhoneView(tester);
    final bridge = FakeBridge(contributions([usagePlugin()]));
    await tester.pumpWidget(
      testApp(
        const NativePanelPage(panel: _usage, sessionId: 's1'),
        overrides: panelOverrides(bridge, inventory()),
      ),
    );
    await pumpFrames(tester);
    expect(find.text('插件已停用或找不到'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
  });

  testWidgets('全部功能 lists a features panel and opens it natively', (tester) async {
    usePhoneView(tester);
    final bridge = usageBridge();
    final inv = inventory();
    late List<FeatureSection> sections;
    await tester.pumpWidget(
      testApp(
        Consumer(
          builder: (context, ref, _) {
            sections = ref.watch(featureSectionsProvider);
            return const SizedBox();
          },
        ),
        overrides: panelOverrides(bridge, inv),
      ),
    );
    await pumpFrames(tester);
    final entry = [for (final s in sections) ...s.items].where((i) => i.id.startsWith('plugin-panel:')).single;
    expect(entry.title, '用量');
    expect(entry.native, isNotNull, reason: 'a native page, not the web');
    // The panel's own icon; the plugin's name says the same as the title, so
    // the card just says it is a plugin panel — never the package name.
    expect(entry.icon, AppIcons.chart);
    expect(entry.summary, '插件面板');
  });

  testWidgets('全部功能: a panel named apart from its plugin says whose it is, by the plugin\'s title', (tester) async {
    usePhoneView(tester);
    final bridge = FakeBridge(
      contributions([
        plugin(
          'dsh-go-example-usage',
          title: '用量统计',
          icon: 'chart',
          panels: [
            {
              'id': 'usage',
              'title': '今日用量',
              'icon': 'wallet',
              'placement': ['features'],
            },
          ],
        ),
      ]),
    );
    late List<FeatureSection> sections;
    await tester.pumpWidget(
      testApp(
        Consumer(
          builder: (context, ref, _) {
            sections = ref.watch(featureSectionsProvider);
            return const SizedBox();
          },
        ),
        overrides: panelOverrides(
          bridge,
          inventory(
            panels: const [
              NativePanel(
                package: 'dsh-go-example-usage',
                id: 'usage',
                title: '今日用量',
                icon: 'wallet',
                placement: {'features'},
              ),
            ],
            webTab: false,
          ),
        ),
      ),
    );
    await pumpFrames(tester);
    final entry = [for (final s in sections) ...s.items].where((i) => i.id.startsWith('plugin-panel:')).single;
    expect(entry.title, '今日用量');
    expect(entry.summary, '用量统计');
    expect(entry.icon, AppIcons.balance);
  });

  testWidgets('对话详情 › 插件: one native panel named like its plugin shows the name once (on the card)', (tester) async {
    usePhoneView(tester);
    await tester.pumpWidget(
      testApp(
        const Scaffold(body: SessionPluginsTab(sessionId: 's1')),
        overrides: panelOverrides(
          usageBridge(),
          const SeatInventory(
            tier: ClientInventoryTier.bridge,
            routeGuard: true,
            webReachable: true,
            occupancy: {Slots.rightPaneTab: []},
            nativePanels: [_usage],
          ),
        ),
      ),
    );
    await pumpFrames(tester);
    // Only the native panel occupies the tab: it fills it.
    expect(find.byType(PluginFrame), findsOneWidget);
    expect(find.text('用量'), findsOneWidget, reason: 'the signature, not a group title over it');
  });
}

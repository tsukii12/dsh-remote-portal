// 插件详情 › 网页版界面 (docs/design/plugin-ui-v3.md §3.5): where a plugin's web
// part lives that the app has no seat for, each a way to DSH Web. Goldens
// (light + dark) and behaviour. Regenerate with
// `flutter test --update-goldens test/plugins/seats/plugin_web_places_test.dart`.

import 'package:dsh_app/plugins/seams/seams.dart';
import 'package:dsh_app/ui/plugins/plugin_detail_sheet.dart';
import 'package:dsh_app/ui/plugins/plugins_screen.dart';
import 'package:dsh_app/ui/plugins/seats/plugin_web_places.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import '../../chat/support/harness.dart' as chat;
import '../../shell/golden_harness.dart';
import '../support/fake_plugin_host.dart';
import 'support.dart';

/// The probe's web part: a settings page, a conversation view and two
/// chat-page parts (seated), and three places the app has no seat for.
final _spread = <String, List<SlotOccupant>>{
  Slots.settingsSection: [occupant(Slots.settingsSection, probe, 'k4-probe', label: '岛屿探针')],
  Slots.inputLeft: [occupant(Slots.inputLeft, probe, 'k4-button')],
  Slots.composerDock: [occupant(Slots.composerDock, probe, 'k4-band')],
  'conversation.input.activity': [occupant('conversation.input.activity', probe, 'k4-activity')],
  'conversation.view': [occupant('conversation.view', probe, 'k4-view', label: '探针视图')],
  'tool.call.toolview': [occupant('tool.call.toolview', probe, 'k4_tool')],
  Slots.shellOverlay: [
    occupant(Slots.shellOverlay, probe, 'k4-toast'),
    const SlotOccupant(slot: Slots.shellOverlay, package: 'official', cell: 'quota', official: true),
  ],
};

List<Override> _pluginHost() {
  final carrier = FakePluginCarrier();
  final client = DshClient.withCarrier(carrier);
  carrier.handlers['pluginManager/listBundles'] = (_) => const <Object?>[];
  addTearDown(client.close);
  return pluginOverrides(fakeHost(client), selectHost: false);
}

Future<void> _openProbe(
  WidgetTester tester,
  SeatInventory? inventory, {
  Brightness brightness = Brightness.light,
}) async {
  await tester.runAsync(loadGoldenFonts);
  usePhoneSurface(tester);
  await tester.pumpWidget(
    goldenApp(
      home: const PluginsScreen(),
      brightness: brightness,
      overrides: [
        ..._pluginHost(),
        ...seatOverrides(inventory: inventory, budget: const NoIslandBudget()),
      ],
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
  await tester.tap(find.text('岛屿探针').first);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
}

void main() {
  setUpAll(chat.loadTestFonts);
  setUp(openedWeb.clear);

  group('places', () {
    test(
      'the unseated slots of a package, in plain words and a fixed order; seated ones and official cells stay out',
      () {
        expect(pluginWebPlaces(seatInventory(occupancy: _spread), probe), [
          WebPlace.besideComposer,
          WebPlace.messages,
          WebPlace.overlay,
        ]);
        expect(pluginWebPlaces(seatInventory(occupancy: fullOccupancy), probe), isEmpty, reason: 'all seated');
      },
    );

    test('without the occupancy table one row for the whole web part; without DSH Web or a browser half, none', () {
      expect(pluginWebPlaces(seatInventory(tier: ClientInventoryTier.boot), probe), [WebPlace.unknown]);
      expect(
        pluginWebPlaces(
          const SeatInventory(
            webReachable: false,
            packages: {probe: PluginClientInfo(package: probe, hasClient: true, enabled: true, installed: true)},
          ),
          probe,
        ),
        isEmpty,
      );
      expect(
        pluginWebPlaces(
          const SeatInventory(
            webReachable: true,
            occupancy: {},
            packages: {probe: PluginClientInfo(package: probe, enabled: true, installed: true)},
          ),
          probe,
        ),
        isEmpty,
      );
      expect(
        pluginWebPlaces(
          const SeatInventory(
            webReachable: true,
            occupancy: {},
            packages: {probe: PluginClientInfo(package: probe, hasClient: true, installed: true, enabled: false)},
          ),
          probe,
        ),
        isEmpty,
        reason: 'a switched-off plugin shows nothing in DSH Web either',
      );
    });

    test('every slot of the catalog has a place; the common ones the expected one', () {
      for (final key in slotCatalog.keys) {
        expect(WebPlace.of(key), isA<WebPlace>(), reason: key);
      }
      expect(WebPlace.of('conversation.input.activity'), WebPlace.besideComposer);
      expect(
        WebPlace.of('conversation.input.right'),
        WebPlace.besideComposer,
        reason: 'seated, but placed all the same',
      );
      expect(WebPlace.of('conversation.session.header.utilities'), WebPlace.header);
      expect(WebPlace.of(Slots.headerViewsActions), WebPlace.header);
      expect(WebPlace.of('conversation.chat.turnTail'), WebPlace.messages);
      expect(WebPlace.of('sidebar.footer.action'), WebPlace.sidebar);
      expect(WebPlace.of('sidebar.right.tab.files.actions'), WebPlace.rightbar);
      expect(WebPlace.of('sidebar.right.tab.document.actions'), WebPlace.files);
      expect(WebPlace.of('deliverables.file.actions'), WebPlace.files);
      expect(WebPlace.of('settings.plugins.tab'), WebPlace.settings);
      expect(WebPlace.of('plugins.detail.section'), WebPlace.plugins);
      expect(WebPlace.of('conversation.hero.options'), WebPlace.newChat);
      expect(WebPlace.of('workspace.toast'), WebPlace.elsewhere);
    });
  });

  group('section', () {
    testWidgets('rows open DSH Web where the place is', (tester) async {
      await _openProbe(tester, seatInventory(occupancy: _spread));
      final section = find.byKey(const ValueKey('plugin-web-places'));
      await tester.scrollUntilVisible(section, 200, scrollable: find.byType(Scrollable).last);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const ValueKey('web-place-elsewhere')), findsNothing, reason: 'the view is in 对话详情');
      for (final place in ['besideComposer', 'messages', 'overlay']) {
        expect(find.byKey(ValueKey('web-place-$place')), findsOneWidget, reason: place);
      }
      await tester.tap(find.byKey(const ValueKey('web-place-overlay')));
      expect(openedWeb.single.isHome, isTrue);
    });

    testWidgets('a plugin whose web part is all seated has no section', (tester) async {
      await _openProbe(tester, seatInventory(occupancy: fullOccupancy));
      expect(find.byKey(const ValueKey('plugin-web-places')), findsNothing);
      expect(find.byType(BundleSheet), findsOneWidget);
    });

    for (final brightness in Brightness.values) {
      final mode = brightness == Brightness.dark ? 'dark' : 'light';
      testWidgets('golden ($mode)', (tester) async {
        await _openProbe(tester, seatInventory(occupancy: _spread), brightness: brightness);
        final section = find.byKey(const ValueKey('plugin-web-places'));
        await tester.scrollUntilVisible(section, 200, scrollable: find.byType(Scrollable).last);
        await Scrollable.ensureVisible(tester.element(section), alignment: 0.5);
        await tester.pump(const Duration(milliseconds: 600));
        await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/plugin_web_places_$mode.png'));
      });
    }
  });
}

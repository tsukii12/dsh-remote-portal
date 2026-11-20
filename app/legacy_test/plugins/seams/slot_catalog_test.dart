import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/plugins/seams/seams.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('every slot of 0.2.2-rc.1 plus the app surface, keyed by their own key', () {
    expect(slotCatalogRelease, '0.2.2-rc.1');
    expect(slotCatalog.length, 110);
    expect(slotCatalog.values.where((s) => s.synthetic).map((s) => s.key), [Slots.dshGoPanel]);
    for (final MapEntry(:key, :value) in slotCatalog.entries) {
      expect(value.key, key);
    }
  });

  test('the table matches the extracted catalog', () {
    // Extracted from DSH's client runner (docs/design/plugin-seams.md, appendix A);
    // key / kind / scope / replaceRisk only. A DSH bump brings a new extract.
    final file = File('test/plugins/seams/fixtures/slot-catalog-$slotCatalogRelease.json');
    final rows = (jsonDecode(file.readAsStringSync()) as List).cast<Map<String, Object?>>();
    expect(rows.length, 109);
    for (final row in rows) {
      final info = slotInfo(row['key']! as String)!;
      expect(info.kind.name, row['kind']);
      expect(info.scope, switch (row['scope']) {
        'session' => SlotScope.session,
        'session-maybe' => SlotScope.sessionMaybe,
        _ => SlotScope.root,
      });
      expect(info.replacesShippedUi, row['replaceRisk'] == 'shadows-shipped-ui', reason: info.key);
    }
  });

  test("rc.4's three 「更多」 menus are known, seatable at most as a web entry, and get no seat", () {
    for (final key in [Slots.headerViewsActions, Slots.panelListActions, Slots.guideActions]) {
      final info = slotInfo(key)!;
      expect(info.kind, SlotKind.list, reason: key);
      expect(info.scope, SlotScope.root, reason: key);
      expect(info.replacesShippedUi, isFalse, reason: key);
      expect(info.policy.priority, SeatPriority.other, reason: key);
      expect(info.policy.islands, isEmpty, reason: key);
    }
  });

  test('§3 priorities', () {
    SeatPriority of(String key) => seatPolicyOf(key).priority;
    for (final key in [
      Slots.settingsSection,
      Slots.bundleConfig,
      Slots.rowConfig,
      Slots.rightPaneTab,
      Slots.main,
      Slots.panelList,
      Slots.cordisView,
    ]) {
      expect(of(key), SeatPriority.p0, reason: key);
    }
    for (final key in [...Slots.chatPanel, Slots.generalItem]) {
      expect(of(key), SeatPriority.p1, reason: key);
    }
    expect(of(Slots.shellOverlay), SeatPriority.p2);
    expect(of(Slots.dshGoPanel), SeatPriority.p2);
    for (final key in [
      'conversation.chat.turnTail',
      'conversation.chat.assistant-actions',
      'conversation.chat.node',
      'conversation.user.text.node',
      'tool.call.toolview',
      'tool.call.images',
    ]) {
      expect(of(key), SeatPriority.message, reason: key);
      expect(seatPolicyOf(key).islands, isEmpty);
    }
    for (final key in [
      'root',
      'sidebar',
      'conversation.header',
      'conversation.composer.bar',
      'conversation.session',
      'main.conversation',
      'shell.leading',
      'shell.bottom',
      'settings.trigger',
      'settings.header',
      'settings.launcher',
      Slots.rightPaneTabTitle,
    ]) {
      expect(slotInfo(key)!.seatable, isFalse, reason: key);
    }
    for (final key in [Slots.sidebarFooter, Slots.settingsPluginsTab, Slots.pluginDetailSection]) {
      expect(seatPolicyOf(key).priority, SeatPriority.p1);
      expect(seatPolicyOf(key).needsOccupancy, isTrue);
      expect(seatPolicyOf(key).islands, {IslandForm.page});
      expect(Slots.seated, contains(key));
    }
    expect(seatPolicyOf('not.a.slot'), SeatPolicy.other);
  });

  test('island forms per §3 and §6.2', () {
    expect(seatPolicyOf(Slots.settingsSection).islands, {IslandForm.page});
    expect(seatPolicyOf(Slots.inputDock).islands, {IslandForm.panel});
    expect(seatPolicyOf(Slots.inputDock).needsOccupancy, isTrue);
    expect(seatPolicyOf(Slots.shellOverlay).optIn, isTrue);
    expect(seatPolicyOf(Slots.bundleConfig).inference, SlotInference.bundleConfig);
    expect(seatPolicyOf(Slots.rowConfig).inference, SlotInference.rowConfig);
    expect(seatPolicyOf(Slots.dshGoPanel).webLink, isFalse);
    // Every island-capable slot is one the app seats.
    for (final info in slotCatalog.values) {
      if (info.policy.islands.isNotEmpty) expect(info.seatable, isTrue, reason: info.key);
    }
  });

  test('ui.json values', () {
    expect(SeatOverride.tryParse('native'), SeatOverride.native);
    expect(SeatOverride.tryParse('island'), SeatOverride.island);
    expect(SeatOverride.tryParse('web'), SeatOverride.web);
    expect(SeatOverride.tryParse('hidden'), SeatOverride.hidden);
    expect(SeatOverride.tryParse('Native'), isNull);
    expect(SeatOverride.tryParse(null), isNull);
    const a = SeatOverrides({
      'shell.overlay': {'dsh-pet': SeatOverride.island},
    });
    const b = SeatOverrides({
      'shell.overlay': {'dsh-pet': SeatOverride.island},
      'main': {},
    });
    expect(a, b);
    expect(a.hashCode, b.hashCode);
    expect(a.lookup('shell.overlay', 'dsh-pet'), SeatOverride.island);
    expect(a.lookup('shell.overlay', 'other'), isNull);
    expect(SeatOverrides.none.isEmpty, isTrue);
    expect(b.isEmpty, isFalse);
  });
}

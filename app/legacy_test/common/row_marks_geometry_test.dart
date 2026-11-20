// The trailing column of a card is measured, not eyeballed: whatever ends a
// row — a chevron, a picked row's ✓, a status dot, an expand arrow, a status
// chip in front of a chevron — ends on the same edge, 16dp in from the card.
// Glyphs are measured by their ink (Material path extents), not their boxes.

import 'package:dsh_app/state/engine_settings_state.dart';
import 'package:dsh_app/ui/agents/agent_widgets.dart';
import 'package:dsh_app/ui/common/list_page_row.dart';
import 'package:dsh_app/ui/common/overview_card.dart';
import 'package:dsh_app/ui/common/row_marks.dart';
import 'package:dsh_app/ui/common/status_chip.dart';
import 'package:dsh_app/ui/plugins/plugin_inventory_page.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _tol = 0.6;

/// Ink extents of the 20dp Material glyphs, as fractions of the box.
const _chevronInkRight = OverviewChevron.inkRight;
const _checkInkRight = 20.58 / 24 * 20;
const _arrowInkLeft = 6.42 / 24 * 20;
const _arrowInkRight = 17.58 / 24 * 20;

Future<void> _pump(WidgetTester tester, Widget child) async {
  tester.view.devicePixelRatio = 2;
  tester.view.physicalSize = const Size(390 * 2, 844 * 2);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        theme: buildLightTheme(),
        home: Scaffold(
          body: SafeArea(child: SingleChildScrollView(child: child)),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Rect _card(WidgetTester tester, Finder inside) =>
    tester.getRect(find.ancestor(of: inside, matching: find.byType(GlassSurface)).first);

/// How far in from [card]'s right edge the ink of [icon] (the [at]th) ends.
double _inkInset(WidgetTester tester, Rect card, IconData icon, double inkRight, {int at = 0}) =>
    card.right - (tester.getRect(find.byIcon(icon).at(at)).left + inkRight);

InventoryItem _item(String title, {bool system = false}) =>
    InventoryItem(entryId: title, moduleName: title, title: title, status: InventoryStatus.running, system: system);

void main() {
  testWidgets('a picked row\'s ✓ ends where a chevron ends', (tester) async {
    await _pump(
      tester,
      ListPageCard(
        children: [
          ListPageRow(icon: AppIcons.folder, title: '已选', meta: '4', trailing: const RowCheck(), onTap: () {}),
          ListPageRow(
            icon: AppIcons.folder,
            title: '未选',
            meta: '1',
            trailing: const RowCheck(visible: false),
            onTap: () {},
          ),
          ListPageRow(icon: AppIcons.configure, title: '管理', onTap: () {}),
        ],
      ),
    );
    final card = _card(tester, find.text('已选'));
    final check = _inkInset(tester, card, AppIcons.selected, _checkInkRight);
    final chevron = _inkInset(tester, card, AppIcons.disclosure, _chevronInkRight);
    expect(check, moreOrLessEquals(ListPageRow.horizontal, epsilon: _tol));
    expect(chevron, moreOrLessEquals(ListPageRow.horizontal, epsilon: _tol));
    // The unpicked row keeps its count in the same column.
    expect(tester.getRect(find.text('1')).right, moreOrLessEquals(tester.getRect(find.text('4')).right, epsilon: 0.01));
  });

  testWidgets('an expand arrow ends where the status dots end', (tester) async {
    await _pump(
      tester,
      Column(
        children: [
          ListPageCard(children: [InventoryRow(item: _item('插件'))]),
          SystemComponentsCard(items: [_item('系统', system: true)], open: false, onToggle: () {}),
        ],
      ),
    );
    final card = _card(tester, find.text('插件'));
    final dot = tester.getRect(find.byType(AnimatedStatusDot).first);
    final arrowBox = tester.getRect(find.byIcon(AppIcons.expand));
    final arrowRight = card.right - (arrowBox.left + _arrowInkRight);
    final arrowCentre = arrowBox.left + (_arrowInkLeft + _arrowInkRight) / 2;
    expect(card.right - dot.right, moreOrLessEquals(16, epsilon: _tol));
    expect(arrowRight, moreOrLessEquals(card.right - dot.right, epsilon: _tol));
    expect(arrowCentre, moreOrLessEquals(dot.center.dx, epsilon: 1));
    // The count sits a row gap before the arrow's ink.
    expect(arrowBox.left + _arrowInkLeft - tester.getRect(find.text('1 个')).right, moreOrLessEquals(12, epsilon: _tol));
  });

  testWidgets('agent rows end like list rows: chevron 16 in, chips in one column', (tester) async {
    await _pump(
      tester,
      ListPageCard(
        children: [
          AgentRow(
            name: 'reviewer',
            title: 'reviewer',
            subtitle: const Text('审查改动'),
            tone: StatusTone.idle,
            stateLabel: '未运行',
            onTap: () {},
          ),
          const AgentRow(name: 'lead', title: 'lead', subtitle: Text('负责人'), tone: StatusTone.idle, stateLabel: '空闲'),
          ListPageRow(
            title: '任务',
            trailing: const StatusChip(tone: StatusTone.ok, label: '完成'),
            chevron: true,
            onTap: () {},
          ),
        ],
      ),
    );
    final card = _card(tester, find.text('reviewer'));
    for (var i = 0; i < 2; i++) {
      expect(
        _inkInset(tester, card, AppIcons.disclosure, _chevronInkRight, at: i),
        moreOrLessEquals(16, epsilon: _tol),
      );
    }
    final chips = [for (final e in find.byType(StatusChip).evaluate()) tester.getRect(find.byWidget(e.widget)).right];
    expect(chips, hasLength(3));
    for (final right in chips) {
      expect(right, moreOrLessEquals(chips.first, epsilon: 0.01));
    }
  });
}

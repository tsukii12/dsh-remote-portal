// Settings rows are measured, not eyeballed:
// the icon disc on the left and the switch track / chevron ink / bare value on
// the right sit the same 16dp from the card's edges; single-line rows are 52
// tall, two-line rows 64; the overview card's avatar sits as far from the top
// as from the left, its footer dot is centred under the avatar and the footer
// text starts where the title does; the engine's three capsules share the
// width evenly.

import 'package:dsh_app/runtime/runtime_bridge.dart';
import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/ui/common/app_sheet.dart';
import 'package:dsh_app/ui/common/list_page_row.dart';
import 'package:dsh_app/ui/common/overview_card.dart';
import 'package:dsh_app/ui/common/sheet_title_bar.dart';
import 'package:dsh_app/ui/common/status_chip.dart';
import 'package:dsh_app/ui/engine/engine_screen.dart';
import 'package:dsh_app/ui/settings/background_guide_page.dart';
import 'package:dsh_app/ui/settings/settings_widgets.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Where the chevron's ink ends inside its 20dp box (Material
/// `chevron_right_rounded`: path max x 15.58 of 24).
const _chevronInkRight = OverviewChevron.inkRight;

const _tol = 0.6;

Future<void> _pump(WidgetTester tester, Widget child, {double textScale = 1}) async {
  tester.view.devicePixelRatio = 2;
  tester.view.physicalSize = const Size(390 * 2, 844 * 2);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        theme: buildLightTheme(),
        home: MediaQuery.withClampedTextScaling(
          minScaleFactor: textScale,
          maxScaleFactor: textScale,
          child: Scaffold(
            body: SafeArea(child: SingleChildScrollView(child: child)),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

Rect _card(WidgetTester tester, Finder inside) =>
    tester.getRect(find.ancestor(of: inside, matching: find.byType(GlassSurface)).first);

void main() {
  testWidgets('rows: 16 from both card edges, 52 / 64 tall', (tester) async {
    await _pump(
      tester,
      SettingsSection(
        title: '分组',
        children: [
          SettingsTile(icon: AppIcons.engine, title: '引擎', onTap: () {}),
          SettingsSwitchTile(icon: AppIcons.running, title: '自动启动', value: true, onChanged: (_) {}),
          SettingsTile(icon: AppIcons.phoneControl, title: '手机操控', subtitle: '看屏幕、帮你点按', onTap: () {}),
          const InfoRow(label: '版本', value: '1.0.0 (1)'),
          SettingsTile(title: '开源许可', onTap: () {}),
        ],
      ),
    );
    final card = _card(tester, find.text('引擎'));

    // Left: the icon disc and a plain row's label both start 16 in.
    final disc = tester.getRect(find.byType(SettingsIcon).first);
    expect(disc.left - card.left, moreOrLessEquals(SettingsMetrics.inset, epsilon: _tol));
    expect(tester.getRect(find.text('版本')).left - card.left, moreOrLessEquals(16, epsilon: _tol));
    expect(tester.getRect(find.text('开源许可')).left - card.left, moreOrLessEquals(16, epsilon: _tol));
    // Titles of icon rows line up.
    expect(
      tester.getRect(find.text('引擎')).left,
      moreOrLessEquals(card.left + SettingsMetrics.textStart, epsilon: _tol),
    );
    expect(tester.getRect(find.text('手机操控')).left, tester.getRect(find.text('引擎')).left);

    // Right: switch track, chevron ink and a bare value all end 16 in.
    final sw = tester.getRect(find.byType(Switch));
    expect(
      card.right - (sw.right - 4),
      moreOrLessEquals(16, epsilon: _tol),
      reason: 'M3 track sits 4 inside the switch box',
    );
    for (final chevron in tester.widgetList<Icon>(find.byIcon(AppIcons.disclosure)).indexed) {
      final box = tester.getRect(find.byIcon(AppIcons.disclosure).at(chevron.$1));
      expect(card.right - (box.left + _chevronInkRight), moreOrLessEquals(16, epsilon: _tol));
    }
    expect(card.right - tester.getRect(find.text('1.0.0 (1)')).right, moreOrLessEquals(16, epsilon: _tol));

    // Heights: one line 52 (switch rows too), two lines 64.
    double rowHeight(String title) =>
        tester.getSize(find.ancestor(of: find.text(title), matching: find.byType(ConstrainedBox)).first).height;
    expect(rowHeight('引擎'), SettingsMetrics.rowHeight);
    expect(rowHeight('自动启动'), SettingsMetrics.rowHeight);
    expect(rowHeight('手机操控'), SettingsMetrics.rowHeightTwoLine);
    expect(rowHeight('版本'), SettingsMetrics.rowHeight);

    // The disc is vertically centred in its row.
    final row = tester.getRect(find.ancestor(of: find.text('引擎'), matching: find.byType(ConstrainedBox)).first);
    expect(disc.center.dy, moreOrLessEquals(row.center.dy, epsilon: _tol));
  });

  testWidgets('segmented row: the pill ends where switches end', (tester) async {
    await _pump(
      tester,
      SettingsSection(
        children: [
          SettingsSegmentTile<int>(
            icon: AppIcons.textSize,
            title: '字号',
            segments: const [PillSegment(0, '小'), PillSegment(1, '大')],
            selected: 0,
            onChanged: (_) {},
          ),
        ],
      ),
    );
    final card = _card(tester, find.text('字号'));
    final pill = tester.getRect(find.byType(SegmentedPill<int>));
    expect(card.right - pill.right, moreOrLessEquals(16, epsilon: _tol));
    expect(pill.center.dy, moreOrLessEquals(tester.getRect(find.text('字号')).center.dy, epsilon: 1));
  });

  for (final scale in [1.0, 1.3]) {
    testWidgets('overview card: avatar insets, footer under avatar and title (text ×$scale)', (tester) async {
      await _pump(
        tester,
        OverviewCard(
          leading: const OverviewGlyph(AppIcons.apiKey),
          title: const Text('雾蓝'),
          subtitle: const Text('余额 ¥128.45'),
          onTap: () {},
          footer: const OverviewFooter(tone: StatusTone.ok, text: '引擎 · 运行中 · DSH 0.2.1'),
          onFooterTap: () {},
        ),
        textScale: scale,
      );
      final card = _card(tester, find.text('雾蓝'));
      final avatar = tester.getRect(find.byType(OverviewGlyph));
      expect(avatar.width, OverviewCard.avatarSize);
      expect(avatar.left - card.left, moreOrLessEquals(OverviewCard.inset, epsilon: _tol));
      // At 1.0 the two text lines are no taller than the avatar: it sits as far
      // from the top as from the left. Larger text centres it on the lines.
      if (scale == 1.0) expect(avatar.top - card.top, moreOrLessEquals(OverviewCard.inset, epsilon: _tol));

      final dot = tester.getRect(find.byType(AnimatedStatusDot));
      expect(dot.center.dx, moreOrLessEquals(avatar.center.dx, epsilon: _tol));
      expect(
        tester.getRect(find.text('引擎 · 运行中 · DSH 0.2.1')).left,
        moreOrLessEquals(tester.getRect(find.text('雾蓝')).left, epsilon: _tol),
      );
      expect(tester.getRect(find.text('雾蓝')).left - card.left, moreOrLessEquals(OverviewCard.textStart, epsilon: _tol));

      // Both chevrons end 16 in, one above the other.
      final chevrons = find.byIcon(AppIcons.disclosure);
      expect(chevrons, findsNWidgets(2));
      for (var i = 0; i < 2; i++) {
        final box = tester.getRect(chevrons.at(i));
        expect(card.right - (box.left + _chevronInkRight), moreOrLessEquals(16, epsilon: _tol));
      }
    });
  }

  testWidgets('engine actions: three equal capsules, flush with the gutters', (tester) async {
    await _pump(
      tester,
      const Padding(
        padding: EdgeInsets.symmetric(horizontal: 16),
        child: EngineActions(phase: RuntimePhase.running),
      ),
    );
    final labels = ['启动', '停止', '重启'];
    final boxes = [
      for (final l in labels)
        tester.getRect(find.ancestor(of: find.text(l), matching: find.byType(AnimatedContainer)).first),
    ];
    expect(boxes.first.left, moreOrLessEquals(16, epsilon: _tol));
    expect(390 - boxes.last.right, moreOrLessEquals(16, epsilon: _tol));
    for (final b in boxes) {
      expect(b.width, moreOrLessEquals(boxes.first.width, epsilon: _tol));
      expect(b.height, EngineActions.height);
    }
    expect(boxes[1].left - boxes[0].right, moreOrLessEquals(EngineActions.gap, epsilon: _tol));
    expect(boxes[2].left - boxes[1].right, moreOrLessEquals(EngineActions.gap, epsilon: _tol));
  });

  testWidgets('group titles share style, page gutter and header semantics', (tester) async {
    final semantics = tester.ensureSemantics();
    await _pump(
      tester,
      const Column(
        children: [
          SettingsSection(title: '设置分组', children: [Text('内容')]),
          ListPageCard(title: '列表分组', children: [Text('内容')]),
          SheetGroup(title: '弹层分组', children: [Text('内容')]),
          SheetSectionLabel('弹层小标题'),
        ],
      ),
    );
    final texts = [
      for (final label in ['设置分组', '列表分组', '弹层分组', '弹层小标题']) tester.widget<Text>(find.text(label)),
    ];
    for (final text in texts.skip(1)) {
      expect(text.style!.fontSize, texts.first.style!.fontSize);
      expect(text.style!.fontWeight, texts.first.style!.fontWeight);
      expect(text.style!.color, texts.first.style!.color);
    }
    for (final label in ['设置分组', '列表分组', '弹层分组']) {
      expect(tester.getRect(find.text(label)).left, closeTo(24, 0.01));
    }
    for (final label in ['设置分组', '列表分组', '弹层分组', '弹层小标题']) {
      expect(tester.getSemantics(find.text(label)), isSemantics(label: label, isHeader: true));
    }
    semantics.dispose();
  });

  testWidgets('background guide: the vendor arrows end where the › above ends', (tester) async {
    tester.view.devicePixelRatio = 2;
    tester.view.physicalSize = const Size(390 * 2, 844 * 2);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [batteryExemptProvider.overrideWith((ref) async => false)],
        child: MaterialApp(theme: buildLightTheme(), home: const BackgroundGuidePage()),
      ),
    );
    await tester.pumpAndSettle();
    final card = _card(tester, find.text('系统电池优化'));
    final chevron = tester.getRect(find.byIcon(AppIcons.disclosure));
    expect(card.right - (chevron.left + _chevronInkRight), moreOrLessEquals(16, epsilon: _tol));
    final arrows = find.byIcon(AppIcons.expand);
    expect(arrows, findsWidgets);
    for (var i = 0; i < arrows.evaluate().length; i++) {
      final box = tester.getRect(arrows.at(i));
      // `expand_more_rounded` ink: x 6.42–17.58 of 24.
      expect(card.right - (box.left + 17.58 / 24 * box.width), moreOrLessEquals(16, epsilon: _tol));
    }
  });
}

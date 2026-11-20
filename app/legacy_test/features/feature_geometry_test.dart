// Measured symmetry of the feature pages' shared pieces: the hub's tile grid,
// a tile's corners, and the list-page row (left and right insets, the glyph
// column, group titles on the page's 24 column).

import 'package:dsh_app/ui/common/feature_tile.dart';
import 'package:dsh_app/ui/common/list_page_row.dart';
import 'package:dsh_app/ui/common/overview_card.dart';
import 'package:dsh_app/ui/common/tile_grid.dart';
import 'package:dsh_app/ui/providers/providers_page.dart' show LoginCapsule;
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../chat/support/harness.dart';

Widget _page(Widget child) => testApp(
  Scaffold(
    body: SafeArea(child: SingleChildScrollView(child: child)),
  ),
);

void main() {
  setUpAll(loadTestFonts);

  testWidgets('tile grid: equal columns, equal gaps, rows equal height', (tester) async {
    usePhoneView(tester);
    await tester.pumpWidget(
      _page(
        TileGrid(
          children: [
            for (final (i, title) in ['对话详情', '产出的文件', '后台任务', '引用文件和对话', '技能'].indexed)
              FeatureCard(
                key: ValueKey(i),
                icon: AppIcons.sessionDetails,
                title: title,
                subtitle: i == 3 ? '在输入框用 @ 引用文件、对话或子代理' : '一行说明',
                badge: i.isOdd ? '网页版' : null,
                onTap: () {},
              ),
          ],
        ),
      ),
    );
    await pumpFrames(tester);
    Rect tile(int i) => tester.getRect(find.byKey(ValueKey(i)));
    final width = tester.view.physicalSize.width / tester.view.devicePixelRatio;

    // 16 from both screen edges, 12 between the columns.
    expect(tile(0).left, 16);
    expect(width - tile(1).right, 16);
    expect(tile(1).left - tile(0).right, 12);
    expect(tile(0).width, tile(1).width);
    // The last row keeps the column width though it is alone.
    expect(tile(4).width, tile(0).width);
    // Rows: same height side by side (the taller one wins), 12 apart.
    expect(tile(2).height, tile(3).height);
    expect(tile(0).height, tile(1).height);
    expect(tile(2).top - tile(0).bottom, 12);
    expect(tile(4).top - tile(2).bottom, 12);
  });

  testWidgets('tile: glyph and corner badge share a centre line, equal insets', (tester) async {
    usePhoneView(tester);
    await tester.pumpWidget(
      _page(
        const TileGrid(
          children: [
            FeatureCard(key: ValueKey('t'), icon: AppIcons.terminal, title: '终端', subtitle: '工作区里的终端', badge: '网页版'),
          ],
        ),
      ),
    );
    await pumpFrames(tester);
    final tile = tester.getRect(find.byKey(const ValueKey('t')));
    final glyph = tester.getRect(
      find.ancestor(of: find.byIcon(AppIcons.terminal), matching: find.byType(DecoratedBox)).first,
    );
    final badge = tester.getRect(find.ancestor(of: find.text('网页版'), matching: find.byType(DecoratedBox)).first);
    expect(glyph.left - tile.left, FeatureCard.padding);
    expect(glyph.top - tile.top, FeatureCard.padding);
    expect(tile.right - badge.right, FeatureCard.padding);
    expect(badge.center.dy, moreOrLessEquals(glyph.center.dy, epsilon: 0.01));
  });

  testWidgets('card: a feature tile takes the circle\'s place exactly', (tester) async {
    usePhoneView(tester);
    await tester.pumpWidget(
      _page(
        const TileGrid(
          children: [
            FeatureCard(key: ValueKey('icon'), icon: AppIcons.terminal, title: '终端', subtitle: '工作区里的终端', badge: '网页版'),
            FeatureCard(
              key: ValueKey('art'),
              art: FeatureTile(FeatureKind.terminal, size: FeatureCard.glyph),
              title: '终端',
              subtitle: '工作区里的终端',
              badge: '网页版',
            ),
          ],
        ),
      ),
    );
    await pumpFrames(tester);
    final iconCard = tester.getRect(find.byKey(const ValueKey('icon')));
    final artCard = tester.getRect(find.byKey(const ValueKey('art')));
    final circle = tester.getRect(
      find.ancestor(of: find.byIcon(AppIcons.terminal), matching: find.byType(DecoratedBox)).first,
    );
    final art = tester.getRect(find.byType(FeatureTile));
    expect(art.size, const Size.square(FeatureCard.glyph));
    expect(art.topLeft - artCard.topLeft, circle.topLeft - iconCard.topLeft);
    expect(artCard.height, iconCard.height);
  });

  testWidgets('list row: 16 on both sides, glyph centred in its 32 column', (tester) async {
    usePhoneView(tester);
    await tester.pumpWidget(
      _page(
        ListPageCard(
          title: '规则',
          children: [
            ListPageRow(
              key: const ValueKey('row'),
              icon: AppIcons.appRules,
              title: '应用名单',
              subtitle: '4 个不碰 · 1 个每步确认',
              onTap: () {},
            ),
            const ListPageRow(key: ValueKey('value'), icon: AppIcons.web, title: '时区', value: 'Asia/Shanghai'),
          ],
        ),
      ),
    );
    await pumpFrames(tester);
    final row = tester.getRect(find.byKey(const ValueKey('row')));
    final glyph = tester.getRect(find.byIcon(AppIcons.appRules));
    final chevron = tester.getRect(find.byIcon(AppIcons.disclosure));
    final title = tester.getRect(find.text('应用名单'));
    final group = tester.getRect(find.text('规则'));
    final card = tester.getRect(find.byType(GlassSurface));

    expect(row.left, card.left);
    expect(row.right, card.right);
    // The 32 glyph column starts 16 in; the icon sits in its middle.
    expect(glyph.center.dx - row.left, ListPageRow.horizontal + 16);
    expect(row.right - (chevron.left + OverviewChevron.inkRight), closeTo(16, 0.5));
    expect(title.left - row.left, ListPageRow.horizontal + ListPageRow.glyphSlot + ListPageRow.gap);
    // Two-line rows are at least 64 tall, single-line ones 52.
    expect(row.height, greaterThanOrEqualTo(64));
    expect(tester.getSize(find.byKey(const ValueKey('value'))).height, greaterThanOrEqualTo(52));
    // A value ends on the same right inset as the chevron's ink.
    expect(tester.getRect(find.text('Asia/Shanghai')).right, row.right - ListPageRow.horizontal);
    // Group title: 8 in from the card, i.e. on the page's 24 column.
    expect(group.left - card.left, 8);
  });

  testWidgets('value, chevron, login capsule and switch share the visible right edge', (tester) async {
    usePhoneView(tester);
    await tester.pumpWidget(
      _page(
        ListPageCard(
          children: [
            const ListPageRow(title: '数值', value: '123'),
            ListPageRow(title: '箭头', onTap: () {}),
            ListPageRow(
              title: '账号',
              trailing: LoginCapsule(onPressed: () {}),
            ),
            ListPageRow(
              key: const ValueKey('switch-row'),
              title: '开关',
              subtitle: '第二行',
              trailing: Switch(value: false, onChanged: (_) {}),
            ),
          ],
        ),
      ),
    );
    await pumpFrames(tester);
    final card = tester.getRect(find.byType(GlassSurface));
    final chevron = tester.getRect(find.byIcon(AppIcons.disclosure));
    final switchBox = tester.getRect(find.byType(Switch));
    for (final edge in [
      tester.getRect(find.text('123')).right,
      chevron.left + OverviewChevron.inkRight,
      tester.getRect(find.byType(LoginCapsule)).right,
      switchBox.right - 4,
    ]) {
      expect(card.right - edge, closeTo(16, 0.5));
    }
    expect(tester.getRect(find.byKey(const ValueKey('switch-row'))).height, closeTo(64, 0.01));
  });

  testWidgets('feature corner glyph and hit area stay centred on the 14 gutter', (tester) async {
    usePhoneView(tester);
    await tester.pumpWidget(
      _page(
        TileGrid(
          children: [
            FeatureCard(
              key: const ValueKey('corner-tile'),
              icon: AppIcons.folder,
              title: '文件',
              onTap: () {},
              corner: IconButton(
                padding: EdgeInsets.zero,
                iconSize: FeatureCard.cornerIcon,
                onPressed: () {},
                icon: const Icon(AppIcons.webApp),
              ),
            ),
          ],
        ),
      ),
    );
    await pumpFrames(tester);
    final tile = tester.getRect(find.byKey(const ValueKey('corner-tile')));
    final globe = tester.getRect(find.byIcon(AppIcons.webApp));
    final button = tester.getRect(find.byType(IconButton));
    final leading = tester.getRect(find.byIcon(AppIcons.folder));
    expect(tile.right - globe.right, closeTo(14, 0.01));
    expect(globe.center.dy, closeTo(leading.center.dy, 0.01));
    expect(button.width, closeTo(36, 0.01));
    expect(button.center.dx, closeTo(globe.center.dx, 0.01));
  });
}

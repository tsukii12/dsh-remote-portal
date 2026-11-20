// Golden screenshots of the shared frame pieces other screens build on: the
// secondary page (large title, and a detail page with a PageHero), a glass
// sheet with its header, and the empty view.
//
//   flutter test --update-goldens test/shell/common_golden_test.dart

import 'package:dsh_app/ui/common/app_sheet.dart';
import 'package:dsh_app/ui/common/empty_view.dart';
import 'package:dsh_app/ui/common/page_hero.dart';
import 'package:dsh_app/ui/common/status_dot.dart';
import 'package:dsh_app/ui/shell/page_frame.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'golden_harness.dart';

List<Widget> _rows() => [
  const PageSectionLabel('常用'),
  SheetGroup(
    children: [
      for (final (icon, title) in const [
        (AppIcons.automation, '自动化'),
        (AppIcons.history, '后台任务'),
        (AppIcons.plugin, '插件'),
      ])
        // Plain rows: ListTile's theme style has no font family, which the
        // test renderer draws as boxes.
        SizedBox(
          height: 52,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Icon(icon, size: 20),
                const SizedBox(width: 14),
                Expanded(child: Text(title)),
              ],
            ),
          ),
        ),
    ],
  ),
];

void _noop() {}

void main() {
  goldenBoth('page_large_title', () => AppPage.list(title: '全部功能', children: _rows()));

  goldenBoth(
    'page_hero',
    () => AppPage(
      title: '引擎',
      hero: PageHero(
        leading: SizedBox.square(
          dimension: 56,
          child: Builder(
            builder: (context) => DecoratedBox(
              decoration: ShapeDecoration(
                color: Theme.of(context).colorScheme.primaryContainer,
                shape: const CircleBorder(),
              ),
              child: Icon(AppIcons.engine, color: Theme.of(context).colorScheme.onPrimaryContainer),
            ),
          ),
        ),
        title: '本机引擎',
        subtitle: const Row(
          children: [
            StatusDot(tone: StatusTone.ok, size: 7),
            SizedBox(width: 6),
            Text('运行中 · DSH 0.2.1'),
          ],
        ),
        stats: const [('2 小时', '已运行'), ('34', '对话'), ('1.2 GB', '占用')],
      ),
      slivers: [SliverList.list(children: _rows())],
    ),
  );

  // The page scrolled: the hero has faded and the title sits in the bar.
  goldenBoth(
    'page_hero_scrolled',
    () => AppPage(
      title: '引擎',
      hero: const PageHero(title: '本机引擎', subtitle: Text('运行中'), stats: [('2 小时', '已运行'), ('34', '对话')]),
      slivers: [
        SliverList.list(children: [for (var i = 0; i < 4; i++) ..._rows()]),
      ],
    ),
    before: (tester) async {
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -160));
      await tester.pump(const Duration(milliseconds: 600));
    },
  );

  goldenBoth(
    'sheet_header',
    () => Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: TextButton(
            onPressed: () => showAppSheet<void>(
              context,
              builder: (_) => SafeArea(
                top: false,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SheetHeader('切换主机'),
                    SheetGroup(
                      children: [
                        for (final (icon, title, on) in const [
                          (AppIcons.thisPhone, '本机', true),
                          (AppIcons.terminal, '电脑', false),
                        ])
                          SizedBox(
                            height: 52,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 16),
                              child: Row(
                                children: [
                                  Icon(icon, size: 20),
                                  const SizedBox(width: 14),
                                  Expanded(child: Text(title)),
                                  if (on) Icon(AppIcons.selected, color: Theme.of(context).colorScheme.primary),
                                ],
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 12),
                  ],
                ),
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ),
    before: (tester) async {
      await tester.tap(find.text('open'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
    },
  );

  goldenBoth(
    'empty_view',
    () => Scaffold(
      backgroundColor: Colors.transparent,
      body: AppBackdrop(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            EmptyView(
              icon: AppIcons.time,
              title: '还没有自动化任务',
              message: '定时让 DSH 帮你跑一遍',
              actionLabel: '新建',
              onAction: _noop,
            ),
            const SizedBox(height: 64),
            EmptyView(
              compact: true,
              icon: AppIcons.offline,
              title: '对话列表加载失败',
              message: '与主机的连接可能已断开',
              actionLabel: '重试',
              onAction: () {},
            ),
          ],
        ),
      ),
    ),
  );
}

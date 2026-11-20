import 'package:dsh_app/ui/common/app_sheet.dart';
import 'package:dsh_app/ui/common/segmented_pill.dart';
import 'package:dsh_app/ui/common/sheet_navigator.dart';
import 'package:dsh_app/ui/common/sheet_title_bar.dart';
import 'package:dsh_app/ui/common/status_chip.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../shell/golden_harness.dart';
import '../support/semantics_tap_check.dart';

void main() {
  for (final scale in [1.0, 2.0]) {
    testWidgets('sheet title bar geometry and semantics at text scale $scale', (tester) async {
      final semantics = tester.ensureSemantics();
      usePhoneSurface(tester);
      await tester.pumpWidget(
        goldenApp(
          brightness: Brightness.light,
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showAppSheet<void>(
                  context,
                  dismissal: SheetDismissal.button,
                  builder: (_) => MediaQuery.withClampedTextScaling(
                    minScaleFactor: scale,
                    maxScaleFactor: scale,
                    child: SheetNavigator(
                      root: (sheet) => Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const SheetHeader('一级标题'),
                          const SheetGroup(title: '组内标题', children: [SizedBox(height: 16)]),
                          TextButton(
                            onPressed: () => SheetNavigator.of(sheet).push((_) => const SheetHeader('二级标题')),
                            child: const Text('下一页'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      void measure(String label, bool secondary) {
        final bar = tester.getRect(find.byType(SheetTitleBar));
        final text = tester.getRect(find.text(label));
        final close = tester.getRect(
          find.descendant(of: find.byTooltip('关闭'), matching: find.byType(DecoratedBox)).first,
        );
        expect(text.left - bar.left, closeTo(secondary ? 62 : 20, 0.01));
        expect(bar.right - close.right, closeTo(20, 0.01));
        expect(close.center.dy, closeTo(text.center.dy, 0.5));
        expect(bar.height, greaterThanOrEqualTo(text.height));
        expect(tester.getSemantics(find.text(label)), isSemantics(label: label, isHeader: true));
        if (secondary) {
          final back = tester.getRect(
            find.descendant(of: find.byTooltip('返回'), matching: find.byType(DecoratedBox)).first,
          );
          expect(back.left - bar.left, closeTo(20, 0.01));
          expect(back.center.dy, closeTo(close.center.dy, 0.01));
        }
        expectAllButtonsTappable();
        expect(tester.takeException(), isNull);
      }

      measure('一级标题', false);
      expect(tester.getRect(find.text('组内标题')).left, closeTo(28, 0.01));
      await tester.tap(find.text('下一页'));
      await tester.pumpAndSettle();
      measure('二级标题', true);
      tester.semantics.tap(find.semantics.byLabel('返回'));
      await tester.pumpAndSettle();
      expect(find.text('一级标题'), findsOneWidget);
      tester.semantics.tap(find.semantics.byLabel('关闭'));
      await tester.pumpAndSettle();
      expect(find.byType(SheetTitleBar), findsNothing);
      semantics.dispose();
    });
  }

  testWidgets('action keys sit as close to each other as to the close key', (tester) async {
    usePhoneSurface(tester);
    await tester.pumpWidget(
      goldenApp(
        brightness: Brightness.light,
        home: Scaffold(
          body: SheetHeader(
            '标题',
            actions: [
              SheetIconButton(icon: AppIcons.copy, tooltip: '复制', onPressed: () {}),
              SheetIconButton(icon: AppIcons.share, tooltip: '分享', onPressed: () {}),
            ],
          ),
        ),
      ),
    );
    Rect circle(String tooltip) =>
        tester.getRect(find.descendant(of: find.byTooltip(tooltip), matching: find.byType(DecoratedBox)).first);
    final copy = circle('复制');
    final share = circle('分享');
    final close = circle('关闭');
    expect(share.left - copy.right, closeTo(12, 0.01));
    expect(close.left - share.right, closeTo(12, 0.01));
    expect(tester.getRect(find.byType(SheetTitleBar)).right - close.right, closeTo(20, 0.01));
    for (final key in [copy, share]) {
      expect(key.center.dy, closeTo(close.center.dy, 0.01));
    }
  });

  testWidgets('segmented and status buttons respond to semantic taps', (tester) async {
    final semantics = tester.ensureSemantics();
    var picked = 0;
    var statusTaps = 0;
    await tester.pumpWidget(
      goldenApp(
        brightness: Brightness.light,
        home: Scaffold(
          body: Column(
            children: [
              SegmentedPill<int>(
                segments: const [PillSegment(0, '选项甲'), PillSegment(1, '选项乙')],
                selected: 0,
                onChanged: (value) => picked = value,
              ),
              StatusChip(tone: StatusTone.ok, label: '状态按钮', onTap: () => statusTaps++),
            ],
          ),
        ),
      ),
    );
    expectAllButtonsTappable();
    tester.semantics.tap(find.semantics.byLabel('选项乙'));
    tester.semantics.tap(find.semantics.byLabel('状态按钮'));
    await tester.pump();
    expect(picked, 1);
    expect(statusTaps, 1);
    semantics.dispose();
  });
}

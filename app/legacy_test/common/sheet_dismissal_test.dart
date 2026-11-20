import 'dart:ui' show SemanticsAction;

import 'package:dsh_app/ui/common/app_sheet.dart';
import 'package:dsh_app/ui/common/discard_guard.dart';
import 'package:dsh_app/ui/common/sheet_navigator.dart';
import 'package:dsh_app/ui/common/sheet_title_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../shell/golden_harness.dart';

Future<void> _open(
  WidgetTester tester, {
  SheetDismissal? dismissal,
  bool glass = true,
  Brightness brightness = Brightness.light,
  double width = 390,
  double scale = 1,
  double? heightFactor,
  bool canPop = true,
  VoidCallback? onBlocked,
  Widget? content,
  bool animations = false,
}) async {
  usePhoneSurface(tester);
  tester.view.physicalSize = Size(width * 2, 844 * 2);
  await tester.pumpWidget(
    goldenApp(
      brightness: brightness,
      animations: animations,
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => showAppSheet<void>(
              context,
              glass: glass,
              dismissal: dismissal,
              heightFactor: heightFactor,
              builder: (_) => PopScope<void>(
                canPop: canPop,
                onPopInvokedWithResult: (didPop, _) {
                  if (!didPop) onBlocked?.call();
                },
                child: MediaQuery.withClampedTextScaling(
                  minScaleFactor: scale,
                  maxScaleFactor: scale,
                  child:
                      content ??
                      const Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          SheetHeader('弹层标题'),
                          Padding(
                            padding: EdgeInsets.symmetric(horizontal: kSheetGutter),
                            child: Text('说明文字'),
                          ),
                          SizedBox(height: 120),
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
}

void main() {
  for (final glass in [true, false]) {
    for (final brightness in Brightness.values) {
      for (final width in [320.0, 390.0]) {
        for (final scale in [1.0, 2.0]) {
          testWidgets('one handle, symmetric title: glass=$glass $brightness width=$width scale=$scale', (
            tester,
          ) async {
            final semantics = tester.ensureSemantics();
            await _open(tester, glass: glass, brightness: brightness, width: width, scale: scale);
            expect(find.byType(SheetDragHandle), findsOneWidget);
            expect(find.byTooltip('关闭'), findsNothing);
            final bar = tester.getRect(find.byType(SheetTitleBar));
            final title = tester.getRect(find.text('弹层标题'));
            expect(title.left - bar.left, closeTo(20, 0.01));
            expect(bar.right - title.right, closeTo(20, 0.01));
            final handle = tester.getRect(find.byType(SheetDragHandle));
            expect(handle.height, greaterThanOrEqualTo(48));
            expect(handle.center.dx, closeTo(bar.center.dx, 0.01));
            final data = tester.getSemantics(find.byType(SheetDragHandle)).getSemanticsData();
            expect(data.label, '关闭');
            expect(data.hasAction(SemanticsAction.tap), isTrue);
            expect(data.hasAction(SemanticsAction.dismiss), isTrue);
            expect(tester.takeException(), isNull);
            semantics.dispose();
          });
        }
      }
    }
    for (final operation in ['tap', 'semantics tap', 'semantics dismiss', 'drag', 'barrier', 'system back']) {
      testWidgets('draggable sheet closes by $operation, glass=$glass', (tester) async {
        final semantics = tester.ensureSemantics();
        await _open(tester, glass: glass);
        final handle = find.byType(SheetDragHandle);
        final id = tester.getSemantics(handle).id;
        final semanticHandle = find.semantics.byPredicate((node) => node.id == id);
        switch (operation) {
          case 'tap':
            await tester.tap(handle);
          case 'semantics tap':
            tester.semantics.tap(semanticHandle);
          case 'semantics dismiss':
            tester.semantics.dismiss(semanticHandle);
          case 'drag':
            await tester.fling(handle, const Offset(0, 240), 1500);
          case 'barrier':
            await tester.tapAt(const Offset(195, 100));
          case 'system back':
            await tester.binding.handlePopRoute();
        }
        await tester.pumpAndSettle();
        expect(find.byType(SheetTitleBar), findsNothing);
        expect(tester.takeException(), isNull);
        semantics.dispose();
      });
    }

    testWidgets('button policy has no handle and rejects drag/barrier, glass=$glass', (tester) async {
      await _open(tester, glass: glass, dismissal: SheetDismissal.button);
      expect(find.byType(SheetDragHandle), findsNothing);
      expect(find.byTooltip('关闭'), findsOneWidget);
      await tester.tapAt(const Offset(195, 100));
      await tester.pumpAndSettle();
      expect(find.byType(SheetTitleBar), findsOneWidget);
      await tester.fling(find.byType(SheetTitleBar), const Offset(0, 240), 1500);
      await tester.pumpAndSettle();
      expect(find.byType(SheetTitleBar), findsOneWidget);
      await tester.tap(find.byTooltip('关闭'));
      await tester.pumpAndSettle();
      expect(find.byType(SheetTitleBar), findsNothing);
    });
  }

  testWidgets('fixed height defaults to the button policy without a caller edit', (tester) async {
    await _open(tester, heightFactor: 0.85);
    expect(find.byType(SheetDragHandle), findsNothing);
    expect(find.byTooltip('关闭'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(SheetTitleBar), findsNothing);
  });

  testWidgets('an explicit drag policy can opt a sized draggable sheet in', (tester) async {
    await _open(tester, heightFactor: 0.6, dismissal: SheetDismissal.drag);
    expect(find.byType(SheetDragHandle), findsOneWidget);
    expect(find.byTooltip('关闭'), findsNothing);
    await tester.fling(find.byType(SheetDragHandle), const Offset(0, 450), 1800);
    await tester.pumpAndSettle();
    expect(find.byType(SheetTitleBar), findsNothing);
  });

  for (final dismissal in SheetDismissal.values) {
    testWidgets('explicit dismissal respects a PopScope: $dismissal', (tester) async {
      var blocked = 0;
      await _open(tester, dismissal: dismissal, canPop: false, onBlocked: () => blocked++);
      await tester.tap(dismissal == SheetDismissal.drag ? find.byType(SheetDragHandle) : find.byTooltip('关闭'));
      await tester.pumpAndSettle();
      expect(blocked, 1);
      expect(find.byType(SheetTitleBar), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(blocked, 2);
      expect(find.byType(SheetTitleBar), findsOneWidget);
    });
  }

  testWidgets('button close goes through the real unsaved-edit confirmation', (tester) async {
    final draft = TextEditingController(text: '未保存');
    addTearDown(draft.dispose);
    await _open(
      tester,
      dismissal: SheetDismissal.button,
      content: DiscardGuard(
        listenable: draft,
        isDirty: () => draft.text.isNotEmpty,
        child: const Column(mainAxisSize: MainAxisSize.min, children: [SheetHeader('草稿'), SizedBox(height: 80)]),
      ),
    );
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.tap(find.text('继续编辑'));
    await tester.pumpAndSettle();
    expect(find.text('草稿'), findsOneWidget);
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('放弃'));
    await tester.pumpAndSettle();
    expect(find.byType(SheetTitleBar), findsNothing);
    expect(find.byType(AlertDialog), findsNothing);
  });

  group('unsaved input holds a draggable sheet', () {
    Future<TextEditingController> openDraft(WidgetTester tester, String text, {bool animations = false}) async {
      final draft = TextEditingController(text: text);
      addTearDown(draft.dispose);
      await _open(
        tester,
        dismissal: SheetDismissal.drag,
        animations: animations,
        content: DiscardGuard(
          listenable: draft,
          isDirty: () => draft.text.isNotEmpty,
          child: const Column(mainAxisSize: MainAxisSize.min, children: [SheetHeader('草稿'), SizedBox(height: 80)]),
        ),
      );
      return draft;
    }

    testWidgets('a drag asks first, springs back on 继续编辑, closes on 放弃', (tester) async {
      final draft = await openDraft(tester, '未保存');
      final handle = find.byType(SheetDragHandle);
      final rest = tester.getTopLeft(handle);
      await tester.fling(handle, const Offset(0, 240), 1500);
      await tester.pumpAndSettle();
      expect(find.text('放弃修改？'), findsOneWidget);
      await tester.tap(find.text('继续编辑'));
      await tester.pumpAndSettle();
      expect(find.text('草稿'), findsOneWidget);
      expect(draft.text, '未保存');
      expect(tester.getTopLeft(handle), rest);
      // From the content too, not only the handle.
      await tester.fling(find.text('草稿'), const Offset(0, 240), 1500);
      await tester.pumpAndSettle();
      await tester.tap(find.text('放弃'));
      await tester.pumpAndSettle();
      expect(find.byType(SheetTitleBar), findsNothing);
      expect(find.byType(AlertDialog), findsNothing);
    });

    testWidgets('flicked back up, it brakes into place and never past it', (tester) async {
      await openDraft(tester, '未保存', animations: true);
      final handle = find.byType(SheetDragHandle);
      final rest = tester.getTopLeft(handle).dy;
      var time = Duration.zero;
      final finger = await tester.startGesture(tester.getCenter(handle));
      for (var i = 0; i < 10; i++) {
        time += const Duration(milliseconds: 40);
        await finger.moveBy(const Offset(0, 8), timeStamp: time);
        await tester.pump(const Duration(milliseconds: 40));
      }
      for (var i = 0; i < 8; i++) {
        time += const Duration(milliseconds: 4);
        await finger.moveBy(const Offset(0, -2), timeStamp: time);
      }
      await finger.up(timeStamp: time);
      await tester.pump();
      for (var i = 0; i < 60; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        expect(tester.getTopLeft(handle).dy, greaterThanOrEqualTo(rest));
      }
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(handle).dy, rest);
    });

    testWidgets('caught on its way back, it carries on from where it is', (tester) async {
      await openDraft(tester, '未保存', animations: true);
      final handle = find.byType(SheetDragHandle);
      final rest = tester.getTopLeft(handle).dy;
      final first = await tester.startGesture(tester.getCenter(handle));
      for (var i = 0; i < 10; i++) {
        await first.moveBy(const Offset(0, 8));
        await tester.pump(const Duration(milliseconds: 40));
      }
      await first.up();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 32));
      final caught = tester.getTopLeft(handle).dy;
      expect(caught, greaterThan(rest + 8), reason: 'still on its way back');

      final second = await tester.startGesture(tester.getCenter(handle));
      await second.moveBy(const Offset(0, 24));
      await tester.pump();
      await second.moveBy(const Offset(0, 4));
      await tester.pump();
      expect(tester.getTopLeft(handle).dy, greaterThanOrEqualTo(caught));
      await second.up();
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(handle).dy, rest);
    });

    testWidgets('nothing typed: the drag closes at once', (tester) async {
      await openDraft(tester, '');
      await tester.fling(find.byType(SheetDragHandle), const Offset(0, 240), 1500);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byType(SheetTitleBar), findsNothing);
    });

    testWidgets('a bare PopScope (back = up a level) does not hold the drag', (tester) async {
      var blocked = 0;
      await _open(tester, dismissal: SheetDismissal.drag, canPop: false, onBlocked: () => blocked++);
      await tester.fling(find.byType(SheetDragHandle), const Offset(0, 240), 1500);
      await tester.pumpAndSettle();
      expect(blocked, 0);
      expect(find.byType(SheetTitleBar), findsNothing);
    });
  });

  testWidgets('nested page back stays local and the one handle still closes the route', (tester) async {
    await _open(
      tester,
      content: SheetNavigator(
        root: (context) => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SheetHeader('一级'),
            TextButton(
              onPressed: () => SheetNavigator.of(context).push((_) => const SheetHeader('二级')),
              child: const Text('下一页'),
            ),
          ],
        ),
      ),
    );
    await tester.tap(find.text('下一页'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('返回'), findsOneWidget);
    expect(find.byTooltip('关闭'), findsNothing);
    expect(find.byType(SheetDragHandle), findsOneWidget);
    await tester.tap(find.byTooltip('返回'));
    await tester.pumpAndSettle();
    expect(find.text('一级'), findsOneWidget);
    await tester.tap(find.byType(SheetDragHandle));
    await tester.pumpAndSettle();
    expect(find.byType(SheetTitleBar), findsNothing);
  });

  for (final brightness in Brightness.values) {
    for (final dismissal in SheetDismissal.values) {
      testWidgets('golden single affordance $brightness $dismissal', (tester) async {
        await _open(tester, brightness: brightness, dismissal: dismissal, width: 320, scale: 2);
        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile('goldens/sheet_dismissal_${brightness.name}_${dismissal.name}.png'),
        );
      });
    }
  }
}

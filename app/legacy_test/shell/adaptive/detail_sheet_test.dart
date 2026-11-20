// The medium-window detail sheet with a stand-in body: its width and
// centring, the two heights (half and full), the handle and drags that move
// between them, a drag that closes it, and folding into the panel when the
// window turns wide.
//
//   flutter test test/shell/adaptive/detail_sheet_test.dart

import 'package:dsh_app/ui/shell/adaptive/detail_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../chat/support/harness.dart';

const _top = 24.0;
const _bottom = 16.0;

void _window(WidgetTester tester, Size size) {
  tester.view.devicePixelRatio = 2;
  tester.view.physicalSize = size * 2;
  const pad = FakeViewPadding(top: _top * 2, bottom: _bottom * 2);
  tester.view.padding = pad;
  tester.view.viewPadding = pad;
  addTearDown(tester.view.reset);
}

final _sheet = find.byKey(const ValueKey('detail-sheet'));

Future<void> _open(WidgetTester tester, {VoidCallback? onWide, bool canPop = true}) async {
  await tester.pumpWidget(
    testApp(
      Builder(
        builder: (context) => Center(
          child: TextButton(
            onPressed: () => showDetailSheet(
              context,
              onWide: onWide,
              builder: (context) => PopScope<void>(
                canPop: canPop,
                child: Column(
                  children: [
                    // The content's own title row moves the sheet too.
                    DetailSheetScope.maybeOf(context)!.dragArea(
                      const SizedBox(
                        key: ValueKey('title-row'),
                        height: 52,
                        width: double.infinity,
                        child: ColoredBox(color: Color(0x00000000)),
                      ),
                    ),
                    const Expanded(child: SizedBox.expand()),
                  ],
                ),
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('720 × 900: full width, half the window tall', (tester) async {
    _window(tester, const Size(720, 900));
    await _open(tester);
    expect(tester.getRect(_sheet), const Rect.fromLTWH(0, 450, 720, 450));
  });

  testWidgets('wider windows: the reading width, centred', (tester) async {
    _window(tester, const Size(820, 900));
    await _open(tester);
    final sheet = tester.getRect(_sheet);
    expect(sheet.width, 744);
    expect(sheet.left, 820 - sheet.right);
    expect(sheet.bottom, 900);
  });

  testWidgets('the handle: half ↔ full (status bar + 12 clear)', (tester) async {
    final semantics = tester.ensureSemantics();
    _window(tester, const Size(720, 900));
    await _open(tester);
    final handle = find.bySemanticsLabel('展开');
    expect(handle, findsOneWidget);
    await tester.tap(handle);
    await tester.pumpAndSettle();
    expect(tester.getRect(_sheet).top, _top + 12);
    expect(find.bySemanticsLabel('收起'), findsOneWidget);
    await tester.tap(find.bySemanticsLabel('收起'));
    await tester.pumpAndSettle();
    expect(tester.getRect(_sheet).top, 450);
    semantics.dispose();
  });

  testWidgets('resize handle exposes semantic dismiss at half and full height', (tester) async {
    final semantics = tester.ensureSemantics();
    _window(tester, const Size(720, 900));
    for (final full in [false, true]) {
      await _open(tester);
      if (full) {
        await tester.tap(find.bySemanticsLabel('展开'));
        await tester.pumpAndSettle();
      }
      tester.semantics.dismiss(find.semantics.byLabel(full ? '收起' : '展开'));
      await tester.pumpAndSettle();
      expect(_sheet, findsNothing);
    }
    semantics.dispose();
  });

  testWidgets('drags snap to the nearer height or fling past it', (tester) async {
    _window(tester, const Size(720, 900));
    await _open(tester);
    final title = find.byKey(const ValueKey('title-row'));
    // A short pull up from the title row falls back to half.
    await tester.drag(title, const Offset(0, -120));
    await tester.pumpAndSettle();
    expect(tester.getRect(_sheet).top, 450);
    // Past the middle: full.
    await tester.drag(title, const Offset(0, -260));
    await tester.pumpAndSettle();
    expect(tester.getRect(_sheet).top, _top + 12);
    // A fling down: half again (not closed).
    await tester.fling(title, const Offset(0, 120), 1500);
    await tester.pumpAndSettle();
    expect(tester.getRect(_sheet).top, 450);
  });

  testWidgets('a pull down from half closes it; a nudge does not', (tester) async {
    _window(tester, const Size(720, 900));
    await _open(tester);
    final title = find.byKey(const ValueKey('title-row'));
    await tester.drag(title, const Offset(0, 60));
    await tester.pumpAndSettle();
    expect(tester.getRect(_sheet).top, 450);
    await tester.drag(title, const Offset(0, 200));
    await tester.pumpAndSettle();
    expect(_sheet, findsNothing);
  });

  group('a release carries the finger on', () {
    final title = find.byKey(const ValueKey('title-row'));

    /// How far the sheet's top moves in the two frames after a release.
    Future<double> movedAfterRelease(WidgetTester tester) async {
      await tester.pump();
      final from = tester.getRect(_sheet).top;
      await tester.pump(const Duration(milliseconds: 16));
      return (tester.getRect(_sheet).top - from).abs();
    }

    Future<void> toFull(WidgetTester tester) async {
      await tester.drag(title, const Offset(0, -300));
      await tester.pumpAndSettle();
      expect(tester.getRect(_sheet).top, _top + 12);
    }

    testWidgets('between the heights: at its speed, not from a standstill', (tester) async {
      _window(tester, const Size(720, 900));
      await _open(tester);
      await toFull(tester);
      await tester.fling(title, const Offset(0, 120), 2000);
      final flung = await movedAfterRelease(tester);
      expect(flung, greaterThan(20), reason: '2000 px/s is 32 px a frame, before the spring has braked');
      await tester.pumpAndSettle();
      expect(tester.getRect(_sheet).top, 450);

      await toFull(tester);
      await tester.drag(title, const Offset(0, 120));
      final let = await movedAfterRelease(tester);
      expect(let, lessThan(10));
      await tester.pumpAndSettle();
      expect(tester.getRect(_sheet).top, _top + 12);
    });

    testWidgets('a hard fling lands on the half height without sinking past it', (tester) async {
      _window(tester, const Size(720, 900));
      await _open(tester);
      await toFull(tester);
      await tester.fling(title, const Offset(0, 370), 6000);
      await tester.pump();
      for (var i = 0; i < 60; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        expect(tester.getRect(_sheet).top, lessThanOrEqualTo(450));
      }
      await tester.pumpAndSettle();
      expect(tester.getRect(_sheet).top, 450);
    });

    testWidgets('closing: it leaves at its speed, and the scrim goes with it', (tester) async {
      _window(tester, const Size(720, 900));
      await _open(tester);
      await tester.fling(title, const Offset(0, 120), 2000);
      expect(await movedAfterRelease(tester), greaterThan(20));
      await tester.pumpAndSettle();
      expect(_sheet, findsNothing);
    });

    testWidgets('pulled far down then flicked back up: it stays', (tester) async {
      _window(tester, const Size(720, 900));
      await _open(tester);
      var time = Duration.zero;
      final finger = await tester.startGesture(tester.getCenter(title));
      for (var i = 0; i < 10; i++) {
        time += const Duration(milliseconds: 50);
        await finger.moveBy(const Offset(0, 22), timeStamp: time);
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(tester.getRect(_sheet).top, greaterThan(450 + 450 * 0.25));
      for (var i = 0; i < 8; i++) {
        time += const Duration(milliseconds: 8);
        await finger.moveBy(const Offset(0, -16), timeStamp: time);
      }
      await finger.up(timeStamp: time);
      await tester.pumpAndSettle();
      expect(tester.getRect(_sheet).top, 450);
    });

    testWidgets('content that refuses to pop: back up to the half height', (tester) async {
      _window(tester, const Size(720, 900));
      await _open(tester, canPop: false);
      await tester.drag(title, const Offset(0, 200));
      await tester.pumpAndSettle();
      expect(tester.getRect(_sheet).top, 450);
      // And it can still go by the next drag.
      await tester.drag(title, const Offset(0, -300));
      await tester.pumpAndSettle();
      expect(tester.getRect(_sheet).top, _top + 12);
    });

    testWidgets('past the full height: a rubber band that lets go exactly', (tester) async {
      _window(tester, const Size(720, 900));
      await _open(tester);
      await toFull(tester);
      final finger = await tester.startGesture(tester.getCenter(title));
      for (var i = 0; i < 30; i++) {
        await finger.moveBy(const Offset(0, -20));
        await tester.pump(const Duration(milliseconds: 16));
      }
      final past = _top + 12 - tester.getRect(_sheet).top;
      expect(past, greaterThan(10), reason: 'it gives');
      expect(past, lessThanOrEqualTo(48), reason: 'it gives only so much');
      expect(tester.getRect(_sheet).bottom, 900);
      await finger.up();
      await tester.pumpAndSettle();
      expect(tester.getRect(_sheet), Rect.fromLTRB(0, _top + 12, 720, 900));
    });

    testWidgets('remove animations: every release lands within the frame', (tester) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(
        disableAnimations: true,
      );
      addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
      _window(tester, const Size(720, 900));
      await _open(tester);
      await tester.drag(title, const Offset(0, -300));
      await tester.pump();
      expect(tester.getRect(_sheet).top, _top + 12);
      await tester.fling(title, const Offset(0, 120), 2000);
      await tester.pump();
      expect(tester.getRect(_sheet).top, 450);
      await tester.fling(title, const Offset(0, 120), 2000);
      await tester.pump();
      await tester.pump();
      expect(_sheet, findsNothing);
    });
  });

  testWidgets('a tap on the scrim closes it', (tester) async {
    _window(tester, const Size(720, 900));
    await _open(tester);
    await tester.tapAt(const Offset(360, 120));
    await tester.pumpAndSettle();
    expect(_sheet, findsNothing);
  });

  testWidgets('turning wide hands over to the panel', (tester) async {
    _window(tester, const Size(720, 900));
    var wide = 0;
    await _open(tester, onWide: () => wide++);
    _window(tester, const Size(1280, 800));
    await tester.pumpAndSettle();
    expect(wide, 1);
    expect(_sheet, findsNothing);
  });
}

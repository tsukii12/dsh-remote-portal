import 'package:dsh_app/ui/chat/widgets/image_gallery.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Finder page(int index) => find.byKey(ValueKey('picture-$index'));

Matrix4 transformOf(WidgetTester tester, int index) =>
    tester.widget<Transform>(find.ancestor(of: page(index), matching: find.byType(Transform)).first).transform;

Future<void> doubleTap(WidgetTester tester, Offset at) async {
  await tester.tapAt(at);
  await tester.pump(const Duration(milliseconds: 80));
  await tester.tapAt(at);
  await tester.pumpAndSettle();
}

Future<void> pumpGallery(
  WidgetTester tester, {
  int initial = 0,
  ValueChanged<int>? onPageChanged,
  VoidCallback? onTap,
  ValueChanged<int>? onLongPress,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(400, 600);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: ImagePager(
          itemCount: 3,
          initialPage: initial,
          onPageChanged: onPageChanged,
          onTap: onTap,
          onLongPress: onLongPress,
          itemBuilder: (_, index) => ColoredBox(key: ValueKey('picture-$index'), color: Colors.blue),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('a large single-finger move turns the page; both ends stay bounded', (tester) async {
    final changed = <int>[];
    await pumpGallery(tester, initial: 1, onPageChanged: changed.add);
    expect(page(1).hitTestable(), findsOneWidget);
    // One event crosses both pan/drag slops: the image must still yield.
    await tester.dragFrom(const Offset(350, 300), const Offset(-300, 0));
    await tester.pumpAndSettle();
    expect(changed, [2]);
    expect(page(2).hitTestable(), findsOneWidget);
    await tester.fling(find.byType(PageView), const Offset(-300, 0), 1000);
    await tester.pumpAndSettle();
    expect(changed, [2]);
    await tester.fling(find.byType(PageView), const Offset(300, 0), 1000);
    await tester.pumpAndSettle();
    await tester.fling(find.byType(PageView), const Offset(300, 0), 1000);
    await tester.pumpAndSettle();
    expect(page(0).hitTestable(), findsOneWidget);
    await tester.fling(find.byType(PageView), const Offset(300, 0), 1000);
    await tester.pumpAndSettle();
    expect(changed, [2, 1, 0]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('double tap zooms at the touch; panning never turns or closes; reset restores paging', (tester) async {
    var taps = 0;
    final changed = <int>[];
    await pumpGallery(tester, onTap: () => taps++, onPageChanged: changed.add);
    await doubleTap(tester, const Offset(120, 200));
    expect(taps, 0);
    var matrix = transformOf(tester, 0);
    expect(matrix.getMaxScaleOnAxis(), ZoomableImage.doubleTapScale);
    expect(matrix.getTranslation().x, closeTo(-180, 0.01));
    expect(matrix.getTranslation().y, closeTo(-300, 0.01));
    await tester.dragFrom(const Offset(200, 300), const Offset(-150, -80));
    await tester.pumpAndSettle();
    expect(changed, isEmpty);
    expect(taps, 0);
    matrix = transformOf(tester, 0);
    expect(matrix.getTranslation().x, lessThan(-180));
    expect(matrix.getTranslation().y, lessThan(-300));
    await doubleTap(tester, const Offset(200, 300));
    expect(transformOf(tester, 0), Matrix4.identity());
    await tester.fling(find.byType(PageView), const Offset(-300, 0), 1000);
    await tester.pumpAndSettle();
    expect(changed, [1]);
    expect(transformOf(tester, 1), Matrix4.identity());
    await tester.fling(find.byType(PageView), const Offset(300, 0), 1000);
    await tester.pumpAndSettle();
    expect(transformOf(tester, 0), Matrix4.identity());
    expect(tester.takeException(), isNull);
  });

  testWidgets('pinch claims both fingers before a page drag, clamps scale and returns to fit', (tester) async {
    final changed = <int>[];
    await pumpGallery(tester, onPageChanged: changed.add);
    final left = await tester.startGesture(const Offset(150, 300), pointer: 1);
    final right = await tester.startGesture(const Offset(250, 300), pointer: 2);
    await left.moveTo(const Offset(50, 300));
    await right.moveTo(const Offset(350, 300));
    await tester.pump();
    expect(transformOf(tester, 0).getMaxScaleOnAxis(), closeTo(3, 0.01));
    expect(changed, isEmpty);
    await left.moveTo(const Offset(-800, 300));
    await right.moveTo(const Offset(1200, 300));
    await tester.pump();
    expect(transformOf(tester, 0).getMaxScaleOnAxis(), ZoomableImage.maxScale);
    await left.moveTo(const Offset(190, 300));
    await right.moveTo(const Offset(210, 300));
    await tester.pump();
    expect(transformOf(tester, 0), Matrix4.identity());
    await left.up();
    await right.up();
    await tester.pumpAndSettle();
    expect(changed, isEmpty);
    await tester.fling(find.byType(PageView), const Offset(-300, 0), 1000);
    await tester.pumpAndSettle();
    expect(changed, [1]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('single tap and long press remain distinct from double tap', (tester) async {
    var taps = 0;
    final longPresses = <int>[];
    await pumpGallery(tester, initial: 2, onTap: () => taps++, onLongPress: longPresses.add);
    await tester.tapAt(const Offset(200, 300));
    await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 20));
    expect(taps, 1);
    await tester.longPressAt(const Offset(200, 300));
    await tester.pumpAndSettle();
    expect(taps, 1);
    expect(longPresses, [2]);
    expect(transformOf(tester, 2), Matrix4.identity());
  });

  testWidgets('long press after a page turn belongs to the new page', (tester) async {
    final presses = <int>[];
    await pumpGallery(tester, initial: 1, onLongPress: presses.add);
    await tester.drag(find.byType(PageView), const Offset(-300, 0));
    await tester.pumpAndSettle();
    await tester.longPress(find.byType(ImagePager));
    await tester.pumpAndSettle();
    expect(presses, [2]);
  });

  testWidgets('out-of-range initial page is clamped consistently', (tester) async {
    await pumpGallery(tester, initial: 99);
    expect(page(2).hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

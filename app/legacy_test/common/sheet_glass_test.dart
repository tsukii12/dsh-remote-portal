// A sheet's glass blurs only at rest: the rise, the fall and a drag show an opaque
// fill, and the blur clears in once it stops, without the content noticing.
//
//   flutter test test/common/sheet_glass_test.dart

import 'package:dsh_app/ui/common/app_sheet.dart';
import 'package:dsh_app/ui/common/discard_guard.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Counted extends StatefulWidget {
  const _Counted(this.inits);

  final List<int> inits;

  @override
  State<_Counted> createState() => _CountedState();
}

class _CountedState extends State<_Counted> {
  @override
  void initState() {
    super.initState();
    widget.inits.add(1);
  }

  @override
  Widget build(BuildContext context) => const SizedBox(height: 240);
}

Future<void> _open(WidgetTester tester, Widget Function(BuildContext) builder) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildLightTheme(),
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => showAppSheet<void>(context, builder: builder),
            child: const Text('打开'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开'));
  await tester.pump();
}

final _sheetBlur = find.descendant(of: find.byType(BottomSheet), matching: find.byType(BackdropFilter));

bool _blurring(WidgetTester tester) => tester.widget<BackdropFilter>(_sheetBlur).enabled;

double _settled(WidgetTester tester) => tester
    .widget<GlassSurface>(find.descendant(of: find.byType(BottomSheet), matching: find.byType(GlassSurface)))
    .settled!;

void main() {
  testWidgets('no blur on the way up; at rest it clears in over a short fade', (tester) async {
    final inits = <int>[];
    await _open(tester, (_) => _Counted(inits));
    for (var t = 0; t < AppMotion.sheetIn.inMilliseconds - 40; t += 40) {
      await tester.pump(const Duration(milliseconds: 40));
      expect(_blurring(tester), isFalse, reason: 'at $t ms');
    }
    await tester.pump(const Duration(milliseconds: 80));
    await tester.pump(const Duration(milliseconds: 60));
    expect(_blurring(tester), isTrue);
    expect(_settled(tester), inExclusiveRange(0, 1));
    await tester.pumpAndSettle();
    expect(_settled(tester), 1);
    expect(tester.binding.hasScheduledFrame, isFalse);
    expect(inits.length, 1, reason: 'the blur coming on does not rebuild what is in the sheet');
  });

  testWidgets('a drag stops the blur at once, and letting go brings it back', (tester) async {
    await _open(tester, (_) => const SizedBox(height: 240, child: Text('内容')));
    await tester.pumpAndSettle();
    expect(_blurring(tester), isTrue);
    final finger = await tester.startGesture(tester.getCenter(find.text('内容')));
    await finger.moveBy(const Offset(0, 30));
    await tester.pump();
    await finger.moveBy(const Offset(0, 10));
    await tester.pump();
    expect(_blurring(tester), isFalse);
    await finger.up();
    await tester.pumpAndSettle();
    expect(_blurring(tester), isTrue);
    expect(_settled(tester), 1);
  });

  testWidgets('going down it does not blur either', (tester) async {
    await _open(tester, (_) => const SizedBox(height: 240, child: Text('内容')));
    await tester.pumpAndSettle();
    Navigator.of(tester.element(find.text('内容'))).pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    expect(_blurring(tester), isFalse);
    await tester.pumpAndSettle();
    expect(find.text('内容'), findsNothing);
  });

  testWidgets('a held sheet under the finger does not blur either', (tester) async {
    final draft = TextEditingController(text: '未保存');
    addTearDown(draft.dispose);
    await _open(
      tester,
      (_) => DiscardGuard(
        listenable: draft,
        isDirty: () => draft.text.isNotEmpty,
        child: const SizedBox(height: 240, child: Text('内容')),
      ),
    );
    await tester.pumpAndSettle();
    expect(_blurring(tester), isTrue);
    final finger = await tester.startGesture(tester.getCenter(find.text('内容')));
    await finger.moveBy(const Offset(0, 30));
    await tester.pump();
    await finger.moveBy(const Offset(0, 10));
    await tester.pump();
    expect(_blurring(tester), isFalse);
    await finger.up();
    await tester.pumpAndSettle();
    expect(_blurring(tester), isTrue);
    expect(_settled(tester), 1);
  });

  testWidgets('remove animations: glass from the first frame', (tester) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await _open(tester, (_) => const SizedBox(height: 240, child: Text('内容')));
    expect(_blurring(tester), isTrue);
    expect(_settled(tester), 1);
  });

  testWidgets('at rest the glass is the plain glass', (tester) async {
    await _open(tester, (_) => const SizedBox(height: 240, child: Text('内容')));
    await tester.pumpAndSettle();
    final glass = DshSurfaces.of(tester.element(find.text('内容'))).glass(GlassTier.sheet);
    final fill = find.descendant(of: find.byType(GlassSurface), matching: find.byType(DecoratedBox));
    final decoration = tester.widgetList<DecoratedBox>(fill).first.decoration as ShapeDecoration;
    expect(decoration.color, glass.fill);
  });
}

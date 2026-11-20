import 'package:dsh_app/ui/common/pressable.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/semantics_tap_check.dart';

void main() {
  for (final enabled in [true, false]) {
    testWidgets('owned tap reads its label once and stays a button (enabled: $enabled)', (tester) async {
      final semantics = tester.ensureSemantics();
      var tapped = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Pressable(enabled: enabled, onTap: () => tapped++, semanticLabel: '查看译文', child: const Text('查看译文')),
          ),
        ),
      );
      expect(
        tester.getSemantics(find.byType(Pressable)),
        isSemantics(label: '查看译文', isButton: true, hasEnabledState: true, isEnabled: enabled, hasTapAction: enabled),
      );
      expectAllButtonsTappable();
      if (enabled) {
        tester.semantics.tap(find.semantics.byLabel('查看译文'));
        await tester.pump();
        expect(tapped, 1);
      }
      semantics.dispose();
    });
  }

  testWidgets('without a custom label there is one tappable node', (tester) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Pressable(onTap: () {}, child: const Text('查看')),
        ),
      ),
    );
    final tappable = find.semantics.byPredicate((node) => node.getSemanticsData().hasAction(SemanticsAction.tap));
    expect(tappable, findsOneWidget);
    expect(tappable.evaluate().single.label, '查看');
    semantics.dispose();
  });

  for (final owned in [true, false]) {
    testWidgets('disabling keeps the child element (owns tap: $owned)', (tester) async {
      var enabled = true;
      late StateSetter update;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                update = setState;
                return Pressable(
                  enabled: enabled,
                  onTap: owned ? () {} : null,
                  child: InkWell(key: const ValueKey('inner'), onTap: () {}, child: const Text('行')),
                );
              },
            ),
          ),
        ),
      );
      final before = tester.element(find.byKey(const ValueKey('inner')));
      update(() => enabled = false);
      await tester.pump();
      expect(tester.element(find.byKey(const ValueKey('inner'))), same(before));
    });
  }

  group('feel', () {
    final scale = find.descendant(of: find.byType(Pressable), matching: find.byType(ScaleTransition));
    double scaleOf(WidgetTester tester) => tester.widget<ScaleTransition>(scale.first).scale.value;

    Widget listOf(Pressable row, {int rows = 40}) => MaterialApp(
      home: Scaffold(body: ListView(children: [row, for (var i = 0; i < rows; i++) const SizedBox(height: 60)])),
    );

    Pressable feedbackRow() => Pressable(
      child: InkWell(
        onTap: () {},
        child: const SizedBox(height: 60, child: Text('行')),
      ),
    );

    testWidgets('a quick tap on its own shows at once and is held long enough to see', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Pressable(
              onTap: () {},
              child: const SizedBox(height: 60, child: Text('行')),
            ),
          ),
        ),
      );
      await tester.tap(find.text('行'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      final pressing = scaleOf(tester);
      expect(pressing, lessThan(1));
      await tester.pump(const Duration(milliseconds: 60));
      expect(scaleOf(tester), lessThan(pressing), reason: 'the finger is gone, the press keeps going in');
      await tester.pumpAndSettle();
      expect(scaleOf(tester), 1);
      expect(tester.binding.hasScheduledFrame, isFalse);
    });

    testWidgets('it turns around from where it is, with no jump', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Pressable(
              onTap: () {},
              child: const SizedBox(height: 60, child: Text('行')),
            ),
          ),
        ),
      );
      final gesture = await tester.startGesture(tester.getCenter(find.text('行')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));
      await tester.pump(const Duration(milliseconds: 16));
      await gesture.up();
      await tester.pump();
      var last = scaleOf(tester);
      expect(last, lessThan(1));
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        final now = scaleOf(tester);
        expect((now - last).abs(), lessThan(0.01));
        expect(now, greaterThanOrEqualTo(last));
        last = now;
      }
      expect(last, 1, reason: 'lands on 1 and never past it');
    });

    testWidgets('in a list the press waits, so a scroll flashes nothing', (tester) async {
      await tester.pumpWidget(listOf(feedbackRow()));
      final gesture = await tester.startGesture(tester.getCenter(find.text('行')));
      await tester.pump(const Duration(milliseconds: 60));
      await tester.pump(const Duration(milliseconds: 16));
      expect(scaleOf(tester), 1, reason: 'still waiting');
      await gesture.moveBy(const Offset(0, -40));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump(const Duration(milliseconds: 16));
      expect(scaleOf(tester), 1, reason: 'the scroll cancelled it');
      await gesture.up();
      await tester.pumpAndSettle();
      expect(scaleOf(tester), 1);
    });

    testWidgets('a second finger leaves nothing behind for the scroll to miss', (tester) async {
      await tester.pumpWidget(listOf(feedbackRow()));
      final first = await tester.startGesture(tester.getCenter(find.text('行')));
      await tester.pump(const Duration(milliseconds: 30));
      final second = await tester.startGesture(tester.getCenter(find.text('行')));
      await tester.pump(const Duration(milliseconds: 30));
      await second.moveBy(const Offset(0, -40));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump(const Duration(milliseconds: 16));
      expect(scaleOf(tester), 1);
      await first.up();
      await second.up();
      await tester.pumpAndSettle();
      expect(scaleOf(tester), 1);
    });

    testWidgets('in a list a finger that stays gets the press after the wait', (tester) async {
      await tester.pumpWidget(listOf(feedbackRow()));
      final gesture = await tester.startGesture(tester.getCenter(find.text('行')));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 16));
      expect(scaleOf(tester), lessThan(1));
      await gesture.moveBy(const Offset(0, -40));
      await tester.pumpAndSettle();
      expect(scaleOf(tester), 1, reason: 'a scroll after the press lets it go');
      await gesture.up();
      await tester.pumpAndSettle();
    });

    testWidgets('in a list a tap too quick to wait for still shows, then lets go', (tester) async {
      await tester.pumpWidget(listOf(feedbackRow()));
      await tester.tap(find.text('行'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      expect(scaleOf(tester), lessThan(1));
      await tester.pumpAndSettle();
      expect(scaleOf(tester), 1);
    });

    testWidgets('owning the tap in a list, a scroll flashes nothing either', (tester) async {
      var tapped = 0;
      await tester.pumpWidget(
        listOf(
          Pressable(
            onTap: () => tapped++,
            child: const SizedBox(height: 60, child: Text('行')),
          ),
        ),
      );
      final gesture = await tester.startGesture(tester.getCenter(find.text('行')));
      await tester.pump(const Duration(milliseconds: 50));
      await gesture.moveBy(const Offset(0, -40));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump(const Duration(milliseconds: 16));
      expect(scaleOf(tester), 1);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(tapped, 0);
    });

    testWidgets('reduced motion stays at 1 and leaves no timer', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(disableAnimations: true),
            child: Scaffold(
              body: Pressable(
                onTap: () {},
                child: const SizedBox(height: 60, child: Text('行')),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('行'));
      await tester.pump();
      expect(scaleOf(tester), 1);
      expect(tester.binding.hasScheduledFrame, isFalse);
    });

    testWidgets('a glass button scales what is on it, not the glass', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildLightTheme(),
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 200,
                height: 60,
                child: GlassSurface(
                  key: const ValueKey('glass'),
                  tier: GlassTier.chrome,
                  padding: const EdgeInsets.all(16),
                  onTap: () {},
                  child: const Center(child: Text('行')),
                ),
              ),
            ),
          ),
        ),
      );
      expect(find.ancestor(of: find.byType(BackdropFilter), matching: find.byType(Pressable)), findsNothing);
      expect(find.descendant(of: find.byType(BackdropFilter), matching: find.byType(Pressable)), findsOneWidget);
      // On the padding too, where nothing but the InkWell would be hit.
      final gesture = await tester.startGesture(
        tester.getTopLeft(find.byKey(const ValueKey('glass'))) + const Offset(6, 6),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      expect(scaleOf(tester), lessThan(1));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(scaleOf(tester), 1);
    });
  });
}

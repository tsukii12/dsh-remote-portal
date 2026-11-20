// The bars above the composer as one deck (lib/ui/chat/dock/dock_stack.dart):
// folded into the front card's row with the others peeking above, a tap to
// spread, the fold button beside the top card to fold, the choice remembered; a swipe brings another card
// forward; one card is never a deck; the
// accessory beside the front card answers on the folded deck too; a card
// growing in moves the deck smoothly.

import 'package:dsh_app/ui/chat/dock/dock_pill.dart';
import 'package:dsh_app/ui/chat/dock/dock_stack.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/harness.dart';

const _bar = DockMetrics.height + DockMetrics.gap;

/// A bar's slot: a bar of glass, the dock gap under it.
class _Card extends StatelessWidget {
  const _Card(this.label, {this.onTap});

  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: DockMetrics.gap),
    child: GestureDetector(
      onTap: onTap,
      child: Container(
        key: ValueKey(label),
        height: DockMetrics.height,
        alignment: Alignment.center,
        decoration: const ShapeDecoration(color: Color(0xFFDDE4F0), shape: StadiumBorder()),
        child: Text(label),
      ),
    ),
  );
}

/// A bar that rises in on its own, like the activity strip.
class _Rising extends StatefulWidget {
  const _Rising();

  static var mounts = 0;

  @override
  State<_Rising> createState() => _RisingState();
}

class _RisingState extends State<_Rising> with SingleTickerProviderStateMixin {
  late final AnimationController _rise = AnimationController(vsync: this, duration: const Duration(milliseconds: 240))
    ..forward();

  @override
  void initState() {
    super.initState();
    _Rising.mounts++;
  }

  @override
  void dispose() {
    _rise.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _rise,
    builder: (context, child) =>
        ClipRect(child: Align(alignment: Alignment.topCenter, heightFactor: _rise.value, child: child)),
    child: const _Card('rising'),
  );
}

Widget _deck(List<Widget> cards, {Widget? accessory}) => testApp(
  Scaffold(
    body: Align(
      alignment: Alignment.bottomCenter,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 80),
        child: DockStack(cards: cards, accessory: accessory),
      ),
    ),
  ),
);

double _deckHeight(WidgetTester tester) => tester.getSize(find.byType(DockStack)).height;

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('three bars fold into one row; a tap spreads them, the fold button folds them, and it is remembered', (
    tester,
  ) async {
    usePhoneView(tester);
    var taps = 0;
    await tester.pumpWidget(_deck([const _Card('todo'), const _Card('goal'), _Card('strip', onTap: () => taps++)]));
    await pumpFrames(tester);

    // Folded by default: the front card's row and two peeks.
    expect(_deckHeight(tester), 2 * DockStackMetrics.peek + _bar);
    final front = tester.getRect(find.byKey(const ValueKey('strip')));
    final goal = tester.getRect(find.byKey(const ValueKey('goal')));
    final todo = tester.getRect(find.byKey(const ValueKey('todo')));
    expect(front.top - goal.top, DockStackMetrics.peek);
    expect(goal.top - todo.top, DockStackMetrics.peek);
    // Further back, smaller, centred.
    expect(goal.width, lessThan(front.width));
    expect(todo.width, lessThan(goal.width));
    expect(goal.center.dx, moreOrLessEquals(front.center.dx, epsilon: 0.01));
    expect(find.byKey(const ValueKey('dock-fold')).hitTestable(), findsNothing);

    // The folded deck takes the tap: the front card's own doesn't fire.
    await tester.tap(find.byKey(const ValueKey('strip')));
    await pumpFrames(tester);
    expect(taps, 0);
    expect(_deckHeight(tester), 3 * _bar);
    expect(tester.getRect(find.byKey(const ValueKey('goal'))).top - tester.getRect(find.byKey(const ValueKey('todo'))).top, _bar);
    // The fold button beside the top card: no row of its own.
    final fold = tester.getRect(find.byKey(const ValueKey('dock-fold')));
    final top = tester.getRect(find.byKey(const ValueKey('todo')));
    expect(fold.top, top.top);
    expect(fold.size, const Size.square(DockStackMetrics.foldSize));
    expect(fold.left - top.right, DockStackMetrics.accessoryGap);
    expect(fold.right, tester.getRect(find.byKey(const ValueKey('strip'))).right);
    expect(find.byKey(const ValueKey('dock-fold')).hitTestable(), findsOneWidget);
    expect((await SharedPreferences.getInstance()).getBool(DockFoldController.key), isFalse);

    // Spread, the cards answer for themselves.
    await tester.tap(find.byKey(const ValueKey('strip')));
    await tester.pump();
    expect(taps, 1);

    await tester.tap(find.byKey(const ValueKey('dock-fold')));
    await pumpFrames(tester);
    expect(_deckHeight(tester), 2 * DockStackMetrics.peek + _bar);
    expect((await SharedPreferences.getInstance()).getBool(DockFoldController.key), isTrue);
  });

  testWidgets('the fold moves, it does not jump', (tester) async {
    usePhoneView(tester);
    await tester.pumpWidget(_deck(const [_Card('todo'), _Card('goal'), _Card('strip')]));
    await pumpFrames(tester);
    await tester.tap(find.byKey(const ValueKey('strip')));
    final heights = <double>[];
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 30));
      heights.add(_deckHeight(tester));
    }
    expect(heights.first, lessThan(3 * _bar));
    for (var i = 1; i < heights.length; i++) {
      expect(heights[i], greaterThanOrEqualTo(heights[i - 1]));
    }
    await pumpFrames(tester);
    expect(_deckHeight(tester), 3 * _bar);
  });

  testWidgets('a swipe on the folded deck brings another card to the front, and back', (tester) async {
    usePhoneView(tester);
    await tester.pumpWidget(_deck(const [_Card('todo'), _Card('goal'), _Card('strip')]));
    await pumpFrames(tester);
    double top(String key) => tester.getRect(find.byKey(ValueKey(key))).top;
    final frontTop = top('strip');

    // Down: the next one behind comes forward, the front one goes to the back.
    await tester.drag(find.byKey(const ValueKey('strip')), const Offset(0, 60));
    await pumpFrames(tester);
    expect(top('goal'), frontTop);
    expect(top('todo'), frontTop - DockStackMetrics.peek);
    expect(top('strip'), frontTop - 2 * DockStackMetrics.peek);
    // Drawn full size in front, smaller behind.
    expect(
      tester.getRect(find.byKey(const ValueKey('goal'))).width,
      greaterThan(tester.getRect(find.byKey(const ValueKey('todo'))).width),
    );
    // Still folded: a swipe never spreads it.
    expect(_deckHeight(tester), 2 * DockStackMetrics.peek + _bar);

    // A short slow drag (past the touch slop, so not a tap) changes nothing.
    await tester.timedDrag(find.byKey(const ValueKey('goal')), const Offset(0, 26), const Duration(milliseconds: 400));
    await pumpFrames(tester);
    expect(top('goal'), frontTop);

    // Up: back the way it came.
    await tester.drag(find.byKey(const ValueKey('goal')), const Offset(0, -60));
    await pumpFrames(tester);
    expect(top('strip'), frontTop);
    expect(top('goal'), frontTop - DockStackMetrics.peek);
  });

  testWidgets('a card coming or going puts the lowest one in front again', (tester) async {
    usePhoneView(tester);
    final strip = ValueNotifier(true);
    addTearDown(strip.dispose);
    await tester.pumpWidget(
      _deck([
        const _Card('todo'),
        const _Card('goal'),
        ValueListenableBuilder<bool>(
          valueListenable: strip,
          builder: (context, on, _) => on ? const _Card('strip') : const SizedBox(width: double.infinity),
        ),
      ]),
    );
    await pumpFrames(tester);
    await tester.drag(find.byKey(const ValueKey('strip')), const Offset(0, 60));
    await pumpFrames(tester);
    final goalFront = tester.getRect(find.byKey(const ValueKey('goal'))).top;
    strip.value = false;
    await pumpFrames(tester);
    // The goal bar is the lowest one now, and in front (turned once more, the todo bar would be).
    expect(_deckHeight(tester), DockStackMetrics.peek + _bar);
    expect(tester.getRect(find.byKey(const ValueKey('goal'))).top, goalFront);
    expect(
      tester.getRect(find.byKey(const ValueKey('goal'))).top - tester.getRect(find.byKey(const ValueKey('todo'))).top,
      DockStackMetrics.peek,
    );
  });

  testWidgets('folding keeps the cards mounted: a bar rising in is not started over', (tester) async {
    usePhoneView(tester);
    await tester.pumpWidget(_deck(const [_Card('todo'), _Rising()]));
    // A deck once the rising bar has height: the fold must not restart it.
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(_Rising.mounts, 1);
    expect(_deckHeight(tester), DockStackMetrics.peek + _bar);
  });

  testWidgets('one bar is never a deck', (tester) async {
    usePhoneView(tester);
    var taps = 0;
    await tester.pumpWidget(
      _deck([const SizedBox(width: double.infinity), _Card('strip', onTap: () => taps++), const SizedBox.shrink()]),
    );
    await pumpFrames(tester);
    expect(_deckHeight(tester), _bar);
    await tester.tap(find.byKey(const ValueKey('strip')));
    await tester.pump();
    expect(taps, 1);
    expect(find.byKey(const ValueKey('dock-fold')).hitTestable(), findsNothing);
  });

  testWidgets('a card regains the full width when its accessory disappears', (tester) async {
    usePhoneView(tester);
    const cards = [_Card('todo')];
    await tester.pumpWidget(_deck(cards, accessory: const SizedBox(width: 60, height: DockMetrics.height)));
    await pumpFrames(tester);
    final width = tester.getSize(find.byType(DockStack)).width;
    expect(tester.getSize(find.byKey(const ValueKey('todo'))).width, width - 60 - DockStackMetrics.accessoryGap);

    await tester.pumpWidget(_deck(cards));
    await pumpFrames(tester);
    expect(tester.getSize(find.byKey(const ValueKey('todo'))).width, width);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the accessory sits right of the front card and answers on the folded deck', (tester) async {
    usePhoneView(tester);
    var off = 0;
    await tester.pumpWidget(
      _deck(
        const [_Card('goal'), _Card('strip')],
        accessory: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => off++,
          child: const SizedBox(key: ValueKey('chip'), width: 60, height: DockMetrics.height),
        ),
      ),
    );
    await pumpFrames(tester);
    final front = tester.getRect(find.byKey(const ValueKey('strip')));
    final chip = tester.getRect(find.byKey(const ValueKey('chip')));
    final goal = tester.getRect(find.byKey(const ValueKey('goal')));
    expect(chip.top, front.top);
    expect(chip.left - front.right, DockStackMetrics.accessoryGap);
    expect(chip.right, moreOrLessEquals(goal.right + goal.width * DockStackMetrics.shrink / 2, epsilon: 0.5));
    await tester.tap(find.byKey(const ValueKey('chip')));
    await pumpFrames(tester);
    expect(off, 1);
    // Still folded.
    expect(_deckHeight(tester), DockStackMetrics.peek + _bar);
  });

  testWidgets('a card growing in at the front slides over the one behind, without a jump', (tester) async {
    usePhoneView(tester);
    final grow = ValueNotifier<double>(0);
    addTearDown(grow.dispose);
    await tester.pumpWidget(
      _deck([
        const _Card('goal'),
        ValueListenableBuilder<double>(
          valueListenable: grow,
          builder: (context, h, _) => h == 0
              ? const SizedBox(width: double.infinity)
              : ClipRect(
                  child: Align(alignment: Alignment.topCenter, heightFactor: h, child: const _Card('strip')),
                ),
        ),
      ]),
    );
    await pumpFrames(tester);
    var last = _deckHeight(tester);
    expect(last, _bar);
    for (var i = 1; i <= 20; i++) {
      grow.value = i / 20;
      await tester.pump();
      final now = _deckHeight(tester);
      expect((now - last).abs(), lessThan(DockStackMetrics.peek), reason: 'step $i');
      last = now;
    }
    expect(last, DockStackMetrics.peek + _bar);
  });
}

import 'package:dsh_app/ui/chat/widgets/live_clock.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final start = DateTime(2026, 10, 28);
  late DateTime now;
  var clockReads = 0;
  setUp(() {
    now = start;
    clockReads = 0;
    runClock = () {
      clockReads++;
      return now;
    };
  });
  tearDown(() => runClock = DateTime.now);

  testWidgets('background stops elapsed rebuilds and resume reads wall clock immediately', (tester) async {
    var builds = 0;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: LiveElapsed(
          since: start,
          builder: (_, elapsed) {
            builds++;
            return Text('${elapsed!.inSeconds}');
          },
        ),
      ),
    );
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    final parked = builds;
    final parkedReads = clockReads;
    now = start.add(const Duration(seconds: 20));
    await tester.pump(const Duration(seconds: 20));
    expect(clockReads, parkedReads, reason: 'background timer must not wake to read the clock');
    expect(builds, parked, reason: 'a mounted hidden clock must not rebuild each background second');
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(find.text('20'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('disabled TickerMode parks timer and reenabling catches up', (tester) async {
    var builds = 0;
    Widget clock(bool enabled) => Directionality(
      textDirection: TextDirection.ltr,
      child: TickerMode(
        enabled: enabled,
        child: LiveElapsed(
          since: start,
          builder: (_, elapsed) {
            builds++;
            return Text('${elapsed!.inSeconds}');
          },
        ),
      ),
    );
    await tester.pumpWidget(clock(true));
    await tester.pumpWidget(clock(false));
    final parked = builds;
    now = start.add(const Duration(seconds: 30));
    await tester.pump(const Duration(seconds: 30));
    expect(builds, parked);
    await tester.pumpWidget(clock(true));
    expect(find.text('30'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('null clock stays idle and timestamp replacement still ticks', (tester) async {
    var builds = 0;
    Widget clock(DateTime? since) => Directionality(
      textDirection: TextDirection.ltr,
      child: LiveElapsed(
        since: since,
        builder: (_, elapsed) {
          builds++;
          return Text('${elapsed?.inSeconds}');
        },
      ),
    );
    await tester.pumpWidget(clock(null));
    final idle = builds;
    await tester.pump(const Duration(seconds: 5));
    expect(builds, idle);
    now = start.add(const Duration(seconds: 5));
    await tester.pumpWidget(clock(start));
    expect(find.text('5'), findsOneWidget);
    now = start.add(const Duration(seconds: 7));
    await tester.pump(const Duration(milliseconds: 1010));
    expect(find.text('7'), findsOneWidget);
    await tester.pumpWidget(clock(null));
    final stopped = builds;
    await tester.pump(const Duration(seconds: 5));
    expect(builds, stopped);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('timestamp changes while inactive stay parked and disposal removes observer', (tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    Widget clock(DateTime since) => Directionality(
      textDirection: TextDirection.ltr,
      child: LiveElapsed(
        since: since,
        skew: const Duration(seconds: 2),
        builder: (_, elapsed) => Text('${elapsed!.inSeconds}'),
      ),
    );
    await tester.pumpWidget(clock(start));
    now = start.add(const Duration(seconds: 10));
    await tester.pumpWidget(clock(start.add(const Duration(seconds: 3))));
    final parkedReads = clockReads;
    now = start.add(const Duration(seconds: 20));
    await tester.pump(const Duration(seconds: 10));
    expect(clockReads, parkedReads);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(find.text('15'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump(const Duration(seconds: 2));
    expect(tester.takeException(), isNull);
  });
}

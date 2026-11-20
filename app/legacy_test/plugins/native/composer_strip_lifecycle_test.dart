import 'dart:async';

import 'package:dsh_app/plugins/native/native_model.dart';
import 'package:dsh_app/plugins/native/native_state.dart';
import 'package:dsh_app/ui/plugins/native/composer_strip.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../chat/support/harness.dart';
import 'support.dart';

const _lines = [
  NativeStrip(package: 'SYNTHETIC-alpha', id: 'line', text: 'SYNTHETIC first'),
  NativeStrip(package: 'SYNTHETIC-beta', id: 'line', text: 'SYNTHETIC second'),
];

class _Count extends Notifier<int> {
  @override
  int build() => 2;

  void replace(int value) => state = value;
}

final _count = NotifierProvider<_Count, int>(_Count.new);
typedef _Flags = ({bool visible, bool ticker});

class _Screen {
  final flags = ValueNotifier<_Flags>((visible: true, ticker: true));
  late ProviderContainer container;
  var builds = 0;

  Future<void> open(WidgetTester tester, {int count = 2}) async {
    usePhoneView(tester);
    final previous = debugOnRebuildDirtyWidget;
    debugOnRebuildDirtyWidget = (element, builtOnce) {
      previous?.call(element, builtOnce);
      if (element.widget is ComposerStripSlot) builds++;
    };
    addTearDown(() {
      debugOnRebuildDirtyWidget = previous;
      flags.dispose();
    });
    final bridge = FakeBridge(
      contributions([
        for (final line in _lines)
          plugin(
            line.package,
            strip: [
              {'id': line.id, 'text': line.text, 'live': false},
            ],
          ),
      ]),
    );
    await tester.pumpWidget(
      testApp(
        Scaffold(
          body: Center(
            child: ValueListenableBuilder<_Flags>(
              valueListenable: flags,
              builder: (context, value, _) => TickerMode(
                enabled: value.ticker,
                child: SizedBox(
                  width: 360,
                  child: ComposerStripSlot(sessionId: 'SYNTHETIC-session', visible: value.visible),
                ),
              ),
            ),
          ),
        ),
        overrides: [
          ...nativeOverrides(bridge),
          nativeStripsProvider.overrideWith((ref) => _lines.take(ref.watch(_count)).toList()),
        ],
      ),
    );
    container = ProviderScope.containerOf(tester.element(find.byType(ComposerStripSlot)));
    container.read(_count.notifier).replace(count);
    await pumpFrames(tester);
  }

  String line(WidgetTester tester) => tester.widget<ComposerStrip>(find.byType(ComposerStrip)).text;

  Future<void> nextTurn(WidgetTester tester) async {
    await tester.pump(StripMetrics.turn);
    await pumpFrames(tester, 4);
    expect(line(tester), 'SYNTHETIC second');
    expect(tester.takeException(), isNull);
  }
}

void _away(WidgetTester tester, AppLifecycleState target) {
  for (final state in [
    AppLifecycleState.inactive,
    AppLifecycleState.hidden,
    AppLifecycleState.paused,
    AppLifecycleState.detached,
  ]) {
    tester.binding.handleAppLifecycleStateChanged(state);
    if (state == target) break;
  }
}

void _resume(WidgetTester tester) {
  switch (tester.binding.lifecycleState) {
    case AppLifecycleState.paused:
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    case AppLifecycleState.hidden:
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    default:
      break;
  }
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
}

void main() {
  setUpAll(loadTestFonts);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('hidden strip does not rotate or rebuild, including a resume while still hidden', (tester) async {
    _resume(tester);
    final screen = _Screen();
    await screen.open(tester);
    screen.flags.value = (visible: false, ticker: true);
    await pumpFrames(tester);
    final parked = screen.builds;
    await tester.pump(const Duration(seconds: 7));
    expect(screen.builds, parked);
    _away(tester, AppLifecycleState.inactive);
    _resume(tester);
    await pumpFrames(tester);
    final resumedHidden = screen.builds;
    await tester.pump(const Duration(seconds: 7));
    expect(screen.builds, resumedHidden);
    screen.flags.value = (visible: true, ticker: true);
    await pumpFrames(tester);
    expect(screen.line(tester), 'SYNTHETIC first');
    await screen.nextTurn(tester);
  });

  testWidgets('TickerMode parks rotation and reenabling starts a fresh turn', (tester) async {
    _resume(tester);
    final screen = _Screen();
    await screen.open(tester);
    screen.flags.value = (visible: true, ticker: false);
    await pumpFrames(tester);
    final parked = screen.builds;
    await tester.pump(const Duration(seconds: 7));
    expect(screen.builds, parked);
    expect(screen.line(tester), 'SYNTHETIC first');
    screen.flags.value = (visible: true, ticker: true);
    await pumpFrames(tester);
    expect(screen.line(tester), 'SYNTHETIC first');
    await screen.nextTurn(tester);
  });

  for (final state in [
    AppLifecycleState.inactive,
    AppLifecycleState.hidden,
    AppLifecycleState.paused,
    AppLifecycleState.detached,
  ]) {
    testWidgets('$state parks the turn without advancing the displayed plugin', (tester) async {
      _resume(tester);
      final screen = _Screen();
      await screen.open(tester);
      _away(tester, state);
      await tester.pump(const Duration(seconds: 7));
      _resume(tester);
      await pumpFrames(tester);
      expect(screen.line(tester), 'SYNTHETIC first');
      await screen.nextTurn(tester);
    });
  }

  testWidgets('first mount while paused stays parked until resume', (tester) async {
    _resume(tester);
    _away(tester, AppLifecycleState.paused);
    final screen = _Screen();
    await screen.open(tester);
    await tester.pump(const Duration(seconds: 7));
    _resume(tester);
    await pumpFrames(tester);
    expect(screen.line(tester), 'SYNTHETIC first');
    await screen.nextTurn(tester);
  });

  testWidgets('a dialog covering the route parks rotation until the route is current', (tester) async {
    _resume(tester);
    final screen = _Screen();
    await screen.open(tester);
    final context = tester.element(find.byType(ComposerStripSlot));
    unawaited(
      showDialog<void>(
        context: context,
        builder: (_) => const AlertDialog(content: Text('SYNTHETIC cover')),
      ),
    );
    await pumpFrames(tester);
    final parked = screen.builds;
    await tester.pump(const Duration(seconds: 7));
    expect(screen.builds, parked);
    Navigator.of(context).pop();
    await pumpFrames(tester);
    expect(screen.line(tester), 'SYNTHETIC first');
    await screen.nextTurn(tester);
  });

  testWidgets('one or zero ready lines stay idle, two resume, and disposal retires the timer', (tester) async {
    _resume(tester);
    final screen = _Screen();
    await screen.open(tester, count: 1);
    final single = screen.builds;
    await tester.pump(const Duration(seconds: 7));
    expect(screen.builds, single);
    screen.container.read(_count.notifier).replace(0);
    await pumpFrames(tester);
    final empty = screen.builds;
    await tester.pump(const Duration(seconds: 7));
    expect(screen.builds, empty);
    expect(find.byType(ComposerStrip), findsNothing);
    screen.container.read(_count.notifier).replace(2);
    await pumpFrames(tester);
    expect(screen.line(tester), 'SYNTHETIC first');
    await screen.nextTurn(tester);
    await tester.pumpWidget(const SizedBox());
    _away(tester, AppLifecycleState.inactive);
    _resume(tester);
    await tester.pump(const Duration(seconds: 7));
    expect(tester.takeException(), isNull);
  });
}

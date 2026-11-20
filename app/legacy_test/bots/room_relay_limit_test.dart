import 'dart:async';

import 'package:dsh_app/state/bots_state.dart';
import 'package:dsh_app/ui/bots/room_relay_limit_sheet.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../chat/support/harness.dart';
import '../shell/golden_harness.dart' show goldenApp;
import 'support.dart';

Future<void> frames(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  setUpAll(loadTestFonts);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<FakeDsBotTransport> open(
    WidgetTester tester, {
    bool readOnly = false,
    double scale = 1,
    Brightness brightness = Brightness.light,
  }) async {
    final team = sampleTeam(working: false);
    final room = (team['rooms'] as List).single as Map<String, Object?>;
    room['relayLimit'] = 20;
    room['relayLimitDefault'] = 6;
    if (readOnly) team['readOnly'] = 'owned elsewhere';
    final fake = FakeDsBotTransport(team: team)..helloOnFeed = false;
    fake.handlers['update-room'] = (_) => true;
    usePhoneView(tester);
    tester.view.physicalSize = const Size(640, 1688);
    await tester.pumpWidget(
      goldenApp(
        brightness: brightness,
        overrides: dsBotOverrides(fake),
        home: Consumer(
          builder: (context, ref, _) {
            final status = ref.watch(dsBotProvider);
            return Scaffold(
              body: Center(
                child: FilledButton(
                  onPressed: status.ready ? () => showRoomRelayLimitSheet(context, DsBotRoom.fromJson(room)) : null,
                  child: const Text('Open'),
                ),
              ),
            );
          },
        ),
      ),
    );
    await frames(tester);
    await tester.tap(find.text('Open'));
    await frames(tester);
    final context = tester.element(find.byType(RoomRelayLimitSheet));
    // Set the ambient scale at the route through the test platform.
    tester.platformDispatcher.textScaleFactorTestValue = scale;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    expect(ProviderScope.containerOf(context).read(dsBotProvider).ready, isTrue);
    await frames(tester);
    expect(MediaQuery.textScalerOf(context).scale(10), closeTo(10 * scale, 0.01));
    return fake;
  }

  final input = find.byKey(const ValueKey('relay-limit-input'));
  final save = find.byKey(const ValueKey('relay-limit-save'));

  testWidgets('validates integers and sends explicit null when cleared', (tester) async {
    final fake = await open(tester);
    for (final value in ['0', '201', '1.5', '-1', 'bad']) {
      await tester.enterText(input, value);
      await tester.pump();
      expect(tester.widget<FilledButton>(save).onPressed, isNull);
    }
    for (final value in ['1', '200']) {
      await tester.enterText(input, value);
      await tester.pump();
      expect(tester.widget<FilledButton>(save).onPressed, isNotNull);
    }
    await tester.enterText(input, '');
    await tester.pump();
    await tester.tap(save);
    await frames(tester);
    expect(fake.calls.lastWhere((call) => call.$1 == 'update-room').$2, {'id': 'r1', 'relayLimit': null});
    expect(find.byType(RoomRelayLimitSheet), findsNothing);
  });

  testWidgets('save is single-flight and failure preserves the draft for retry', (tester) async {
    final fake = await open(tester);
    final pending = Completer<Object?>();
    fake.handlers['update-room'] = (_) => pending.future;
    await tester.enterText(input, '19');
    await tester.tap(save);
    await tester.pump();
    expect(tester.widget<FilledButton>(save).onPressed, isNull);
    pending.completeError(StateError('offline'));
    await frames(tester);
    expect(tester.widget<FilledButton>(save).onPressed, isNotNull);
    expect(tester.widget<TextField>(input).controller!.text, '19');
    fake.handlers['update-room'] = (_) => true;
    await tester.tap(save);
    await frames(tester);
    expect(fake.calls.where((call) => call.$1 == 'update-room'), hasLength(2));
    expect(fake.calls.lastWhere((call) => call.$1 == 'update-room').$2, {'id': 'r1', 'relayLimit': 19});
  });

  testWidgets('reconnecting while saving cannot close or reuse the old sheet', (tester) async {
    final fake = await open(tester);
    final pending = Completer<Object?>();
    fake.handlers['update-room'] = (_) => pending.future;
    await tester.tap(save);
    await tester.pump();
    final container = ProviderScope.containerOf(tester.element(find.byType(RoomRelayLimitSheet)));
    container.read(dsBotProvider.notifier).retry();
    await frames(tester);
    expect(tester.widget<FilledButton>(save).onPressed, isNull);
    pending.complete(true);
    await frames(tester);
    expect(find.byType(RoomRelayLimitSheet), findsOneWidget);
    expect(tester.widget<FilledButton>(save).onPressed, isNull);
  });

  testWidgets('restore default explicitly clears the saved override', (tester) async {
    final fake = await open(tester);
    await tester.tap(find.byKey(const ValueKey('relay-limit-default')));
    await frames(tester);
    expect(fake.calls.lastWhere((call) => call.$1 == 'update-room').$2, {'id': 'r1', 'relayLimit': null});
  });

  testWidgets('read-only team cannot edit or restore the limit', (tester) async {
    final fake = await open(tester, readOnly: true);
    expect(tester.widget<FilledButton>(save).onPressed, isNull);
    expect(tester.widget<TextButton>(find.byKey(const ValueKey('relay-limit-default'))).onPressed, isNull);
    expect(tester.widget<TextField>(input).enabled, isFalse);
    expect(fake.endpoints, isNot(contains('update-room')));
  });

  for (final brightness in Brightness.values) {
    for (final scale in [1.3, 2.0]) {
      testWidgets('relay limit at 320dp/$scale/${brightness.name}', (tester) async {
        await open(tester, scale: scale, brightness: brightness);
        await tester.ensureVisible(save);
        await frames(tester);
        expect(tester.takeException(), isNull);
        final rect = tester.getRect(save);
        expect(rect.left, greaterThanOrEqualTo(0));
        expect(rect.right, lessThanOrEqualTo(320));
        expect(rect.height, greaterThanOrEqualTo(44));
      });
    }
    testWidgets('relay limit golden ${brightness.name}', (tester) async {
      await open(tester, brightness: brightness);
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/room_relay_limit_${brightness.name}.png'));
    }, skip: !const bool.fromEnvironment('DSBOT_GOLDENS'));
  }
}

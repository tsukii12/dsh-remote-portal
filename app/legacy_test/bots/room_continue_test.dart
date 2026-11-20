import 'dart:async';

import 'package:dsh_app/ui/bots/room_chat_page.dart';
import 'package:flutter/material.dart';
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
    double width = 390,
    Brightness brightness = Brightness.light,
  }) async {
    final team = sampleTeam(working: false);
    final room = (team['rooms'] as List).single as Map<String, Object?>;
    room['paused'] = [
      {'id': 'parked-1', 'botId': 'b2', 'name': 'Writer'},
    ];
    if (readOnly) team['readOnly'] = 'Another host owns this team';
    final fake = FakeDsBotTransport(team: team);
    usePhoneView(tester);
    tester.view.physicalSize = Size(width * 2, 1688);
    await tester.pumpWidget(
      goldenApp(
        home: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
            child: const RoomChatPage(roomId: 'r1'),
          ),
        ),
        brightness: brightness,
        overrides: dsBotOverrides(fake),
      ),
    );
    await frames(tester);
    return fake;
  }

  testWidgets('a paused group continues once and waits for its parked calls to change', (tester) async {
    final fake = await open(tester);
    final pending = Completer<Object?>();
    fake.handlers['room-continue'] = (_) => pending.future;
    final button = find.byKey(const ValueKey('room-continue'));
    expect(find.byKey(const ValueKey('room-paused')), findsOneWidget);
    await tester.tap(button);
    await tester.pump();
    expect(tester.widget<FilledButton>(button).onPressed, isNull);
    expect(fake.calls.lastWhere((call) => call.$1 == 'room-continue').$2, {'roomId': 'r1'});
    pending.complete(true);
    await frames(tester);
    // The server queues a round; the same pending IDs must not be resumed twice.
    expect(tester.widget<FilledButton>(button).onPressed, isNull);
    expect(fake.endpoints.where((endpoint) => endpoint == 'room-continue'), hasLength(1));
  });

  testWidgets('a failed continue remains retryable', (tester) async {
    final fake = await open(tester);
    fake.handlers['room-continue'] = (_) => throw StateError('offline');
    final button = find.byKey(const ValueKey('room-continue'));
    await tester.tap(button);
    await frames(tester);
    expect(tester.widget<FilledButton>(button).onPressed, isNotNull);
    expect(find.byType(SnackBar), findsOneWidget);
  });

  for (final brightness in Brightness.values) {
    for (final scale in [1.3, 2.0]) {
      testWidgets('paused group fits 320dp at $scale in ${brightness.name}', (tester) async {
        await open(tester, scale: scale, width: 320, brightness: brightness);
        expect(tester.takeException(), isNull);
        final button = tester.getRect(find.byKey(const ValueKey('room-continue')));
        expect(button.left, greaterThanOrEqualTo(0));
        expect(button.right, lessThanOrEqualTo(320));
        expect(button.height, greaterThanOrEqualTo(44));
      });
    }
    testWidgets('paused group golden ${brightness.name}', (tester) async {
      useBotGoldenClock();
      await open(tester, brightness: brightness);
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/room_paused_${brightness.name}.png'));
    }, skip: !const bool.fromEnvironment('DSBOT_GOLDENS'));
  }

  testWidgets('a read-only group shows its pause without allowing continuation', (tester) async {
    final fake = await open(tester, readOnly: true);
    final button = find.byKey(const ValueKey('room-continue'));
    expect(tester.widget<FilledButton>(button).onPressed, isNull);
    expect(fake.endpoints, isNot(contains('room-continue')));
  });
}

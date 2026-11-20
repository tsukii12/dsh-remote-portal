import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/state/bots_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/ui/bots/bot_details_page.dart';
import 'package:dsh_app/ui/bots/bot_chat_page.dart';
import 'package:dsh_app/ui/common/list_page_row.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../chat/support/harness.dart';
import '../shell/golden_harness.dart' show goldenApp;
import 'support.dart';

class _Host extends ActiveHostController {
  @override
  HostRef build() => HostRef.none;
  @override
  void select(HostRef host) => state = host;
}

Future<void> frames(WidgetTester t) async {
  for (var i = 0; i < 8; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  setUpAll(loadTestFonts);
  setUp(() => SharedPreferences.setMockInitialValues({}));
  final fixture =
      jsonDecode(File('../packages/dsh_client/test/fixtures/dsbot_duplicate_bot.json').readAsStringSync()) as Map;
  final copy = (fixture['first']['value'] as Map).cast<String, Object?>();
  final row = find.byKey(const ValueKey('duplicate-bot-row'));
  final confirm = find.byKey(const ValueKey('duplicate-bot-confirm'));
  Future<ProviderContainer> open(
    WidgetTester t,
    FakeDsBotTransport old,
    FakeDsBotTransport next, {
    double scale = 1,
    Brightness brightness = Brightness.light,
  }) async {
    var opens = 0;
    usePhoneView(t);
    t.view.physicalSize = const Size(640, 1688);
    t.platformDispatcher.textScaleFactorTestValue = scale;
    addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
    await t.pumpWidget(
      goldenApp(
        brightness: brightness,
        home: const BotDetailsPage(botId: 'b2'),
        overrides: [
          activeHostProvider.overrideWith(_Host.new),
          activeConnectionProvider.overrideWith((ref) {
            final h = ref.watch(activeHostProvider);
            return AsyncData(
              HostConnection(
                client: fakeConnection.client,
                label: h.id,
                isLocal: h.isLocal,
                kind: h.kind,
                hostId: h.id,
              ),
            );
          }),
          dsBotApiFactoryProvider.overrideWithValue((_) => DsBotApi(opens++ == 0 ? old : next)),
        ],
      ),
    );
    await frames(t);
    final c = ProviderScope.containerOf(t.element(find.byType(BotDetailsPage)));
    await t.scrollUntilVisible(row, 300, scrollable: find.byType(Scrollable).first);
    await frames(t);
    return c;
  }

  FakeDsBotTransport fake() => FakeDsBotTransport(team: sampleTeam(working: false))..helloOnFeed = false;
  Future<void> start(WidgetTester t) async {
    await t.tap(row);
    await frames(t);
  }

  testWidgets('copy requires explicit confirmation explaining automatic greeting', (t) async {
    final old = fake();
    await open(t, old, fake());
    await start(t);
    expect(find.textContaining('先发送一句问候'), findsOneWidget);
    expect(old.endpoints, isNot(contains('duplicate-bot')));
    await t.tap(find.text('取消'));
    await frames(t);
    expect(old.endpoints, isNot(contains('duplicate-bot')));
    expect(t.widget<ListPageRow>(row).onTap, isNotNull);
  });
  testWidgets('actual reply opens fresh Bot after one write and refresh', (t) async {
    final old = fake();
    old.handlers['duplicate-bot'] = (_) {
      old.handlers['state'] = (_) => {
        ...sampleTeam(working: false),
        'revision': 8,
        'bots': [...(sampleTeam()['bots'] as List), copy],
      };
      return copy;
    };
    await open(t, old, fake());
    await start(t);
    await t.tap(confirm);
    await frames(t);
    expect(old.calls.where((c) => c.$1 == 'duplicate-bot').single.$2, {'id': 'b2'});
    expect(find.byType(BotChatPage), findsOneWidget);
    expect(t.widget<BotChatPage>(find.byType(BotChatPage)).botId, copy['id']);
  });
  testWidgets('in-flight write is single-flight and failure permits retry', (t) async {
    final old = fake();
    final pending = Completer<Object?>();
    old.handlers['duplicate-bot'] = (_) => pending.future;
    await open(t, old, fake());
    await start(t);
    await t.tap(confirm);
    await frames(t);
    expect(t.widget<ListPageRow>(row).onTap, isNull);
    expect(old.endpoints.where((x) => x == 'duplicate-bot'), hasLength(1));
    pending.completeError(const DshTransportException('copy failed'));
    await frames(t);
    expect(t.widget<ListPageRow>(row).onTap, isNotNull);
    expect(find.byType(SnackBar), findsOneWidget);
    expect(find.byType(BotChatPage), findsNothing);
  });
  testWidgets('created copy with a failed team refresh is reported as created, not failed', (t) async {
    final old = fake();
    old.handlers['duplicate-bot'] = (_) {
      old.handlers['state'] = (_) => throw const DshTransportException('state failed');
      return copy;
    };
    await open(t, old, fake());
    await start(t);
    await t.tap(confirm);
    await frames(t);
    expect(old.endpoints.where((x) => x == 'duplicate-bot'), hasLength(1));
    expect(find.text('已复制，稍后会出现在列表中。'), findsOneWidget);
    expect(find.byType(BotChatPage), findsNothing);
  });
  testWidgets('readonly from the beginning offers no copy action', (t) async {
    final old = fake();
    old.handlers['state'] = (_) => {...sampleTeam(working: false), 'readOnly': 'other owner'};
    await open(t, old, fake());
    expect(t.widget<ListPageRow>(row).onTap, isNull);
  });
  for (final change in ['readonly', 'reconnect']) {
    testWidgets('$change while copying does not navigate or refresh a retired target', (t) async {
      final old = fake(), next = fake();
      final pending = Completer<Object?>();
      old.handlers['duplicate-bot'] = (_) => pending.future;
      final c = await open(t, old, next);
      await start(t);
      await t.tap(confirm);
      await frames(t);
      if (change == 'readonly') {
        old.handlers['state'] = (_) => {...sampleTeam(working: false), 'readOnly': 'other owner'};
        await c.read(dsBotProvider.notifier).refresh();
      } else {
        c.read(dsBotProvider.notifier).retry();
      }
      await frames(t);
      final before = next.endpoints.length;
      pending.complete(copy);
      await frames(t);
      expect(next.endpoints.length, before);
      expect(find.byType(BotChatPage), findsNothing);
      expect(find.byType(SnackBar), findsNothing);
    });
  }
  for (final change in ['host', 'reconnect', 'boot', 'readonly', 'removed']) {
    testWidgets('$change before confirmation never writes', (t) async {
      final old = fake();
      final next = fake();
      final c = await open(t, old, next);
      await start(t);
      if (change == 'host') {
        c.read(activeHostProvider.notifier).select(const HostRef.portal('next'));
      } else if (change == 'reconnect') {
        c.read(dsBotProvider.notifier).retry();
      } else if (change == 'boot') {
        old.emit('hello', {'boot': 'restarted-plugin', 'seq': 0});
        await frames(t);
      } else {
        old.handlers['state'] = (_) => {
          ...sampleTeam(working: false),
          if (change == 'readonly') 'readOnly': 'other owner',
          if (change == 'removed') 'bots': [...(sampleTeam()['bots'] as List).where((b) => b['id'] != 'b2')],
        };
        await c.read(dsBotProvider.notifier).refresh();
      }
      // Host change is checked even if confirmation happens before another frame.
      await t.tap(confirm);
      await frames(t);
      expect(old.endpoints, isNot(contains('duplicate-bot')));
      expect(next.endpoints, isNot(contains('duplicate-bot')));
    });
  }
  for (final failure in [false, true]) {
    testWidgets('old ${failure ? 'error' : 'success'} after host change has no new-host effect', (t) async {
      final old = fake(), next = fake();
      final pending = Completer<Object?>();
      old.handlers['duplicate-bot'] = (_) => pending.future;
      final c = await open(t, old, next);
      await start(t);
      await t.tap(confirm);
      await frames(t);
      c.read(activeHostProvider.notifier).select(const HostRef.portal('next'));
      await frames(t);
      final before = next.endpoints.length;
      if (failure) {
        pending.completeError(const DshTransportException('late failure'));
      } else {
        pending.complete(copy);
      }
      await frames(t);
      expect(next.endpoints.length, before);
      expect(find.byType(BotChatPage), findsNothing);
      expect(find.byType(SnackBar), findsNothing);
      await t.scrollUntilVisible(row, 300, scrollable: find.byType(Scrollable).first);
      expect(t.widget<ListPageRow>(row).onTap, isNotNull);
    });
  }
  for (final brightness in Brightness.values) {
    testWidgets('copy confirm 320dp 2x ${brightness.name}', (t) async {
      await open(t, fake(), fake(), scale: 2, brightness: brightness);
      await start(t);
      expect(t.takeException(), isNull);
      expect(t.getRect(confirm).right, lessThanOrEqualTo(320));
    });
    testWidgets('copy confirm golden ${brightness.name}', (t) async {
      await open(t, fake(), fake(), brightness: brightness);
      await start(t);
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/bot_duplicate_${brightness.name}.png'));
    }, skip: !const bool.fromEnvironment('DSBOT_GOLDENS'));
  }
}

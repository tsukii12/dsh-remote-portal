import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/state/bots_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/ui/bots/memory_card.dart';
import 'package:dsh_app/ui/common/list_page_row.dart';
import 'package:dsh_app/ui/features/feature_kit.dart';
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
  void select(HostRef value) => state = value;
}

Future<void> frames(WidgetTester t) async {
  for (var i = 0; i < 8; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

class _Hub extends DsBotController {
  void setBoot(DsBotHello hello) => state = state.copyWith(hello: hello);
}

void main() {
  setUpAll(loadTestFonts);
  setUp(() => SharedPreferences.setMockInitialValues({}));
  final fixture =
      jsonDecode(File('../packages/dsh_client/test/fixtures/dsbot_memory_refresh.json').readAsStringSync()) as Map;
  Future<ProviderContainer> open(
    WidgetTester t,
    FakeDsBotTransport old,
    FakeDsBotTransport next, {
    String entity = 'bot',
    bool reconnect = false,
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
        home: Scaffold(
          body: entity == 'bot' ? const BotMemoryCard(botId: 'writer') : const BotMemoryCard(roomId: 'r1'),
        ),
        overrides: [
          activeHostProvider.overrideWith(_Host.new),
          dsBotProvider.overrideWith(_Hub.new),
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
          dsBotApiFactoryProvider.overrideWithValue(
            (c) => DsBotApi(reconnect ? (opens++ == 0 ? old : next) : ((c.hostId == HostRef.none.id) ? old : next)),
          ),
        ],
      ),
    );
    await frames(t);
    return ProviderScope.containerOf(t.element(find.byType(BotMemoryCard)));
  }

  FakeDsBotTransport fake() =>
      FakeDsBotTransport(team: (fixture['team'] as Map).cast<String, Object?>())..helloOnFeed = false;
  ({String? botId, String? roomId}) key(String entity) =>
      (botId: entity == 'bot' ? 'writer' : null, roomId: entity == 'room' ? 'r1' : null);
  String marker(String entity) => 'SYNTHETIC_${entity}_MEMORY_INITIAL';
  ListPageRow entry(WidgetTester t, String entity) =>
      t.widget<ListPageRow>(find.ancestor(of: find.text(marker(entity)), matching: find.byType(ListPageRow)));

  for (final entity in ['bot', 'room']) {
    for (final failed in [false, true]) {
      testWidgets(
        '$entity same owner refresh ${failed ? 'failure retains rows and retries' : 'keeps rows then updates'}',
        (t) async {
          final old = fake(), next = fake();
          old.handlers['memory-view'] = (_) => fixture['before'][entity]['value'];
          final c = await open(t, old, next, entity: entity);
          expect(c.read(dsBotMemoryProvider(key(entity))).error, isNull, reason: 'initial memory read');
          expect(find.text(marker(entity)), findsOneWidget);
          final pending = Completer<Object?>();
          old.handlers['memory-view'] = (_) => pending.future;
          c.invalidate(dsBotMemoryProvider(key(entity)));
          await frames(t);
          expect(find.text(marker(entity)), findsOneWidget);
          expect(find.textContaining('更新中 · 上次结果'), findsOneWidget);
          expect(find.byType(QuietSpinner), findsNothing);
          expect(entry(t, entity).onTap, isNull);
          if (failed) {
            pending.completeError(const DshTransportException('synthetic refresh failure'));
            await frames(t);
            expect(find.text(marker(entity)), findsOneWidget);
            expect(find.textContaining('未更新 · 上次结果'), findsOneWidget);
            expect(entry(t, entity).onTap, isNull);
            old.handlers['memory-view'] = (_) => fixture['after'][entity]['value'];
            await t.tap(find.text('没能读取记忆'));
          } else {
            pending.complete(fixture['after'][entity]['value']);
          }
          await frames(t);
          expect(find.text('SYNTHETIC_${entity}_MEMORY_REFRESHED'), findsOneWidget);
          expect(find.textContaining('上次结果'), findsNothing);
          expect(entry(t, entity).onTap, isNotNull);
          expect(t.takeException(), isNull);
        },
      );
    }
    for (final change in ['host', 'reconnect', 'boot']) {
      testWidgets('$entity $change clears cached memory while the new read waits', (t) async {
        final old = fake(), next = fake();
        old.handlers['memory-view'] = (_) => fixture['before'][entity]['value'];
        final pending = Completer<Object?>();
        next.handlers['memory-view'] = (_) => pending.future;
        final c = await open(t, old, next, entity: entity, reconnect: change == 'reconnect');
        expect(find.text(marker(entity)), findsOneWidget);
        if (change == 'host') {
          c.read(activeHostProvider.notifier).select(const HostRef.portal('next'));
        } else if (change == 'reconnect') {
          c.read(dsBotProvider.notifier).retry();
        } else {
          old.handlers['memory-view'] = (_) => pending.future;
          (c.read(dsBotProvider.notifier) as _Hub).setBoot(
            DsBotHello.fromJson({...old.helloAnswer(), 'boot': 'synthetic-new-boot'}),
          );
        }
        await frames(t);
        expect(find.text(marker(entity)), findsNothing);
        expect(find.textContaining('上次结果'), findsNothing);
        pending.complete(fixture['after'][entity]['value']);
        await frames(t);
        expect(find.text('SYNTHETIC_${entity}_MEMORY_REFRESHED'), findsOneWidget);
        expect(t.takeException(), isNull);
      });
    }
    for (final failed in [false, true]) {
      testWidgets('$entity old refresh ${failed ? 'error' : 'success'} cannot replace new host contents', (t) async {
        final old = fake(), next = fake();
        old.handlers['memory-view'] = (_) => fixture['before'][entity]['value'];
        next.handlers['memory-view'] = (_) => fixture['after'][entity]['value'];
        final c = await open(t, old, next, entity: entity);
        final pending = Completer<Object?>();
        old.handlers['memory-view'] = (_) => pending.future;
        c.invalidate(dsBotMemoryProvider(key(entity)));
        await frames(t);
        expect(find.text(marker(entity)), findsOneWidget);
        c.read(activeHostProvider.notifier).select(const HostRef.portal('next'));
        await frames(t);
        expect(find.text('SYNTHETIC_${entity}_MEMORY_REFRESHED'), findsOneWidget);
        if (failed) {
          pending.completeError(const DshTransportException('old refresh failed'));
        } else {
          pending.complete(fixture['before'][entity]['value']);
        }
        await frames(t);
        expect(find.text('SYNTHETIC_${entity}_MEMORY_REFRESHED'), findsOneWidget);
        expect(find.text('没能读取记忆'), findsNothing);
      });
    }
  }
  for (final brightness in Brightness.values) {
    testWidgets('retained memory 320dp 2x ${brightness.name}', (t) async {
      final old = fake();
      old.handlers['memory-view'] = (_) => fixture['before']['bot']['value'];
      final c = await open(t, old, fake(), scale: 2, brightness: brightness);
      final pending = Completer<Object?>();
      old.handlers['memory-view'] = (_) => pending.future;
      c.invalidate(dsBotMemoryProvider(key('bot')));
      await frames(t);
      expect(find.text(marker('bot')), findsOneWidget);
      expect(t.takeException(), isNull);
      pending.complete(fixture['after']['bot']['value']);
      await frames(t);
    });
  }
}

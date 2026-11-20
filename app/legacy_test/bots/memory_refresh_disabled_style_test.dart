import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/state/bots_state.dart';
import 'package:dsh_app/ui/bots/memory_card.dart';
import 'package:dsh_app/ui/common/list_page_row.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../chat/support/harness.dart';
import '../shell/golden_harness.dart' show goldenApp;
import 'support.dart';

Future<void> frames(WidgetTester t) async {
  for (var i = 0; i < 8; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

Finder row(String title) => find.ancestor(of: find.text(title), matching: find.byType(ListPageRow));
double opacity(WidgetTester t, Finder target) => t
    .widgetList<Opacity>(find.ancestor(of: target, matching: find.byType(Opacity)))
    .fold(1, (total, w) => total * w.opacity);
void main() {
  setUpAll(loadTestFonts);
  setUp(() => SharedPreferences.setMockInitialValues({}));
  final fixture =
      jsonDecode(File('../packages/dsh_client/test/fixtures/dsbot_memory_refresh.json').readAsStringSync()) as Map;
  for (final entity in ['bot', 'room']) {
    for (final failed in [false, true]) {
      testWidgets('$entity refreshing rows are visibly disabled; failure=$failed', (t) async {
        usePhoneView(t);
        final fake = FakeDsBotTransport(team: (fixture['team'] as Map).cast<String, Object?>())..helloOnFeed = false;
        fake.handlers['memory-view'] = (_) => fixture['before'][entity]['value'];
        await t.pumpWidget(
          goldenApp(
            brightness: Brightness.light,
            home: Scaffold(
              body: entity == 'bot' ? const BotMemoryCard(botId: 'writer') : const BotMemoryCard(roomId: 'r1'),
            ),
            overrides: dsBotOverrides(fake),
          ),
        );
        await frames(t);
        final c = ProviderScope.containerOf(t.element(find.byType(BotMemoryCard)));
        final key = (botId: entity == 'bot' ? 'writer' : null, roomId: entity == 'room' ? 'r1' : null);
        final initial = 'SYNTHETIC_${entity}_MEMORY_INITIAL';
        for (final target in [row(initial), row('添加记忆')]) {
          expect(t.widget<ListPageRow>(target).onTap, isNotNull);
          expect(opacity(t, target), 1);
        }
        final pending = Completer<Object?>();
        fake.handlers['memory-view'] = (_) => pending.future;
        c.invalidate(dsBotMemoryProvider(key));
        await frames(t);
        for (final target in [row(initial), row('添加记忆')]) {
          expect(t.widget<ListPageRow>(target).onTap, isNull);
          expect(opacity(t, target), 0.5);
          await t.tap(target);
          await t.pump();
        }
        expect(find.byType(TextField), findsNothing);
        expect(find.text('编辑'), findsNothing);
        if (failed) {
          pending.completeError(Exception('synthetic failed refresh'));
          await frames(t);
          for (final target in [row(initial), row('添加记忆')]) {
            expect(t.widget<ListPageRow>(target).onTap, isNull);
            expect(opacity(t, target), 0.5);
          }
          fake.handlers['memory-view'] = (_) => fixture['after'][entity]['value'];
          c.invalidate(dsBotMemoryProvider(key));
        } else {
          pending.complete(fixture['after'][entity]['value']);
        }
        await frames(t);
        final refreshed = 'SYNTHETIC_${entity}_MEMORY_REFRESHED';
        for (final target in [row(refreshed), row('添加记忆')]) {
          expect(t.widget<ListPageRow>(target).onTap, isNotNull);
          expect(opacity(t, target), 1);
        }
        await t.tap(row(refreshed));
        await frames(t);
        expect(find.text('编辑'), findsOneWidget);
        Navigator.of(t.element(find.text('编辑'))).pop();
        await frames(t);
        await t.tap(row('添加记忆'));
        await frames(t);
        expect(find.byType(TextField), findsOneWidget);
        expect(t.takeException(), isNull);
      });
    }
  }

  // A read-only host's rows are untappable but keep full opacity, like the
  // details page's other read-only rows; only a refresh dims them.
  for (final entity in ['bot', 'room']) {
    testWidgets('$entity read-only memory rows keep full opacity', (t) async {
      usePhoneView(t);
      final team = {...(fixture['team'] as Map).cast<String, Object?>(), 'readOnly': 'another-dsh'};
      final fake = FakeDsBotTransport(team: team)..helloOnFeed = false;
      fake.handlers['state'] = (_) => team;
      fake.handlers['memory-view'] = (_) => fixture['before'][entity]['value'];
      await t.pumpWidget(
        goldenApp(
          brightness: Brightness.light,
          home: Scaffold(
            body: entity == 'bot' ? const BotMemoryCard(botId: 'writer') : const BotMemoryCard(roomId: 'r1'),
          ),
          overrides: dsBotOverrides(fake),
        ),
      );
      await frames(t);
      final c = ProviderScope.containerOf(t.element(find.byType(BotMemoryCard)));
      expect(c.read(dsBotProvider).readOnly, isNotNull);
      final entry = row('SYNTHETIC_${entity}_MEMORY_INITIAL');
      expect(t.widget<ListPageRow>(entry).onTap, isNull);
      expect(opacity(t, entry), 1);
      expect(row('添加记忆'), findsNothing);
      expect(t.takeException(), isNull);
    });
  }
}

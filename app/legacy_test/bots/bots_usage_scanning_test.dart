import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/ui/bots/bot_details_page.dart';
import 'package:dsh_app/ui/common/page_hero.dart';
import 'package:flutter/material.dart';
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

void main() {
  final fixture =
      jsonDecode(File('../packages/dsh_client/test/fixtures/dsbot_usage_scanning.json').readAsStringSync()) as Map;
  final during = (fixture['during']['value'] as Map).cast<String, Object?>();
  final after = (fixture['after']['value'] as Map).cast<String, Object?>();
  final scanning = find.byKey(const ValueKey('usage-scanning'));
  final refresh = find.byKey(const ValueKey('usage-refresh'));
  setUpAll(loadTestFonts);
  setUp(() => SharedPreferences.setMockInitialValues({}));
  Future<FakeDsBotTransport> open(
    WidgetTester t, {
    bool complete = false,
    double scale = 1,
    Brightness brightness = Brightness.light,
  }) async {
    final fake = FakeDsBotTransport(team: sampleTeam(working: false))..helloOnFeed = false;
    fake.handlers['usage-summary'] = (_) => complete ? after : during;
    usePhoneView(t);
    t.view.physicalSize = const Size(640, 1688);
    t.platformDispatcher.textScaleFactorTestValue = scale;
    addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
    await t.pumpWidget(
      goldenApp(
        brightness: brightness,
        overrides: dsBotOverrides(fake),
        home: const BotDetailsPage(botId: 'b2'),
      ),
    );
    await frames(t);
    return fake;
  }

  Future<void> reveal(WidgetTester t, Finder target) async {
    await t.scrollUntilVisible(target, 300, scrollable: find.byType(Scrollable).first);
    await frames(t);
  }

  testWidgets('actual scanning response labels partial totals and rolling 24h', (t) async {
    await open(t);
    final hero = t.widget<PageHero>(find.byType(PageHero));
    expect(hero.stats.first.$1, '—');
    expect(hero.stats.first.$2, contains('24'));
    await reveal(t, scanning);
    expect(find.text('正在统计历史对话，数据稍后补全。'), findsOneWidget);
    expect(find.text('近 24 小时'), findsOneWidget);
    expect(find.text('今天'), findsNothing);
  });
  testWidgets('explicit refresh is single-flight and clears scanning when host finishes', (t) async {
    final fake = await open(t);
    await reveal(t, refresh);
    final pending = Completer<Object?>();
    fake.handlers['usage-summary'] = (_) => pending.future;
    final before = fake.endpoints.where((e) => e == 'usage-summary').length;
    await t.tap(refresh);
    await frames(t);
    expect(t.widget<TextButton>(refresh).onPressed, isNull);
    expect(fake.endpoints.where((e) => e == 'usage-summary'), hasLength(before + 1));
    pending.complete(after);
    await frames(t);
    expect(scanning, findsNothing);
    // A completed zero is valid and must not remain a perpetual loading marker.
    await t.scrollUntilVisible(find.byType(PageHero), -300, scrollable: find.byType(Scrollable).first);
    expect(t.widget<PageHero>(find.byType(PageHero)).stats.first.$1, '0');
  });
  testWidgets('refresh failure retains partial warning and permits retry', (t) async {
    final fake = await open(t);
    await reveal(t, refresh);
    fake.handlers['usage-summary'] = (_) => throw StateError('retry failed');
    await t.tap(refresh);
    await frames(t);
    expect(scanning, findsOneWidget);
    expect(t.widget<TextButton>(refresh).onPressed, isNotNull);
    fake.handlers['usage-summary'] = (_) => after;
    await t.tap(refresh);
    await frames(t);
    expect(scanning, findsNothing);
  });
  testWidgets('completed response has no scanning warning or extra refresh affordance', (t) async {
    await open(t, complete: true);
    expect(t.widget<PageHero>(find.byType(PageHero)).stats.first.$1, '0');
    await reveal(t, find.text('近 24 小时'));
    expect(scanning, findsNothing);
    expect(refresh, findsNothing);
  });
  for (final brightness in Brightness.values) {
    testWidgets('partial usage 320dp 2x ${brightness.name}', (t) async {
      await open(t, scale: 2, brightness: brightness);
      await reveal(t, refresh);
      expect(t.takeException(), isNull);
      expect(t.getRect(refresh).right, lessThanOrEqualTo(320));
    });
    testWidgets('usage scanning golden ${brightness.name}', (t) async {
      await open(t, brightness: brightness);
      await reveal(t, scanning);
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/usage_scanning_${brightness.name}.png'));
    }, skip: !const bool.fromEnvironment('DSBOT_GOLDENS'));
  }
}

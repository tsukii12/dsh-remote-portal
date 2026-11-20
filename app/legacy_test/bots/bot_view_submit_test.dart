import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/ui/bots/bot_chat_kit.dart';
import 'package:dsh_app/ui/bots/bot_chat_page.dart';
import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/state/bots_state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../chat/support/harness.dart';
import '../shell/golden_harness.dart' show goldenApp;
import 'support.dart';

void main() {
  setUpAll(loadTestFonts);
  setUp(() => SharedPreferences.setMockInitialValues({}));
  final raw = jsonDecode(File('../packages/dsh_client/test/fixtures/dsbot_submit.json').readAsStringSync()) as Map;
  final card = DsBotViewCard.fromJson(raw['viewState']['value']['views']['writer-now']);
  testWidgets('official text+submit view can complete with its declared action', (t) async {
    final answers = <(String, Map<String, Object?>)>[];
    await t.pumpWidget(
      goldenApp(
        brightness: Brightness.light,
        home: Scaffold(
          body: BotViewCard(
            view: card,
            onAnswer: (action, values) async {
              answers.add((action, values));
              return true;
            },
            onDismiss: () {},
          ),
        ),
      ),
    );
    expect(find.text('SYNTHETIC ready to proceed.'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Synthetic Proceed'), findsOneWidget);
    await t.tap(find.widgetWithText(FilledButton, 'Synthetic Proceed'));
    await t.pump();
    expect(answers, hasLength(1));
    expect(answers.single.$1, raw['payload']['action']);
    expect(answers.single.$2, isEmpty);
  });

  testWidgets('plain submit uses the existing send label', (t) async {
    final plain = DsBotViewCard(id: 'plain', title: '', view: {'type': 'submit', 'id': 'finish'});
    await t.pumpWidget(
      goldenApp(
        brightness: Brightness.light,
        home: Scaffold(
          body: BotViewCard(view: plain, onAnswer: (_, _) async => true, onDismiss: () {}),
        ),
      ),
    );
    expect(find.widgetWithText(FilledButton, appL10n.commonSend), findsOneWidget);
  });

  testWidgets('submit stays busy and a failed answer permits retry', (t) async {
    final pending = Completer<bool>();
    var calls = 0;
    await t.pumpWidget(
      goldenApp(
        brightness: Brightness.light,
        home: Scaffold(
          body: BotViewCard(
            view: card,
            onAnswer: (_, _) {
              calls++;
              return calls == 1 ? pending.future : Future.value(true);
            },
            onDismiss: () {},
          ),
        ),
      ),
    );
    final button = find.widgetWithText(FilledButton, 'Synthetic Proceed');
    await t.tap(button);
    await t.pump();
    expect(t.widget<FilledButton>(button).onPressed, isNull);
    pending.complete(false);
    await t.pump();
    expect(t.widget<FilledButton>(button).onPressed, isNotNull);
    await t.tap(button);
    await t.pump();
    expect(calls, 2);
  });

  for (final unsafe in <Map<String, Object?>>[
    {'type': 'slider', 'id': 'price', 'label': 'Price', 'value': 2, 'min': 0, 'max': 5},
    {'type': 'number', 'id': 'price', 'label': 'Price', 'value': 2},
    {'type': 'toggle', 'id': 'allow', 'label': 'Allow', 'value': true},
    {'type': 'future-input', 'id': 'unknown'},
    {
      'type': 'text',
      'text': {'=': 'price * 2'},
    },
    {
      'type': 'chart',
      'categories': ['A'],
      'series': [
        {
          'values': [2],
        },
      ],
    },
  ]) {
    test('submit never sends hidden ${unsafe['type']} values/defaults', () {
      expect(
        readView({
          'type': 'stack',
          'children': [
            {'type': 'submit', 'id': 'finish'},
            {
              'type': 'row',
              'children': [unsafe],
            },
          ],
        }).control,
        isNull,
      );
    });
  }

  for (final readOnly in [false, true]) {
    testWidgets('production page submit readOnly=$readOnly', (t) async {
      final team = Map<String, Object?>.from(raw['viewState']['value'] as Map);
      if (readOnly) team['readOnly'] = 'Synthetic read-only';
      final fake = FakeDsBotTransport(team: team);
      fake.handlers['chat'] = (_) => {'sessionId': 'writer-now', 'items': <Object?>[], 'cursor': null};
      fake.handlers['view-reply'] = (_) => true;
      await t.pumpWidget(
        goldenApp(
          brightness: Brightness.light,
          home: const BotChatPage(botId: 'writer'),
          overrides: dsBotOverrides(fake),
        ),
      );
      for (var i = 0; i < 10; i++) {
        await t.pump(const Duration(milliseconds: 100));
      }
      final button = find.widgetWithText(FilledButton, 'Synthetic Proceed');
      if (readOnly) {
        expect(button, findsOneWidget);
        await t.tap(button);
        await t.pump();
        expect(fake.endpoints.where((e) => e == 'view-reply'), isEmpty);
        expect(t.widget<FilledButton>(button).onPressed, isNotNull);
      } else {
        expect(button, findsOneWidget);
        await t.tap(button);
        for (var i = 0; i < 5; i++) {
          await t.pump(const Duration(milliseconds: 100));
        }
        final call = fake.calls.singleWhere((call) => call.$1 == 'view-reply');
        expect(call.$2, Map<String, Object?>.from(raw['payload'] as Map));
      }
      expect(t.takeException(), isNull);
    });
  }

  for (final brightness in Brightness.values) {
    testWidgets('static submit 320dp 2x ${brightness.name}', (t) async {
      usePhoneView(t);
      t.view.physicalSize = const Size(640, 1688);
      t.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
      await t.pumpWidget(
        goldenApp(
          brightness: brightness,
          home: Scaffold(
            body: SingleChildScrollView(
              child: BotViewCard(view: card, onAnswer: (_, _) async => true, onDismiss: () {}),
            ),
          ),
        ),
      );
      expect(find.widgetWithText(FilledButton, 'Synthetic Proceed'), findsOneWidget);
      expect(t.takeException(), isNull);
    });
  }
  testWidgets('old submit button cannot write after a production API reconnect before a frame', (t) async {
    final fake = FakeDsBotTransport(team: Map<String, Object?>.from(raw['viewState']['value'] as Map));
    fake.handlers['view-reply'] = (_) => true;
    await t.pumpWidget(
      goldenApp(
        brightness: Brightness.light,
        home: const BotChatPage(botId: 'writer'),
        overrides: dsBotOverrides(fake),
      ),
    );
    for (var i = 0; i < 10; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
    final callback = t.widget<FilledButton>(find.widgetWithText(FilledButton, 'Synthetic Proceed')).onPressed!;
    final container = ProviderScope.containerOf(t.element(find.byType(BotChatPage)));
    container.read(dsBotProvider.notifier).retry();
    callback();
    for (var i = 0; i < 10; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
    expect(fake.endpoints.where((e) => e == 'view-reply'), isEmpty);
    expect(t.takeException(), isNull);
  });
}

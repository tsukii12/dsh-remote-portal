import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/ui/bots/bot_chat_kit.dart';
import 'package:dsh_app/ui/bots/bot_chat_page.dart';
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
  final raw = jsonDecode(File('../packages/dsh_client/test/fixtures/dsbot_choice.json').readAsStringSync()) as Map;
  final card = DsBotViewCard.fromJson(raw['viewState']['value']['views']['writer-now']);
  testWidgets('official choice displays defaults and submits typed values not labels', (t) async {
    Map<String, Object?>? answer;
    String? action;
    await t.pumpWidget(
      goldenApp(
        brightness: Brightness.light,
        home: Scaffold(
          body: SingleChildScrollView(
            child: BotViewCard(
              view: card,
              onAnswer: (a, v) async {
                action = a;
                answer = v;
                return true;
              },
              onDismiss: () {},
            ),
          ),
        ),
      ),
    );
    expect(find.widgetWithText(ChoiceChip, 'One'), findsOneWidget);
    expect(t.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'One')).selected, isTrue);
    expect(t.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'Off')).selected, isTrue);
    expect(t.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'Alpha')).selected, isTrue);
    for (final label in ['Two', 'On', 'Beta']) {
      await t.tap(find.widgetWithText(ChoiceChip, label));
      await t.pump();
    }
    await t.tap(find.widgetWithText(FilledButton, 'Synthetic Proceed'));
    await t.pump();
    expect(action, raw['payload']['action']);
    expect(answer, raw['payload']['values']);
  });
  testWidgets('official ordinary form already sends string fields', (t) async {
    final form = DsBotViewCard.fromJson(raw['formState']['value']['views']['writer-now']);
    Map<String, Object?>? answer;
    await t.pumpWidget(
      goldenApp(
        brightness: Brightness.light,
        home: Scaffold(
          body: BotViewCard(
            view: form,
            onAnswer: (_, v) async {
              answer = v;
              return true;
            },
            onDismiss: () {},
          ),
        ),
      ),
    );
    await t.enterText(find.byType(TextField), 'SYNTHETIC text');
    await t.tap(find.widgetWithText(FilledButton, 'Synthetic Save'));
    await t.pump();
    expect(answer, raw['formPayload']['values']);
  });

  testWidgets('choice selection remains fixed while sending and survives a retry', (t) async {
    final pending = Completer<bool>();
    var count = 0;
    Map<String, Object?>? last;
    await t.pumpWidget(
      goldenApp(
        brightness: Brightness.light,
        home: Scaffold(
          body: SingleChildScrollView(
            child: BotViewCard(
              view: card,
              onAnswer: (_, v) {
                last = v;
                count++;
                return count == 1 ? pending.future : Future.value(true);
              },
              onDismiss: () {},
            ),
          ),
        ),
      ),
    );
    await t.tap(find.widgetWithText(ChoiceChip, 'Two'));
    await t.pump();
    await t.tap(find.widgetWithText(FilledButton, 'Synthetic Proceed'));
    await t.pump();
    await t.tap(find.widgetWithText(ChoiceChip, 'One'));
    await t.pump();
    expect(t.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'Two')).selected, isTrue);
    pending.complete(false);
    await t.pump();
    await t.tap(find.widgetWithText(FilledButton, 'Synthetic Proceed'));
    await t.pump();
    expect(count, 2);
    expect((last!['inputs'] as Map)['count'], 2);
  });

  for (final unsafe in <Map<String, Object?>>[
    {'type': 'toggle', 'id': 'hidden', 'label': 'Hidden', 'value': true},
    {
      'type': 'text',
      'text': {'=': 'count * 2'},
    },
    {'type': 'future-input', 'id': 'hidden'},
  ]) {
    test('mixed ${unsafe['type']} never sends unseen defaults', () {
      final view = Map<String, Object?>.from(card.view);
      view['children'] = [...(view['children'] as List), unsafe];
      expect(readView(view).control, isNull);
    });
  }
  for (final options in <List<Object?>>[
    [],
    [
      {'label': 'Bad', 'value': <String, Object?>{}},
    ],
    [
      {'label': 'A', 'value': 1},
      {'label': 'B', 'value': 1},
    ],
  ]) {
    test('malformed choices do not expose submit: $options', () {
      expect(
        readView({
          'type': 'stack',
          'children': [
            {'type': 'choice', 'id': 'x', 'label': 'X', 'options': options},
            {'type': 'submit', 'id': 'send'},
          ],
        }).control,
        isNull,
      );
    });
  }

  for (final readOnly in [false, true]) {
    testWidgets('production choice API preserves values, readonly=$readOnly', (t) async {
      final team = Map<String, Object?>.from(raw['viewState']['value'] as Map);
      if (readOnly) team['readOnly'] = 'Synthetic read-only';
      final fake = FakeDsBotTransport(team: team);
      fake.handlers['view-reply'] = (_) => true;
      usePhoneView(t);
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
      for (final label in ['Two', 'On', 'Beta']) {
        await t.tap(find.widgetWithText(ChoiceChip, label));
        await t.pump();
      }
      await t.tap(find.widgetWithText(FilledButton, 'Synthetic Proceed'));
      for (var i = 0; i < 6; i++) {
        await t.pump(const Duration(milliseconds: 100));
      }
      final calls = fake.calls.where((c) => c.$1 == 'view-reply');
      if (readOnly) {
        expect(calls, isEmpty);
      } else {
        expect(calls.single.$2, raw['payload']);
      }
      expect(t.takeException(), isNull);
    });
  }
  for (final brightness in Brightness.values) {
    testWidgets('choice card 320dp 2x ${brightness.name}', (t) async {
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
      expect(find.widgetWithText(ChoiceChip, 'Two'), findsOneWidget);
      expect(t.takeException(), isNull);
    });
  }
}

import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/state/bots_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/ui/bots/bot_chat_kit.dart';
import 'package:dsh_app/ui/bots/bot_chat_page.dart';
import 'package:dsh_app/ui/bots/install_card.dart';
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
      jsonDecode(File('../packages/dsh_client/test/fixtures/dsbot_mixed_choice.json').readAsStringSync()) as Map;
  final schemas =
      jsonDecode(File('../packages/dsh_client/test/fixtures/dsbot_view_schema.json').readAsStringSync()) as Map;
  for (final sample in schemas['cases'] as List) {
    test('fixed official schema scope ${sample['name']}', () {
      expect(canRenderBotView(Map<String, Object?>.from(sample['view'] as Map)), sample['native']);
    });
  }
  for (final kind in ['form', 'confirm', 'options']) {
    for (final mixed in [false, true]) {
      testWidgets('$kind preserves own payload and visible choice=$mixed', (t) async {
        final sample = fixture['cases'][kind][mixed ? 'selected' : 'plain'] as Map;
        final fake = FakeDsBotTransport(team: Map<String, Object?>.from(sample['state']['value'] as Map));
        fake.handlers['view-reply'] = (_) => true;
        usePhoneView(t);
        await t.pumpWidget(
          goldenApp(
            brightness: Brightness.light,
            home: const BotChatPage(botId: 'writer'),
            overrides: dsBotOverrides(fake),
          ),
        );
        await frames(t);
        if (mixed) {
          expect(t.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'One')).selected, isTrue);
          await t.tap(find.widgetWithText(ChoiceChip, 'Two'));
          await t.pump();
        }
        switch (kind) {
          case 'form':
            await t.enterText(find.widgetWithText(TextField, 'Synthetic body'), 'SYNTHETIC text');
            await t.tap(find.widgetWithText(FilledButton, 'Synthetic Save'));
          case 'confirm':
            await t.tap(find.widgetWithText(FilledButton, 'Confirm'));
          case 'options':
            await t.tap(find.widgetWithText(ChoiceChip, 'Accept'));
            await t.pump();
            await t.tap(find.widgetWithText(FilledButton, '发送'));
        }
        await frames(t);
        expect(fake.calls.singleWhere((c) => c.$1 == 'view-reply').$2, sample['payload']);
        expect(t.takeException(), isNull);
      });
    }
  }

  Map<String, Object?> fallbackTeam(String schema, {bool readOnly = false}) {
    final team = jsonDecode(jsonEncode(fixture['cases']['confirm']['omitted']['state']['value'])) as Map;
    final found = (schemas['cases'] as List).singleWhere((v) => v['name'] == schema);
    team['views']['writer-now']['view'] = found['view'];
    if (readOnly) team['readOnly'] = 'Synthetic read-only';
    return Map<String, Object?>.from(team);
  }

  Future<ProviderContainer> open(
    WidgetTester t,
    FakeDsBotTransport old,
    FakeDsBotTransport next,
    List<String> opened,
  ) async {
    usePhoneView(t);
    await t.pumpWidget(
      goldenApp(
        brightness: Brightness.light,
        home: const BotChatPage(botId: 'writer'),
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
          dsBotApiFactoryProvider.overrideWithValue((c) => DsBotApi((c.hostId == HostRef.none.id) ? old : next)),
          dsBotWebOpenerProvider.overrideWithValue((context, ref) => opened.add(ref.read(activeHostProvider).id)),
        ],
      ),
    );
    await frames(t);
    return ProviderScope.containerOf(t.element(find.byType(BotChatPage)));
  }

  for (final schema in ['slider', 'formula', 'future-input']) {
    testWidgets('$schema has only current-host web fallback, no answer', (t) async {
      final old = FakeDsBotTransport(team: fallbackTeam(schema));
      final next = FakeDsBotTransport(team: fallbackTeam(schema));
      final opened = <String>[];
      final c = await open(t, old, next, opened);
      expect(find.widgetWithText(FilledButton, 'Confirm'), findsNothing);
      expect(find.widgetWithText(ChoiceChip, 'Two'), findsNothing);
      await t.tap(find.byKey(const ValueKey('bot-view-open-web')));
      await t.pump();
      expect(opened, [HostRef.none.id]);
      c.read(activeHostProvider.notifier).select(const HostRef.portal('next'));
      await frames(t);
      await t.tap(find.byKey(const ValueKey('bot-view-open-web')));
      await t.pump();
      expect(opened, [HostRef.none.id, 'next']);
      expect([...old.endpoints, ...next.endpoints].where((e) => e == 'view-reply'), isEmpty);
      expect(t.takeException(), isNull);
    });
  }
  for (final change in ['host', 'api', 'boot', 'session']) {
    testWidgets('stale web callback is retired after $change', (t) async {
      final team = fallbackTeam('slider');
      final old = FakeDsBotTransport(team: team);
      final next = FakeDsBotTransport(team: fallbackTeam('slider'));
      final opened = <String>[];
      final c = await open(t, old, next, opened);
      final callback = t.widget<FilledButton>(find.byKey(const ValueKey('bot-view-open-web'))).onPressed!;
      switch (change) {
        case 'host':
          c.read(activeHostProvider.notifier).select(const HostRef.portal('next'));
        case 'api':
          c.read(dsBotProvider.notifier).retry();
        case 'boot':
          old.emit('hello', {'revision': 1, 'api': 1, 'boot': 'new-boot', 'seq': 0});
          for (var i = 0; i < 10; i++) {
            await Future<void>.value();
          }
        case 'session':
          final changed = jsonDecode(jsonEncode(team)) as Map;
          for (final bot in changed['bots'] as List) {
            if (bot['id'] == 'writer') bot['sessionId'] = 'new-part';
          }
          old.handlers['state'] = (_) => changed;
          await c.read(dsBotProvider.notifier).refresh();
      }
      callback();
      await frames(t);
      expect(opened, isEmpty);
      expect([...old.endpoints, ...next.endpoints].where((e) => e == 'view-reply'), isEmpty);
      expect(t.takeException(), isNull);
    });
  }
  testWidgets('read-only unsupported card may open its web view without answering', (t) async {
    final old = FakeDsBotTransport(team: fallbackTeam('slider', readOnly: true));
    final opened = <String>[];
    await open(t, old, old, opened);
    await t.tap(find.byKey(const ValueKey('bot-view-open-web')));
    await t.pump();
    expect(opened, [HostRef.none.id]);
    expect(old.endpoints.where((e) => e == 'view-reply'), isEmpty);
  });
}

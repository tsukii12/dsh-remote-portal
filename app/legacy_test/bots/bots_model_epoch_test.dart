// Regression based on the independent W1 review reproducer.
import 'package:dsh_app/state/bots_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/models_state.dart';
import 'package:dsh_app/ui/bots/bot_details_page.dart';
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
  void select(HostRef h) => state = h;
}

Future<void> frames(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  setUpAll(loadTestFonts);
  setUp(() => SharedPreferences.setMockInitialValues({}));
  for (final change in ['host', 'reconnect', 'removed', 'readonly', 'same']) {
    testWidgets('model sheet preserves its target after $change', (t) async {
      final old = FakeDsBotTransport()..helloOnFeed = false;
      final next = FakeDsBotTransport()..helloOnFeed = false;
      old.handlers['update-bot'] = (_) => true;
      next.handlers['update-bot'] = (_) => true;
      usePhoneView(t);
      await t.pumpWidget(
        goldenApp(
          home: const BotDetailsPage(botId: 'm1'),
          brightness: Brightness.light,
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
            modelCatalogProvider.overrideWith(
              (_) async => ModelCatalog(
                defaultSelection: null,
                groups: [
                  ProviderGroup('deepseek', 'DeepSeek', [
                    const ModelInfo(provider: 'deepseek', id: 'review-model', name: 'Review Model'),
                  ]),
                ],
                routableProviders: const ['deepseek'],
                failures: const [],
              ),
            ),
          ],
        ),
      );
      await frames(t);
      final c = ProviderScope.containerOf(t.element(find.byType(BotDetailsPage)));
      await t.tap(find.text('模型'));
      await frames(t);
      switch (change) {
        case 'host':
          c.read(activeHostProvider.notifier).select(const HostRef.portal('next'));
        case 'reconnect':
          c.read(dsBotProvider.notifier).retry();
        case 'removed' || 'readonly':
          final team = sampleTeam(working: false);
          team['revision'] = 8;
          if (change == 'removed') {
            team['bots'] = [(team['bots'] as List).last];
          } else {
            team['readOnly'] = 'owned elsewhere';
          }
          old.handlers['state'] = (_) => team;
          await c.read(dsBotProvider.notifier).refresh();
        default:
          break;
      }
      await frames(t);
      expect(c.read(dsBotProvider).ready, isTrue);
      await t.tap(find.text('Review Model'));
      await frames(t);
      expect(
        next.endpoints,
        isNot(contains('update-bot')),
        reason: 'old-host modal must not dispatch via mutable hub.api to new host',
      );
      expect(
        old.endpoints,
        change == 'same' ? contains('update-bot') : isNot(contains('update-bot')),
        reason: 'only a current writable target may receive the selection',
      );
    });
  }
}

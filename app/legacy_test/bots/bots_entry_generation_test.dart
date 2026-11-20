import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/state/bots_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/models_state.dart';
import 'package:dsh_app/ui/bots/bot_chat_kit.dart';
import 'package:dsh_app/ui/bots/bot_chat_page.dart';
import 'package:dsh_app/ui/bots/bot_details_page.dart';
import 'package:dsh_app/ui/bots/room_chat_page.dart';
import 'package:dsh_app/ui/bots/room_details_page.dart';
import 'package:dsh_app/ui/bots/room_relay_limit_sheet.dart';
import 'package:dsh_app/ui/bots/working_folder_sheet.dart';
import 'package:dsh_app/ui/common/list_page_row.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../chat/support/harness.dart';
import '../shell/golden_harness.dart' show goldenApp;
import 'room_continue_test.dart' show frames;
import 'support.dart';

class _Host extends ActiveHostController {
  @override
  HostRef build() => HostRef.none;
}

void main() {
  setUpAll(loadTestFonts);
  setUp(() => SharedPreferences.setMockInitialValues({}));
  final longPost =
      jsonDecode(File('../packages/dsh_client/test/fixtures/dsbot_long_post.json').readAsStringSync()) as Map;

  for (final entry in ['bot folder', 'room folder', 'relay limit', 'model', 'chat model', 'duplicate', 'full text']) {
    for (final transition in ['host', 'HTTP boot', 'unchanged']) {
      testWidgets('$entry entry keeps its rendered generation before a frame: $transition', (tester) async {
        Map<String, Object?> team() {
          final value = sampleTeam(working: false);
          ((value['bots'] as List).first as Map)['workDir'] = '/old';
          if (entry == 'chat model') ((value['bots'] as List).first as Map)['waiting'] = true;
          final room = (value['rooms'] as List).single as Map;
          room['workDir'] = '/old';
          room['relayLimitDefault'] = 20;
          return value;
        }

        FakeDsBotTransport transport() {
          final fake = FakeDsBotTransport(team: team())..helloOnFeed = false;
          fake.roomItems = List<Object?>.from(longPost['projected']);
          fake.handlers['state'] = (_) => team();
          fake.handlers['folders'] = (_) => {
            'team': '/team',
            'picker': null,
            'folders': [
              {'title': 'Next folder', 'path': '/next'},
            ],
          };
          fake.handlers['update-bot'] = fake.handlers['update-room'] = (_) => true;
          fake.handlers['duplicate-bot'] = (_) => {'id': 'copied-bot', 'name': 'Copy', 'sessionId': 'copied-session'};
          fake.handlers['file-text'] = (_) => longPost['full']['value'];
          return fake;
        }

        final old = transport(), next = transport();
        next.handlers['hello'] = (_) => {...next.helloAnswer(), 'boot': 'boot-2'};
        var reconnect = false;
        final Widget page = entry == 'full text'
            ? const RoomChatPage(roomId: 'r1')
            : entry == 'chat model'
            ? const BotChatPage(botId: 'm1')
            : entry == 'room folder' || entry == 'relay limit'
            ? const RoomDetailsPage(roomId: 'r1')
            : const BotDetailsPage(botId: 'm1');
        usePhoneView(tester);
        await tester.pumpWidget(
          goldenApp(
            brightness: Brightness.light,
            home: page,
            overrides: [
              activeHostProvider.overrideWith(_Host.new),
              activeConnectionProvider.overrideWith((ref) {
                final host = ref.watch(activeHostProvider);
                return AsyncData(
                  HostConnection(
                    client: fakeConnection.client,
                    label: host.id,
                    isLocal: host.isLocal,
                    kind: host.kind,
                    hostId: host.id,
                  ),
                );
              }),
              dsBotApiFactoryProvider.overrideWithValue(
                (connection) => DsBotApi((connection.hostId == HostRef.none.id) && !reconnect ? old : next),
              ),
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
        await frames(tester);
        final container = ProviderScope.containerOf(tester.element(find.byWidget(page)));
        final oldApi = container.read(dsBotProvider.notifier).api;
        Future<VoidCallback> renderedAction() async {
          if (entry == 'full text') {
            return tester
                .widget<GroupMessage>(
                  find.byWidgetPredicate((widget) => widget is GroupMessage && widget.onShowAll != null).first,
                )
                .onShowAll!;
          }
          if (entry == 'chat model') return tester.widget<BotModelCard>(find.byType(BotModelCard)).onPick;
          final finder = switch (entry) {
            'bot folder' => find.byKey(const ValueKey('bot-working-folder')),
            'room folder' => find.byKey(const ValueKey('room-working-folder')),
            'relay limit' => find.byKey(const ValueKey('room-relay-limit')),
            'duplicate' => find.byKey(const ValueKey('duplicate-bot-row')),
            _ => find.byWidgetPredicate((widget) => widget is ListPageRow && widget.title == '模型'),
          };
          await tester.scrollUntilVisible(finder, 250, scrollable: find.byType(Scrollable).first);
          return tester.widget<ListPageRow>(finder).onTap!;
        }

        final action = await renderedAction();

        if (transition == 'host') {
          container.read(activeHostProvider.notifier).select(const HostRef.portal('next'));
        } else if (transition == 'HTTP boot') {
          reconnect = true;
          old.emit('hello', {'api': 1, 'boot': 'boot-2', 'seq': 0, 'revision': 1});
        }
        if (transition != 'unchanged') {
          // Drain real provider/feed microtasks, but render no new frame.
          // The user-facing callbacks still belong to the previous generation.
          for (var i = 0; i < 12; i++) {
            await tester.idle();
            container.read(dsBotProvider);
          }
          expect(container.read(dsBotProvider).ready, isTrue);
          expect(container.read(dsBotProvider).hello?.boot, 'boot-2');
          expect(container.read(dsBotProvider.notifier).api, isNot(same(oldApi)));
        }
        action();
        await frames(tester);

        // Exercise the resulting form, if the stale entry wrongly opened it.
        Future<void> submitOpenForm() async {
          if (entry.endsWith('folder') && find.byType(WorkingFolderSheet).evaluate().isNotEmpty) {
            await tester.tap(find.byKey(const ValueKey('folder:/next')));
            await tester.pump();
            await tester.tap(find.byKey(const ValueKey('folder-save')));
            await frames(tester);
            await tester.tap(find.byKey(const ValueKey('folder-confirm')));
            await frames(tester);
          } else if (entry.endsWith('model') && find.text('Review Model').evaluate().isNotEmpty) {
            await tester.tap(find.text('Review Model'));
            await frames(tester);
          } else if (entry == 'duplicate' &&
              find.byKey(const ValueKey('duplicate-bot-confirm')).evaluate().isNotEmpty) {
            await tester.tap(find.byKey(const ValueKey('duplicate-bot-confirm')));
            await frames(tester);
          } else if (entry == 'relay limit' && find.byType(RoomRelayLimitSheet).evaluate().isNotEmpty) {
            await tester.enterText(find.byKey(const ValueKey('relay-limit-input')), '7');
            await tester.pump();
            await tester.tap(find.byKey(const ValueKey('relay-limit-save')));
            await frames(tester);
          }
        }

        await submitOpenForm();
        final endpoint = switch (entry) {
          'bot folder' || 'model' || 'chat model' => 'update-bot',
          'room folder' || 'relay limit' => 'update-room',
          'duplicate' => 'duplicate-bot',
          _ => 'file-text',
        };
        expect(
          next.endpoints.where((value) => value == endpoint),
          isEmpty,
          reason: 'an old entry must not recapture a new connection and send $endpoint',
        );
        expect(old.endpoints.where((value) => value == endpoint), transition == 'unchanged' ? hasLength(1) : isEmpty);
        if (transition != 'unchanged') {
          final fresh = await renderedAction();
          fresh();
          await frames(tester);
          await submitOpenForm();
          expect(
            next.endpoints.where((value) => value == endpoint),
            hasLength(1),
            reason: 'a freshly rendered entry must work on the new generation',
          );
        }
        expect(tester.takeException(), isNull);
      });
    }
  }
}

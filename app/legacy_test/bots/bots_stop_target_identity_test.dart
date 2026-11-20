import 'package:dsh_app/state/bots_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/ui/bots/bot_chat_page.dart';
import 'package:dsh_app/ui/bots/room_chat_page.dart';
import 'package:dsh_app/ui/chat/composer.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../chat/support/harness.dart';
import '../chat/support/composer_fakes.dart';
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

void main() {
  setUpAll(loadTestFonts);
  setUp(() => SharedPreferences.setMockInitialValues({}));
  for (final room in [false, true]) {
    for (final mode in [
      'current',
      'host',
      'host ABA',
      'reconnect',
      'entity ABA',
      'readOnly',
      'benign',
      'part',
      'part ABA',
    ]) {
      if (room && mode.startsWith('part')) continue;
      testWidgets('${room ? 'room' : 'bot'} stop target mode=$mode', (t) async {
        usePhoneView(t);
        final a = FakeRpcCarrier({
              'session/cancel': (_) => {'accepted': true},
            }),
            b = FakeRpcCarrier({
              'session/cancel': (_) => {'accepted': true},
            });
        final ca = DshClient.withCarrier(a), cb = DshClient.withCarrier(b);
        addTearDown(() async {
          await ca.close();
          await cb.close();
        });
        final fa = FakeDsBotTransport()
              ..helloOnFeed = false
              ..roomRunning = true,
            fb = FakeDsBotTransport()
              ..helloOnFeed = false
              ..roomRunning = true;
        var reconnected = false;
        await t.pumpWidget(
          goldenApp(
            brightness: Brightness.light,
            home: room ? const RoomChatPage(roomId: 'r1') : const BotChatPage(botId: 'm1'),
            overrides: [
              activeHostProvider.overrideWith(_Host.new),
              activeConnectionProvider.overrideWith((ref) {
                final host = ref.watch(activeHostProvider);
                return AsyncData(
                  HostConnection(
                    client: (host.id == HostRef.none.id) ? ca : cb,
                    isLocal: host.isLocal,
                    kind: host.kind,
                    hostId: host.id,
                  ),
                );
              }),
              dsBotApiFactoryProvider.overrideWithValue((conn) => DsBotApi((conn.hostId == HostRef.none.id) && !reconnected ? fa : fb)),
            ],
          ),
        );
        await frames(t);
        final c = ProviderScope.containerOf(t.element(find.byType(Composer)));
        final stop = t.widget<Composer>(find.byType(Composer));
        expect(stop.running, isTrue);
        final originApi = c.read(dsBotProvider.notifier).api;
        if (mode.startsWith('host')) {
          c.read(activeHostProvider.notifier).select(const HostRef.portal('next'));
          expect(c.read(activeConnectionProvider).value!.client, same(cb));
          c.read(dsBotProvider);
          if (mode == 'host ABA') {
            c.read(activeHostProvider.notifier).select(HostRef.none);
            c.read(activeConnectionProvider);
            c.read(dsBotProvider);
          }
        }
        if (mode == 'reconnect') {
          reconnected = true;
          c.read(dsBotProvider.notifier).retry();
          await frames(t);
          expect(identical(c.read(dsBotProvider.notifier).api, originApi), isFalse);
        }
        if (mode == 'entity ABA') {
          final removed = sampleTeam();
          if (room) {
            removed['rooms'] = <Object?>[];
          } else {
            removed['bots'] = (removed['bots'] as List).where((v) => v['id'] != 'm1').toList();
          }
          fa.handlers['state'] = (_) => removed;
          await c.read(dsBotProvider.notifier).refresh();
          fa.handlers['state'] = (_) => sampleTeam();
          await c.read(dsBotProvider.notifier).refresh();
        }
        if (mode.startsWith('part')) {
          final team = sampleTeam();
          (team['bots'] as List).firstWhere((v) => v['id'] == 'm1')['sessionId'] = 'm1-next';
          fa.handlers['state'] = (_) => team;
          await c.read(dsBotProvider.notifier).refresh();
          if (mode == 'part ABA') {
            fa.handlers['state'] = (_) => sampleTeam();
            await c.read(dsBotProvider.notifier).refresh();
          }
        }
        if (mode == 'readOnly') {
          fa.handlers['state'] = (_) => {...sampleTeam(), 'readOnly': 'another-dsh'};
          await c.read(dsBotProvider.notifier).refresh();
        }
        if (mode == 'benign') {
          fa.handlers['state'] = (_) => {...sampleTeam(), 'revision': 8};
          await c.read(dsBotProvider.notifier).refresh();
        }

        stop.onStop();
        await frames(t);
        expect(b.argsOf('session/cancel'), isEmpty, reason: 'old rendered stop must not address the next Host');
        expect(
          a.argsOf('session/cancel'),
          (mode != 'current' && mode != 'benign')
              ? isEmpty
              : [
                  {
                    'request': {'sessionId': room ? 'r1' : 'm1c'},
                  },
                ],
        );
        if (mode == 'host' || mode == 'reconnect') {
          final current = t.widget<Composer>(find.byType(Composer));
          expect(current.running, isTrue);
          current.onStop();
          await frames(t);
          expect((mode == 'host' ? b : a).argsOf('session/cancel'), [
            {
              'request': {'sessionId': room ? 'r1' : 'm1c'},
            },
          ]);
        }
        expect(t.takeException(), isNull);
      });
    }
  }
}

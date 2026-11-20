import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/state/attachments.dart';
import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/ui/chat/chat_list.dart';
import 'package:dsh_app/ui/chat/widgets/assistant_message.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../packages/dsh_client/test/support/fake_dsh.dart';
import 'support/harness.dart';
import 'support/session_sync_host.dart';

class _Connection extends Notifier<HostConnection?> {
  _Connection(this.initial);
  final HostConnection initial;
  @override
  HostConnection? build() => initial;
  void replace(DshClient client) => state = HostConnection(hostId: '', client: client, isLocal: true, label: 'same Host');
}

final _connection = NotifierProvider<_Connection, HostConnection?>(() => throw UnimplementedError());

class _Carrier extends HeldReplyCarrier {
  _Carrier(super.inner, super.hold);
  final calls = <String>[];
  @override
  Future<RpcResult> call(String endpoint, Map<String, Object?> args, {Duration? timeout}) {
    calls.add(endpoint);
    return super.call(endpoint, args, timeout: timeout);
  }
}

class _Client {
  _Client(this.client, this.carrier, this.hold);
  final DshClient client;
  final _Carrier carrier;
  final ReplyHold hold;
}

class _Host {
  _Host(this.server);
  final FakeDsh server;
  final clients = <_Client>[];
  bool failImage = false;
  static const image = {
    'attachmentId': 'image-1',
    'mediaType': 'image/png',
    'name': 'original.png',
    'width': 4,
    'height': 4,
  };

  static Future<_Host> start() async {
    final h = _Host(await FakeDsh.start());
    h.server.handlers['session/attachment'] = (_) => h.failImage
        ? {
            'ok': false,
            'error': {'code': 'image/missing', 'message': 'held image failure'},
          }
        : {
            'ok': true,
            'value': {'attachment': image, 'data': base64Encode(tinyPng)},
          };
    h.server.handlers['session/projections'] = (_) => {'ok': true, 'value': null};
    h.server.handlers['session/fork'] = (_) => {
      'ok': true,
      'value': {'sessionId': 'fork-S'},
    };
    h.server.onOpen = (socket, id, endpoint, _) {
      if (endpoint != 'session/follow') throw StateError(endpoint);
      final snapshot = syncSnapshot(1);
      snapshot['cursor'] = 4;
      snapshot['records'] = [
        syncEvent('turn/end', 1, 0),
        {
          'type': 'event',
          'event': {
            'type': 'user/message',
            'seq': 2,
            'time': 1792700000002,
            'data': {
              'id': 'user-S',
              'role': 'user',
              'source': {'kind': 'user', 'rpcId': 'request-S'},
              'content': [
                {'type': 'text', 'text': 'look at this'},
                {'type': 'image', 'attachment': image},
              ],
            },
          },
        },
        {
          'type': 'event',
          'event': {
            'type': 'assistant/message',
            'seq': 3,
            'time': 1792700000003,
            'data': {
              'turn': 1,
              'step': 1,
              'message': {
                'id': 'reply-S',
                'role': 'assistant',
                'content': [
                  {'type': 'text', 'text': 'original answer'},
                ],
                'source': {'kind': 'assistant'},
              },
            },
          },
        },
        syncEvent('turn/end', 4, 1),
      ];
      snapshot['hasMore'] = false;
      snapshot['projections'] = {'asOfSeq': 4, 'values': <String, Object?>{}};
      socket.item(id, snapshot);
    };
    return h;
  }

  Future<_Client> connect({bool holdImage = false}) async {
    final connection = DshConnection(server.baseUri);
    await connection.login(FakeDsh.token);
    final hold = ReplyHold();
    if (holdImage) hold.arm('session/attachment');
    final carrier = _Carrier(DshHttpCarrier(connection), hold);
    final client = DshClient.withCarrier(
      carrier,
      muxOptions: const MuxOptions(readyTimeout: Duration(seconds: 2), retryCaps: [Duration(milliseconds: 20)]),
    );
    final peer = _Client(client, carrier, hold);
    clients.add(peer);
    await client.mux.ready();
    return peer;
  }

  int get forks => server.rpcCalls.where((c) => c['method'] == 'session/fork').length;
  Future<void> close() async {
    for (final peer in clients) {
      peer.hold.finish();
      await peer.client.close();
    }
    await server.close();
  }
}

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() ready,
  String reason, {
  Duration step = const Duration(milliseconds: 5),
}) async {
  for (var i = 0; i < 300; i++) {
    if (ready()) return;
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
    await tester.pump(step);
  }
  fail('UI/IO did not settle: $reason');
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  for (final mode in ['same', 'same-failure', 'new-client', 'client-roundtrip', 'new-mux', 'new-mux-failure']) {
    testWidgets('regenerate image await retains original connection intent: $mode', (tester) async {
      late _Host host;
      late _Client a;
      late ProviderContainer c;
      final resent = <String>[];
      await tester.runAsync(
        () => HttpOverrides.runWithHttpOverrides(() async {
          host = await _Host.start();
          host.failImage = mode.endsWith('failure');
          a = await host.connect(holdImage: true);
          final ui = ChatHarness(session: 'S');
          c = ProviderContainer(
            overrides: [
              for (final override in ui.overrides)
                if (override.origin != activeConnectionProvider && override.origin != chatProvider) override,
              _connection.overrideWith(
                () => _Connection(HostConnection(hostId: '', client: a.client, isLocal: true, label: 'same Host')),
              ),
              activeConnectionProvider.overrideWith((ref) => AsyncData(ref.watch(_connection))),
            ],
          );
        }, RealSyncHttp()),
      );
      usePhoneView(tester);
      try {
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: c,
            child: testApp(
              Scaffold(
                body: ChatList(
                  key: const ValueKey('S'),
                  sessionId: 'S',
                  topInset: 0,
                  bottomInset: 0,
                  onResend: (id, text, List<DraftAttachment> images) async {
                    resent.add('$id:$text:${images.length}');
                  },
                ),
              ),
            ),
          ),
        );
        await _pumpUntil(
          tester,
          () =>
              c.read(chatProvider('S')).controlReady &&
              a.hold.received!.isCompleted &&
              find.byTooltip('重新回答').evaluate().isNotEmpty,
          'initial snapshot, image request and regenerate button',
        );
        final listState = tester.state(find.byType(ChatList));
        final controller = c.read(chatProvider('S').notifier);
        expect(c.read(currentSessionProvider), 'S');
        expect(host.forks, 0);
        await tester.tap(find.byTooltip('重新回答'));
        await tester.pump();
        expect(tester.widget<AssistantMessage>(find.byType(AssistantMessage)).regenerating, isTrue);
        if (mode == 'new-client' || mode == 'client-roundtrip') {
          late _Client b;
          await tester.runAsync(
            () => HttpOverrides.runWithHttpOverrides(() async {
              b = await host.connect(holdImage: true); // Same actual authority, fresh authenticated client.
            }, RealSyncHttp()),
          );
          c.read(_connection.notifier).replace(b.client);
          await tester.pump();
          await _pumpUntil(
            tester,
            () => c.read(chatProvider('S')).controlReady && b.hold.received!.isCompleted,
            'replacement client snapshot and held image reply',
          );
          expect(c.read(activeConnectionProvider).value!.client, same(b.client));
          expect(c.read(currentSessionProvider), 'S', reason: 'same Host retry does not clear the session');
          if (mode == 'client-roundtrip') {
            c.read(_connection.notifier).replace(a.client);
            await tester.pump();
            await _pumpUntil(tester, () => c.read(chatProvider('S')).controlReady, 'original client restored');
            expect(c.read(activeConnectionProvider).value!.client, same(a.client));
          }
          b.hold.finish();
        } else if (mode.startsWith('new-mux')) {
          final oldGeneration = a.client.mux.generation;
          await tester.runAsync(() async {
            unawaited(host.server.sockets.last.ws.close(1001, 'B20 real reconnect'));
          });
          await _pumpUntil(
            tester,
            () =>
                a.client.mux.generation != null &&
                !identical(a.client.mux.generation, oldGeneration) &&
                c.read(chatProvider('S')).controlReady,
            'new mux generation and production snapshot',
          );
          expect(c.read(currentSessionProvider), 'S', reason: 'mux reconnect keeps the current session');
        }
        expect(tester.state(find.byType(ChatList)), same(listState));
        expect(c.read(chatProvider('S').notifier), same(controller));
        await tester.runAsync(() async {
          a.hold.finish();
        });
        await _pumpUntil(
          tester,
          () => !tester.widget<AssistantMessage>(find.byType(AssistantMessage)).regenerating,
          'original image operation finished',
          step: mode.endsWith('failure') ? const Duration(milliseconds: 250) : const Duration(milliseconds: 5),
        );
        final currentOwner = mode == 'same' || mode == 'same-failure';
        expect(host.forks, mode == 'same' ? 1 : 0, reason: 'old image wait must not enter a new owner fork');
        expect(resent, mode == 'same' ? ['fork-S:look at this:1'] : isEmpty);
        expect(
          c.read(chatProvider('S')).error,
          currentOwner && mode.endsWith('failure') ? appL10n.chatReadOriginalImageFailed : isNull,
          reason: 'old image error must not be published into a new synchronization owner',
        );
      } finally {
        a.hold.finish();
        await tester.pumpWidget(const SizedBox());
        c.dispose();
        await tester.pump(const Duration(milliseconds: 600));
        var closed = false;
        Object? closeError;
        await tester.runAsync(() async {
          unawaited(
            host.close().then(
              (_) {
                closed = true;
              },
              onError: (Object error) {
                closeError = error;
                closed = true;
              },
            ),
          );
        });
        await _pumpUntil(tester, () => closed, 'transport cleanup while pumping stream cancellations');
        expect(closeError, isNull);
      }
    });
  }
}

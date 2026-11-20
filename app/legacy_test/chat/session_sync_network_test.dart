import 'dart:async';
import 'dart:io';

import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/session_sync_host.dart';

// Only the recovery deadline is controlled; socket I/O and all other timers
// remain real. Timer's factory supplies a callback bound to the creating Zone.
class _RecoveryDeadline implements Timer {
  _RecoveryDeadline(this.callback);
  final void Function() callback;
  bool _active = true;
  int _tick = 0;

  @override
  bool get isActive => _active;
  @override
  int get tick => _tick;
  @override
  void cancel() => _active = false;

  void fire() {
    if (!_active) throw StateError('recovery deadline was already cancelled');
    _active = false;
    _tick = 1;
    callback();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Future<void> scenario(Future<void> Function(SyncHarness h) run, {ReplyHold? hold, bool initialSnapshot = true}) =>
      HttpOverrides.runWithHttpOverrides(() async {
        final h = await SyncHarness.start(hold: hold, initialSnapshot: initialSnapshot);
        try {
          await run(h);
        } finally {
          await h.close();
        }
      }, RealSyncHttp());

  test(
    'fresh snapshot permits stop and preserves inbox wake order',
    () => scenario((h) async {
      await h.chat.cancel();
      expect(h.methods, ['session/cancel', 'session/updateQueue', 'session/prompt']);
    }),
  );

  for (final phase in [
    'terminal-follow-error',
    'same-generation-follow-retry',
    'new-mux-ready-snapshot-held',
    'websocket-refused-http-live',
  ]) {
    for (final action in ['cancel', 'sendNow', 'interrupt', 'steer', 'withdraw']) {
      test(
        '$phase blocks new $action before any write RPC',
        () => scenario((h) async {
          await h.enter(phase);
          expect(h.state.controlReady, isFalse);
          final prompt = h.state.pending.single;
          switch (action) {
            case 'cancel':
              expect(await h.chat.cancel(), isEmpty);
            case 'sendNow':
              expect(await h.chat.sendNow(prompt), isEmpty);
            case 'interrupt':
              expect(await h.chat.send('interrupt', mode: SendMode.interrupt), isFalse);
            case 'steer':
              expect(await h.chat.steerQueued(prompt), isFalse);
            case 'withdraw':
              expect(await h.chat.withdrawQueued(prompt), isFalse);
          }
          expect(h.methods, isEmpty);
          syncTrace('$phase/$action', h.fact());
        }),
      );
    }
  }

  test(
    'manual recovery actually reopens a failed follow without resetting the mux',
    () => scenario((h) async {
      await h.enter('terminal-follow-error');
      h.followMode = 'hold';
      final generation = h.client.mux.generation;
      final recovery = h.chat.resync();
      expect(identical(recovery, h.chat.resync()), isTrue, reason: 'one bounded recovery in flight');
      await waitSync(() => h.follows.length == 7, 'fresh follow');
      expect(h.state.controlReady, isFalse);
      expect(h.observedTurns, [1]);
      h.follows.last.socket.item(h.follows.last.id, syncSnapshot(2));
      expect(await recovery, isTrue);
      expect(h.state.controlReady, isTrue);
      expect(h.observedTurns, [1, 2]);
      expect(h.state.pending.single.inboxId, 'queue-run-2');
      expect(identical(generation, h.client.mux.generation), isTrue);
      await h.chat.cancel();
      expect((h.boundary[1]['request'] as Map)['itemId'], 'queue-run-2');
    }),
  );

  for (final defect in ['normal-end', 'revision-gap', 'durable-gap']) {
    test(
      '$defect revokes controls until a new complete snapshot',
      () => scenario((h) async {
        h.followMode = 'hold';
        final old = h.follows.last;
        switch (defect) {
          case 'normal-end':
            old.socket.send({'type': 'end', 'streamId': old.id});
          case 'revision-gap':
            old.socket.item(old.id, {
              'type': 'assistant-stream',
              'frame': {'type': 'start', 'attemptId': 'a', 'revision': 2, 'turn': 1, 'step': 1},
            });
          case 'durable-gap':
            old.socket.item(old.id, syncEvent('turn/start', 2, 2));
        }
        await waitSync(() => !h.state.controlReady, 'immediate revocation');
        await h.chat.cancel();
        expect(h.methods, isEmpty);
        await waitSync(() => h.follows.length == 2, 'reopened follow');
        expect(h.state.controlReady, isFalse);
        h.follows.last.socket.item(h.follows.last.id, syncSnapshot(2));
        await waitSync(() => h.state.controlReady, 'fresh applied snapshot');
        expect(h.observedTurns, [1, 2]);
      }),
    );
  }

  for (final action in ['cancel', 'sendNow', 'interrupt']) {
    test('same-mux follow retirement stops old $action continuation', () async {
      final hold = ReplyHold()..arm(action == 'sendNow' ? 'session/updateQueue' : 'session/cancel');
      await scenario((h) async {
        final Future<Object?> operation = switch (action) {
          'cancel' => h.chat.cancel(),
          'sendNow' => h.chat.sendNow(h.state.pending.single),
          _ => h.chat.send('interrupt', mode: SendMode.interrupt),
        };
        await hold.received!.future;
        await h.enter('same-generation-follow-retry', unchangedInbox: false);
        hold.finish();
        await operation;
        expect(h.methods, [action == 'sendNow' ? 'session/updateQueue' : 'session/cancel']);
        expect(h.state.controlReady, isFalse);
        expect(h.state.stopping, isFalse);
      }, hold: hold);
    });
  }

  test('history repair must finish before snapshot unlock; retired late repair cannot overwrite recovery', () async {
    final hold = ReplyHold()..arm('session/page');
    await scenario((h) async {
      await h.enter('new-mux-ready-snapshot-held');
      h.host.handlers['session/page'] = (args) => {
        'ok': true,
        'value': {
          'records': [syncEvent('turn/end', 1, 1), syncEvent('turn/start', 2, 2)],
          'hasMore': false,
        },
      };
      final pending = h.follows.last;
      pending.socket.item(pending.id, {
        ...syncSnapshot(2),
        'cursor': 3,
        'records': [syncEvent('step/start', 3, 2)],
      });
      await hold.received!.future;
      expect(h.state.controlReady, isFalse);
      await h.chat.cancel();
      expect(h.methods, ['session/page']);
      // A new explicit attempt supersedes the outstanding repaired snapshot.
      final recovery = h.chat.resync();
      await waitSync(() => h.follows.length == 3, 'replacement follow');
      h.follows.last.socket.item(h.follows.last.id, {
        ...syncSnapshot(2),
        'projections': {
          'asOfSeq': 2,
          'values': {
            'inbox': {
              'next-turn': [syncItem('replacement')],
              'next-step': <Object?>[],
            },
          },
        },
      });
      expect(await recovery, isTrue);
      hold.finish();
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(h.state.controlReady, isTrue);
      expect(h.state.pending.single.inboxId, 'replacement');
    }, hold: hold);
  });

  test(
    'first ordinary message waits for initial snapshot and uses its real running state',
    () => scenario((h) async {
      final sent = h.chat.send('first message');
      await Future<void>.delayed(const Duration(milliseconds: 25));
      expect(h.methods, isEmpty);
      h.follows.last.socket.item(h.follows.last.id, {
        ...syncSnapshot(1),
        'cursor': -1,
        'records': <Object?>[],
        'projections': {
          'asOfSeq': -1,
          'values': {
            'inbox': {'next-turn': <Object?>[], 'next-step': <Object?>[]},
          },
        },
      });
      expect(await sent, isTrue);
      expect(h.methods, ['session/prompt']);
      expect((h.boundary.single['request'] as Map)['mode'], 'queue');
    }, initialSnapshot: false),
  );

  test(
    'manual recovery deadline cancels its follow; late snapshot cannot unlock',
    () => scenario((h) async {
      h.followMode = 'hold';
      final deadlines = <_RecoveryDeadline>[];
      var capturing = true;
      late final Future<bool> recovery;
      try {
        recovery = runZoned<Future<bool>>(
          h.chat.resync,
          zoneSpecification: ZoneSpecification(
            createTimer: (self, parent, zone, duration, callback) {
              if (capturing && duration == const Duration(seconds: 10)) {
                final timer = _RecoveryDeadline(callback);
                deadlines.add(timer);
                return timer;
              }
              return parent.createTimer(zone, duration, callback);
            },
          ),
        );
      } finally {
        // Inherited async continuations must delegate every later timer.
        capturing = false;
      }
      expect(deadlines, hasLength(1), reason: 'only the synchronous recovery timeout');
      await waitSync(() => h.follows.length == 2, 'recovery follow');
      final pending = h.follows.last;
      expect(h.state.controlReady, isFalse);
      expect(deadlines.single.isActive, isTrue);
      deadlines.single.fire();
      expect(await recovery, isFalse);
      expect(h.state.controlReady, isFalse);
      expect(h.state.resyncing, isFalse);
      await waitSync(
        () => pending.socket.received.any((frame) => frame['type'] == 'cancel' && frame['streamId'] == pending.id),
        'real mux cancel',
      );
      pending.socket.item(pending.id, syncSnapshot(2));
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(h.state.controlReady, isFalse);
      expect(h.observedTurns, [1]);
      syncTrace('controlled recovery deadline', {
        'capturedTimers': deadlines.length,
        'deadlineTicks': deadlines.single.tick,
        'cancelFrames': pending.socket.received
            .where((frame) => frame['type'] == 'cancel' && frame['streamId'] == pending.id)
            .toList(),
        'lateSnapshotControlReady': h.state.controlReady,
        'observedTurns': h.observedTurns,
      });
    }),
    timeout: const Timeout(Duration(seconds: 20)),
  );
  test('immediate epoch revocation blocks controls even before a UI sync event', () async {
    await HttpOverrides.runWithHttpOverrides(() async {
      SessionFollowEpoch? epoch;
      final h = await SyncHarness.start(
        observe: (event) {
          if (event is SessionSnapshotEvent) epoch = event.followEpoch;
        },
      );
      try {
        expect(h.state.controlReady, isTrue);
        epoch!.retire();
        expect(h.state.controlReady, isTrue, reason: 'The queued UI notification has not run');
        await h.chat.cancel();
        expect(h.methods, isEmpty);
      } finally {
        await h.close();
      }
    }, RealSyncHttp());
  });

  test(
    'first-message wait retires when its connection is removed',
    () => scenario((h) async {
      final sent = h.chat.send('keep the original draft');
      h.container.updateOverrides([activeConnectionProvider.overrideWithValue(const AsyncData(null))]);
      await h.container.pump();
      expect(await sent, isFalse);
      expect(h.methods, isEmpty);
    }, initialSnapshot: false),
  );
  test('snapshot queued before a reconnect cannot adopt its replacement mux', () async {
    await HttpOverrides.runWithHttpOverrides(() async {
      late SyncHarness h;
      var disconnectedAtDelivery = false;
      h = await SyncHarness.start(
        initialSnapshot: false,
        observe: (event) {
          if (event is SessionSnapshotEvent && !disconnectedAtDelivery) {
            disconnectedAtDelivery = true;
            // Deterministically lose the mux between watch emission and the
            // controller's delivery, while the old token's event is queued.
            h.client.mux.reconnect();
          }
        },
      );
      final readyStates = <bool>[];
      final subscription = h.container.listen(chatProvider('S'), (_, next) {
        readyStates.add(next.controlReady);
      });
      try {
        h.follows.last.socket.item(h.follows.last.id, syncSnapshot(1));
        await waitSync(
          () => h.client.mux.generation?.number == 2 && h.follows.length == 2,
          'new mux with held snapshot',
        );
        expect(readyStates, isNot(contains(true)));
        expect(h.observedTurns, isEmpty);
        expect(h.state.controlReady, isFalse);
        await h.chat.cancel();
        expect(h.methods, isEmpty);
        h.follows.last.socket.item(h.follows.last.id, syncSnapshot(2));
        await waitSync(() => h.state.controlReady, 'replacement baseline');
        expect(h.observedTurns, [1, 2]);
      } finally {
        subscription.close();
        await h.close();
      }
    }, RealSyncHttp());
  });
}

// Model replies retain only their original controller lifetime, client, mux
// and request order. Real DshClient and loopback HTTP/WS are used throughout.
import 'dart:async';
import 'dart:io';

import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/session_sync_host.dart';

const _a = ModelSelection(provider: 'review', model: 'requested-A');
const _appliedA = ModelSelection(provider: 'review', model: 'accepted-A');
const _b = ModelSelection(provider: 'review', model: 'current-B');
const _previous = ModelSelection(provider: 'review', model: 'previous');

void _models(SyncHarness h, {bool failA = false}) {
  h.host.handlers['session/selectModel'] = (args) {
    final request = args['request']! as Map;
    if (request['model'] == _a.model && failA) {
      return {
        'ok': false,
        'error': {'code': 'gateway/internal', 'message': 'Controlled old model failure', 'details': {}},
      };
    }
    return {
      'ok': true,
      'value': {'selected': request['model'] == _a.model ? _appliedA.toJson() : request},
    };
  };
}

void _replace(SyncHarness owner, SyncHarness target) {
  owner.container.updateOverrides([
    activeConnectionProvider.overrideWithValue(AsyncData(HostConnection(hostId: '', client: target.client, isLocal: true))),
  ]);
  // Force the actual dependency rebuild before any held result is released.
  owner.container.read(chatProvider('S'));
}

void _trace(SyncHarness h, String name, {bool? result}) => syncTrace('r4-model/$name', {
  'model': h.state.model?.toJson(),
  'error': h.state.error,
  'ready': h.state.controlReady,
  'muxGeneration': h.client.mux.generation?.number,
  'methods': h.methods,
  'result': result,
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> scenario(
    Future<void> Function(SyncHarness h) run, {
    ReplyHold? hold,
    bool initialSnapshot = true,
    bool failA = false,
  }) => HttpOverrides.runWithHttpOverrides(() async {
    final h = await SyncHarness.start(hold: hold, initialSnapshot: initialSnapshot);
    _models(h, failA: failA);
    try {
      await run(h);
    } finally {
      hold?.finish();
      await h.close();
    }
  }, RealSyncHttp());

  test(
    'current model selection succeeds before the first complete snapshot',
    () => scenario((h) async {
      expect(h.state.controlReady, isFalse);
      expect(await h.chat.setModel(_a), isTrue);
      expect(h.state.model!.toJson(), _appliedA.toJson());
      expect(h.state.controlReady, isFalse);
      expect(h.state.error, isNull);
      expect(h.methods, ['session/selectModel']);
      _trace(h, 'before-first-snapshot', result: true);
    }, initialSnapshot: false),
  );

  test(
    'current model failure restores the prior model and reports its error',
    () => scenario((h) async {
      expect(await h.chat.setModel(_previous), isTrue);
      final before = h.state;
      expect(await h.chat.setModel(_a), isFalse);
      expect(h.state.model!.toJson(), _previous.toJson());
      expect(h.state.error, isNotNull);
      expect(h.state.items, before.items);
      expect(h.state.pending, before.pending);
      expect(h.state.running, before.running);
      expect(h.state.controlReady, before.controlReady);
      _trace(h, 'current-failure', result: false);
    }, failA: true),
  );

  test(
    'default persistence failure keeps the applied session model and reports only the save failure',
    () => scenario((h) async {
      h.host.handlers['session/selectModel'] = (args) => {
        'ok': true,
        'value': {
          'selected': _appliedA.toJson(),
          'defaultSave': {'status': 'failed', 'code': 'settings/default-save-failed'},
        },
      };
      expect(await h.chat.setModel(_a), isTrue);
      expect(h.state.model!.toJson(), _appliedA.toJson());
      expect(h.state.error, isNull);
      expect(h.state.defaultModelSaveFailed, isTrue);
      expect(h.methods, ['session/selectModel']);
      for (final status in [null, 'unknown', 'saved', 'failed', 'skipped']) {
        h.host.handlers['session/selectModel'] = (args) => {
          'ok': true,
          'value': {
            'selected': _b.toJson(),
            if (status != null) 'defaultSave': {'status': status},
          },
        };
        expect(await h.chat.setModel(_b), isTrue);
        expect(h.state.defaultModelSaveFailed, status != 'saved' && status != 'skipped');
      }
      h.chat.dismissDefaultModelSaveWarning();
      expect(h.state.defaultModelSaveFailed, isFalse);
    }),
  );

  for (final failA in [false, true]) {
    test('old host ${failA ? 'error' : 'success'} cannot alter the replacement host model', () async {
      final hold = ReplyHold()..arm('session/selectModel');
      SyncHarness? next;
      addTearDown(() async => next?.close());
      await scenario(
        (h) async {
          try {
            final old = h.chat.setModel(_a);
            await hold.received!.future;
            next = await SyncHarness.start();
            _models(next!);
            _replace(h, next!);
            expect(await h.chat.setModel(_b), isTrue);
            expect(h.state.model!.toJson(), _b.toJson());
            hold.finish();
            final oldResult = await old;
            _trace(h, 'old-host-$failA', result: oldResult);
            expect(oldResult, isFalse);
            expect(h.state.model!.toJson(), _b.toJson());
            expect(h.state.error, isNull);
            expect(h.methods, ['session/selectModel']);
            expect(next!.methods, ['session/selectModel']);
          } finally {
            // Keep the replacement client alive until the owner is disposed.
            hold.finish();
          }
        },
        hold: hold,
        failA: failA,
      );
    });
  }

  test('host A B A retires the first A model even when the client identity returns', () async {
    final hold = ReplyHold()..arm('session/selectModel');
    SyncHarness? next;
    addTearDown(() async => next?.close());
    await scenario((h) async {
      final old = h.chat.setModel(_a);
      await hold.received!.future;
      next = await SyncHarness.start();
      _replace(h, next!);
      await waitSync(() => h.state.controlReady, 'B snapshot');
      _replace(h, h);
      await waitSync(() => h.state.controlReady, 'returned A snapshot');
      final before = h.state.model!.toJson();
      hold.finish();
      final oldResult = await old;
      _trace(h, 'host-ABA', result: oldResult);
      expect(oldResult, isFalse);
      expect(h.state.model!.toJson(), before);
      expect(h.state.model!.toJson(), isNot(_appliedA.toJson()));
      expect(h.state.error, isNull);
    }, hold: hold);
  });

  test('a same-client provider rebuild retires the prior model continuation', () async {
    final hold = ReplyHold()..arm('session/selectModel');
    await scenario((h) async {
      final old = h.chat.setModel(_a);
      await hold.received!.future;
      final generation = h.client.mux.generation;
      h.container.invalidate(chatProvider('S'));
      h.container.read(chatProvider('S'));
      await waitSync(() => h.state.controlReady, 'rebuilt current controller');
      final before = h.state.model?.toJson();
      expect(identical(h.client.mux.generation, generation), isTrue);
      hold.finish();
      final oldResult = await old;
      _trace(h, 'same-client-ref-rebuild', result: oldResult);
      expect(oldResult, isFalse);
      expect(h.state.model?.toJson(), before);
      expect(h.state.error, isNull);
    }, hold: hold);
  });

  test('a new mux retires a held model reply without requiring a replacement client', () async {
    final hold = ReplyHold()..arm('session/selectModel');
    await scenario((h) async {
      final old = h.chat.setModel(_a);
      await hold.received!.future;
      final generation = h.client.mux.generation;
      await h.enter('new-mux-ready-snapshot-held');
      expect(identical(h.client.mux.generation, generation), isFalse);
      final before = h.state.model!.toJson();
      hold.finish();
      final oldResult = await old;
      _trace(h, 'new-mux', result: oldResult);
      expect(oldResult, isFalse);
      expect(h.state.model!.toJson(), before);
      expect(h.state.controlReady, isFalse);
      expect(h.state.error, isNull);
    }, hold: hold);
  });

  test('a same-mux follow retry does not cancel a current model choice', () async {
    final hold = ReplyHold()..arm('session/selectModel');
    await scenario((h) async {
      final current = h.chat.setModel(_a);
      await hold.received!.future;
      final generation = h.client.mux.generation;
      await h.enter('same-generation-follow-retry');
      expect(identical(h.client.mux.generation, generation), isTrue);
      hold.finish();
      expect(await current, isTrue);
      expect(h.state.model!.toJson(), _appliedA.toJson());
      expect(h.state.controlReady, isFalse);
      expect(h.state.error, isNull);
      _trace(h, 'same-mux-follow-retry', result: true);
    }, hold: hold);
  });

  for (final failA in [false, true]) {
    test('a later same-host choice survives an older ${failA ? 'failure' : 'success'}', () async {
      final hold = ReplyHold()..arm('session/selectModel');
      await scenario(
        (h) async {
          final old = h.chat.setModel(_a);
          await hold.received!.future;
          // Only A is held; B uses the same live HTTP carrier immediately.
          hold.endpoint = null;
          expect(await h.chat.setModel(_b), isTrue);
          expect(h.state.model!.toJson(), _b.toJson());
          hold.finish();
          final oldResult = await old;
          _trace(h, 'later-choice-$failA', result: oldResult);
          expect(oldResult, isFalse);
          expect(h.state.model!.toJson(), _b.toJson());
          expect(h.state.error, isNull);
          expect(h.methods, ['session/selectModel', 'session/selectModel']);
        },
        hold: hold,
        failA: failA,
      );
    });
  }

  test('the old completion cannot retire a newer model request that is still waiting', () async {
    final hold = ReplyHold()..arm('session/selectModel');
    Completer<void>? oldRelease;
    await scenario((h) async {
      try {
        final old = h.chat.setModel(_a);
        await hold.received!.future;
        oldRelease = hold.release;
        hold.arm('session/selectModel');
        final current = h.chat.setModel(_b);
        await hold.received!.future;
        expect(h.state.model!.toJson(), _b.toJson());
        oldRelease!.complete();
        expect(await old, isFalse);
        expect(h.state.model!.toJson(), _b.toJson());
        hold.finish();
        expect(await current, isTrue);
        expect(h.state.model!.toJson(), _b.toJson());
        expect(h.state.error, isNull);
        _trace(h, 'old-finally-current-still-waiting', result: true);
      } finally {
        if (oldRelease case final release? when !release.isCompleted) release.complete();
        hold.finish();
      }
    }, hold: hold);
  });
}

// A provider invalidation retires model replies before a lazy rebuild.
// Real DshClient and loopback HTTP/WS; no provider read or pump is inserted
// between invalidation and completion in the first two cases.
import 'dart:async';
import 'dart:io';

import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/session_sync_host.dart';

const _previous = ModelSelection(provider: 'review', model: 'prior-success');
const _old = ModelSelection(provider: 'review', model: 'old-request');
const _late = ModelSelection(provider: 'review', model: 'retired-server-value');
const _current = ModelSelection(provider: 'review', model: 'current-request');
const _accepted = ModelSelection(provider: 'review', model: 'current-server-value');

void _models(SyncHarness h, {required bool failOld}) {
  h.host.handlers['session/selectModel'] = (args) {
    final request = args['request']! as Map;
    if (request['model'] == _old.model && failOld) {
      return {
        'ok': false,
        'error': {'code': 'gateway/internal', 'message': 'Retired model error', 'details': {}},
      };
    }
    return {
      'ok': true,
      'value': {
        'selected': switch (request['model']) {
          'old-request' => _late.toJson(),
          'current-request' => _accepted.toJson(),
          _ => request,
        },
      },
    };
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final failOld in [false, true]) {
    test(
      'lazy invalidation rejects old ${failOld ? 'error' : 'success'} before a read and allows a fresh choice',
      () async {
        final hold = ReplyHold();
        await HttpOverrides.runWithHttpOverrides(() async {
          final h = await SyncHarness.start(hold: hold);
          _models(h, failOld: failOld);
          try {
            final notifier = h.chat;
            expect(await notifier.setModel(_previous), isTrue);
            hold.arm('session/selectModel');
            final old = notifier.setModel(_old);
            await hold.received!.future;
            expect(h.state.model!.toJson(), _old.toJson());

            h.container.invalidate(chatProvider('S'));
            hold.finish();
            final oldResult = await old;
            // This is the first provider/state read after invalidation. The
            // stale continuation must not publish a result or an error first.
            final after = h.state;
            syncTrace('r5-model/lazy-${failOld ? 'error' : 'success'}', {
              'oldResult': oldResult,
              'model': after.model?.toJson(),
              'error': after.error,
              'methods': h.methods,
            });
            expect(oldResult, isFalse);
            expect(
              after.model!.toJson(),
              _old.toJson(),
              reason: 'Keep the existing optimistic value; do not apply or roll back an obsolete reply',
            );
            expect(after.error, isNull);
            expect(h.methods, ['session/selectModel', 'session/selectModel']);

            // Retiring A does not disable model changes in the new lifetime.
            expect(await h.chat.setModel(_current), isTrue);
            expect(h.state.model!.toJson(), _accepted.toJson());
            expect(h.state.error, isNull);
            expect(h.methods, ['session/selectModel', 'session/selectModel', 'session/selectModel']);
            syncTrace('r5-model/fresh-after-${failOld ? 'error' : 'success'}', {
              'model': h.state.model?.toJson(),
              'error': h.state.error,
              'methods': h.methods,
            });
          } finally {
            hold.finish();
            await h.close();
          }
        }, RealSyncHttp());
      },
    );

    test('invalidated old ${failOld ? 'error' : 'success'} cannot retire a pending new-lifetime choice', () async {
      final hold = ReplyHold()..arm('session/selectModel');
      await HttpOverrides.runWithHttpOverrides(() async {
        final h = await SyncHarness.start(hold: hold);
        _models(h, failOld: failOld);
        Completer<void>? oldRelease;
        try {
          final old = h.chat.setModel(_old);
          await hold.received!.future;
          oldRelease = hold.release;
          h.container.invalidate(chatProvider('S'));
          // This separate case intentionally starts a new lifetime and a
          // pending choice before releasing A. It does not stand in for the
          // no-read window tested above.
          h.container.read(chatProvider('S'));
          hold.arm('session/selectModel');
          bool? currentResult;
          final current = h.chat.setModel(_current).then((value) {
            currentResult = value;
            return value;
          });
          await hold.received!.future;
          expect(h.state.model!.toJson(), _current.toJson());
          expect(currentResult, isNull);
          oldRelease!.complete();
          expect(await old, isFalse);
          expect(currentResult, isNull);
          expect(h.state.model!.toJson(), _current.toJson());
          expect(h.state.error, isNull);
          hold.finish();
          expect(await current, isTrue, reason: 'The old finally must not clear the new operation');
          expect(h.state.model!.toJson(), _accepted.toJson());
          expect(h.state.error, isNull);
          expect(h.methods, ['session/selectModel', 'session/selectModel']);
          syncTrace('r5-model/pending-new-lifetime-${failOld ? 'error' : 'success'}', {
            'currentResult': currentResult,
            'model': h.state.model?.toJson(),
            'error': h.state.error,
            'methods': h.methods,
          });
        } finally {
          if (oldRelease case final release? when !release.isCompleted) release.complete();
          hold.finish();
          await h.close();
        }
      }, RealSyncHttp());
    });
  }
}

import 'dart:async';

import 'package:dsh_client/dsh_client.dart';
import 'package:test/test.dart';

import 'support/fake_dsh.dart';

void main() {
  final cases = <(String, WatchOptions, bool)>[
    ('default options', const WatchOptions(), false),
    (
      'app sync and activation options',
      WatchOptions(includeSyncEvents: true, activate: true, activationAllowed: () => true),
      false,
    ),
    ('subscription cancelled before client close', const WatchOptions(), true),
  ];

  for (final (label, options, cancelFirst) in cases) {
    test('session watch owns ready/open close gap: $label', () async {
      final host = await FakeDsh.start();
      DshClient? client;
      StreamSubscription<DshEvent>? subscription;
      try {
        final connected = client = await DshClient.connect(baseUri: host.baseUri, token: FakeDsh.token);
        expect(connected.mux.state, DshConnectionState.connected);
        final opened = <String>[];
        host.onOpen = (_, _, endpoint, _) => opened.add(endpoint);
        final parentZone = Zone.current;
        final unhandled = <Object>[];
        final streamErrors = <Object>[];
        final scenarioFinished = Completer<void>();
        (Object, StackTrace)? scenarioError;
        var streamDone = false;
        unawaited(
          runZonedGuarded(
            () async {
              try {
                subscription = connected
                    .watch('session-1', options: options)
                    .listen(
                      (_) {},
                      onError: (Object error) => streamErrors.add(error),
                      onDone: () => streamDone = true,
                    );
                // Only the control cancels first. The regression cases close in
                // the same synchronous turn that suspended watch at mux.ready.
                if (cancelFirst) await subscription!.cancel();
                await connected.close();
              } catch (error, stack) {
                scenarioError = (error, stack);
              } finally {
                scenarioFinished.complete();
              }
            },
            (error, stack) {
              unhandled.add(error);
              parentZone.handleUncaughtError(error, stack);
            },
          ),
        );
        // Await real teardown, never the baseline watch's potentially orphaned
        // done event. Late unhandled errors still belong to the test runner.
        await scenarioFinished.future;
        if (scenarioError case final failure?) Error.throwWithStackTrace(failure.$1, failure.$2);
        expect(unhandled, isEmpty, reason: 'watch failures must belong to the returned stream');
        expect(opened, isEmpty, reason: 'neither cancelled nor closed watches may open session/follow');
        if (cancelFirst) {
          expect(streamErrors, isEmpty);
        } else {
          expect(streamErrors, everyElement(isA<DshClosedException>()));
          expect(streamDone, isTrue, reason: 'client close terminates an uncancelled watch');
        }
      } finally {
        try {
          await subscription?.cancel();
        } finally {
          try {
            await client?.close();
          } finally {
            await host.close();
          }
        }
      }
    });
  }
}

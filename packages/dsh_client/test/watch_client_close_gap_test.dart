import 'dart:async';

import 'package:dsh_client/dsh_client.dart';
import 'package:test/test.dart';

import 'support/fake_dsh.dart';

void main() {
  final watches = <String, Stream<Object?> Function(DshClient)>{
    'workspace/follow': (client) => client.watchWorkspaces(),
    'session/control': (client) => client.watchSessionControl(),
    'job/list': (client) => client.watchJobs('session-1'),
    'job/follow': (client) => client.followJob('session-1', 'job-1'),
  };

  for (final entry in watches.entries) {
    test('${entry.key} owns close between ready and logical open', () async {
      final host = await FakeDsh.start();
      DshClient? client;
      StreamSubscription<Object?>? subscription;
      try {
        final connected = client = await DshClient.connect(baseUri: host.baseUri, token: FakeDsh.token);
        expect(connected.mux.state, DshConnectionState.connected);
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
                subscription = entry
                    .value(connected)
                    .listen(
                      (_) {},
                      onError: (Object error) => streamErrors.add(error),
                      onDone: () => streamDone = true,
                    );
                // onListen is suspended at the already-ready mux Future. Close
                // synchronously retires the mux before that continuation opens.
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
        // Actual WebSocket/mux/carrier teardown is the observation boundary;
        // never await the possibly orphaned watch's done event on the baseline.
        await scenarioFinished.future;
        if (scenarioError case final failure?) Error.throwWithStackTrace(failure.$1, failure.$2);
        expect(unhandled, isEmpty, reason: 'watch failures must belong to the returned stream');
        expect(streamErrors, everyElement(isA<DshClosedException>()));
        expect(streamDone, isTrue, reason: 'closing the client terminates its watch');
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

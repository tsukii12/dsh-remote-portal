import 'dart:async';

/// Gives a consumer one file stream and waits for its reader to stop.
///
/// A socket consumer can cancel its input without awaiting that cancellation.
/// Keep the reader's completion here too, so returning from this function is a
/// barrier for that asynchronous cleanup. The source is only listened to while
/// the consumer is active; retaining the relay does not allow a late file open.
///
/// Relay cancellation reports settlement, not errors: a consumer may discard
/// that Future. This function reports a cancellation error if consumption
/// succeeded; an original consumer error and stack take precedence otherwise.
/// This cannot strengthen the source's own guarantees about native close errors.
Future<void> consumeCompanionFileStream(
  Stream<List<int>> source,
  Future<void> Function(Stream<List<int>>) consume,
) async {
  StreamSubscription<List<int>>? reader;
  Future<void>? cancellation;
  Object? cancellationError;
  StackTrace? cancellationStack;
  var finished = false;

  Future<void> cancelReader() => cancellation ??= () async {
    try {
      await reader?.cancel();
    } catch (error, stack) {
      cancellationError = error;
      cancellationStack = stack;
    }
  }();

  late final StreamController<List<int>> relay;
  relay = StreamController<List<int>>(
    sync: true,
    onListen: () {
      if (finished) return;
      try {
        reader = source.listen(
          relay.add,
          onError: relay.addError,
          onDone: () => unawaited(relay.close()),
        );
      } catch (error, stack) {
        // onListen is guarded by the controller. Deliver a synchronous listen
        // failure as a stream event after listen returns, rather than to Zone.
        scheduleMicrotask(() {
          if (finished) return;
          relay.addError(error, stack);
          unawaited(relay.close());
        });
      }
    },
    onPause: () => reader?.pause(),
    onResume: () => reader?.resume(),
    onCancel: cancelReader,
  );

  try {
    await consume(relay.stream);
  } finally {
    finished = true;
    await cancelReader();
    // An unlistened relay has no reader and its close Future waits for a
    // listener. Closing it is sufficient; do not wait for a late listener.
    unawaited(relay.close());
  }
  final error = cancellationError;
  if (error != null) Error.throwWithStackTrace(error, cancellationStack!);
}

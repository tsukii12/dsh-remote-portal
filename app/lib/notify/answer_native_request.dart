import 'package:dsh_client/dsh_client.dart';

/// Answers a displayed native request only in the generation that presented it.
Future<bool> answerNativeRequest({
  required DshClient client,
  required MuxGeneration generation,
  required String eventId,
  required Map<String, Object?> outcome,
  required bool Function() current,
}) async {
  if (!identical(client.mux.generation, generation) || !current()) return false;
  // The general respondHostEvent API waits for a ready generation and retries
  // a stale clientId. An already displayed native choice must do neither.
  await client.rpc.call(r'$events/result', {'clientId': generation.clientId, 'eventId': eventId, 'outcome': outcome});
  // An accepted old RPC remains a fact, but cannot clear a redelivered request.
  if (identical(client.mux.generation, generation) && current()) {
    client.mux.resolvePendingRequest(eventId);
  }
  return true;
}

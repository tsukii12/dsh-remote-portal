/// Unary Typert Remote calls: `endpoint` + named wire `args`.
///
/// Wire semantics (0.2.0-rc.2), independent of the carrier:
/// * `endpoint` is `<namespace>/<method>` (`$events/result` keeps a literal
///   `$`);
/// * `args` uses the descriptor's wire parameter names, exactly (unknown or
///   missing keys fail with `gateway/arguments-invalid`);
/// * the result is `{ok: true, value?}` or
///   `{ok: false, error: {code, message, details}}`.
///
/// The default [DshHttpCarrier] sends `POST /api/<endpoint>` with a
/// `client-request` envelope; other carriers tunnel the same pair.
library;

import 'carrier.dart';
import 'errors.dart';

/// Outcome of one unary call; [DshRpc.call] unwraps it.
sealed class RpcResult {
  const RpcResult();
}

final class RpcOk extends RpcResult {
  const RpcOk(this.value);

  /// Decoded JSON value; `null` for void results (`{"ok":true}`).
  final Object? value;
}

final class RpcError extends RpcResult {
  const RpcError(this.error);
  final DshRemoteException error;
}

final RegExp _segment = RegExp(r'^[A-Za-z0-9_$.-]+$');

/// Throws [ArgumentError] unless [endpoint] is a well-formed Remote
/// endpoint (`[A-Za-z0-9_$.-]` segments, no `.`/`..`).
void checkRemoteEndpoint(String endpoint) {
  final segments = endpoint.split('/');
  if (segments.isEmpty || segments.any((s) => s.isEmpty || s == '.' || s == '..' || !_segment.hasMatch(s))) {
    throw ArgumentError.value(endpoint, 'endpoint', 'invalid Remote endpoint');
  }
}

class DshRpc {
  DshRpc(this.carrier);

  final DshCarrier carrier;

  /// Calls [endpoint] with named wire [args] and returns the success value.
  ///
  /// Throws [DshRemoteException] for `ok: false`, [DshHttpException] for
  /// HTTP carrier refusals, [DshTransportException] for network failures,
  /// [DshProtocolException] for malformed responses and
  /// [DshCarrierRefusedException] when the carrier needs user action.
  Future<Object?> call(String endpoint, [Map<String, Object?> args = const {}, Duration? timeout]) async {
    final result = await callResult(endpoint, args, timeout: timeout);
    return switch (result) {
      RpcOk(:final value) => value,
      RpcError(:final error) => throw error,
    };
  }

  /// Like [call] but returns Host failures as [RpcError] instead of throwing.
  Future<RpcResult> callResult(String endpoint, Map<String, Object?> args, {Duration? timeout}) async {
    checkRemoteEndpoint(endpoint);
    return carrier.call(endpoint, args, timeout: timeout);
  }
}

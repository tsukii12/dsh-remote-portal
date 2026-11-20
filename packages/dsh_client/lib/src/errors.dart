/// Typed failures raised by the client.
///
/// Callers usually only need two questions answered:
/// * is it a Host decision ([DshRemoteException], carries the Host `code`), or
/// * is it the pipe ([DshHttpException], [DshTransportException],
///   [DshCarrierLostException]), which a retry or a re-login may fix.
library;

import 'json.dart';

sealed class DshException implements Exception {
  const DshException(this.message);
  final String message;

  @override
  String toString() => '$runtimeType: $message';
}

/// The Host answered with `{ok: false, error: {code, message, details}}`, or a
/// logical stream ended with an `error` frame.
///
/// Codes seen on 0.2.0-rc.2 include `gateway/bad-request`,
/// `gateway/arguments-invalid`, `gateway/internal`, `session/not-found`,
/// `session/model-unavailable`, `session/writer-held`, `session/agent-busy`,
/// `credential/rejected` (key shadowed by the launch environment).
final class DshRemoteException extends DshException {
  const DshRemoteException(this.code, String message, [this.details = const {}]) : super(message);

  factory DshRemoteException.fromJson(Object? json) {
    final map = asMapOrEmpty(json);
    return DshRemoteException(
      asString(map['code']) ?? 'unknown',
      asString(map['message']) ?? 'Host returned an error without a message',
      asMapOrEmpty(map['details']),
    );
  }

  final String code;
  final JsonMap details;

  /// Dispatch failures owned by the Gateway rather than a business service.
  bool get isGatewayError => code.startsWith('gateway/');

  @override
  String toString() => 'DshRemoteException($code): $message';
}

/// The HTTP carrier rejected the request before RPC dispatch.
///
/// 401 means the cookie is missing, expired, or bound to another
/// `host:port` (log in again with a fresh launch token); 403 means the
/// Host/Origin trust fence refused the request; 404 an unclaimed endpoint;
/// 415 a non-JSON body.
final class DshHttpException extends DshException {
  const DshHttpException(this.statusCode, String message, {this.body = ''}) : super(message);

  final int statusCode;
  final String body;

  bool get isUnauthorized => statusCode == 401;
  bool get isForbidden => statusCode == 403;

  @override
  String toString() => 'DshHttpException($statusCode): $message';
}

/// Socket, DNS, TLS or timeout failure: the Host may simply be down.
final class DshTransportException extends DshException {
  const DshTransportException(super.message, [this.cause]);
  final Object? cause;
}

/// The Host sent something this client cannot interpret (bad envelope,
/// rpcId mismatch, multipart result, ...).
final class DshProtocolException extends DshException {
  const DshProtocolException(super.message);
}

/// The physical WebSocket carrying a logical stream went away. Retryable:
/// reopen the stream once the mux reports `connected` again.
final class DshCarrierLostException extends DshException {
  const DshCarrierLostException(super.message);
}

/// A carrier refused the connection for a reason that retrying cannot fix
/// without user action: an expired account, a pinned peer identity that
/// changed, the connection taken over by another client, an incompatible
/// Host. [DshMux] stops reconnecting (state `unauthorized`) like on HTTP
/// 401/403; call [DshMux.reconnect] after the user resolved it.
final class DshCarrierRefusedException extends DshException {
  const DshCarrierRefusedException(this.code, String message) : super(message);

  /// Stable reason code, e.g. `ACCOUNT_AUTH_REQUIRED`,
  /// `PEER_IDENTITY_MISMATCH`, `CONNECTION_REPLACED`,
  /// `HARNESS_VERSION_INCOMPATIBLE`.
  final String code;

  @override
  String toString() => 'DshCarrierRefusedException($code): $message';
}

/// The client (or stream) was closed by the caller.
final class DshClosedException extends DshException {
  const DshClosedException([super.message = 'closed']);
}

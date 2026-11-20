import 'errors.dart';
import 'json.dart';
import 'rpc.dart';

/// Shared HTTP envelope contract. Call after the legacy incoming tracer so
/// tracer mutations and exceptions retain their original ordering.
RpcResult readRpcEnvelope(Map<String, Object?>? decoded, String rpcId, String endpoint) {
  if (decoded == null || decoded['type'] != 'server-response') {
    throw DshProtocolException('$endpoint: invalid server-response envelope');
  }
  final echoed = asString(decoded['rpcId']);
  final result = asMap(decoded['result']);
  if (result == null) throw DshProtocolException('$endpoint: server-response without result');
  if (result['ok'] == true) {
    if (echoed != rpcId) {
      throw DshProtocolException('$endpoint: rpcId mismatch (sent $rpcId, got $echoed)');
    }
    return RpcOk(result['value']);
  }
  // Gateway validation failures may echo `invalid-request` instead of rpcId.
  if (result['ok'] == false) return RpcError(DshRemoteException.fromJson(result['error']));
  throw DshProtocolException('$endpoint: result is neither ok nor error');
}

String httpRpcStatusMessage(int status, String endpoint) => switch (status) {
  401 => 'not authenticated for $endpoint (missing/expired cookie or Host mismatch); log in again',
  403 => 'request to $endpoint refused by the Host/Origin trust fence',
  404 => 'endpoint $endpoint is not served by this Host',
  415 => 'Host rejected the content type for $endpoint',
  _ => 'HTTP $status from $endpoint',
};

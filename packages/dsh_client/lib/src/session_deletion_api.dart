/// Permanent deletion is an optional, guarded dsh-go Host capability.
/// Stock/old Hosts and relay-only carriers must never fall back to archive.
library;

import 'dart:convert';

import 'carrier.dart';
import 'errors.dart';
import 'json.dart';
import 'session_api.dart';

const sessionDeletionCapabilityPath = '/dsh-go/v1/sessions/deletion';
const sessionDeletionPath = '/dsh-go/v1/sessions/delete';
const _maxReplyBytes = 8192;

extension SessionDeletionApi on DshClient {
  /// A fresh capability read, not inferred from the release or bridge version.
  ///
  /// It uses the same authenticated GET transport as the rest of the bridge
  /// API (inventory, plugin config); a missing route, a login page or another
  /// plugin's JSON is *not* proof of support.
  Future<bool> supportsSessionDeletion({Duration timeout = const Duration(seconds: 8)}) async {
    final transport = carrier;
    if (transport is! DshHttpCarrier) return false;
    final response = await transport.connection.get(sessionDeletionCapabilityPath, timeout: timeout);
    if (response.statusCode == 404 || response.statusCode == 405 || response.statusCode == 501) return false;
    if (response.statusCode != 200) {
      throw DshHttpException(response.statusCode, 'session deletion capability is unavailable');
    }
    final body = asMap(tryDecodeJson(response.text));
    return response.contentType == 'application/json' && body?['version'] == 1 && body?['supported'] == true;
  }

  /// Deletes exactly one confirmed session; the Host also removes the subagent
  /// sessions that chat started. Never retries or follows redirects:
  /// after a lost response the outcome is unknown, not safe to replay blindly.
  /// The caller must separately hold and recheck its Host/generation authority.
  Future<void> deleteSessionPermanently(String sessionId, {Duration timeout = const Duration(seconds: 30)}) async {
    if (sessionId.isEmpty || sessionId.length > 256 || sessionId.contains(RegExp(r'[\x00-\x1f\x7f]'))) {
      throw ArgumentError.value(sessionId, 'sessionId');
    }
    final transport = carrier;
    if (transport is! DshHttpCarrier) {
      throw const DshRemoteException('unavailable', 'this carrier cannot delete sessions');
    }
    final response = await transport.connection.postBytes(
      sessionDeletionPath,
      utf8.encode(jsonEncode({'sessionId': sessionId})),
      contentType: 'application/json',
      followRedirects: false,
      maxResponseBytes: _maxReplyBytes,
      timeout: timeout,
    );
    final body = response.contentType == 'application/json' ? asMap(tryDecodeJson(response.text)) : null;
    if (response.statusCode != 200) {
      final error = asMap(body?['error']);
      final code = asString(error?['code']);
      if (code != null && code.isNotEmpty && code.length <= 80) {
        throw DshRemoteException(code, 'Host refused session deletion');
      }
      if (response.statusCode == 404 || response.statusCode == 405 || response.statusCode == 501) {
        throw const DshRemoteException('unavailable', 'session deletion is not supported');
      }
      throw DshHttpException(response.statusCode, 'session deletion request failed');
    }
    if (body?['deleted'] != true || body?['sessionId'] != sessionId) {
      throw const DshProtocolException('session deletion reply did not confirm the requested session');
    }
  }
}

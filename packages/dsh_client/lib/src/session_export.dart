/// The official session-log download (`@deepseek-ai/dsh-session-log-export`,
/// the Web client's `/export` and "下载 Session 日志"):
/// `GET /api/session.export?sessionId=…&includeDescendants=true` streams the
/// session tree (the session, its child sessions, their attachments) as one
/// ZIP. It is an HTTP route, so only the HTTP carrier (local engine, SSH
/// tunnel) can fetch it; the relay tunnel cannot.
library;

import 'dart:typed_data';

import 'carrier.dart';
import 'errors.dart';
import 'session_api.dart';

/// The archive's file name, as the Host and the official client name it.
String sessionLogZipName(String sessionId) => 'dsh-session-${sessionId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_')}.zip';

extension DshSessionExport on DshClient {
  /// Whether [exportSessionLog] can reach the Host's download route.
  bool get canExportSessionLog => carrier is DshHttpCarrier;

  /// The ZIP of [sessionId] and its descendants. Throws
  /// `session-export/unsupported` over the relay tunnel and
  /// `session-export/http-<status>` when the Host refuses.
  Future<Uint8List> exportSessionLog(String sessionId) async {
    final carrier = this.carrier;
    if (carrier is! DshHttpCarrier) {
      throw DshRemoteException(
        'session-export/unsupported',
        'The session-log download is an HTTP route; this connection cannot fetch it.',
        {'sessionId': sessionId},
      );
    }
    final response = await carrier.connection.get(
      '/api/session.export',
      query: {'sessionId': sessionId, 'includeDescendants': 'true'},
      timeout: const Duration(minutes: 5),
    );
    if (response.statusCode == 200) return response.body;
    throw DshRemoteException(
      'session-export/http-${response.statusCode}',
      'session.export: HTTP ${response.statusCode} ${response.text}'.trim(),
      {'sessionId': sessionId},
    );
  }
}

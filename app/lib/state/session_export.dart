// The official session-log download (`/export`, "下载 Session 日志") for the
// app: the Host's ZIP of a conversation, handed to the share sheet or the
// phone's Downloads instead of a browser download.

import 'dart:io';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../l10n/l10n.dart';
import 'artifacts.dart';
import 'connection_state.dart';

class SessionLogExporter {
  SessionLogExporter({
    required this.connection,
    required this.channel,
    Future<void> Function(ShareParams params)? share,
    Future<Directory> Function()? cacheRoot,
  }) : _share = share ?? _systemShare,
       _cacheRoot = cacheRoot ?? getTemporaryDirectory;

  final HostConnection? connection;
  final FilesChannel channel;
  final Future<void> Function(ShareParams params) _share;
  final Future<Directory> Function() _cacheRoot;

  static const mime = 'application/zip';

  static Future<void> _systemShare(ShareParams params) async {
    await SharePlus.instance.share(params);
  }

  /// False over the relay tunnel: the download is an HTTP route.
  bool get supported => connection?.client.canExportSessionLog ?? false;

  /// The system share sheet with this export's own archive. share_plus gives
  /// data-backed files unique temporary paths; its result is not a receipt
  /// that the native worker has finished reading the source.
  Future<void> share(String sessionId) async {
    final conn = connection;
    if (conn == null) throw const DshTransportException('offline');
    final bytes = await conn.client.exportSessionLog(sessionId);
    final name = sessionLogZipName(sessionId);
    await _share(
      ShareParams(
        files: [XFile.fromData(bytes, mimeType: mime, name: name)],
        fileNameOverrides: [name],
      ),
    );
  }

  /// Copies the archive into the phone's Downloads; returns where.
  Future<String> saveToDownloads(String sessionId) async {
    final conn = connection;
    if (conn == null) throw const DshTransportException('offline');
    final bytes = await conn.client.exportSessionLog(sessionId);
    final root = await _cacheRoot();
    final exports = await Directory('${root.path}/exports').create(recursive: true);
    // The page can be closed and reopened while the native worker still reads
    // its source. Each save owns an immutable path until that worker replies.
    final operation = await exports.createTemp('save-');
    try {
      final name = sessionLogZipName(sessionId);
      final file = File('${operation.path}/$name');
      await file.writeAsBytes(bytes, flush: true);
      return await channel.saveToDownloads(file.path, name: name, mime: mime);
    } finally {
      // FilesPlugin replies after copying (or reporting failure). Cleanup must
      // neither turn a completed save into failure nor mask its original error.
      try {
        await operation.delete(recursive: true);
      } catch (_) {
        // An undeletable temporary directory remains in the app cache.
      }
    }
  }
}

/// What went wrong, in words.
String sessionExportErrorText(Object error) {
  final code = switch (error) {
    DshRemoteException(:final code) => code,
    PlatformException(:final code) => code,
    DshTransportException() || DshCarrierLostException() || DshClosedException() => 'offline',
    _ => '',
  };
  return switch (code) {
    'session-export/unsupported' => appL10n.stateExportRelayUnsupported,
    'session-export/http-404' => appL10n.stateExportChatMissing,
    'permission' => appL10n.stateStoragePermission,
    'offline' => appL10n.commonEngineUnreachable,
    _ when code.startsWith('session-export/http-') => appL10n.stateExportFailed,
    _ => appL10n.stateExportFailed,
  };
}

final sessionLogExporterProvider = Provider<SessionLogExporter>(
  (ref) => SessionLogExporter(
    connection: ref.watch(activeConnectionProvider).value,
    channel: ref.watch(filesChannelProvider),
  ),
);

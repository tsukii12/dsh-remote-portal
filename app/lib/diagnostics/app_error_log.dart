import 'dart:async';
import 'dart:collection';
import 'dart:ui';

import 'package:flutter/foundation.dart';

import 'diagnostics_channel.dart';
import 'redact.dart';

enum AppErrorSource { flutter, platform, session }

/// A bounded, already-redacted record from this app process. Persistent evidence
/// retains only its category and source locations, never the error body.
class AppErrorRecord {
  const AppErrorRecord({required this.at, required this.source, required this.message, required this.stack});

  final DateTime at;
  final AppErrorSource source;
  final String message;
  final String stack;

  Map<String, Object?> toJson() => {
    'at': at.toUtc().toIso8601String(),
    'source': source.name,
    'message': message,
    'stack': stack,
  };
}

/// Records before delegating to the existing error handlers. Collection is
/// synchronous and in memory; content-free persistence is queued separately.
/// No connection/provider reads or synchronous IO happen in an error handler.
class AppErrorLog {
  AppErrorLog({DateTime Function()? clock, this._diagnostics = const DiagnosticsChannel()})
    : _clock = clock ?? DateTime.now;

  static const maxRecords = 40;
  static const maxMessageLength = 4000;
  static const maxStackLength = 8000;
  static const _maxInputLength = 16000;

  final DateTime Function() _clock;
  final DiagnosticsChannel _diagnostics;
  final ValueNotifier<int> revision = ValueNotifier(0);
  bool _notificationPending = false;
  bool _notifying = false;
  final Queue<AppErrorRecord> _records = Queue();
  bool _recording = false;

  List<AppErrorRecord> snapshot() => List.unmodifiable(_records);

  void record(AppErrorSource source, Object error, StackTrace stack) {
    // An arbitrary error's toString can itself report an error. Keep that
    // nested report out of this collector while its original handler runs.
    if (_recording) return;
    _recording = true;
    try {
      final record = AppErrorRecord(
        at: _clock(),
        source: source,
        message: _text(error, maxMessageLength),
        stack: _text(stack, maxStackLength),
      );
      if (_records.length == maxRecords) _records.removeFirst();
      _records.addLast(record);
      _changed();
      unawaited(_persist(record, error));
    } catch (_) {
      // Diagnostics must not replace the error being reported with its own.
    } finally {
      _recording = false;
    }
  }

  void _changed() {
    // Coalesce bursts; an error raised by a listener must not recursively notify.
    if (_notificationPending || _notifying) return;
    _notificationPending = true;
    scheduleMicrotask(() {
      _notificationPending = false;
      _notifying = true;
      try {
        revision.value++;
      } finally {
        _notifying = false;
      }
    });
  }

  Future<void> _persist(AppErrorRecord record, Object error) async {
    try {
      final type = error.runtimeType.toString();
      final locations = RegExp(r'\((package:(?:dsh_app|flutter)/[A-Za-z0-9_/.-]{1,120}\.dart:[0-9]{1,7}:[0-9]{1,7})\)');
      final stack = locations.allMatches(record.stack).take(6).map((m) => m[1]!).join('\n');
      await _diagnostics.recordAppError(
        source: record.source.name,
        errorType: diagnosticErrorTypes.contains(type) ? type : 'OtherError',
        stack: stack,
      );
    } catch (_) {
      // Diagnostic IO must never report another app error or alter the original handler.
    }
  }

  static String _text(Object value, int limit) {
    String text;
    try {
      text = value.toString();
    } catch (_) {
      text = '<description unavailable>';
    }
    if (text.length > _maxInputLength) {
      final prefix = text.substring(0, _maxInputLength);
      final end = prefix.lastIndexOf('\n');
      // Do not retain a partial credential at the input boundary.
      text = '${end < 0 ? '' : prefix.substring(0, end + 1)}<text truncated>';
    }
    // A bounded prefix may omit a PEM block's END line. Mask even that
    // incomplete block before the shared diagnostics redactor runs.
    text = text.replaceAll(
      RegExp(r'-----BEGIN [^-\r\n]*PRIVATE KEY-----[\s\S]*?(?:-----END [^-\r\n]*PRIVATE KEY-----|$)'),
      '<private key redacted>',
    );
    // The shared redactor bounds lines before matching known key formats.
    // Omit oversized lines here so that shortening a key cannot prevent its
    // format from being recognised and leave a secret prefix in the record.
    text = text.split('\n').map((line) => line.length > maxLineLength ? '<long line omitted>' : line).join('\n');
    text = redactDiagnostics(text);
    return text.length > limit ? '${text.substring(0, limit - 1)}…' : text;
  }
}

/// Installs once, without introducing a new zone or suppressing the platform
/// embedding's fallback. Existing callback results and exceptions are kept.
class AppErrorCapture {
  AppErrorCapture(this.log);

  final AppErrorLog log;
  FlutterExceptionHandler? _previousFlutter;
  ErrorCallback? _previousPlatform;
  FlutterExceptionHandler? _flutter;
  ErrorCallback? _platform;

  void install() {
    if (_flutter != null) return;
    _previousFlutter = FlutterError.onError;
    _previousPlatform = PlatformDispatcher.instance.onError;
    _flutter = (details) {
      log.record(AppErrorSource.flutter, details.exception, details.stack ?? StackTrace.empty);
      _previousFlutter?.call(details);
    };
    _platform = (error, stack) {
      log.record(AppErrorSource.platform, error, stack);
      return _previousPlatform?.call(error, stack) ?? false;
    };
    FlutterError.onError = _flutter;
    PlatformDispatcher.instance.onError = _platform;
  }

  /// Restores only our own registrations; later integrations keep theirs.
  @visibleForTesting
  void uninstall() {
    if (_flutter == null) return;
    if (identical(FlutterError.onError, _flutter)) FlutterError.onError = _previousFlutter;
    if (identical(PlatformDispatcher.instance.onError, _platform)) {
      PlatformDispatcher.instance.onError = _previousPlatform;
    }
    _flutter = null;
    _platform = null;
  }
}

final appErrorLog = AppErrorLog();
final appErrorCapture = AppErrorCapture(appErrorLog);

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'diagnostics_channel.dart';
import 'system_ime_evidence.dart';

/// App-process memory only; no capture occurs by reading this provider.
class SystemImeDiagnostics extends ChangeNotifier {
  SystemImeDiagnostics(this._channel);

  final DiagnosticsChannel _channel;
  SystemImeEvidence? _evidence;
  bool _collecting = false;
  bool _disposed = false;
  int _generation = 0;

  SystemImeEvidence? get evidence => _evidence;
  bool get collecting => _collecting;

  Future<void> collect({required bool Function() isCurrent}) async {
    if (_disposed || _collecting || !isCurrent()) return;
    final generation = ++_generation;
    _evidence = null;
    _collecting = true;
    notifyListeners();
    SystemImeEvidence result;
    try {
      result = await _channel.collectSystemIme();
    } catch (_) {
      result = SystemImeEvidence.failure('failed', DateTime.now());
    }
    if (_disposed || generation != _generation) return;
    _collecting = false;
    if (isCurrent()) _evidence = result;
    notifyListeners();
  }

  /// Leaving the owner revokes pending consent/results, not successful evidence.
  /// Suppress notification during route teardown; its widget is already leaving.
  void cancelPending({bool notify = true}) {
    if (_disposed) return;
    ++_generation;
    final wasCollecting = _collecting;
    _collecting = false;
    _channel.cancelSystemIme().ignore();
    if (wasCollecting && notify) notifyListeners();
  }

  void clear() {
    if (_disposed) return;
    cancelPending(notify: false);
    _evidence = null;
    notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    cancelPending(notify: false);
    _evidence = null;
    _disposed = true;
    super.dispose();
  }
}

final systemImeDiagnosticsProvider = Provider<SystemImeDiagnostics>((ref) {
  final diagnostics = SystemImeDiagnostics(ref.watch(diagnosticsChannelProvider));
  ref.onDispose(diagnostics.dispose);
  return diagnostics;
});

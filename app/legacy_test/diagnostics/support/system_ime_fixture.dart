import 'package:dsh_app/diagnostics/system_ime_evidence.dart';

final systemImeAt = DateTime.utc(2026, 11, 8, 3);

Map<String, Object?> systemImeReply({DateTime? at, String code = 'ok', int count = 1}) {
  final epoch = (at ?? systemImeAt).millisecondsSinceEpoch;
  return {
    'ok': code == 'ok' || code == 'noEvents',
    'code': code,
    'capturedAt': epoch,
    'source': 'privilegedIme',
    'events': List.generate(count, (i) => <String, Object?>{
      'timestamp': epoch - count + i,
      'event': 'requestHide',
      'fromUser': null,
      'reason': 'HIDE_SOFT_INPUT',
      'origin': 'imeTracker',
    }),
  };
}

SystemImeEvidence systemImeEvidence({String code = 'ok', int count = 1}) =>
    SystemImeEvidence.fromNative(systemImeReply(code: code, count: count), now: systemImeAt);

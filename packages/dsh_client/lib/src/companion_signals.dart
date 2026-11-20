/// Metadata-only v1 signal schema. Decoding is validation, never authorization.
library;

import 'dart:convert';

const companionSignalKinds = <String>{
  'task.terminal',
  'task.approval_waiting',
  'task.approval_cleared',
  'device.power',
  'app.late_use',
  'notification.available',
  'notification.removed',
  'run.result',
};
const _safeMax = 9007199254740991;
final _uuid = RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$');

/// The one process-local monotonic clock used by transport receipts. Consumers
/// with another clock use receipt age, never the remote or UTC timestamp.
final _monotonic = Stopwatch()..start();
int companionMonotonicMs() => _monotonic.elapsedMilliseconds;

bool companionScalarText(String value, {bool controls = false}) {
  for (var i = 0; i < value.length; i++) {
    final u = value.codeUnitAt(i);
    if (u >= 0xd800 && u <= 0xdbff) {
      if (++i >= value.length) return false;
      final low = value.codeUnitAt(i);
      if (low < 0xdc00 || low > 0xdfff) return false;
    } else if ((u >= 0xdc00 && u <= 0xdfff) || (!controls && (u < 32 || (u >= 127 && u <= 159)))) {
      return false;
    }
  }
  return true;
}

bool companionSignalId(Object? value, {int maxBytes = 256}) =>
    value is String && value.isNotEmpty && companionScalarText(value) && utf8.encode(value).length <= maxBytes;
bool companionSignalInteger(Object? value, {int min = 0, int max = _safeMax}) =>
    value is int && value >= min && value <= max;
bool companionSignalUuid(Object? value) => value is String && _uuid.hasMatch(value);
bool _keys(Map<Object?, Object?> value, Iterable<String> keys) =>
    value.length == keys.length && keys.every(value.containsKey);
Map<String, Object?> _map(Object? value) {
  if (value is! Map || value.keys.any((key) => key is! String)) _bad();
  return Map<String, Object?>.from(value);
}

Never _bad() => throw const FormatException('invalid companion signal metadata');

final class CompanionSignalV1 {
  CompanionSignalV1._(
    this.id,
    this.kind,
    Map<String, Object?> source,
    this.observedAt,
    this.freshness,
    Map<String, Object?> payload,
  ) : source = Map.unmodifiable(source),
      payload = Map.unmodifiable(payload);
  final String id;
  final String kind;
  final Map<String, Object?> source;
  final DateTime observedAt;
  final String freshness;
  final Map<String, Object?> payload;
  bool get reconciled => freshness == 'reconciled';
  String? get hostKey => source['hostKey'] as String?;
  String? get sessionId => source['sessionId'] as String?;
  int? get seq => source['seq'] as int?;
  int? get turn => source['turn'] as int?;
  String? get requestId => source['requestId'] as String?;

  factory CompanionSignalV1.fromJson(Object? json) {
    final m = _map(json);
    if (!_keys(m, const ['v', 'id', 'kind', 'source', 'observedAt', 'freshness', 'payload']) ||
        m['v'] != 1 ||
        !companionSignalId(m['id'], maxBytes: 512) ||
        !companionSignalKinds.contains(m['kind']) ||
        !const {'live', 'reconciled'}.contains(m['freshness'])) {
      _bad();
    }
    final stamp = m['observedAt'];
    final at = stamp is String ? DateTime.tryParse(stamp) : null;
    if (at == null || !at.isUtc || stamp != at.toIso8601String()) _bad();
    final s = _map(m['source']);
    final p = _map(m['payload']);
    if (utf8.encode(jsonEncode(p)).length > 1024) _bad();
    final kind = m['kind'] as String;
    if (kind.startsWith('task.') || kind == 'run.result') {
      final extra = kind == 'task.terminal'
          ? ['seq', 'turn']
          : kind == 'run.result'
          ? ['seq', 'turn', 'step', 'callId']
          : ['requestId'];
      if (!_keys(s, ['type', 'hostKey', 'sessionId', ...extra]) ||
          s['type'] != 'dsh' ||
          !companionSignalId(s['hostKey']) ||
          (!(kind == 'task.approval_cleared' && s['sessionId'] == null) && !companionSignalId(s['sessionId']))) {
        _bad();
      }
      if (kind == 'task.terminal') {
        if (!companionSignalInteger(s['seq']) ||
            (s['turn'] != null && !companionSignalInteger(s['turn'], min: 1)) ||
            !_keys(p, const ['phase', 'endKind', 'endSeq', 'turn']) ||
            p['endSeq'] != s['seq'] ||
            p['turn'] != s['turn']) {
          _bad();
        }
        const phases = {
          'completed': 'completed',
          'max-tokens': 'output_limit',
          'aborted': 'stopped',
          'interrupted': 'interrupted',
          'error': 'failed',
          'blocked': 'failed',
          'forked': 'unknown',
          'unknown': 'unknown',
        };
        if (!phases.containsKey(p['endKind']) || phases[p['endKind']] != p['phase']) _bad();
      } else if (kind == 'run.result') {
        _validateRun(s, p);
      } else {
        if (!companionSignalId(s['requestId']) ||
            !_keys(p, const ['requestId', 'openSessionId', 'requestKind']) ||
            p['requestId'] != s['requestId'] ||
            (!(kind == 'task.approval_cleared' && p['openSessionId'] == null) &&
                !companionSignalId(p['openSessionId'])) ||
            !const {'approval', 'question'}.contains(p['requestKind'])) {
          _bad();
        }
      }
    } else if (kind == 'app.late_use') {
      if (!_keys(s, const ['type']) ||
          s['type'] != 'device' ||
          !_keys(p, const ['nightKey', 'utcOffsetMinutes', 'recentInteraction', 'activeMinutesBucket']) ||
          !companionSignalInteger(p['utcOffsetMinutes'], min: -840, max: 840) ||
          p['recentInteraction'] != true ||
          p['activeMinutesBucket'] != '15plus' ||
          p['nightKey'] is! String ||
          !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(p['nightKey'] as String) ||
          DateTime.tryParse('${p['nightKey']}T23:00:00Z')?.toIso8601String().substring(0, 10) != p['nightKey']) {
        _bad();
      }
    } else if (kind == 'device.power') {
      if (!_keys(s, const ['type']) ||
          s['type'] != 'device' ||
          !_keys(p, const ['charging', 'band']) ||
          !const {true, false, 'unknown'}.contains(p['charging']) ||
          !const {'normal', 'low', 'critical', 'unknown'}.contains(p['band'])) {
        _bad();
      }
    } else {
      if (!_keys(s, const ['type']) ||
          s['type'] != 'notification' ||
          !_keys(p, const ['opaqueKey', 'packageId', 'change', 'count']) ||
          !companionSignalId(p['opaqueKey']) ||
          !companionSignalId(p['packageId']) ||
          !companionSignalInteger(p['count'], max: 1000000) ||
          (kind == 'notification.removed'
              ? p['change'] != 'removed'
              : !const {'posted', 'updated'}.contains(p['change']))) {
        _bad();
      }
    }
    return CompanionSignalV1._(m['id'] as String, kind, s, at, m['freshness'] as String, p);
  }

  Map<String, Object?> toJson() => {
    'v': 1,
    'id': id,
    'kind': kind,
    'source': source,
    'observedAt': observedAt.toIso8601String(),
    'freshness': freshness,
    'payload': payload,
  };
  @override
  String toString() => 'CompanionSignalV1($kind)';
}

void _validateRun(Map<String, Object?> s, Map<String, Object?> p) {
  if (!companionSignalId(s['callId']) ||
      !companionSignalInteger(s['turn'], min: 1) ||
      !companionSignalInteger(s['step'], min: 1) ||
      !companionSignalInteger(s['seq']) ||
      !_keys(p, const ['runId', 'runKind', 'result', 'exitCode', 'durationMs', 'passed', 'failed', 'skipped']) ||
      p['runId'] != s['callId'] ||
      !const {'build', 'test', 'command'}.contains(p['runKind']) ||
      !const {'succeeded', 'failed', 'cancelled', 'not_run', 'unknown'}.contains(p['result']) ||
      (p['exitCode'] != null && !companionSignalInteger(p['exitCode'], min: -2147483648, max: 2147483647)) ||
      (p['durationMs'] != null && !companionSignalInteger(p['durationMs'], max: 604800000)) ||
      p['passed'] != null ||
      p['failed'] != null ||
      p['skipped'] != null ||
      (p['runKind'] == 'command' && const {'succeeded', 'failed'}.contains(p['result'])) ||
      (p['result'] == 'succeeded' && p['exitCode'] != 0) ||
      (p['result'] == 'failed' && (p['exitCode'] == null || p['exitCode'] == 0))) {
    _bad();
  }
}

/// Public wire decoding is useful for conformance fixtures. Only the private
/// receipt created by the actual SSE API can authorize a `run.result`.
final class CompanionRunEnvelope {
  CompanionRunEnvelope._(this.id, this.generation, Map<String, Object?> source, Map<String, Object?> payload)
    : source = Map.unmodifiable(source),
      payload = Map.unmodifiable(payload);
  final String id;
  final String generation;
  final Map<String, Object?> source;
  final Map<String, Object?> payload;
  factory CompanionRunEnvelope.fromJson(Object? json) {
    final m = _map(json);
    if (!_keys(m, const ['v', 'id', 'generation', 'source', 'payload']) ||
        m['v'] != 1 ||
        !companionSignalUuid(m['generation']) ||
        utf8.encode(jsonEncode(m)).length > 1024) {
      _bad();
    }
    final s = _map(m['source']);
    final p = _map(m['payload']);
    if (!_keys(s, const ['sessionId', 'turn', 'step', 'callId', 'seq']) || !companionSignalId(s['sessionId'])) _bad();
    _validateRun(s, p);
    if (m['id'] != companionRunEventId(s['sessionId'] as String, s['callId'] as String, s['seq'] as int)) _bad();
    return CompanionRunEnvelope._(m['id'] as String, m['generation'] as String, s, p);
  }
  CompanionSignalV1 normalize(String hostKey, DateTime receivedAt) => CompanionSignalV1.fromJson({
    'v': 1,
    'id': id,
    'kind': 'run.result',
    'source': {'type': 'dsh', 'hostKey': hostKey, ...source},
    'observedAt': receivedAt.toUtc().toIso8601String(),
    'freshness': 'live',
    'payload': payload,
  });
}

/// SHA-256 of the specified JSON tuple, matching Node's base64url event id.
/// Kept dependency-free for the pure Dart SDK; test vectors include UTF-8.
String companionRunEventId(String sessionId, String callId, int seq) {
  final data = utf8.encode(jsonEncode([sessionId, callId, seq]));
  final bytes = [...data, 128];
  while (bytes.length % 64 != 56) {
    bytes.add(0);
  }
  final bits = data.length * 8;
  for (var i = 7; i >= 0; i--) {
    bytes.add((bits >> (8 * i)) & 255);
  }
  final h = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19];
  const k = [
    0x428a2f98,
    0x71374491,
    0xb5c0fbcf,
    0xe9b5dba5,
    0x3956c25b,
    0x59f111f1,
    0x923f82a4,
    0xab1c5ed5,
    0xd807aa98,
    0x12835b01,
    0x243185be,
    0x550c7dc3,
    0x72be5d74,
    0x80deb1fe,
    0x9bdc06a7,
    0xc19bf174,
    0xe49b69c1,
    0xefbe4786,
    0x0fc19dc6,
    0x240ca1cc,
    0x2de92c6f,
    0x4a7484aa,
    0x5cb0a9dc,
    0x76f988da,
    0x983e5152,
    0xa831c66d,
    0xb00327c8,
    0xbf597fc7,
    0xc6e00bf3,
    0xd5a79147,
    0x06ca6351,
    0x14292967,
    0x27b70a85,
    0x2e1b2138,
    0x4d2c6dfc,
    0x53380d13,
    0x650a7354,
    0x766a0abb,
    0x81c2c92e,
    0x92722c85,
    0xa2bfe8a1,
    0xa81a664b,
    0xc24b8b70,
    0xc76c51a3,
    0xd192e819,
    0xd6990624,
    0xf40e3585,
    0x106aa070,
    0x19a4c116,
    0x1e376c08,
    0x2748774c,
    0x34b0bcb5,
    0x391c0cb3,
    0x4ed8aa4a,
    0x5b9cca4f,
    0x682e6ff3,
    0x748f82ee,
    0x78a5636f,
    0x84c87814,
    0x8cc70208,
    0x90befffa,
    0xa4506ceb,
    0xbef9a3f7,
    0xc67178f2,
  ];
  int r(int v, int n) => ((v >> n) | (v << (32 - n))) & 0xffffffff;
  for (var start = 0; start < bytes.length; start += 64) {
    final w = List<int>.filled(64, 0);
    for (var i = 0; i < 16; i++) {
      final j = start + i * 4;
      w[i] = (bytes[j] << 24) | (bytes[j + 1] << 16) | (bytes[j + 2] << 8) | bytes[j + 3];
    }
    for (var i = 16; i < 64; i++) {
      final x = w[i - 15], y = w[i - 2];
      w[i] = (w[i - 16] + (r(x, 7) ^ r(x, 18) ^ (x >> 3)) + w[i - 7] + (r(y, 17) ^ r(y, 19) ^ (y >> 10))) & 0xffffffff;
    }
    var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], z = h[7];
    for (var i = 0; i < 64; i++) {
      final t1 = (z + (r(e, 6) ^ r(e, 11) ^ r(e, 25)) + ((e & f) ^ ((~e) & g)) + k[i] + w[i]) & 0xffffffff;
      final t2 = ((r(a, 2) ^ r(a, 13) ^ r(a, 22)) + ((a & b) ^ (a & c) ^ (b & c))) & 0xffffffff;
      z = g;
      g = f;
      f = e;
      e = (d + t1) & 0xffffffff;
      d = c;
      c = b;
      b = a;
      a = (t1 + t2) & 0xffffffff;
    }
    final next = [a, b, c, d, e, f, g, z];
    for (var i = 0; i < 8; i++) {
      h[i] = (h[i] + next[i]) & 0xffffffff;
    }
  }
  return base64Url
      .encode([
        for (final n in h)
          for (final shift in [24, 16, 8, 0]) (n >> shift) & 255,
      ])
      .replaceAll('=', '');
}

String terminalPhase(String reason) => switch (reason) {
  'completed' => 'completed',
  'max-tokens' => 'output_limit',
  'aborted' => 'stopped',
  'interrupted' => 'interrupted',
  'error' || 'blocked' => 'failed',
  _ => 'unknown',
};

abstract final class CompanionSignalKind {
  static const terminal = 'task.terminal',
      approvalWaiting = 'task.approval_waiting',
      approvalCleared = 'task.approval_cleared',
      power = 'device.power',
      lateUse = 'app.late_use',
      notificationAvailable = 'notification.available',
      notificationRemoved = 'notification.removed',
      runResult = 'run.result';
}

/// Explicit, Host-scoped automatic recall. No polling, binding, retries, or
/// memory-to-message fallback happens without the caller choosing that action.
library;

import 'dart:convert';

import 'carrier.dart';
import 'companion_api.dart';
import 'connection.dart';
import 'errors.dart';
import 'json.dart';
import 'session_api.dart';

const companionRecallSelector = 'confirmed-recency-v1';
const _recallPath = '$dshGoCompanionPath/recall';
const _maxBytes = 16 * 1024;
const _maxSafe = 9007199254740991;
final _uuid = RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$');

/// Use one consumer id per client owner and a fresh operation id per explicit
/// action. Keep an operation id when reconciling an uncertain result; do not
/// manufacture a new id to silently replay a possibly accepted action.
String newCompanionRecallId() => uuidV4();

class CompanionRecallCapabilities {
  const CompanionRecallCapabilities._({
    required DshClient owner,
    required this.supported,
    required this.reason,
    required this.busy,
    required this.activeBindingId,
  }) : _owner = owner;

  final DshClient _owner;
  final bool supported;
  final String? reason;
  final bool busy;
  final String? activeBindingId;
  String get selectorVersion => companionRecallSelector;
  int get maxItems => 12;
  int get textUtf16Budget => 1200;
}

enum CompanionRecallStatus { ready, retired, unavailable }

/// This envelope contains identity and status only, never memory text.
class CompanionRecallBinding {
  const CompanionRecallBinding._({
    required this.bindingId,
    required this.bridgeEpoch,
    required this.recallEpoch,
    required this.storeId,
    required this.memoryRevision,
    required this.sessionId,
    required this.status,
    required this.reason,
    required this.serverNow,
  });

  final String bindingId;
  final String bridgeEpoch;
  final int recallEpoch;
  final String storeId;
  final int memoryRevision;
  final String sessionId;
  final CompanionRecallStatus status;
  final String? reason;
  final int? serverNow;
  String get selectorVersion => companionRecallSelector;
  bool get isReady => status == CompanionRecallStatus.ready;
}

extension CompanionRecallApi on DshClient {
  /// Null means a relay or an older bridge's unclaimed route. Supported=false
  /// is an explicit capability result, not permission to inject a fallback.
  Future<CompanionRecallCapabilities?> readCompanionRecallCapabilities({
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final transport = carrier;
    if (transport is! DshHttpCarrier) return null;
    final response = await transport.connection.getBounded(
      _recallPath,
      maxBytes: _maxBytes,
      autoUncompress: true,
      timeout: timeout,
    );
    final map = _recallMap(_recallPath, response, allowMissing: true);
    if (map == null) return null;
    final supported = map['supported'];
    final busy = map['busy'];
    final active = map['activeBindingId'];
    if (supported is! bool ||
        busy is! bool ||
        map['selectorVersion'] != companionRecallSelector ||
        map['maxItems'] is! int ||
        map['maxItems'] != 12 ||
        map['textUtf16Budget'] is! int ||
        map['textUtf16Budget'] != 1200 ||
        !map.containsKey('activeBindingId') ||
        !map.containsKey('reason') ||
        (active != null && !_validUuid(active)) ||
        busy != (active != null)) {
      throw const DshProtocolException('invalid recall capabilities');
    }
    return CompanionRecallCapabilities._(
      owner: this,
      supported: supported,
      reason: _reason(map['reason']),
      busy: busy,
      activeBindingId: active as String?,
    );
  }

  /// Call only after explicit consent for this Host and a clean full session.
  /// [consent] must be [companionRecallSelector]; the string is a protocol
  /// declaration, not evidence of a real UI click. No automatic retry or takeover.
  Future<CompanionRecallBinding> bindCompanionRecall(
    CompanionRecallCapabilities host, {
    required String operationId,
    required String storeId,
    required int expectedMemoryRevision,
    required String sessionId,
    required String consumerId,
    required String consent,
    Duration timeout = const Duration(seconds: 8),
  }) async {
    _recallOwner(host);
    if (!host.supported) {
      throw const DshRemoteException(
        'companion/recall-adapter-unavailable',
        'This Host cannot safely enable automatic recall',
      );
    }
    for (final value in [operationId, storeId, consumerId]) {
      _requireUuid(value);
    }
    _requireSession(sessionId);
    if (!_safe(expectedMemoryRevision) || consent != companionRecallSelector) {
      throw ArgumentError('invalid recall revision or consent');
    }
    final map = await _recallPost('bind', {
      'v': 1,
      'operationId': operationId,
      'storeId': storeId,
      'expectedMemoryRevision': expectedMemoryRevision,
      'sessionId': sessionId,
      'consumerId': consumerId,
      'consent': consent,
    }, timeout);
    final binding = _binding(map);
    if (binding.storeId != storeId ||
        binding.sessionId != sessionId ||
        (binding.isReady && binding.memoryRevision != expectedMemoryRevision)) {
      throw const DshProtocolException('recall bind returned a different target');
    }
    // An idempotent replay can return retired; never promote it back to ready.
    return binding;
  }

  /// Fetch with fresh Host capabilities after a new connection. Foreground
  /// polling and presentation-generation checks belong to the App owner.
  Future<CompanionRecallBinding> readCompanionRecallBinding(
    CompanionRecallCapabilities host,
    String bindingId, {
    Duration timeout = const Duration(seconds: 8),
  }) async {
    _recallOwner(host);
    _requireUuid(bindingId);
    final path = '$_recallPath/bindings/$bindingId';
    final transport = carrier as DshHttpCarrier;
    final response = await transport.connection.getBounded(
      path,
      maxBytes: _maxBytes,
      autoUncompress: true,
      timeout: timeout,
    );
    final binding = _binding(_recallMap(path, response)!, requireNow: true);
    if (binding.bindingId != bindingId) throw const DshProtocolException('recall status returned a different binding');
    return binding;
  }

  /// Explicitly retires a binding, including one reported busy by another
  /// client. It does not delete memories or approve/cancel unrelated tasks.
  /// This remains available when supported=false; revocation must not depend
  /// on the currently selected provider being certifiable.
  Future<CompanionRecallBinding> revokeCompanionRecall(
    CompanionRecallCapabilities host, {
    required String operationId,
    required String bindingId,
    Duration timeout = const Duration(seconds: 8),
  }) async {
    _recallOwner(host);
    _requireUuid(operationId);
    _requireUuid(bindingId);
    final binding = _binding(
      await _recallPost('revoke', {
        'v': 1,
        'operationId': operationId,
        'bindingId': bindingId,
        'reason': 'user-off',
      }, timeout),
    );
    if (binding.bindingId != bindingId || binding.status != CompanionRecallStatus.retired) {
      throw const DshProtocolException('recall revocation did not retire the requested binding');
    }
    return binding;
  }

  void _recallOwner(CompanionRecallCapabilities host) {
    if (!identical(host._owner, this) || carrier is! DshHttpCarrier) {
      throw ArgumentError('recall capabilities belong to another client; read this Host first');
    }
  }

  Future<Map<String, Object?>> _recallPost(String operation, Map<String, Object?> body, Duration timeout) async {
    final bytes = utf8.encode(jsonEncode(body));
    if (bytes.length > _maxBytes) throw ArgumentError('recall request exceeds 16384 bytes');
    final path = '$_recallPath/$operation';
    final response = await (carrier as DshHttpCarrier).connection.postBytes(
      path,
      bytes,
      contentType: 'application/json',
      followRedirects: false,
      maxResponseBytes: _maxBytes,
      timeout: timeout,
    );
    return _recallMap(path, response)!;
  }
}

Map<String, Object?>? _recallMap(String path, DshHttpResponse response, {bool allowMissing = false}) {
  Object? decoded;
  try {
    decoded = jsonDecode(utf8.decode(response.body));
  } on FormatException {
    if (response.statusCode == 200) throw const DshProtocolException('recall response is not valid UTF-8 JSON');
  }
  final map = asMap(decoded);
  final error = asMap(map?['error']);
  if (allowMissing &&
      response.statusCode == 404 &&
      (error?.containsKey('code') != true || error?['code'] == 'companion/not-found')) {
    return null;
  }
  if (response.statusCode != 200) throw companionHttpError(path, response);
  if (map == null || map['v'] is! int || map['v'] != 1) {
    throw const DshProtocolException('invalid recall response version');
  }
  return map;
}

CompanionRecallBinding _binding(Map<String, Object?> map, {bool requireNow = false}) {
  final status = switch (map['status']) {
    'ready' => CompanionRecallStatus.ready,
    'retired' => CompanionRecallStatus.retired,
    'unavailable' => CompanionRecallStatus.unavailable,
    _ => null,
  };
  if (status == null ||
      !['bindingId', 'bridgeEpoch', 'storeId'].every((key) => _validUuid(map[key])) ||
      !_safe(map['recallEpoch']) ||
      !_safe(map['memoryRevision']) ||
      !_validSession(map['sessionId']) ||
      map['selectorVersion'] != companionRecallSelector ||
      (requireNow && !_safe(map['serverNow'])) ||
      (map['serverNow'] != null && !_safe(map['serverNow']))) {
    throw const DshProtocolException('invalid recall binding');
  }
  return CompanionRecallBinding._(
    bindingId: map['bindingId'] as String,
    bridgeEpoch: map['bridgeEpoch'] as String,
    recallEpoch: map['recallEpoch'] as int,
    storeId: map['storeId'] as String,
    memoryRevision: map['memoryRevision'] as int,
    sessionId: map['sessionId'] as String,
    status: status,
    reason: _reason(map['reason']),
    serverNow: map['serverNow'] as int?,
  );
}

bool _safe(Object? value) => value is int && value >= 0 && value <= _maxSafe;
bool _validUuid(Object? value) => value is String && value.length == 36 && _uuid.hasMatch(value);
void _requireUuid(String value) {
  if (!_validUuid(value)) throw ArgumentError('recall requires a canonical lower-case UUID');
}

void _requireSession(String value) {
  if (!_validSession(value)) throw ArgumentError('invalid recall sessionId');
}

bool _validSession(Object? value) {
  return value is String && value.isNotEmpty && value.length <= 512 && _scalarText(value) && value.runes.length <= 256;
}

String? _reason(Object? value) {
  if (value == null) return null;
  if (value is! String || value.length > 512 || !_scalarText(value)) {
    throw const DshProtocolException('invalid recall reason');
  }
  return value;
}

bool _scalarText(String value) {
  for (var i = 0; i < value.length; i++) {
    final unit = value.codeUnitAt(i);
    if (unit >= 0xd800 && unit <= 0xdbff) {
      if (++i >= value.length) return false;
      final low = value.codeUnitAt(i);
      if (low < 0xdc00 || low > 0xdfff) return false;
    } else if ((unit >= 0xdc00 && unit <= 0xdfff) || unit < 32 || (unit >= 0x7f && unit <= 0x9f)) {
      return false;
    }
  }
  return true;
}

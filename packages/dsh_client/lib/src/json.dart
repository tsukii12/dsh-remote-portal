/// Tolerant JSON readers shared by the parsers.
///
/// The Host validates everything it receives but the client must never crash
/// on a newer Host that adds fields or event types, so every reader returns
/// `null` instead of throwing on a shape it does not expect.
library;

import 'dart:convert';
import 'dart:math';

typedef JsonMap = Map<String, Object?>;

JsonMap? asMap(Object? value) {
  if (value is Map<String, Object?>) return value;
  if (value is Map) {
    return value.map((key, v) => MapEntry(key.toString(), v));
  }
  return null;
}

JsonMap asMapOrEmpty(Object? value) => asMap(value) ?? const {};

List<Object?>? asList(Object? value) => value is List ? value.cast<Object?>() : null;

List<Object?> asListOrEmpty(Object? value) => asList(value) ?? const [];

String? asString(Object? value) => value is String ? value : null;

bool? asBool(Object? value) => value is bool ? value : null;

int? asInt(Object? value) {
  if (value is int) return value;
  if (value is double && value.isFinite && value == value.truncateToDouble()) {
    return value.toInt();
  }
  return null;
}

num? asNum(Object? value) => value is num ? value : null;

/// Milliseconds since the epoch to a local [DateTime]; `null` when absent.
DateTime? asEpochMs(Object? value) {
  final ms = asInt(value);
  return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
}

/// Reads a list of strings, dropping non-string members.
List<String> asStringList(Object? value) => asListOrEmpty(value).whereType<String>().toList(growable: false);

/// Decodes JSON text; `null` when the text is not JSON.
Object? tryDecodeJson(String text) {
  try {
    return jsonDecode(text);
  } on FormatException {
    return null;
  }
}

final Random _random = Random.secure();

/// RFC 4122 version-4 UUID, used for rpc ids, stream ids and request ids.
String uuidV4() {
  final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

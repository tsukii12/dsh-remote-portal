// The wire form of a share code. A body is compact JSON → raw DEFLATE →
// base64url, with a checksum of the JSON bytes after a dot:
//
//   <base64url(deflate-raw(json))>.<base64url(sha256(json)[0..6])>
//
// The landing page (site/share/) decodes the same string with
// DecompressionStream('deflate-raw') and SubtleCrypto. A `.dshgo` file and a
// Gist hold that string in a small JSON envelope, so there is one decoder.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'share_models.dart';

/// The share code could not be read (truncated, corrupted, not ours).
class ShareDecodeException implements Exception {
  const ShareDecodeException(this.reason);
  final String reason;

  @override
  String toString() => 'ShareDecodeException: $reason';
}

/// Largest decompressed body accepted (a zip-bomb guard; profiles with
/// skills stay far below it).
const maxShareBodyBytes = 1024 * 1024;

/// Largest encoded string accepted.
const maxShareCodeChars = 1024 * 1024;

/// The same two limits for a conversation (`conversation_share.dart`): its
/// text is longer, and a `.dshgo` file of one stays under
/// `maxConversationFileBytes`.
const maxConversationBodyBytes = 16 * 1024 * 1024;
const maxConversationCodeChars = 6 * 1024 * 1024;

String _b64(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');

Uint8List _unb64(String text) {
  if (!RegExp(r'^[A-Za-z0-9_-]*$').hasMatch(text)) throw const ShareDecodeException('not base64url');
  final padded = text.padRight((text.length + 3) ~/ 4 * 4, '=');
  try {
    return base64Url.decode(padded);
  } on FormatException {
    throw const ShareDecodeException('not base64url');
  }
}

/// 8 base64url characters: the first 6 bytes of SHA-256 over [bytes].
String shareChecksum(List<int> bytes) => _b64(sha256.convert(bytes).bytes.sublist(0, 6));

/// The JSON bytes of [payload] (what the checksum covers).
Uint8List shareBodyBytes(SharePayload payload) => utf8.encode(jsonEncode(payload.toJson()));

/// `<data>.<sum>` for [payload].
String encodeShareCode(SharePayload payload) {
  final body = shareBodyBytes(payload);
  final deflated = ZLibEncoder(raw: true, level: 9).convert(body);
  return '${_b64(deflated)}.${shareChecksum(body)}';
}

/// `<data>.<sum>` for any JSON body (a conversation, see
/// `conversation_share.dart`).
String encodeShareJson(Map<String, Object?> json) {
  final body = utf8.encode(jsonEncode(json));
  final deflated = ZLibEncoder(raw: true, level: 9).convert(body);
  return '${_b64(deflated)}.${shareChecksum(body)}';
}

/// Reads `<data>.<sum>`; throws [ShareDecodeException] when the string is
/// damaged and [ShareFormatException] when the body isn't allowed.
SharePayload decodeShareCode(String code) => SharePayload.fromJson(decodeShareJson(code));

/// The checked JSON object inside `<data>.<sum>`, whatever its kind. A
/// conversation may be larger than a plugin or profile: [large] lifts the
/// limits to the conversation ones, and anything else over the usual ones is
/// still refused.
Map<Object?, Object?> decodeShareJson(String code, {bool large = false}) {
  final body = decodeShareBody(
    code,
    maxBytes: large ? maxConversationBodyBytes : maxShareBodyBytes,
    maxChars: large ? maxConversationCodeChars : maxShareCodeChars,
  );
  final Object? json;
  try {
    json = jsonDecode(utf8.decode(body));
  } on FormatException {
    throw const ShareDecodeException('not JSON');
  }
  if (json is! Map) throw const ShareFormatException('body is not an object');
  final small = body.length <= maxShareBodyBytes && code.length <= maxShareCodeChars;
  if (!small && ShareKind.parse(json['kind']) != ShareKind.conversation) {
    throw const ShareDecodeException('body too large');
  }
  return json;
}

/// The checked JSON bytes inside `<data>.<sum>`.
Uint8List decodeShareBody(String code, {int maxBytes = maxShareBodyBytes, int maxChars = maxShareCodeChars}) {
  final text = code.trim();
  if (text.isEmpty || text.length > maxChars) throw const ShareDecodeException('empty or too long');
  final dot = text.indexOf('.');
  if (dot <= 0 || dot != text.lastIndexOf('.')) throw const ShareDecodeException('no checksum');
  final data = _unb64(text.substring(0, dot));
  final sum = text.substring(dot + 1);
  final body = _inflate(data, maxBytes);
  if (shareChecksum(body) != sum) throw const ShareDecodeException('checksum mismatch');
  return body;
}

Uint8List _inflate(Uint8List data, int maxBytes) {
  final out = _LimitedSink(maxBytes);
  try {
    final sink = ZLibDecoder(raw: true).startChunkedConversion(out);
    sink.add(data);
    sink.close();
  } on _TooLarge {
    throw const ShareDecodeException('body too large');
  } on FormatException {
    throw const ShareDecodeException('not deflate');
  } on FileSystemException {
    throw const ShareDecodeException('not deflate');
  } catch (e) {
    // dart:io reports a damaged stream as an internal ZLib error.
    throw ShareDecodeException('not deflate: ${e.runtimeType}');
  }
  return out.bytes;
}

class _TooLarge implements Exception {}

class _LimitedSink implements Sink<List<int>> {
  _LimitedSink(this.limit);

  final int limit;
  final _builder = BytesBuilder(copy: false);

  Uint8List get bytes => _builder.takeBytes();

  @override
  void add(List<int> chunk) {
    if (_builder.length + chunk.length > limit) throw _TooLarge();
    _builder.add(chunk);
  }

  @override
  void close() {}
}

// ── File / Gist envelope ─────────────────────────────────────────────────────

/// MIME type of `.dshgo` files.
const shareFileMime = 'application/vnd.dshgo+json';

/// File extension (without the dot).
const shareFileExtension = 'dshgo';

/// A `.dshgo` file (also the Gist file): readable header, the code inside.
/// A conversation's file is written by `encodeConversationFile`.
String encodeShareFile(SharePayload payload, {String? code}) {
  final name = switch (payload) {
    PluginShare(:final plugin) => plugin.displayTitle,
    ProfileShare(:final name) => name,
  };
  return '${const JsonEncoder.withIndent('  ').convert({'dshgo': shareFormatVersion, 'kind': payload.kind.name, 'name': ?name, 'code': code ?? encodeShareCode(payload)})}\n';
}

/// Reads a `.dshgo` file's text (or a bare share code pasted into one).
SharePayload decodeShareFile(String text) => decodeShareCode(readShareEnvelope(text).code);

/// What a `.dshgo` file holds around its code: the readable header and, for a
/// conversation, its pictures (`assets`, checked by `decodeConversationFile`).
class ShareEnvelope {
  const ShareEnvelope({required this.code, this.kind, this.name, this.assets});

  final String code;

  /// The header's kind; the code's own kind is what counts.
  final ShareKind? kind;
  final String? name;

  /// Asset id → `{type, w, h, data}` as written; null when there are none.
  final Map<Object?, Object?>? assets;
}

/// Reads a `.dshgo` file's envelope (a bare code is an envelope without a
/// header).
ShareEnvelope readShareEnvelope(String text) {
  final trimmed = text.trim();
  if (!trimmed.startsWith('{')) return ShareEnvelope(code: trimmed);
  final Object? json;
  try {
    json = jsonDecode(trimmed);
  } on FormatException {
    throw const ShareDecodeException('not JSON');
  }
  if (json is! Map || json['dshgo'] is! int || json['code'] is! String) {
    throw const ShareDecodeException('not a dsh-go file');
  }
  final assets = json['assets'];
  return ShareEnvelope(
    code: json['code'] as String,
    kind: ShareKind.parse(json['kind']),
    name: json['name'] is String ? json['name'] as String : null,
    assets: assets is Map ? assets : null,
  );
}

// SPDX-FileCopyrightText: 2026 DeepSeek
// SPDX-License-Identifier: MIT
// See THIRD_PARTY_NOTICES.md.

/// Binary Remote results over HTTP (`workspaceFiles/readBytes`,
/// `officeToPdf/render`).
///
/// The Host's Connection (`@deepseek-ai/dsh-client-connection`,
/// `fullResponse`) answers a result carrying byte attachments as
/// `multipart/form-data`: a `metadata` field holding the usual
/// `server-response` envelope, with `null` placeholders where bytes go, plus
/// an `attachments` table `[{path, codec: 'bytes', part}]`; each `part` names
/// one more field with the raw bytes. [decodeBinaryResponse] puts the bytes
/// back as [Uint8List]s, the way the official client's `parseBinaryResponse`
/// (`@deepseek-ai/dsh-client-connection`) does.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'errors.dart';
import 'json.dart';

/// One `multipart/form-data` body split into its fields (name → bytes).
Map<String, Uint8List> parseFormData(Uint8List body, String boundary) {
  final delimiter = ascii.encode('--$boundary');
  final fields = <String, Uint8List>{};
  var at = _indexOf(body, delimiter, 0);
  if (at < 0) throw const DshProtocolException('multipart body without its boundary');
  while (true) {
    var start = at + delimiter.length;
    // `--boundary--` closes the body.
    if (start + 1 < body.length && body[start] == 0x2d && body[start + 1] == 0x2d) break;
    start = _skipLineBreak(body, start);
    final headerEnd = _indexOf(body, const [13, 10, 13, 10], start);
    if (headerEnd < 0) throw const DshProtocolException('multipart part without headers');
    final headers = utf8.decode(body.sublist(start, headerEnd), allowMalformed: true);
    final contentStart = headerEnd + 4;
    final next = _indexOf(body, [13, 10, ...delimiter], contentStart);
    if (next < 0) throw const DshProtocolException('multipart part without an end');
    final name = RegExp(r'''name="([^"]*)"''', caseSensitive: false).firstMatch(headers)?.group(1);
    if (name == null) throw const DshProtocolException('multipart part without a name');
    if (fields.containsKey(name)) throw DshProtocolException('multipart field $name appears twice');
    fields[name] = Uint8List.sublistView(body, contentStart, next);
    at = next + 2;
  }
  return fields;
}

/// The `server-response` envelope of a binary result, its byte placeholders
/// filled in. Throws [DshProtocolException] for anything malformed.
Map<String, Object?> decodeBinaryResponse(Uint8List body, String boundary) {
  final fields = parseFormData(body, boundary);
  final metadata = fields.remove('metadata');
  if (metadata == null) throw const DshProtocolException('binary response without metadata');
  final envelope = asMap(tryDecodeJson(utf8.decode(metadata, allowMalformed: true)));
  final result = asMap(envelope?['result']);
  final attachments = envelope?['attachments'];
  if (envelope == null || result == null || result['ok'] != true || attachments is! List || attachments.isEmpty) {
    throw const DshProtocolException('invalid binary response envelope');
  }
  final root = <String, Object?>{'value': result['value']};
  for (final attachment in attachments) {
    final map = asMap(attachment);
    final part = map?['part'];
    final path = map?['path'];
    if (map == null || map['codec'] != 'bytes' || part is! String || path is! List) {
      throw const DshProtocolException('invalid binary response attachment');
    }
    final bytes = fields.remove(part);
    if (bytes == null) throw DshProtocolException('binary response is missing part $part');
    Object? parent = root;
    Object key = 'value';
    for (final Object? segment in path) {
      final value = _child(parent, key);
      final present =
          (value is List && segment is int && segment >= 0 && segment < value.length) ||
          (value is Map && segment is String && value.containsKey(segment));
      if (!present) throw const DshProtocolException('invalid binary response path');
      parent = value;
      key = segment as Object;
    }
    if (_child(parent, key) != null) throw const DshProtocolException('binary response placeholder is not null');
    switch (parent) {
      case final List<Object?> list:
        list[key as int] = bytes;
      case final Map<Object?, Object?> object:
        object[key] = bytes;
    }
  }
  if (fields.isNotEmpty) throw const DshProtocolException('binary response has unclaimed parts');
  return {
    ...envelope,
    'result': {...result, 'value': root['value']},
  };
}

Object? _child(Object? parent, Object key) => switch (parent) {
  final List<Object?> list when key is int => list[key],
  final Map<Object?, Object?> map => map[key],
  _ => null,
};

int _skipLineBreak(Uint8List body, int at) {
  if (at + 1 < body.length && body[at] == 13 && body[at + 1] == 10) return at + 2;
  if (at < body.length && body[at] == 10) return at + 1;
  return at;
}

int _indexOf(Uint8List haystack, List<int> needle, int from) {
  if (needle.isEmpty) return from;
  final first = needle.first;
  final last = haystack.length - needle.length;
  outer:
  for (var i = from; i <= last; i++) {
    if (haystack[i] != first) continue;
    for (var j = 1; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) continue outer;
    }
    return i;
  }
  return -1;
}

// ST JSONL framing: public/script.js saveChat and src/endpoints/chats.js
// trySaveChat, SillyTavern 1.19.0, commit
// 7e8663cd9c184a550b37238218bdd32c6efc68e9 (AGPL-3.0).
// Branch/swipe interpretation belongs to the tree importer, not this document.
import 'dart:convert';
import 'dart:typed_data';

/// A detached JSONL header and message sequence, without filesystem operations.
///
/// Unknown JSON fields remain in the recursively immutable containers. [fileName]
/// is only a source label; this class neither normalizes it nor opens that path.
/// Numeric values use Dart's JSON [num] representation, not arbitrary precision.
final class StChatDocument {
  factory StChatDocument({
    required String fileName,
    required Map<String, Object?> header,
    required List<Map<String, Object?>> messages,
  }) {
    final copiedHeader = _objectSnapshot(header, 'header');
    final copiedMessages = <Map<String, Object?>>[];
    for (var i = 0; i < messages.length; i++) {
      copiedMessages.add(_objectSnapshot(messages[i], 'messages[$i]'));
    }
    return StChatDocument._(
      fileName,
      copiedHeader,
      List<Map<String, Object?>>.unmodifiable(copiedMessages),
      List<int>.unmodifiable(List<int>.generate(messages.length, (index) => index + 2)),
      1,
    );
  }

  const StChatDocument._(this.fileName, this.header, this.messages, this.messageLines, this.headerLineNumber);

  /// Decodes strict UTF-8 and one JSON object per nonblank physical line.
  ///
  /// Accepts one file-leading BOM, LF, CRLF, CR, and JSON whitespace-only lines.
  /// A malformed nonblank line fails the whole document instead of dropping it.
  /// The first object is the header, even when its fields are unfamiliar.
  factory StChatDocument.decode(String fileName, Uint8List bytes) {
    Map<String, Object?>? header;
    final messages = <Map<String, Object?>>[];
    final messageLines = <int>[];
    var start = _startsWithBom(bytes) ? 3 : 0;
    var lineNumber = 1;
    var headerLineNumber = 1;

    while (start < bytes.length) {
      var end = start;
      while (end < bytes.length && bytes[end] != 10 && bytes[end] != 13) {
        end++;
      }
      final lineBytes = Uint8List.sublistView(bytes, start, end);
      // Utf8Decoder itself consumes a leading BOM. Doing that independently on
      // every line would silently accept/remove a BOM in the middle of a file.
      if (_startsWithBom(lineBytes)) {
        throw StChatFormatException(fileName, lineNumber, 'A BOM is only allowed at the start of the file.');
      }
      final String line;
      try {
        line = utf8.decode(lineBytes, allowMalformed: false);
      } on FormatException {
        throw StChatFormatException(fileName, lineNumber, 'Invalid UTF-8.');
      }

      if (!_blankJsonLine(line)) {
        final Object? decoded;
        try {
          decoded = jsonDecode(line);
        } on FormatException catch (error) {
          throw StChatFormatException(fileName, lineNumber, error.message);
        }
        if (decoded is! Map<String, Object?>) {
          throw StChatFormatException(fileName, lineNumber, 'Expected a JSON object.');
        }
        final Map<String, Object?> object;
        try {
          object = _objectSnapshot(decoded, header == null ? 'header' : 'message');
        } on ArgumentError catch (error) {
          throw StChatFormatException(fileName, lineNumber, '${error.message}');
        }
        if (header == null) {
          header = object;
          headerLineNumber = lineNumber;
        } else {
          messages.add(object);
          messageLines.add(lineNumber);
        }
      }

      start = end;
      if (start < bytes.length) {
        final delimiter = bytes[start++];
        if (delimiter == 13 && start < bytes.length && bytes[start] == 10) {
          start++;
        }
        lineNumber++;
      }
    }

    if (header == null) {
      throw StChatFormatException(fileName, 1, 'The document has no JSON header.');
    }
    return StChatDocument._(
      fileName,
      header,
      List<Map<String, Object?>>.unmodifiable(messages),
      List<int>.unmodifiable(messageLines),
      headerLineNumber,
    );
  }

  final String fileName;
  final Map<String, Object?> header;
  final List<Map<String, Object?>> messages;

  /// Original 1-based physical line of the first JSON object. Documents
  /// constructed from objects use line 1; encoding writes the header first.
  final int headerLineNumber;

  /// Original 1-based physical line for each message, including skipped blanks.
  /// Documents created from objects use the canonical lines 2, 3, ... .
  final List<int> messageLines;

  /// Encodes compact UTF-8 JSON objects joined by LF, without BOM or trailing LF.
  ///
  /// This preserves JSON values, not original whitespace or numeric spelling.
  /// It does not create or replace integrity, main_chat, or any other field.
  Uint8List encode() {
    final output = BytesBuilder(copy: false);
    final encoder = JsonUtf8Encoder();
    output.add(encoder.convert(header));
    for (final message in messages) {
      output.addByte(10);
      output.add(encoder.convert(message));
    }
    return output.takeBytes();
  }
}

/// A structural document error with the source filename and physical line.
/// The source text is not embedded in the diagnostic.
final class StChatFormatException extends FormatException {
  StChatFormatException(this.fileName, this.lineNumber, String detail) : super('$fileName:$lineNumber: $detail');

  final String fileName;
  final int lineNumber;
}

bool _startsWithBom(Uint8List bytes) => bytes.length >= 3 && bytes[0] == 0xef && bytes[1] == 0xbb && bytes[2] == 0xbf;

bool _blankJsonLine(String line) {
  for (final codeUnit in line.codeUnits) {
    if (codeUnit != 32 && codeUnit != 9) {
      return false;
    }
  }
  return true;
}

Map<String, Object?> _objectSnapshot(Map<String, Object?> source, String path) =>
    _jsonSnapshot(source, Set<Object>.identity(), path) as Map<String, Object?>;

Object? _jsonSnapshot(Object? value, Set<Object> ancestors, String path) {
  if (value == null || value is String || value is bool) {
    return value;
  }
  if (value is num) {
    if (!value.isFinite) {
      throw ArgumentError('Non-finite JSON number at $path.');
    }
    return value;
  }
  if (value is List<Object?>) {
    if (!ancestors.add(value)) {
      throw ArgumentError('Cyclic JSON container at $path.');
    }
    try {
      return List<Object?>.unmodifiable([
        for (var i = 0; i < value.length; i++) _jsonSnapshot(value[i], ancestors, '$path[$i]'),
      ]);
    } finally {
      ancestors.remove(value);
    }
  }
  if (value is Map<Object?, Object?>) {
    if (!ancestors.add(value)) {
      throw ArgumentError('Cyclic JSON container at $path.');
    }
    try {
      final result = <String, Object?>{};
      for (final entry in value.entries) {
        final key = entry.key;
        if (key is! String) {
          throw ArgumentError('Non-string JSON object key at $path.');
        }
        result[key] = _jsonSnapshot(entry.value, ancestors, '$path.$key');
      }
      return Map<String, Object?>.unmodifiable(result);
    } finally {
      ancestors.remove(value);
    }
  }
  throw ArgumentError('Non-JSON value at $path (${value.runtimeType}).');
}

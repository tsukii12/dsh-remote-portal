import 'dart:convert';
import 'dart:io';

/// Keeps the exact valid UTF-8 text alongside the parser's normal BOM-stripped
/// input. Both values come from the same read of the authoritative file.
({String text, String rawText}) decodeAuthoringText(List<int> bytes) {
  final text = utf8.decode(bytes);
  final hasBom = bytes.length >= 3 && bytes[0] == 0xef && bytes[1] == 0xbb && bytes[2] == 0xbf;
  return (text: text, rawText: hasBom ? '\uFEFF$text' : text);
}

Future<({String text, String rawText})> readAuthoringText(File file) async {
  final bytes = await file.readAsBytes();
  try {
    return decodeAuthoringText(bytes);
  } on FormatException {
    // Match File.readAsString's decoding boundary; I/O errors already retain
    // their original type and path from readAsBytes above.
    throw FileSystemException("Failed to decode data using encoding 'utf-8'", file.path);
  }
}

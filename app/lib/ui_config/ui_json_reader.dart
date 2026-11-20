// A strict JSON reader for ui.json. `jsonDecode` would do, except that it gives
// no line and column for a mistake, silently keeps the last of two equal keys,
// and cannot tell `1` from `1.0`; the skill's `check.mjs` has a line-for-line
// twin of this reader, so both report the same position and words for the same
// file (test/ui_config/fixtures/).

import '../l10n/l10n.dart';
import 'ui_config_schema.dart';

/// A file that is not strict JSON: where (1-based, UTF-16 columns) and why.
class UiJsonSyntaxError implements Exception {
  const UiJsonSyntaxError(this.line, this.column, this.reason);

  final int line;
  final int column;
  final String reason;

  String get message => appL10n.shellJsonPosition(line, column, reason);

  @override
  String toString() => 'UiJsonSyntaxError($message)';
}

/// What [readUiJson] returns: the value (objects as insertion-ordered maps,
/// integer literals of up to nine digits as `int`, every other number as
/// `double`) and the JSON Pointers of keys that appeared twice in one
/// object (the later value wins, in the first one's place).
class UiJsonDocument {
  const UiJsonDocument(this.value, this.duplicateKeys);

  final Object? value;
  final List<String> duplicateKeys;
}

/// RFC 6901 escaping of one reference token.
String escapePointerToken(String token) => token.replaceAll('~', '~0').replaceAll('/', '~1');

/// Reads [text] as strict JSON (no comments, no trailing commas, double
/// quotes only; a leading BOM is skipped). Throws [UiJsonSyntaxError].
UiJsonDocument readUiJson(String text) {
  final reader = _Reader(text);
  final value = reader.document();
  return UiJsonDocument(value, List.unmodifiable(reader.duplicates));
}

class _Reader {
  _Reader(this.s);

  final String s;
  int i = 0;
  final duplicates = <String>[];

  static const _quote = 0x22, _backslash = 0x5C, _slash = 0x2F, _apostrophe = 0x27;
  static const _openBrace = 0x7B, _closeBrace = 0x7D, _openBracket = 0x5B, _closeBracket = 0x5D;
  static const _comma = 0x2C, _colon = 0x3A, _minus = 0x2D, _plus = 0x2B, _dot = 0x2E;

  Never _fail(int at, String reason) {
    var line = 1;
    var lineStart = 0;
    for (var k = 0; k < at && k < s.length; k++) {
      if (s.codeUnitAt(k) == 0x0A) {
        line++;
        lineStart = k + 1;
      }
    }
    throw UiJsonSyntaxError(line, at - lineStart + 1, reason);
  }

  bool get _end => i >= s.length;
  int get _c => s.codeUnitAt(i);

  void _ws() {
    while (!_end) {
      final c = _c;
      if (c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D) {
        i++;
      } else {
        break;
      }
    }
  }

  static bool _digit(int c) => c >= 0x30 && c <= 0x39;

  static bool _startsValue(int c) =>
      c == _quote ||
      c == _openBrace ||
      c == _openBracket ||
      c == _minus ||
      _digit(c) ||
      c == 0x74 ||
      c == 0x66 ||
      c == 0x6E;

  static bool _identStart(int c) => (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F || c == 0x24;

  Object? document() {
    if (!_end && _c == 0xFEFF) i++;
    _ws();
    if (_end) _fail(i, appL10n.shellJsonEmptyFile);
    final value = _value('', 0);
    _ws();
    if (!_end) _fail(i, appL10n.shellJsonExtraContent);
    return value;
  }

  Object? _value(String pointer, int depth) {
    _ws();
    if (_end) _fail(i, appL10n.shellJsonIncompleteFile);
    final c = _c;
    if (c == _openBrace) return _object(pointer, depth + 1);
    if (c == _openBracket) return _array(pointer, depth + 1);
    if (c == _quote) return _string();
    if (c == _minus || _digit(c)) return _number();
    if (s.startsWith('true', i)) {
      i += 4;
      return true;
    }
    if (s.startsWith('false', i)) {
      i += 5;
      return false;
    }
    if (s.startsWith('null', i)) {
      i += 4;
      return null;
    }
    if (c == _slash) _fail(i, appL10n.shellJsonCommentsUnsupported);
    if (c == _apostrophe) _fail(i, appL10n.shellJsonDoubleQuotes);
    if (c == _closeBrace || c == _closeBracket || c == _comma) _fail(i, appL10n.shellJsonMissingValue);
    _fail(i, appL10n.shellJsonUnknownContent(s[i]));
  }

  Map<String, Object?> _object(String pointer, int depth) {
    if (depth > UiSchema.maxDepth) _fail(i, appL10n.shellJsonTooDeep);
    i++;
    final map = <String, Object?>{};
    _ws();
    if (!_end && _c == _closeBrace) {
      i++;
      return map;
    }
    var comma = -1;
    while (true) {
      _ws();
      if (_end) _fail(i, appL10n.shellJsonIncompleteFile);
      final c = _c;
      if (c != _quote) {
        if (c == _closeBrace && comma >= 0) _fail(comma, appL10n.shellJsonExtraComma);
        if (c == _slash) _fail(i, appL10n.shellJsonCommentsUnsupported);
        if (c == _apostrophe) _fail(i, appL10n.shellJsonDoubleQuotes);
        if (_identStart(c)) _fail(i, appL10n.shellJsonQuotedKey);
        _fail(i, appL10n.shellJsonExpectedKey);
      }
      final key = _string();
      _ws();
      if (_end) _fail(i, appL10n.shellJsonIncompleteFile);
      if (_c != _colon) _fail(i, appL10n.shellJsonMissingColon);
      i++;
      final child = '$pointer/${escapePointerToken(key)}';
      final value = _value(child, depth);
      if (map.containsKey(key)) duplicates.add(child);
      map[key] = value;
      _ws();
      if (_end) _fail(i, appL10n.shellJsonIncompleteFile);
      final next = _c;
      if (next == _comma) {
        comma = i;
        i++;
        continue;
      }
      if (next == _closeBrace) {
        i++;
        return map;
      }
      if (next == _slash) _fail(i, appL10n.shellJsonCommentsUnsupported);
      if (_startsValue(next)) _fail(i, appL10n.shellJsonMissingComma);
      _fail(i, appL10n.shellJsonUnexpectedContent(s[i]));
    }
  }

  List<Object?> _array(String pointer, int depth) {
    if (depth > UiSchema.maxDepth) _fail(i, appL10n.shellJsonTooDeep);
    i++;
    final list = <Object?>[];
    _ws();
    if (!_end && _c == _closeBracket) {
      i++;
      return list;
    }
    var comma = -1;
    while (true) {
      _ws();
      if (!_end && _c == _closeBracket && comma >= 0) _fail(comma, appL10n.shellJsonExtraComma);
      list.add(_value('$pointer/${list.length}', depth));
      _ws();
      if (_end) _fail(i, appL10n.shellJsonIncompleteFile);
      final next = _c;
      if (next == _comma) {
        comma = i;
        i++;
        continue;
      }
      if (next == _closeBracket) {
        i++;
        return list;
      }
      if (next == _slash) _fail(i, appL10n.shellJsonCommentsUnsupported);
      if (_startsValue(next)) _fail(i, appL10n.shellJsonMissingComma);
      _fail(i, appL10n.shellJsonUnexpectedContent(s[i]));
    }
  }

  String _string() {
    final start = i;
    i++;
    final out = StringBuffer();
    while (true) {
      if (_end) _fail(start, appL10n.shellJsonUnterminatedString);
      final c = _c;
      if (c == _quote) {
        i++;
        return out.toString();
      }
      if (c == _backslash) {
        if (i + 1 >= s.length) _fail(start, appL10n.shellJsonUnterminatedString);
        final e = s.codeUnitAt(i + 1);
        switch (e) {
          case _quote:
          case _backslash:
          case _slash:
            out.writeCharCode(e);
          case 0x62:
            out.writeCharCode(0x08);
          case 0x66:
            out.writeCharCode(0x0C);
          case 0x6E:
            out.writeCharCode(0x0A);
          case 0x72:
            out.writeCharCode(0x0D);
          case 0x74:
            out.writeCharCode(0x09);
          case 0x75:
            if (i + 6 > s.length || !RegExp(r'^[0-9A-Fa-f]{4}$').hasMatch(s.substring(i + 2, i + 6))) {
              _fail(i, appL10n.shellJsonBadEscape);
            }
            out.writeCharCode(int.parse(s.substring(i + 2, i + 6), radix: 16));
            i += 4;
          default:
            _fail(i, appL10n.shellJsonBadEscape);
        }
        i += 2;
        continue;
      }
      if (c == 0x0A || c == 0x0D) _fail(i, appL10n.shellJsonStringNewline);
      if (c < 0x20) _fail(i, appL10n.shellJsonControlCharacter);
      out.writeCharCode(c);
      i++;
    }
  }

  num _number() {
    final start = i;
    if (_c == _minus) i++;
    if (_end) _fail(i, appL10n.shellJsonBadNumber);
    if (_c == 0x30) {
      i++;
    } else if (_digit(_c)) {
      while (!_end && _digit(_c)) {
        i++;
      }
    } else {
      _fail(i, appL10n.shellJsonBadNumber);
    }
    var integer = true;
    if (!_end && _c == _dot) {
      integer = false;
      i++;
      if (_end || !_digit(_c)) _fail(i, appL10n.shellJsonBadNumber);
      while (!_end && _digit(_c)) {
        i++;
      }
    }
    if (!_end && (_c == 0x65 || _c == 0x45)) {
      integer = false;
      i++;
      if (!_end && (_c == _plus || _c == _minus)) i++;
      if (_end || !_digit(_c)) _fail(i, appL10n.shellJsonBadNumber);
      while (!_end && _digit(_c)) {
        i++;
      }
    }
    final literal = s.substring(start, i);
    final digits = literal.startsWith('-') ? literal.length - 1 : literal.length;
    if (integer && digits <= 9) return int.parse(literal);
    return double.parse(literal);
  }
}

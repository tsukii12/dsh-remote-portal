part of 'pet_pack_validator.dart';

/// Strict bounded JSON: checks decoded keys before a Map could overwrite them.
/// The returned values still use Dart's own string and number decoder.
Object? decodePetJson(Uint8List bytes, {int maxBytes = petJsonCap}) {
  _require(bytes.length <= maxBytes, 'pack-size');
  // utf8.decode silently removes this marker; Python's JSON parser rejects it.
  _require(!_hasUtf8Bom(bytes), 'json-bom');
  try {
    return _PetJsonReader(utf8.decode(bytes)).read();
  } on FormatException {
    throw const PetValidationException('json-syntax');
  }
}

bool _hasUtf8Bom(Uint8List bytes) => bytes.length >= 3 && bytes[0] == 0xef && bytes[1] == 0xbb && bytes[2] == 0xbf;

void _checkUnicode(String value) {
  for (var i = 0; i < value.length; i++) {
    final c = value.codeUnitAt(i);
    if (c >= 0xd800 && c <= 0xdbff) {
      _require(
        i + 1 < value.length && value.codeUnitAt(i + 1) >= 0xdc00 && value.codeUnitAt(i + 1) <= 0xdfff,
        'json-unicode',
      );
      i++;
    } else {
      _require(c < 0xdc00 || c > 0xdfff, 'json-unicode');
    }
  }
}

void _checkJsonValue(Object? value, int depth) {
  _require(depth <= petJsonDepthCap, 'json-depth');
  switch (value) {
    case num():
      _require(value.isFinite, 'json-number');
    case String():
      _checkUnicode(value);
    case Map():
      for (final e in value.entries) {
        _require(e.key is String, 'json-key');
        _checkJsonValue(e.key, depth + 1);
        _checkJsonValue(e.value, depth + 1);
      }
    case List():
      for (final item in value) {
        _checkJsonValue(item, depth + 1);
      }
    case null || bool():
      break;
    default:
      throw const PetValidationException('json-value');
  }
}

class _PetJsonReader {
  _PetJsonReader(this.text);
  final String text;
  int at = 0;
  static final number = RegExp(r'-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?');

  void whitespace() {
    while (at < text.length &&
        (text.codeUnitAt(at) == 32 ||
            text.codeUnitAt(at) == 9 ||
            text.codeUnitAt(at) == 10 ||
            text.codeUnitAt(at) == 13)) {
      at++;
    }
  }

  bool take(String char) {
    whitespace();
    if (at < text.length && text[at] == char) {
      at++;
      return true;
    }
    return false;
  }

  Object? read() {
    final value = valueAt(0);
    whitespace();
    _require(at == text.length, 'json-syntax');
    return value;
  }

  String string() {
    whitespace();
    _require(at < text.length && text[at] == '"', 'json-syntax');
    final start = at++;
    while (at < text.length) {
      final c = text.codeUnitAt(at++);
      if (c == 34) {
        final result = jsonDecode(text.substring(start, at)) as String;
        _checkUnicode(result);
        return result;
      }
      if (c == 92) at++; // jsonDecode validates this escape, including \u.
    }
    throw const PetValidationException('json-syntax');
  }

  Object? valueAt(int depth) {
    _require(depth <= petJsonDepthCap, 'json-depth');
    whitespace();
    _require(at < text.length, 'json-syntax');
    final c = text[at];
    if (c == '"') return string();
    if (c == '{') {
      at++;
      final map = <String, Object?>{};
      if (take('}')) return map;
      do {
        _require(depth + 1 <= petJsonDepthCap, 'json-depth');
        final key = string();
        _require(!map.containsKey(key), 'json-duplicate-key', key);
        _require(take(':'), 'json-syntax');
        map[key] = valueAt(depth + 1);
      } while (take(','));
      _require(take('}'), 'json-syntax');
      return map;
    }
    if (c == '[') {
      at++;
      final list = <Object?>[];
      if (take(']')) return list;
      do {
        list.add(valueAt(depth + 1));
      } while (take(','));
      _require(take(']'), 'json-syntax');
      return list;
    }
    for (final literal in const {'true': true, 'false': false, 'null': null}.entries) {
      if (text.startsWith(literal.key, at)) {
        at += literal.key.length;
        return literal.value;
      }
    }
    final match = number.matchAsPrefix(text, at);
    _require(match != null, 'json-syntax');
    at = match!.end;
    final result = jsonDecode(match[0]!) as num;
    _require(result.isFinite, 'json-number');
    return result;
  }
}

// Limited default lowercase for world-info plaintext matching.
// Unicode SpecialCasing supplies U+0130 and Final_Sigma; context properties
// come from the runtime. Five UnicodeData ranges add Cherokee, Mtavruli and
// Adlam; other mappings retain the runtime's existing lowercase.
// This is not a complete, version-pinned JavaScript lowercase implementation.
// https://www.unicode.org/Public/17.0.0/ucd/SpecialCasing.txt
// https://www.unicode.org/Public/17.0.0/ucd/UnicodeData.txt
// https://www.unicode.org/versions/Unicode17.0.0/core-spec/chapter-3/#G33992

final _caseIgnorable = RegExp(r'\p{Case_Ignorable}', unicode: true);
final _cased = RegExp(r'\p{Cased}', unicode: true);

enum _CaseContext { ignored, cased, boundary }

String lowercaseWorldInfoPlain(String text) {
  if (!text.contains('\u03a3') && !text.contains('\u0130') && !_hasFamilyUppercase(text)) {
    return text.toLowerCase();
  }

  // Keep original UTF-16 offsets: no encoding, normalization or reconstruction
  // of unpaired surrogates. Context is always read from the original input.
  final boundaries = <int>[0];
  final kinds = <_CaseContext>[];
  var offset = 0;
  while (offset < text.length) {
    final start = offset;
    final first = text.codeUnitAt(offset++);
    if (_highSurrogate(first) && offset < text.length && _lowSurrogate(text.codeUnitAt(offset))) {
      offset++;
    }
    boundaries.add(offset);
    final unpaired = offset == start + 1 && _surrogate(first);
    final token = text.substring(start, offset);
    // These properties overlap (for example U+0345); Case_Ignorable must win.
    kinds.add(
      unpaired
          ? _CaseContext.boundary
          : _caseIgnorable.hasMatch(token)
          ? _CaseContext.ignored
          : _cased.hasMatch(token)
          ? _CaseContext.cased
          : _CaseContext.boundary,
    );
  }

  final rightCased = List<bool>.filled(kinds.length, false);
  var casedAfter = false;
  for (var index = kinds.length - 1; index >= 0; index--) {
    rightCased[index] = casedAfter;
    if (kinds[index] != _CaseContext.ignored) {
      casedAfter = kinds[index] == _CaseContext.cased;
    }
  }

  final output = StringBuffer();
  var casedBefore = false;
  var plainStart = 0;
  for (var index = 0; index < kinds.length; index++) {
    final start = boundaries[index];
    final end = boundaries[index + 1];
    final first = text.codeUnitAt(start);
    final String? replacement;
    if (first == 0x0130) {
      replacement = 'i\u0307';
    } else if (first == 0x03a3) {
      replacement = casedBefore && !rightCased[index] ? '\u03c2' : '\u03c3';
    } else if (end == start + 1 && _surrogate(first)) {
      replacement = text.substring(start, end);
    } else {
      final codePoint = end == start + 1 ? first : _surrogateCodePoint(first, text.codeUnitAt(start + 1));
      final family = _familyLowercase(codePoint);
      replacement = family == null ? null : String.fromCharCode(family);
    }
    if (replacement != null) {
      output.write(text.substring(plainStart, start).toLowerCase());
      output.write(replacement);
      plainStart = end;
    }
    if (kinds[index] != _CaseContext.ignored) {
      casedBefore = kinds[index] == _CaseContext.cased;
    }
  }
  output.write(text.substring(plainStart).toLowerCase());
  return output.toString();
}

bool _hasFamilyUppercase(String text) {
  for (var index = 0; index < text.length; index++) {
    var value = text.codeUnitAt(index);
    if (_highSurrogate(value) && index + 1 < text.length && _lowSurrogate(text.codeUnitAt(index + 1))) {
      value = _surrogateCodePoint(value, text.codeUnitAt(++index));
    }
    if (_familyLowercase(value) != null) {
      return true;
    }
  }
  return false;
}

int? _familyLowercase(int value) {
  if (value >= 0x13a0 && value <= 0x13ef) {
    return value + 0x97d0;
  }
  if (value >= 0x13f0 && value <= 0x13f5) {
    return value + 8;
  }
  if ((value >= 0x1c90 && value <= 0x1cba) || (value >= 0x1cbd && value <= 0x1cbf)) {
    return value - 0xbc0;
  }
  if (value >= 0x1e900 && value <= 0x1e921) {
    return value + 0x22;
  }
  return null;
}

int _surrogateCodePoint(int high, int low) => 0x10000 + ((high - 0xd800) << 10) + low - 0xdc00;

bool _highSurrogate(int value) => value >= 0xd800 && value <= 0xdbff;
bool _lowSurrogate(int value) => value >= 0xdc00 && value <= 0xdfff;
bool _surrogate(int value) => value >= 0xd800 && value <= 0xdfff;

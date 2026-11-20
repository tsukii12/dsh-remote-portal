// ECMAScript String.prototype.trim and StringNumericLiteral use the same
// WhiteSpace and LineTerminator code units. Dart VM String.trim additionally
// removes U+0085 NEL, which JavaScript must retain.
String trimJsWhitespace(String value) {
  var start = 0;
  var end = value.length;
  while (start < end && _isJsWhitespace(value.codeUnitAt(start))) {
    start++;
  }
  while (end > start && _isJsWhitespace(value.codeUnitAt(end - 1))) {
    end--;
  }
  return value.substring(start, end);
}

String trimStartJsWhitespace(String value) {
  var start = 0;
  while (start < value.length && isJsWhitespace(value.codeUnitAt(start))) {
    start++;
  }
  return value.substring(start);
}

String trimEndJsWhitespace(String value) {
  var end = value.length;
  while (end > 0 && isJsWhitespace(value.codeUnitAt(end - 1))) {
    end--;
  }
  return value.substring(0, end);
}

bool _isJsWhitespace(int code) => isJsWhitespace(code);

bool isJsWhitespace(int code) =>
    (code >= 0x0009 && code <= 0x000d) ||
    code == 0x0020 ||
    code == 0x00a0 ||
    code == 0x1680 ||
    (code >= 0x2000 && code <= 0x200a) ||
    code == 0x2028 ||
    code == 0x2029 ||
    code == 0x202f ||
    code == 0x205f ||
    code == 0x3000 ||
    code == 0xfeff;

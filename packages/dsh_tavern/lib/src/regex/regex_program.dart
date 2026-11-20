// ST 1.19 parser semantics: regex/engine.js, utils.js and world-info.js,
// commit 7e8663cd9c184a550b37238218bdd32c6efc68e9 (AGPL-3.0).
import 'regex_types.dart';

/// This recognition scans fixed host syntax only; it never constructs the
/// supplied user pattern. Plain native keywords do not consume a regex slot.
bool isNativeRegexLiteral(String text) => _nativeDelimiter(text) != null;

final class RegexProgram {
  const RegexProgram({required this.compilation, this.regex, this.global = false, this.sticky = false});
  final RegexCompileResult compilation;
  final RegExp? regex;
  final bool global;
  final bool sticky;
}

/// Shared grammar for the synchronous legacy script path and the worker.
/// Call this only inside the protected worker for display and WI operations.
RegexProgram compileRegexProgram(String input, RegexDialect dialect, {bool caseSensitive = true}) {
  var pattern = input;
  var flags = '';
  var fallback = false;
  if (dialect == RegexDialect.script) {
    final parsed = _scriptLiteral.firstMatch(input);
    if (parsed == null) {
      return const RegexProgram(
        compilation: RegexCompileResult(
          status: RegexCompileStatus.incompatible,
          code: 'invalid-pattern',
          message: '无法读取正则模式。',
        ),
      );
    }
    pattern = parsed[2]!;
    flags = parsed[3]!;
    if (flags.isNotEmpty && !_scriptFlags.hasMatch(flags)) {
      // ST historically reinterprets the entire string, including slashes and
      // an unrecognized flag suffix, as a flagless pattern.
      pattern = input;
      flags = '';
      fallback = true;
    }
    if (flags.contains(_unsupportedScriptFlags)) {
      return const RegexProgram(
        compilation: RegexCompileResult(
          status: RegexCompileStatus.incompatible,
          code: 'unsupported-flags',
          message: '该标志组合不能按 ST 正则执行。',
        ),
      );
    }
    caseSensitive = !flags.contains('i');
  } else if (dialect == RegexDialect.nativeKeyword || input.startsWith('/')) {
    final parsed = _nativeLiteral(input);
    if (parsed == null) {
      return RegexProgram(
        compilation: dialect == RegexDialect.nativeKeyword
            ? const RegexCompileResult(
                status: RegexCompileStatus.literalFallback,
                code: 'literal-fallback',
                message: '原生世界书将此值作为普通关键词。',
              )
            : const RegexCompileResult(
                status: RegexCompileStatus.incompatible,
                code: 'invalid-literal',
                message: 'V3 正则字面量格式无效，不能按普通关键词回退。',
              ),
      );
    }
    pattern = parsed.$1;
    flags = parsed.$2;
    caseSensitive = !flags.contains('i');
  }
  try {
    final regex = RegExp(
      pattern,
      caseSensitive: caseSensitive,
      multiLine: flags.contains('m'),
      unicode: flags.contains('u'),
      dotAll: flags.contains('s'),
    );
    return RegexProgram(
      compilation: RegexCompileResult(
        status: RegexCompileStatus.compatible,
        code: fallback ? 'literal-fallback' : null,
        message: fallback ? '按 ST 历史规则把完整字符串作为无标志正则。' : null,
      ),
      regex: regex,
      global: flags.contains('g'),
      sticky: flags.contains('y'),
    );
  } on FormatException {
    return const RegexProgram(
      compilation: RegexCompileResult(
        status: RegexCompileStatus.incompatible,
        code: 'incompatible-pattern',
        message: '当前 Dart 运行时无法编译此正则；保留原文并跳过。',
      ),
    );
  } on ArgumentError {
    return const RegexProgram(
      compilation: RegexCompileResult(
        status: RegexCompileStatus.incompatible,
        code: 'incompatible-pattern',
        message: '当前 Dart 运行时无法编译此正则；保留原文并跳过。',
      ),
    );
  }
}

final _scriptLiteral = RegExp(r'(/?)(.+)\1([a-z]*)', caseSensitive: false);
final _scriptFlags = RegExp(r'^(?!.*?(.).*?\1)[gmixXsuUAJ]+$');
final _unsupportedScriptFlags = RegExp('[xXUAJ]');

(String, String)? _nativeLiteral(String text) {
  final end = _nativeDelimiter(text);
  if (end == null) {
    return null;
  }
  return (text.substring(1, end).replaceFirst(r'\/', '/'), text.substring(end + 1));
}

// Equivalent to the fixed native /^\/([\w\W]+?)\/([gimsuy]*)$/
// recognizer and its duplicate-flag/unescaped-slash guards. The allowed suffix
// has no slash, so only the last slash can be its delimiter. Recognition is
// linear and constructs no user RegExp, even before the caller's rule budget.
int? _nativeDelimiter(String text) {
  if (!text.startsWith('/')) {
    return null;
  }
  final end = text.lastIndexOf('/');
  if (end <= 1) {
    return null;
  }
  final seen = <int>{};
  const allowed = {103, 105, 109, 115, 117, 121};
  for (var index = end + 1; index < text.length; index++) {
    final unit = text.codeUnitAt(index);
    if (!allowed.contains(unit) || !seen.add(unit)) {
      return null;
    }
  }
  for (var index = 1; index < end; index++) {
    if (text.codeUnitAt(index) == 47 && (index == 1 || text.codeUnitAt(index - 1) != 92)) {
      return null;
    }
  }
  return end;
}

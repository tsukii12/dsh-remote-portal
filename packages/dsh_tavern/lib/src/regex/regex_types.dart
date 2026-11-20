/// Host limits for the protected display/keyword path (ADDENDUM-04 T21).
/// Sizes count UTF-8 bytes, while match positions remain UTF-16 offsets.
final class RegexLimits {
  const RegexLimits({
    this.maxRules = 200,
    this.maxInputBytes = 512 * 1024,
    this.maxOutputBytes = 2 * 1024 * 1024,
    this.maxReplacements = 20000,
    this.timeout = const Duration(milliseconds: 1500),
    this.maxCaptureBytes = 2 * 1024 * 1024,
    this.maxPending = 64,
  });

  final int maxRules;
  final int maxInputBytes;
  final int maxOutputBytes;
  final int maxReplacements;
  final Duration timeout;
  final int maxCaptureBytes;
  final int maxPending;
}

enum RegexDialect { script, nativeKeyword, v3Keyword }

/// literalFallback means the native WI parser did not identify a regex and
/// the caller may use its original plain-keyword path. A script's historical
/// whole-string fallback is still compatible, with code=literal-fallback.
enum RegexCompileStatus { compatible, literalFallback, incompatible, skipped }

final class RegexCompileResult {
  const RegexCompileResult({required this.status, this.code, this.message});

  final RegexCompileStatus status;
  final String? code;
  final String? message;
}

/// A skipped regex is indeterminate, never boolean false. In particular it
/// must not become a successful NOT/exclusion condition in a world book.
enum RegexMatchStatus { matched, notMatched, skipped }

final class RegexMatchResult {
  const RegexMatchResult({required this.status, required this.compilation, this.code, this.message});

  final RegexMatchStatus status;
  final RegexCompileResult compilation;
  final String? code;
  final String? message;
}

/// Pure compile/match seam. Each caller owns its per-evaluation rule budget;
/// a shared worker never shares that budget between chats or display calls.
abstract interface class RegexExecutor {
  RegexLimits get limits;

  Future<RegexCompileResult> compile(
    String pattern, {
    RegexDialect dialect = RegexDialect.script,
    bool caseSensitive = true,
  });

  Future<RegexMatchResult> hasMatch(
    String pattern,
    String text, {
    RegexDialect dialect = RegexDialect.script,
    bool caseSensitive = true,
  });
}

final class RegexDisplayWarning {
  const RegexDisplayWarning({
    required this.ruleId,
    required this.ruleName,
    required this.ruleIndex,
    required this.reason,
    required this.message,
  });

  final String ruleId;
  final String ruleName;
  final int ruleIndex;
  final String reason;
  final String message;

  Map<String, Object?> toJson() => {
    'ruleId': ruleId,
    'ruleName': ruleName,
    'ruleIndex': ruleIndex,
    'reason': reason,
    'message': message,
  };
}

final class RegexDisplayResult {
  RegexDisplayResult({
    required this.text,
    Iterable<RegexDisplayWarning> warnings = const [],
    this.replacements = 0,
    this.cancelled = false,
  }) : warnings = List.unmodifiable(warnings);

  final String text;
  final List<RegexDisplayWarning> warnings;
  final int replacements;
  final bool cancelled;
}

/// Counts without allocating an encoded copy and without changing the text.
/// An unpaired surrogate has the same three-byte replacement size as Dart's
/// UTF-8 encoder, but the original code unit remains in the actual string.
/// If [stopAfter] is exceeded, any value greater than that limit suffices.
int regexUtf8Length(String text, {int? stopAfter}) {
  var bytes = 0;
  for (var index = 0; index < text.length; index++) {
    final unit = text.codeUnitAt(index);
    if (unit <= 0x7f) {
      bytes++;
    } else if (unit <= 0x7ff) {
      bytes += 2;
    } else if (unit >= 0xd800 &&
        unit <= 0xdbff &&
        index + 1 < text.length &&
        text.codeUnitAt(index + 1) >= 0xdc00 &&
        text.codeUnitAt(index + 1) <= 0xdfff) {
      bytes += 4;
      index++;
    } else {
      bytes += 3;
    }
    if (stopAfter != null && bytes > stopAfter) {
      return bytes;
    }
  }
  return bytes;
}

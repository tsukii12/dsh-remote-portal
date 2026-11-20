// The masking every line of a diagnostics bundle goes through before it leaves
// the phone.

import '../ui/chat/secret_mask.dart' show findSecrets;
import 'ansi.dart';

/// What a removed value becomes.
const redactionMark = '•••';

/// Longest line kept whole.
const maxLineLength = 2000;

/// The launch-token mask the native side applies to every engine log line
/// (`CrashClassifier.redact`): `token=•••`.
// Singular token names are credentials except explicit counts and pagination cursors.
const _tokenName =
    r'(?!(?:[A-Za-z0-9_.-]*[_.-])?'
    r'(?:(?:max|min|prompt|completion|input|output|next|prev|previous|continuation|page|cursor|total)[_-]?)+'
    r'token(?![A-Za-z0-9_.-]))[A-Za-z0-9_.-]*token';
final _launchToken = RegExp('(?<![A-Za-z0-9_.-])($_tokenName)=[A-Za-z0-9._~%:+/=-]+', caseSensitive: false);

/// `Authorization: Bearer <credential>` (and `Basic`).
final _bearer = RegExp(r'\b(Bearer|Basic)\s+(?!•)[A-Za-z0-9._~+/=-]+', caseSensitive: false);
final _authorizationScheme = RegExp(r'^(?:Bearer|Basic)$', caseSensitive: false);
final _maskedAuthorization = RegExp(r'^(?:Bearer|Basic)\s+•••$', caseSensitive: false);

// ECMAScript whitespace, shared with the Kotlin scanner.
const _space =
    '\u0009\u000A\u000B\u000C\u000D\u0020\u00A0\u1680'
    '\u2000\u2001\u2002\u2003\u2004\u2005\u2006\u2007\u2008\u2009\u200A'
    '\u2028\u2029\u202F\u205F\u3000\uFEFF';
final _inlineSpace = _space.replaceAll('\r', '').replaceAll('\n', '');

final _assignment = RegExp(
  r'''(?<![A-Za-z0-9_])([A-Za-z0-9_.-]*(?:passw(?:or)?d|passphrase|secret|credential|cookie|authorization|api[_-]?key|apikey|access[_-]?key|private[_-]?key|token)[A-Za-z0-9_.-]*)("?[^\S\r\n]*[:=])''',
  caseSensitive: false,
);
// `name=` at the end of a word is base64 padding (`YWJj=`), not an empty next field.
final _nextAssignment = RegExp(r'''[A-Za-z0-9_.-]+"?[^\S\r\n]*(?:=(?![=\s]|$)|:(?=[^\S\r\n]))''');
final _secretName = RegExp(r'passw(?:or)?d|passphrase|secret|credential|cookie|authorization', caseSensitive: false);
// Explicit credential names do not use value length or numeric content as a proxy.
// Use the live log's token-name rule, including its count/cursor exclusions.
final _credentialKey = RegExp(
  r'^(?:(?:.*[_.-])?(?:api[_-]?key|access[_-]?key|private[_-]?key)|' + _tokenName + r')$',
  caseSensitive: false,
);
final _privateKeyBegin = RegExp(r'-----BEGIN [A-Z0-9 ]{0,40}PRIVATE KEY-----');
final _privateKeyEnd = RegExp(r'-----END [A-Z0-9 ]{0,40}PRIVATE KEY-----');

/// Known credential prefixes kept in front of the mark, so a reader still
/// sees which kind of key was there (`sk-•••`).
const _prefixes = [
  'github_pat_',
  'sk_live_',
  'sk_test_',
  'rk_live_',
  'rk_test_',
  'whsec_',
  'glpat-',
  'xoxa-',
  'xoxb-',
  'xoxp-',
  'xoxr-',
  'xoxs-',
  'ghp_',
  'gho_',
  'ghu_',
  'ghs_',
  'ghr_',
  'npm_',
  'hf_',
  'sk-',
  'AIza',
  'AKIA',
  'ASIA',
  'LTAI',
  'AKID',
];

/// [text] with every credential removed:
///
/// - colour escapes stripped;
/// - API-key-shaped strings (the official secret-mask formats: `sk-…`,
///   `AIza…`, `ghp_…`, JWTs, private-key blocks, passwords in URLs) replaced
///   whole, keeping only a known prefix (`sk-•••`) or a key block's
///   BEGIN / END lines;
/// - the launch token, as the engine log already masks it (`token=•••`);
/// - `Bearer …` / `Basic …` credentials and the values of secret-named
///   assignments.
///
/// Unlike the chat's display mask, nothing of a key's own characters stays.
/// Lines longer than [maxLineLength] are cut first (an inlined image in a
/// log line says nothing to a reader, and it keeps the scan short).
String redactDiagnostics(String text) {
  var out = stripAnsi(text);
  if (out.length > maxLineLength) {
    out = out
        .split('\n')
        .map((line) {
          if (line.length <= maxLineLength) return line;
          var end = maxLineLength;
          final before = line.codeUnitAt(end - 1);
          final after = line.codeUnitAt(end);
          // Keep a supplementary character whole at the truncation boundary.
          if (before >= 0xd800 && before <= 0xdbff && after >= 0xdc00 && after <= 0xdfff) {
            end--;
          }
          return '${line.substring(0, end)}…';
        })
        .join('\n');
  }
  final secrets = findSecrets(out);
  if (secrets.isNotEmpty) {
    final buffer = StringBuffer();
    var at = 0;
    for (final secret in secrets) {
      buffer
        ..write(out.substring(at, secret.start))
        ..write(_maskSpan(out.substring(secret.start, secret.end)));
      at = secret.end;
    }
    buffer.write(out.substring(at));
    out = buffer.toString();
  }
  out = out.replaceAllMapped(_launchToken, (m) => '${m[1]}=$redactionMark');
  out = out.replaceAllMapped(_bearer, (m) => '${m[1]} $redactionMark');
  return _redactAssignments(out);
}

// Keep quoted values, including a value cut before its closing quote, in one mask.
String _redactAssignments(String text) {
  final out = StringBuffer();
  var copied = 0;
  var cursor = 0;
  while (true) {
    final match = _assignment.allMatches(text, cursor).firstOrNull;
    if (match == null) break;
    final name = match[1]!;
    final start = match.end;
    var at = start;
    while (at < text.length && _inlineSpace.contains(text[at])) {
      at++;
    }
    final cookieHeader =
        (name.toLowerCase() == 'cookie' || name.toLowerCase() == 'set-cookie') &&
        match[2]!.endsWith(':') &&
        !match[2]!.startsWith('"');
    // An empty assignment must not eat the next field or cross a log line.
    if (!cookieHeader && at > start && _assignmentAt(text, at)) {
      cursor = at;
      continue;
    }
    final quote = !cookieHeader && at < text.length && (text[at] == "'" || text[at] == '"') ? text[at] : null;
    if (quote != null) at++;
    final valueStart = at;
    if (quote != null) {
      while (at < text.length && text[at] != quote && text[at] != '\r' && text[at] != '\n') {
        if (text[at] == r'\') {
          if (at + 1 == text.length || text[at + 1] == '\r' || text[at + 1] == '\n') {
            at++;
            break;
          }
          at++;
        }
        at++;
      }
    } else if (cookieHeader) {
      while (at < text.length && text[at] != '\r' && text[at] != '\n') {
        at++;
      }
    } else {
      final jsonValue =
          match.start > 0 && text[match.start - 1] == '"' && match[2]!.startsWith('"') && match[2]!.endsWith(':');
      while (at < text.length &&
          !_space.contains(text[at]) &&
          !"\"',;&".contains(text[at]) &&
          (!jsonValue || !'}]'.contains(text[at]))) {
        at++;
      }
      final markedEnd = _maskedEnd(text, valueStart);
      final queryToken =
          name.toLowerCase() == 'token' && match.start > 0 && '?&#'.contains(text[match.start - 1]);
      if (markedEnd > valueStart &&
          (_assignmentAt(text, markedEnd) ||
              (queryToken &&
                  markedEnd < at &&
                  (text[markedEnd] == '#' || (text[markedEnd] == ')' && markedEnd + 1 == at))))) {
        at = markedEnd;
      }
    }
    if (quote == null &&
        !cookieHeader &&
        match.start > 0 &&
        text[match.start - 1] == '(' &&
        at > valueStart &&
        text[at - 1] == ')') {
      at--;
    }
    final value = text.substring(valueStart, at);
    final secret = _secretName.hasMatch(name);
    final authorization = name.toLowerCase().endsWith('authorization');
    final alreadyMasked =
        value == redactionMark ||
        (!secret && _maskedEnd(value, 0) == value.length) ||
        (authorization &&
            (_maskedAuthorization.hasMatch(value) || (quote == null && _authorizationScheme.hasMatch(value))));
    if (value.isNotEmpty &&
        !alreadyMasked &&
        (secret ||
            _credentialKey.hasMatch(name) ||
            (!name.toLowerCase().endsWith('token') &&
                value.length >= 8 &&
                value.codeUnits.any((unit) => unit < 0x30 || unit > 0x39)))) {
      out
        ..write(text.substring(copied, valueStart))
        ..write(redactionMark);
      copied = at;
      cursor = quote != null && at < text.length && text[at] == quote ? at + 1 : at;
    } else {
      // A value left readable (a cursor that is a URL) can carry a credential of its own.
      cursor = valueStart;
    }
  }
  return (out..write(text.substring(copied))).toString();
}

// A generic URI scheme is a value, not an empty field followed by an assignment.
bool _assignmentAt(String text, int start) =>
    _nextAssignment.matchAsPrefix(text, start) != null || _assignment.matchAsPrefix(text, start) != null;

int _maskedEnd(String text, int start) {
  if (text.startsWith(redactionMark, start)) return start + redactionMark.length;
  for (final prefix in _prefixes) {
    if (text.startsWith('$prefix$redactionMark', start)) return start + prefix.length + redactionMark.length;
  }
  return start;
}

/// Redacts the log together so private-key blocks retain their line context.
List<String> redactLines(Iterable<String> lines) {
  final source = lines.toList();
  if (source.isEmpty) return source;
  return redactDiagnostics(source.join('\n')).split('\n');
}

/// A JSON-shaped value with every string through [redactDiagnostics]; keys
/// and non-string values unchanged (`"hasApiKey": true` stays readable).
Object? redactJson(Object? value) => switch (value) {
  String() => redactDiagnostics(value),
  Map() => {for (final e in value.entries) '${e.key}': redactJson(e.value)},
  Iterable() => [for (final v in value) redactJson(v)],
  _ => value,
};

String _maskSpan(String secret) {
  if (secret.startsWith('-----BEGIN')) {
    final begin = _privateKeyBegin.firstMatch(secret)?[0];
    if (begin == null) return redactionMark;
    if (secret == begin) return begin;
    if (!secret.contains('\n')) return redactionMark;
    final end = _privateKeyEnd.firstMatch(secret)?[0];
    return '$begin\n$redactionMark${end == null ? '' : '\n$end'}';
  }
  for (final prefix in _prefixes) {
    if (secret.startsWith(prefix)) return '$prefix$redactionMark';
  }
  return redactionMark;
}

// What a shared conversation never carries. Applied to every text that goes
// into the file: the messages, the thinking, tool arguments and output,
// notices.
//
// - Credentials: the chat's own recogniser (`secret_mask.dart`: `sk-…`,
//   `ghp_…`, JWTs, private key blocks, passwords in URLs), Bearer / Basic
//   values in `Authorization:` headers, and values assigned to names like
//   `API_KEY=` / `"token":` that no format catches.
// - Home folders: `/home/<name>`, `/Users/<name>`, `C:\Users\<name>` become
//   `~` (the name is the person's account). `/root` stays: it is every
//   on-device engine's home and says nothing about anyone.
// - The app's private storage (`/data/user/0/<package>/…`) becomes `…`.
// - Pictures in replies (`![alt](…)`) become their alt text: a viewer must
//   not fetch anything, and local paths mean nothing elsewhere.

import '../ui/chat/secret_mask.dart' show maskSecrets;

/// How masked characters are drawn: `•` survives Markdown (a `*` run would
/// turn into emphasis).
const redactMark = '•';

final _home = RegExp(r'(?<![\w.~-])(/home|/Users)/([A-Za-z0-9._-]+)(?=/|\b)');
final _winHome = RegExp(r'(?<![\w])([A-Za-z]):\\Users\\([^\\/\s"<>|:*?]+)', caseSensitive: false);
final _appData = RegExp(r'/data/(?:user/\d+|data)/[A-Za-z0-9._]+(?=/|\b)');

/// `NAME = value` / `"name": "value"` where the name says it is a secret.
final _assignment = RegExp(
  r'''(?<![A-Za-z0-9])((?:[A-Za-z0-9]+[_-])*(?:api[_-]?key|apikey|secret|token|password|passwd|access[_-]?key|private[_-]?key|auth[_-]?token|client[_-]?secret)"?'?)(\s*[:=]\s*["']?)([^\s"',;)}]{6,})''',
  caseSensitive: false,
);

/// A shell variable or a placeholder, not a value (`$TOKEN`, `${KEY}`,
/// `<token>`, `***`).
final _placeholder = RegExp(r'^(?:\$|<|\{|\*|•|%|xxx)', caseSensitive: false);

// Require header context so ordinary prose such as "basic usage" stays readable.
final _authorization = RegExp(
  r'''(\b(?:proxy-)?authorization["']?\s*[:=]\s*["']?(?:Bearer|Basic)\s+)([A-Za-z0-9._~+/=-]+)''',
  caseSensitive: false,
);

/// [text] as it may leave the device.
String redactText(String text) {
  if (text.isEmpty) return text;
  var out = text.replaceAllMapped(_authorization, (m) => '${m[1]}${redactMark * 6}');
  out = maskSecrets(out, mark: redactMark);
  out = out.replaceAllMapped(_assignment, (m) {
    final value = m.group(3)!;
    if (_placeholder.hasMatch(value)) return m.group(0)!;
    final keep = value.length > 12 ? 4 : 0;
    return '${m.group(1)}${m.group(2)}${value.substring(0, keep)}${redactMark * 6}';
  });
  return redactPaths(out);
}

/// Home folders and app storage in [text] replaced (see the file comment).
String redactPaths(String text) {
  if (!text.contains('/') && !text.contains(r'\')) return text;
  return text
      .replaceAllMapped(_home, (_) => '~')
      .replaceAllMapped(_winHome, (_) => '~')
      .replaceAllMapped(_appData, (_) => '…');
}

final _image = RegExp(r'!\[([^\]\n]*)\]\((?:[^()\s]|\([^()\s]*\))+(?:\s+"[^"\n]*")?\)');
final _fence = RegExp(r'^\s{0,3}(`{3,}|~{3,})');

/// A reply's Markdown with pictures as their alt text (`〔alt〕`), outside
/// code blocks.
String markdownWithoutImages(String markdown) {
  if (!markdown.contains('![')) return markdown;
  final out = <String>[];
  String? fence;
  for (final line in markdown.split('\n')) {
    if (fence != null) {
      if (line.trimLeft().startsWith(fence)) fence = null;
      out.add(line);
      continue;
    }
    if (_fence.firstMatch(line) case final open?) {
      fence = open.group(1)!.substring(0, 3);
      out.add(line);
      continue;
    }
    out.add(
      line.replaceAllMapped(_image, (m) {
        final alt = m.group(1)!.trim();
        return alt.isEmpty ? '' : '〔$alt〕';
      }),
    );
  }
  return out.join('\n');
}

/// [value] (a decoded JSON value) with every string redacted and cut to
/// [maxChars].
Object? redactJson(Object? value, {int maxChars = 2000}) => switch (value) {
  final String s => cutText(redactText(s), maxChars).text,
  final List<Object?> list => [for (final v in list.take(200)) redactJson(v, maxChars: maxChars)],
  final Map<Object?, Object?> map => {
    for (final MapEntry(:key, :value) in map.entries.take(200)) '$key': redactJson(value, maxChars: maxChars),
  },
  _ => value,
};

/// [text] at most [max] characters: the start and the end kept, the middle
/// replaced by a `…` line. [omitted] is how many characters went.
({String text, int omitted}) cutText(String text, int max) {
  if (text.length <= max) return (text: text, omitted: 0);
  final head = (max * 0.6).round();
  final tail = max - head;
  var a = head;
  var b = text.length - tail;
  // Don't split a surrogate pair.
  if (a > 0 && _isHigh(text.codeUnitAt(a - 1))) a--;
  if (b < text.length && _isLow(text.codeUnitAt(b))) b++;
  return (text: '${text.substring(0, a)}\n…\n${text.substring(b)}', omitted: b - a);
}

bool _isHigh(int c) => c >= 0xD800 && c <= 0xDBFF;
bool _isLow(int c) => c >= 0xDC00 && c <= 0xDFFF;

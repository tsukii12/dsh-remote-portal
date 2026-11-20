// Discourse emoji names → the system emoji. Posts arrive as cooked HTML with
// `<img class="emoji" alt=":smile:">`; titles and blurbs keep `:smile:` as
// text. Both are shown as the character, like the rest of the app's text (no
// picture per emoji).

import 'emoji_data.g.dart';

Map<String, String>? _table;

Map<String, String> get _emoji => _table ??= {
  for (final entry in emojiData.split(';'))
    if (entry.lastIndexOf(':') case final i when i > 0) entry.substring(0, i): entry.substring(i + 1),
};

/// Skin tone suffixes `:+1:t2:` … `:+1:t6:` → U+1F3FB … U+1F3FF.
const _tones = {'t2': 0x1F3FB, 't3': 0x1F3FC, 't4': 0x1F3FD, 't5': 0x1F3FE, 't6': 0x1F3FF};

/// The emoji for a Discourse name (`smile`, `+1`, `+1:t3`, `:smile:`);
/// null for names it doesn't know (a forum's custom emoji).
String? emojiFor(String name) {
  var key = name.trim();
  if (key.startsWith(':')) key = key.substring(1);
  if (key.endsWith(':')) key = key.substring(0, key.length - 1);
  int? tone;
  final colon = key.lastIndexOf(':');
  if (colon > 0 && _tones.containsKey(key.substring(colon + 1))) {
    tone = _tones[key.substring(colon + 1)];
    key = key.substring(0, colon);
  }
  final code = _emoji[key.toLowerCase()];
  if (code == null) return null;
  final points = [for (final part in code.split('-')) int.tryParse(part, radix: 16) ?? 0x20];
  if (tone != null) {
    // After the first code point: right for single emoji and for the
    // person-led ZWJ sequences Discourse marks as tonable.
    points.insert(1, tone);
    if (points.length > 2 && points[2] == 0xFE0F) points.removeAt(2);
  }
  return String.fromCharCodes(points);
}

final _shortcode = RegExp(r':([a-z0-9_+\-]+)(?::(t[2-6]))?:', caseSensitive: false);

/// [text] with every known `:name:` replaced by its emoji; unknown ones and
/// look-alikes (`10:30:45`) stay as written.
String replaceEmojiShortcodes(String text) {
  if (!text.contains(':')) return text;
  return text.replaceAllMapped(_shortcode, (m) {
    final name = m[2] == null ? m[1]! : '${m[1]}:${m[2]}';
    return emojiFor(name) ?? m[0]!;
  });
}

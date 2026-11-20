// Expression markers (docs/design/roleplay-roadmap.md P1, T16f): presets and
// cards often ask the model to say how she looks — 「[表情:开心]」,
// 「【表情：害羞】」, "[expression: joy]". The marker picks her picture (a
// sprite or her Live2D figure's feeling) ahead of what the words suggest,
// and is never shown as text.

final _marker = RegExp(
  r'[ \t]*[\[【]\s*(?:表情|情绪|expression|emotion)\s*[:：]\s*([^\]】\n]{1,32}?)\s*[\]】]',
  caseSensitive: false,
);

/// The first marker's value in [text], trimmed; null when there is none.
String? tavernMarkerIn(String text) {
  final value = _marker.firstMatch(text)?.group(1)?.trim();
  return value == null || value.isEmpty ? null : value;
}

/// [text] without its markers; a line that was only a marker goes, and
/// paragraphs keep their spacing.
String tavernStripMarkers(String text) {
  if (!_marker.hasMatch(text)) return text;
  return text
      .split('\n')
      .map((line) => (line, line.replaceAll(_marker, '')))
      .where((l) => !(l.$2.trim().isEmpty && l.$1.trim().isNotEmpty))
      .map((l) => l.$2.trimRight())
      .join('\n')
      .replaceAll(RegExp(r'\n{3,}'), '\n\n')
      .trim();
}

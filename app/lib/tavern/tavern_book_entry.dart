/// A lorebook entry as the editor reads and writes it: a card's own book's
/// field names (V2 character_book: keys, secondary_keys, insertion_order,
/// enabled, ST's other fields under extensions). A book in the library may be
/// kept in ST's own world-info shape instead (key, keysecondary, order,
/// disable, position as a number, the rest at the top); these turn one into
/// the other, so the same editor serves both.
library;

/// ST's own entry as the editor's (card-shaped) entry.
Map<String, Object?> tavernNativeToCard(Map<String, Object?> native) => {
  'comment': native['comment'] ?? '',
  'keys': native['key'] ?? const <Object?>[],
  'secondary_keys': native['keysecondary'] ?? const <Object?>[],
  'selective': native['selective'] ?? false,
  'content': native['content'] ?? '',
  'constant': native['constant'] ?? false,
  'enabled': native['disable'] != true,
  'insertion_order': native['order'] ?? 100,
  'position': native['position'] == 0 ? 'before_char' : 'after_char',
  'extensions': {
    for (final MapEntry(key: card, value: own) in _extensionNames.entries)
      if (native.containsKey(own)) card: native[own],
  },
};

/// The editor's changes (or a whole new entry) in ST's own field names. The
/// card's position word goes: the number in extensions says the same.
Map<String, Object?> tavernCardToNative(Map<String, Object?> card) => {
  for (final MapEntry(:key, :value) in card.entries)
    if (_topNames[key] case final own?)
      own: key == 'enabled' ? value != true : value
    else if (key == 'extensions' && value is Map<String, Object?>)
      for (final MapEntry(key: name, value: field) in value.entries) ?_extensionNames[name]: field,
};

/// Card name → ST's own, for the top-level fields ('enabled' is ST's 'disable', turned over).
const _topNames = {
  'comment': 'comment',
  'keys': 'key',
  'secondary_keys': 'keysecondary',
  'selective': 'selective',
  'content': 'content',
  'constant': 'constant',
  'enabled': 'disable',
  'insertion_order': 'order',
};

/// Card extensions → ST's own top-level fields.
const _extensionNames = {
  'position': 'position',
  'depth': 'depth',
  'role': 'role',
  'selectiveLogic': 'selectiveLogic',
  'probability': 'probability',
  'useProbability': 'useProbability',
  'case_sensitive': 'caseSensitive',
  'match_whole_words': 'matchWholeWords',
};

/// [into] with [changes] laid over it: maps one level down merged (as the
/// engine merges a card entry's extensions), everything else replaced.
Map<String, Object?> tavernMergeEntry(Map<String, Object?> into, Map<String, Object?> changes) => {
  ...into,
  for (final MapEntry(:key, :value) in changes.entries)
    key: switch ((into[key], value)) {
      (final Map<String, Object?> was, final Map<String, Object?> now) => {...was, ...now},
      _ => value,
    },
};

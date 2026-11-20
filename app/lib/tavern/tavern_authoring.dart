// 做卡草稿 (Pro 阶段二, STAGE2-IMPLEMENTATION-R3 §6): a card or a book copied
// into a draft, changed there by the player's AI or by hand, and applied to
// the real one only when the player picks which changes go in.

import 'dart:convert';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/l10n.dart';
import 'tavern_provider.dart';
import 'tavern_usage_summary.dart';

/// Every draft, newest first (the engine's order).
final tavernDraftsProvider = FutureProvider.autoDispose<List<TavernAuthoringDraftSummary>>(
  (ref) => ref.watch(tavernProvider).listAuthoringDrafts(),
);

/// [source]'s name as its own JSON has it: a card's name, a book's; the regex
/// library and a nameless preset by what they are.
String tavernDraftSourceName(L10n l10n, TavernAuthoringSource source) {
  final base = source.base;
  final data = base['data'];
  final name = switch (source.target.kind) {
    TavernAuthoringTargetKind.character => data is Map ? data['name'] : base['name'],
    TavernAuthoringTargetKind.lorebook || TavernAuthoringTargetKind.preset => base['name'],
    TavernAuthoringTargetKind.regexLibrary => null,
  };
  if (name is String && name.trim().isNotEmpty) return name.trim();
  return switch (source.target.kind) {
    TavernAuthoringTargetKind.character => l10n.tavernDraftKindCharacter,
    TavernAuthoringTargetKind.lorebook => l10n.tavernLorebook,
    TavernAuthoringTargetKind.regexLibrary => l10n.tavernRegex,
    TavernAuthoringTargetKind.preset => l10n.tavernDraftKindPreset,
  };
}

/// A JSON Pointer's parts, unescaped.
List<String> _pointer(String path) => [
  for (final part in path.split('/').skip(1)) part.replaceAll('~1', '/').replaceAll('~0', '~'),
];

/// Where [path] is, in the words the card and lorebook pages use: 开场白,
/// 世界书 › 第 3 条 › 内容. A place those pages do not name stays a pointer.
String tavernDraftPlace(L10n l10n, String path) {
  final parts = _pointer(path);
  // A card's fields live under data; a book's entries at its root.
  final data = parts.firstOrNull == 'data' ? parts.skip(1).toList() : parts;
  String? entry(List<String> rest) {
    if (rest.isEmpty) return l10n.tavernLorebook;
    final n = int.tryParse(rest.first);
    final which = n == null ? rest.first : l10n.tavernDraftEntry(n + 1);
    final field = rest.length < 2
        ? null
        : switch (rest[1]) {
            'content' => l10n.tavernLorebookFieldContent,
            'keys' || 'key' => l10n.tavernLorebookFieldKeys,
            'secondary_keys' || 'keysecondary' => l10n.tavernLorebookFieldSecondary,
            'comment' || 'name' => l10n.tavernLorebookFieldName,
            'enabled' || 'disable' => l10n.tavernLorebookFieldEnabled,
            'insertion_order' || 'order' => l10n.tavernLorebookFieldOrder,
            'position' => l10n.tavernLorebookFieldPosition,
            final other => other,
          };
    return [which, ?field, ...rest.skip(2)].join(' › ');
  }

  final words = switch (data) {
    ['name'] => l10n.tavernFieldName,
    ['nickname'] => l10n.tavernFieldNickname,
    ['description'] => l10n.tavernFieldDescription,
    ['personality'] => l10n.tavernFieldPersonality,
    ['scenario'] => l10n.tavernFieldScenario,
    ['first_mes'] => l10n.tavernGreeting,
    ['alternate_greetings'] => l10n.tavernDraftGreetings,
    ['alternate_greetings', final i] when int.tryParse(i) != null => l10n.tavernGreetingNumber(int.parse(i) + 2),
    ['mes_example'] => l10n.tavernFieldExamples,
    ['system_prompt'] => l10n.tavernFieldSystemPrompt,
    ['post_history_instructions'] => l10n.tavernFieldPostHistory,
    ['creator_notes'] => l10n.tavernCreatorNotes,
    ['tags'] => l10n.tavernFieldTags,
    ['creator'] => l10n.tavernFieldCreator,
    ['character_version'] => l10n.tavernFieldVersion,
    ['character_book'] => l10n.tavernLorebook,
    ['character_book', 'entries', ...final rest] => '${l10n.tavernLorebook} › ${entry(rest)}',
    ['entries', ...final rest] => entry(rest),
    _ => null,
  };
  return words ?? path;
}

/// What [path] holds in [base]: whether it is there, and its value.
(bool, Object?) tavernDraftValueAt(Map<String, Object?> base, String path) {
  Object? at = base;
  for (final part in _pointer(path)) {
    switch (at) {
      case final Map<String, Object?> map when map.containsKey(part):
        at = map[part];
      case final List<Object?> list:
        final i = int.tryParse(part);
        if (i == null || i < 0 || i >= list.length) return (false, null);
        at = list[i];
      default:
        return (false, null);
    }
  }
  return (true, at);
}

/// What an AI run's requests reported using; short of a request, only what
/// is known, and said to be so.
String tavernDraftUsageText(L10n l10n, TavernUsageSummary usage) => usage.complete
    ? l10n.tavernInspectUsageTotals(usage.prompt.known, usage.cacheHit.known, usage.completion.known)
    : l10n.tavernDraftUsagePartial(usage.prompt.known, usage.completion.known);

/// A value as text for reading: a string as it is, anything else as JSON.
String tavernDraftValueText(Object? value) => switch (value) {
  final String s => s,
  null => 'null',
  _ => const JsonEncoder.withIndent('  ').convert(value),
};

/// [ids] and every change they depend on, however far back.
Set<String> tavernDraftWithDependencies(Iterable<String> ids, List<TavernAuthoringChange> changes) {
  final byId = {for (final c in changes) c.id: c};
  final out = <String>{};
  void add(String id) {
    if (!out.add(id)) return;
    for (final d in byId[id]?.dependsOn ?? const <String>[]) {
      add(d);
    }
  }

  ids.forEach(add);
  return out;
}

/// [ids] and every change that depends on them, however far on.
Set<String> tavernDraftWithDependents(Iterable<String> ids, List<TavernAuthoringChange> changes) {
  final out = {...ids};
  var grew = true;
  while (grew) {
    grew = false;
    for (final c in changes) {
      if (!out.contains(c.id) && c.dependsOn.any(out.contains)) grew = out.add(c.id);
    }
  }
  return out;
}

// 世界书 › 测一下 (docs/design/roleplay-ui §9, engine T16): one line tried
// against the card's own book without a model call. The engine runs the same
// world-info stage a turn would (keywords, secondary keys, regex, budget) and
// says which entries would go into the prompt and why; a row opens that entry
// to edit, and coming back tries the line again.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../tavern/tavern_provider.dart';
import '../features/feature_kit.dart';
import '../providers/provider_widgets.dart';
import '../settings/settings_widgets.dart';
import '../shell/page_frame.dart';
import '../theme/theme.dart';
import 'tavern_lorebook_page.dart';

class TavernLorebookTestPage extends ConsumerStatefulWidget {
  const TavernLorebookTestPage({super.key, required this.characterId});

  final String characterId;

  static Route<void> route(String characterId) =>
      MaterialPageRoute<void>(builder: (_) => TavernLorebookTestPage(characterId: characterId));

  @override
  ConsumerState<TavernLorebookTestPage> createState() => _TavernLorebookTestPageState();
}

class _TavernLorebookTestPageState extends ConsumerState<TavernLorebookTestPage> {
  final _text = TextEditingController();

  /// The line last tried, and what the engine said about it.
  String? _tried;
  Map<String, Object?>? _result;
  bool _busy = false;
  String? _error;

  /// Bumped per try; a slower, older answer is dropped.
  int _ticket = 0;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _test([String? line]) async {
    final text = line ?? _text.text.trim();
    final ticket = ++_ticket;
    final l10n = context.l10n;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await ref.read(tavernProvider).previewCharacterBook(widget.characterId, text);
      if (!mounted || ticket != _ticket) return;
      setState(() {
        _busy = false;
        _tried = text;
        _result = result;
      });
    } on Object catch (e) {
      if (!mounted || ticket != _ticket) return;
      setState(() {
        _busy = false;
        _result = null;
        _error = l10n.tavernLoreTestFailed('$e');
      });
    }
  }

  Future<void> _open(TavernBookEntry entry) async {
    await Navigator.of(context).push(TavernLorebookEntryPage.route(characterId: widget.characterId, entry: entry));
    if (mounted && _tried != null) await _test(_tried);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final dsh = DshColors.of(context);
    final entries = ref.watch(tavernCardBookProvider(widget.characterId)).value?.entries ?? const <TavernBookEntry>[];
    final result = _result;
    final hits = [
      if (result?['activated'] case final List<Object?> list)
        for (final hit in list)
          if (hit is Map<String, Object?>) hit,
    ];
    final note = theme.textTheme.bodySmall?.copyWith(color: dsh.textTertiary, height: 1.5);
    return AppPage.list(
      title: l10n.tavernLoreTestTitle,
      children: [
        SettingsSection(
          footer: Text(l10n.tavernLoreTestNote),
          children: [
            FormFieldGroup(
              children: [
                FormFieldBlock(
                  label: l10n.tavernLoreTestInput,
                  child: TextField(
                    key: const ValueKey('tavern-lore-test-input'),
                    controller: _text,
                    autofocus: true,
                    minLines: 2,
                    maxLines: 6,
                    keyboardType: TextInputType.multiline,
                    decoration: InputDecoration(hintText: l10n.tavernLoreTestHint),
                  ),
                ),
              ],
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Align(
            alignment: Alignment.centerRight,
            child: FilledButton(
              key: const ValueKey('tavern-lore-test-run'),
              onPressed: _busy ? null : () => unawaited(_test()),
              child: Text(l10n.tavernLoreTest),
            ),
          ),
        ),
        if (_busy)
          const QuietSpinner()
        else if (_error case final error?)
          Padding(
            padding: const EdgeInsets.fromLTRB(28, 0, 28, 16),
            child: Text(error, style: theme.textTheme.bodySmall?.copyWith(color: dsh.danger)),
          )
        else if (result != null) ...[
          if (hits.isEmpty)
            Padding(
              key: const ValueKey('tavern-lore-test-none'),
              padding: const EdgeInsets.fromLTRB(28, 0, 28, 16),
              child: Text(l10n.tavernLoreTestNone, style: note),
            )
          else
            SettingsSection(
              key: const ValueKey('tavern-lore-test-hits'),
              title: l10n.tavernLoreTestHits(hits.length),
              children: [
                for (final hit in hits)
                  () {
                    final entry = tavernBookEntryForHit(entries, hit);
                    return _HitRow(
                      key: ValueKey('tavern-lore-hit-${hit['uid']}'),
                      hit: hit,
                      title: entry == null ? null : tavernBookEntryTitle(entry.entry),
                      onOpen: entry == null ? null : () => unawaited(_open(entry)),
                    );
                  }(),
              ],
            ),
          if (result['overflowed'] == true)
            Padding(
              key: const ValueKey('tavern-lore-test-overflow'),
              padding: const EdgeInsets.fromLTRB(28, 0, 28, 16),
              child: Text(l10n.tavernLoreTestOverflow, style: note),
            ),
        ],
      ],
    );
  }
}

/// The entry of the book a hit came from: by the entry's id, which the
/// engine reports as the hit's uid, else by its place in the book.
TavernBookEntry? tavernBookEntryForHit(List<TavernBookEntry> entries, Map<String, Object?> hit) {
  final uid = '${hit['uid']}';
  for (final e in entries) {
    if (e.entry['id'] != null && '${e.entry['id']}' == uid) return e;
  }
  final index = int.tryParse(uid);
  for (final e in entries) {
    if (e.entry['id'] == null && e.index == index) return e;
  }
  return null;
}

/// Why a hit came in, as the reader would say it.
String tavernHitReason(L10n l10n, Map<String, Object?> hit) {
  switch (hit['reason']) {
    case 'constant':
      return l10n.tavernLorebookConstant;
    case 'keywords':
      final keys = [
        if (hit['primaryKey'] case final String key) key,
        if (hit['secondaryMatches'] case final List<Object?> more)
          for (final key in more)
            if (key is String) key,
      ];
      return l10n.tavernLoreReasonKeys(keys.map((k) => '「$k」').join(' + '));
    case 'sticky':
      return l10n.tavernLoreReasonSticky;
    case final String reason when reason.startsWith('decorator'):
      return l10n.tavernLoreReasonDecorator;
    case final String reason:
      return reason;
    default:
      return '';
  }
}

/// Where in the prompt a hit goes, by ST's numbered positions.
String tavernHitPosition(L10n l10n, Map<String, Object?> hit) => switch (hit['position']) {
  0 => l10n.tavernLorebookBeforeChar,
  1 => l10n.tavernLorebookAfterChar,
  2 || 3 => l10n.tavernLoreNearNote,
  4 => l10n.tavernLoreAtDepth(hit['depth'] is int ? hit['depth']! as int : 0),
  5 || 6 => l10n.tavernLoreNearExamples,
  7 => l10n.tavernLoreOutlet,
  _ => '',
};

/// A hit: the entry's name (or its first line), why, where and in what
/// order it goes, and the first lines of what goes in.
class _HitRow extends StatelessWidget {
  const _HitRow({super.key, required this.hit, required this.title, required this.onOpen});

  final Map<String, Object?> hit;
  final String? title;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final dsh = DshColors.of(context);
    final content = hit['content'] is String ? (hit['content']! as String).trim() : '';
    final order = hit['order'];
    final meta = [
      tavernHitReason(l10n, hit),
      tavernHitPosition(l10n, hit),
      if (order is num) l10n.tavernLoreOrder('$order'),
    ].where((s) => s.isNotEmpty).join(' · ');
    return InkWell(
      onTap: onOpen,
      splashFactory: rowSplash(context),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(SettingsMetrics.inset, 12, SettingsMetrics.inset, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              title ?? content.split('\n').first,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyLarge,
            ),
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(meta, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.primary)),
            ),
            if (content.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  content,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(color: dsh.textTertiary, height: 1.45),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

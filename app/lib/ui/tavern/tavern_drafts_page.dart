// 草稿 (STAGE2-IMPLEMENTATION-R3 §6): the drafts kept so far, newest first.
// From a character's page, its own drafts and 新草稿; from 资源库, all of
// them and 从文件起稿, which keeps a file as a draft without importing it.

import 'dart:async';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../tavern/tavern_authoring.dart';
import '../../tavern/tavern_file_kind.dart';
import '../../tavern/tavern_provider.dart';
import '../bots/bot_format.dart' show shortTime;
import '../common/brief_notice.dart';
import '../common/empty_view.dart';
import '../features/feature_kit.dart' show QuietSpinner;
import '../settings/settings_widgets.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import 'tavern_chat_files.dart' show tavernChatPickerProvider;
import 'tavern_draft_page.dart';
import 'tavern_lorebooks_page.dart' show tavernLorebooksProvider;

class TavernDraftsPage extends ConsumerStatefulWidget {
  const TavernDraftsPage({super.key, this.characterId});

  /// Only this character's drafts, with 新草稿 for it; null for all of them.
  final String? characterId;

  static Route<void> route({String? characterId}) =>
      MaterialPageRoute<void>(builder: (_) => TavernDraftsPage(characterId: characterId));

  @override
  ConsumerState<TavernDraftsPage> createState() => _TavernDraftsPageState();
}

class _TavernDraftsPageState extends ConsumerState<TavernDraftsPage> {
  bool _busy = false;

  Future<void> _open(String draftId) async {
    await Navigator.of(context).push(TavernDraftPage.route(draftId));
    ref.invalidate(tavernDraftsProvider);
  }

  Future<void> _create() async {
    setState(() => _busy = true);
    try {
      final draft = await ref.read(tavernProvider).createAuthoringDraft([
        TavernAuthoringTarget(kind: TavernAuthoringTargetKind.character, id: widget.characterId!),
      ]);
      if (mounted) await _open(draft.id);
    } on TavernAuthoringException catch (e) {
      if (mounted) showBriefNotice(context, e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// A card or a lorebook file kept as a draft: nothing is imported until
  /// 另存为新的 in the draft.
  Future<void> _fromFile() async {
    final l10n = context.l10n;
    final picked = await ref.read(tavernChatPickerProvider)();
    if (picked.isEmpty || !mounted) return;
    final file = picked.first;
    final kind = switch (tavernFileKindOf(file.fileName, file.bytes)) {
      TavernFileKind.card => TavernAuthoringTargetKind.character,
      TavernFileKind.lorebook => TavernAuthoringTargetKind.lorebook,
      _ => null,
    };
    if (kind == null) {
      showBriefNotice(context, l10n.tavernDraftSeedUnsupported(file.fileName));
      return;
    }
    setState(() => _busy = true);
    try {
      final draft = await ref
          .read(tavernProvider)
          .createAuthoringSeed(TavernAuthoringSeedInput(kind: kind, bytes: file.bytes, fileName: file.fileName));
      if (mounted) await _open(draft.id);
    } on TavernAuthoringException catch (e) {
      if (mounted) showBriefNotice(context, l10n.tavernImportFileFailed(file.fileName, e.message));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// What a draft is of, by the names in the library; a seed (or something
  /// since deleted) by its kind.
  String _name(L10n l10n, TavernAuthoringTarget target) {
    switch (target.kind) {
      case TavernAuthoringTargetKind.character:
        for (final c in ref.watch(tavernCharactersProvider).value ?? const <TavernCharacter>[]) {
          if (c.id == target.id) return c.name;
        }
        return l10n.tavernDraftKindCharacter;
      case TavernAuthoringTargetKind.lorebook:
        for (final b in ref.watch(tavernLorebooksProvider).value?.books ?? const <TavernLorebookSummary>[]) {
          if (b.id == target.id) return b.name;
        }
        return l10n.tavernLorebook;
      case TavernAuthoringTargetKind.regexLibrary:
        return l10n.tavernRegex;
      case TavernAuthoringTargetKind.preset:
        return l10n.tavernDraftKindPreset;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final drafts = ref.watch(tavernDraftsProvider);
    final own = widget.characterId;
    final shown = [
      for (final d in drafts.value ?? const <TavernAuthoringDraftSummary>[])
        if (own == null || d.targets.any((t) => t.kind == TavernAuthoringTargetKind.character && t.id == own)) d,
    ];
    return AppPage.list(
      title: l10n.tavernDrafts,
      subtitle: Text(l10n.tavernDraftsSubtitle),
      actions: [
        GlassIconButton(
          key: const ValueKey('tavern-drafts-new'),
          icon: own == null ? AppIcons.download : AppIcons.add,
          tooltip: own == null ? l10n.tavernDraftFromFile : l10n.tavernDraftNew,
          onPressed: _busy ? null : () => unawaited(own == null ? _fromFile() : _create()),
        ),
      ],
      children: [
        if (drafts.isLoading && !drafts.hasValue)
          const Padding(
            padding: EdgeInsets.only(top: 48),
            child: Center(child: QuietSpinner()),
          )
        else if (shown.isEmpty)
          Padding(
            key: const ValueKey('tavern-drafts-empty'),
            padding: const EdgeInsets.only(top: 48),
            child: EmptyView(
              icon: AppIcons.askAi,
              title: l10n.tavernDraftsEmpty,
              message: drafts.hasError
                  ? '${drafts.error}'
                  : own == null
                  ? l10n.tavernDraftsEmptyAll
                  : l10n.tavernDraftsEmptyOwn,
              actionLabel: own == null ? l10n.tavernDraftFromFile : l10n.tavernDraftNew,
              onAction: _busy ? null : () => unawaited(own == null ? _fromFile() : _create()),
              compact: true,
            ),
          )
        else
          SettingsSection(
            key: const ValueKey('tavern-drafts'),
            children: [
              for (final d in shown)
                SettingsTile(
                  key: ValueKey('tavern-draft-${d.id}'),
                  icon: AppIcons.article,
                  tinted: false,
                  title: [for (final t in d.targets) _name(l10n, t)].join('、'),
                  value: Text(shortTime(d.updatedAt.toLocal())),
                  onTap: () => unawaited(_open(d.id)),
                ),
            ],
          ),
      ],
    );
  }
}

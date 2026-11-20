// 用草稿看提示词 (STAGE2-IMPLEMENTATION-R3 §5): the prompt the next turn of
// one of the character's chats would send with the ticked changes in, put
// together on a copy. Nothing is sent and the chat is not touched. Card
// scripts do not run here; a card that needs them says so.

import 'dart:async';
import 'dart:math';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../tavern/tavern_provider.dart';
import '../../tavern/tavern_tool_turns.dart' show tavernNewId;
import '../bots/bot_format.dart' show shortTime;
import '../features/feature_kit.dart' show QuietSpinner;
import '../providers/provider_widgets.dart' show FormFieldBlock, FormFieldGroup;
import '../settings/settings_widgets.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import 'tavern_inspector_page.dart' show TavernPromptSegmentTile;

class TavernDraftPromptPage extends ConsumerStatefulWidget {
  const TavernDraftPromptPage({super.key, required this.draft, required this.changeIds});

  final TavernAuthoringDraft draft;
  final List<String> changeIds;

  static Route<void> route({required TavernAuthoringDraft draft, required List<String> changeIds}) =>
      MaterialPageRoute<void>(
        builder: (_) => TavernDraftPromptPage(draft: draft, changeIds: changeIds),
      );

  @override
  ConsumerState<TavernDraftPromptPage> createState() => _TavernDraftPromptPageState();
}

class _TavernDraftPromptPageState extends ConsumerState<TavernDraftPromptPage> {
  final _text = TextEditingController();

  /// The chat whose next turn is shown; null for a first message to the card.
  String? _chatId;
  bool _picked = false;
  TavernAuthoringTask<TavernAuthoringPromptPreview>? _task;
  TavernAuthoringPromptPreview? _result;
  String? _error;

  TavernAuthoringSource get _character =>
      widget.draft.sources.firstWhere((s) => s.target.kind == TavernAuthoringTargetKind.character);

  @override
  void dispose() {
    unawaited(_task?.cancel());
    _text.dispose();
    super.dispose();
  }

  Future<void> _show() async {
    final character = _character;
    final task = ref
        .read(tavernProvider)
        .previewAuthoringPrompt(
          TavernAuthoringPromptRequest(
            requestId: tavernNewId(),
            draftId: widget.draft.id,
            draftRevision: widget.draft.draftRevision,
            changeIds: widget.changeIds,
            context: switch (_chatId) {
              final chat? => TavernAuthoringChatContext(chatId: chat),
              null => TavernAuthoringSampleContext(characterResourceId: character.physicalResourceId),
            },
            text: _text.text,
            at: DateTime.now().toUtc(),
            seed: Random().nextInt(1 << 31),
          ),
        );
    setState(() {
      _task = task;
      _result = null;
      _error = null;
    });
    try {
      final result = await task.result;
      if (mounted && _task == task) setState(() => _result = result);
    } on Object catch (e) {
      if (mounted && _task == task) setState(() => _error = '$e'.split('\n').first);
    }
    if (mounted && _task == task) setState(() => _task = null);
  }

  static String _statusText(L10n l10n, TavernAuthoringPreviewStatus status) => switch (status) {
    TavernAuthoringPreviewStatus.complete => l10n.tavernDraftPromptComplete,
    TavernAuthoringPreviewStatus.unsupported => l10n.tavernDraftPromptUnsupported,
    TavernAuthoringPreviewStatus.cancelled => l10n.tavernDraftAiStopped,
    TavernAuthoringPreviewStatus.conflict => l10n.tavernDraftChangedMeanwhile,
    TavernAuthoringPreviewStatus.failed => l10n.tavernDraftAiFailed,
  };

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final character = _character;
    // A seed is no shelf character yet: it has no chats. A group's next turn
    // needs a speaker picked; its single chats are enough here.
    final chats = character.origin == TavernAuthoringSourceOrigin.seed
        ? const <TavernChatSummary>[]
        : [
            for (final c in ref.watch(tavernChatsProvider(character.target.id)).value ?? const <TavernChatSummary>[])
              if (c.kind == TavernChatKind.single) c,
          ];
    if (!_picked && chats.isNotEmpty) {
      _chatId = chats.first.id;
      _picked = true;
    }
    final result = _result;
    final segments = result?.assembly?.afterPostProcessing ?? const <PromptSegment>[];
    final running = _task != null;
    return AppPage.list(
      title: l10n.tavernDraftPrompt,
      subtitle: Text(l10n.tavernDraftPromptSubtitle),
      children: [
        SettingsSection(
          title: l10n.tavernDraftPromptFrom,
          children: [
            for (final chat in chats.take(5))
              SettingsTile(
                key: ValueKey('tavern-draft-prompt-chat-${chat.id}'),
                icon: _chatId == chat.id ? AppIcons.done : AppIcons.chat,
                tinted: false,
                title: chat.title.isEmpty ? shortTime(chat.updatedAt.toLocal()) : chat.title,
                value: Text(shortTime(chat.updatedAt.toLocal())),
                chevron: false,
                onTap: () => setState(() {
                  _chatId = chat.id;
                  _picked = true;
                }),
              ),
            SettingsTile(
              key: const ValueKey('tavern-draft-prompt-first'),
              icon: _chatId == null ? AppIcons.done : AppIcons.add,
              tinted: false,
              title: l10n.tavernDraftPromptFirst,
              chevron: false,
              onTap: () => setState(() {
                _chatId = null;
                _picked = true;
              }),
            ),
          ],
        ),
        SettingsSection(
          children: [
            FormFieldGroup(
              children: [
                FormFieldBlock(
                  label: l10n.tavernDraftPromptText,
                  child: TextField(
                    key: const ValueKey('tavern-draft-prompt-text'),
                    controller: _text,
                    minLines: 1,
                    maxLines: 4,
                    decoration: InputDecoration(hintText: l10n.tavernDraftPromptTextHint),
                  ),
                ),
              ],
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
          child: FilledButton(
            key: const ValueKey('tavern-draft-prompt-show'),
            onPressed: running ? null : () => unawaited(_show()),
            child: running ? const QuietSpinner() : Text(l10n.tavernDraftPromptShow),
          ),
        ),
        if (result != null || _error != null)
          SettingsSection(
            key: const ValueKey('tavern-draft-prompt-result'),
            title: _error ?? _statusText(l10n, result!.status),
            footer: segments.isEmpty ? null : Text(l10n.tavernDraftPromptNote),
            children: [
              for (final issue in result?.issues ?? const <TavernAuthoringIssue>[])
                SettingsTile(
                  icon: AppIcons.info,
                  tinted: false,
                  title: issue.message,
                  subtitle: issue.type,
                  chevron: false,
                ),
              for (final s in segments) TavernPromptSegmentTile(segment: s),
            ],
          ),
        const SizedBox(height: 24),
      ],
    );
  }
}

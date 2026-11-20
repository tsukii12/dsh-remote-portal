// 试玩 (Pro 阶段二 C7): the draft played for one to four lines in a chat of
// its own, with the real model, so the card can be tried before it is
// applied. The real chats are not touched; the model is asked for real and
// what it used is shown.

import 'dart:async';
import 'dart:math';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../tavern/tavern_authoring.dart';
import '../../tavern/tavern_provider.dart';
import '../../tavern/tavern_tool_turns.dart' show tavernNewId;
import '../../tavern/tavern_usage_summary.dart';
import '../features/feature_kit.dart' show QuietSpinner;
import '../providers/provider_widgets.dart' show FormFieldBlock, FormFieldGroup;
import '../settings/settings_widgets.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';

class TavernDraftTrialPage extends ConsumerStatefulWidget {
  const TavernDraftTrialPage({super.key, required this.draft, required this.changeIds});

  final TavernAuthoringDraft draft;
  final List<String> changeIds;

  /// The most lines one trial plays.
  static const lines = 4;

  static Route<void> route({required TavernAuthoringDraft draft, required List<String> changeIds}) =>
      MaterialPageRoute<void>(
        builder: (_) => TavernDraftTrialPage(draft: draft, changeIds: changeIds),
      );

  @override
  ConsumerState<TavernDraftTrialPage> createState() => _TavernDraftTrialPageState();
}

class _TavernDraftTrialPageState extends ConsumerState<TavernDraftTrialPage> {
  final _inputs = [TextEditingController()];
  TavernAuthoringSimulationTask? _task;
  TavernAuthoringSimulationResult? _result;
  String? _error;

  /// While it plays, what it has so far, read from the task now and then.
  Timer? _watch;

  @override
  void dispose() {
    _watch?.cancel();
    // Leaving stops it: nothing would show what it goes on to spend.
    unawaited(_task?.cancel());
    for (final c in _inputs) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _play() async {
    final lines = [
      for (final c in _inputs)
        if (c.text.trim().isNotEmpty) c.text.trim(),
    ];
    if (lines.isEmpty) return;
    final character = widget.draft.sources.firstWhere((s) => s.target.kind == TavernAuthoringTargetKind.character);
    final task = ref
        .read(tavernProvider)
        .simulateAuthoringDraft(
          TavernAuthoringSimulationRequest(
            requestId: tavernNewId(),
            draftId: widget.draft.id,
            draftRevision: widget.draft.draftRevision,
            changeIds: widget.changeIds,
            context: TavernAuthoringSampleContext(characterResourceId: character.physicalResourceId),
            userInputs: lines,
            at: DateTime.now().toUtc(),
            seed: Random().nextInt(1 << 31),
          ),
        );
    setState(() {
      _task = task;
      _result = null;
      _error = null;
    });
    _watch = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (mounted && _task == task) setState(() => _result = task.view);
    });
    try {
      final result = await task.result;
      if (mounted) setState(() => _result = result);
    } on Object catch (e) {
      if (mounted) {
        setState(() {
          _result = task.view;
          _error = '$e'.split('\n').first;
        });
      }
    }
    _watch?.cancel();
    if (mounted) setState(() => _task = null);
  }

  static String _statusText(L10n l10n, TavernAuthoringSimulationStatus status) => switch (status) {
    TavernAuthoringSimulationStatus.running => l10n.tavernDraftTrialRunning,
    TavernAuthoringSimulationStatus.completed => l10n.tavernDraftTrialDone,
    TavernAuthoringSimulationStatus.cancelled => l10n.tavernDraftAiStopped,
    TavernAuthoringSimulationStatus.conflict => l10n.tavernDraftChangedMeanwhile,
    TavernAuthoringSimulationStatus.unsupported => l10n.tavernDraftTrialUnsupported,
    TavernAuthoringSimulationStatus.failed => l10n.tavernDraftAiFailed,
  };

  Widget _turn(TavernAuthoringSimulationTurn turn) {
    final theme = Theme.of(context);
    final dsh = DshColors.of(context);
    final reply = turn.message?.text;
    return Padding(
      key: ValueKey('tavern-draft-trial-turn-${turn.index}'),
      padding: const EdgeInsets.symmetric(horizontal: SettingsMetrics.inset, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(turn.input, style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          const SizedBox(height: 8),
          if (reply != null && reply.isNotEmpty)
            SelectableText(reply, style: theme.textTheme.bodyMedium?.copyWith(height: 1.55))
          else if (turn.status == TavernAuthoringSimulationStatus.running)
            const Align(alignment: Alignment.centerLeft, child: QuietSpinner())
          else
            Text(
              [_statusText(context.l10n, turn.status), if (turn.failure?['message'] case final String m) m].join(' · '),
              style: theme.textTheme.bodySmall?.copyWith(color: dsh.textTertiary),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final result = _result;
    final running = _task != null;
    final usage = result == null ? null : TavernUsageSummary.fromJson(result.usage);
    return AppPage.list(
      title: l10n.tavernDraftTrial,
      subtitle: Text(l10n.tavernDraftTrialSubtitle),
      children: [
        SettingsSection(
          footer: Text(l10n.tavernDraftTrialNote),
          children: [
            FormFieldGroup(
              children: [
                for (final (i, c) in _inputs.indexed)
                  FormFieldBlock(
                    label: l10n.tavernDraftTrialLine(i + 1),
                    child: TextField(
                      key: ValueKey('tavern-draft-trial-line-$i'),
                      controller: c,
                      enabled: !running,
                      minLines: 1,
                      maxLines: 3,
                    ),
                  ),
              ],
            ),
            if (_inputs.length < TavernDraftTrialPage.lines && !running)
              SettingsTile(
                key: const ValueKey('tavern-draft-trial-more'),
                icon: AppIcons.add,
                tinted: false,
                title: l10n.tavernDraftTrialMore,
                chevron: false,
                onTap: () => setState(() => _inputs.add(TextEditingController())),
              ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
          child: running
              ? OutlinedButton(
                  key: const ValueKey('tavern-draft-trial-stop'),
                  onPressed: () => unawaited(_task!.cancel()),
                  child: Text(l10n.tavernDraftAiStop),
                )
              : FilledButton(
                  key: const ValueKey('tavern-draft-trial-play'),
                  onPressed: () => unawaited(_play()),
                  child: Text(l10n.tavernDraftTrialPlay),
                ),
        ),
        if (result != null)
          SettingsSection(
            key: const ValueKey('tavern-draft-trial-result'),
            title: _error ?? _statusText(l10n, result.status),
            footer: usage == null
                ? null
                : Text([l10n.tavernInspectRequests(usage.requests), tavernDraftUsageText(l10n, usage)].join(' · ')),
            children: [
              for (final turn in result.turns) _turn(turn),
              for (final issue in result.issues)
                SettingsTile(icon: AppIcons.info, tinted: false, title: issue.message, chevron: false),
            ],
          ),
        const SizedBox(height: 24),
      ],
    );
  }
}

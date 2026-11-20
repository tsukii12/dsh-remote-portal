// 舞台 › 状态 › 后台记录 (docs/design/roleplay-ui.md §8–§9): who changed the
// state and what the director, card events and the story did, newest first,
// from the engine's audit (readAgentRuns). One opens to its raw record.

import 'dart:async';
import 'dart:convert';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../tavern/tavern_agent_runs.dart';
import '../../tavern/tavern_provider.dart';
import '../bots/bot_format.dart' show shortTime;
import '../common/app_sheet.dart';
import '../common/empty_view.dart';
import '../common/sheet_title_bar.dart';
import '../features/feature_kit.dart' show QuietSpinner;
import '../settings/settings_widgets.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';

class TavernRunsPage extends ConsumerStatefulWidget {
  const TavernRunsPage({super.key, required this.chatId});

  final String chatId;

  /// How many the page reads at most.
  static const limit = 100;

  static Route<void> route(String chatId) => MaterialPageRoute<void>(builder: (_) => TavernRunsPage(chatId: chatId));

  @override
  ConsumerState<TavernRunsPage> createState() => _TavernRunsPageState();
}

class _TavernRunsPageState extends ConsumerState<TavernRunsPage> {
  late final Future<List<TavernAgentRun>> _runs = ref
      .read(tavernProvider)
      .readAgentRuns(widget.chatId, limit: TavernRunsPage.limit);

  static String _label(TavernRunFamily family, String kind, L10n l10n) => switch (family) {
    TavernRunFamily.user => l10n.tavernRunUser,
    TavernRunFamily.model => l10n.tavernRunModel,
    TavernRunFamily.rules => l10n.tavernRunRules,
    TavernRunFamily.stopped => l10n.tavernRunStopped,
    TavernRunFamily.director => l10n.tavernRunDirector,
    TavernRunFamily.directorFailed => l10n.tavernRunDirectorFailed,
    TavernRunFamily.event => l10n.tavernRunEvent,
    TavernRunFamily.story => l10n.tavernRunStory,
    TavernRunFamily.secret => l10n.tavernRunSecret,
    TavernRunFamily.other => kind,
  };

  static IconData _icon(TavernRunFamily family) => switch (family) {
    TavernRunFamily.user => AppIcons.edit,
    TavernRunFamily.model => AppIcons.model,
    TavernRunFamily.rules => AppIcons.workflow,
    TavernRunFamily.stopped => AppIcons.stopped,
    TavernRunFamily.director => AppIcons.askAi,
    TavernRunFamily.directorFailed => AppIcons.failed,
    TavernRunFamily.event => AppIcons.announcement,
    TavernRunFamily.story => AppIcons.article,
    TavernRunFamily.secret => AppIcons.lock,
    TavernRunFamily.other => AppIcons.history,
  };

  /// [run]'s line under its label: what it changed (three at most, then how
  /// many more), else what went wrong; then when, and whether it was kept and
  /// its message is still there.
  static String _line(TavernAgentRun run, L10n l10n) {
    final changes = tavernRunChanges(run);
    final issue = tavernRunIssue(run);
    return [
      if (changes.isNotEmpty)
        [...changes.take(3), if (changes.length > 3) l10n.tavernRunMore(changes.length - 3)].join('；')
      else
        ?issue,
      // Not kept: why, when the line above did not already say.
      if (!tavernRunKept(run))
        changes.isNotEmpty && issue != null ? '${l10n.tavernRunNotKept}：$issue' : l10n.tavernRunNotKept,
      if (run.nodeId == null) l10n.tavernRunGone,
      shortTime(run.at),
    ].join(' · ');
  }

  Future<void> _open(TavernAgentRun run, String label) async {
    final whole = const JsonEncoder.withIndent('  ').convert({
      'kind': run.kind,
      'at': run.at.toIso8601String(),
      'nodeId': run.nodeId,
      'usage': ?run.usage,
      'result': run.result,
    });
    await showAppSheet<void>(
      context,
      isScrollControlled: true,
      builder: (sheet) => SafeArea(
        top: false,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(sheet).height * 0.75),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SheetTitleBar(label),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(SheetTitleBar.inset + 12, 0, SheetTitleBar.inset + 12, 16),
                  child: SelectableText(
                    whole,
                    key: const ValueKey('tavern-run-whole'),
                    style: Theme.of(sheet).textTheme.bodySmall?.copyWith(fontFamily: 'monospace', height: 1.5),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return FutureBuilder<List<TavernAgentRun>>(
      future: _runs,
      builder: (context, snapshot) {
        final runs = snapshot.data;
        return AppPage.list(
          title: l10n.tavernRuns,
          children: [
            if (runs == null && !snapshot.hasError)
              const Padding(
                padding: EdgeInsets.only(top: 48),
                child: Center(child: QuietSpinner()),
              )
            else if (runs == null || runs.isEmpty)
              Padding(
                key: const ValueKey('tavern-runs-empty'),
                padding: const EdgeInsets.only(top: 48),
                child: EmptyView(
                  icon: AppIcons.history,
                  title: l10n.tavernRunsEmpty,
                  message: snapshot.hasError ? '${snapshot.error}' : l10n.tavernRunsEmptyMessage,
                  compact: true,
                ),
              )
            else
              SettingsSection(
                key: const ValueKey('tavern-runs'),
                footer: Text(l10n.tavernRunsNote),
                children: [
                  for (final run in runs)
                    () {
                      final family = tavernRunFamily(run.kind);
                      final label = _label(family, run.kind, l10n);
                      return SettingsTile(
                        key: ValueKey('tavern-run-${run.id}'),
                        icon: _icon(family),
                        tinted: false,
                        danger: !tavernRunKept(run) || family == TavernRunFamily.directorFailed,
                        title: label,
                        subtitle: _line(run, l10n),
                        chevron: false,
                        onTap: () => unawaited(_open(run, label)),
                      );
                    }(),
                ],
              ),
          ],
        );
      },
    );
  }
}
